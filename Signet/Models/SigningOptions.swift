import Foundation

struct SigningOptions: Codable, Equatable {
    // Per-app customization (never saved as defaults)
    var appName = ""
    var bundleID = ""
    var version = ""
    var minimumOSVersion = ""
    var customIcon: Data?
    var injectFiles: [URL] = []
    var removeLoadCommands: [String] = []
    var interfaceStyle = InterfaceStyle.unchanged
    var appearance = Appearance.unchanged
    /// Paths inside the .app to delete, e.g. `PlugIns/Share.appex` or `Frameworks/Ads.framework`.
    var removePaths: [String] = []
    /// An entitlements plist to sign with instead of the profile's (or merged) entitlements.
    var entitlementsFile: URL?

    // Behaviour (saved as defaults)
    var removeSupportedDevices = true
    var enableFileSharing = false
    var removeURLSchemes = false
    var removePlugins = false
    var removeWatchApp = false
    var forceFullScreen = false
    /// Lets the app run at 120 Hz on ProMotion iPhones.
    var enableProMotion = false
    var enableGameMode = false
    var removeProvisioningFile = false
    var weakInject = true
    var fixSubstratePaths = true
    var bundleElleKit = true
    /// Also inject tweaks into the app's extensions (widgets, share extensions and so on).
    var injectIntoExtensions = false
    var mergeEntitlements = false
    var compressIPA = true
    var installAfterSigning = false
    var deleteOriginalAfterSigning = false
    /// Add `ppqSuffix` to bundle IDs when the certificate's profile has Apple check apps at launch, so a signed app
    /// never shares an App Store app's ID (which can get the certificate revoked).
    var ppqProtection = true
    /// Random, generated once and used for every app, so re-signing an app still updates the installed copy.
    var ppqSuffix = ""
    /// Replace an app's bundle ID or name automatically whenever it's signed, e.g. com.spotify.client → com.me.spotify.
    var bundleIDRules: [RenameRule] = []
    var nameRules: [RenameRule] = []

    /// The bundle ID a rule gives this app, if any (exact match).
    func ruleBundleID(for bundleID: String) -> String? {
        bundleIDRules.first { $0.match.trimmingCharacters(in: .whitespaces) == bundleID }?.cleanReplacement
    }

    /// The name a rule gives this app, if any (exact match, ignoring case).
    func ruleName(for name: String) -> String? {
        nameRules.first { $0.match.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }?.cleanReplacement
    }

    /// Strips the per-app fields so the rest can be stored as defaults.
    var asDefaults: SigningOptions {
        var copy = self
        copy.appName = ""
        copy.bundleID = ""
        copy.version = ""
        copy.minimumOSVersion = ""
        copy.customIcon = nil
        copy.injectFiles = []
        copy.removeLoadCommands = []
        copy.interfaceStyle = .unchanged
        copy.appearance = .unchanged
        copy.removePaths = []
        copy.entitlementsFile = nil
        return copy
    }

    /// Forces light or dark mode (`UIUserInterfaceStyle`).
    enum Appearance: String, Codable, CaseIterable {
        case unchanged, light, dark
    }

    /// iOS 26's design. Apps built with an older SDK get the classic look; ones built with iOS 26 get Liquid Glass.
    enum InterfaceStyle: String, Codable, CaseIterable {
        case unchanged
        /// Keeps the pre-iOS 26 look (`UIDesignRequiresCompatibility`).
        case classic
        /// Marks the app as built with the iOS 26 SDK so UIKit uses Liquid Glass. Can break apps that check the SDK.
        case liquidGlass
    }

    struct RenameRule: Codable, Hashable, Identifiable {
        var id = UUID()
        var match: String
        var replacement: String

        var cleanReplacement: String? {
            let value = replacement.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    private static let key = "defaultSigningOptions"

    static var defaults: SigningOptions {
        get {
            var options = UserDefaults.standard.data(forKey: key).map(decodeDefaults) ?? SigningOptions()
            if options.ppqSuffix.isEmpty {
                options.ppqSuffix = makePPQSuffix()
                UserDefaults.standard.set(try? JSONEncoder().encode(options.asDefaults), forKey: key)
            }
            return options
        }
        set {
            var value = newValue.asDefaults
            // Never lose the suffix (e.g. on "Reset to Defaults"): apps signed with it would stop updating in place.
            if value.ppqSuffix.isEmpty { value.ppqSuffix = defaults.ppqSuffix }
            UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
        }
    }

    /// Six lowercase letters and digits, starting with a letter, e.g. `k3x9qa`.
    static func makePPQSuffix() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let characters = letters + Array("0123456789")
        return String(letters.randomElement()!) + String((0..<5).map { _ in characters.randomElement()! })
    }

    /// Overlays saved values on the current defaults, so options added in later versions don't
    /// make older saved defaults fail to decode.
    static func decodeDefaults(from data: Data) -> SigningOptions {
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseData = try? JSONEncoder().encode(SigningOptions()),
              var merged = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] else { return SigningOptions() }
        merged.merge(saved) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let options = try? JSONDecoder().decode(SigningOptions.self, from: mergedData) else { return SigningOptions() }
        return options
    }
}
