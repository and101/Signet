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
            try? FileManager.default.removeItem(at: source.directory)
            try? FileManager.default.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }
        try prepare(source.appURL)
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        let out = try Paths.newTempDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: signed.directory)
            try? FileManager.default.removeItem(at: out)
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
        XCTAssertTrue(try MachO.rpaths(of: app.appendingPathComponent("Fixture")).contains("@executable_path/Frameworks"),
                      "the app can find tweaks copied into Frameworks")
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

    // MARK: - Remembered options

    func testSignedAppRemembersItsOptions() async throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }
        var options = SigningOptions()
        options.appName = "Renamed"
        options.bundleID = "com.example.renamed"
        options.interfaceStyle = .classic
        options.removePaths = ["Frameworks/Helper.framework"]
        options.injectFiles = [try fixture("FixtureTweak.dylib")]
        options.customIcon = UIImage(contentsOfFile: source.iconURL.path)?.pngData()

        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        // Round-trip through the library index, as a relaunch would.
        let decoded = try JSONDecoder().decode(LibraryApp.self, from: JSONEncoder().encode(signed))
        let remembered = try XCTUnwrap(decoded.rememberedOptions)
        XCTAssertEqual(remembered.appName, "Renamed")
        XCTAssertEqual(remembered.bundleID, "com.example.renamed")
        XCTAssertEqual(remembered.interfaceStyle, .classic)
        XCTAssertEqual(remembered.removePaths, ["Frameworks/Helper.framework"])
        XCTAssertEqual(remembered.injectFiles.map(\.lastPathComponent), ["FixtureTweak.dylib"])
        XCTAssertEqual(remembered.injectFiles.first?.deletingLastPathComponent().lastPathComponent, "Tweaks",
                       "tweaks are kept with the signed app, not in temporary storage")
        XCTAssertEqual(remembered.customIcon, options.customIcon)
        XCTAssertFalse(String(decoding: try XCTUnwrap(signed.signingOptionsData), as: UTF8.self).contains("customIcon\":\""),
                       "the icon isn't stored in the library index")
    }

    func testImportedAppsHaveNoRememberedOptions() throws {
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? FileManager.default.removeItem(at: source.directory) }
        XCTAssertNil(source.rememberedOptions)
    }

    func testLibraryEntriesFromOlderVersionsStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"signed","name":"A","bundleID":"com.a","version":"1","build":"1","appFolderName":"A.app","size":0,"dateAdded":0}"#
        let app = try JSONDecoder().decode(LibraryApp.self, from: Data(json.utf8))
        XCTAssertNil(app.signingOptionsData)
        XCTAssertNil(app.rememberedOptions)
    }

    // MARK: - Custom entitlements

    func testUngrantedEntitlements() {
        let profile: [String: Any] = ["application-identifier": "T.*", "get-task-allow": true,
                                      "keychain-access-groups": ["T.*"]]
        let custom: [String: Any] = ["get-task-allow": true, "com.apple.developer.healthkit": true,
                                     "com.apple.developer.siri": false, "aps-environment": "development"]
        XCTAssertEqual(EntitlementsMerger.ungranted(custom, profile: profile), ["aps-environment", "com.apple.developer.healthkit"])
    }

    func testSignsWithCustomEntitlementsAndRemembersThem() async throws {
        let folder = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(folder) }
        let file = folder.appendingPathComponent("custom.entitlements")
        let custom: [String: Any] = ["application-identifier": "TESTTEAM01.com.example.fixture",
                                     "com.apple.developer.team-identifier": "TESTTEAM01",
                                     "get-task-allow": true, "keychain-access-groups": ["TESTTEAM01.custom.group"]]
        try PropertyListSerialization.data(fromPropertyList: custom, format: .xml, options: 0).write(to: file)

        var options = SigningOptions()
        options.entitlementsFile = file
        options.mergeEntitlements = true // ignored when a file is chosen
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        let executable = out.appendingPathComponent("Payload/Fixture.app/Fixture")
        let signedEntitlements = try XCTUnwrap(MachO.entitlements(of: executable))
        XCTAssertEqual(signedEntitlements["keychain-access-groups"] as? [String], ["TESTTEAM01.custom.group"])
        XCTAssertTrue(fm.fileExists(atPath: file.path), "the user's file isn't deleted after signing")

        let remembered = try XCTUnwrap(signed.rememberedOptions)
        XCTAssertEqual(remembered.entitlementsFile?.lastPathComponent, "custom-entitlements.plist")
        XCTAssertEqual(try EntitlementsMerger.read(XCTUnwrap(remembered.entitlementsFile))["keychain-access-groups"] as? [String],
                       ["TESTTEAM01.custom.group"])
        XCTAssertNil(options.asDefaults.entitlementsFile, "custom entitlements are per app")
    }

    func testBadEntitlementsFileFailsSigning() async throws {
        let folder = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(folder) }
        let file = folder.appendingPathComponent("broken.entitlements")
        try Data("not a plist".utf8).write(to: file)
        var options = SigningOptions()
        options.entitlementsFile = file
        do {
            _ = try await sign(options)
            XCTFail("signing should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't an entitlements file"))
        }
    }

    // MARK: - Export without signing

    func testExportsModifiedUnsignedIPA() async throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? fm.removeItem(at: source.directory) }
        try addExtensions(to: source.appURL)
        var options = SigningOptions()
        options.appName = "Modded"
        options.bundleID = "com.me.modded"
        options.version = "5.0"
        options.removePaths = ["PlugIns/Widget.appex"]

        let url = try await Signer.shared.exportModified(source, options: options) { _ in }
        defer { try? fm.removeItem(at: url) }
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, Paths.exports.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "Modded_5.0_unsigned.ipa")

        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: url, to: out)
        let app = out.appendingPathComponent("Payload/Fixture.app")
        let plist = try infoPlist(app)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.me.modded")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Modded")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "5.0")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "5.0")
        let share = try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("PlugIns/Share.appex/Info.plist")) as? [String: Any])
        XCTAssertEqual(share["CFBundleIdentifier"] as? String, "com.me.modded.Share", "extensions follow the new prefix")
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("PlugIns/Widget.appex").path))

        // Nothing is added to the library, and a second export doesn't overwrite the first.
        let second = try await Signer.shared.exportModified(source, options: options) { _ in }
        defer { try? fm.removeItem(at: second) }
        XCTAssertEqual(second.lastPathComponent, "Modded_5.0_unsigned 2.ipa")
    }

    func testUnsignedRenameOnlyTouchesTheAppsOwnIDs() throws {
        let fm = FileManager.default
        let app = try Paths.newTempDirectory().appendingPathComponent("A.app", isDirectory: true)
        defer { Paths.removeIfTemporary(app.deletingLastPathComponent()) }
        func write(_ path: String, _ id: String) throws {
            let folder = app.appendingPathComponent(path, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            (["CFBundleIdentifier": id] as NSDictionary).write(to: folder.appendingPathComponent("Info.plist"), atomically: true)
        }
        try write("", "com.foo")
        try write("PlugIns/Widget.appex", "com.foo.widget")
        try write("PlugIns/Other.appex", "com.foobar.ext")
        try Signer.applyIdentity(in: app, from: "com.foo", to: "com.me", name: "", version: "")
        func id(_ path: String) -> String? {
            (NSDictionary(contentsOf: app.appendingPathComponent(path).appendingPathComponent("Info.plist")) as? [String: Any])?["CFBundleIdentifier"] as? String
        }
        XCTAssertEqual(id(""), "com.me")
        XCTAssertEqual(id("PlugIns/Widget.appex"), "com.me.widget")
        XCTAssertEqual(id("PlugIns/Other.appex"), "com.foobar.ext", "a longer ID that only starts the same is left alone")
    }

    func testRememberedTweaksKeepTheirOrder() throws {
        let fm = FileManager.default
        let folder = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(folder) }
        let zebra = folder.appendingPathComponent("Zebra.dylib"), apple = folder.appendingPathComponent("Apple.dylib")
        try fm.copyItem(at: fixture("FixtureTweak.dylib"), to: zebra)
        try fm.copyItem(at: fixture("FixtureTweak.dylib"), to: apple)
        var app = LibraryApp(kind: .signed, name: "A", bundleID: "com.a", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try fm.createDirectory(at: app.directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: app.directory) }
        var options = SigningOptions()
        options.injectFiles = [zebra, apple]
        app.signingOptionsData = try Signer.remember(options, for: app)
        let decoded = try JSONDecoder().decode(LibraryApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(decoded.rememberedOptions?.injectFiles.map(\.lastPathComponent), ["Zebra.dylib", "Apple.dylib"])
    }

    func testSignedRenameOnlyTouchesTheAppsOwnExtensionIDs() async throws {
        var options = SigningOptions()
        options.bundleID = "com.example.renamed"
        let app = try await sign(options) { app in
            let fm = FileManager.default
            for (path, id) in [("PlugIns/Share.appex", "com.example.fixture.Share"), ("PlugIns/Other.appex", "com.example.fixtureother")] {
                let appex = app.appendingPathComponent(path, isDirectory: true)
                try fm.createDirectory(at: appex, withIntermediateDirectories: true)
                let name = appex.deletingPathExtension().lastPathComponent
                (["CFBundleIdentifier": id, "CFBundleExecutable": name] as NSDictionary)
                    .write(to: appex.appendingPathComponent("Info.plist"), atomically: true)
                try fm.copyItem(at: app.appendingPathComponent("Fixture"), to: appex.appendingPathComponent(name))
            }
        }
        func id(_ path: String) throws -> String? {
            try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("\(path)/Info.plist")) as? [String: Any])["CFBundleIdentifier"] as? String
        }
        XCTAssertEqual(try id("PlugIns/Share.appex"), "com.example.renamed.Share")
        XCTAssertEqual(try id("PlugIns/Other.appex"), "com.example.fixtureother", "zsign no longer renames by substring")
    }

    func testRunPathIsSkippedWhenAnEquivalentExists() async throws {
        var options = SigningOptions()
        options.injectFiles = [try fixture("FixtureTweak.dylib")]
        let app = try await sign(options) { app in
            try MachO.addRPath("@loader_path/Frameworks", to: app.appendingPathComponent("Fixture"))
        }
        let rpaths = try MachO.rpaths(of: app.appendingPathComponent("Fixture"))
        XCTAssertTrue(rpaths.contains("@loader_path/Frameworks"))
        XCTAssertFalse(rpaths.contains("@executable_path/Frameworks"))
    }

    func testSameNamedTweaksAreInjectedOnce() async throws {
        let fm = FileManager.default
        let folder = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(folder) }
        var copies: [URL] = []
        for sub in ["a", "b"] {
            let dir = folder.appendingPathComponent(sub, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent("FixtureTweak.dylib")
            try fm.copyItem(at: fixture("FixtureTweak.dylib"), to: copy)
            copies.append(copy)
        }
        var options = SigningOptions()
        options.injectFiles = copies
        let app = try await sign(options)
        let links = try MachO.linkedDylibs(of: app.appendingPathComponent("Fixture"))
        XCTAssertEqual(links.filter { $0 == "@rpath/FixtureTweak.dylib" }.count, 1)
    }
}
