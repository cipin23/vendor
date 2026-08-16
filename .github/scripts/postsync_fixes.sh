#!/usr/bin/env bash
# postsync_fixes.sh
# ------------------
# Replay semua fix yang ditemukan selama sesi debugging manual build vendor.img
# LOS 18.1 a02. Dijalankan SETELAH `repo sync` selesai, SEBELUM `lunch`/`mka`.
#
# Usage: postsync_fixes.sh <source_tree_root>
set -euo pipefail

SRC="${1:?Usage: postsync_fixes.sh <source_tree_root>}"
cd "$SRC"

echo "=== [1/5] Hapus duplikat device/vendor fisik di dalam project _rdbckp_vendor ==="
# Root cause Masalah 3: <copyfile> di manifest duplikasi isi device/samsung/a02 dan
# vendor/samsung/a02 ke dua lokasi (project asli _rdbckp_vendor + dest copyfile).
# Soong nemuin Android.bp yang sama di dua tempat -> "already defined".
if [ -d "_rdbckp_vendor/device" ]; then
  rm -rf _rdbckp_vendor/device
  echo "  removed _rdbckp_vendor/device"
fi
if [ -d "_rdbckp_vendor/vendor" ]; then
  rm -rf _rdbckp_vendor/vendor
  echo "  removed _rdbckp_vendor/vendor"
fi

echo "=== [2/5] Disable module type/module yang gak dikenal Soong utk target vendorimage ==="
# tradefed_binary_host: module type ini gak diregister di Soong config default untuk
# vendorimage build (khusus VTS test suite variant), sync test/vts gak akan fix ini.
declare -a DISABLE_LIST=(
  "test/vts/tools/vts-tradefed/Android.bp"
  "test/vts/tools/vts-core-tradefed/Android.bp"
)
for f in "${DISABLE_LIST[@]}"; do
  if [ -f "$f" ]; then
    mv "$f" "$f.disabled"
    echo "  disabled: $f"
  fi
done

echo "=== [3/5] Rename modul di vendor/samsung/a02/Android.bp yang collision sama AOSP core ==="
VENDOR_BP="vendor/samsung/a02/Android.bp"
VENDOR_MK="vendor/samsung/a02/a02-vendor.mk"

if [ ! -f "$VENDOR_BP" ]; then
  echo "  ERROR: $VENDOR_BP tidak ditemukan, skip step ini" >&2
else
  # Regenerate collision list secara dinamis (bukan hardcoded) biar tetap akurat
  # walau isi Android.bp berubah di masa depan.
  grep -oP '(?<=name: ")[a-zA-Z0-9_.@-]+(?=")' "$VENDOR_BP" | sort -u > /tmp/_vendor_module_names.txt
  find "$SRC" -name Android.bp -not -path '*/out/*' -not -path "$SRC/$VENDOR_BP" \
    -exec grep -ohP '(?<=name: ")[a-zA-Z0-9_.@-]+(?=")' {} \; 2>/dev/null \
    | sort -u > /tmp/_other_module_names.txt
  comm -12 /tmp/_vendor_module_names.txt /tmp/_other_module_names.txt > /tmp/_collision_names.txt

  N_COLLISION=$(wc -l < /tmp/_collision_names.txt)
  echo "  ditemukan $N_COLLISION collision module name"

  python3 - "$VENDOR_BP" "$VENDOR_MK" /tmp/_collision_names.txt <<'PYEOF'
import re, sys

bp_path, mk_path, collision_path = sys.argv[1], sys.argv[2], sys.argv[3]
PREFIX = "vnda02_"

with open(collision_path) as f:
    names = [l.strip() for l in f if l.strip()]

with open(bp_path) as f:
    bp = f.read()
with open(mk_path) as f:
    mk = f.read()

renamed, skipped, mk_updated = [], [], []

# Proses nama yang lebih panjang dulu supaya nama yang jadi substring nama lain
# (mis. "libeffects" vs "libeffectsconfig") gak salah ke-replace duluan.
for name in sorted(names, key=len, reverse=True):
    pattern = f'name: "{name}"'
    count = bp.count(pattern)
    if count == 0:
        skipped.append(name)
        continue
    if count > 1:
        print(f"  WARNING: '{name}' muncul {count}x, skip (perlu review manual)")
        continue
    new_name = PREFIX + re.sub(r'[^A-Za-z0-9_]', '_', name)
    bp = bp.replace(pattern, f'name: "{new_name}"')
    renamed.append((name, new_name))

    mk_pattern = re.compile(r'(?<![A-Za-z0-9_.@-])' + re.escape(name) + r'(?![A-Za-z0-9_.@-])')
    new_mk, n = mk_pattern.subn(new_name, mk)
    if n > 0:
        mk = new_mk
        mk_updated.append((name, new_name, n))

with open(bp_path, "w") as f:
    f.write(bp)
with open(mk_path, "w") as f:
    f.write(mk)

print(f"  renamed di Android.bp : {len(renamed)}")
print(f"  updated di a02-vendor.mk : {len(mk_updated)}")
print(f"  skip (gak ketemu literal, mungkin format beda) : {len(skipped)}")
if skipped:
    print("   ->", skipped)
PYEOF
fi

echo "=== [4/5] Invalidate Soong finder cache ==="
rm -rf out/.module_paths out/soong/.finder* 2>/dev/null || true
find out -iname "*files.db*" -delete 2>/dev/null || true

echo "=== [5/5] Selesai. Siap lunch + mka vendorimage (pakai BUILD_HOST_static=true) ==="
