import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(InstallManager.self) private var installer
    @Environment(SourceStore.self) private var sources
    @Environment(GitHubStore.self) private var github
    @State private var path = NavigationPath()
    @State private var selection = Set<UUID>()
    @State private var editMode = EditMode.inactive
    @State private var confirmDeleteSelection = false

    @State private var showImporter = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var importing = false
    @State private var importError: String?
    @State private var search = ""
    @State private var appToDelete: LibraryApp?
    @State private var downloadToCancel: LibraryStore.Download?

    private var hasNoApps: Bool {
        library.signedApps.isEmpty && library.importedApps.isEmpty && library.downloads.isEmpty && !importing
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selection) {
                let updates = sources.updates(for: library, github: github)
                if !updates.isEmpty, search.isEmpty {
                    Section {
                        ForEach(updates) { update in
                            UpdateRow(update: update) { imported in path.append(imported) }
                                .selectionDisabled()
                        }
                    } header: {
                        Text("Updates")
                    } footer: {
                        Text("Downloads the new version, then opens it for signing.")
                    }
                }

                if !library.downloads.isEmpty {
                    Section("Downloads") {
                        ForEach(library.downloads) { download in
                            DownloadRow(download: download)
                                .selectionDisabled()
                                .swipeToDelete("Cancel", systemImage: "xmark") { downloadToCancel = download }
                        }
                    }
                }

                if importing {
                    Section { LabeledContent("Importing…") { ProgressView() } }
                }

                if !filtered(library.signedApps).isEmpty {
                    Section("Signed") {
                        ForEach(filtered(library.signedApps)) { app in
                            NavigationLink(value: app) { AppRow(app: app) }
                                .swipeToDelete {
                                    appToDelete = app
                                } actions: {
                                    Button { Task { await installer.install(app) } } label: {
                                        Label("Install", systemImage: "arrow.down.app")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }

                if !filtered(library.importedApps).isEmpty {
                    Section("Imported") {
                        ForEach(filtered(library.importedApps)) { app in
                            NavigationLink(value: app) { AppRow(app: app) }
                                .swipeToDelete { appToDelete = app }
                        }
                    }
                }
            }
            .overlay {
                if hasNoApps {
                    ContentUnavailableView {
                        Label("No Apps", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Import an IPA from Files, a URL, or a source.")
                    } actions: {
                        Button("Import from Files") { showImporter = true }
                    }
                } else if !search.isEmpty, filtered(library.signedApps).isEmpty, filtered(library.importedApps).isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .destructiveConfirmation(
                item: $appToDelete,
                title: { "Delete \($0.name)?" },
                message: { $0.kind == .signed
                    ? "If the app is installed, it stays on your iPhone."
                    : "This removes it from your library."
                },
                perform: { library.delete($0.id) }
            )
            .destructiveConfirmation(
                item: $downloadToCancel,
                title: { "Cancel \($0.name)?" },
                message: { _ in "Its progress will be lost." },
                confirm: "Cancel Download",
                cancel: "Keep Downloading",
                perform: { library.cancel($0) }
            )
            .environment(\.editMode, $editMode)
            .onChange(of: editMode.isEditing) { _, editing in if !editing { selection = [] } }
            .confirmationDialog(
                "Delete \(selection.count) App\(selection.count == 1 ? "" : "s")?",
                isPresented: $confirmDeleteSelection,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    for id in selection { library.delete(id) }
                    selection = []
                    editMode = .inactive
                }
            } message: {
                Text("Installed apps stay on your iPhone.")
            }
            .navigationTitle("Library")
            .searchable(text: $search)
            .refreshable { await sources.refreshAll() }
            .navigationDestination(for: LibraryApp.self) { app in
                if app.kind == .signed {
                    SignedAppView(appID: app.id)
                } else {
                    SignView(app: app)
                }
            }
            .toolbar {
                if !library.apps.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(editMode.isEditing ? "Done" : "Select") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                    }
                }
                if editMode.isEditing {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) { confirmDeleteSelection = true } label: {
                            Text(selection.isEmpty ? "Delete" : "Delete (\(selection.count))")
                        }
                        .disabled(selection.isEmpty)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showImporter = true } label: { Label("Import from Files", systemImage: "folder") }
                        Button { showURLPrompt = true } label: { Label("Download from URL", systemImage: "link") }
                    } label: {
                        Label("Add App", systemImage: "plus")
                    }
                }
            }
            .copyingFileImporter(isPresented: $showImporter, allowedContentTypes: [.ipa, .zip, .data], allowsMultipleSelection: true) { urls in
                Task {
                    importing = true
                    defer { importing = false }
                    for url in urls {
                        do { try await library.importIPA(at: url, securityScoped: true) } catch { importError = error.localizedDescription }
                        Paths.removeIfTemporary(url) // the app is unpacked into the library; the IPA copy isn't needed
                    }
                }
            }
            .alert("Download IPA", isPresented: $showURLPrompt) {
                TextField("https://example.com/app.ipa", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Download") {
                    if let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true {
                        library.download(from: url)
                    } else {
                        importError = "That isn't a valid URL."
                    }
                    urlText = ""
                }
                Button("Cancel", role: .cancel) { urlText = "" }
            }
            .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func filtered(_ apps: [LibraryApp]) -> [LibraryApp] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }
}

private struct UpdateRow: View {
    let update: SourceUpdate
    let onImported: (LibraryApp) -> Void
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            RemoteIcon(url: update.iconURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(update.name).lineLimit(1)
                Text("\(update.localVersion) → \(update.remoteVersion) · \(update.sourceName)")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let download = library.download(for: update.downloadURL) {
                DownloadRing(download: download).frame(minWidth: 56)
            } else {
                Button("Update") {
                    library.download(from: update.downloadURL, name: "\(update.name) \(update.remoteVersion)",
                                     onImported: onImported)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .font(.subheadline.bold())
            }
        }
    }
}

private struct DownloadRow: View {
    let download: LibraryStore.Download

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(download.name).lineLimit(1)
            ProgressView(value: download.progress)
            Text(download.expected > 0
                 ? "\(download.received.formattedBytes) of \(download.expected.formattedBytes)"
                 : download.status)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
