import Foundation

/// How signed apps get onto the iPhone.
enum InstallMethod: String, CaseIterable {
    /// Signet's local HTTPS server and an itms-services link (needs the install certificate).
    case server
    /// Straight to the iPhone's installer through a pairing file and LocalDevVPN.
    case direct
}

/// Saved settings and records for direct install.
enum DirectInstall {
    private static let defaults = UserDefaults.standard
    static let methodKey = "installMethod"
    static let addressKey = "directInstallAddress"
    static let portKey = "directInstallPort"
    private static let discoveredPortKey = "directInstallDiscoveredPort"
    private static let stagedKey = "directInstallStagedPaths"
    private static let pendingSelfUpdateKey = "directInstallPendingSelfUpdate"

    static var method: InstallMethod {
        get { defaults.string(forKey: methodKey).flatMap(InstallMethod.init) ?? .server }
        set { defaults.set(newValue.rawValue, forKey: methodKey) }
    }

    /// LocalDevVPN's address for this iPhone; only changed for other VPNs.
    static var address: String {
        let saved = defaults.string(forKey: addressKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? DirectInstaller.defaultAddress : saved
    }

    /// A port typed in Advanced, if any; otherwise Signet finds it.
    static var manualPort: UInt16? {
        UInt16(defaults.string(forKey: portKey)?.trimmingCharacters(in: .whitespaces) ?? "").flatMap { $0 == 0 ? nil : $0 }
    }

    /// The port found over Bonjour last time, tried before searching again.
    static var discoveredPort: UInt16? {
        get { (defaults.object(forKey: discoveredPortKey) as? Int).flatMap { UInt16(exactly: $0) } }
        set { defaults.set(newValue.map { Int($0) }, forKey: discoveredPortKey) }
    }

    // MARK: - Pairing file

    /// Kept out of Documents (which the Files app shows) and encrypted while the iPhone is locked.
    static let pairingFileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pairing", isDirectory: true).appendingPathComponent("remote-pairing.plist")

    static var hasPairingFile: Bool { FileManager.default.fileExists(atPath: pairingFileURL.path) }

    /// Validates and stores a pairing file picked by the user.
    static func importPairingFile(from url: URL) throws {
        guard DirectInstaller.isRemotePairingFile(url) else {
            if DirectInstaller.isLockdownPairingFile(url) {
                throw AppError("That's an older lockdown pairing file, which current iOS doesn't accept over the network. Export the remote-pairing file from iloader instead (PairingFile_RemoteRP.plist).")
            }
            throw AppError("That isn't a pairing file. Export the remote-pairing file from iloader.")
        }
        let data = try Data(contentsOf: url)
        try FileManager.default.createDirectory(at: pairingFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: pairingFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        discoveredPort = nil
    }

    static func removePairingFile() {
        try? FileManager.default.removeItem(at: pairingFileURL)
    }

    // MARK: - Staged files

    /// IPAs uploaded to the iPhone and not yet deleted. Kept across launches, since a self-update closes Signet
    /// before it can clean up.
    static var stagedPaths: [String] {
        get { defaults.stringArray(forKey: stagedKey) ?? [] }
        set { defaults.set(newValue, forKey: stagedKey) }
    }

    // MARK: - Self-update

    struct PendingSelfUpdate: Codable, Equatable {
        let version: String
        let build: String
        /// Where the running copy lived. iOS installs every update into a new bundle container, so a different
        /// path on the next launch shows the update happened, even when the build number is the same.
        var bundlePath: String?

        func wasInstalled(nowAt currentPath: String) -> Bool {
            if let bundlePath { return bundlePath != currentPath }
            return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == build
        }
    }

    /// Recorded just before Signet quits to let iOS replace it; read on the next launch.
    static var pendingSelfUpdate: PendingSelfUpdate? {
        get { defaults.data(forKey: pendingSelfUpdateKey).flatMap { try? JSONDecoder().decode(PendingSelfUpdate.self, from: $0) } }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: pendingSelfUpdateKey)
            defaults.synchronize() // Signet exits right after setting this
        }
    }
}

/// Decides whether installing an app would replace Signet itself, and whether that's safe.
enum SelfUpdateCheck: Equatable {
    /// Not Signet.
    case otherApp
    /// Signet with its own bundle ID: replaces this copy and keeps its data. `differentTeam` means the update is
    /// signed by another team, so passwords in the keychain won't be readable afterwards.
    case update(differentTeam: Bool)
    /// A copy of Signet under another bundle ID: it would install as a separate app with none of this one's data.
    case separateCopy

    static func evaluate(app: LibraryApp, runningBundleID: String?, runningTeamID: String?, signingTeamID: String?) -> SelfUpdateCheck {
        guard let runningBundleID else { return .otherApp }
        if app.bundleID == runningBundleID {
            let differentTeam = runningTeamID.map { running in signingTeamID.map { !$0.isEmpty && $0 != running } ?? false } ?? false
            return .update(differentTeam: differentTeam)
        }
        if app.originalBundleID == runningBundleID || app.originalBundleID == Self.releaseBundleID { return .separateCopy }
        return .otherApp
    }

    /// The bundle ID Signet is published with, which re-signed copies keep as their original.
    static let releaseBundleID = "ember.wax.signet"

    /// The team that signed the running copy of Signet, from its embedded profile.
    static var runningTeamID: String? {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? ProvisioningProfile(url: $0).teamID }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
