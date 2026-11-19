#!/bin/sh
# Downloads a pinned prebuilt idevice (MIT) xcframework, used for direct install.
# Output: Vendor/IDevice/IDevice.xcframework (device and simulator slices only; not committed) and
# Vendor/IDevice/LICENSE. idevice talks to the iPhone's own lockdownd, AFC and installation_proxy.
set -eu
cd "$(dirname "$0")/.."

VERSION=v0.1.68
SHA256=c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7
URL=https://github.com/jkcoxson/idevice/releases/download/$VERSION/idevice-xcframework-$VERSION.zip
OUT=Vendor/IDevice

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "$URL" -o "$WORK/idevice.zip"
echo "$SHA256  $WORK/idevice.zip" | shasum -a 256 -c - >/dev/null
unzip -q "$WORK/idevice.zip" -d "$WORK/x"

FW="$WORK/x/swift/IDevice.xcframework"
# macOS and Mac Catalyst slices aren't needed and are most of the download.
rm -rf "$FW/macos-arm64_x86_64" "$FW/ios-arm64_x86_64-maccatalyst"
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$FW/Info.plist" >/dev/null
python3 - "$FW/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f: info = plistlib.load(f)
info['AvailableLibraries'] = [lib for lib in info['AvailableLibraries']
                              if lib.get('SupportedPlatformVariant') != 'maccatalyst' and lib['SupportedPlatform'] == 'ios']
with open(path, 'wb') as f: plistlib.dump(info, f)
PY

rm -rf "$OUT/IDevice.xcframework"
mkdir -p "$OUT"
mv "$FW" "$OUT/"
curl -fsSL "https://raw.githubusercontent.com/jkcoxson/idevice/$VERSION/LICENSE.txt" -o "$OUT/LICENSE"
echo "idevice $VERSION → $OUT"
