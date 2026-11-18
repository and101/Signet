import XCTest
import ZIPFoundation
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
}
