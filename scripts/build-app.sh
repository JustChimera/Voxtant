#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Expected debug or release" >&2; exit 1 ;; esac
sh scripts/build-icon.sh
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/lecture-translate-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/lecture-translate-swift-cache"
swift build --disable-sandbox --cache-path .build/shared-cache --config-path .build/shared-config --security-path .build/shared-security -c "$CONFIGURATION" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
BIN_DIR="$(swift build --disable-sandbox --cache-path .build/shared-cache --config-path .build/shared-config --security-path .build/shared-security -c "$CONFIGURATION" --show-bin-path)"
APP="dist/Voxtant.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Voxtant" "$APP/Contents/MacOS/Voxtant"
if [ "$CONFIGURATION" = release ]; then
    strip -S "$APP/Contents/MacOS/Voxtant"
fi
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp .build/brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
codesign --force --sign - --identifier local.lecturetranslate.demo "$APP"
printf '\nBuilt: %s/%s\n' "$PWD" "$APP"
