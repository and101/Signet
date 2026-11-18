import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(InstallManager.self) private var installer
    @Environment(GitHubStore.self) private var github
    @Environment(SourceStore.self) private var sources

    var body: some View {
        @Bindable var router = router
        @Bindable var library = library
        TabView(selection: $router.tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
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
        .sheet(isPresented: Binding(
            get: { installer.state != .idle },
            set: { if !$0 { installer.dismiss() } }
        )) {
            InstallProgressView()
                .presentationDetents([.medium])
        }
        .alert("Error", isPresented: Binding(
            get: { router.message != nil || library.lastError != nil },
            set: { if !$0 { router.message = nil; library.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.message ?? library.lastError ?? "")
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
        case .source: "Add This Source?"
        case .download: "Download This App?"
        case nil: ""
        }
    }

    private func linkAction(_ link: Router.PendingLink) -> String {
        switch link {
        case .source: "Add"
        case .download: "Download"
        }
    }
}
