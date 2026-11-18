import XCTest
import ZIPFoundation
@testable import Signet

final class TweakSupportTests: XCTestCase {
    // MARK: - arm64e

    /// A fat file with an arm64 slice and an arm64e slice whose subtypes are given, each slice a bare
    /// mach_header_64 with no load commands.
    private func fatBinary(arm64eFat: UInt32, arm64eHeader: UInt32) -> Data {
        var data = Data()
        func be(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        func le(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        be(0xcafe_babe); be(2)
        be(0x0100_000c); be(0); be(0x1000); be(32); be(12)
        be(0x0100_000c); be(arm64eFat); be(0x2000); be(32); be(12)
        data.append(Data(count: 0x1000 - data.count))
        le(0xfeed_facf); le(0x0100_000c); le(0); le(6); le(0); le(0); le(0); le(0)
        data.append(Data(count: 0x2000 - data.count))
        le(0xfeed_facf); le(0x0100_000c); le(arm64eHeader); le(6); le(0); le(0); le(0); le(0)
        return data
    }

    private func word(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt32 {
        let bytes = Array(data[offset..<(offset + 4)])
        return (bigEndian ? bytes : bytes.reversed()).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = try Paths.newTempDirectory().appendingPathComponent("binary.dylib")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testLegacyARM64ESliceGetsVersionedABI() throws {
        let url = try temporaryFile(fatBinary(arm64eFat: 2, arm64eHeader: 2))
        XCTAssertTrue(try MachO.fixLegacyARM64ESlices(in: url))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(word(data, 8 + 20 + 4, bigEndian: true), 0x8000_0002, "fat record")
        XCTAssertEqual(word(data, 0x2000 + 8, bigEndian: false), 0x8000_0002, "slice header")
        XCTAssertEqual(word(data, 8 + 4, bigEndian: true), 0, "arm64 record untouched")
        XCTAssertEqual(word(data, 0x1000 + 8, bigEndian: false), 0, "arm64 header untouched")
        XCTAssertFalse(try MachO.fixLegacyARM64ESlices(in: url), "second pass is a no-op")
    }

    func testMismatchedARM64ESliceIsMadeConsistent() throws {
        let url = try temporaryFile(fatBinary(arm64eFat: 0x8000_0002, arm64eHeader: 2))
        XCTAssertTrue(try MachO.fixLegacyARM64ESlices(in: url))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(word(data, 8 + 20 + 4, bigEndian: true), 0x8000_0002)
        XCTAssertEqual(word(data, 0x2000 + 8, bigEndian: false), 0x8000_0002)
    }

    func testModernARM64EAndNonMachOAreLeftAlone() throws {
        let modern = fatBinary(arm64eFat: 0x8100_0002, arm64eHeader: 0x8100_0002)
        let url = try temporaryFile(modern)
        XCTAssertFalse(try MachO.fixLegacyARM64ESlices(in: url))
        XCTAssertEqual(try Data(contentsOf: url), modern)

        let text = try temporaryFile(Data("not a binary at all".utf8))
        XCTAssertFalse(try MachO.fixLegacyARM64ESlices(in: text))
        XCTAssertFalse(MachO.isMachO(text))
    }

    func testReadOnlyBinariesAreOnlyTouchedWhenTheyNeedFixing() throws {
        let fm = FileManager.default
        let modern = try temporaryFile(fatBinary(arm64eFat: 0x8000_0002, arm64eHeader: 0x8000_0002))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: modern.path)
        XCTAssertFalse(try MachO.fixLegacyARM64ESlices(in: modern), "read-only files that are fine aren't opened for writing")
        XCTAssertEqual((try fm.attributesOfItem(atPath: modern.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)

        let legacy = try temporaryFile(fatBinary(arm64eFat: 2, arm64eHeader: 2))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: legacy.path)
        XCTAssertTrue(try MachO.fixLegacyARM64ESlices(in: legacy), "read-only files that need fixing are made writable")
        XCTAssertEqual(word(try Data(contentsOf: legacy), 0x2000 + 8, bigEndian: false), 0x8000_0002)
    }

    // MARK: - Entitlements

    func testMergeKeepsAllowedAppValuesOnTheSigningTeam() {
        let profile: [String: Any] = [
            "application-identifier": "NEWTEAM001.*",
            "com.apple.developer.team-identifier": "NEWTEAM001",
            "get-task-allow": true,
            "keychain-access-groups": ["NEWTEAM001.*"],
            "com.apple.developer.associated-domains": "*",
            "com.apple.developer.ubiquity-kvstore-identifier": "NEWTEAM001.*",
            "com.apple.developer.icloud-container-environment": ["Development", "Production"],
            "com.apple.security.application-groups": ["group.allowed"],
            "com.apple.developer.healthkit": true,
        ]
        let app: [String: Any] = [
            "application-identifier": "OLDTEAM001.com.app",
            "com.apple.developer.team-identifier": "OLDTEAM001",
            "get-task-allow": false,
            "keychain-access-groups": ["OLDTEAM001.com.app", "OLDTEAM001.com.app.shared", "com.apple.token"],
            "com.apple.developer.associated-domains": ["applinks:example.com"],
            "com.apple.developer.ubiquity-kvstore-identifier": "OLDTEAM001.com.app",
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.security.application-groups": ["group.other"],
            "com.apple.developer.healthkit": false,
            "com.apple.developer.siri": true,
        ]
        let merged = EntitlementsMerger.merge(profile: profile, app: app, teamID: "NEWTEAM001")

        XCTAssertEqual(merged["application-identifier"] as? String, "NEWTEAM001.*", "left for zsign to expand")
        XCTAssertEqual(merged["com.apple.developer.team-identifier"] as? String, "NEWTEAM001")
        XCTAssertEqual(merged["get-task-allow"] as? Bool, true)
        XCTAssertEqual(merged["keychain-access-groups"] as? [String],
                       ["NEWTEAM001.com.app", "NEWTEAM001.com.app.shared"], "moved to our team; com.apple.token isn't allowed")
        XCTAssertEqual(merged["com.apple.developer.associated-domains"] as? [String], ["applinks:example.com"])
        XCTAssertEqual(merged["com.apple.developer.ubiquity-kvstore-identifier"] as? String, "NEWTEAM001.com.app")
        XCTAssertEqual(merged["com.apple.developer.icloud-container-environment"] as? String, "Production")
        XCTAssertEqual(merged["com.apple.security.application-groups"] as? [String], ["group.allowed"],
                       "app groups the profile lacks fall back to the profile's")
        XCTAssertEqual(merged["com.apple.developer.healthkit"] as? Bool, true, "booleans stay as granted")
        XCTAssertNil(merged["com.apple.developer.siri"], "keys the profile doesn't grant are dropped")
    }

    func testWildcardMatching() {
        XCTAssertTrue(EntitlementsMerger.allowed("anything", by: ["*"]))
        XCTAssertTrue(EntitlementsMerger.allowed("T.com.a", by: ["T.*"]))
        XCTAssertFalse(EntitlementsMerger.allowed("U.com.a", by: ["T.*"]))
        XCTAssertTrue(EntitlementsMerger.allowed("exact", by: ["exact"]))
        XCTAssertFalse(EntitlementsMerger.allowed("exactly", by: ["exact"]))
    }

    func testZippedFrameworksAreUnpackedForInjection() throws {
        let fm = FileManager.default
        let work = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: work) }
        let source = work.appendingPathComponent("src", isDirectory: true)
        let framework = source.appendingPathComponent("Tool.framework", isDirectory: true)
        try fm.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: framework.appendingPathComponent("Tool"))
        try Data("nested".utf8).write(to: framework.appendingPathComponent("Helper.dylib"))
        let junk = source.appendingPathComponent("__MACOSX/Tool.framework", isDirectory: true)
        try fm.createDirectory(at: junk, withIntermediateDirectories: true)

        let zip = work.appendingPathComponent("Tool.framework.zip")
        try fm.zipItem(at: source, to: zip, shouldKeepParent: false)
        let picked = try TweakInjector.unpackPicked(zip)
        XCTAssertEqual(picked.map(\.lastPathComponent), ["Tool.framework"], "the framework, not its contents or Finder junk")
        XCTAssertTrue(fm.fileExists(atPath: picked[0].appendingPathComponent("Tool").path))
        defer { Paths.removeIfTemporary(picked[0]) }

        let empty = work.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: empty.appendingPathComponent("readme.txt"))
        let emptyZip = work.appendingPathComponent("nothing.zip")
        try fm.zipItem(at: empty, to: emptyZip, shouldKeepParent: false)
        XCTAssertThrowsError(try TweakInjector.unpackPicked(emptyZip))
    }

    // MARK: - Debs and options

    func testDebPathsAreNormalizedAndContained() {
        XCTAssertEqual(DebPackage.safeRelativePath("./var/jb/Library/x.dylib"), "var/jb/Library/x.dylib")
        XCTAssertEqual(DebPackage.safeRelativePath("/Library//x"), "Library/x")
        XCTAssertNil(DebPackage.safeRelativePath("./"))
        XCTAssertNil(DebPackage.safeRelativePath("../escape"))
        XCTAssertNil(DebPackage.safeRelativePath("Library/../../escape"))
    }

    func testDebWithoutArHeaderIsRejected() throws {
        let url = try temporaryFile(Data("plain text".utf8)).deletingLastPathComponent().appendingPathComponent("x.deb")
        try Data("plain text".utf8).write(to: url)
        XCTAssertThrowsError(try DebPackage.extract(url, to: url.deletingLastPathComponent()))
    }

    func testOlderSavedDefaultsStillDecode() throws {
        // Saved by a version that predates bundleElleKit/mergeEntitlements.
        let json = #"{"removeSupportedDevices":false,"enableFileSharing":true,"removeURLSchemes":false,"#
            + #""removePlugins":false,"removeWatchApp":false,"forceFullScreen":false,"removeProvisioningFile":false,"#
            + #""weakInject":true,"fixSubstratePaths":true,"compressIPA":true,"installAfterSigning":false,"#
            + #""deleteOriginalAfterSigning":false,"appName":"","bundleID":"","version":"","minimumOSVersion":"","#
            + #""injectFiles":[],"removeLoadCommands":[]}"#
        let options = SigningOptions.decodeDefaults(from: Data(json.utf8))
        XCTAssertFalse(options.removeSupportedDevices, "saved values survive")
        XCTAssertTrue(options.enableFileSharing)
        XCTAssertTrue(options.bundleElleKit, "new options take their defaults")
        XCTAssertFalse(options.mergeEntitlements)
    }
}
