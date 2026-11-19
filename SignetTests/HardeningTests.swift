import XCTest
@testable import Signet

/// Untrusted files (IPAs, tweaks, backups) must fail with errors, never crash or touch files outside the app.
final class HardeningTests: XCTestCase {
    override func setUp() { Paths.prepare() }

    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = try Paths.newTempDirectory().appendingPathComponent("file")
        try Data(bytes).write(to: url)
        addTeardownBlock { Paths.removeIfTemporary(url) }
        return url
    }

    private func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    private func be(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    private func be64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    func testShortCodeSignatureCommandIsIgnored() throws {
        // A 64-bit arm64 header with one 8-byte LC_CODE_SIGNATURE, too short to hold an offset and length.
        var bytes = le(0xfeed_facf) + le(0x0100_000c) + le(0) + le(6) + le(1) + le(8) + le(0) + le(0)
        bytes += le(0x1d) + le(8)
        let url = try write(bytes + [UInt8](repeating: 0, count: 64))
        XCTAssertNil(try MachO.entitlements(of: url))
    }

    func testOversizedFatOffsetsAreSkipped() throws {
        // A FAT64 header whose only slice claims an offset no file could have.
        var bytes = be(0xcafe_babf) + be(1)
        bytes += be(0x0100_000c) + be(0) + be64(UInt64.max) + be64(4096) + be(0) + be(0)
        let url = try write(bytes + [UInt8](repeating: 0, count: 64))
        XCTAssertFalse(MachO.isMachO(url))
        XCTAssertEqual(try MachO.linkedDylibs(of: url), [])
    }

    func testFatSliceCantClaimMoreThanTheFile() throws {
        var bytes = be(0xcafe_babe) + be(1)
        bytes += be(0x0100_000c) + be(0) + be(64) + be(1_000_000) + be(0)
        let url = try write(bytes + [UInt8](repeating: 0, count: 200))
        XCTAssertFalse(MachO.isMachO(url))
    }

    func testNegativeDebNameLengthIsRejected() throws {
        var header = Array("#1/-5".utf8) + [UInt8](repeating: 0x20, count: 11) // name, 16 bytes
        header += [UInt8](repeating: 0x20, count: 32) // date, uid, gid, mode
        header += Array("10".utf8) + [UInt8](repeating: 0x20, count: 8) // size, 10 bytes
        header += Array("`\n".utf8)
        let url = try write(Array("!<arch>\n".utf8) + header + [UInt8](repeating: 0x41, count: 10))
        let deb = url.deletingLastPathComponent().appendingPathComponent("tweak.deb")
        try FileManager.default.moveItem(at: url, to: deb)
        let out = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(out) }
        XCTAssertThrowsError(try DebPackage.extract(deb, to: out))
    }

    func testBundleFileNamesCantLeaveTheBundle() {
        let app = URL(fileURLWithPath: "/tmp/x/Payload/A.app")
        XCTAssertEqual(AppImporter.file(named: "A", in: app)?.lastPathComponent, "A")
        for name in ["../../Documents/other", "Frameworks/X", "..", ".", "", "/etc/passwd"] {
            XCTAssertNil(AppImporter.file(named: name, in: app), name)
        }
    }

    func testMainExecutableWithAPathIsRefused() throws {
        let app = try Paths.newTempDirectory().appendingPathComponent("A.app", isDirectory: true)
        defer { Paths.removeIfTemporary(app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        (["CFBundleExecutable": "../victim"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        XCTAssertNil(AppImporter.mainExecutable(of: app))
    }

    // MARK: - Restore keeps current settings

    func testRestoreUsesBackupDefaultsOnlyOnAFreshInstall() {
        var backup = SigningOptions()
        backup.enableFileSharing = true
        backup.ppqSuffix = "backup"
        backup.bundleIDRules = [.init(match: "com.b", replacement: "com.b.mine")]

        var fresh = SigningOptions()
        fresh.ppqSuffix = "fresh1"
        let onFresh = Backup.mergedDefaults(current: fresh, backup: backup, hasSignedApps: false)
        XCTAssertTrue(onFresh.enableFileSharing)
        XCTAssertEqual(onFresh.ppqSuffix, "backup", "a fresh install takes the suffix older apps were signed with")

        var customised = SigningOptions()
        customised.ppqSuffix = "mine12"
        customised.removeWatchApp = true
        customised.bundleIDRules = [.init(match: "com.a", replacement: "com.a.mine")]
        let onCustomised = Backup.mergedDefaults(current: customised, backup: backup, hasSignedApps: false)
        XCTAssertFalse(onCustomised.enableFileSharing, "existing settings are kept")
        XCTAssertTrue(onCustomised.removeWatchApp)
        XCTAssertEqual(onCustomised.ppqSuffix, "mine12")
        XCTAssertEqual(onCustomised.bundleIDRules.map(\.match), ["com.a", "com.b"], "rules from both are kept")
    }

    func testRestoreKeepsTheSuffixOnceAppsAreSigned() {
        var backup = SigningOptions()
        backup.ppqSuffix = "backup"
        backup.enableFileSharing = true
        var established = SigningOptions() // default settings, but apps were signed with this suffix
        established.ppqSuffix = "mine12"
        let merged = Backup.mergedDefaults(current: established, backup: backup, hasSignedApps: true)
        XCTAssertEqual(merged.ppqSuffix, "mine12")
        XCTAssertFalse(merged.enableFileSharing)
    }

    func testRestoreMergesRulesTheWayTheyMatch() {
        var current = SigningOptions()
        current.nameRules = [.init(match: "YouTube", replacement: "Tube")]
        current.bundleIDRules = [.init(match: "com.a", replacement: "com.a.mine")]
        var backup = SigningOptions()
        backup.nameRules = [.init(match: " youtube ", replacement: "Other"), .init(match: "Maps", replacement: "M")]
        backup.bundleIDRules = [.init(match: "com.a ", replacement: "com.a.theirs")]
        let merged = Backup.mergedDefaults(current: current, backup: backup, hasSignedApps: true)
        XCTAssertEqual(merged.nameRules.map(\.replacement), ["Tube", "M"], "names match ignoring case and spaces")
        XCTAssertEqual(merged.bundleIDRules.map(\.replacement), ["com.a.mine"])
    }

    func testMalformedDebMemberRejectsThePackageEvenWithData() throws {
        // A bad long-name member in front of an otherwise valid package.
        let original = try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("DebTweak.deb"))
        var header = Array("#1/-5".utf8) + [UInt8](repeating: 0x20, count: 11)
        header += [UInt8](repeating: 0x20, count: 32)
        header += Array("10".utf8) + [UInt8](repeating: 0x20, count: 8)
        header += Array("`\n".utf8)
        var bytes = Array("!<arch>\n".utf8) + header + [UInt8](repeating: 0x41, count: 10)
        bytes += Array(original.dropFirst(8))
        let deb = try write(bytes).deletingLastPathComponent().appendingPathComponent("bad.deb")
        try Data(bytes).write(to: deb)
        let out = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(out) }
        XCTAssertNoThrow(try DebPackage.extract(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("DebTweak.deb"), to: out), "the package itself is fine")
        XCTAssertThrowsError(try DebPackage.extract(deb, to: try Paths.newTempDirectory()))
    }

    func testOverlappingFatSlicesAreRefused() throws {
        // Two slices whose ranges overlap, each fitting in the file on its own.
        var bytes = be(0xcafe_babe) + be(2)
        bytes += be(0x0100_000c) + be(0) + be(64) + be(128) + be(0)
        bytes += be(0x0100_000c) + be(2) + be(128) + be(128) + be(0)
        var thin = le(0xfeed_facf) + le(0x0100_000c) + le(0) + le(6) + le(0) + le(0) + le(0) + le(0)
        thin += [UInt8](repeating: 0, count: 32)
        bytes += [UInt8](repeating: 0, count: 64 - bytes.count) + thin + thin + [UInt8](repeating: 0, count: 128)
        XCTAssertFalse(MachO.isMachO(try write(bytes)))
    }

    func testSigningRefusesANestedExecutableOutsideItsBundle() throws {
        let app = try Paths.newTempDirectory().appendingPathComponent("A.app", isDirectory: true)
        defer { Paths.removeIfTemporary(app.deletingLastPathComponent()) }
        let appex = app.appendingPathComponent("PlugIns/Share.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        (["CFBundleExecutable": "A"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        try Data().write(to: app.appendingPathComponent("A"))
        XCTAssertNoThrow(try AppImporter.validateForSigning(app))
        (["CFBundleExecutable": "../../A"] as NSDictionary).write(to: appex.appendingPathComponent("Info.plist"), atomically: true)
        XCTAssertThrowsError(try AppImporter.validateForSigning(app)) { error in
            XCTAssertTrue(error.localizedDescription.contains("PlugIns/Share.appex"))
        }
    }
}
