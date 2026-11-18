import Crypto
import Foundation
import Security
import SwiftASN1
import X509

/// TLS identity for the on-device install server.
///
/// iOS only installs over itms-services when the manifest and IPA come from HTTPS that the system trusts.
/// Public "localhost" certificates (e.g. backloop.dev) publish their private key, so CAs revoke them and
/// installs silently fail. Instead the app mints its own CA once, issues a certificate for 127.0.0.1 and
/// localhost, then throws the CA's private key away. The user installs the CA as a profile and enables full
/// trust; because the CA key no longer exists, that trust can't be used to vouch for any other site.
///
/// iOS rejects install manifests on loopback hosts ("The manifest URL isn't external"), so URLs use a public
/// name whose DNS points at 127.0.0.1. local.backloop.dev is used because DNS filters with rebinding
/// protection commonly allow it while blocking other loopback names (nip.io, sslip.io, localtest.me).
enum ServerCertificate {
    static let hostname = "local.backloop.dev"

    static let certificateURL = Paths.server.appendingPathComponent("server.crt")
    static let keyURL = Paths.server.appendingPathComponent("server.pem")
    static let authorityURL = Paths.server.appendingPathComponent("ca.cer")
    // v2: certificates now cover `hostname`; older 127.0.0.1-only identities are replaced automatically.
    static let infoURL = Paths.server.appendingPathComponent("local-ca-v2.json")

    struct Info: Codable {
        var authorityName: String
        var created: Date
        var expires: Date

        var hostname: String { ServerCertificate.hostname }
        var isExpired: Bool { expires < Date() }
    }

    static var info: Info? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: certificateURL.path),
              fm.fileExists(atPath: keyURL.path),
              fm.fileExists(atPath: authorityURL.path),
              let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    /// Returns the current identity, creating one if needed.
    @discardableResult
    static func ensure() throws -> Info {
        if let info, !info.isExpired { return info }
        return try regenerate()
    }

    /// Creates a new CA and server certificate. The previously installed profile stops working.
    @discardableResult
    static func regenerate() throws -> Info {
        let now = Date()
        let tag = String(UUID().uuidString.prefix(8))

        let authorityKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let authorityName = try DistinguishedName {
            CommonName("Signet Local CA \(tag)")
            OrganizationName("Signet")
        }
        let authoritySKI = SubjectKeyIdentifier(hash: authorityKey.publicKey)
        let authority = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: authorityKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86_400),
            issuer: authorityName,
            subject: authorityName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                authoritySKI
            },
            issuerPrivateKey: authorityKey
        )

        // Apple rejects server certificates valid for more than 825 days, so stay under that.
        let expires = now.addingTimeInterval(800 * 86_400)
        let serverKey = P256.Signing.PrivateKey()
        let serverPublicKey = Certificate.PrivateKey(serverKey).publicKey
        let server = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: serverPublicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: expires,
            issuer: authorityName,
            subject: try DistinguishedName { CommonName(hostname) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([
                    .dnsName(hostname),
                    .dnsName("localhost"),
                    .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
                    .ipAddress(ASN1OctetString(contentBytes: ArraySlice([UInt8](repeating: 0, count: 15) + [1]))),
                ])
                SubjectKeyIdentifier(hash: serverPublicKey)
                AuthorityKeyIdentifier(keyIdentifier: authoritySKI.keyIdentifier)
            },
            issuerPrivateKey: authorityKey
        )
        // `authorityKey` goes out of scope here and is never written anywhere.

        let chain = try server.serializeAsPEM().pemString + "\n" + authority.serializeAsPEM().pemString + "\n"
        var der = DER.Serializer()
        try der.serialize(authority)
        let info = Info(authorityName: "Signet Local CA \(tag)", created: now, expires: expires)

        try FileManager.default.createDirectory(at: Paths.server, withIntermediateDirectories: true)
        try Data(chain.utf8).write(to: certificateURL, options: .atomic)
        try Data(serverKey.pemRepresentation.utf8).write(to: keyURL, options: [.atomic, .completeFileProtection])
        try Data(der.serializedBytes).write(to: authorityURL, options: .atomic)
        try JSONEncoder().encode(info).write(to: infoURL, options: .atomic)
        return info
    }

    /// Whether iOS currently trusts the server certificate, i.e. the CA profile is installed with full trust.
    static var isTrusted: Bool {
        guard let pem = try? String(contentsOf: certificateURL, encoding: .utf8),
              let authorityDER = try? Data(contentsOf: authorityURL),
              let serverEnd = pem.range(of: "-----END CERTIFICATE-----"),
              let server = try? Certificate(pemEncoded: String(pem[..<serverEnd.upperBound])) else { return false }
        var der = DER.Serializer()
        guard (try? der.serialize(server)) != nil,
              let serverRef = SecCertificateCreateWithData(nil, Data(der.serializedBytes) as CFData),
              let authorityRef = SecCertificateCreateWithData(nil, authorityDER as CFData) else { return false }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        guard SecTrustCreateWithCertificates([serverRef, authorityRef] as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// A configuration profile that installs the CA as a root certificate.
    static func profile() throws -> Data {
        guard let info else { throw AppError("No install certificate yet.") }
        let authority = try Data(contentsOf: authorityURL)
        let payload: [String: Any] = [
            "PayloadCertificateFileName": "SignetLocalCA.cer",
            "PayloadContent": authority,
            "PayloadDescription": "Lets Signet install apps from this iPhone.",
            "PayloadDisplayName": info.authorityName,
            "PayloadIdentifier": "ember.wax.signet.ca.root",
            "PayloadType": "com.apple.security.root",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
        ]
        let profile: [String: Any] = [
            "PayloadContent": [payload],
            "PayloadDescription": "Lets Signet install apps on this iPhone.",
            "PayloadDisplayName": "Signet Install Certificate",
            "PayloadIdentifier": "ember.wax.signet.ca",
            "PayloadOrganization": "Signet",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}
