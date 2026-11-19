import SwiftUI
import UIKit

@main
struct SignetApp: App {
    @State private var certificates = CertificateStore()
    @State private var library = LibraryStore()
    @State private var sources = SourceStore()
    @State private var github = GitHubStore()
    @State private var installer = InstallManager()
    @State private var router = Router()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Nothing can be using temporary files yet, so leftovers from earlier runs are safe to delete.
        Paths.clearTemporaryFiles()
        CryptoSetup.loadProviders()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(certificates)
                .environment(library)
                .environment(sources)
                .environment(github)
                .environment(installer)
                .environment(router)
                .onOpenURL { router.handle($0, library: library, sources: sources) }
                .task {
                    installer.teamLookup = { [certificates] id in certificates.certificate(id)?.teamID }
                    installer.checkPendingSelfUpdate()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                installer.appBecameActive()
                Task { await github.refreshAll(library: library) }
                Task { await sources.refreshIfStale() }
            }
        }
    }
}

/// Handles files and links opened from other apps.
@MainActor @Observable
final class Router {
    enum Tab: Hashable { case library, sources, certificates, settings }

    var tab: Tab = .library
    var pendingP12: URL?
    var pendingProfile: URL?
    /// A password that came with a certificate link, filled in on the Add Certificate screen.
    var pendingPassword: String?
    /// Another app asking for a certificate through a callback link, waiting for the user to agree.
    var pendingCertificateRequest: String?
    /// A certificate sent to Signet in a link, waiting for the user to agree to add it.
    var pendingIncomingCertificate: CertificateSharing.IncomingCertificate?
    var showAddCertificate = false
    /// A backup opened from another app, waiting for its password in Settings.
    var pendingBackup: URL?
    /// A `signet://` link waiting for the user to confirm it.
    var pendingLink: PendingLink?
    var message: String?

    enum PendingLink: Equatable {
        case source(URL)
        case download(URL)

        var url: URL {
            switch self {
            case .source(let url), .download(let url): url
            }
        }
    }

    func handle(_ url: URL, library: LibraryStore, sources: SourceStore) {
        if url.isFileURL {
            handleFile(url, library: library)
            return
        }
        guard url.scheme == "signet" else { return }
        // signet://certificate?callback_template=…: the request LiveContainer sends to SideStore and AltStore.
        // export-certificate is Feather's name for the same request.
        if url.host == "certificate" || url.host == "export-certificate" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let template = items.first(where: { $0.name.lowercased() == "callback_template" })?.value
                .map({ $0.removingPercentEncoding ?? $0 }),
                CertificateSharing.isAppScheme(template), template.contains("$(BASE64_CERT)") else {
                message = "That certificate request isn't valid."
                return
            }
            pendingCertificateRequest = template
            return
        }
        // signet://import-certificate?p12=…&mobileprovision=…&password=… (Feather's format)
        if url.host == "import-certificate" {
            guard let incoming = CertificateSharing.incoming(from: url) else {
                message = "That certificate link is incomplete."
                return
            }
            pendingIncomingCertificate = incoming
            return
        }
        // signet://source?url=…  |  signet://install?url=…
        guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value else { return }
        // Any web page can open these links, so nothing happens until the user confirms.
        guard let link = Self.link(host: url.host, target: target) else {
            message = "Signet can only open http and https links."
            return
        }
        pendingLink = link
    }

    /// Parses a `signet://` link's target, accepting only web URLs. Returns nil for unknown hosts or other schemes.
    nonisolated static func link(host: String?, target: String) -> PendingLink? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remote = URL(string: trimmed),
              let scheme = remote.scheme?.lowercased(), scheme == "http" || scheme == "https",
              remote.host?.isEmpty == false else { return nil }
        switch host {
        case "source": return .source(remote)
        case "install", "download": return .download(remote)
        default: return nil
        }
    }

    /// Sends the default certificate to the app that asked, after Face ID.
    func sendCertificate(to template: String, certificate: CertificateRecord?) async {
        pendingCertificateRequest = nil
        guard let certificate else {
            message = "Add a certificate first."
            return
        }
        do {
            try await CertificateSharing.authenticate(reason: "Send \(certificate.nickname) to another app")
            let p12 = try Data(contentsOf: certificate.p12URL)
            guard let url = CertificateSharing.callbackURL(template: template, p12: p12, password: certificate.password),
                  await UIApplication.shared.open(url) else {
                message = "Couldn't open the app that asked for the certificate."
                return
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Opens Add Certificate filled in with a certificate that came in a link.
    func addIncomingCertificate() {
        guard let incoming = pendingIncomingCertificate else { return }
        pendingIncomingCertificate = nil
        do {
            let folder = try Paths.newTempDirectory()
            let p12 = folder.appendingPathComponent("Certificate.p12")
            let profile = folder.appendingPathComponent("Profile.mobileprovision")
            try incoming.p12.write(to: p12)
            try incoming.profile.write(to: profile)
            pendingP12 = p12
            pendingProfile = profile
            pendingPassword = incoming.password
            tab = .certificates
            showAddCertificate = true
        } catch {
            message = error.localizedDescription
        }
    }

    func confirm(_ link: PendingLink, library: LibraryStore, sources: SourceStore) {
        pendingLink = nil
        switch link {
        case .source(let remote):
            tab = .sources
            Task {
                do { try await sources.add(remote.absoluteString) } catch { message = error.localizedDescription }
            }
        case .download(let remote):
            tab = .library
            library.download(from: remote)
        }
    }

    private func handleFile(_ url: URL, library: LibraryStore) {
        // Files opened via "Open in" may be security scoped; copy them somewhere we own first.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let copy = Paths.temp.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            // iOS hands over its own copy in Documents/Inbox; move it rather than leave a second copy there.
            if url.standardizedFileURL.path.hasPrefix(Paths.inbox.standardizedFileURL.path + "/") {
                try FileManager.default.moveItem(at: url, to: copy)
            } else {
                try FileManager.default.copyItem(at: url, to: copy)
            }
        } catch {
            message = error.localizedDescription
            return
        }

        switch url.pathExtension.lowercased() {
        case "ipa", "tipa":
            tab = .library
            Task {
                do { try await library.importIPA(at: copy) } catch { message = error.localizedDescription }
                Paths.removeIfTemporary(copy)
            }
        case "p12":
            pendingP12 = copy
            tab = .certificates
            showAddCertificate = true
        case "mobileprovision":
            pendingProfile = copy
            tab = .certificates
            showAddCertificate = true
        case Backup.fileExtension:
            pendingBackup = copy
            tab = .settings
        default:
            message = "Unsupported file type: .\(url.pathExtension)"
        }
    }
}
