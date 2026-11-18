#!/bin/sh
# Builds an unsigned build/Signet.ipa and updates docs/source.json (the AltStore-style source served by GitHub
# Pages) for the version in project.yml. Then: commit docs/, push, and attach build/Signet.ipa to a GitHub release
# tagged v<version>, e.g. `gh release create v1.0 build/Signet.ipa`.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml)
REPO=and101/Signet
DERIVED=$(mktemp -d)
STAGE=$(mktemp -d)
trap 'rm -rf "$DERIVED" "$STAGE"' EXIT

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

python3 -I - "$VERSION" "$BUILD" "$SIZE" "$REPO" > docs/source.json <<'EOF'
import json, sys, datetime
version, build, size, repo = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
owner, name = repo.split("/")
pages = f"https://{owner}.github.io/{name}"
description = ("Sign IPAs with your own certificate, customise them, inject tweaks and install them, "
               "all on your iPhone. Track GitHub releases, back up your setup, and update Signet with Signet.")
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

echo "Signet $VERSION ($BUILD): build/Signet.ipa, $SIZE bytes; docs/source.json updated."
