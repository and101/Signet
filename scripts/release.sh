#!/bin/sh
# Builds an unsigned build/Signet.ipa and updates docs/source.json (the AltStore-style source served by GitHub
# Pages) for the version in project.yml, with docs/release-notes/<version>.md as its release notes. Then commit docs/,
# push, and attach build/Signet.ipa to a GitHub release (the script prints the command).
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml)
REPO=and101/Signet
# Release notes for this version, shown as "What's New" in sideloading apps and used for the GitHub release.
NOTES="docs/release-notes/$VERSION.md"
[ -f "$NOTES" ] || { echo "Write $NOTES first." >&2; exit 1; }
DERIVED=$(mktemp -d)
STAGE=$(mktemp -d)
trap 'rm -rf "$DERIVED" "$STAGE"' EXIT

[ -d Vendor/IDevice/IDevice.xcframework ] || ./scripts/fetch-idevice.sh
xcodegen generate >/dev/null
xcodebuild build -project Signet.xcodeproj -scheme Signet -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet

mkdir -p build "$STAGE/Payload"
ditto "$DERIVED/Build/Products/Release-iphoneos/Signet.app" "$STAGE/Payload/Signet.app"
rm -f build/Signet.ipa
(cd "$STAGE" && zip -qry -X "$OLDPWD/build/Signet.ipa" Payload)
SIZE=$(stat -f %z build/Signet.ipa)

mkdir -p docs
sips -Z 512 Signet/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png --out docs/icon.png >/dev/null

python3 -I - "$VERSION" "$BUILD" "$SIZE" "$REPO" "$NOTES" > docs/source.json <<'EOF'
import json, re, sys, datetime
version, build, size, repo, notes_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
# Sideloading apps show plain text, so drop the Markdown emphasis.
notes = re.sub(r"\*\*(.+?)\*\*", r"\1", open(notes_path).read()).strip()
owner, name = repo.split("/")
pages = f"https://{owner}.github.io/{name}"
description = ("Sign, customise and install apps on your iPhone with your own certificate. Inject tweaks, "
               "install directly without a computer, track GitHub releases, back up your setup and update Signet "
               "from Signet.")
source = {
    "name": "Signet",
    "identifier": "ember.wax.signet.source",
    "subtitle": "On-device app signer",
    "description": description,
    "iconURL": f"{pages}/icon.png",
    "website": f"https://github.com/{repo}",
    "tintColor": "#C8382A",
    "apps": [{
        "name": "Signet",
        "bundleIdentifier": "ember.wax.signet",
        "developerName": owner,
        "subtitle": "Sign and install apps on your iPhone",
        "localizedDescription": description,
        "iconURL": f"{pages}/icon.png",
        "tintColor": "#C8382A",
        "category": "utilities",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.date.today().isoformat(),
            "localizedDescription": notes,
            "size": size,
            "downloadURL": f"https://github.com/{repo}/releases/download/v{version}/Signet.ipa",
            "minOSVersion": "17.0",
        }],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}
print(json.dumps(source, indent=2))
EOF

echo "Signet $VERSION ($BUILD): build/Signet.ipa, $SIZE bytes. docs/source.json updated."
echo "Then: gh release create v$VERSION build/Signet.ipa --title \"Signet $VERSION\" --notes-file $NOTES"
