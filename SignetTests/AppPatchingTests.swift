import XCTest
import ZIPFoundation
import Zsign
@testable import Signet

/// Tests for the options that change what's inside the app: interface style, removals, names and plist switches.
final class AppPatchingTests: XCTestCase {
    override func setUp() {
        Paths.prepare()
        CryptoSetup.loadProviders()
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> URL {
        let folder = Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)
        guard let url = folder?.appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name). Run scripts/make-test-fixtures.sh first.")
        }
        return url
    }

    /// Imports the fixture app, lets `prepare` change its files, signs it with `options` and returns the unpacked app.
    private func sign(_ options: SigningOptions, prepare: (URL) throws -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        addTeardownBlock {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }
        try prepare(source.appURL)
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        let out = try Paths.newTempDirectory()
        addTeardownBlock {
            try? fm.removeItem(at: signed.directory)
            try? fm.removeItem(at: out)
        }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        return out.appendingPathComponent("Payload/Fixture.app")
    }

    private func infoPlist(_ app: URL) throws -> [String: Any] {
        try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any])
    }

    // MARK: - Interface style

    func testVersionPacking() {
        XCTAssertEqual(MachO.packVersion("26.0"), 0x001a_0000)
        XCTAssertEqual(MachO.packVersion("18.4.1"), 0x0012_0401)
        XCTAssertEqual(MachO.packVersion("17"), 0x0011_0000)
        XCTAssertNil(MachO.packVersion("26.x"))
        XCTAssertNil(MachO.packVersion("1.2.3.4"))
        XCTAssertNil(MachO.packVersion("1.256"))
        XCTAssertEqual(MachO.unpackVersion(0x0012_0401), "18.4.1")
        XCTAssertEqual(MachO.unpackVersion(0x001a_0000), "26.0")
    }

    func testSetSDKVersionOnlyRaises() throws {
        let fm = FileManager.default
        let folder = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("Fixture")
        let app = folder.appendingPathComponent("Fixture.app")
        try fm.unzipItem(at: fixture("Fixture.ipa"), to: folder)
        try fm.moveItem(at: folder.appendingPathComponent("Payload/Fixture.app"), to: app)
        try fm.copyItem(at: app.appendingPathComponent("Fixture"), to: binary)

        XCTAssertTrue(try MachO.setSDKVersion(in: binary, to: "18.0", onlyRaise: false))
        XCTAssertEqual(try MachO.sdkVersion(of: binary), "18.0")
        XCTAssertFalse(try MachO.setSDKVersion(in: binary, to: "17.0"), "never lowers")
        XCTAssertEqual(try MachO.sdkVersion(of: binary), "18.0")
        XCTAssertTrue(try MachO.setSDKVersion(in: binary, to: "26.0"))
        XCTAssertEqual(try MachO.sdkVersion(of: binary), "26.0")
        XCTAssertFalse(try MachO.setSDKVersion(in: binary, to: "26.0"), "already set")
        XCTAssertThrowsError(try MachO.setSDKVersion(in: binary, to: "nope"))
    }

    func testLiquidGlassRaisesSDKAndSetsPlist() async throws {
        var options = SigningOptions()
        options.interfaceStyle = .liquidGlass
        let app = try await sign(options) { app in
            try MachO.setSDKVersion(in: app.appendingPathComponent("Fixture"), to: "18.0", onlyRaise: false)
        }
        XCTAssertEqual(try infoPlist(app)["UIDesignRequiresCompatibility"] as? Bool, false)
        XCTAssertEqual(try MachO.sdkVersion(of: app.appendingPathComponent("Fixture")), "26.0")
    }

    func testClassicKeepsSDKAndSetsPlist() async throws {
        var options = SigningOptions()
        options.interfaceStyle = .classic
        let app = try await sign(options) { app in
            try MachO.setSDKVersion(in: app.appendingPathComponent("Fixture"), to: "18.0", onlyRaise: false)
        }
        XCTAssertEqual(try infoPlist(app)["UIDesignRequiresCompatibility"] as? Bool, true)
        XCTAssertEqual(try MachO.sdkVersion(of: app.appendingPathComponent("Fixture")), "18.0")
    }

    func testInterfaceStyleIsNotSavedAsDefault() {
        var options = SigningOptions()
        options.interfaceStyle = .liquidGlass
        XCTAssertEqual(options.asDefaults.interfaceStyle, .unchanged)
    }

    // MARK: - Removing parts

    private func addExtensions(to app: URL) throws {
        let fm = FileManager.default
        for path in ["PlugIns/Share.appex", "PlugIns/Widget.appex", "Extensions/Intents.appex"] {
            let appex = app.appendingPathComponent(path, isDirectory: true)
            try fm.createDirectory(at: appex, withIntermediateDirectories: true)
            let name = appex.deletingPathExtension().lastPathComponent
            let plist: [String: Any] = ["CFBundleIdentifier": "com.example.fixture.\(name)", "CFBundleExecutable": name]
            (plist as NSDictionary).write(to: appex.appendingPathComponent("Info.plist"), atomically: true)
            try fm.copyItem(at: app.appendingPathComponent("Fixture"), to: appex.appendingPathComponent(name))
        }
        try fm.copyItem(at: fixture("FixtureTweak.dylib"), to: app.appendingPathComponent("Frameworks/Loose.dylib"))
    }

    func testListsRemovableItems() throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? fm.removeItem(at: source.directory) }
        try addExtensions(to: source.appURL)

        let items = Signer.removableItems(in: source.appURL)
        XCTAssertEqual(items.map(\.path), ["PlugIns/Share.appex", "PlugIns/Widget.appex", "Extensions/Intents.appex",
                                           "Frameworks/Helper.framework", "Frameworks/Loose.dylib"])
        XCTAssertEqual(items.map(\.kind), [.appExtension, .appExtension, .appExtension, .framework, .library])
        XCTAssertFalse(items.contains(where: \.isLinked), "the fixture executable links neither")
    }

    func testRemovesChosenItemsOnly() async throws {
        var options = SigningOptions()
        options.removePaths = ["PlugIns/Share.appex", "Frameworks/Helper.framework"]
        let app = try await sign(options) { try self.addExtensions(to: $0) }
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("PlugIns/Share.appex").path))
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("Frameworks/Helper.framework").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("PlugIns/Widget.appex").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("Extensions/Intents.appex").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("Frameworks/Loose.dylib").path))
    }

    func testRemovalPathsCantEscapeTheApp() {
        let app = URL(fileURLWithPath: "/tmp/x/Payload/A.app")
        XCTAssertNotNil(Signer.removableURL("PlugIns/Share.appex", in: app))
        XCTAssertNil(Signer.removableURL("../../Documents", in: app))
        XCTAssertNil(Signer.removableURL("PlugIns/../..", in: app))
        XCTAssertNil(Signer.removableURL("/etc", in: app))
        XCTAssertNil(Signer.removableURL("", in: app))
        XCTAssertNil(Signer.removableURL(".", in: app))
    }

    func testEscapingRemovalPathFailsSigning() async throws {
        var options = SigningOptions()
        options.removePaths = ["../../escape"]
        do {
            _ = try await sign(options)
            XCTFail("signing should fail")
        } catch let error as AppError {
            XCTAssertTrue(error.localizedDescription.contains("isn't inside the app"))
        }
    }

    // MARK: - Localized names

    func testRenameUpdatesLocalizedNames() async throws {
        var options = SigningOptions()
        options.appName = "Renamed"
        let app = try await sign(options) { app in
            let fm = FileManager.default
            for language in ["en", "fr", "ja", "de"] {
                try fm.createDirectory(at: app.appendingPathComponent("\(language).lproj"), withIntermediateDirectories: true)
            }
            // Text .strings as Xcode writes them, UTF-16 as older projects use, a binary plist, and a broken file.
            try Data("/* Name */\n\"CFBundleDisplayName\" = \"Fixture\";\n\"NSCameraUsageDescription\" = \"Camera\";\n".utf8)
                .write(to: app.appendingPathComponent("en.lproj/InfoPlist.strings"))
            try XCTUnwrap("\"CFBundleName\" = \"Fixture FR\";".data(using: .utf16))
                .write(to: app.appendingPathComponent("fr.lproj/InfoPlist.strings"))
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": "フィクスチャ"], format: .binary, options: 0)
                .write(to: app.appendingPathComponent("ja.lproj/InfoPlist.strings"))
            try Data("not = valid = strings".utf8).write(to: app.appendingPathComponent("de.lproj/InfoPlist.strings"))
        }

        func strings(_ language: String) throws -> [String: String]? {
            let data = try Data(contentsOf: app.appendingPathComponent("\(language).lproj/InfoPlist.strings"))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        }
        XCTAssertEqual(try strings("en"), ["CFBundleDisplayName": "Renamed", "NSCameraUsageDescription": "Camera"])
        XCTAssertEqual(try strings("fr"), ["CFBundleName": "Renamed", "CFBundleDisplayName": "Renamed"])
        XCTAssertEqual(try strings("ja"), ["CFBundleDisplayName": "Renamed"])
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("de.lproj/InfoPlist.strings")),
                       Data("not = valid = strings".utf8), "unreadable files are left alone")
    }

    func testLocalizedNamesUntouchedWithoutRename() async throws {
        let original = Data("\"CFBundleDisplayName\" = \"Fixture\";".utf8)
        let app = try await sign(SigningOptions()) { app in
            try FileManager.default.createDirectory(at: app.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
            try original.write(to: app.appendingPathComponent("en.lproj/InfoPlist.strings"))
        }
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("en.lproj/InfoPlist.strings")), original)
    }

    // MARK: - Info.plist switches

    func testAppearanceAndDisplaySwitches() async throws {
        var options = SigningOptions()
        options.appearance = .dark
        options.enableProMotion = true
        options.enableGameMode = true
        let plist = try infoPlist(try await sign(options))
        XCTAssertEqual(plist["UIUserInterfaceStyle"] as? String, "Dark")
        XCTAssertEqual(plist["CADisableMinimumFrameDurationOnPhone"] as? Bool, true)
        XCTAssertEqual(plist["GCSupportsGameMode"] as? Bool, true)
        XCTAssertEqual(options.asDefaults.appearance, .unchanged, "appearance is per app")
        XCTAssertTrue(options.asDefaults.enableProMotion, "display switches are saved as defaults")
    }

    func testSwitchesOffLeavePlistAlone() async throws {
        let plist = try infoPlist(try await sign(SigningOptions()))
        XCTAssertNil(plist["UIUserInterfaceStyle"])
        XCTAssertNil(plist["CADisableMinimumFrameDurationOnPhone"])
        XCTAssertNil(plist["GCSupportsGameMode"])
        XCTAssertNil(plist["UIDesignRequiresCompatibility"])
    }

    func testOlderSavedDefaultsStillDecode() {
        let json = #"{"enableFileSharing": true, "ppqSuffix": "abc123"}"#
        let options = SigningOptions.decodeDefaults(from: Data(json.utf8))
        XCTAssertTrue(options.enableFileSharing)
        XCTAssertEqual(options.ppqSuffix, "abc123")
        XCTAssertFalse(options.enableProMotion)
        XCTAssertEqual(options.interfaceStyle, .unchanged)
        XCTAssertEqual(options.removePaths, [])
    }

    // MARK: - Tweaks in extensions

    func testAddRPathAppendsOnce() throws {
        let fm = FileManager.default
        let folder = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("Tweak.dylib")
        try fm.copyItem(at: fixture("FixtureTweak.dylib"), to: binary)
        let before = try MachO.linkedDylibs(of: binary)

        XCTAssertTrue(try MachO.addRPath("@executable_path/../../Frameworks", to: binary))
        XCTAssertFalse(try MachO.addRPath("@executable_path/../../Frameworks", to: binary), "already there")
        XCTAssertEqual(try MachO.rpaths(of: binary).filter { $0 == "@executable_path/../../Frameworks" }.count, 1)
        XCTAssertEqual(try MachO.linkedDylibs(of: binary), before, "other load commands are untouched")
        XCTAssertEqual(Zsign.listDylibs(appExecutable: binary.path), before, "zsign still parses the file")
    }

    func testInjectsIntoExtensionsWhenAsked() async throws {
        var options = SigningOptions()
        options.injectFiles = [try fixture("FixtureTweak.dylib")]
        options.injectIntoExtensions = true
        let app = try await sign(options) { try self.addExtensions(to: $0) }
        for path in ["PlugIns/Share.appex/Share", "PlugIns/Widget.appex/Widget", "Extensions/Intents.appex/Intents"] {
            let executable = app.appendingPathComponent(path)
            XCTAssertTrue(try MachO.linkedDylibs(of: executable).contains("@rpath/FixtureTweak.dylib"), path)
            XCTAssertTrue(try MachO.rpaths(of: executable).contains("@executable_path/../../Frameworks"), path)
            XCTAssertTrue(Zsign.checkSigned(appExecutable: executable.path), path)
        }
        XCTAssertTrue(try MachO.linkedDylibs(of: app.appendingPathComponent("Fixture")).contains("@rpath/FixtureTweak.dylib"))
    }

    func testExtensionsUntouchedByDefault() async throws {
        var options = SigningOptions()
        options.injectFiles = [try fixture("FixtureTweak.dylib")]
        let app = try await sign(options) { try self.addExtensions(to: $0) }
        let executable = app.appendingPathComponent("PlugIns/Share.appex/Share")
        XCTAssertFalse(try MachO.linkedDylibs(of: executable).contains("@rpath/FixtureTweak.dylib"))
    }

    func testRemovedExtensionsAreNotInjected() async throws {
        var options = SigningOptions()
        options.injectFiles = [try fixture("FixtureTweak.dylib")]
        options.injectIntoExtensions = true
        options.removePaths = ["PlugIns/Share.appex"]
        let app = try await sign(options) { try self.addExtensions(to: $0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("PlugIns/Share.appex").path))
        XCTAssertTrue(try MachO.linkedDylibs(of: app.appendingPathComponent("PlugIns/Widget.appex/Widget"))
            .contains("@rpath/FixtureTweak.dylib"))
    }

    // MARK: - Icons

    func testFindsLooseAlternateIcons() throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? fm.removeItem(at: source.directory) }
        let app = source.appURL
        let primary = try XCTUnwrap(AppImporter.largestIcon(in: app)?.pngData())
        try primary.write(to: app.appendingPathComponent("DarkIcon60x60@2x.png"))
        try primary.write(to: app.appendingPathComponent("Retro@3x.png"))
        let plistURL = app.appendingPathComponent("Info.plist")
        let plist = try XCTUnwrap(NSMutableDictionary(contentsOf: plistURL))
        var icons = plist["CFBundleIcons"] as? [String: Any] ?? [:]
        icons["CFBundleAlternateIcons"] = [
            "Dark": ["CFBundleIconFiles": ["DarkIcon60x60"]],
            "Retro": [String: Any](),          // named only by its key
            "Catalog": ["CFBundleIconName": "CatalogOnly"], // only in Assets.car, so skipped
        ]
        plist["CFBundleIcons"] = icons
        plist.write(to: plistURL, atomically: true)

        XCTAssertEqual(AppImporter.alternateIcons(in: app).map(\.name), ["Dark", "Retro"])
    }

    func testNoAlternateIcons() throws {
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? FileManager.default.removeItem(at: source.directory) }
        XCTAssertTrue(AppImporter.alternateIcons(in: source.appURL).isEmpty)
    }
}
