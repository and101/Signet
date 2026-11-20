# Vendored ZIPFoundation

Source: https://github.com/weichsel/ZIPFoundation, tag `0.9.20` (commit `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`),
MIT licensed — see `LICENSE`. Only `Sources/ZIPFoundation` and `LICENSE` were copied; `Package.swift` is trimmed to
Apple platforms without the upstream test target. Local patches are marked `PATCH(signet)`.

Signet opens archives it doesn't control (IPAs, tweak .zips, backups). 0.9.20 adds offsets and sizes read from the
archive without overflow checks, and its `<= .max` guards compare against `UInt64.max`, so they never fail, before
converting to `off_t`/`Int64`. A crafted archive could therefore trap and end the app. Upstream `main` has a partial
fix for one site but no release.

1. `Archive.swift` — `checkedSum` adds archive values with overflow checks and requires the result to fit an
   `off_t`. `makeIterator` uses it for the next central-directory index and the data-descriptor position; an
   impossible value ends iteration (Signet's `ArchiveBudget.validate` compares the count read with the declared
   count, so the archive is then reported as damaged).
2. `Entry.swift` — `dataOffset` and `localSize` use `checkedSum` and return `UInt64.max` on overflow, which the
   readers below reject.
3. `Data+Serialization.swift` — `readStruct` refuses offsets past `Int64.max` instead of trapping in `off_t(_:)`.
4. `Archive+Reading.swift` — `extract` refuses a data offset past `Int64.max` (`invalidLocalHeaderDataOffset`).
5. `Archive+Helpers.swift` — `readUncompressed`/`readCompressed` refuse sizes past `Int64.max` (`invalidEntrySize`).

6. `Archive.swift` — the end-of-central-directory search stops after 22 + 65,535 bytes (the record plus the largest
   comment). It used to seek and read one byte at a time back to the start of the file, so a large download missing
   its end took a very long time to fail.
7. `Archive.swift`, `Entry.swift` — public `Archive.declaredEntryCount` and `Entry.localHeaderCompressedSize`, so
   Signet can check an archive was read completely and bound symlink reads without reflection.

8. `Entry.swift` — `effectiveCompressedSize`, `effectiveUncompressedSize` and `effectiveRelativeOffsetOfLocalHeader`
   take the ZIP64 value whenever the classic field is `0xFFFFFFFF` (the case in which the extra field carries it),
   including a ZIP64 value of 0. Upstream ignored zero, kept the sentinel, and so looked for a first entry at offset
   4 GiB and sized an empty file at 4 GiB.

9. `Archive.swift` — `makeIterator` reads a ZIP64 (64-bit) data descriptor only when the entry's local header has a
   ZIP64 extra field, as APPNOTE 4.3.9 specifies; otherwise the 32-bit one. Upstream chose by the central record, so
   a streamed entry whose central record needed ZIP64 only for its offset (past 4 GiB) had its 32-bit descriptor
   misread and its sizes became garbage.

Writing paths are unchanged: Signet only writes archives from its own files.
