import Foundation

enum RevocationStatus: String, Codable {
    case valid, revoked, unknown

    init(ocspStatus: Int32) {
        switch ocspStatus {
        case 0: self = .valid
        case 1: self = .revoked
        default: self = .unknown
        }
    }
}

/// A .p12 + .mobileprovision pair. Password lives in the keychain keyed by `id`.
struct CertificateRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var nickname: String
    var certificateName: String
    var teamName: String
    var teamID: String
    var profileName: String
    var applicationIdentifier: String
    var creationDate: Date
    var expirationDate: Date
    var provisionedDeviceCount: Int?
    var provisionsAllDevices: Bool
    var entitlements: [String: String]
    var certificateMatchesProfile: Bool?
    var revocation: RevocationStatus?
    var revocationCheckedAt: Date?
    var dateAdded = Date()
    /// The profile asks iOS to check apps with Apple when they launch. Nil for certificates imported before this
    /// was recorded; `CertificateStore` fills it in from the saved profile.
    var ppqCheck: Bool?

    var directory: URL { Paths.certificates.appendingPathComponent(id.uuidString, isDirectory: true) }
    var p12URL: URL { directory.appendingPathComponent("certificate.p12") }
    var profileURL: URL { directory.appendingPathComponent("profile.mobileprovision") }
    var password: String { Keychain.get(id.uuidString) ?? "" }

    var isExpired: Bool { expirationDate < Date() }

    /// Bundle ID pattern without the App ID prefix, e.g. `*` or `com.example.app`.
    /// The prefix is usually the team ID, but older App IDs can have a different 10-character prefix.
    var bundleIDPattern: String {
        let prefix = teamID + "."
        if !teamID.isEmpty, applicationIdentifier.hasPrefix(prefix) {
            return String(applicationIdentifier.dropFirst(prefix.count))
        }
        if let dot = applicationIdentifier.firstIndex(of: ".") {
            let candidate = applicationIdentifier[..<dot]
            if candidate.count == 10, candidate.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
            }
        }
        return applicationIdentifier
    }

    var isWildcard: Bool { bundleIDPattern.hasSuffix("*") }

    var distributionKind: String {
        if provisionsAllDevices { return String(localized: "Enterprise") }
        if provisionedDeviceCount != nil { return entitlements["get-task-allow"] == "true" ? String(localized: "Development") : String(localized: "Ad Hoc") }
        return String(localized: "Distribution")
    }

    /// Why apps signed with this certificate won't open. Nil when nothing is known to be wrong.
    var problem: String? {
        if isExpired { return String(localized: "Expired") }
        return revocation == .revoked ? String(localized: "Revoked") : nil
    }

    /// Wildcard profiles can't sign IDs outside their namespace (zsign fails). Exact App IDs never block: apps keep
    /// their own bundle ID so several can be installed side by side, like Feather.
    func rejects(bundleID: String) -> Bool {
        isWildcard && !allows(bundleID: bundleID)
    }

    /// What to show when `bundleID` can't be used, e.g. "Must start with com.example.".
    func bundleIDRequirement(for bundleID: String) -> String? {
        rejects(bundleID: bundleID) ? "Must start with \(String(bundleIDPattern.dropLast()))" : nil
    }


    func allows(bundleID: String) -> Bool {
        let pattern = bundleIDPattern
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return bundleID.hasPrefix(prefix) && bundleID.count > prefix.count
        }
        return bundleID == pattern
    }

    /// The bundle ID to sign with when none is chosen, or nil to keep the app's own: moved into a wildcard profile's
    /// namespace if needed, plus the PPQ suffix when this profile has Apple check apps at launch.
    func bundleID(for appBundleID: String, options: SigningOptions) -> String? {
        var id = suggestedBundleID(for: appBundleID) ?? appBundleID
        let suffix = options.ppqSuffix
        if ppqCheck == true, options.ppqProtection, !suffix.isEmpty, !id.hasSuffix("." + suffix) {
            id += "." + suffix
        }
        return id == appBundleID ? nil : id
    }

    /// The bundle ID to sign with when a wildcard profile doesn't cover the app's own. Keeps the original ID inside
    /// the profile's namespace so suggestions stay unique per app. Nil when the app's ID can be used as is.
    func suggestedBundleID(for bundleID: String) -> String? {
        guard isWildcard, !bundleID.isEmpty, !allows(bundleID: bundleID) else { return nil }
        let suggested = String(bundleIDPattern.dropLast()) + bundleID
        return allows(bundleID: suggested) ? suggested : nil
    }
}
