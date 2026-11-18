import Foundation
import Observation

@MainActor @Observable
final class CertificateStore {
    private(set) var certificates: [CertificateRecord] = []
    var defaultID: UUID? {
        didSet { UserDefaults.standard.set(defaultID?.uuidString, forKey: "defaultCertificate") }
    }

    private let file = JSONFile<[CertificateRecord]>("certificates.json")

    init() {
        certificates = file.load() ?? []
        // Certificates imported before the PPQ flag was recorded: read it from their saved profile.
        var filledIn = false
        for index in certificates.indices where certificates[index].ppqCheck == nil {
            if let profile = try? ProvisioningProfile(url: certificates[index].profileURL) {
                certificates[index].ppqCheck = profile.ppqCheck
                filledIn = true
            }
        }
        if filledIn { save() }
        defaultID = UserDefaults.standard.string(forKey: "defaultCertificate").flatMap(UUID.init)
        if defaultID == nil || !certificates.contains(where: { $0.id == defaultID }) {
            defaultID = certificates.first?.id
        }
    }

    var defaultCertificate: CertificateRecord? {
        certificates.first { $0.id == defaultID } ?? certificates.first
    }

    func certificate(_ id: UUID?) -> CertificateRecord? {
        certificates.first { $0.id == id }
    }

    func add(p12: URL, profile: URL, password: String, nickname: String) async throws {
        let record = try await Task.detached {
            try CertificateImporter.importCertificate(p12: p12, profile: profile, password: password, nickname: nickname)
        }.value
        certificates.append(record)
        if defaultID == nil { defaultID = record.id }
        save()
        await checkRevocation(record.id)
    }

    /// Adds a certificate restored from a backup. Its files and keychain password must already be in place.
    func restore(_ record: CertificateRecord) {
        guard certificate(record.id) == nil else { return }
        certificates.append(record)
        if defaultID == nil { defaultID = record.id }
        save()
    }

    func rename(_ id: UUID, to nickname: String) {
        guard let index = certificates.firstIndex(where: { $0.id == id }) else { return }
        certificates[index].nickname = nickname
        save()
    }

    func delete(_ id: UUID) {
        guard let record = certificate(id) else { return }
        try? FileManager.default.removeItem(at: record.directory)
        Keychain.delete(id.uuidString)
        certificates.removeAll { $0.id == id }
        if defaultID == id { defaultID = certificates.first?.id }
        save()
    }

    func checkRevocation(_ id: UUID) async {
        guard let record = certificate(id) else { return }
        let (status, _) = await CertificateImporter.checkRevocation(record)
        guard let index = certificates.firstIndex(where: { $0.id == id }) else { return }
        certificates[index].revocation = status
        certificates[index].revocationCheckedAt = Date()
        save()
    }

    func checkAll() async {
        for record in certificates {
            await checkRevocation(record.id)
        }
    }

    private func save() { file.save(certificates) }
}
