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
        let onFresh = Backup.mergedDefaults(current: fresh, backup: backup)
        XCTAssertTrue(onFresh.enableFileSharing)
        XCTAssertEqual(onFresh.ppqSuffix, "backup", "a fresh install takes the suffix older apps were signed with")

        var customised = SigningOptions()
        customised.ppqSuffix = "mine12"
        customised.removeWatchApp = true
        customised.bundleIDRules = [.init(match: "com.a", replacement: "com.a.mine")]
        let onCustomised = Backup.mergedDefaults(current: customised, backup: backup)
        XCTAssertFalse(onCustomised.enableFileSharing, "existing settings are kept")
        XCTAssertTrue(onCustomised.removeWatchApp)
        XCTAssertEqual(onCustomised.ppqSuffix, "mine12")
        XCTAssertEqual(onCustomised.bundleIDRules.map(\.match), ["com.a", "com.b"], "rules from both are kept")
    }
}
