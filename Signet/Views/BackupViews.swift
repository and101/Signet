import SwiftUI

/// State for the backup and restore flow. Owned by the Settings screen so list redraws can't reset it.
@MainActor @Observable
final class BackupFlow {
    var showExport = false
    var showPicker = false
    var showPasswordPrompt = false
    var password = ""
    var restoring = false
    var result: String?
    var error: String?
    private(set) var restoreFile: URL?

    func promptForPassword(_ file: URL) {
        discardRestoreFile()
        restoreFile = file
        showPasswordPrompt = true
    }

    func discardRestoreFile() {
        if let restoreFile { Paths.removeIfTemporary(restoreFile) }
        restoreFile = nil
        password = ""
    }

    /// Takes the file and password now, before the alert's dismissal can change any state.
    func takeRestoreRequest() -> (file: URL, password: String)? {
        guard let file = restoreFile else { return nil }
        let request = (file, password)
        restoreFile = nil
        password = ""
        return request
    }
}

/// Settings section with the backup buttons. Its sheet, file picker and alerts are attached to the whole screen
/// with `backupPresentations(_:)`: presentations attached to a list row are dismissed when the list redraws.
struct BackupSection: View {
    let flow: BackupFlow

    var body: some View {
        Section {
            Button { flow.showExport = true } label: {
                Label { Text("Back Up…") } icon: { SettingsIcon("arrow.up.doc.fill", color: .blue) }
            }
            .tint(.primary)
            Button { flow.showPicker = true } label: {
                LabeledContent {
                    if flow.restoring { ProgressView() }
                } label: {
                    Label { Text("Restore from Backup…") } icon: {
                        SettingsIcon("arrow.down.doc.fill", color: .orange)
                    }
                }
            }
            .tint(.primary)
            .disabled(flow.restoring)
        } header: {
            Text("Backup")
        } footer: {
            Text("Save certificates, sources, repos and settings to one file. Keep a copy outside Signet, like in iCloud Drive.")
        }
    }
}

extension View {
    func backupPresentations(_ flow: BackupFlow) -> some View {
        modifier(BackupPresentations(flow: flow))
    }
}

private struct BackupPresentations: ViewModifier {
    @Bindable var flow: BackupFlow
    @Environment(CertificateStore.self) private var certificates
    @Environment(LibraryStore.self) private var library
    @Environment(SourceStore.self) private var sources
    @Environment(GitHubStore.self) private var github
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.showExport) {
                BackupExportView()
            }
            .copyingFileImporter(isPresented: $flow.showPicker, allowedContentTypes: [.signetBackup, .zip, .data]) { urls in
                guard let url = urls.first else { return }
                do { flow.promptForPassword(try copyPickedFile(url)) } catch { flow.error = error.localizedDescription }
            }
            .onChange(of: router.pendingBackup, initial: true) { _, pending in
                if let pending {
                    router.pendingBackup = nil
                    flow.promptForPassword(pending)
                }
            }
            // Dismissing only hides the alert. The buttons decide what happens to the file, because SwiftUI may
            // dismiss the alert before a button's work runs.
            .alert("Restore Backup", isPresented: $flow.showPasswordPrompt) {
                SecureField("Backup Password", text: $flow.password)
                Button("Restore") { startRestore() }
                Button("Cancel", role: .cancel) { flow.discardRestoreFile() }
            } message: {
                Text("Enter the backup's password. Nothing you already have is replaced.")
            }
            .alert("Backup Restored", isPresented: Binding(get: { flow.result != nil }, set: { if !$0 { flow.result = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(flow.result ?? "")
            }
            .alert("Couldn't Restore", isPresented: Binding(get: { flow.error != nil }, set: { if !$0 { flow.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(flow.error ?? "")
            }
    }

    private func startRestore() {
        guard let request = flow.takeRestoreRequest() else { return }
        flow.restoring = true
        Task { await restore(request.file, password: request.password) }
    }

    private func restore(_ file: URL, password: String) async {
        defer {
            flow.restoring = false
            Paths.removeIfTemporary(file)
        }
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try Backup.open(file, password: password) }.value
            let summary = Backup.apply(opened, certificates: certificates, library: library, sources: sources, github: github)
            flow.result = summary.message + "\n\nRedo Settings → Install Certificate to install apps."
            Task {
                await sources.refreshAll()
                await github.refreshAll(force: true, library: library)
                await certificates.checkAll()
            }
        } catch {
            flow.error = error.localizedDescription
        }
    }
}

struct BackupExportView: View {
    @Environment(CertificateStore.self) private var certificates
    @Environment(LibraryStore.self) private var library
    @Environment(SourceStore.self) private var sources
    @Environment(GitHubStore.self) private var github
    @Environment(\.dismiss) private var dismiss

    @State private var includeLibrary = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var file: URL?
    @State private var showMover = false
    @State private var error: String?

    /// Measured off the main thread when the form opens; walking a big library would stall typing.
    @State private var librarySize: Int64?

    private var canCreate: Bool { !password.isEmpty && password == confirmation && !creating }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledText("Certificates", "\(certificates.certificates.count)")
                    LabeledText("Sources", "\(sources.sources.count)")
                    LabeledText("GitHub Repos", "\(github.repos.count)")
                    Toggle(isOn: $includeLibrary) {
                        Text("Include Library")
                        Text("\(library.apps.count) apps · \(librarySize?.formattedBytes ?? "…")")
                    }
                } footer: {
                    Text("Settings are always included. Apps can make the backup large.")
                }

                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm Password", text: $confirmation)
                        .textContentType(.newPassword)
                } header: {
                    Text("Backup Password")
                } footer: {
                    if !confirmation.isEmpty && password != confirmation {
                        Text("The passwords don't match.").foregroundStyle(.red)
                    } else {
                        Text("Needed to restore. It can't be recovered.")
                    }
                }
            }
            .navigationTitle("Back Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { finish() } }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await create() } }.disabled(!canCreate)
                    }
                }
            }
            .fileMover(isPresented: $showMover, file: file) { moved in
                if case .failure(let error) = moved, (error as? CocoaError)?.code != .userCancelled {
                    self.error = error.localizedDescription
                    return
                }
                finish()
            }
            .alert("Couldn't Back Up", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .interactiveDismissDisabled(creating)
            .task {
                let directories = library.apps.map(\.directory)
                librarySize = await Task.detached(priority: .utility) {
                    directories.reduce(0) { $0 + FileManager.default.directorySize(at: $1) }
                }.value
            }
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        // The backup holds every certificate and its password, readable with the password typed here, so whoever
        // makes it must be able to unlock this iPhone.
        if !certificates.certificates.isEmpty {
            do {
                try await CertificateSharing.authenticate(reason: "Back up your certificates and their passwords")
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        let contents = Backup.Contents(
            certificates: certificates.certificates,
            defaultCertificateID: certificates.defaultID,
            sources: sources.sources,
            repos: github.repos,
            signingDefaults: SigningOptions.defaults,
            library: includeLibrary ? library.apps : []
        )
        let password = password
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let url = try Paths.newTempDirectory().appendingPathComponent(Backup.suggestedFileName())
                try Backup.create(contents, password: password, to: url)
                return url
            }.value
            file = url
            showMover = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Closes the sheet and removes the temporary file if it wasn't moved out.
    private func finish() {
        if let file { Paths.removeIfTemporary(file) }
        dismiss()
    }
}
