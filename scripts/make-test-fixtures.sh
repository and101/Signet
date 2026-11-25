#!/bin/sh
# Generates throwaway signing fixtures for the unit tests: a "developer" certificate issued by its own small CA,
# a CMS-signed provisioning profile for it, and a small IPA. Nothing here is a real Apple identity.
set -eu
cd "$(dirname "$0")/.."
OUT=SignetTests/Fixtures
OPENSSL=${OPENSSL:-$(command -v /opt/homebrew/opt/openssl@3/bin/openssl || command -v openssl)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# Root, intermediate and leaf, as Apple issues them: signing needs the leaf's issuer, which the p12 carries.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Fixture Root" \
  -keyout "$WORK/root.key" -out "$WORK/root.pem" 2>/dev/null
"$OPENSSL" req -newkey rsa:2048 -nodes -subj "/CN=Fixture Intermediate" \
  -keyout "$WORK/ca.key" -out "$WORK/ca.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\nsubjectKeyIdentifier=hash\n' > "$WORK/ca.ext"
"$OPENSSL" x509 -req -in "$WORK/ca.csr" -CA "$WORK/root.pem" -CAkey "$WORK/root.key" -CAcreateserial \
  -days 3650 -extfile "$WORK/ca.ext" -out "$WORK/ca.pem" 2>/dev/null
"$OPENSSL" req -newkey rsa:2048 -nodes -subj "/CN=Apple Development: Fixture (TESTTEAM01)/OU=TESTTEAM01/O=Fixture/C=US" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > "$WORK/cert.ext"
"$OPENSSL" x509 -req -in "$WORK/cert.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial \
  -days 3650 -extfile "$WORK/cert.ext" -out "$WORK/cert.pem" 2>/dev/null
cat "$WORK/ca.pem" "$WORK/root.pem" > "$WORK/chain.pem"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -certfile "$WORK/chain.pem" \
  -passout pass:fixture -out "$OUT/test.p12"
# The same identity without its issuer, which can't be signed with.
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass:fixture -out "$OUT/test-nochain.p12"

CERT_B64=$("$OPENSSL" x509 -in "$WORK/cert.pem" -outform DER | base64 | tr -d '\n')
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LATER=$(date -u -v+3650d +%Y-%m-%dT%H:%M:%SZ)
cat > "$WORK/profile.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key><string>Fixture Wildcard</string>
  <key>TeamName</key><string>Fixture Team</string>
  <key>TeamIdentifier</key><array><string>TESTTEAM01</string></array>
  <key>CreationDate</key><date>$NOW</date>
  <key>ExpirationDate</key><date>$LATER</date>
  <key>ProvisionedDevices</key><array><string>00008110-000000000000001E</string></array>
  <key>DeveloperCertificates</key><array><data>$CERT_B64</data></array>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key><string>TESTTEAM01.*</string>
    <key>com.apple.developer.team-identifier</key><string>TESTTEAM01</string>
    <key>get-task-allow</key><true/>
    <key>keychain-access-groups</key><array><string>TESTTEAM01.*</string></array>
  </dict>
</dict>
</plist>
PLIST
"$OPENSSL" cms -sign -nodetach -binary -outform DER -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" \
  -in "$WORK/profile.plist" -out "$OUT/test.mobileprovision"
sed 's|<string>TESTTEAM01\.\*</string>|<string>TESTTEAM01.com.example.*</string>|' "$WORK/profile.plist" > "$WORK/prefixed-profile.plist"
"$OPENSSL" cms -sign -nodetach -binary -outform DER -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" \
  -in "$WORK/prefixed-profile.plist" -out "$OUT/test-prefixed.mobileprovision"
sed 's|<string>TESTTEAM01\.\*</string>|<string>TESTTEAM01.com.example.exact</string>|' "$WORK/profile.plist" > "$WORK/exact-profile.plist"
"$OPENSSL" cms -sign -nodetach -binary -outform DER -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" \
  -in "$WORK/exact-profile.plist" -out "$OUT/test-exact.mobileprovision"

# TLS identity for the install-server test (CN=localhost).
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 800 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" -keyout "$OUT/server.pem" -out "$OUT/server.crt" 2>/dev/null

# A minimal app bundle: Info.plist, an icon, and a tiny arm64 iOS executable.
APP="$WORK/Payload/Fixture.app"
mkdir -p "$APP"
printf 'int main(void){return 0;}\n' > "$WORK/main.c"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 "$WORK/main.c" -o "$APP/Fixture"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Fixture</string>
  <key>CFBundleIdentifier</key><string>com.example.fixture</string>
  <key>CFBundleName</key><string>Fixture</string>
  <key>CFBundleDisplayName</key><string>Fixture App</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
  <key>CFBundleVersion</key><string>42</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>MinimumOSVersion</key><string>15.0</string>
  <key>UISupportedDevices</key><array><string>iPhone14,2</string></array>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>fixture</string></array></dict></array>
  <key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array></dict></dict>
</dict>
</plist>
PLIST
sips -z 120 120 Signet/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png --out "$APP/AppIcon60x60@2x.png" >/dev/null
# A tweak-style dylib that links CydiaSubstrate by its jailbreak path, to exercise injection and path fixing.
printf 'void fixture_tweak(void){}\n' > "$WORK/tweak.c"
mkdir -p "$WORK/Substrate"
printf 'void MSHookFunction(void){}\n' > "$WORK/substrate.c"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -dynamiclib "$WORK/substrate.c" \
  -install_name /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate -o "$WORK/Substrate/libsubstrate.dylib"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -dynamiclib "$WORK/tweak.c" \
  "$WORK/Substrate/libsubstrate.dylib" -install_name @rpath/FixtureTweak.dylib -o "$OUT/FixtureTweak.dylib"

# A framework whose binary is read-only, as in some real IPAs (e.g. OpenSSL.framework in this app's own build).
FW="$APP/Frameworks/Helper.framework"
mkdir -p "$FW"
printf 'void helper(void){}\n' > "$WORK/fwhelper.c"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -dynamiclib "$WORK/fwhelper.c" \
  -install_name @rpath/Helper.framework/Helper -o "$FW/Helper"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Helper</string><key>CFBundleIdentifier</key><string>com.example.helper</string><key>CFBundlePackageType</key><string>FMWK</string></dict></plist>\n' > "$FW/Info.plist"
chmod 555 "$FW/Helper"

# Give the app its own entitlements from another team, for the entitlement-merge test.
cat > "$WORK/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key><string>OLDTEAM001.com.example.fixture</string>
  <key>com.apple.developer.team-identifier</key><string>OLDTEAM001</string>
  <key>get-task-allow</key><false/>
  <key>keychain-access-groups</key>
  <array><string>OLDTEAM001.com.example.fixture</string><string>OLDTEAM001.com.example.shared</string></array>
  <key>com.apple.security.application-groups</key><array><string>group.com.example.fixture</string></array>
</dict>
</plist>
PLIST
codesign -f -s - --entitlements "$WORK/app.entitlements" "$APP/Fixture" 2>/dev/null

# A rootless tweak package: the tweak links Substrate by a short jailbreak path (so rewriting it to
# @rpath must grow the load command) and a helper library from the same package. Also ships a filter
# plist and a resource bundle.
DEB="$WORK/deb"
JB="$DEB/data/var/jb"
mkdir -p "$JB/Library/MobileSubstrate/DynamicLibraries" "$JB/usr/lib" \
  "$JB/Library/Application Support/DebTweak/DebTweak.bundle"
printf 'void deb_helper(void){}\n' > "$WORK/helper.c"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -dynamiclib "$WORK/helper.c" \
  -install_name /var/jb/usr/lib/libdebhelper.dylib -o "$JB/usr/lib/libdebhelper.dylib"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -dynamiclib "$WORK/substrate.c" \
  -install_name /usr/lib/libsubstrate.dylib -o "$WORK/Substrate/libsubstrate-short.dylib"
printf 'void deb_tweak(void){}\n' > "$WORK/debtweak.c"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -dynamiclib "$WORK/debtweak.c" \
  "$WORK/Substrate/libsubstrate-short.dylib" "$JB/usr/lib/libdebhelper.dylib" -install_name @rpath/DebTweak.dylib \
  -o "$JB/Library/MobileSubstrate/DynamicLibraries/DebTweak.dylib"
printf '{ Filter = { Bundles = ( "com.example.fixture" ); }; }\n' > "$JB/Library/MobileSubstrate/DynamicLibraries/DebTweak.plist"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.debtweak.resources</string></dict></plist>\n' \
  > "$JB/Library/Application Support/DebTweak/DebTweak.bundle/Info.plist"
echo 2.0 > "$DEB/debian-binary"
printf 'Package: com.example.debtweak\nVersion: 1.0\nArchitecture: iphoneos-arm64\n' > "$DEB/control"
(cd "$DEB" && COPYFILE_DISABLE=1 tar --no-mac-metadata --format ustar -czf control.tar.gz control)
(cd "$DEB/data" && COPYFILE_DISABLE=1 tar --no-mac-metadata --format ustar -cJf ../data.tar.xz .)
# Written by hand: macOS ar adds a symbol table and BSD long names that dpkg-deb never produces.
ar_member() {
  size=$(wc -c < "$DEB/$1" | tr -d ' ')
  printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$1" 0 0 0 100644 "$size"
  cat "$DEB/$1"
  if [ $((size % 2)) -eq 1 ]; then printf '\n'; fi
}
{ printf '!<arch>\n'; ar_member debian-binary; ar_member control.tar.gz; ar_member data.tar.xz; } > "$OUT/DebTweak.deb"

rm -f "$OUT/Fixture.ipa"
(cd "$WORK" && zip -qry "$OLDPWD/$OUT/Fixture.ipa" Payload)
echo "Fixtures written to $OUT"
