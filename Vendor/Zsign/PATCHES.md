# Vendored zsign

Source: https://github.com/khcrysalis/Zsign-Package (branch `package`, commit `c4ba9da4283031c07efa03bce42c4b8602d22e73`), MIT licensed — see `LICENSE`.
Only `src/`, `swift/`, `Package.swift` and `LICENSE` were copied. Local patches are marked `PATCH(signet)`:

1. `src/bundle.cpp` — `SignFolder` wrote `embedded.mobileprovision` only when `bRemoveProvision` was **true**, and the
   CodeResources pass then deleted it for the same flag, so a profile was never embedded. The condition is now
   `!bRemoveProvision`. Without an embedded profile iOS refuses to install development/ad-hoc signed apps.
2. `swift/zsign.mm` — `zsign()` invoked its completion block without a nil check (crash when none is passed).
3. `src/archo.cpp` — expand wildcard application identifiers and matching keychain access groups in the
   executable's XML and DER entitlements using that executable's concrete bundle ID.
4. `src/bundle.cpp` — `SignNode` ignored the result of signing loose Mach-O files and, on iOS, returned success when
   the app's main executable couldn't be parsed. Both now fail signing (nested bundles without a readable
   executable are still skipped), so a damaged app no longer produces a "successful" IPA. The loose-file pass also
   skips each bundle's own executable, which it used to sign first without a bundle ID (failing silently for
   wildcard profiles) before signing it properly.
5. `src/macho.cpp` — `Free()` cleared the mapping pointer before `CloseFile()` could unmap it, so every inspection
   (`ListDylibs`, `InjectDyLib`, …) leaked a mapping of the binary, keeping its disk space reserved after deletion
   until the app quit. `Free()` now unmaps first, `CloseFile()` forgets the mapping after unmapping, and the
   destructor and `OpenFile()` release any mapping still open.

6. `src/bundle.cpp` — when renaming an app, extension and Watch app bundle IDs were rewritten with a substring
   replace, so renaming `com.foo` also changed `com.foobar.ext`. Only the old ID itself and IDs under it
   (`com.foo.widget`) are renamed now.

7. `swift/zsign.mm` — sign with a SHA-256 code directory only, not SHA-1 + SHA-256. Upstream made this the
   default (`fe1750d`); dual hashes are only needed for iOS 10 and earlier.

8. `swift/zsign.mm` — `checkCert` only knew the WWDR G1 and G3 issuers. It now uses the ones signing accepts: the
   p12's own CA chain or any embedded intermediate. (`certcheck.cpp` isn't part of the package.)
9. `src/archo.cpp` — `BuildCodeSignature` ignored failures building the CMS signature and the DER entitlements, so an
   app with no signature counted as signed. Both now fail signing.
10. `src/signing.cpp` — DER entitlements: integers were written with their value as the length (and 0 appended 512 MB),
    and dates, decimals and data hit an assert. Integers are encoded properly; the others fail signing.
11. `src/archo.cpp` — patch 3 added an integer 0 `keychain-access-groups` to wildcard entitlements without that key.

## Upstream fixes

Picked from https://github.com/zhlynn/zsign (`master`), which the package branch hasn't merged:

- `a98b1ce` — signatures that pass macOS `codesign --verify`.
- `fe1750d` — DER entitlements in Apple's form (versioned wrapper, sorted keys, `true` as `0xff`). The CLI's
  SHA-256 default doesn't reach the package; see patch 7.
- `6c1870f` — support WWDR G2–G8 issuers and prefer the p12's own CA chain.
- `57e6463` — check that the p12's CA chain issued the leaf and pick a matching root.

The package branch's `src/openssl.h` lacked the G2, G4–G8 and RootCA G3 declarations and `m_caCerts`; they were
added by hand when applying these.

`SignetTests/SigningPipelineTests` cover patch 1: embedding by default and omitting when requested.
