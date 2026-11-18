import XCTest
@testable import Signet

/// Serves a file over the real NIO + TLS stack using a self-signed localhost certificate.
final class InstallServerTests: XCTestCase {
    private final class TrustAll: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    func testServesManifestAndIPA() async throws {
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("Fixture.ipa").path) else {
            throw XCTSkip("Run scripts/make-test-fixtures.sh first.")
        }

        let restore = try backUpServerIdentity()
        defer { InstallServer.shared.stop(); restore() }
        try ServerCertificate.regenerate()

        let ipa = folder.appendingPathComponent("Fixture.ipa")
        let (token, itms) = try InstallServer.shared.host(.init(
            ipa: ipa, icon: nil, bundleID: "com.example.fixture", bundleVersion: "42", title: "Fixture"))
        XCTAssertEqual(itms.scheme, "itms-services")
        XCTAssertTrue(itms.absoluteString.hasPrefix("itms-services://?action=download-manifest&url=https%3A%2F%2F\(ServerCertificate.hostname)%3A"),
                      itms.absoluteString)

        let manifestString = try XCTUnwrap(URLComponents(url: itms, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value)
        XCTAssertTrue(manifestString.hasPrefix("https://\(ServerCertificate.hostname):"), "iOS rejects loopback manifest hosts")

        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        // The simulator doesn't trust the generated CA, and ATS won't let a delegate override trust for named
        // hosts, so fetch over the loopback IP (ATS-exempt). On device the user-trusted CA covers the name.
        let loopback = { (url: URL) in
            URL(string: url.absoluteString.replacingOccurrences(of: ServerCertificate.hostname, with: "127.0.0.1"))!
        }
        let (manifestData, _) = try await session.data(from: loopback(XCTUnwrap(URL(string: manifestString))))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any])
        let item = try XCTUnwrap((manifest["items"] as? [[String: Any]])?.first)
        XCTAssertEqual((item["metadata"] as? [String: String])?["bundle-identifier"], "com.example.fixture")
        XCTAssertEqual((item["metadata"] as? [String: String])?["bundle-version"], "42", "the build number, not the marketing version")

        let progress = expectation(description: "progress reported")
        progress.assertForOverFulfill = false
        InstallServer.shared.onProgress = { reported, sent, total in
            if reported == token, sent == total { progress.fulfill() }
        }
        let ipaURL = loopback(InstallServer.shared.baseURL(token).appendingPathComponent("app.ipa"))
        let (body, response) = try await session.data(from: ipaURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body, try Data(contentsOf: ipa))
        await fulfillment(of: [progress], timeout: 5)

        var ranged = URLRequest(url: ipaURL)
        ranged.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (part, partResponse) = try await session.data(for: ranged)
        XCTAssertEqual((partResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(part, try Data(contentsOf: ipa).subdata(in: 10..<20))

        // localhost may resolve to ::1 first, so the server must answer over IPv6 too.
        let v6 = try XCTUnwrap(URL(string: "https://[::1]:\(InstallServer.shared.port)/\(token)/manifest.plist"))
        let (v6Data, v6Response) = try await session.data(from: v6)
        XCTAssertEqual((v6Response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(v6Data, manifestData)

        let (_, missing) = try await session.data(from: loopback(InstallServer.shared.baseURL("nope").appendingPathComponent("app.ipa")))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
    }

    /// The generated certificate must pass Apple's own TLS policy once its CA is trusted, as iOS does
    /// after the user enables full trust for the installed profile.
    func testRestartsServerWhoseSocketsWereReclaimed() async throws {
        let restore = try backUpServerIdentity()
        defer { InstallServer.shared.stop(); restore() }
        try ServerCertificate.regenerate()

        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        let ping = { URL(string: "https://127.0.0.1:\(InstallServer.shared.port)/ping")! }

        try await InstallServer.shared.ensureResponsive()
        let (_, first) = try await session.data(from: ping())
        XCTAssertEqual((first as? HTTPURLResponse)?.statusCode, 200)

        InstallServer.shared.simulateReclaimedSockets()
        XCTAssertTrue(InstallServer.shared.isRunning, "NIO still reports the dead server as running")
        do {
            _ = try await session.data(from: ping())
            XCTFail("Closed server should not answer")
        } catch {}

        try await InstallServer.shared.ensureResponsive()
        let (_, revived) = try await session.data(from: ping())
        XCTAssertEqual((revived as? HTTPURLResponse)?.statusCode, 200)
    }

    func testGeneratedCertificatePassesSSLPolicyWhenCATrusted() throws {
        let restore = try backUpServerIdentity()
        defer { restore() }
        let info = try ServerCertificate.regenerate()
        XCTAssertGreaterThan(info.expires, Date().addingTimeInterval(790 * 86_400))
        XCTAssertLessThan(info.expires, Date().addingTimeInterval(825 * 86_400), "Apple rejects longer TLS lifetimes")
        XCTAssertFalse(ServerCertificate.isTrusted, "not trusted until the user installs the profile")

        let pem = try String(contentsOf: ServerCertificate.certificateURL, encoding: .utf8)
        let leafB64 = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")[1]
            .components(separatedBy: "-----END CERTIFICATE-----")[0]
            .components(separatedBy: .whitespacesAndNewlines).joined()
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, XCTUnwrap(Data(base64Encoded: leafB64)) as CFData))
        let ca = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(contentsOf: ServerCertificate.authorityURL) as CFData))

        for host in [ServerCertificate.hostname, "127.0.0.1", "localhost"] {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates([leaf, ca] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
            let evaluation = try XCTUnwrap(trust)
            SecTrustSetAnchorCertificates(evaluation, [ca] as CFArray)
            var error: CFError?
            XCTAssertTrue(SecTrustEvaluateWithError(evaluation, &error), "\(host): \(String(describing: error))")
        }

        // A different host must not be accepted.
        var other: SecTrust?
        SecTrustCreateWithCertificates([leaf, ca] as CFArray, SecPolicyCreateSSL(true, "example.com" as CFString), &other)
        SecTrustSetAnchorCertificates(other!, [ca] as CFArray)
        XCTAssertFalse(SecTrustEvaluateWithError(other!, nil))

        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: ServerCertificate.profile(), format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payload["PayloadContent"] as? Data, try Data(contentsOf: ServerCertificate.authorityURL))
    }

    /// Moves any existing identity aside and returns a closure that puts it back.
    private func backUpServerIdentity() throws -> () -> Void {
        Paths.prepare()
        let fm = FileManager.default
        let backup = try Paths.newTempDirectory()
        let files = [ServerCertificate.certificateURL, ServerCertificate.keyURL,
                     ServerCertificate.authorityURL, ServerCertificate.infoURL]
        for file in files where fm.fileExists(atPath: file.path) {
            try fm.moveItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent))
        }
        return {
            for file in files {
                try? fm.removeItem(at: file)
                let saved = backup.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: saved.path) { try? fm.moveItem(at: saved, to: file) }
            }
        }
    }
}
