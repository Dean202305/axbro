#!/bin/zsh
# Regenerate all macOS app-icon representations from the selected axbro master.
set -eu
cd "$(dirname "$0")/.."
MASTER="Source/Assets/AxbroLogo.png"
SET=".build/axbro.iconset"
mkdir -p "$SET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$MASTER" --out "$SET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$MASTER" --out "$SET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Source/AppIcon.icns
