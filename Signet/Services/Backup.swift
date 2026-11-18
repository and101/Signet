import CommonCrypto
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation
import ZsignC

extension UTType {
    static let signetBackup = UTType(exportedAs: "ember.wax.signet.backup")
}

/// Saves certificates (with their passwords), sources, GitHub repos, signing options and optionally the library
/// into one `.signetbackup` file, so a re-signed copy of Signet (new bundle ID, new storage) can pick up where
/// the old one left off.
///
/// The file is a zip: `manifest.json`, `Certificates/<id>/…` and `Library/<id>/…`. Certificate passwords are
/// encrypted with AES-GCM under a key derived from the backup password; everything else is plain, and the
/// `.p12` files keep their own password protection.
enum Backup {
    static let currentVersion = 1
    static let fileExtension = "signetbackup"

    struct EncryptedBlob: Codable {
        var salt: Data
        var iterations: Int
        var sealed: Data
    }

    struct Manifest: Codable {
        var version: Int
        var created: Date
        var appVersion: String?
        var certificates: [Lossy<CertificateRecord>]
        var passwords: EncryptedBlob
        var defaultCertificateID: UUID?
        var sources: [Lossy<SavedSource>]
        var repos: [Lossy<TrackedRepo>]
        /// `SigningOptions` defaults as JSON, decoded leniently so older or newer option sets still load.
        var signingDefaults: Data?
        var library: [Lossy<LibraryApp>]
    }

    struct Contents {
        var certificates: [CertificateRecord]
        var defaultCertificateID: UUID?
        var sources: [SavedSource]
        var repos: [TrackedRepo]
        var signingDefaults: SigningOptions
        var library: [LibraryApp]
    }

    /// A backup that was decrypted and unpacked into a temporary folder, ready to apply.
    struct Opened {
        let manifest: Manifest
        let passwords: [UUID: String]
        let folder: URL

        var certificates: [CertificateRecord] { manifest.certificates.compactMap(\.value) }
        var library: [LibraryApp] { manifest.library.compactMap(\.value) }

        func discard() { try? FileManager.default.removeItem(at: folder) }
    }

    struct Summary: Equatable {
        var certificates = 0
        var sources = 0
        var repos = 0
        var apps = 0
        var skipped: [String] = []

        var message: String {
            func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
            var text = "Restored \(count(certificates, "certificate")), \(count(sources, "source")), "
                + "\(count(repos, "GitHub repo")) and \(count(apps, "app"))."
            if !skipped.isEmpty { text += "\n\nSkipped: " + skipped.joined(separator: "; ") + "." }
            return text
        }
    }

    // MARK: - Creating

    static func suggestedFileName(date: Date = Date()) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        return "Signet Backup \(day).\(fileExtension)"
    }

    /// Writes a backup to `url`. Fails if a certificate's saved password can't be read, rather than backing up
    /// a certificate that couldn't be used after restoring.
    static func create(_ contents: Contents, password: String, to url: URL,
                       readPassword: (UUID) -> String? = { Keychain.get($0.uuidString) }) throws {
        guard !password.isEmpty else { throw AppError("Choose a password for the backup.") }
        let fm = FileManager.default

        var passwords: [String: String] = [:]
        for record in contents.certificates {
            guard let saved = readPassword(record.id) else {
                throw AppError("\(record.nickname)'s password is missing. Re-add the certificate and try again.")
            }
            guard fm.fileExists(atPath: record.p12URL.path), fm.fileExists(atPath: record.profileURL.path) else {
                throw AppError("\(record.nickname)'s files are missing. Re-add the certificate and try again.")
            }
            passwords[record.id.uuidString] = saved
        }

        let library = contents.library.filter { fm.fileExists(atPath: $0.directory.path) }
        let manifest = Manifest(
            version: currentVersion,
            created: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            certificates: contents.certificates.map { Lossy(value: $0) },
            passwords: try encrypt(JSONEncoder().encode(passwords), password: password),
            defaultCertificateID: contents.defaultCertificateID,
            sources: contents.sources.map { Lossy(value: $0) },
            repos: contents.repos.map { Lossy(value: $0) },
            signingDefaults: try? JSONEncoder().encode(contents.signingDefaults.asDefaults),
            library: library.map { Lossy(value: $0) }
        )

        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        do {
            let archive = try Archive(url: url, accessMode: .create)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(manifestData.count),
                                 compressionMethod: .deflate) { position, size in
                manifestData.subdata(in: Int(position)..<Int(position) + size)
            }
            for record in contents.certificates {
                try add(folder: record.directory, as: "Certificates/\(record.id.uuidString)", to: archive)
            }
            for app in library {
                // IPAs and app bundles are already compressed or large; storing keeps backups fast.
                try add(folder: app.directory, as: "Library/\(app.id.uuidString)", to: archive, compression: .none)
            }
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    private static func add(folder: URL, as prefix: String, to archive: Archive,
                            compression: CompressionMethod = .deflate) throws {
        let fm = FileManager.default
        let base = folder.resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let item as URL in enumerator {
            // Resolve the parent only, so a symlink inside an app bundle is stored as a link, under its own name.
            let full = item.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(item.lastPathComponent).path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            try archive.addEntry(with: "\(prefix)/\(relative)", fileURL: item, compressionMethod: compression)
        }
    }

    // MARK: - Opening

    /// Decrypts and unpacks a backup into a temporary folder. Nothing in the app changes until `apply`.
    static func open(_ url: URL, password: String) throws -> Opened {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw AppError("That isn't a Signet backup.")
        }
        guard let manifestEntry = archive["manifest.json"] else { throw AppError("That isn't a Signet backup.") }
        var manifestData = Data()
        _ = try archive.extract(manifestEntry) { manifestData.append($0) }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw AppError("This backup is damaged.")
        }
        guard manifest.version <= currentVersion else {
            throw AppError("This backup needs a newer version of Signet.")
        }
        let passwordData = try decrypt(manifest.passwords, password: password)
        let rawPasswords = (try? JSONDecoder().decode([String: String].self, from: passwordData)) ?? [:]
        var passwords: [UUID: String] = [:]
        for (key, value) in rawPasswords { if let id = UUID(uuidString: key) { passwords[id] = value } }

        let folder = try Paths.newTempDirectory()
        do {
            for entry in archive where entry.type != .directory {
                guard let destination = safeDestination(for: entry.path, in: folder) else { continue }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return Opened(manifest: manifest, passwords: passwords, folder: folder)
    }

    /// Only `Certificates/<uuid>/…` and `Library/<uuid>/…` are unpacked, and never outside `folder`.
    static func safeDestination(for path: String, in folder: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, ["Certificates", "Library"].contains(parts[0]), UUID(uuidString: parts[1]) != nil,
              !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.reduce(folder) { $0.appendingPathComponent($1) }
    }

    // MARK: - Applying

    /// Merges an opened backup into the app. Items that already exist (same ID, source URL or repo) are kept as is.
    @MainActor
    static func apply(_ backup: Opened, certificates: CertificateStore, library: LibraryStore,
                      sources: SourceStore, github: GitHubStore) -> Summary {
        let fm = FileManager.default
        var summary = Summary()
        let hadCertificates = !certificates.certificates.isEmpty

        for record in backup.certificates where certificates.certificate(record.id) == nil {
            let source = backup.folder.appendingPathComponent("Certificates/\(record.id.uuidString)", isDirectory: true)
            let p12 = source.appendingPathComponent(record.p12URL.lastPathComponent)
            guard let password = backup.passwords[record.id], fm.fileExists(atPath: p12.path),
                  fm.fileExists(atPath: source.appendingPathComponent(record.profileURL.lastPathComponent).path),
                  p12_password_check(p12.path, password) else {
                summary.skipped.append("\(record.nickname) (files or password missing)")
                continue
            }
            do {
                try? fm.removeItem(at: record.directory)
                try fm.createDirectory(at: Paths.certificates, withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: record.directory)
            } catch {
                summary.skipped.append("\(record.nickname) (\(error.localizedDescription))")
                continue
            }
            guard (try? Keychain.set(password, for: record.id.uuidString)) != nil,
                  Keychain.get(record.id.uuidString) == password else {
                try? fm.removeItem(at: record.directory)
                summary.skipped.append("\(record.nickname) (couldn't save its password)")
                continue
            }
            certificates.restore(record)
            summary.certificates += 1
        }
        if !hadCertificates, let id = backup.manifest.defaultCertificateID, certificates.certificate(id) != nil {
            certificates.defaultID = id
        }

        summary.sources = sources.restore(backup.manifest.sources.compactMap(\.value))
        summary.repos = github.restore(backup.manifest.repos.compactMap(\.value))
        if let data = backup.manifest.signingDefaults {
            SigningOptions.defaults = SigningOptions.decodeDefaults(from: data)
        }

        for app in backup.library where library.app(app.id) == nil {
            let source = backup.folder.appendingPathComponent("Library/\(app.id.uuidString)", isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            do {
                try? fm.removeItem(at: app.directory)
                try fm.createDirectory(at: Paths.library, withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: app.directory)
                library.add(app)
                summary.apps += 1
            } catch {
                summary.skipped.append("\(app.name) (\(error.localizedDescription))")
            }
        }
        backup.discard()
        return summary
    }

    // MARK: - Encryption

    private static let defaultIterations = 210_000

    static func encrypt(_ data: Data, password: String, iterations: Int = defaultIterations) throws -> EncryptedBlob {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AppError("Couldn't create the backup's encryption key.") }
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        guard let sealed = try AES.GCM.seal(data, using: key).combined else {
            throw AppError("Couldn't encrypt the backup.")
        }
        return EncryptedBlob(salt: salt, iterations: iterations, sealed: sealed)
    }

    static func decrypt(_ blob: EncryptedBlob, password: String) throws -> Data {
        let key = try deriveKey(password: password, salt: blob.salt, iterations: blob.iterations)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: blob.sealed), using: key)
        } catch {
            throw AppError("Wrong password.")
        }
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard (1...10_000_000).contains(iterations) else { throw AppError("The backup is damaged.") }
        var key = Data(count: 32)
        let passwordBytes = Array(password.utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    keyBytes.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        guard status == kCCSuccess else { throw AppError("Couldn't derive the backup key.") }
        return SymmetricKey(data: key)
    }
}

extension Lossy {
    init(value: T?) { self.value = value }
}
