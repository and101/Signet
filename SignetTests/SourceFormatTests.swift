import XCTest
@testable import Signet
import SwiftUI

final class SourceFormatTests: XCTestCase {
    private func decode(_ json: String) throws -> SourceRepository {
        try JSONDecoder().decode(SourceRepository.self, from: Data(json.utf8))
    }

    func testReadsNewsFeaturedAndScreenshots() throws {
        let repo = try decode("""
        {
          "name": "Repo", "tintColor": "#C8382A", "website": "https://example.com",
          "featuredApps": ["com.b", "com.missing"],
          "news": [
            {"title": "Hello", "identifier": "n1", "caption": "Welcome", "imageURL": "https://example.com/n.png", "appID": "com.a"},
            {"caption": "no title, skipped"}
          ],
          "apps": [
            {"name": "A", "bundleIdentifier": "com.a", "screenshots": ["https://example.com/1.png", {"imageURL": "https://example.com/2.png"}]},
            {"name": "B", "bundleIdentifier": "com.b", "screenshots": {"iphone": ["https://example.com/p.png"], "ipad": [{"imageURL": "https://example.com/t.png"}]}},
            {"name": "C", "bundleIdentifier": "com.c", "screenshotURLs": ["https://example.com/old.png"]},
            {"name": "D", "bundleIdentifier": "com.d", "screenshots": 42}
          ]
        }
        """)
        XCTAssertEqual(repo.news.map(\.title), ["Hello"], "a news item without a title is skipped, not the source")
        XCTAssertEqual(repo.news.first?.appID, "com.a")
        XCTAssertEqual(repo.featured.map(\.name), ["B"], "featured apps the source doesn't list are skipped")
        XCTAssertEqual(repo.website?.host, "example.com")
        XCTAssertEqual(repo.apps.count, 4, "an unreadable screenshots field doesn't drop the app")

        let a = repo.apps[0], b = repo.apps[1], c = repo.apps[2], d = repo.apps[3]
        XCTAssertEqual(a.screenshotList(iPad: false).map(\.lastPathComponent), ["1.png", "2.png"])
        XCTAssertEqual(b.screenshotList(iPad: false).map(\.lastPathComponent), ["p.png"])
        XCTAssertEqual(b.screenshotList(iPad: true).map(\.lastPathComponent), ["t.png"])
        XCTAssertEqual(a.screenshotList(iPad: true).map(\.lastPathComponent), ["1.png", "2.png"], "iPad falls back to iPhone shots")
        XCTAssertEqual(c.screenshotList(iPad: false).map(\.lastPathComponent), ["old.png"])
        XCTAssertEqual(d.screenshotList(iPad: false), [])
    }

    func testOlderSourcesStillDecode() throws {
        let repo = try decode(#"{"name": "Plain", "apps": [{"name": "A"}]}"#)
        XCTAssertEqual(repo.news, [])
        XCTAssertEqual(repo.featured, [])
        XCTAssertEqual(repo.apps.first?.screenshotList(iPad: false), [])
    }

    func testHexColours() {
        XCTAssertNotNil(Color(hex: "#C8382A"))
        XCTAssertNotNil(Color(hex: "c8382a"))
        XCTAssertNil(Color(hex: "#FFF"))
        XCTAssertNil(Color(hex: "red"))
        XCTAssertNil(Color(hex: nil))
    }
}
