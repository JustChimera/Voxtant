#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/build-app.sh release
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/Voxtant.app/Contents/Info.plist)
ARCH=$(uname -m)
NAME="Voxtant-${VERSION}-macOS-${ARCH}"
OUTPUT="dist/releases"
mkdir -p "$OUTPUT"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/voxtant-release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
ditto dist/Voxtant.app "$STAGING/Voxtant.app"
ln -s /Applications "$STAGING/Applications"
cp LICENSE "$STAGING/LICENSE.txt"
cp docs/INSTALL.txt "$STAGING/READ-ME-FIRST.txt"
codesign --verify --deep --strict "$STAGING/Voxtant.app"
rm -f "$OUTPUT/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Voxtant.app "$OUTPUT/$NAME.zip"
hdiutil create -quiet -ov -volname "Voxtant $VERSION" -srcfolder "$STAGING" -format UDZO "$OUTPUT/$NAME.dmg"
(cd "$OUTPUT" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)
printf '\nRelease artifacts: %s/%s\n' "$PWD" "$OUTPUT"
