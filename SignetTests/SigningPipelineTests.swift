import XCTest
import ZIPFoundation
@testable import Signet
import Zsign

/// End-to-end tests against fixtures from scripts/make-test-fixtures.sh.
final class SigningPipelineTests: XCTestCase {
    private func signedEntitlements(at executable: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: executable)
        func word(_ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { throw AppError("Invalid code signature") }
            let bytes = data[offset..<(offset + 4)]
            return bytes.reduce(UInt32(0)) { result, byte in
                bigEndian ? (result << 8) | UInt32(byte) : (result >> 8) | (UInt32(byte) << 24)
            }
        }
        XCTAssertEqual(try word(0), 0xfeedfacf)
        let commands = Int(try word(16))
        var offset = 32
        for _ in 0..<commands {
            let command = try word(offset)
            let length = Int(try word(offset + 4))
            guard length >= 8 else { throw AppError("Invalid load command") }
            if command == 0x1d {
                let signature = Int(try word(offset + 8))
                let count = Int(try word(signature + 8, bigEndian: true))
                for index in 0..<count {
                    let entry = signature + 12 + index * 8
                    if try word(entry, bigEndian: true) == 5 {
                        let blob = signature + Int(try word(entry + 4, bigEndian: true))
                        let blobLength = Int(try word(blob + 4, bigEndian: true))
                        guard blobLength >= 8, blob + blobLength <= data.count else { throw AppError("Invalid entitlements") }
                        return try XCTUnwrap(PropertyListSerialization.propertyList(
                            from: data.subdata(in: (blob + 8)..<(blob + blobLength)), format: nil) as? [String: Any])
                    }
                }
            }
            offset += length
        }
        throw AppError("No signed entitlements found")
    }

    private func fixture(_ name: String) throws -> URL {
        let folder = Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)
        guard let url = folder?.appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name). Run scripts/make-test-fixtures.sh first.")
        }
        return url
    }

    override func setUp() {
        Paths.prepare()
        CryptoSetup.loadProviders()
    }

    func testImportReadsBundleInfoAndIcon() throws {
        let app = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? FileManager.default.removeItem(at: app.directory) }

        XCTAssertEqual(app.name, "Fixture App")
        XCTAssertEqual(app.bundleID, "com.example.fixture")
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertEqual(app.build, "42")
        XCTAssertEqual(app.appFolderName, "Fixture.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.iconURL.path), "icon should be extracted")
    }

    func testCertificateImportParsesProfile() throws {
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        defer { try? FileManager.default.removeItem(at: cert.directory); Keychain.delete(cert.id.uuidString) }

        XCTAssertEqual(cert.nickname, "Fixture Wildcard")
        XCTAssertEqual(cert.teamID, "TESTTEAM01")
        XCTAssertEqual(cert.bundleIDPattern, "*")
        XCTAssertTrue(cert.isWildcard)
        XCTAssertEqual(cert.provisionedDeviceCount, 1)
        XCTAssertEqual(cert.distributionKind, "Development")
        XCTAssertEqual(cert.entitlements["get-task-allow"], "true")
        XCTAssertEqual(cert.password, "fixture")
        if let matches = cert.certificateMatchesProfile { XCTAssertTrue(matches) }
    }

    func testKnownCertificateProfileMismatchStopsBeforeSigning() async throws {
        let app = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? FileManager.default.removeItem(at: app.directory) }
        var cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        defer { try? FileManager.default.removeItem(at: cert.directory); Keychain.delete(cert.id.uuidString) }
        cert.certificateMatchesProfile = false
        // A stale flag alone doesn't block signing: the files are re-checked. Make them really mismatch by giving the
        // stored profile a different developer certificate.
        let profileData = try Data(contentsOf: cert.profileURL)
        let start = try XCTUnwrap(profileData.range(of: Data("<?xml".utf8)))
        let end = try XCTUnwrap(profileData.range(of: Data("</plist>".utf8)))
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: profileData.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any])
        plist["DeveloperCertificates"] = [Data([1, 2, 3])]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: cert.profileURL)
        do {
            _ = try await Signer.shared.sign(app, with: cert, options: SigningOptions(), log: { _ in })
            XCTFail("A known mismatch must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't included"), error.localizedDescription)
        }
    }

    func testStaleMismatchFlagIsRecheckedAgainstTheFiles() async throws {
        let app = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? FileManager.default.removeItem(at: app.directory) }
        var cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        defer { try? FileManager.default.removeItem(at: cert.directory); Keychain.delete(cert.id.uuidString) }
        let fresh = CertificateImporter.certificateMatches(p12: cert.p12URL, password: "fixture",
                                                           profile: try ProvisioningProfile(url: cert.profileURL))
        guard fresh == true else { throw XCTSkip("Security.framework can't read the fixture p12 here") }
        // e.g. restored verbatim by 1.1: the pair matches, but the saved flag says it doesn't. Signing must go ahead.
        cert.certificateMatchesProfile = false
        let signed = try await Signer.shared.sign(app, with: cert, options: SigningOptions(), log: { _ in })
        defer { try? FileManager.default.removeItem(at: signed.directory) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: signed.ipaURL.path))
    }

    func testWrongPasswordIsRejected() throws {
        XCTAssertThrowsError(try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "nope", nickname: ""))
    }

    func testBundleIDMatching() {
        var cert = CertificateRecord(
            nickname: "", certificateName: "", teamName: "", teamID: "T", profileName: "",
            applicationIdentifier: "T.com.example.*", creationDate: Date(), expirationDate: Date(),
            provisionsAllDevices: false, entitlements: [:])
        XCTAssertTrue(cert.allows(bundleID: "com.example.app"))
        XCTAssertFalse(cert.allows(bundleID: "org.other.app"))
        XCTAssertFalse(cert.allows(bundleID: "com.example."))
        XCTAssertEqual(cert.suggestedBundleID(for: "org.other.app"), "com.example.org.other.app")
        XCTAssertNil(cert.suggestedBundleID(for: "com.example.app"))
        cert.applicationIdentifier = "T.com.example.app"
        XCTAssertTrue(cert.allows(bundleID: "com.example.app"))
        XCTAssertFalse(cert.allows(bundleID: "com.example.app2"))
        XCTAssertNil(cert.suggestedBundleID(for: "org.other.app"), "exact App IDs keep the app's own ID")
        XCTAssertNil(cert.bundleIDRequirement(for: "org.other.app"))
        cert.applicationIdentifier = "T.*"
        XCTAssertNil(cert.suggestedBundleID(for: "org.other.app"))
        XCTAssertNil(cert.bundleIDRequirement(for: "org.other.app"))
        cert.applicationIdentifier = "T.com.example.*"
        XCTAssertEqual(cert.bundleIDRequirement(for: "org.other.app"), "Must start with com.example.")
    }

    func testAppIDPrefixThatIsntTheTeamIDIsStripped() {
        var cert = CertificateRecord(
            nickname: "", certificateName: "", teamName: "", teamID: "TEAM000001", profileName: "",
            applicationIdentifier: "LEGACY0001.app.example.thing", creationDate: Date(), expirationDate: Date(),
            provisionsAllDevices: false, entitlements: [:])
        XCTAssertEqual(cert.bundleIDPattern, "app.example.thing")
        cert.applicationIdentifier = "TEAM000001.*"
        XCTAssertEqual(cert.bundleIDPattern, "*")
    }

    func testDamagedMainExecutableFailsInsteadOfSucceeding() async throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test-prefixed.mobileprovision"), password: "fixture", nickname: "Test")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }
        try Data("not a mach-o".utf8).write(to: source.appURL.appendingPathComponent("Fixture"))

        do {
            let signed = try await Signer.shared.sign(source, with: cert, options: SigningOptions()) { _ in }
            try? fm.removeItem(at: signed.directory)
            XCTFail("signing a damaged executable must fail")
        } catch {}
    }

    func testExtensionsGetTheSigningProfile() throws {
        let fm = FileManager.default
        let app = try Paths.newTempDirectory().appendingPathComponent("Host.app", isDirectory: true)
        defer { Paths.removeIfTemporary(app.deletingLastPathComponent()) }
        let appex = app.appendingPathComponent("PlugIns/Share.appex", isDirectory: true)
        try fm.createDirectory(at: appex, withIntermediateDirectories: true)
        try Data("app profile".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        try Data("original developer".utf8).write(to: appex.appendingPathComponent("embedded.mobileprovision"))
        let ours = app.deletingLastPathComponent().appendingPathComponent("ours.mobileprovision")
        try Data("ours".utf8).write(to: ours)

        try Signer.replaceNestedProfiles(in: app, with: ours, remove: false)
        XCTAssertEqual(try Data(contentsOf: appex.appendingPathComponent("embedded.mobileprovision")), Data("ours".utf8))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")), Data("app profile".utf8),
                       "the app's own profile is left to zsign")

        try Signer.replaceNestedProfiles(in: app, with: ours, remove: true)
        XCTAssertFalse(fm.fileExists(atPath: appex.appendingPathComponent("embedded.mobileprovision").path))
    }

    func testSignProducesPatchedSignedIPA() async throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test-prefixed.mobileprovision"), password: "fixture", nickname: "Test")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }

        var options = SigningOptions()
        options.appName = "Renamed"
        options.bundleID = "com.example.renamed"
        options.version = "9.9"
        options.enableFileSharing = true
        options.removeURLSchemes = true
        options.removeSupportedDevices = true
        options.customIcon = UIImage(contentsOfFile: source.iconURL.path)?.pngData()

        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        XCTAssertEqual(signed.kind, .signed)
        XCTAssertEqual(signed.name, "Renamed")
        XCTAssertEqual(signed.bundleID, "com.example.renamed")
        XCTAssertEqual(signed.version, "9.9")
        XCTAssertEqual(signed.originalAppID, source.id)
        XCTAssertTrue(fm.fileExists(atPath: signed.ipaURL.path))
        XCTAssertFalse(fm.fileExists(atPath: signed.payloadURL.path), "extracted payload is removed after zipping")

        // Unpack and inspect the result.
        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        let app = out.appendingPathComponent("Payload/Fixture.app")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.example.renamed")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Renamed")
        XCTAssertEqual(plist["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertNil(plist["UISupportedDevices"])
        XCTAssertNil(plist["CFBundleURLTypes"])
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("SignerIcon60x60@2x.png").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
        XCTAssertTrue(Zsign.checkSigned(appExecutable: app.appendingPathComponent("Fixture").path))
        XCTAssertTrue(Zsign.checkSigned(appExecutable: app.appendingPathComponent("Frameworks/Helper.framework/Helper").path),
                      "read-only framework binaries are signed too")
        let entitlements = try signedEntitlements(at: app.appendingPathComponent("Fixture"))
        XCTAssertEqual(entitlements["application-identifier"] as? String, "TESTTEAM01.com.example.renamed")
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String], ["TESTTEAM01.com.example.renamed"])
        // Original stays untouched.
        XCTAssertEqual(try BundleInfo(appURL: source.appURL).bundleID, "com.example.fixture")
    }

    func testExactProfileKeepsTheAppsBundleIDUnlessAnotherIsChosen() async throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test-exact.mobileprovision"), password: "fixture", nickname: "")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }

        var options = SigningOptions()
        options.bundleID = ""
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        // By default the app keeps its own ID, so it installs alongside other apps signed with this profile.
        XCTAssertEqual(signed.bundleID, "com.example.fixture")
        let app = try unpack(signed)
        XCTAssertEqual(try plistBundleID(app), "com.example.fixture")
        XCTAssertEqual(try signedEntitlements(at: app.appendingPathComponent("Fixture"))["application-identifier"] as? String,
                       "TESTTEAM01.com.example.exact")

        // A chosen bundle ID is applied as is.
        options.bundleID = "com.example.exact"
        let matched = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: matched.directory) }
        XCTAssertEqual(matched.bundleID, "com.example.exact")
        XCTAssertEqual(try plistBundleID(unpack(matched)), "com.example.exact")
    }

    private func unpack(_ signed: LibraryApp) throws -> URL {
        let out = try Paths.newTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        try FileManager.default.unzipItem(at: signed.ipaURL, to: out)
        return out.appendingPathComponent("Payload/Fixture.app")
    }

    private func plistBundleID(_ app: URL) throws -> String? {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any])
        return plist["CFBundleIdentifier"] as? String
    }

    func testOnlyWildcardProfilesRejectBundleIDs() {
        func record(_ pattern: String) -> CertificateRecord {
            CertificateRecord(
                nickname: "", certificateName: "", teamName: "", teamID: "TEAM", profileName: "",
                applicationIdentifier: "TEAM.\(pattern)", creationDate: .now, expirationDate: .distantFuture,
                provisionsAllDevices: false, entitlements: [:])
        }
        XCTAssertFalse(record("*").rejects(bundleID: "org.other.app"))
        XCTAssertFalse(record("com.example.exact").rejects(bundleID: "org.other.app"), "exact IDs never block")
        XCTAssertTrue(record("com.example.*").rejects(bundleID: "org.other.app"))
        XCTAssertFalse(record("com.example.*").rejects(bundleID: "com.example.app"))
    }

    func testProblemOnlyReportsExpiredOrRevoked() {
        var cert = CertificateRecord(
            nickname: "", certificateName: "", teamName: "", teamID: "TEAM", profileName: "",
            applicationIdentifier: "TEAM.*", creationDate: .now, expirationDate: .distantFuture,
            provisionsAllDevices: false, entitlements: [:])
        XCTAssertNil(cert.problem)
        cert.revocation = .unknown
        XCTAssertNil(cert.problem, "an inconclusive check isn't a problem")
        cert.revocation = .revoked
        XCTAssertEqual(cert.problem, "Revoked")
        cert.expirationDate = .distantPast
        XCTAssertEqual(cert.problem, "Expired")
    }

    func testWildcardMismatchStillThrows() async throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test-prefixed.mobileprovision"), password: "fixture", nickname: "")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }

        var options = SigningOptions()
        options.bundleID = "org.other.app"
        do {
            let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
            try? fm.removeItem(at: signed.directory)
            XCTFail("A wildcard mismatch should still throw")
        } catch {}
    }

    func testProvisioningFileCanBeOmitted() async throws {
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
        options.removeProvisioningFile = true
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        let app = out.appendingPathComponent("Payload/Fixture.app")
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
    }

    func testInjectsTweakAndFixesSubstratePath() async throws {
        let fm = FileManager.default
        let tweak = try fixture("FixtureTweak.dylib")
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }
        var options = SigningOptions()
        options.injectFiles = [tweak]
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        let app = out.appendingPathComponent("Payload/Fixture.app")
        let injected = app.appendingPathComponent("Frameworks/FixtureTweak.dylib")

        XCTAssertTrue(Zsign.listDylibs(appExecutable: app.appendingPathComponent("Fixture").path)
            .contains("@rpath/FixtureTweak.dylib"))
        let tweakLinks = Zsign.listDylibs(appExecutable: injected.path)
        XCTAssertTrue(tweakLinks.contains("@rpath/CydiaSubstrate.framework/CydiaSubstrate"), "\(tweakLinks)")
        XCTAssertFalse(tweakLinks.contains("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"))
        XCTAssertTrue(Zsign.checkSigned(appExecutable: injected.path), "injected dylib is signed too")

        // The tweak links Substrate, so ElleKit is bundled as CydiaSubstrate.framework and signed.
        let substrate = app.appendingPathComponent("Frameworks/CydiaSubstrate.framework/CydiaSubstrate")
        XCTAssertTrue(fm.fileExists(atPath: substrate.path), "ElleKit should be added")
        XCTAssertTrue(Zsign.checkSigned(appExecutable: substrate.path))
    }

    func testElleKitCanBeLeftOut() async throws {
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
        options.injectFiles = [try fixture("FixtureTweak.dylib")]
        options.bundleElleKit = false
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        let frameworks = out.appendingPathComponent("Payload/Fixture.app/Frameworks")
        XCTAssertTrue(fm.fileExists(atPath: frameworks.appendingPathComponent("FixtureTweak.dylib").path))
        XCTAssertFalse(fm.fileExists(atPath: frameworks.appendingPathComponent("CydiaSubstrate.framework").path))
    }

    func testInjectsRootlessDebTweak() async throws {
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
        options.injectFiles = [try fixture("DebTweak.deb")]
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }

        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        let app = out.appendingPathComponent("Payload/Fixture.app")
        let frameworks = app.appendingPathComponent("Frameworks")
        let tweak = frameworks.appendingPathComponent("DebTweak.dylib")

        XCTAssertEqual(Zsign.listDylibs(appExecutable: app.appendingPathComponent("Fixture").path)
            .filter { $0.hasPrefix("@rpath/") }, ["@rpath/DebTweak.dylib"], "only the tweak is injected")
        let links = try MachO.linkedDylibs(of: tweak)
        XCTAssertTrue(links.contains("@rpath/CydiaSubstrate.framework/CydiaSubstrate"), "grown rewrite: \(links)")
        XCTAssertTrue(links.contains("@rpath/libdebhelper.dylib"), "\(links)")
        XCTAssertFalse(links.contains { $0.hasPrefix("/usr/lib/libsubstrate") || $0.hasPrefix("/var/jb") }, "\(links)")
        XCTAssertEqual(Zsign.listDylibs(appExecutable: tweak.path), links, "zsign reads the rewritten commands too")
        XCTAssertTrue(Zsign.checkSigned(appExecutable: tweak.path))
        XCTAssertTrue(Zsign.checkSigned(appExecutable: frameworks.appendingPathComponent("libdebhelper.dylib").path))
        XCTAssertTrue(fm.fileExists(atPath: frameworks.appendingPathComponent("CydiaSubstrate.framework/CydiaSubstrate").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("DebTweak.bundle/Info.plist").path))
        XCTAssertFalse(fm.fileExists(atPath: frameworks.appendingPathComponent("DebTweak.plist").path))
    }

    func testChangeLinkedDylibGrowsLoadCommand() throws {
        let fm = FileManager.default
        let folder = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("Tweak.dylib")
        try fm.copyItem(at: fixture("FixtureTweak.dylib"), to: binary)

        let old = "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
        let long = "@rpath/" + String(repeating: "Long", count: 30) + ".framework/Binary"
        XCTAssertTrue(try MachO.changeLinkedDylib(in: binary, from: old, to: long))
        XCTAssertFalse(try MachO.changeLinkedDylib(in: binary, from: old, to: long), "already rewritten")
        let links = try MachO.linkedDylibs(of: binary)
        XCTAssertTrue(links.contains(long))
        XCTAssertFalse(links.contains(old))
        XCTAssertEqual(Zsign.listDylibs(appExecutable: binary.path), links)

        // Shrinking back keeps the command size and leaves no trailing bytes of the long path.
        XCTAssertTrue(try MachO.changeLinkedDylib(in: binary, from: long, to: "@rpath/S"))
        XCTAssertTrue(try MachO.linkedDylibs(of: binary).contains("@rpath/S"))
    }

    func testMergesAppEntitlements() async throws {
        let fm = FileManager.default
        let source = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        let original = try XCTUnwrap(MachO.entitlements(of: source.appURL.appendingPathComponent("Fixture")),
                                     "re-run scripts/make-test-fixtures.sh: the fixture app needs entitlements")
        XCTAssertEqual(original["com.apple.developer.team-identifier"] as? String, "OLDTEAM001")
        let cert = try CertificateImporter.importCertificate(
            p12: fixture("test.p12"), profile: fixture("test.mobileprovision"), password: "fixture", nickname: "")
        defer {
            try? fm.removeItem(at: source.directory)
            try? fm.removeItem(at: cert.directory)
            Keychain.delete(cert.id.uuidString)
        }
        var options = SigningOptions()
        options.mergeEntitlements = true
        let signed = try await Signer.shared.sign(source, with: cert, options: options) { _ in }
        defer { try? fm.removeItem(at: signed.directory) }
        XCTAssertFalse(fm.fileExists(atPath: signed.directory.appendingPathComponent("entitlements.plist").path))

        let out = try Paths.newTempDirectory()
        defer { try? fm.removeItem(at: out) }
        try fm.unzipItem(at: signed.ipaURL, to: out)
        let entitlements = try signedEntitlements(at: out.appendingPathComponent("Payload/Fixture.app/Fixture"))
        XCTAssertEqual(entitlements["application-identifier"] as? String, "TESTTEAM01.com.example.fixture")
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String, "TESTTEAM01")
        XCTAssertEqual(entitlements["get-task-allow"] as? Bool, true, "the profile decides get-task-allow")
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String],
                       ["TESTTEAM01.com.example.fixture", "TESTTEAM01.com.example.shared"])
        XCTAssertNil(entitlements["com.apple.security.application-groups"], "not granted by the profile")
    }
}
