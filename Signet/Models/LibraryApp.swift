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

    var directory: URL { Paths.library.appendingPathComponent(id.uuidString, isDirectory: true) }
    var payloadURL: URL { directory.appendingPathComponent("Payload", isDirectory: true) }
    var appURL: URL { payloadURL.appendingPathComponent(appFolderName, isDirectory: true) }
    var iconURL: URL { directory.appendingPathComponent("icon.png") }
    var ipaURL: URL { directory.appendingPathComponent(ipaFileName) }

    var ipaFileName: String {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return "\(safe)_\(version).ipa"
    }
}
