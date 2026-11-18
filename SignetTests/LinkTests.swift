import XCTest
@testable import Signet

final class LinkTests: XCTestCase {
    func testAcceptsWebLinks() {
        let source = URL(string: "https://example.com/source.json")!
        XCTAssertEqual(Router.link(host: "source", target: source.absoluteString), .source(source))
        let ipa = URL(string: "http://example.com/app.ipa")!
        XCTAssertEqual(Router.link(host: "install", target: ipa.absoluteString), .download(ipa))
        XCTAssertEqual(Router.link(host: "download", target: " \(ipa.absoluteString)\n"), .download(ipa))
    }

    func testRejectsOtherSchemesAndHosts() {
        XCTAssertNil(Router.link(host: "install", target: "file:///etc/passwd"))
        XCTAssertNil(Router.link(host: "install", target: "itms-services://?action=download-manifest"))
        XCTAssertNil(Router.link(host: "source", target: "javascript:alert(1)"))
        XCTAssertNil(Router.link(host: "install", target: "https://"))
        XCTAssertNil(Router.link(host: "install", target: "not a url"))
        XCTAssertNil(Router.link(host: "delete", target: "https://example.com/app.ipa"))
        XCTAssertNil(Router.link(host: nil, target: "https://example.com/app.ipa"))
    }
}
