#!/bin/bash
# Regenerate committed icon sizes from the reviewed brand masters.
# Requires ImageMagick for the menu-bar SVG; Xcode builds use the committed PNGs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

if ! command -v magick >/dev/null 2>&1; then
    echo "ImageMagick is required to regenerate brand assets (brew install imagemagick)." >&2
    exit 1
fi

MASTER=docs/media/brand/soft-wave-app-master.png
WAVE=docs/media/brand/soft-wave-menu.svg
APP_SET=Sotto/Assets.xcassets/AppIcon.appiconset
MENU_SET=Sotto/Assets.xcassets/MenuBarIcon.imageset
GLASS_SET=Sotto/Assets.xcassets/MenuBarGlassIcon.imageset

for size in 16 32 128 256 512; do
    magick "$MASTER" -filter Lanczos -resize "${size}x${size}" "$APP_SET/icon_${size}x${size}@1x.png"
    double_size=$((size * 2))
    magick "$MASTER" -filter Lanczos -resize "${double_size}x${double_size}" "$APP_SET/icon_${size}x${size}@2x.png"
done

for size in 16 18 32; do
    magick -background none "$WAVE" -resize "${size}x${size}" "docs/media/brand/menu-wave-${size}@1x.png"
    double_size=$((size * 2))
    magick -background none "$WAVE" -resize "${double_size}x${double_size}" "docs/media/brand/menu-wave-${size}@2x.png"
done
cp docs/media/brand/menu-wave-18@1x.png "$MENU_SET/menu-wave-18.png"
cp docs/media/brand/menu-wave-18@2x.png "$MENU_SET/menu-wave-36.png"

brand_tmp="$(mktemp -d)"
trap 'rm -rf "$brand_tmp"' EXIT
for appearance in light dark; do
    if [ "$appearance" = light ]; then
        wave_source=docs/media/brand/soft-wave-menu-light.svg
        glass_fill='rgba(20,20,19,0.09)'
        glass_border='rgba(20,20,19,0.20)'
    else
        wave_source="$WAVE"
        glass_fill='rgba(244,240,230,0.10)'
        glass_border='rgba(244,240,230,0.25)'
    fi
    magick -size 128x96 xc:none -fill "$glass_fill" -stroke "$glass_border" -strokewidth 4 \
        -draw 'roundrectangle 4,4 123,91 39,39' "$brand_tmp/glass.png"
    magick -background none "$wave_source" -resize 72x72 "$brand_tmp/wave.png"
    magick "$brand_tmp/glass.png" "$brand_tmp/wave.png" -geometry +28+12 -composite "$brand_tmp/combined.png"
    magick "$brand_tmp/combined.png" -filter Lanczos -resize 32x24 "$GLASS_SET/menu-glass-${appearance}-32.png"
    magick "$brand_tmp/combined.png" -filter Lanczos -resize 64x48 "$GLASS_SET/menu-glass-${appearance}-64.png"
    cp "$GLASS_SET/menu-glass-${appearance}-64.png" "docs/media/brand/menu-glass-${appearance}@2x.png"
done

MATRIX=docs/media/brand/size-matrix.png
magick -size 1000x460 xc:'#E8ECEB' \
    -fill '#141413' -draw 'rectangle 0,230 999,459' \
    -font Arial -pointsize 25 -fill '#141413' -annotate +30+45 'Light' \
    -fill '#F4F0E6' -annotate +30+275 'Dark' \
    "$MATRIX"

for size in 128 64 32 16; do
    magick "$MASTER" -filter Lanczos -resize "${size}x${size}" "docs/media/brand/app-${size}.png"
    case "$size" in
        128) x=140; y=68 ;;
        64) x=420; y=100 ;;
        32) x=650; y=116 ;;
        16) x=840; y=124 ;;
    esac
    magick "$MATRIX" "docs/media/brand/app-${size}.png" -geometry "+${x}+${y}" -composite "$MATRIX"
    dark_y=$((y + 230))
    magick "$MATRIX" "docs/media/brand/app-${size}.png" -geometry "+${x}+${dark_y}" -composite "$MATRIX"
    magick "$MATRIX" -font Arial -pointsize 18 -fill '#596968' -annotate "+${x}+213" "${size}px" \
        -fill '#AAB7B6' -annotate "+${x}+443" "${size}px" "$MATRIX"
done

echo "Regenerated AppIcon sizes, menu wave exports, and glass menu bar images."
