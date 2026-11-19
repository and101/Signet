import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(InstallManager.self) private var installer
    @Environment(GitHubStore.self) private var github
    @Environment(SourceStore.self) private var sources
    @Environment(CertificateStore.self) private var certificates

    var body: some View {
        @Bindable var router = router
        @Bindable var library = library
        TabView(selection: $router.tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .badge(sources.updates(for: library, github: github).count)
                .tag(Router.Tab.library)
            SourcesView()
                .tabItem { Label("Sources", systemImage: "globe") }
                .badge(github.updateCount(in: library))
                .tag(Router.Tab.sources)
            CertificatesView()
                .tabItem { Label("Certificates", systemImage: "checkmark.seal") }
                .tag(Router.Tab.certificates)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Router.Tab.settings)
        }
        // Scene phase changes cover returning to the app; this covers a cold launch. Checks are throttled.
        .task { await github.refreshAll(library: library) }
        .task { await sources.refreshIfStale() }
        .sheet(isPresented: Binding(
            get: { installer.state != .idle },
            set: { if !$0 { installer.dismiss() } }
        )) {
            InstallProgressView()
                .presentationDetents([.medium, .large]) // long failure messages can be expanded
        }
        .alert("Error", isPresented: Binding(
            get: { router.message != nil || library.lastError != nil },
            set: { if !$0 { router.message = nil; library.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.message ?? library.lastError ?? "")
        }
        .alert("Signet Updated", isPresented: Binding(
            get: { installer.selfUpdateResult != nil },
            set: { if !$0 { installer.selfUpdateResult = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installer.selfUpdateResult ?? "")
        }
        .alert("Send a Certificate?", isPresented: Binding(
            get: { router.pendingCertificateRequest != nil },
            set: { if !$0 { router.pendingCertificateRequest = nil } }
        )) {
            Button("Send") {
                let template = router.pendingCertificateRequest ?? ""
                Task { await router.sendCertificate(to: template, certificate: certificates.defaultCertificate) }
            }
            Button("Cancel", role: .cancel) { router.pendingCertificateRequest = nil }
        } message: {
            let app = router.pendingCertificateRequest.flatMap(CertificateSharing.scheme(of:)) ?? "another app"
            Text("\(app) is asking for \(certificates.defaultCertificate?.nickname ?? "your certificate") and its password. Anyone with them can sign apps as you, so only send it to apps you trust.")
        }
        .alert("Add This Certificate?", isPresented: Binding(
            get: { router.pendingIncomingCertificate != nil },
            set: { if !$0 { router.pendingIncomingCertificate = nil } }
        )) {
            Button("Review") { router.addIncomingCertificate() }
            Button("Cancel", role: .cancel) { router.pendingIncomingCertificate = nil }
        } message: {
            Text("A link sent a certificate and provisioning profile. You can check them before saving.")
        }
        .alert(
            linkTitle(router.pendingLink),
            isPresented: Binding(
                get: { router.pendingLink != nil },
                set: { if !$0 { router.pendingLink = nil } }
            ),
            presenting: router.pendingLink
        ) { link in
            Button(linkAction(link)) { router.confirm(link, library: library, sources: sources) }
            Button("Cancel", role: .cancel) { router.pendingLink = nil }
        } message: { link in
            Text(link.url.absoluteString)
        }
    }

    private func linkTitle(_ link: Router.PendingLink?) -> String {
        switch link {
        case .source: String(localized: "Add This Source?")
        case .download: String(localized: "Download This App?")
        case nil: ""
        }
    }

    private func linkAction(_ link: Router.PendingLink) -> String {
        switch link {
        case .source: String(localized: "Add")
        case .download: String(localized: "Download")
        }
    }
}
