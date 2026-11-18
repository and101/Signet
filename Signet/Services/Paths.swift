import Foundation

/// On-disk layout. Everything lives in Documents so it's visible in the Files app.
enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let certificates = documents.appendingPathComponent("Certificates", isDirectory: true)
    static let library = documents.appendingPathComponent("Library", isDirectory: true)
    static let server = documents.appendingPathComponent("Server", isDirectory: true)
    static let metadata = documents.appendingPathComponent(".metadata", isDirectory: true)
    static let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Signet", isDirectory: true)

    static func prepare() {
        for url in [certificates, library, server, metadata, temp] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Old copies in the system Inbox, used when another app hands over a file it can't share in place.
    static let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)

    /// Everything the app owns on disk, as iOS counts it under Documents & Data.
    static var containerRoots: [URL] {
        let fm = FileManager.default
        return [documents, fm.temporaryDirectory] + fm.urls(for: .cachesDirectory, in: .userDomainMask)
    }

    /// Removes temporary files. Pass `olderThan` to keep files an import or signing in progress may still use.
    /// Call with no age only at launch, when nothing can be using them yet.
    static func clearTemporaryFiles(olderThan age: TimeInterval? = nil) {
        let fm = FileManager.default
        // iOS may drop a file into the Inbox just before launching us to open it, so never clear brand-new ones there.
        let inboxAge = max(age ?? 0, 10 * 60)
        for (folder, minimumAge) in [(temp, age), (inbox, inboxAge)] {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for item in items where minimumAge.map({ item.isOlder(than: $0) }) ?? true {
                try? fm.removeItem(at: item)
            }
        }
        prepare()
    }

    /// Deletes a file only if it's a temporary copy the app made.
    static func removeIfTemporary(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(temp.standardizedFileURL.path + "/") else { return }
        // Picked files live in their own UUID folder; remove that too.
        let folder = url.deletingLastPathComponent()
        let target = folder.standardizedFileURL == temp.standardizedFileURL ? url : folder
        try? FileManager.default.removeItem(at: target)
    }

    static func newTempDirectory() throws -> URL {
        let url = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension URL {
    /// True when the item hasn't been modified for at least `age` seconds.
    func isOlder(than age: TimeInterval) -> Bool {
        let modified = (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Date().timeIntervalSince(modified) >= age
    }
}

extension FileManager {
    func directorySize(at url: URL) -> Int64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    func fileSize(at url: URL) -> Int64 {
        (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    func replaceItem(at destination: URL, withCopyOf source: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}

/// Reads and writes a Codable value as JSON in the metadata folder.
struct JSONFile<Value: Codable> {
    let url: URL

    init(_ name: String) {
        url = Paths.metadata.appendingPathComponent(name)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The decoded value, or nil when the file doesn't exist. A file that exists but can't be read or decoded is
    /// copied aside first (see `preserveUnreadable`), so the next save can't destroy the only copy.
    func load() -> Value? {
        guard let data = readData() else { return nil }
        if let value = try? JSONDecoder().decode(Value.self, from: data) { return value }
        preserveUnreadable()
        return nil
    }

    /// The raw file, or nil when it doesn't exist. Unreadable files are preserved before returning nil.
    func readData() -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            preserveUnreadable()
            return nil
        }
    }

    /// Copies the current file next to itself as `name.unreadable-<timestamp>.json` and returns the copy.
    @discardableResult
    func preserveUnreadable() -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// Writes the value atomically. Returns false if it couldn't be saved.
    @discardableResult
    func save(_ value: Value) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
