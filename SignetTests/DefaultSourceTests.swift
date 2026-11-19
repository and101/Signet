import XCTest
@testable import Signet

final class DefaultSourceTests: XCTestCase {
    private let key = "addedSignetSource"

    @MainActor
    func testSignetSourceIsAddedOnceAndStaysDeleted() throws {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        // Start from a store without it.
        var store = SourceStore()
        for source in store.sources where source.url == SourceStore.signetSourceURL { store.delete(source.id) }

        UserDefaults.standard.removeObject(forKey: key)
        store = SourceStore()
        XCTAssertEqual(store.sources.filter { $0.url == SourceStore.signetSourceURL }.count, 1)
        XCTAssertEqual(store.sources.first?.url, SourceStore.signetSourceURL, "listed first")

        // Deleted by the user: not added back on the next launch.
        let id = try XCTUnwrap(store.sources.first { $0.url == SourceStore.signetSourceURL }?.id)
        store.delete(id)
        store = SourceStore()
        XCTAssertFalse(store.sources.contains { $0.url == SourceStore.signetSourceURL })
    }
}
