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
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw AppError("The app is missing its Info.plist.")
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
            try fm.unzipItem(at: ipa, to: work)
        } catch {
            throw AppError("Couldn't unzip the IPA: \(error.localizedDescription)")
        }

        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        guard let appFolder = try? fm.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
            throw AppError("This isn't a valid IPA.")
        }
        let appURL = payload.appendingPathComponent(appFolder, isDirectory: true)
        if let link = escapingSymlinks(in: appURL).first {
            throw AppError("This IPA contains a link that points outside the app (\(link)), so it wasn't imported.")
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
        let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
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
        let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
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
        return candidates
            .compactMap { UIImage(contentsOfFile: appURL.appendingPathComponent($0).path) }
            .max { $0.size.width * $0.scale < $1.size.width * $1.scale }
    }

    static func mainExecutable(of appURL: URL) -> URL? {
        let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any]
        guard let name = plist?["CFBundleExecutable"] as? String else { return nil }
        return file(named: name, in: appURL)
    }

    /// Symbolic links in an app that point outside it. Signing patches files in place, so following one could change
    /// a file elsewhere in Signet's storage. Returns their paths relative to the app.
    static func escapingSymlinks(in appURL: URL) -> [String] {
        let fm = FileManager.default
        let root = appURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var escaping: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target)
                            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target))
                .standardizedFileURL.path
            if resolved != root, !resolved.hasPrefix(root + "/") {
                escaping.append(String(url.path.dropFirst(appURL.path.count + 1)))
            }
        }
        return escaping
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
