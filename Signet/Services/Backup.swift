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
        /// Certificates whose staged files passed the checks in `open` (small regular files, readable profile, correct
        /// password), with whether the profile includes the certificate. Done while opening, off the main actor.
        var verifiedCertificates: [UUID: Bool?] = [:]

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
    /// - Returns: the names of library apps left out because restoring them would fail.
    @discardableResult
    static func create(_ contents: Contents, password: String, to url: URL,
                       readPassword: (UUID) -> String? = { Keychain.get($0.uuidString) }) throws -> [String] {
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
            // Restore only accepts small regular files, so check here rather than make a backup that can't restore it.
            guard isSmallRegularFile(record.p12URL), isSmallRegularFile(record.profileURL) else {
                throw AppError("\(record.nickname)'s files are too large or aren't regular files, so it can't be backed up.")
            }
            passwords[record.id.uuidString] = saved
        }

        // An app that restore would refuse (unsafe record, or an imported app whose bundle is gone) is left out
        // rather than failing the whole backup.
        let library = contents.library.filter {
            fm.fileExists(atPath: $0.directory.path) && (try? $0.validateAppFolder(in: $0.directory)) != nil
                && isFullyReadable($0.directory)
        }
        let leftOut = contents.library.filter { app in !library.contains { $0.id == app.id } }.map(\.name)
        // Checked before writing anything: restore refuses backups over this size, so don't make one.
        let total = library.reduce(Int64(0)) { $0 + fm.directorySize(at: $1.directory) }
            + contents.certificates.reduce(Int64(0)) { $0 + fm.directorySize(at: $1.directory) }
        guard UInt64(max(0, total)) <= ArchiveBudget.backup.remaining else {
            throw AppError("The library is too large to back up (over \(ByteCountFormatter.string(fromByteCount: Int64(ArchiveBudget.backup.remaining), countStyle: .file))). Turn off Include Library, or remove some apps.")
        }
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
            guard manifestData.count <= ArchiveBudget.manifestLimit else { throw AppError("The backup manifest is too large.") }
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
            try ArchiveBudget.backup.validate(archive)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return leftOut
    }

    /// Whether every item under `folder` can be listed, so an app isn't backed up with parts silently missing.
    static func isFullyReadable(_ folder: URL) -> Bool {
        var failed = false
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) { _, _ in
            failed = true
            return false
        }
        guard let walker else { return false }
        while walker.nextObject() != nil, !failed {}
        return !failed
    }

    private static func add(folder: URL, as prefix: String, to archive: Archive,
                            compression: CompressionMethod = .deflate) throws {
        let fm = FileManager.default
        let base = folder.resolvingSymlinksInPath().path
        // A folder that can't be read fails the backup rather than leaving files out of it without a word.
        var readError: Error?
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) { url, error in
            readError = AppError("Couldn't read \(url.lastPathComponent) for the backup: \(error.localizedDescription)")
            return false
        }
        guard let enumerator else { throw AppError("Couldn't read \(folder.lastPathComponent) for the backup.") }
        for case let item as URL in enumerator {
            if let readError { throw readError }
            // Resolve the parent only, so a symlink inside an app bundle is stored as a link, under its own name.
            // Restoring checks each link's size and that it stays inside the bundle.
            let full = item.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(item.lastPathComponent).path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            try archive.addEntry(with: "\(prefix)/\(relative)", fileURL: item, compressionMethod: compression)
        }
        if let readError { throw readError }
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
        let needed = try ArchiveBudget.backup.validate(archive)
        try ArchiveBudget.checkFreeSpace(needed: needed, at: FileManager.default.temporaryDirectory)
        guard let manifestEntry = archive["manifest.json"] else { throw AppError("That isn't a Signet backup.") }
        var manifestData = Data()
        guard manifestEntry.type == .file, manifestEntry.uncompressedSize <= ArchiveBudget.manifestLimit else {
            throw AppError("The backup manifest is too large.")
        }
        let manifestChecksum = try archive.extract(manifestEntry) { chunk in
            guard UInt64(chunk.count) <= ArchiveBudget.manifestLimit - UInt64(manifestData.count) else {
                throw AppError("The backup manifest is too large.")
            }
            manifestData.append(chunk)
        }
        guard manifestChecksum == manifestEntry.checksum else { throw AppError("This backup is damaged.") }
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
            var budget = ArchiveBudget.backup
            // Directories are restored too, so empty folders in app bundles survive.
            for entry in archive {
                guard let destination = safeDestination(for: entry.path, in: folder) else { continue }
                // extract creates parent folders itself, after checking they don't lead through a link.
                try budget.extract(entry, from: archive, to: destination, root: folder)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        var opened = Opened(manifest: manifest, passwords: passwords, folder: folder)
        for record in opened.certificates {
            let source = folder.appendingPathComponent("Certificates/\(record.id.uuidString)", isDirectory: true)
            let p12 = source.appendingPathComponent(record.p12URL.lastPathComponent)
            let profileURL = source.appendingPathComponent(record.profileURL.lastPathComponent)
            // Real p12s and profiles are kilobytes; the limit keeps a crafted backup from reading gigabytes.
            guard let password = passwords[record.id], isSmallRegularFile(p12), isSmallRegularFile(profileURL),
                  let profile = try? ProvisioningProfile(url: profileURL), p12_password_check(p12.path, password) else { continue }
            opened.verifiedCertificates[record.id] = .some(CertificateImporter.certificateMatches(
                p12: p12, password: password, profile: profile))
        }
        return opened
    }

    static let certificateFileLimit: Int64 = 4 * 1024 * 1024

    /// A regular file (not a link, which readers would follow) no larger than `certificateFileLimit`.
    static func isSmallRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value <= certificateFileLimit
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
            let profileURL = source.appendingPathComponent(record.profileURL.lastPathComponent)
            guard let password = backup.passwords[record.id], fm.fileExists(atPath: p12.path), fm.fileExists(atPath: profileURL.path) else {
                summary.skipped.append("\(record.nickname) (files or password missing)")
                continue
            }
            // Checked in `open` (off the main actor), before anything is moved or saved here.
            guard let match = backup.verifiedCertificates[record.id] else {
                summary.skipped.append("\(record.nickname) (certificate or profile unreadable)")
                continue
            }
            // The pair's match comes from the restored files, not the flag saved in the backup.
            var restored = record
            restored.certificateMatchesProfile = match
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
            certificates.restore(restored)
            summary.certificates += 1
        }
        if !hadCertificates, let id = backup.manifest.defaultCertificateID, certificates.certificate(id) != nil {
            certificates.defaultID = id
        }

        summary.sources = sources.restore(backup.manifest.sources.compactMap(\.value))
        summary.repos = github.restore(backup.manifest.repos.compactMap(\.value))
        if let data = backup.manifest.signingDefaults {
            SigningOptions.defaults = mergedDefaults(current: SigningOptions.defaults, backup: SigningOptions.decodeDefaults(from: data),
                                                     hasSignedApps: library.apps.contains { $0.kind == .signed })
        }

        for app in backup.library where library.app(app.id) == nil {
            let source = backup.folder.appendingPathComponent("Library/\(app.id.uuidString)", isDirectory: true)
            guard fm.fileExists(atPath: source.path) else {
                summary.skipped.append("\(app.name) (files missing from the backup)")
                continue
            }
            do {
                try app.validateAppFolder(in: source)
                try? fm.removeItem(at: app.directory)
                try fm.createDirectory(at: Paths.library, withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: app.directory)
                try library.addOrRemove(app)
                summary.apps += 1
            } catch {
                summary.skipped.append("\(app.name) (\(error.localizedDescription))")
            }
        }
        backup.discard()
        return summary
    }

    /// Restoring keeps what's already here: a backup's signing defaults are used only if the current ones were never
    /// changed (a fresh install, where they also bring back the PPQ suffix older apps were signed with). Rename
    /// rules from both are kept.
    static func mergedDefaults(current: SigningOptions, backup: SigningOptions, hasSignedApps: Bool) -> SigningOptions {
        var fresh = SigningOptions()
        fresh.ppqSuffix = current.ppqSuffix
        // Rules are compared separately below; a fresh install with rules typed in still counts as unchanged.
        var currentSettings = current.asDefaults
        currentSettings.bundleIDRules = []
        currentSettings.nameRules = []
        // Apps already signed here use this installation's PPQ suffix; replacing it would stop them updating in place.
        let unchanged = currentSettings == fresh.asDefaults && !hasSignedApps
        var result = unchanged ? backup : current
        func union(_ mine: [SigningOptions.RenameRule], _ theirs: [SigningOptions.RenameRule],
                   key: (String) -> String) -> [SigningOptions.RenameRule] {
            let taken = Set(mine.map { key($0.match) })
            return mine + theirs.filter { !taken.contains(key($0.match)) }
        }
        result.bundleIDRules = union(current.bundleIDRules, backup.bundleIDRules) { $0.trimmingCharacters(in: .whitespaces) }
        result.nameRules = union(current.nameRules, backup.nameRules) { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return result
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
