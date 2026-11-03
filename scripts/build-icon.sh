#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SOURCE="assets/brand/app-icon.png"
OUTPUT=".build/brand/AppIcon.icns"
if [ -f "$OUTPUT" ] && [ "$OUTPUT" -nt "$SOURCE" ] && [ "$OUTPUT" -nt "$0" ]; then
    exit 0
fi
ICONSET=".build/brand/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$OUTPUT"
