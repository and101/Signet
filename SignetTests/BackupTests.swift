import XCTest
import ZIPFoundation
@testable import Signet

@MainActor
final class BackupTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let folder = Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)
        guard let url = folder?.appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name). Run scripts/make-test-fixtures.sh first.")
        }
        return url
    }

    override func setUp() {
        super.setUp()
        Paths.prepare()
    }

    private func importFixtureCertificate(into store: CertificateStore) async throws -> CertificateRecord {
        try await store.add(p12: fixture("test.p12"), profile: fixture("test-prefixed.mobileprovision"),
                            password: "fixture", nickname: "Backup Test \(UUID().uuidString.prefix(4))")
        return try XCTUnwrap(store.certificates.last)
    }

    func testRestoredCertificateSignsAfterItsFilesAndPasswordAreGone() async throws {
        let certificates = CertificateStore(), library = LibraryStore(), sources = SourceStore(), github = GitHubStore()
        let record = try await importFixtureCertificate(into: certificates)
        defer { certificates.delete(record.id) }
        var repo = TrackedRepo(owner: "backup-test", name: "repo-\(UUID().uuidString.prefix(6))")
        repo.certificateID = record.id
        repo.bundleID = "com.example.restored"
        let source = SavedSource(url: URL(string: "https://example.com/\(UUID().uuidString).json")!, name: "Test Source")

        let url = try Paths.newTempDirectory().appendingPathComponent(Backup.suggestedFileName())
        defer { Paths.removeIfTemporary(url) }
        try Backup.create(Backup.Contents(certificates: [record], defaultCertificateID: record.id, sources: [source],
                                          repos: [repo], signingDefaults: SigningOptions(), library: []),
                          password: "correct horse", to: url)

        // Simulate a fresh install: the certificate, its files and its password are gone.
        certificates.delete(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.directory.path))
        XCTAssertNil(Keychain.get(record.id.uuidString))

        let opened = try Backup.open(url, password: "correct horse")
        let summary = Backup.apply(opened, certificates: certificates, library: library, sources: sources, github: github)
        defer {
            sources.delete(source.id)
            github.delete(repo.id)
        }
        XCTAssertEqual(summary.certificates, 1)
        XCTAssertEqual(summary.sources, 1)
        XCTAssertEqual(summary.repos, 1)
        XCTAssertTrue(summary.skipped.isEmpty, summary.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.folder.path), "temporary files are cleaned up")

        let restored = try XCTUnwrap(certificates.certificate(record.id))
        XCTAssertEqual(restored.password, "fixture")
        XCTAssertEqual(github.repo(repo.id)?.certificateID, record.id, "repo defaults still point at the certificate")

        let app = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let signed = try await Signer.shared.sign(app, with: restored, options: SigningOptions()) { _ in }
        defer { try? FileManager.default.removeItem(at: signed.directory) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: signed.ipaURL.path))

        // Restoring again adds nothing.
        let again = try Backup.open(url, password: "correct horse")
        let second = Backup.apply(again, certificates: certificates, library: library, sources: sources, github: github)
        XCTAssertEqual(second, Backup.Summary())
    }

    func testWrongPasswordChangesNothing() async throws {
        let certificates = CertificateStore()
        let record = try await importFixtureCertificate(into: certificates)
        defer { certificates.delete(record.id) }
        let url = try Paths.newTempDirectory().appendingPathComponent(Backup.suggestedFileName())
        defer { Paths.removeIfTemporary(url) }
        try Backup.create(Backup.Contents(certificates: [record], defaultCertificateID: nil, sources: [], repos: [],
                                          signingDefaults: SigningOptions(), library: []),
                          password: "right", to: url)
        let before = try FileManager.default.contentsOfDirectory(atPath: Paths.temp.path).count

        XCTAssertThrowsError(try Backup.open(url, password: "wrong")) { error in
            XCTAssertTrue(error.localizedDescription.contains("password"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: Paths.temp.path).count, before,
                       "nothing is unpacked before the password checks out")
    }

    func testRefusesCertificatesWithoutASavedPassword() throws {
        let record = CertificateRecord(
            nickname: "No Password", certificateName: "", teamName: "", teamID: "", profileName: "",
            applicationIdentifier: "", creationDate: Date(), expirationDate: Date(), provisionedDeviceCount: nil,
            provisionsAllDevices: false, entitlements: [:], certificateMatchesProfile: nil)
        let url = try Paths.newTempDirectory().appendingPathComponent("x.signetbackup")
        defer { Paths.removeIfTemporary(url) }
        XCTAssertThrowsError(try Backup.create(
            Backup.Contents(certificates: [record], defaultCertificateID: nil, sources: [], repos: [],
                            signingDefaults: SigningOptions(), library: []),
            password: "p", to: url, readPassword: { _ in nil })) { error in
            XCTAssertTrue(error.localizedDescription.contains("No Password"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRefusesBackupsFromNewerVersions() throws {
        let url = try Paths.newTempDirectory().appendingPathComponent("newer.signetbackup")
        defer { Paths.removeIfTemporary(url) }
        let manifest = Backup.Manifest(version: Backup.currentVersion + 1, created: Date(), appVersion: "9.9",
                                       certificates: [], passwords: try Backup.encrypt(Data("{}".utf8), password: "p", iterations: 1_000),
                                       defaultCertificateID: nil, sources: [], repos: [], signingDefaults: nil, library: [])
        let data = try JSONEncoder().encode(manifest)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
        XCTAssertThrowsError(try Backup.open(url, password: "p")) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version"))
        }
    }

    func testLibraryAppsRoundTrip() async throws {
        let certificates = CertificateStore(), library = LibraryStore(), sources = SourceStore(), github = GitHubStore()
        let app = try AppImporter.importIPA(at: fixture("Fixture.ipa"))
        library.add(app)
        defer { library.delete(app.id) }
        let files = FileManager.default.directorySize(at: app.directory)

        let url = try Paths.newTempDirectory().appendingPathComponent(Backup.suggestedFileName())
        defer { Paths.removeIfTemporary(url) }
        try Backup.create(Backup.Contents(certificates: [], defaultCertificateID: nil, sources: [], repos: [],
                                          signingDefaults: SigningOptions(), library: [app]),
                          password: "p", to: url)
        library.delete(app.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.path))

        let summary = Backup.apply(try Backup.open(url, password: "p"), certificates: certificates, library: library,
                                   sources: sources, github: github)
        XCTAssertEqual(summary.apps, 1)
        let restored = try XCTUnwrap(library.app(app.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appURL.appendingPathComponent("Info.plist").path))
        XCTAssertEqual(FileManager.default.directorySize(at: restored.directory), files)
    }

    func testOnlyExpectedPathsAreUnpacked() {
        let folder = URL(fileURLWithPath: "/tmp/restore")
        let id = UUID().uuidString
        XCTAssertNotNil(Backup.safeDestination(for: "Certificates/\(id)/certificate.p12", in: folder))
        XCTAssertNotNil(Backup.safeDestination(for: "Library/\(id)/Payload/App.app/Info.plist", in: folder))
        XCTAssertNil(Backup.safeDestination(for: "Certificates/\(id)/../../evil", in: folder))
        XCTAssertNil(Backup.safeDestination(for: "Certificates/not-a-uuid/file", in: folder))
        XCTAssertNil(Backup.safeDestination(for: "Other/\(id)/file", in: folder))
        XCTAssertNil(Backup.safeDestination(for: "manifest.json", in: folder))
    }

    func testPasswordEncryptionRoundTrips() throws {
        let blob = try Backup.encrypt(Data("secret".utf8), password: "pw", iterations: 1_000)
        XCTAssertEqual(try Backup.decrypt(blob, password: "pw"), Data("secret".utf8))
        XCTAssertThrowsError(try Backup.decrypt(blob, password: "nope"))
    }
}
