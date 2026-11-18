import XCTest
@testable import Signet

/// A damaged library.json must never lead to app folders being deleted.
@MainActor
final class LibraryIndexTests: XCTestCase {
    private let index = Paths.metadata.appendingPathComponent("library.json")
    private var savedIndex: Data?

    override func setUp() {
        super.setUp()
        Paths.prepare()
        savedIndex = try? Data(contentsOf: index)
        removePreservedCopies()
    }

    override func tearDown() {
        if let savedIndex { try? savedIndex.write(to: index) } else { try? FileManager.default.removeItem(at: index) }
        removePreservedCopies()
        super.tearDown()
    }

    private var preservedCopies: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Paths.metadata.path)) ?? [])
            .filter { $0.hasPrefix("library.unreadable-") }
    }

    private func removePreservedCopies() {
        for name in preservedCopies { try? FileManager.default.removeItem(at: Paths.metadata.appendingPathComponent(name)) }
    }

    /// An app folder old enough that Clean Up would treat it as an orphan if nothing claimed it.
    private func makeOldFolder() throws -> URL {
        let folder = Paths.library.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: folder.appendingPathComponent("App.ipa"))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: folder.path)
        return folder
    }

    func testCorruptIndexIsPreservedAndCleanUpKeepsFolders() async throws {
        let folder = try makeOldFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{ not json".utf8).write(to: index)

        let library = LibraryStore()
        XCTAssertTrue(library.indexIncomplete)
        XCTAssertEqual(preservedCopies.count, 1, "the damaged index is copied aside before anything overwrites it")

        await library.cleanUp(gracePeriod: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        // Still protected on a later launch, after a save has replaced the damaged file.
        try Data("[]".utf8).write(to: index)
        let relaunched = LibraryStore()
        XCTAssertFalse(relaunched.indexIncomplete)
        XCTAssertTrue(relaunched.hasPreservedIndex)
        await relaunched.cleanUp(gracePeriod: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testOneBadRecordDoesntHideTheRest() async throws {
        let good = LibraryApp(kind: .imported, name: "Good", bundleID: "com.example.good", version: "1", build: "1",
                              appFolderName: "Good.app", size: 1)
        try FileManager.default.createDirectory(at: good.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: good.directory) }
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let data = try JSONSerialization.data(withJSONObject: [goodJSON, ["id": "broken", "kind": "unknown"]])
        try data.write(to: index)

        let library = LibraryStore()
        XCTAssertEqual(library.apps.map(\.id), [good.id])
        XCTAssertTrue(library.indexIncomplete)
        XCTAssertEqual(preservedCopies.count, 1)
    }

    func testMissingIndexIsAFreshLibrary() {
        try? FileManager.default.removeItem(at: index)
        let library = LibraryStore()
        XCTAssertTrue(library.apps.isEmpty)
        XCTAssertFalse(library.indexIncomplete)
        XCTAssertTrue(preservedCopies.isEmpty)
    }
}
