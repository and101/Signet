#!/bin/sh
# Updates Signet/Resources/Localizable.xcstrings with every string in the app, for translation.
# Xcode does this when building in the IDE; command-line builds extract the strings but don't merge them.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED=$(mktemp -d)
trap 'rm -rf "$DERIVED"' EXIT

[ -d Vendor/IDevice/IDevice.xcframework ] || ./scripts/fetch-idevice.sh
xcodegen generate >/dev/null
xcodebuild build -project Signet.xcodeproj -scheme Signet -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO -quiet

find "$DERIVED/Build/Intermediates.noindex/Signet.build" -name '*.stringsdata' ! -name 'ExtractedAppShortcutsMetadata.stringsdata' \
  > "$DERIVED/stringsdata.txt"
set --
while IFS= read -r file; do set -- "$@" --stringsdata "$file"; done < "$DERIVED/stringsdata.txt"
xcrun xcstringstool sync Signet/Resources/Localizable.xcstrings "$@"
echo "$(xcrun xcstringstool print Signet/Resources/Localizable.xcstrings | grep -c '') strings in Localizable.xcstrings"
