import Foundation
import ZIPFoundation

/// Limits are deliberately generous for large games and backups; tweak tar data is held in memory.
struct ArchiveBudget {
    var remaining: UInt64
    let perEntry: UInt64
    let entries: Int
    static let ipa = ArchiveBudget(remaining: 16 * 1024 * 1024 * 1024, perEntry: 8 * 1024 * 1024 * 1024, entries: 200_000)
    static let backup = ArchiveBudget(remaining: 32 * 1024 * 1024 * 1024, perEntry: 8 * 1024 * 1024 * 1024, entries: 400_000)
    static let manifestLimit: UInt64 = 16 * 1024 * 1024

    mutating func consume(_ count: UInt64) throws {
        guard count <= remaining else { throw AppError("The archive exceeds the extraction size limit.") }
        remaining -= count
    }

    /// Returns the total declared size, for the free-space check.
    @discardableResult
    func validate(_ archive: Archive) throws -> UInt64 {
        var budget = self
        var count = 0
        for entry in archive {
            count += 1
            if entry.type == .symlink { try Self.checkSymlinkSize(entry) }
            // Folders hold no data. Some ZIP64 writers leave their size as 0xFFFFFFFF, so it isn't counted.
            let size = entry.type == .directory ? 0 : entry.uncompressedSize
            guard count <= entries, size <= perEntry else {
                throw AppError("The archive has too many files or an oversized entry.")
            }
            try budget.consume(size)
        }
        // ZIPFoundation's iterator also ends when it can't read an entry, so a damaged archive would look complete.
        guard archive.declaredEntryCount == UInt64(count) else { throw AppError("The archive is damaged.") }
        return remaining - budget.remaining
    }


    /// Fails before extracting rather than filling the disk partway through. Skipped if capacity can't be read.
    static func checkFreeSpace(needed: UInt64, at folder: URL) throws {
        let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        try checkFreeSpace(needed: needed, available: available)
    }

    static func checkFreeSpace(needed: UInt64, available: Int64?) throws {
        // Some volumes report 0 when the figure isn't available; a really full disk fails while writing anyway.
        guard let available, available > 0 else { return }
        // The extracted size plus 10% headroom.
        let required = needed.addingReportingOverflow(needed / 10)
        guard !required.overflow, UInt64(available) >= required.partialValue else {
            let format = ByteCountFormatter()
            throw AppError("Not enough free space. Needs about \(format.string(fromByteCount: Int64(clamping: required.partialValue))), \(format.string(fromByteCount: available)) free.")
        }
    }

    /// Files are streamed with an actual-byte budget, even if ZIP size metadata is dishonest.
    mutating func extract(_ entry: Entry, from archive: Archive, to url: URL, root: URL) throws {
        if entry.type == .symlink { try Self.checkSymlinkSize(entry) }
        let fm = FileManager.default
        try Self.checkContained(url, in: root)
        if entry.type == .directory {
            // Created here rather than by ZIPFoundation, which would apply the archived mode at once: a read-only
            // folder (0555) would then refuse the files that follow it. Folder modes don't matter to an app.
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return
        }
        if entry.type != .file {
            // Preserve ZIPFoundation's symlink containment and file attribute handling.
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try consume(entry.uncompressedSize)
            let checksum = try archive.extract(entry, to: url)
            guard checksum == entry.checksum else { throw AppError("The archive is damaged.") }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // attributesOfItem doesn't follow links, so an extracted link can't be written through.
        guard (try? fm.attributesOfItem(atPath: url.path)) == nil, fm.createFile(atPath: url.path, contents: nil) else {
            throw AppError("The archive contains a duplicate or unwritable file.")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written: UInt64 = 0
        let checksum = try archive.extract(entry) { data in
            // The declared size is what the free-space check reserved, so a dishonest entry can't write past it.
            guard UInt64(data.count) <= entry.uncompressedSize - written else { throw AppError("The archive is damaged.") }
            guard UInt64(data.count) <= perEntry - written else { throw AppError("An archive entry exceeds the extraction size limit.") }
            try consume(UInt64(data.count))
            written += UInt64(data.count)
            try handle.write(contentsOf: data)
        }
        guard checksum == entry.checksum, written == entry.uncompressedSize else { throw AppError("The archive is damaged.") }
        try fm.setAttributes(entry.fileAttributes, ofItemAtPath: url.path)
    }

    static func unzip(_ source: URL, to destination: URL, limits: ArchiveBudget = .ipa) throws {
        let archive = try Archive(url: source, accessMode: .read)
        let needed = try limits.validate(archive)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try checkFreeSpace(needed: needed, at: destination)
        var budget = limits
        for entry in archive {
            try budget.extract(entry, from: archive, to: destination.appendingPathComponent(entry.path), root: destination)
        }
    }

    /// Longest symlink target accepted; real bundle links (Versions/Current and the like) are far shorter.
    static let symlinkLimit: UInt64 = 4096

    /// ZIPFoundation reads a symlink's target using the size in its local header, which the central directory
    /// (and so `Entry.compressedSize`) doesn't vouch for. Bound both before anything is read.
    /// (`localHeaderCompressedSize` is a Signet patch to the vendored ZIPFoundation.)
    static func checkSymlinkSize(_ entry: Entry) throws {
        let tooLarge = AppError("The archive contains an oversized symbolic link.")
        guard entry.compressedSize <= symlinkLimit, entry.uncompressedSize <= symlinkLimit else { throw tooLarge }
        let size = entry.localHeaderCompressedSize
        guard size <= symlinkLimit else { throw tooLarge }
        // ZIPFoundation reads exactly the local size, so it must match the declared size the budget charges.
        guard size == entry.uncompressedSize else { throw AppError("The archive is damaged.") }
    }

    /// Checks `url` stays inside `root`: its components below `root` may not step up or sideways, and after
    /// following links already extracted, its nearest existing folder must still be inside `root`.
    /// Nothing is standardised: Foundation drops /private only from paths that exist, so on device a missing file
    /// under /private/var would never match its existing root. Only existing paths are resolved, on both sides.
    static func checkContained(_ url: URL, in root: URL) throws {
        let unsafe = AppError("The archive contains an unsafe path.")
        let base = root.path
        guard url.path.hasPrefix(base + "/") else { throw unsafe }
        let parts = url.path.dropFirst(base.count + 1).split(separator: "/")
        guard !parts.isEmpty, !parts.contains("..") else { throw unsafe }
        let fm = FileManager.default
        let resolvedBase = root.resolvingSymlinksInPath().path
        // Nearest existing ancestor; attributesOfItem doesn't follow links, so a dangling link counts as existing.
        var ancestor = url.deletingLastPathComponent()
        while ancestor.path.count > base.count, (try? fm.attributesOfItem(atPath: ancestor.path)) == nil {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let resolved = ancestor.resolvingSymlinksInPath().path
        guard resolved == resolvedBase || resolved.hasPrefix(resolvedBase + "/") else { throw unsafe }
    }
}
