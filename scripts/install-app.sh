#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SOURCE="dist/Voxtant.app"
DESTINATION="$HOME/Applications/Voxtant.app"
test -f "$SOURCE/Contents/MacOS/Voxtant"
if [ -e "$DESTINATION" ]; then
    ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")
    test "$ID" = "local.lecturetranslate.demo" || { echo "Another application occupies $DESTINATION" >&2; exit 1; }
    echo "Voxtant is already installed. Quit it and replace the app from the release disk image." >&2
    exit 1
fi
mkdir -p "$HOME/Applications"
ditto "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
printf '\nInstalled: %s\n' "$DESTINATION"
