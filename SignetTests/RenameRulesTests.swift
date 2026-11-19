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
}
