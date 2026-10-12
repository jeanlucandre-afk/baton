#!/bin/zsh
# Renders every macOS app icon size from one 1024×1024 PNG into the asset catalog.
#   Scripts/make-icon.sh design/icon/baton-1024.png
set -euo pipefail
src=${1:?usage: Scripts/make-icon.sh <1024.png>}
[[ -f $src ]] || { echo "No such file: $src" >&2; exit 1; }
out="${0:A:h}/../App/Baton/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$out"
for size in 16 32 128 256 512; do
  sips -s format png -z $size $size "$src" --out "$out/icon_${size}x${size}.png" >/dev/null
  sips -s format png -z $((size * 2)) $((size * 2)) "$src" --out "$out/icon_${size}x${size}@2x.png" >/dev/null
done
echo "Wrote 10 sizes to ${out:A}"
