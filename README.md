<img src="assets/icon.svg" width="64" height="64" alt="">

# Signet

Sign, customise and install iOS apps right on your iPhone, with your own certificate.

## Install

Signet needs to be signed before it can sign anything, so the first install uses another tool. Requires iOS 17 or
later.

- **From a sideloading app.** Add this source in AltStore, SideStore, Feather, Ksign or ESign, then install Signet:

  ```
  https://and101.github.io/Signet/source.json
  ```

- **From a computer.** Download `Signet.ipa` from the [latest release](https://github.com/and101/Signet/releases/latest)
  and install it with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io). With a free Apple ID
  the app expires after 7 days. A paid developer account lasts a year.
- **With your own certificate.** Sign `Signet.ipa` with your `.p12` and provisioning profile in any signer.

### Updates

In Signet, go to **Sources → + → Track GitHub Repo** and enter `and101/Signet`. New versions get an **Update**
badge. Download one, sign it and install it over the current Signet, which closes while it installs. Signet fills in
its own bundle ID for this repo, so your data carries over.

Switching to a certificate with a different bundle ID makes iOS treat Signet as a new app. Back up first in
**Settings → Back Up…** and restore in the new copy.

## Features

- **Certificates.** Import `.p12` and provisioning profile pairs. See expiry, devices and entitlements, and check
  for revocation. Passwords stay in the keychain.
- **Library.** Import IPAs from Files, other apps, a URL, a source or a GitHub release.
- **Signing.** Change the name, bundle ID, version, minimum iOS and icon. Remove device limits, URL schemes,
  extensions or the Watch app, enable file sharing, and merge the app's entitlements with your profile's. Apps keep
  their bundle ID unless you change it.
- **PPQ protection.** For profiles that have Apple check apps at launch, Signet adds a short suffix to bundle IDs
  so they never match an App Store app.
- **Tweaks.** Inject `.dylib`, `.deb` and zipped `.framework` files. Jailbreak paths are fixed and ElleKit is added
  when a tweak needs it.
- **Install.** Install signed apps over the air from the phone, or share the IPA.
- **Sources.** Browse AltStore-compatible sources.
- **GitHub releases.** Track a repo to see new IPAs, download them automatically, and set a bundle ID and
  certificate for its apps.
- **Backup.** Save certificates, sources, repos and settings to one file. Certificate passwords are encrypted with
  a backup password.
- **Links.** `signet://source?url=…` adds a source and `signet://install?url=…` downloads an IPA.

Only sign apps you have the right to use, with certificates you own.

## How installs work

iOS only installs apps over the air from trusted HTTPS, and not from `127.0.0.1`. Signet serves the app from a
server inside itself and links to it as `local.backloop.dev`, a public name that points back to the phone.

For HTTPS, Signet creates its own certificate authority and deletes its private key straight after use. Install it
once in **Settings → Install Certificate**. Without the key, it can't vouch for any other site.

If installs fail:

- Ad blockers or DNS filters may block `local.backloop.dev`. Allow it.
- Stay in Signet until the transfer finishes.
- If an app won't open, trust the developer in **Settings → General → VPN & Device Management**. Development and
  ad hoc profiles also need your device in the profile.

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Signet.xcodeproj
```

Set your team under **Signing & Capabilities** and run on your device.

**Tests.** Create the test fixtures once, then run the suite:

```sh
./scripts/make-test-fixtures.sh
xcodebuild test -project Signet.xcodeproj -scheme Signet -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

**Releases.** Set the version in `project.yml` and run `./scripts/release.sh`. It builds an unsigned
`build/Signet.ipa` and updates the source in `docs/`. Commit, push, then attach the IPA to a release:

```sh
gh release create v<version> build/Signet.ipa --title "Signet <version>"
```

## Licence

Signet is released under the [MIT License](LICENSE). It includes
[zsign](https://github.com/khcrysalis/Zsign-Package) (MIT, patches in `Vendor/Zsign/PATCHES.md`) and
[ElleKit](https://github.com/tealbathingsuit/ellekit) (BSD-3-Clause), and uses OpenSSL, SwiftNIO,
swift-certificates, ZIPFoundation and SWCompression under their own licences.
