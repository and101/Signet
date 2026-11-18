import XCTest
@testable import Signet

final class InstalledAppsTests: XCTestCase {
    private func app(_ kind: LibraryApp.Kind, _ bundleID: String, original: LibraryApp? = nil,
                     originalBundleID: String? = nil, age: TimeInterval = 0) -> LibraryApp {
        var app = LibraryApp(kind: kind, name: "App", bundleID: bundleID, version: "1", build: "1",
                             appFolderName: "App.app", size: 0)
        app.dateAdded = Date(timeIntervalSinceNow: -age)
        app.originalAppID = original?.id
        app.originalBundleID = originalBundleID ?? original?.bundleID
        return app
    }

    func testCandidatesIncludeEveryBundleIDTheAppWasSignedWith() {
        let source = app(.imported, "com.example.app")
        let older = app(.signed, "com.example.app.old", original: source, age: 100)
        let newer = app(.signed, "com.example.app.new", original: source, age: 10)
        // The original import was deleted and re-imported: matched by original bundle ID instead.
        let orphan = app(.signed, "com.example.app.orphan", originalBundleID: "com.example.app", age: 50)
        let unrelated = app(.signed, "org.other", originalBundleID: "org.other.source")

        let candidates = InstalledApps.candidates(for: source, in: [older, unrelated, newer, orphan])
        XCTAssertEqual(candidates, ["com.example.app", "com.example.app.new", "com.example.app.orphan", "com.example.app.old"])

        // Signing a signed copy looks for the same family.
        XCTAssertEqual(InstalledApps.candidates(for: newer, in: [older, newer]).first, "com.example.app")
        XCTAssertTrue(InstalledApps.candidates(for: newer, in: [older, newer]).contains("com.example.app.old"))
    }

    func testDetectionUsesTheSystemWhenItCanSeeInstalls() {
        let source = app(.imported, "com.example.app")
        let signed = app(.signed, "com.example.app.new", original: source)
        let installed: Set<String> = ["com.example.app.new"]
        let detection = InstalledApps.detect(for: source, in: [signed], check: { installed.contains($0) },
                                             history: ["com.example.app"])
        XCTAssertTrue(detection.systemCanSee)
        XCTAssertEqual(detection.matches, [.init(bundleID: "com.example.app.new", evidence: .installed)],
                       "history is ignored when the system answers")
    }

    func testDetectionFallsBackToHistoryAndSignedCopies() {
        let source = app(.imported, "com.example.app")
        let older = app(.signed, "com.example.app.old", original: source, age: 100)
        let newer = app(.signed, "com.example.app.new", original: source, age: 10)
        let detection = InstalledApps.detect(for: source, in: [older, newer], check: nil,
                                             history: ["com.example.app", "com.example.app.old"])
        XCTAssertFalse(detection.systemCanSee)
        XCTAssertEqual(detection.matches, [
            .init(bundleID: "com.example.app", evidence: .previouslyInstalled),
            .init(bundleID: "com.example.app.new", evidence: .signedBefore),
            .init(bundleID: "com.example.app.old", evidence: .previouslyInstalled),
        ])

        let fresh = InstalledApps.detect(for: source, in: [], check: nil, history: [])
        XCTAssertEqual(fresh, .init(systemCanSee: false, matches: []))
    }

    func testOnlyQueriesThatAnswerCorrectlyAreTrusted() {
        let me = Bundle.main.bundleIdentifier ?? ""
        let blind: InstalledApps.Check = { _ in false }       // hides everything, even us
        let yesMan: InstalledApps.Check = { _ in true }       // claims everything is installed
        let missing: InstalledApps.Check = { _ in nil }       // API unavailable
        let honest: InstalledApps.Check = { $0 == me || $0 == "com.example.app" }

        XCTAssertNil(InstalledApps.workingSystemCheck([blind, yesMan, missing]))
        let chosen = InstalledApps.workingSystemCheck([blind, yesMan, honest])
        XCTAssertEqual(chosen?("com.example.app"), true)
        XCTAssertEqual(chosen?("com.example.other"), false)
    }

    func testSystemQueriesOnThisDevice() throws {
        let me = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let results = [
            ("workspace", InstalledApps.workspaceCheck(me)),
            ("proxy", InstalledApps.proxyCheck(me)),
            ("record", InstalledApps.recordCheck(me)),
        ]
        print("Install queries for self:", results.map { "\($0.0)=\(String(describing: $0.1))" })
        guard InstalledApps.workingSystemCheck() != nil else {
            throw XCTSkip("No install query works here; the signed/installed-before fallback applies.")
        }
    }
}
