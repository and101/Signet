import Foundation
import UIKit
import Zsign
import ZIPFoundation

/// Runs the signing pipeline: copy → patch Info.plist → strip/inject → fix arm64e → merge entitlements → zsign → zip.
/// zsign keeps global state, so signing is serialized through this actor.
actor Signer {
    static let shared = Signer()
    /// The first SDK whose apps get Liquid Glass.
    static let liquidGlassSDK = "26.0"

    func sign(
        _ source: LibraryApp,
        with certificate: CertificateRecord,
        options: SigningOptions,
        log: @escaping @Sendable (String) -> Void
    ) throws -> LibraryApp {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appURL.path) else {
            throw AppError("The original app files are missing. Re-import the IPA.")
        }
        guard fm.fileExists(atPath: certificate.p12URL.path), fm.fileExists(atPath: certificate.profileURL.path) else {
            throw AppError("The certificate files are missing. Re-import the certificate.")
        }
        let requestedID = options.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        // With no bundle ID chosen, keep the app's own, moved into a wildcard profile's namespace if needed and
        // with the PPQ suffix for profiles that have Apple check apps at launch.
        let effectiveID = requestedID.isEmpty
            ? (certificate.bundleID(for: source.bundleID, options: options) ?? source.bundleID)
            : requestedID
        // zsign fails on a wildcard mismatch, so block those. Exact App IDs are applied as the profile's
        // entitlements while the app keeps the chosen bundle ID, matching Feather.
        guard !certificate.rejects(bundleID: effectiveID) else {
            throw AppError("The bundle ID must match your profile: \(certificate.bundleIDPattern).")
        }

        var result = source
        result.id = UUID()
        result.kind = .signed
        result.dateAdded = Date()
        result.originalAppID = source.id
        result.originalBundleID = source.kind == .signed ? (source.originalBundleID ?? source.bundleID) : source.bundleID
        result.certificateID = certificate.id
        result.certificateName = certificate.nickname

        do {
            try fm.createDirectory(at: result.payloadURL, withIntermediateDirectories: true)
            log("Copying \(source.appFolderName)…")
            try fm.copyItem(at: source.appURL, to: result.appURL)
            let appURL = result.appURL

            log("Patching Info.plist…")
            try patchInfoPlist(at: appURL, options: options)

            if let icon = options.customIcon {
                log("Applying custom icon…")
                try applyIcon(icon, to: appURL)
            }

            if options.removePlugins {
                log("Removing app extensions…")
                for folder in ["PlugIns", "Extensions"] {
                    try? fm.removeItem(at: appURL.appendingPathComponent(folder))
                }
            }
            if options.removeWatchApp {
                log("Removing Watch app…")
                for folder in ["Watch", "com.apple.WatchPlaceholder"] {
                    try? fm.removeItem(at: appURL.appendingPathComponent(folder))
                }
            }

            try TweakInjector(appURL: appURL, options: options, log: log).run()
            try fixLegacyARM64ESlices(in: appURL, log: log)
            if options.interfaceStyle == .liquidGlass, let executable = AppImporter.mainExecutable(of: appURL) {
                log("Enabling Liquid Glass…")
                try MachO.setSDKVersion(in: executable, to: Self.liquidGlassSDK)
            }

            var entitlementsPath = ""
            if options.mergeEntitlements, let executable = AppImporter.mainExecutable(of: source.appURL) {
                if let url = try mergedEntitlements(for: executable, certificate: certificate, into: result.directory) {
                    log("Merging the app's entitlements…")
                    entitlementsPath = url.path
                } else {
                    log("The app has no entitlements to merge; using the profile's.")
                }
            }

            try Self.replaceNestedProfiles(in: appURL, with: certificate.profileURL,
                                           remove: options.removeProvisioningFile)
            log("Signing with \(certificate.nickname)…")
            let ok = Zsign.sign(
                appPath: appURL.path,
                provisionPath: certificate.profileURL.path,
                p12Path: certificate.p12URL.path,
                p12Password: certificate.password,
                entitlementsPath: entitlementsPath,
                // Empty keeps the app's own ID; otherwise zsign renames the app (and its extensions) to it.
                customIdentifier: effectiveID == source.bundleID ? "" : effectiveID,
                customName: options.appName.trimmingCharacters(in: .whitespaces),
                customVersion: options.version.trimmingCharacters(in: .whitespaces),
                removeProvision: options.removeProvisioningFile
            )
            guard ok else {
                throw AppError("Signing failed. Check the certificate's password and that it isn't revoked.")
            }

            let info = try BundleInfo(appURL: appURL)
            result.name = info.name
            result.bundleID = info.bundleID
            result.version = info.version
            result.build = info.build
            result.minimumOSVersion = info.minimumOSVersion

            AppImporter.saveIcon(from: appURL, to: result.iconURL)
            if !fm.fileExists(atPath: result.iconURL.path) {
                try? fm.copyItem(at: source.iconURL, to: result.iconURL)
            }

            log("Packaging IPA…")
            try fm.zipItem(
                at: result.payloadURL,
                to: result.ipaURL,
                shouldKeepParent: true,
                compressionMethod: options.compressIPA ? .deflate : .none
            )
            try fm.removeItem(at: result.payloadURL)
            if !entitlementsPath.isEmpty { try? fm.removeItem(atPath: entitlementsPath) }
            result.size = fm.fileSize(at: result.ipaURL)
            log("Done — \(result.size.formattedBytes)")
            return result
        } catch {
            try? fm.removeItem(at: result.directory)
            throw error
        }
    }

    // MARK: - Info.plist

    private func patchInfoPlist(at appURL: URL, options: SigningOptions) throws {
        let url = appURL.appendingPathComponent("Info.plist")
        guard let plist = NSMutableDictionary(contentsOf: url) else {
            throw AppError("Couldn't read Info.plist.")
        }
        if options.removeSupportedDevices {
            plist.removeObject(forKey: "UISupportedDevices")
        }
        if options.enableFileSharing {
            plist["UIFileSharingEnabled"] = true
            plist["UISupportsDocumentBrowser"] = true
            plist["LSSupportsOpeningDocumentsInPlace"] = true
        }
        if options.removeURLSchemes {
            plist.removeObject(forKey: "CFBundleURLTypes")
        }
        if options.forceFullScreen {
            plist["UIRequiresFullScreen"] = true
        }
        switch options.interfaceStyle {
        case .unchanged: break
        case .classic: plist["UIDesignRequiresCompatibility"] = true
        case .liquidGlass: plist["UIDesignRequiresCompatibility"] = false
        }
        let minOS = options.minimumOSVersion.trimmingCharacters(in: .whitespaces)
        if !minOS.isEmpty {
            plist["MinimumOSVersion"] = minOS
        }
        // Keep CFBundleVersion in sync so iOS treats the install as the version shown.
        let version = options.version.trimmingCharacters(in: .whitespaces)
        if !version.isEmpty {
            plist["CFBundleShortVersionString"] = version
        }
        guard plist.write(to: url, atomically: true) else {
            throw AppError("Couldn't write Info.plist.")
        }
    }

    /// Replaces the home screen icon by writing loose PNGs and pointing CFBundleIcons at them.
    /// Dropping CFBundleIconName stops iOS from preferring the compiled Assets.car icon.
    private func applyIcon(_ data: Data, to appURL: URL) throws {
        guard let image = UIImage(data: data) else { throw AppError("The selected icon isn't a valid image.") }
        let sizes: [(points: CGFloat, scale: CGFloat, suffix: String)] = [
            (60, 2, "60x60@2x"), (60, 3, "60x60@3x"),
            (76, 1, "76x76"), (76, 2, "76x76@2x"), (83.5, 2, "83.5x83.5@2x"),
        ]
        for size in sizes {
            let pixels = size.points * size.scale
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            }
            try rendered.pngData()?.write(to: appURL.appendingPathComponent("SignerIcon\(size.suffix).png"))
        }

        let url = appURL.appendingPathComponent("Info.plist")
        guard let plist = NSMutableDictionary(contentsOf: url) else { return }
        plist["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["SignerIcon60x60"]]]
        plist["CFBundleIcons~ipad"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["SignerIcon60x60", "SignerIcon76x76", "SignerIcon83.5x83.5"]]]
        plist.removeObject(forKey: "CFBundleIconFile")
        plist.removeObject(forKey: "CFBundleIconFiles")
        plist.write(to: url, atomically: true)
    }

    // MARK: - Mach-O

    /// Applies the arm64e ABI fix to every dylib and framework binary in the bundle.
    private func fixLegacyARM64ESlices(in appURL: URL, log: (String) -> Void) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        var fixed: [String] = []
        for case let url as URL in walker {
            // Files that aren't Mach-O (Info.plist, resources) are left alone by the fix.
            let inFramework = url.deletingLastPathComponent().pathExtension == "framework"
            guard url.pathExtension == "dylib" || inFramework,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if try MachO.fixLegacyARM64ESlices(in: url) { fixed.append(url.lastPathComponent) }
        }
        if !fixed.isEmpty { log("Fixed legacy arm64e slices in \(fixed.joined(separator: ", "))") }
    }

    // MARK: - Entitlements

    /// Writes the profile's entitlements merged with the app's own, or returns nil if the app has none.
    private func mergedEntitlements(for executable: URL, certificate: CertificateRecord, into folder: URL) throws -> URL? {
        guard let appEntitlements = try MachO.entitlements(of: executable), !appEntitlements.isEmpty else { return nil }
        let profile = try ProvisioningProfile(url: certificate.profileURL)
        let merged = EntitlementsMerger.merge(profile: profile.entitlements, app: appEntitlements, teamID: profile.teamID)
        let url = folder.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: merged, format: .xml, options: 0).write(to: url)
        return url
    }

    /// zsign only replaces the app's own profile, so extensions would keep the original developer's
    /// `embedded.mobileprovision` and iOS would refuse to install the app. Give each nested bundle ours.
    static func replaceNestedProfiles(in appURL: URL, with profile: URL, remove: Bool) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in walker where item.lastPathComponent == "embedded.mobileprovision" {
            guard item.deletingLastPathComponent().standardizedFileURL != appURL.standardizedFileURL else { continue }
            try fm.removeItem(at: item)
            if !remove { try fm.copyItem(at: profile, to: item) }
        }
    }
}
