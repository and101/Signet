import Foundation
import ZIPFoundation
import Zsign

/// Injects tweaks (.dylib, .framework, .deb) into an app bundle before signing.
///
/// - Tweak dylibs and frameworks are copied into `Frameworks/` and linked from the main executable.
/// - From a .deb, the tweak dylibs (`Library/MobileSubstrate/DynamicLibraries`, rootless `usr/lib/TweakInject`)
///   are injected; frameworks under `Library/Frameworks` and libraries under `usr/lib` are copied as
///   dependencies; `.bundle`s under `Library/Application Support` go to the app root. Rootful and rootless
///   (`var/jb/…`) layouts are both read.
/// - Jailbreak paths in the added binaries are rewritten to `@rpath`, and ElleKit is added as
///   `CydiaSubstrate.framework` when something links Substrate and the app doesn't already ship it.
struct TweakInjector {
    static let tweakExtensions: Set<String> = ["dylib", "framework", "deb"]

    /// Prepares a picked file for injection. A `.zip` is unpacked and every tweak in it is returned, because the
    /// Files picker can't hand over a `.framework` (a folder) directly. Other files are copied as they are.
    static func unpackPicked(_ url: URL) throws -> [URL] {
        guard url.pathExtension.lowercased() == "zip" else { return [try copyPickedFile(url)] }
        let folder = try Paths.newTempDirectory()
        do {
            try FileManager.default.unzipItem(at: url, to: folder)
        } catch {
            throw AppError("Couldn't unzip \(url.lastPathComponent).")
        }
        var found: [URL] = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let item = walker?.nextObject() as? URL {
            if item.pathComponents.contains("__MACOSX") { walker?.skipDescendants(); continue }
            if tweakExtensions.contains(item.pathExtension.lowercased()) {
                found.append(item)
                walker?.skipDescendants() // a framework's contents aren't separate tweaks
            }
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        guard !found.isEmpty else {
            throw AppError("\(url.lastPathComponent) has no .dylib, .framework or .deb.")
        }
        // Each tweak gets its own folder, so removing one from the list deletes only that one.
        return try found.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
            let destination = try Paths.newTempDirectory().appendingPathComponent(item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: destination)
            return destination
        }
    }

    let appURL: URL
    let options: SigningOptions
    let log: (String) -> Void

    private let fm = FileManager.default
    private var frameworks: URL { appURL.appendingPathComponent("Frameworks", isDirectory: true) }

    static let substratePath = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
    private static let substrateAliases = [
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/usr/lib/libsubstrate.dylib",
        "/usr/lib/libsubstitute.dylib",
        "/usr/lib/libellekit.dylib",
        "@rpath/libsubstrate.dylib",
        "@rpath/libellekit.dylib",
    ]

    private struct Plan {
        /// Binaries that get a load command in the main executable, as (file in the app, load path).
        var injected: [(binary: URL, loadPath: String)] = []
        /// Every binary added to the app, whose jailbreak paths get rewritten.
        var added: [URL] = []
        /// Jailbreak path → @rpath path for libraries copied out of .debs.
        var rewrites: [String: String] = [:]
    }

    func run() throws {
        guard !options.removeLoadCommands.isEmpty || !options.injectFiles.isEmpty else { return }
        guard let executable = AppImporter.mainExecutable(of: appURL) else {
            throw AppError("Couldn't find the app's main executable.")
        }

        if !options.removeLoadCommands.isEmpty {
            log(String(localized: "Removing \(options.removeLoadCommands.count) load command(s)…"))
            _ = Zsign.removeDylibs(appExecutable: executable.path, using: options.removeLoadCommands)
        }
        guard !options.injectFiles.isEmpty else { return }
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)

        var plan = Plan()
        let work = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: work) }
        for file in options.injectFiles {
            switch file.pathExtension.lowercased() {
            case "dylib": try addDylib(file, to: &plan)
            case "framework": try addFramework(file, inject: true, to: &plan)
            case "deb": try addDeb(file, work: work, to: &plan)
            default: throw AppError("\(file.lastPathComponent) isn't a .dylib, .framework or .deb.")
            }
        }

        if options.fixSubstratePaths {
            for binary in plan.added { try rewritePaths(in: binary, extra: plan.rewrites) }
        }

        // Tweaks are copied into Frameworks and loaded by @rpath; apps that embed no frameworks may not search there.
        do {
            try MachO.addRPath(Self.mainRPath, to: executable)
        } catch {
            log(String(localized: "Couldn't add a Frameworks run path to the app (\(error.localizedDescription)); tweaks may not load."))
        }
        for (binary, loadPath) in plan.injected {
            log(String(localized: "Injecting \(binary.lastPathComponent)…"))
            guard Zsign.injectDyLib(appExecutable: executable.path, with: loadPath, weak: options.weakInject) else {
                throw AppError("Failed to inject \(binary.lastPathComponent).")
            }
        }

        if options.injectIntoExtensions {
            for executable in extensionExecutables() {
                log(String(localized: "Injecting into \(executable.deletingLastPathComponent().lastPathComponent)…"))
                // Extensions sit two levels down; this lets @rpath reach the app's Frameworks folder.
                try MachO.addRPath(Self.extensionRPath, to: executable)
                for (binary, loadPath) in plan.injected {
                    guard Zsign.injectDyLib(appExecutable: executable.path, with: loadPath, weak: options.weakInject) else {
                        throw AppError("Failed to inject \(binary.lastPathComponent) into \(executable.lastPathComponent).")
                    }
                }
            }
        }

        if options.bundleElleKit, try needsSubstrate(plan.added) {
            try installElleKit()
        }
    }

    // MARK: - Inputs

    private func addDylib(_ file: URL, to plan: inout Plan) throws {
        let destination = frameworks.appendingPathComponent(file.lastPathComponent)
        try fm.replaceItem(at: destination, withCopyOf: file)
        plan.injected.append((destination, "@rpath/\(file.lastPathComponent)"))
        plan.added.append(destination)
    }

    private func addFramework(_ file: URL, inject: Bool, to plan: inout Plan) throws {
        let name = file.lastPathComponent
        let destination = frameworks.appendingPathComponent(name)
        try fm.replaceItem(at: destination, withCopyOf: file)
        let binaryName = Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            ?? file.deletingPathExtension().lastPathComponent
        guard let binary = AppImporter.file(named: binaryName, in: destination), fm.fileExists(atPath: binary.path) else {
            throw AppError("\(name) has no executable.")
        }
        if inject { plan.injected.append((binary, "@rpath/\(name)/\(binaryName)")) }
        plan.added.append(binary)
    }

    private func addDeb(_ file: URL, work: URL, to plan: inout Plan) throws {
        log(String(localized: "Extracting \(file.lastPathComponent)…"))
        let root = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try DebPackage.extract(file, to: root)
        var found = 0

        for prefix in ["", "var/jb/"] {
            let base = root.appendingPathComponent(prefix)
            for folder in ["Library/MobileSubstrate/DynamicLibraries", "usr/lib/TweakInject"] {
                for dylib in contents(of: base.appendingPathComponent(folder), withExtension: "dylib") {
                    try addDylib(dylib, to: &plan)
                    found += 1
                }
            }
            for framework in contents(of: base.appendingPathComponent("Library/Frameworks"), withExtension: "framework") {
                let name = framework.lastPathComponent
                let binary = framework.deletingPathExtension().lastPathComponent
                try addFramework(framework, inject: false, to: &plan)
                found += 1
                for jbRoot in ["", "/var/jb"] {
                    plan.rewrites["\(jbRoot)/Library/Frameworks/\(name)/\(binary)"] = "@rpath/\(name)/\(binary)"
                }
            }
            for library in contents(of: base.appendingPathComponent("usr/lib"), withExtension: "dylib") {
                let name = library.lastPathComponent
                let destination = frameworks.appendingPathComponent(name)
                try fm.replaceItem(at: destination, withCopyOf: library)
                plan.added.append(destination)
                found += 1
                for jbRoot in ["", "/var/jb"] { plan.rewrites["\(jbRoot)/usr/lib/\(name)"] = "@rpath/\(name)" }
            }
            let support = base.appendingPathComponent("Library/Application Support")
            for bundle in bundles(under: support) {
                try fm.replaceItem(at: appURL.appendingPathComponent(bundle.lastPathComponent), withCopyOf: bundle)
            }
        }
        guard found > 0 else { throw AppError("\(file.lastPathComponent) doesn't contain any dylibs or frameworks to inject.") }
    }

    static let extensionRPath = "@executable_path/../../Frameworks"
    static let mainRPath = "@executable_path/Frameworks"

    /// Main executables of the app's extensions (PlugIns and Extensions).
    func extensionExecutables() -> [URL] {
        ["PlugIns", "Extensions"].flatMap { contents(of: appURL.appendingPathComponent($0), withExtension: "appex") }
            .compactMap { AppImporter.mainExecutable(of: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private func contents(of folder: URL, withExtension ext: String) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func bundles(under folder: URL) -> [URL] {
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "bundle" {
            found.append(url)
            walker.skipDescendants()
        }
        return found
    }

    // MARK: - Paths and Substrate

    /// Tweaks built for jailbreaks link absolute paths that don't exist on a stock device;
    /// point them at @rpath so the copies in the app's Frameworks folder are used.
    private func rewritePaths(in binary: URL, extra: [String: String]) throws {
        var rewrites = extra
        for alias in Self.substrateAliases {
            rewrites[alias] = Self.substratePath
            if alias.hasPrefix("/") { rewrites["/var/jb" + alias] = Self.substratePath }
        }
        for linked in try MachO.linkedDylibs(of: binary) {
            guard let replacement = rewrites[linked] else { continue }
            try MachO.changeLinkedDylib(in: binary, from: linked, to: replacement)
        }
    }

    private func needsSubstrate(_ binaries: [URL]) throws -> Bool {
        let bundled = frameworks.appendingPathComponent("CydiaSubstrate.framework")
        guard !fm.fileExists(atPath: bundled.path) else { return false }
        return try binaries.contains { try MachO.linkedDylibs(of: $0).contains(Self.substratePath) }
    }

    private func installElleKit() throws {
        guard let archive = Bundle.main.url(forResource: "ElleKit", withExtension: "zip") else {
            throw AppError("ElleKit is missing from this build, so Substrate tweaks can't be injected.")
        }
        log(String(localized: "Adding ElleKit (CydiaSubstrate.framework)…"))
        try fm.unzipItem(at: archive, to: frameworks)
    }
}
