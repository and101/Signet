import XCTest
@testable import Signet

@MainActor
final class StorageCleanupTests: XCTestCase {
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        Paths.prepare()
    }

    private func makeOld(_ url: URL) throws {
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 60 * 60)], ofItemAtPath: url.path)
    }

    func testRemoveIfTemporaryDeletesPickedFileFolder() throws {
        let folder = try Paths.newTempDirectory()
        let file = folder.appendingPathComponent("cert.p12")
        try Data("x".utf8).write(to: file)

        Paths.removeIfTemporary(file)

        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        XCTAssertTrue(fm.fileExists(atPath: Paths.temp.path))
    }

    func testRemoveIfTemporaryIgnoresFilesOutsideTemp() throws {
        let file = Paths.metadata.appendingPathComponent("keep-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? fm.removeItem(at: file) }

        Paths.removeIfTemporary(file)

        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }

    func testClearTemporaryFilesKeepsRecentItemsWhenAgeGiven() throws {
        let recent = try Paths.newTempDirectory()
        let old = try Paths.newTempDirectory()
        try makeOld(old)

        Paths.clearTemporaryFiles(olderThan: 10 * 60)

        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        try? fm.removeItem(at: recent)
    }

    func testCleanUpRemovesBrokenEntriesAndOldOrphanFolders() async throws {
        let store = LibraryStore()

        // A signed entry whose IPA was deleted in the Files app.
        var signed = LibraryApp(kind: .signed, name: "Gone", bundleID: "com.example.gone", version: "1.0",
                                build: "1", appFolderName: "Gone.app", size: 0)
        try fm.createDirectory(at: signed.directory, withIntermediateDirectories: true)
        try Data().write(to: signed.iconURL)
        signed.size = 1
        store.add(signed)

        // An untracked folder left by an interrupted sign, plus one that may still be in progress.
        let oldOrphan = Paths.library.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let newOrphan = Paths.library.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: oldOrphan, withIntermediateDirectories: true)
        try fm.createDirectory(at: newOrphan, withIntermediateDirectories: true)
        try makeOld(oldOrphan)
        defer { try? fm.removeItem(at: newOrphan) }

        let removed = await store.cleanUp()

        XCTAssertEqual(removed, 1)
        XCTAssertNil(store.app(signed.id))
        XCTAssertFalse(fm.fileExists(atPath: signed.directory.path))
        XCTAssertFalse(fm.fileExists(atPath: oldOrphan.path))
        XCTAssertTrue(fm.fileExists(atPath: newOrphan.path))
    }
}
