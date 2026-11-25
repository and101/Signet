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
        try run(source, certificate: certificate, options: options, log: log)
    }

    /// Applies every change except signing and saves the IPA to Documents/Exports, for signing somewhere else.
    /// Custom and merged entitlements need a signature, so they're skipped.
    func exportModified(
        _ source: LibraryApp,
        options: SigningOptions,
        log: @escaping @Sendable (String) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let result = try run(source, certificate: nil, options: options, log: log)
        defer { try? fm.removeItem(at: result.directory) }
        try fm.createDirectory(at: Paths.exports, withIntermediateDirectories: true)
        let safeName = LibraryApp.safeFileComponent(result.name)
        let safeVersion = LibraryApp.safeFileComponent(result.version)
        var destination = Paths.exports.appendingPathComponent("\(safeName)_\(safeVersion)_unsigned.ipa")
        var copy = 2
        while fm.fileExists(atPath: destination.path) {
            destination = Paths.exports.appendingPathComponent("\(safeName)_\(safeVersion)_unsigned \(copy).ipa")
            copy += 1
        }
        try fm.moveItem(at: result.ipaURL, to: destination)
        return destination
    }

    /// The pipeline. With no certificate it modifies the app but doesn't sign it.
    private func run(
        _ source: LibraryApp,
        certificate: CertificateRecord?,
        options: SigningOptions,
        log: @escaping @Sendable (String) -> Void
    ) throws -> LibraryApp {
        let fm = FileManager.default
        try source.validateAppFolder(in: source.directory)
        guard fm.fileExists(atPath: source.appURL.path) else {
            throw AppError("The original app files are missing. Re-import the IPA.")
        }
        if let certificate {
            // The saved flag may be stale (a profile replaced since, or a record restored by 1.1), so a mismatch is
            // re-checked against the files; it only stands if they can't be read.
            if certificate.certificateMatchesProfile == false {
                let current = (try? ProvisioningProfile(url: certificate.profileURL)).flatMap {
                    CertificateImporter.certificateMatches(p12: certificate.p12URL, password: certificate.password, profile: $0)
                }
                guard current ?? false else {
                    throw AppError("The signing certificate isn't included in this provisioning profile. Import a matching pair.")
                }
            }
            guard fm.fileExists(atPath: certificate.p12URL.path), fm.fileExists(atPath: certificate.profileURL.path) else {
                throw AppError("The certificate files are missing. Re-import the certificate.")
            }
        }
        let requestedID = options.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        // With no bundle ID chosen, keep the app's own, moved into a wildcard profile's namespace if needed and
        // with the PPQ suffix for profiles that have Apple check apps at launch.
        let effectiveID = requestedID.isEmpty
            ? (certificate?.bundleID(for: source.bundleID, options: options) ?? source.bundleID)
            : requestedID
        // zsign fails on a wildcard mismatch, so block those. Exact App IDs are applied as the profile's
        // entitlements while the app keeps the chosen bundle ID, matching Feather.
        if let certificate, certificate.rejects(bundleID: effectiveID) {
            throw AppError("The bundle ID must match your profile: \(certificate.bundleIDPattern).")
        }

        var result = source
        result.id = UUID()
        result.kind = .signed
        result.dateAdded = Date()
        result.originalAppID = source.id
        result.originalBundleID = source.kind == .signed ? (source.originalBundleID ?? source.bundleID) : source.bundleID
        result.certificateID = certificate?.id
        result.certificateName = certificate?.nickname

        do {
            try fm.createDirectory(at: result.payloadURL, withIntermediateDirectories: true)
            log(String(localized: "Copying \(source.appFolderName)…"))
            try fm.copyItem(at: source.appURL, to: result.appURL)
            let appURL = result.appURL
            // Library entries from older versions or backups weren't checked at import.
            try AppImporter.validateForSigning(appURL)

            log(String(localized: "Patching Info.plist…"))
            try patchInfoPlist(at: appURL, options: options)
            let newName = options.appName.trimmingCharacters(in: .whitespaces)
            if !newName.isEmpty {
                Self.renameLocalizations(in: appURL, to: newName)
            }

            if let icon = options.customIcon {
                log(String(localized: "Applying custom icon…"))
                try applyIcon(icon, to: appURL)
            }

            if options.removePlugins {
                log(String(localized: "Removing app extensions…"))
                for folder in ["PlugIns", "Extensions"] {
                    try? fm.removeItem(at: appURL.appendingPathComponent(folder))
                }
            }
            for path in options.removePaths {
                guard let url = Self.removableURL(path, in: appURL) else {
                    throw AppError("Can't remove \(path): it isn't inside the app.")
                }
                log(String(localized: "Removing \(path)…"))
                try? fm.removeItem(at: url)
            }
            if options.removeWatchApp {
                log(String(localized: "Removing Watch app…"))
                for folder in ["Watch", "com.apple.WatchPlaceholder"] {
                    try? fm.removeItem(at: appURL.appendingPathComponent(folder))
                }
            }

            try TweakInjector(appURL: appURL, options: options, log: log).run()
            try fixLegacyARM64ESlices(in: appURL, log: log)
            if options.interfaceStyle == .liquidGlass, let executable = AppImporter.mainExecutable(of: appURL) {
                log(String(localized: "Enabling Liquid Glass…"))
                try MachO.setSDKVersion(in: executable, to: Self.liquidGlassSDK)
            }

            // A document group the profile still grants (same team, new bundle ID) keeps working as it is.
            let grantedGroups = certificate.flatMap { try? ProvisioningProfile(url: $0.profileURL) }
                .flatMap { $0.entitlements["com.apple.security.application-groups"] as? [String] } ?? []
            try Self.rewriteExtensionKit(in: appURL, from: source.bundleID, to: effectiveID, keeping: Set(grantedGroups))

            var entitlementsPath = ""
            var mergedFile = false
            if let certificate {
                if let custom = options.entitlementsFile {
                    _ = try EntitlementsMerger.read(custom) // fail early with a clear message
                    log(String(localized: "Using custom entitlements from \(custom.lastPathComponent)…"))
                    entitlementsPath = custom.path
                } else if options.mergeEntitlements, let executable = AppImporter.mainExecutable(of: source.appURL) {
                    if let url = try mergedEntitlements(for: executable, certificate: certificate, into: result.directory) {
                        log(String(localized: "Merging the app's entitlements…"))
                        entitlementsPath = url.path
                        mergedFile = true
                    } else {
                        log(String(localized: "The app has no entitlements to merge. Using the profile's."))
                    }
                }

                try Self.replaceNestedProfiles(in: appURL, with: certificate.profileURL,
                                               remove: options.removeProvisioningFile)
                // Tweaks and frameworks added since the first check are bundles and links too.
            try AppImporter.validateForSigning(appURL)
            log(String(localized: "Signing with \(certificate.nickname)…"))
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
                    throw AppError("Signing failed. Check that Apple issued the certificate and that it isn't revoked.")
                }
            } else {
                log(String(localized: "Applying changes without signing…"))
                try Self.applyIdentity(in: appURL, from: source.bundleID, to: effectiveID,
                                       name: options.appName.trimmingCharacters(in: .whitespaces),
                                       version: options.version.trimmingCharacters(in: .whitespaces))
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

            log(String(localized: "Packaging IPA…"))
            try fm.zipItem(
                at: result.payloadURL,
                to: result.ipaURL,
                shouldKeepParent: true,
                compressionMethod: options.compressIPA ? .deflate : .none
            )
            try fm.removeItem(at: result.payloadURL)
            if mergedFile { try? fm.removeItem(atPath: entitlementsPath) } // never the user's own file
            if certificate != nil { result.signingOptionsData = try Self.remember(options, for: result) }
            result.size = fm.fileSize(at: result.ipaURL)
            log(String(localized: "Done — \(result.size.formattedBytes)"))
            return result
        } catch {
            try? fm.removeItem(at: result.directory)
            throw error
        }
    }

    // MARK: - Unsigned changes

    /// What zsign does to Info.plist files when it signs: a new bundle ID for the app and, by prefix, its
    /// extensions and Watch app; a new display name; a new version. Used when exporting without signing.
    static func applyIdentity(in appURL: URL, from oldID: String, to newID: String, name: String, version: String) throws {
        let fm = FileManager.default
        func update(_ plistURL: URL, isMain: Bool) throws {
            guard let plist = NSMutableDictionary(contentsOf: plistURL) else { return }
            if newID != oldID {
                // The app's own ID, or one under it (com.app.widget), but not com.appother.
                func renamed(_ value: Any?) -> String? {
                    guard let value = value as? String, value == oldID || value.hasPrefix(oldID + ".") else { return nil }
                    return newID + value.dropFirst(oldID.count)
                }
                if let id = renamed(plist["CFBundleIdentifier"]) { plist["CFBundleIdentifier"] = id }
                if let id = renamed(plist["WKCompanionAppBundleIdentifier"]) { plist["WKCompanionAppBundleIdentifier"] = id }
                if let ext = (plist["NSExtension"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary,
                   let attributes = (ext["NSExtensionAttributes"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary,
                   let id = renamed(attributes["WKAppBundleIdentifier"]) {
                    attributes["WKAppBundleIdentifier"] = id
                    ext["NSExtensionAttributes"] = attributes
                    plist["NSExtension"] = ext
                }
            }
            if isMain, !name.isEmpty {
                plist["CFBundleDisplayName"] = name
                plist["CFBundleName"] = name
            }
            if isMain, !version.isEmpty {
                plist["CFBundleVersion"] = version
                plist["CFBundleShortVersionString"] = version
            }
            guard plist.write(to: plistURL, atomically: true) else {
                throw AppError("Couldn't write \(plistURL.deletingLastPathComponent().lastPathComponent)/Info.plist.")
            }
        }
        try update(appURL.appendingPathComponent("Info.plist"), isMain: true)
        guard let walker = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where ["appex", "app"].contains(url.pathExtension) {
            try update(url.appendingPathComponent("Info.plist"), isMain: false)
        }
    }

    /// Only app-owned extension point names change. Apple's system extension points retain their names.
    /// A File Provider's document group (`group.<old ID>…`) is renamed the same way, unless it's in `keeping` (groups
    /// the signing profile grants); zsign leaves it alone, and another team's profile can never grant the original.
    static func rewriteExtensionKit(in appURL: URL, from oldID: String, to newID: String, keeping: Set<String> = []) throws {
        guard oldID != newID, !oldID.isEmpty else { return }
        func renamed(_ id: String) -> String {
            id == oldID || id.hasPrefix(oldID + ".") ? newID + id.dropFirst(oldID.count) : id
        }
        guard let walker = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            let parent = url.deletingLastPathComponent()
            let bundleInfo = url.lastPathComponent == "Info.plist" && (parent == appURL || ["app", "appex"].contains(parent.pathExtension))
            guard bundleInfo || ["appexpt", "appext"].contains(url.pathExtension) else { continue }
            // Read at most 4 MiB plus one byte, irrespective of a racing or dishonest file-size value.
            let reader = try FileHandle(forReadingFrom: url)
            let data: Data
            do { data = try reader.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data(); try reader.close() }
            catch { try? reader.close(); throw error }
            guard data.count <= 4 * 1024 * 1024 else {
                throw AppError("Extension metadata in \(url.lastPathComponent) exceeds the size limit.")
            }
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard var plist = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
                throw AppError("Couldn't read extension metadata in \(url.lastPathComponent).")
            }
            var changed = false
            if url.lastPathComponent == "Info.plist" {
                if var attrs = plist["EXAppExtensionAttributes"] as? [String: Any],
                   let id = attrs["EXExtensionPointIdentifier"] as? String, renamed(id) != id {
                    attrs["EXExtensionPointIdentifier"] = renamed(id)
                    plist["EXAppExtensionAttributes"] = attrs
                    changed = true
                }
                if var ext = plist["NSExtension"] as? [String: Any],
                   let group = ext["NSExtensionFileProviderDocumentGroup"] as? String, group.hasPrefix("group."),
                   !keeping.contains(group),
                   case let id = String(group.dropFirst("group.".count)), renamed(id) != id {
                    ext["NSExtensionFileProviderDocumentGroup"] = "group." + renamed(id)
                    plist["NSExtension"] = ext
                    changed = true
                }
            } else {
                var declarations: [String: Any] = [:]
                for (key, value) in plist {
                    let replacement = renamed(key)
                    guard declarations[replacement] == nil else {
                        throw AppError("Renaming would create duplicate extension point identifiers.")
                    }
                    declarations[replacement] = value
                    changed = changed || replacement != key
                }
                plist = declarations
            }
            if changed {
                try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Remembering options

    /// Keeps the options next to the signed app so an update can be signed the same way:
    /// tweaks are copied into its Tweaks folder and a custom icon into custom-icon.png.
    static func remember(_ options: SigningOptions, for app: LibraryApp) throws -> Data {
        let fm = FileManager.default
        if !options.injectFiles.isEmpty {
            try fm.createDirectory(at: app.tweaksURL, withIntermediateDirectories: true)
            for file in options.injectFiles {
                // Same-named tweaks overwrite each other in Frameworks too, so the last one wins here as well.
                let destination = app.tweaksURL.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: file, to: destination)
            }
        }
        if let icon = options.customIcon {
            try icon.write(to: app.customIconURL)
        }
        if let entitlements = options.entitlementsFile, entitlements.standardizedFileURL != app.customEntitlementsURL.standardizedFileURL {
            try? fm.removeItem(at: app.customEntitlementsURL)
            try fm.copyItem(at: entitlements, to: app.customEntitlementsURL)
        }
        var stored = options
        stored.customIcon = nil
        stored.entitlementsFile = nil
        // Rules live in Settings; a stale copy here would bring back deleted rules or drop new ones.
        stored.bundleIDRules = []
        stored.nameRules = []
        // Only the names, in the order they were injected; the files themselves are in the Tweaks folder.
        var names = Set<String>()
        stored.injectFiles = options.injectFiles.map(\.lastPathComponent).filter { names.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
        return try JSONEncoder().encode(stored)
    }

    // MARK: - Removing parts

    struct RemovableItem: Hashable {
        enum Kind { case appExtension, framework, library }
        /// Relative to the .app, e.g. `PlugIns/Share.appex`.
        let path: String
        let kind: Kind
        /// The main executable links it, so removing it makes the app crash at launch.
        let isLinked: Bool
    }

    /// App extensions, frameworks and loose dylibs that can be removed one by one.
    static func removableItems(in appURL: URL) -> [RemovableItem] {
        let fm = FileManager.default
        let linked = AppImporter.mainExecutable(of: appURL).flatMap { try? MachO.linkedDylibs(of: $0) } ?? []
        func isLinked(_ name: String) -> Bool {
            linked.contains { $0.hasPrefix("@rpath/\(name)/") || $0 == "@rpath/\(name)"
                || $0.hasSuffix("/Frameworks/\(name)") || $0.contains("/Frameworks/\(name)/") }
        }
        var items: [RemovableItem] = []
        for folder in ["PlugIns", "Extensions"] {
            let names = (try? fm.contentsOfDirectory(atPath: appURL.appendingPathComponent(folder).path)) ?? []
            for name in names.sorted() where name.hasSuffix(".appex") {
                items.append(RemovableItem(path: "\(folder)/\(name)", kind: .appExtension, isLinked: false))
            }
        }
        let frameworks = (try? fm.contentsOfDirectory(atPath: appURL.appendingPathComponent("Frameworks").path)) ?? []
        for name in frameworks.sorted() {
            if name.hasSuffix(".framework") {
                items.append(RemovableItem(path: "Frameworks/\(name)", kind: .framework, isLinked: isLinked(name)))
            } else if name.hasSuffix(".dylib") {
                items.append(RemovableItem(path: "Frameworks/\(name)", kind: .library, isLinked: isLinked(name)))
            }
        }
        return items
    }

    /// Resolves a path chosen for removal, refusing anything that escapes the app or is the app itself.
    static func removableURL(_ path: String, in appURL: URL) -> URL? {
        let base = appURL.standardizedFileURL.path
        let url = appURL.appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, !path.hasPrefix("/"), url.path.hasPrefix(base + "/") else { return nil }
        return url
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
        if options.enableProMotion {
            plist["CADisableMinimumFrameDurationOnPhone"] = true
        }
        if options.enableGameMode {
            plist["GCSupportsGameMode"] = true
        }
        switch options.appearance {
        case .unchanged: break
        case .light: plist["UIUserInterfaceStyle"] = "Light"
        case .dark: plist["UIUserInterfaceStyle"] = "Dark"
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

    /// Sets the name in every language's InfoPlist.strings, which iOS shows instead of Info.plist's.
    /// Files that can't be read are left alone; CFBundleName is only replaced where the file already sets it.
    static func renameLocalizations(in appURL: URL, to name: String) {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.pathExtension == "lproj" {
            let url = folder.appendingPathComponent("InfoPlist.strings")
            guard let data = try? Data(contentsOf: url),
                  var strings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { continue }
            strings["CFBundleDisplayName"] = name
            if strings["CFBundleName"] != nil { strings["CFBundleName"] = name }
            if let output = try? PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0) {
                try? output.write(to: url, options: .atomic)
            }
        }
    }

    /// Replaces the home screen icon by writing loose PNGs and pointing CFBundleIcons at them.
    /// Dropping CFBundleIconName stops iOS from preferring the compiled Assets.car icon.
    private func applyIcon(_ data: Data, to appURL: URL) throws {
        // Normalised again here, so any size of photo works and nothing huge is ever fully decoded.
        guard let icon = IconImage.normalizedCustomIcon(data), let image = UIImage(data: icon) else {
            throw AppError("The selected icon isn't a valid image.")
        }
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
        if !fixed.isEmpty {
            let names = fixed.joined(separator: ", ")
            log(String(localized: "Fixed legacy arm64e slices in \(names)"))
        }
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
