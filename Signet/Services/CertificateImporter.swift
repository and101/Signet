import Foundation
import Security
import ZsignC

struct ProvisioningProfile {
    let name: String
    let teamName: String
    let teamID: String
    let applicationIdentifier: String
    let creationDate: Date
    let expirationDate: Date
    let provisionedDevices: [String]?
    let provisionsAllDevices: Bool
    /// Apple checks apps signed with this profile online when they launch ("PPQ").
    let ppqCheck: Bool
    let entitlements: [String: Any]
    let developerCertificates: [Data]

    /// Profiles are CMS-signed plists; the XML payload sits in the clear inside the envelope.
    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            throw AppError("That doesn't look like a provisioning profile.")
        }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            throw AppError("Couldn't read the provisioning profile.")
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        name = plist["Name"] as? String ?? "Unknown Profile"
        teamName = plist["TeamName"] as? String ?? "Unknown Team"
        teamID = (plist["TeamIdentifier"] as? [String])?.first ?? ""
        applicationIdentifier = entitlements["application-identifier"] as? String ?? ""
        creationDate = plist["CreationDate"] as? Date ?? Date()
        expirationDate = plist["ExpirationDate"] as? Date ?? Date()
        provisionedDevices = plist["ProvisionedDevices"] as? [String]
        provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        ppqCheck = plist["PPQCheck"] as? Bool ?? false
        self.entitlements = entitlements
        developerCertificates = plist["DeveloperCertificates"] as? [Data] ?? []
    }
}

enum CertificateImporter {
    /// Validates a p12/profile pair and copies both into the app's storage.
    static func importCertificate(p12: URL, profile: URL, password: String, nickname: String) throws -> CertificateRecord {
        let parsed = try ProvisioningProfile(url: profile)

        guard p12_password_check(p12.path, password) else {
            throw AppError("Wrong password, or the .p12 is invalid.")
        }

        // Security.framework gives us the certificate's common name and DER bytes.
        // It can reject some newer p12 encodings even when OpenSSL accepts them, so this part is best-effort.
        // Decrypted once (key derivation can be slow on a phone) and used for both the name and the profile match.
        let identityCerts = (try? loadCertificates(p12: p12, password: password)) ?? []
        let commonName = identityCerts.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let matches: Bool? = identityCerts.isEmpty ? nil
            : identityCerts.contains { parsed.developerCertificates.contains(SecCertificateCopyData($0) as Data) }

        var record = CertificateRecord(
            nickname: nickname.isEmpty ? parsed.name : nickname,
            certificateName: commonName ?? parsed.teamName,
            teamName: parsed.teamName,
            teamID: parsed.teamID,
            profileName: parsed.name,
            applicationIdentifier: parsed.applicationIdentifier,
            creationDate: parsed.creationDate,
            expirationDate: parsed.expirationDate,
            provisionedDeviceCount: parsed.provisionedDevices?.count,
            provisionsAllDevices: parsed.provisionsAllDevices,
            entitlements: parsed.entitlements.mapValues(describe),
            certificateMatchesProfile: matches
        )
        record.id = UUID()
        record.ppqCheck = parsed.ppqCheck

        let fm = FileManager.default
        try fm.createDirectory(at: record.directory, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: p12, to: record.p12URL)
            try fm.copyItem(at: profile, to: record.profileURL)
        } catch {
            try? fm.removeItem(at: record.directory)
            throw error
        }
        do {
            try Keychain.set(password, for: record.id.uuidString)
        } catch {
            try? fm.removeItem(at: record.directory)
            throw error
        }
        return record
    }

    static func checkRevocation(_ record: CertificateRecord) async -> (RevocationStatus, String?) {
        await withCheckedContinuation { continuation in
            checkCert(record.profileURL.path, record.p12URL.path, record.password) { status, _, error in
                continuation.resume(returning: (RevocationStatus(ocspStatus: status), error))
            }
        }
    }

    /// Whether the profile includes one of the p12's certificates; nil when Security.framework can't read the p12.
    /// Every identity is checked: a p12 may hold several, and zsign may use one that isn't listed first.
    static func certificateMatches(p12: URL, password: String, profile: ProvisioningProfile) -> Bool? {
        guard let certificates = try? loadCertificates(p12: p12, password: password), !certificates.isEmpty else { return nil }
        return certificates.contains { profile.developerCertificates.contains(SecCertificateCopyData($0) as Data) }
    }

    private static func loadCertificate(p12: URL, password: String) throws -> SecCertificate {
        guard let first = try loadCertificates(p12: p12, password: password).first else { throw AppError("No certificate in p12.") }
        return first
    }

    /// The certificate of every identity in the p12, in the order Security.framework lists them.
    private static func loadCertificates(p12: URL, password: String) throws -> [SecCertificate] {
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess, let entries = items as? [[String: Any]] else {
            throw AppError("Couldn't read the .p12 (\(status)).")
        }
        return entries.compactMap { entry in
            guard let identityRef = entry[kSecImportItemIdentity as String] else { return nil }
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identityRef as! SecIdentity, &certificate)
            return certificate
        }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "true" : "false"
        case let array as [Any]: return array.map(describe).joined(separator: ", ")
        case let dict as [String: Any]: return dict.keys.sorted().joined(separator: ", ")
        default: return "\(value)"
        }
    }
}
