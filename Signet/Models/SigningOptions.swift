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

    // Behaviour (saved as defaults)
    var removeSupportedDevices = true
    var enableFileSharing = false
    var removeURLSchemes = false
    var removePlugins = false
    var removeWatchApp = false
    var forceFullScreen = false
    var removeProvisioningFile = false
    var weakInject = true
    var fixSubstratePaths = true
    var bundleElleKit = true
    var mergeEntitlements = false
    var compressIPA = true
    var installAfterSigning = false
    var deleteOriginalAfterSigning = false
    /// Add `ppqSuffix` to bundle IDs when the certificate's profile has Apple check apps at launch, so a signed app
    /// never shares an App Store app's ID (which can get the certificate revoked).
    var ppqProtection = true
    /// Random, generated once and used for every app, so re-signing an app still updates the installed copy.
    var ppqSuffix = ""

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
        return copy
    }

    /// iOS 26's design. Apps built with an older SDK get the classic look; ones built with iOS 26 get Liquid Glass.
    enum InterfaceStyle: String, Codable, CaseIterable {
        case unchanged
        /// Keeps the pre-iOS 26 look (`UIDesignRequiresCompatibility`).
        case classic
        /// Marks the app as built with the iOS 26 SDK so UIKit uses Liquid Glass. Can break apps that check the SDK.
        case liquidGlass
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
