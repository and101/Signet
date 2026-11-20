import Foundation
import UIKit
import ZIPFoundation

struct BundleInfo {
    let name: String
    let bundleID: String
    let version: String
    let build: String
    let minimumOSVersion: String?

    init(appURL: URL) throws {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let plist = AppImporter.readPlist(plistURL) else {
            throw AppError("The app is missing its Info.plist, or it's too large.")
        }
        name = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        bundleID = plist["CFBundleIdentifier"] as? String ?? "unknown"
        version = plist["CFBundleShortVersionString"] as? String ?? "1.0"
        build = plist["CFBundleVersion"] as? String ?? version
        minimumOSVersion = plist["MinimumOSVersion"] as? String
    }
}

enum AppImporter {
    /// Unzips an IPA into a new library entry.
    static func importIPA(at ipa: URL, sourceURL: String? = nil) throws -> LibraryApp {
        let fm = FileManager.default
        let work = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: work) }

        do {
            try ArchiveBudget.unzip(ipa, to: work)
        } catch {
            throw AppError("Couldn't unzip the IPA: \(error.localizedDescription)")
        }

        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        guard let appFolder = try? fm.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
            throw AppError("This isn't a valid IPA.")
        }
        let appURL = payload.appendingPathComponent(appFolder, isDirectory: true)
        if let link = escapingSymlinks(in: appURL).first {
            throw AppError("This IPA has a link pointing outside the app (\(link)), so it wasn't imported.")
        }
        let info = try BundleInfo(appURL: appURL)

        var app = LibraryApp(
            kind: .imported,
            name: info.name,
            bundleID: info.bundleID,
            version: info.version,
            build: info.build,
            minimumOSVersion: info.minimumOSVersion,
            appFolderName: appFolder,
            size: 0,
            sourceURL: sourceURL
        )
        try fm.createDirectory(at: app.directory, withIntermediateDirectories: true)
        try fm.moveItem(at: payload, to: app.payloadURL)
        app.size = fm.directorySize(at: app.payloadURL)
        saveIcon(from: app.appURL, to: app.iconURL)
        return app
    }

    /// Finds the largest icon PNG the bundle references and stores a normal PNG copy.
    /// iOS can decode Xcode's "crushed" CgBI PNGs, so re-encoding through UIImage makes them portable.
    static func saveIcon(from appURL: URL, to destination: URL) {
        guard let image = largestIcon(in: appURL), let data = image.pngData() else { return }
        try? data.write(to: destination)
    }

    static func largestIcon(in appURL: URL) -> UIImage? {
        let plist = AppImporter.readPlist(appURL.appendingPathComponent("Info.plist")) ?? [:]
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = plist[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                names += primary["CFBundleIconFiles"] as? [String] ?? []
                if let name = primary["CFBundleIconName"] as? String { names.append(name) }
            }
        }
        names += plist["CFBundleIconFiles"] as? [String] ?? []
        if let name = plist["CFBundleIconFile"] as? String { names.append(name) }
        names.append("AppIcon")
        return largestPNG(in: appURL, matching: names)
    }

    /// The app's alternate icons that ship as loose PNGs, largest image of each, sorted by name.
    /// Icons only inside the compiled Assets.car can't be read, so they're skipped.
    static func alternateIcons(in appURL: URL) -> [(name: String, image: UIImage)] {
        let plist = AppImporter.readPlist(appURL.appendingPathComponent("Info.plist")) ?? [:]
        var files: [String: [String]] = [:]
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = plist[key] as? [String: Any],
                  let alternates = icons["CFBundleAlternateIcons"] as? [String: Any] else { continue }
            for (name, value) in alternates {
                let entry = value as? [String: Any] ?? [:]
                var names = entry["CFBundleIconFiles"] as? [String] ?? []
                if let iconName = entry["CFBundleIconName"] as? String { names.append(iconName) }
                if names.isEmpty { names.append(name) }
                files[name, default: []] += names
            }
        }
        return files.keys.sorted().compactMap { name in
            largestPNG(in: appURL, matching: files[name]!).map { (name, $0) }
        }
    }

    private static func largestPNG(in appURL: URL, matching names: [String]) -> UIImage? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: appURL.path)) ?? []
        let candidates = files.filter { file in
            file.lowercased().hasSuffix(".png") && names.contains { file.hasPrefix($0) }
        }
        // Picked by the size in each file's header, and only that one is decoded: an IPA's PNG can be small on disk
        // and still decode to gigabytes, so ones over the limit are skipped.
        let best = candidates
            .compactMap { name -> (URL, Int)? in
                let url = appURL.appendingPathComponent(name)
                return IconImage.acceptableWidth(of: url).map { (url, $0) }
            }
            .max { $0.1 < $1.1 }
        return best.flatMap { UIImage(contentsOfFile: $0.0.path) }
    }

    static func mainExecutable(of appURL: URL) -> URL? {
        let plist = readPlist(appURL.appendingPathComponent("Info.plist"))
        guard let name = plist?["CFBundleExecutable"] as? String else { return nil }
        return file(named: name, in: appURL)
    }

    /// Symbolic links in an app that point outside it. Signing patches files in place, so following one could change
    /// a file elsewhere in Signet's storage. Returns their paths relative to the app.
    /// A link whose target can't be read counts as escaping, and so does a folder that can't be walked.
    static func escapingSymlinks(in appURL: URL) -> [String] {
        let fm = FileManager.default
        let root = appURL.resolvingSymlinksInPath().standardizedFileURL.path
        var unreadable = false
        guard let walker = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                         errorHandler: { _, _ in unreadable = true; return true }) else { return ["."] }
        var escaping: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else {
                escaping.append(String(url.path.dropFirst(appURL.path.count + 1)))
                continue
            }
            let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target)
                            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target))
                .standardizedFileURL.path
            if resolved != root, !resolved.hasPrefix(root + "/") {
                escaping.append(String(url.path.dropFirst(appURL.path.count + 1)))
            }
        }
        if unreadable { escaping.append(".") }
        return escaping
    }

    /// Checks an app before Signet patches or signs it: no link may lead outside it, and every bundle's executable
    /// (the app, its extensions and frameworks) must be a plain file name inside that bundle. zsign reads
    /// CFBundleExecutable itself, so this has to hold for every nested bundle, not only for Signet's own lookups.
    static func validateForSigning(_ appURL: URL) throws {
        if let link = escapingSymlinks(in: appURL).first {
            throw AppError("The app has a link pointing outside it (\(link)), so it can't be signed safely.")
        }
        let fm = FileManager.default
        var bundles = [appURL]
        if let walker = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) {
            // Every bundle type zsign signs, including .xctest.
            for case let url as URL in walker where ["app", "appex", "framework", "xctest"].contains(url.pathExtension.lowercased()) {
                bundles.append(url)
            }
        }
        for bundle in bundles {
            let plistURL = bundle.appendingPathComponent("Info.plist")
            // zsign and later steps read every bundle's Info.plist whole, so one that's too large stops here.
            if (try? fm.attributesOfItem(atPath: plistURL.path)) != nil, readPlist(plistURL) == nil {
                let relative = bundle == appURL ? appURL.lastPathComponent : String(bundle.path.dropFirst(appURL.path.count + 1))
                throw AppError("\(relative) has an unreadable or oversized Info.plist, so it can't be signed.")
            }
            let plist = readPlist(plistURL)
            guard let name = plist?["CFBundleExecutable"] as? String else { continue }
            let relative = bundle == appURL ? appURL.lastPathComponent : String(bundle.path.dropFirst(appURL.path.count + 1))
            guard let executable = file(named: name, in: bundle), executableStaysInside(executable, bundle: bundle) else {
                throw AppError("\(relative) points its executable outside itself (\"\(name)\"), so it can't be signed safely.")
            }
        }
    }

    /// A bundle's executable may be a link (e.g. into its own Versions folder), but it must end at a regular file
    /// inside that same bundle, not at a sibling bundle's binary elsewhere in the app. A missing one is left to the
    /// signing steps that need it. Both paths resolved exist, so they get the same /private handling.
    static func executableStaysInside(_ executable: URL, bundle: URL) -> Bool {
        let fm = FileManager.default
        guard let type = (try? fm.attributesOfItem(atPath: executable.path))?[.type] as? FileAttributeType else { return true }
        if type == .typeRegular { return true }
        guard type == .typeSymbolicLink else { return false }
        let target = executable.resolvingSymlinksInPath()
        guard (try? fm.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType == .typeRegular else { return false }
        return target.path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/")
    }

    static let plistLimit: Int64 = 4 * 1024 * 1024

    /// Reads a bundle's Info.plist if it's a regular file no larger than `plistLimit`. Extraction allows entries of
    /// gigabytes, and these are decoded whole into memory.
    /// A link is followed only to a regular file inside the same bundle (as macOS-style frameworks link Info.plist into
    /// their Versions folder); 1.1 read those too.
    static func readPlist(_ url: URL) -> [String: Any]? {
        let fm = FileManager.default
        guard var attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        var target = url
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            target = url.resolvingSymlinksInPath()
            let bundle = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard target.path.hasPrefix(bundle + "/"), let resolved = try? fm.attributesOfItem(atPath: target.path) else {
                return nil
            }
            attributes = resolved
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= plistLimit else { return nil }
        return NSDictionary(contentsOf: target) as? [String: Any]
    }

    /// A file directly inside a bundle. Names come from the bundle's Info.plist, which an IPA controls, so
    /// anything with a path in it ("../../x") is refused rather than patched outside the app.
    static func file(named name: String, in bundle: URL) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let url = bundle.appendingPathComponent(name).standardizedFileURL
        guard url.deletingLastPathComponent().path == bundle.standardizedFileURL.path else { return nil }
        return url
    }
}
