import XCTest
@testable import Signet

final class SourceUpdatesTests: XCTestCase {
    private func app(_ bundleID: String, _ version: String, kind: LibraryApp.Kind = .imported,
                     originalBundleID: String? = nil, sourceURL: String? = nil) -> LibraryApp {
        var app = LibraryApp(kind: kind, name: "App", bundleID: bundleID, version: version, build: "1",
                             appFolderName: "App.app", size: 0)
        app.originalBundleID = originalBundleID
        app.sourceURL = sourceURL
        return app
    }

    private func offer(_ bundleID: String?, _ version: String, source: String = "Repo",
                       url: String = "https://example.com/app.ipa", older: [String: String] = [:]) -> (sourceName: String, app: SourceApp) {
        var versions = [SourceAppVersion(version: version, downloadURL: URL(string: url))]
        versions += older.sorted { $0.key > $1.key }.map { SourceAppVersion(version: $0.key, downloadURL: URL(string: $0.value)) }
        return (source, SourceApp(name: "Remote", bundleIdentifier: bundleID, versions: versions))
    }

    func testVersionComparison() {
        XCTAssertEqual(SourceUpdates.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(SourceUpdates.compare("v2.0", "2.0"), .orderedSame)
        XCTAssertEqual(SourceUpdates.compare("2", "2.0.0"), .orderedSame)
        XCTAssertEqual(SourceUpdates.compare("2.0.1", "2.0"), .orderedDescending)
        XCTAssertEqual(SourceUpdates.compare("1.2.3", "1.12"), .orderedAscending)
    }

    func testFindsNewerVersion() throws {
        let updates = SourceUpdates.find(library: [app("com.a", "1.0")], offers: [offer("com.a", "1.1")])
        let update = try XCTUnwrap(updates["com.a"])
        XCTAssertEqual(update.localVersion, "1.0")
        XCTAssertEqual(update.remoteVersion, "1.1")
        XCTAssertEqual(update.downloadURL.absoluteString, "https://example.com/app.ipa")
    }

    func testNoUpdateWhenCurrentOrNewer() {
        XCTAssertTrue(SourceUpdates.find(library: [app("com.a", "1.1")], offers: [offer("com.a", "1.1")]).isEmpty)
        XCTAssertTrue(SourceUpdates.find(library: [app("com.a", "2.0")], offers: [offer("com.a", "1.9")]).isEmpty)
        XCTAssertTrue(SourceUpdates.find(library: [app("com.a", "1.0")], offers: [offer("com.b", "9.0")]).isEmpty)
        XCTAssertTrue(SourceUpdates.find(library: [app("com.a", "1.0")], offers: [offer(nil, "9.0")]).isEmpty)
    }

    func testSignedCopiesMatchByOriginalBundleID() {
        // A PPQ suffix or chosen bundle ID changes the signed app's ID; the original still matches.
        let signed = app("com.a.k3x9qa", "1.0", kind: .signed, originalBundleID: "com.a")
        XCTAssertNotNil(SourceUpdates.find(library: [signed], offers: [offer("com.a", "1.1")])["com.a"])
    }

    func testNewestCopyInLibraryCounts() {
        // An imported 1.1 next to a signed 1.0 means the update was already downloaded.
        let library = [app("com.a", "1.0", kind: .signed, originalBundleID: "com.a"), app("com.a", "1.1")]
        XCTAssertTrue(SourceUpdates.find(library: library, offers: [offer("com.a", "1.1")]).isEmpty)
    }

    func testPrefersTheSourceTheAppCameFrom() throws {
        let library = [app("com.a", "1.0", sourceURL: "https://mine.example/a-1.0.ipa")]
        let offers = [
            offer("com.a", "5.0", source: "Other", url: "https://other.example/a.ipa"),
            offer("com.a", "1.2", source: "Mine", url: "https://mine.example/a-1.2.ipa",
                  older: ["1.0": "https://mine.example/a-1.0.ipa"]),
        ]
        let update = try XCTUnwrap(SourceUpdates.find(library: library, offers: offers)["com.a"])
        XCTAssertEqual(update.sourceName, "Mine")
        XCTAssertEqual(update.remoteVersion, "1.2")
    }

    func testOtherwiseOffersTheNewest() throws {
        let offers = [offer("com.a", "1.2", source: "Old"), offer("com.a", "1.3", source: "New")]
        let update = try XCTUnwrap(SourceUpdates.find(library: [app("com.a", "1.0")], offers: offers)["com.a"])
        XCTAssertEqual(update.sourceName, "New")
    }

    func testExcludedAppsAreSkipped() {
        XCTAssertTrue(SourceUpdates.find(library: [app("com.a", "1.0")], offers: [offer("com.a", "1.1")],
                                         excluded: ["com.a"]).isEmpty)
    }
}
