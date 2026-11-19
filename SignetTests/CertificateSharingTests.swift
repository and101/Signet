import XCTest
@testable import Signet

final class CertificateSharingTests: XCTestCase {
    private let p12 = Data((0..<200).map { UInt8($0) }) // base64 of this includes + and /

    func testLiveContainerURLRoundTrips() throws {
        let url = try XCTUnwrap(CertificateSharing.liveContainerURL(p12: p12, password: "p&ss=word+1"))
        XCTAssertEqual(url.scheme, "livecontainer")
        XCTAssertEqual(url.host, "certificate")
        // Decode the way LiveContainer does: query items, then removingPercentEncoding on cert.
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let cert = try XCTUnwrap(items.first { $0.name == "cert" }?.value?.removingPercentEncoding)
        XCTAssertEqual(Data(base64Encoded: cert), p12)
        XCTAssertEqual(items.first { $0.name == "password" }?.value, "p&ss=word+1")
    }

    func testCallbackTemplateIsFilled() throws {
        let template = "livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)"
        let url = try XCTUnwrap(CertificateSharing.callbackURL(template: template, p12: p12, password: "a b&c"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let cert = try XCTUnwrap(items.first { $0.name == "cert" }?.value?.removingPercentEncoding)
        XCTAssertEqual(Data(base64Encoded: cert), p12)
        XCTAssertEqual(items.first { $0.name == "password" }?.value, "a b&c")
        XCTAssertEqual(CertificateSharing.scheme(of: template), "livecontainer")
    }

    func testRefusesWebAndFileCallbacks() {
        for template in ["https://evil.example/c?cert=$(BASE64_CERT)", "http://x/?c=$(BASE64_CERT)",
                         "file:///tmp/$(BASE64_CERT)", "javascript:$(BASE64_CERT)",
                         "mailto:me@example.com?body=$(BASE64_CERT)", "sms:123&body=$(BASE64_CERT)"] {
            XCTAssertNil(CertificateSharing.callbackURL(template: template, p12: p12, password: ""), template)
            XCTAssertFalse(CertificateSharing.isAppScheme(template), template)
        }
        XCTAssertNil(CertificateSharing.callbackURL(template: "livecontainer://nothing", p12: p12, password: ""),
                     "a template without the placeholder can't receive anything")
        // Browsers open web links from their own schemes, so they could forward a certificate anywhere.
        for template in ["googlechrome://evil.example/$(BASE64_CERT)", "firefox://open-url?url=https://evil.example/$(BASE64_CERT)",
                         "myapp://certificate?cert=$(BASE64_CERT)"] {
            XCTAssertNil(CertificateSharing.callbackURL(template: template, p12: p12, password: ""), template)
        }
    }

    func testParsesFeatherImportLinks() throws {
        let profile = Data("profile".utf8)
        var components = URLComponents(string: "signet://import-certificate")!
        components.queryItems = [
            URLQueryItem(name: "p12", value: p12.base64EncodedString()),
            URLQueryItem(name: "mobileprovision", value: profile.base64EncodedString()),
            URLQueryItem(name: "password", value: Data("secret".utf8).base64EncodedString()),
        ]
        let incoming = try XCTUnwrap(CertificateSharing.incoming(from: components.url!))
        XCTAssertEqual(incoming.p12, p12)
        XCTAssertEqual(incoming.profile, profile)
        XCTAssertEqual(incoming.password, "secret")
        XCTAssertNil(CertificateSharing.incoming(from: URL(string: "signet://import-certificate?p12=AAAA")!), "needs a profile too")
    }

    @MainActor
    func testRouterNeedsConfirmationForCertificateLinks() {
        let router = Router()
        let library = LibraryStore()
        let sources = SourceStore()
        router.handle(URL(string: "signet://certificate?callback_template=livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29")!,
                      library: library, sources: sources)
        XCTAssertEqual(router.pendingCertificateRequest, "livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)")
        router.pendingCertificateRequest = nil
        router.handle(URL(string: "signet://export-certificate?callback_template=https%3A%2F%2Fevil.example%2F%24%28BASE64_CERT%29")!,
                      library: library, sources: sources)
        XCTAssertNil(router.pendingCertificateRequest, "web callbacks are refused")
        XCTAssertNotNil(router.message)
    }

    func testDestinationShownInTheConfirmation() {
        XCTAssertEqual(CertificateSharing.destination(of: "livecontainer://certificate?cert=$(BASE64_CERT)"), "livecontainer://certificate")
        XCTAssertEqual(CertificateSharing.destination(of: "livecontainer:$(BASE64_CERT)"), "livecontainer://")
    }
}
