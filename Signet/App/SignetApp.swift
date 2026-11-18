import SwiftUI

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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                installer.appBecameActive()
                Task { await github.refreshAll(library: library) }
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
    var showAddCertificate = false
    /// A backup opened from another app, waiting for its password in Settings.
    var pendingBackup: URL?
    var message: String?

    func handle(_ url: URL, library: LibraryStore, sources: SourceStore) {
        if url.isFileURL {
            handleFile(url, library: library)
            return
        }
        // signet://source?url=…  |  signet://install?url=…
        guard url.scheme == "signet",
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value else { return }
        switch url.host {
        case "source":
            tab = .sources
            Task {
                do { try await sources.add(target) } catch { message = error.localizedDescription }
            }
        case "install", "download":
            if let remote = URL(string: target) {
                tab = .library
                library.download(from: remote)
            }
        default:
            break
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
