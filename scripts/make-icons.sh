#!/bin/sh
# Regenerates assets/icon.svg and the AppIcon set (light, dark, tinted). Needs rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."
SET=Signet/Resources/Assets.xcassets/AppIcon.appiconset
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -O scripts/flatten.swift -o "$WORK/flatten"
python3 scripts/generate-icon.py rounded > assets/icon.svg
for mode in square dark tinted; do
  python3 scripts/generate-icon.py "$mode" > "$WORK/$mode.svg"
  rsvg-convert -w 1024 -h 1024 "$WORK/$mode.svg" -o "$WORK/$mode.png"
done
"$WORK/flatten" "$WORK/square.png" "$SET/icon-1024.png"
"$WORK/flatten" "$WORK/dark.png" "$SET/icon-1024-dark.png"
"$WORK/flatten" "$WORK/tinted.png" "$SET/icon-1024-tinted.png"
echo "Icons updated."
