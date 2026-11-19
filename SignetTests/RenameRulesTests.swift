import XCTest
@testable import Signet

final class RenameRulesTests: XCTestCase {
    func testBundleIDRulesMatchExactly() {
        var options = SigningOptions()
        options.bundleIDRules = [.init(match: " com.spotify.client ", replacement: " com.me.spotify ")]
        XCTAssertEqual(options.ruleBundleID(for: "com.spotify.client"), "com.me.spotify")
        XCTAssertNil(options.ruleBundleID(for: "com.spotify.client.widget"))
        XCTAssertNil(options.ruleBundleID(for: "COM.SPOTIFY.CLIENT"), "bundle IDs are case-sensitive")
    }

    func testNameRulesIgnoreCase() {
        var options = SigningOptions()
        options.nameRules = [.init(match: "YouTube", replacement: "Tube")]
        XCTAssertEqual(options.ruleName(for: "youtube"), "Tube")
        XCTAssertNil(options.ruleName(for: "YouTube Music"))
    }

    func testBlankReplacementsDoNothing() {
        var options = SigningOptions()
        options.bundleIDRules = [.init(match: "com.a", replacement: "  ")]
        XCTAssertNil(options.ruleBundleID(for: "com.a"))
    }

    func testRulesAreSavedWithDefaultsAndSurviveOlderData() {
        var options = SigningOptions()
        options.bundleIDRules = [.init(match: "com.a", replacement: "com.b")]
        XCTAssertEqual(options.asDefaults.bundleIDRules.count, 1, "rules are kept as defaults")
        let decoded = SigningOptions.decodeDefaults(from: Data(#"{"enableFileSharing": true}"#.utf8))
        XCTAssertEqual(decoded.bundleIDRules, [])
        XCTAssertEqual(decoded.nameRules, [])
    }

    func testSigningAnUpdateKeepsRulesAddedSince() throws {
        let key = "defaultSigningOptions"
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        // An app signed while one rule existed remembers its options...
        var original = SigningOptions()
        original.bundleIDRules = [.init(match: "com.old", replacement: "com.old.mine")]
        let folder = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(folder) }
        var app = LibraryApp(kind: .signed, name: "A", bundleID: "com.a", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try FileManager.default.createDirectory(at: app.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.directory) }
        app.signingOptionsData = try Signer.remember(original, for: app)
        XCTAssertEqual(app.rememberedOptions?.bundleIDRules, [], "rules aren't stored with signed apps")

        // ...then a second rule is added in Settings, and the update is signed from the remembered options.
        var defaults = SigningOptions.defaults
        defaults.bundleIDRules = [.init(match: "com.old", replacement: "com.old.mine"), .init(match: "com.new", replacement: "com.new.mine")]
        SigningOptions.defaults = defaults
        let fromSignScreen = try XCTUnwrap(app.rememberedOptions)
        SigningOptions.defaults = fromSignScreen.asDefaultsKeepingSavedRules
        XCTAssertEqual(SigningOptions.defaults.bundleIDRules.map(\.match), ["com.old", "com.new"])
    }

    func testOnlyWebLinksOpenFromSources() {
        XCTAssertTrue(URL(string: "https://example.com")!.isWebLink)
        XCTAssertTrue(URL(string: "HTTP://example.com")!.isWebLink)
        XCTAssertFalse(URL(string: "signet://install?url=x")!.isWebLink)
        XCTAssertFalse(URL(string: "tel:123")!.isWebLink)
    }
}
