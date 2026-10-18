#!/bin/zsh
# Builds "File Sync.app" in the repo root.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="File Sync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FileSync "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"

TMP=$(mktemp -d)
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
swift Support/icon.swift "$TMP/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

codesign --force -s - "$APP"
echo "Built $APP"
