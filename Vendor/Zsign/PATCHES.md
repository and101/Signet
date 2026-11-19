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

`SignetTests/SigningPipelineTests` cover both: embedding by default and omitting when requested.
