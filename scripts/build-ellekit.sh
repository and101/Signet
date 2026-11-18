#!/bin/sh
# Builds ElleKit from source and packages it as CydiaSubstrate.framework for tweak injection.
# Output: Signet/Resources/ElleKit.zip (bundled in the app) and Vendor/ElleKit/LICENSE.
# The signer extracts the framework into an app's Frameworks folder when an injected tweak links Substrate.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD

REPO=https://github.com/tealbathingsuit/ellekit.git
COMMIT=1017a0d09606ea49ba8bc4d6cccc530d372e640e

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone -q "$REPO" "$WORK/src"
git -C "$WORK/src" checkout -q "$COMMIT"

# ElleKit's project targets iOS 11, which current Xcode no longer accepts.
xcodebuild -project "$WORK/src/ellekit.xcodeproj" -scheme ellekit -configuration Release \
  -destination 'generic/platform=iOS' BUILD_DIR="$WORK/build/" IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet build

FW="$WORK/out/CydiaSubstrate.framework"
mkdir -p "$FW"
cp "$WORK/build/Release-iphoneos/libellekit.dylib" "$FW/CydiaSubstrate"
install_name_tool -id @rpath/CydiaSubstrate.framework/CydiaSubstrate "$FW/CydiaSubstrate" 2>/dev/null
codesign -f -s - "$FW/CydiaSubstrate" 2>/dev/null
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CydiaSubstrate</string>
  <key>CFBundleIdentifier</key><string>com.evilpenguin.ellekit</string>
  <key>CFBundleName</key><string>CydiaSubstrate</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

rm -f Signet/Resources/ElleKit.zip
(cd "$WORK/out" && zip -qry -X "$ROOT/Signet/Resources/ElleKit.zip" CydiaSubstrate.framework)
mkdir -p Vendor/ElleKit
cp "$WORK/src/LICENSE" Vendor/ElleKit/LICENSE
echo "ElleKit $COMMIT packaged to Signet/Resources/ElleKit.zip"
