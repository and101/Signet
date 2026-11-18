import Foundation

/// Reads and patches Mach-O headers directly, for what zsign doesn't cover: legacy arm64e slices,
/// load-command rewrites that need more room than the old path had, and reading signed entitlements.
/// Handles thin 64-bit files and fat files (32- and 64-bit fat headers); other files are ignored.
enum MachO {
    private static let fatMagic: UInt32 = 0xcafe_babe
    private static let fatMagic64: UInt32 = 0xcafe_babf
    private static let magic64: UInt32 = 0xfeed_facf
    private static let cpuTypeARM64: UInt32 = 0x0100_000c
    private static let cpuSubtypeARM64E: UInt32 = 2
    private static let cpuSubtypeMask: UInt32 = 0xff00_0000
    private static let cpuSubtypePtrAuthABI: UInt32 = 0x8000_0000

    private static let headerSize = 32
    private static let lcSegment64: UInt32 = 0x19
    private static let lcCodeSignature: UInt32 = 0x1d
    /// LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
    private static let dylibCommands: Set<UInt32> = [0xc, 0x8000_0018, 0x8000_001f, 0x20, 0x8000_0023]

    struct Slice {
        let offset: Int
        let cpuType: UInt32
        let cpuSubtype: UInt32
        /// File offset of this slice's `fat_arch` record; nil for thin files.
        let fatRecord: Int?
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let file = try? BinaryFile(url, writable: false) else { return false }
        return !((try? slices(of: file)) ?? []).isEmpty
    }

    // MARK: - arm64e

    /// Fat binaries built before the versioned arm64e ABI (e.g. old CydiaSubstrate builds) carry an
    /// "arm64e.old" slice that iOS 26's dyld refuses, failing the whole file even though apps load the
    /// arm64 slice. Mark those slices as ABI version 0, in both the slice header and the fat record.
    /// - Returns: true if the file was changed.
    @discardableResult
    static func fixLegacyARM64ESlices(in url: URL) throws -> Bool {
        // Most files need nothing, so look first: app bundles often contain read-only binaries.
        let reader = try BinaryFile(url, writable: false)
        var fixes: [(slice: Slice, subtype: UInt32)] = []
        for slice in try slices(of: reader) where slice.fatRecord != nil {
            guard slice.cpuType == cpuTypeARM64, slice.cpuSubtype & ~cpuSubtypeMask == cpuSubtypeARM64E,
                  try reader.u32(slice.offset) == magic64 else { continue }
            let headerSubtype = try reader.u32(slice.offset + 8)
            let fixed = headerSubtype | cpuSubtypePtrAuthABI
            if fixed != headerSubtype || fixed != slice.cpuSubtype { fixes.append((slice, fixed)) }
        }
        guard !fixes.isEmpty else { return false }

        let file = try BinaryFile(url, writable: true)
        for (slice, subtype) in fixes {
            try file.write(u32: subtype, at: slice.offset + 8)
            try file.write(u32: subtype, at: slice.fatRecord! + 4, bigEndian: true)
        }
        return true
    }

    // MARK: - Load commands

    /// The dylib paths a binary links (load, weak, re-export, lazy and upward), from its preferred slice.
    static func linkedDylibs(of url: URL) throws -> [String] {
        let file = try BinaryFile(url, writable: false)
        guard let slice = preferredSlice(try slices(of: file)) else { return [] }
        return try loadCommands(of: file, slice: slice).compactMap { command in
            dylibCommands.contains(command.type) ? dylibName(in: command.data) : nil
        }
    }

    /// Replaces a linked dylib path in every slice. Grows the load command into the header padding
    /// when the new path is longer, like `install_name_tool -change`.
    /// - Returns: true if the path was found and changed.
    @discardableResult
    static func changeLinkedDylib(in url: URL, from old: String, to new: String) throws -> Bool {
        guard try linkedDylibs(of: url).contains(old) else { return false }
        let file = try BinaryFile(url, writable: true)
        var changed = false
        for slice in try slices(of: file) {
            guard try file.u32(slice.offset) == magic64 else { continue }
            let commands = try loadCommands(of: file, slice: slice)
            guard commands.contains(where: { dylibCommands.contains($0.type) && dylibName(in: $0.data) == old }) else { continue }

            let oldSize = commands.reduce(0) { $0 + $1.data.count }
            var rebuilt = Data()
            for command in commands {
                guard dylibCommands.contains(command.type), dylibName(in: command.data) == old else {
                    rebuilt.append(command.data)
                    continue
                }
                let nameOffset = Int(command.data.u32(8))
                let needed = (nameOffset + new.utf8.count + 1 + 7) & ~7
                let size = max(needed, command.data.count)
                var replacement = Data(command.data.prefix(nameOffset))
                replacement.append(contentsOf: Array(new.utf8))
                replacement.append(Data(count: size - replacement.count))
                replacement.setU32(UInt32(size), at: 4)
                rebuilt.append(replacement)
            }

            let growth = rebuilt.count - oldSize
            if growth > 0 {
                let available = try firstSectionOffset(of: file, slice: slice, commands: commands) - (headerSize + oldSize)
                guard growth <= available else {
                    throw AppError("\(url.lastPathComponent) has no room to rewrite \(old) to \(new).")
                }
            }
            try file.write(rebuilt, at: slice.offset + headerSize)
            try file.write(u32: UInt32(rebuilt.count), at: slice.offset + 20)
            changed = true
        }
        return changed
    }

    // MARK: - Run paths

    private static let lcRPath: UInt32 = 0x8000_001c

    /// The LC_RPATH entries of a binary's preferred slice.
    static func rpaths(of url: URL) throws -> [String] {
        let file = try BinaryFile(url, writable: false)
        guard let slice = preferredSlice(try slices(of: file)) else { return [] }
        return try loadCommands(of: file, slice: slice).compactMap { command in
            guard command.type == lcRPath, command.data.count >= 12 else { return nil }
            let offset = Int(command.data.u32(8))
            guard offset < command.data.count else { return nil }
            return String(decoding: command.data[(command.data.startIndex + offset)...].prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Appends an LC_RPATH to every slice that lacks it, using the padding after the load commands.
    /// - Returns: true if the file was changed.
    @discardableResult
    static func addRPath(_ path: String, to url: URL) throws -> Bool {
        let size = (12 + path.utf8.count + 1 + 7) & ~7
        var command = Data(count: size)
        command.setU32(lcRPath, at: 0)
        command.setU32(UInt32(size), at: 4)
        command.setU32(12, at: 8)
        command.replaceSubrange(12..<(12 + path.utf8.count), with: Array(path.utf8))

        let reader = try BinaryFile(url, writable: false)
        var targets: [(slice: Slice, count: UInt32, size: Int)] = []
        for slice in try slices(of: reader) {
            guard try reader.u32(slice.offset) == magic64 else { continue }
            let commands = try loadCommands(of: reader, slice: slice)
            let existing = commands.contains { $0.type == lcRPath && $0.data.count >= 12
                && String(decoding: $0.data[($0.data.startIndex + Int($0.data.u32(8)))...].prefix { $0 != 0 }, as: UTF8.self) == path }
            if existing { continue }
            let used = commands.reduce(0) { $0 + $1.data.count }
            let available = try firstSectionOffset(of: reader, slice: slice, commands: commands) - (headerSize + used)
            guard size <= available else { throw AppError("\(url.lastPathComponent) has no room to add a run path.") }
            targets.append((slice, UInt32(commands.count), used))
        }
        guard !targets.isEmpty else { return false }
        let file = try BinaryFile(url, writable: true)
        for target in targets {
            try file.write(command, at: target.slice.offset + headerSize + target.size)
            try file.write(u32: target.count + 1, at: target.slice.offset + 16)
            try file.write(u32: UInt32(target.size + size), at: target.slice.offset + 20)
        }
        return true
    }

    // MARK: - SDK version

    /// LC_BUILD_VERSION, and LC_VERSION_MIN_IPHONEOS for binaries built before it existed.
    private static let lcBuildVersion: UInt32 = 0x32
    private static let lcVersionMinIPhoneOS: UInt32 = 0x25

    /// Packs "26.0" or "18.4.1" as Mach-O's xxxx.yy.zz nibbles.
    static func packVersion(_ version: String) -> UInt32? {
        let parts = version.split(separator: ".").map { UInt32($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
        guard numbers[0] <= 0xffff, numbers[1] <= 0xff, numbers[2] <= 0xff else { return nil }
        return numbers[0] << 16 | numbers[1] << 8 | numbers[2]
    }

    static func unpackVersion(_ packed: UInt32) -> String {
        let patch = packed & 0xff
        return "\(packed >> 16).\((packed >> 8) & 0xff)" + (patch == 0 ? "" : ".\(patch)")
    }

    /// The SDK a binary was built against, from its preferred slice, e.g. "18.2".
    static func sdkVersion(of url: URL) throws -> String? {
        let file = try BinaryFile(url, writable: false)
        guard let slice = preferredSlice(try slices(of: file)) else { return nil }
        for command in try loadCommands(of: file, slice: slice) {
            if command.type == lcBuildVersion, command.data.count >= 24 { return unpackVersion(command.data.u32(16)) }
            if command.type == lcVersionMinIPhoneOS, command.data.count >= 16 { return unpackVersion(command.data.u32(12)) }
        }
        return nil
    }

    /// Sets the SDK version in every slice. With `onlyRaise`, slices already built with a newer SDK are left alone.
    /// UIKit picks some behaviour (like iOS 26's Liquid Glass) from the main executable's SDK version.
    /// - Returns: true if the file was changed.
    @discardableResult
    static func setSDKVersion(in url: URL, to version: String, onlyRaise: Bool = true) throws -> Bool {
        guard let packed = packVersion(version) else { throw AppError("\(version) isn't a valid SDK version.") }
        let reader = try BinaryFile(url, writable: false)
        var writes: [Int] = []
        for slice in try slices(of: reader) {
            guard try reader.u32(slice.offset) == magic64 else { continue }
            var cursor = slice.offset + headerSize
            for command in try loadCommands(of: reader, slice: slice) {
                defer { cursor += command.data.count }
                let field: Int
                switch command.type {
                case lcBuildVersion where command.data.count >= 24: field = 16
                case lcVersionMinIPhoneOS where command.data.count >= 16: field = 12
                default: continue
                }
                let current = command.data.u32(field)
                if current == packed || (onlyRaise && current > packed) { continue }
                writes.append(cursor + field)
            }
        }
        guard !writes.isEmpty else { return false }
        let file = try BinaryFile(url, writable: true)
        for offset in writes { try file.write(u32: packed, at: offset) }
        return true
    }

    // MARK: - Entitlements

    /// The entitlements embedded in a binary's code signature, from its preferred slice.
    static func entitlements(of url: URL) throws -> [String: Any]? {
        let file = try BinaryFile(url, writable: false)
        guard let slice = preferredSlice(try slices(of: file)),
              let signature = try loadCommands(of: file, slice: slice).first(where: { $0.type == lcCodeSignature }) else {
            return nil
        }
        let blob = try file.read(at: slice.offset + Int(signature.data.u32(8)), count: Int(signature.data.u32(12)))
        guard blob.count >= 12, blob.u32(0, bigEndian: true) == 0xfade_0cc0 else { return nil }
        let count = Int(blob.u32(8, bigEndian: true))
        for index in 0..<count {
            let entry = 12 + index * 8
            guard entry + 8 <= blob.count else { break }
            guard blob.u32(entry, bigEndian: true) == 5 else { continue }
            let start = Int(blob.u32(entry + 4, bigEndian: true))
            guard start + 8 <= blob.count, blob.u32(start, bigEndian: true) == 0xfade_7171 else { return nil }
            let end = start + Int(blob.u32(start + 4, bigEndian: true))
            guard end <= blob.count, end > start + 8 else { return nil }
            let xml = blob.subdata(in: (blob.startIndex + start + 8)..<(blob.startIndex + end))
            return try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        }
        return nil
    }

    // MARK: - Parsing

    private struct LoadCommand {
        let type: UInt32
        let data: Data
    }

    private static func slices(of file: BinaryFile) throws -> [Slice] {
        guard file.size >= 8 else { return [] }
        let magic = try file.u32(0, bigEndian: true)
        if magic == fatMagic || magic == fatMagic64 {
            let is64 = magic == fatMagic64
            let count = Int(try file.u32(4, bigEndian: true))
            let recordSize = is64 ? 32 : 20
            guard count > 0, count < 32, 8 + count * recordSize <= file.size else { return [] }
            return try (0..<count).compactMap { index in
                let record = 8 + index * recordSize
                let offset = is64 ? Int(try file.u64(record + 8, bigEndian: true)) : Int(try file.u32(record + 8, bigEndian: true))
                guard offset > 0, offset + headerSize <= file.size else { return nil }
                return Slice(offset: offset, cpuType: try file.u32(record, bigEndian: true),
                             cpuSubtype: try file.u32(record + 4, bigEndian: true), fatRecord: record)
            }
        }
        guard try file.u32(0) == magic64, file.size >= headerSize else { return [] }
        return [Slice(offset: 0, cpuType: try file.u32(4), cpuSubtype: try file.u32(8), fatRecord: nil)]
    }

    /// arm64 is what third-party processes run; fall back to any arm64 slice, then the first.
    private static func preferredSlice(_ slices: [Slice]) -> Slice? {
        slices.first { $0.cpuType == cpuTypeARM64 && $0.cpuSubtype & ~cpuSubtypeMask == 0 }
            ?? slices.first { $0.cpuType == cpuTypeARM64 }
            ?? slices.first
    }

    private static func loadCommands(of file: BinaryFile, slice: Slice) throws -> [LoadCommand] {
        guard try file.u32(slice.offset) == magic64 else { return [] }
        let count = Int(try file.u32(slice.offset + 16))
        let size = Int(try file.u32(slice.offset + 20))
        let region = try file.read(at: slice.offset + headerSize, count: size)
        guard region.count == size else { throw AppError("Truncated Mach-O header.") }
        var commands: [LoadCommand] = []
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 8 <= size else { throw AppError("Malformed Mach-O load commands.") }
            let length = Int(region.u32(cursor + 4))
            guard length >= 8, cursor + length <= size else { throw AppError("Malformed Mach-O load commands.") }
            let start = region.startIndex + cursor
            commands.append(LoadCommand(type: region.u32(cursor), data: region.subdata(in: start..<(start + length))))
            cursor += length
        }
        return commands
    }

    private static func dylibName(in command: Data) -> String? {
        guard command.count >= 24 else { return nil }
        let offset = Int(command.u32(8))
        guard offset < command.count else { return nil }
        let bytes = command[(command.startIndex + offset)...].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Where section data starts in a slice; load commands can grow up to this point.
    private static func firstSectionOffset(of file: BinaryFile, slice: Slice, commands: [LoadCommand]) throws -> Int {
        var lowest = Int.max
        for command in commands where command.type == lcSegment64 && command.data.count >= 72 {
            let sections = Int(command.data.u32(64))
            for index in 0..<sections {
                let section = 72 + index * 80
                guard section + 80 <= command.data.count else { break }
                let offset = Int(command.data.u32(section + 48))
                if offset > 0 { lowest = min(lowest, offset) }
            }
        }
        return lowest == .max ? 0 : lowest
    }
}

/// Positioned reads and writes on a file without loading it whole (main executables can be huge).
private final class BinaryFile {
    let size: Int
    private let handle: FileHandle

    init(_ url: URL, writable: Bool) throws {
        if writable { try Self.addOwnerWritePermission(to: url) }
        handle = writable ? try FileHandle(forUpdating: url) : try FileHandle(forReadingFrom: url)
        size = Int(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    /// Binaries copied out of an IPA can be read-only; the copy is ours to patch before signing.
    private static func addOwnerWritePermission(to url: URL) throws {
        let fm = FileManager.default
        let mode = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        guard mode & 0o200 == 0 else { return }
        try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: url.path)
    }

    func read(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= size else { throw AppError("Read past the end of a Mach-O file.") }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    func u32(_ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        try read(at: offset, count: 4).u32(0, bigEndian: bigEndian)
    }

    func u64(_ offset: Int, bigEndian: Bool) throws -> UInt64 {
        let data = try read(at: offset, count: 8)
        let high = UInt64(data.u32(bigEndian ? 0 : 4, bigEndian: bigEndian))
        let low = UInt64(data.u32(bigEndian ? 4 : 0, bigEndian: bigEndian))
        return high << 32 | low
    }

    func write(_ data: Data, at offset: Int) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    func write(u32 value: UInt32, at offset: Int, bigEndian: Bool = false) throws {
        var data = Data(count: 4)
        data.setU32(value, at: 0, bigEndian: bigEndian)
        try write(data, at: offset)
    }
}

private extension Data {
    func u32(_ offset: Int, bigEndian: Bool = false) -> UInt32 {
        let bytes = Array(self[(startIndex + offset)..<(startIndex + offset + 4)])
        return (bigEndian ? bytes : bytes.reversed()).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func setU32(_ value: UInt32, at offset: Int, bigEndian: Bool = false) {
        let ordered = bigEndian ? value.bigEndian : value.littleEndian
        Swift.withUnsafeBytes(of: ordered) { replaceSubrange((startIndex + offset)..<(startIndex + offset + 4), with: $0) }
    }
}
