import XCTest
@testable import Signet

final class LinkTests: XCTestCase {
    func testAcceptsWebLinks() {
        let source = URL(string: "https://example.com/source.json")!
        XCTAssertEqual(Router.link(host: "source", target: source.absoluteString, http: false), .source(source))
        let ipa = URL(string: "https://example.com/app.ipa")!
        XCTAssertEqual(Router.link(host: "install", target: ipa.absoluteString, http: false), .download(ipa))
        XCTAssertEqual(Router.link(host: "download", target: " \(ipa.absoluteString)\n", http: false), .download(ipa))
    }

    func testRejectsOtherSchemesAndHosts() {
        XCTAssertNil(Router.link(host: "install", target: "file:///etc/passwd", http: false))
        XCTAssertNil(Router.link(host: "install", target: "itms-services://?action=download-manifest", http: false))
        XCTAssertNil(Router.link(host: "source", target: "javascript:alert(1)", http: false))
        XCTAssertNil(Router.link(host: "install", target: "https://", http: false))
        XCTAssertNil(Router.link(host: "install", target: "not a url", http: false))
        XCTAssertNil(Router.link(host: "delete", target: "https://example.com/app.ipa", http: false))
        XCTAssertNil(Router.link(host: nil, target: "https://example.com/app.ipa", http: false))
    }

    func testHTTPLinksAreAcceptedAndKeepTheirURL() {
        // Fetched over https with the setting off, as plain http with it on; either way the link keeps the URL given,
        // which the stores resolve and match sources and downloads by.
        let ipa = URL(string: "http://example.com/app.ipa")!
        XCTAssertEqual(Router.link(host: "install", target: ipa.absoluteString, http: true), .download(ipa))
        XCTAssertEqual(Router.link(host: "install", target: ipa.absoluteString, http: false), .download(ipa))
        let source = URL(string: "http://example.com/source.json")!
        XCTAssertEqual(Router.link(host: "source", target: source.absoluteString, http: false), .source(source))
        XCTAssertNil(Router.link(host: "install", target: "file:///etc/passwd", http: true))
        XCTAssertNil(Router.link(host: "install", target: "http://user:pass@example.com/app.ipa", http: false))
    }
}
