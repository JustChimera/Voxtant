#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/lecture-translate-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/lecture-translate-swift-cache"
swift build --disable-sandbox --cache-path .build/shared-cache --config-path .build/shared-config --security-path .build/shared-security -c debug
BIN_DIR="$(swift build --disable-sandbox --cache-path .build/shared-cache --config-path .build/shared-config --security-path .build/shared-security -c debug --show-bin-path)"
APP="dist/Voxtant.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Voxtant" "$APP/Contents/MacOS/Voxtant"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.lecturetranslate.demo "$APP"
printf '\nBuilt: %s/%s\n' "$PWD" "$APP"
