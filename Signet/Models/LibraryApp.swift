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
    var ipaURL: URL { directory.appendingPathComponent(ipaFileName) }

    var tweaksURL: URL { directory.appendingPathComponent("Tweaks", isDirectory: true) }
    var customIconURL: URL { directory.appendingPathComponent("custom-icon.png") }

    /// The options a signed app was made with, including its custom icon and tweaks.
    var rememberedOptions: SigningOptions? {
        guard let signingOptionsData else { return nil }
        var options = SigningOptions.decodeDefaults(from: signingOptionsData)
        let fm = FileManager.default
        options.customIcon = try? Data(contentsOf: customIconURL)
        options.injectFiles = ((try? fm.contentsOfDirectory(at: tweaksURL, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return options
    }

    var ipaFileName: String {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return "\(safe)_\(version).ipa"
    }
}
