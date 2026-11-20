import Foundation

/// An app in the library: either an imported (unsigned) IPA or one produced by signing.
struct LibraryApp: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case imported, signed }

    var id = UUID()
    var kind: Kind
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minimumOSVersion: String?
    var appFolderName: String
    var size: Int64
    var dateAdded = Date()
    var sourceURL: String?

    // Signed apps only
    var certificateID: UUID?
    var certificateName: String?
    var originalAppID: UUID?
    /// Bundle ID of the app this was signed from, kept even if that app is deleted.
    var originalBundleID: String?
    /// The options this app was signed with, as JSON so options added later don't stop it decoding.
    /// The custom icon and tweaks are stored as files next to it; see `rememberedOptions`.
    var signingOptionsData: Data?

    var directory: URL { Paths.library.appendingPathComponent(id.uuidString, isDirectory: true) }
    var payloadURL: URL { directory.appendingPathComponent("Payload", isDirectory: true) }
    var appURL: URL { payloadURL.appendingPathComponent(appFolderName, isDirectory: true) }
    var iconURL: URL { directory.appendingPathComponent("icon.png") }
    var ipaURL: URL { ipaURL(in: directory) }

    /// The signed IPA in `folder` (the app's directory, or a backup's staging copy of it).
    func ipaURL(in folder: URL) -> URL {
        let directory = folder
        let safe = directory.appendingPathComponent(ipaFileName)
        // Older releases used unbounded components. Keep existing safe filenames readable after upgrading.
        let legacyName = "\(name.replacingOccurrences(of: "/", with: "-"))_\(version).ipa"
        if legacyName != ipaFileName, !legacyName.contains("/"),
           !FileManager.default.fileExists(atPath: safe.path) {
            let legacy = directory.appendingPathComponent(legacyName)
            if FileManager.default.fileExists(atPath: legacy.path),
               legacy.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() {
                return legacy
            }
        }
        return safe
    }

    var tweaksURL: URL { directory.appendingPathComponent("Tweaks", isDirectory: true) }
    var customIconURL: URL { directory.appendingPathComponent("custom-icon.png") }
    var customEntitlementsURL: URL { directory.appendingPathComponent("custom-entitlements.plist") }

    /// The options a signed app was made with, including its custom icon and tweaks.
    var rememberedOptions: SigningOptions? {
        guard let signingOptionsData else { return nil }
        var options = SigningOptions.decodeDefaults(from: signingOptionsData)
        let fm = FileManager.default
        // Remembered icons can be 1.1's original photos or come from a backup: scaled down safely, not refused.
        options.customIcon = IconImage.loadCustomIcon(customIconURL)
        options.entitlementsFile = fm.fileExists(atPath: customEntitlementsURL.path) ? customEntitlementsURL : nil
        // Tweaks load in the order they were added, which can matter; older records only have the files.
        let files = ((try? fm.contentsOfDirectory(at: tweaksURL, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var unique = Set<String>()
        let order = options.injectFiles.map(\.lastPathComponent).filter { unique.insert($0).inserted }
        options.injectFiles = order.compactMap { name in files.first { $0.lastPathComponent == name } }
            + files.filter { !order.contains($0.lastPathComponent) }
        return options
    }

    /// Backup metadata and older indexes are untrusted too; a bundle must be a direct Payload child.
    /// `requireBundle` is for restores; a backup goes ahead even if an imported app's bundle has gone missing.
    func validateAppFolder(in directory: URL, requireBundle: Bool = true) throws {
        guard !appFolderName.contains("/"), !appFolderName.contains("\\"), !appFolderName.contains("\0"),
              appFolderName.hasSuffix(".app"), appFolderName != ".app" else {
            throw AppError("The app record contains an unsafe bundle folder name.")
        }
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent(appFolderName, isDirectory: true)
        // The name is a single component, so only a link at Payload or the bundle could lead elsewhere.
        // Check with lstat rather than comparing resolved paths: Payload is gone for signed apps, and resolving
        // a missing path keeps /private on device while an existing one drops it.
        for url in [payload, app] {
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            guard type != .typeSymbolicLink else { throw AppError("The app record points outside its Payload directory.") }
        }
        if requireBundle, kind == .imported {
            guard (try? app.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw AppError("The app bundle is missing.")
            }
        }
        if requireBundle, kind == .signed {
            let ipa = ipaURL(in: directory)
            guard (try? FileManager.default.attributesOfItem(atPath: ipa.path))?[.type] as? FileAttributeType == .typeRegular else {
                throw AppError("The signed IPA is missing.")
            }
        }
    }

    var ipaFileName: String {
        "\(Self.safeFileComponent(name))_\(Self.safeFileComponent(version)).ipa"
    }

    static func safeFileComponent(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
        // Also bound names so a hostile Info.plist cannot exceed filesystem component limits.
        var result = ""
        for scalar in cleaned.unicodeScalars {
            guard result.utf8.count + scalar.utf8.count <= 80 else { break }
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty ? "App" : result
    }
}
