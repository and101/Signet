import SwiftUI

struct SettingsView: View {
    @Environment(CertificateStore.self) private var certificates
    @Environment(Router.self) private var router
    @State private var trusted = true
    @State private var storageTotal: Int64?
    @State private var backup = BackupFlow()
    @AppStorage(KeepAlive.settingKey) private var keepAlive = true
    @AppStorage(DirectInstall.methodKey) private var installMethod = InstallMethod.server.rawValue
    @AppStorage(DownloadPolicy.allowHTTPKey) private var allowHTTP = false

    private var usesServer: Bool { installMethod != InstallMethod.direct.rawValue }

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            Form {
                Section {
                    NavigationLink { CertificatesView() } label: { certificateCard }
                } footer: {
                    if certificates.certificates.count > 1 {
                        Text("Your default certificate. Tap to see all \(certificates.certificates.count).")
                    }
                }

                Section("Signing") {
                    NavigationLink { DefaultOptionsView() } label: {
                        Label { Text("Default Options") } icon: { SettingsIcon("slider.horizontal.3", color: .indigo) }
                    }
                }

                Section {
                    NavigationLink {
                        InstallMethodView()
                    } label: {
                        LabeledContent {
                            Text(usesServer ? (trusted ? "Server" : "Set Up Needed") : "Direct")
                        } label: {
                            Label { Text("Install Method") } icon: { SettingsIcon("arrow.down.app.fill", color: .blue) }
                        }
                    }
                    Toggle(isOn: $keepAlive) {
                        Label { Text("Keep Running During Installs") } icon: { SettingsIcon("speaker.wave.2.fill", color: .purple) }
                    }
                } header: {
                    Text("Installing")
                } footer: {
                    Text("Keep Running plays silence so installs finish in the background. Your music keeps playing.")
                }

                Section {
                    Toggle(isOn: $allowHTTP) {
                        Label { Text("Allow HTTP") } icon: { SettingsIcon("lock.open.fill", color: .orange) }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Lets sources and downloads use plain http. Anyone on your network could change what you download.")
                }

                Section("Data") {
                    NavigationLink { BackupView(flow: backup) } label: {
                        Label { Text("Backup & Restore") } icon: { SettingsIcon("archivebox.fill", color: .teal) }
                    }
                    NavigationLink { StorageView() } label: {
                        LabeledContent {
                            if let storageTotal { Text(storageTotal.formattedBytes) }
                        } label: {
                            Label { Text("Storage") } icon: { SettingsIcon("internaldrive.fill", color: .gray) }
                        }
                    }
                }

                Section {
                    NavigationLink { AboutView() } label: {
                        Label { Text("About Signet") } icon: { SettingsIcon("info", color: .cyan) }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $router.showCertificates) { CertificatesView() }
            .onAppear {
                Task { trusted = await Task.detached { ServerCertificate.isTrusted }.value }
                Task { storageTotal = await Task.detached(priority: .utility) { StorageUsage.measure().total }.value }
            }
        }
        // On the stack, not a page: opening a backup file from Files starts a restore wherever Settings is.
        .backupPresentations(backup)
    }

    @ViewBuilder
    private var certificateCard: some View {
        if let cert = certificates.defaultCertificate {
            HStack(spacing: 12) {
                SettingsIcon(cert.problem == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                             color: cert.problem == nil ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cert.nickname).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(cert.teamName).font(.subheadline).foregroundStyle(.secondary)
                    if let problem = cert.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    } else {
                        Text("\(cert.distributionKind) · Expires \(cert.expirationDate.formatted(.relative(presentation: .named)))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Certificates")
                    Text("Add one to start signing.").font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                SettingsIcon("checkmark.seal.fill", color: .gray)
            }
        }
    }
}

/// Settings → Backup & Restore.
private struct BackupView: View {
    let flow: BackupFlow

    var body: some View {
        Form { BackupSection(flow: flow) }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Storage: what Signet uses, and cleaning up.
private struct StorageView: View {
    @Environment(LibraryStore.self) private var library
    @State private var storage = StorageUsage()
    @State private var cleaning = false
    @State private var cleanupResult: String?
    @State private var hasSavedIndex = false
    @State private var confirmDeleteIndex = false

    var body: some View {
        Form {
            Section {
                LabeledText("Library", storage.library.formattedBytes)
                LabeledText("Certificates", storage.certificates.formattedBytes)
                LabeledText("Temporary Files", storage.temporary.formattedBytes)
                LabeledText("Total", storage.total.formattedBytes)
            }

            Section {
                Button {
                    Task { await cleanUp() }
                } label: {
                    HStack {
                        Text("Clean Up Storage")
                        Spacer()
                        if cleaning { ProgressView() }
                    }
                }
                .disabled(cleaning || !library.downloads.isEmpty)
            } footer: {
                Text(storageFooter)
            }

            if hasSavedIndex {
                Section {
                    Button("Delete Saved Library List", role: .destructive) { confirmDeleteIndex = true }
                } footer: {
                    Text("Your library list was damaged and a copy was saved. Until you delete it, Clean Up keeps unknown folders.")
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete the saved library list?", isPresented: $confirmDeleteIndex, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.removePreservedIndex()
                hasSavedIndex = library.hasPreservedIndex
            }
        } message: {
            Text("Apps missing from your library can't be recovered after this.")
        }
        .onAppear {
            hasSavedIndex = library.hasPreservedIndex
            Task { storage = await Task.detached(priority: .utility) { StorageUsage.measure() }.value }
        }
    }

    private var storageFooter: String {
        let base = String(localized: "Clears temporary files and leftovers. Delete old apps in Library to free more.")
        guard let cleanupResult else { return base }
        return cleanupResult + "\n\n" + base
    }

    private func cleanUp() async {
        cleaning = true
        defer { cleaning = false }
        let before = storage.total
        let removed = await library.cleanUp()
        // Something may be importing or signing right now, so only clear files that have sat idle a while.
        await Task.detached(priority: .utility) { Paths.clearTemporaryFiles(olderThan: 10 * 60) }.value
        storage = await Task.detached(priority: .utility) { StorageUsage.measure() }.value
        let freed = max(before - storage.total, 0)
        var result = "Freed \(freed.formattedBytes)."
        if removed > 0 {
            result += " Removed \(removed) missing \(removed == 1 ? "app" : "apps")."
        }
        cleanupResult = result
    }
}

/// Settings → About Signet.
private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledText("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Link(destination: URL(string: "https://github.com/and101/Signet")!) {
                    LabeledContent("Developer") {
                        HStack(spacing: 4) {
                            Text("and101")
                            Image(systemName: "arrow.up.right").font(.footnote).accessibilityHidden(true)
                        }
                    }
                }
                .foregroundStyle(.primary)
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
            } footer: {
                Text("Signing by zsign (MIT). Only use certificates and apps you're allowed to.")
            }
        }
        .navigationTitle("About Signet")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StorageUsage {
    var library: Int64 = 0
    var certificates: Int64 = 0
    var temporary: Int64 = 0
    var total: Int64 = 0

    static func measure() -> StorageUsage {
        let fm = FileManager.default
        return StorageUsage(
            library: fm.directorySize(at: Paths.library),
            certificates: fm.directorySize(at: Paths.certificates),
            temporary: fm.directorySize(at: Paths.temp) + fm.directorySize(at: Paths.inbox),
            total: Paths.containerRoots.reduce(0) { $0 + fm.directorySize(at: $1) }
        )
    }
}

private struct DefaultOptionsView: View {
    @State private var options = SigningOptions.defaults

    var body: some View {
        Form {
            SigningToggles(options: $options, note: "Used each time you sign. Changes on the Sign screen are saved here.")
            Section {
                NavigationLink {
                    RenameRulesView(title: "Bundle ID Rules", rules: $options.bundleIDRules,
                                    matchPrompt: "com.example.app", replacementPrompt: "com.me.app",
                                    footer: "Apps with this bundle ID are signed with the new one. Updates reusing earlier settings keep theirs.")
                } label: {
                    LabeledContent("Bundle ID Rules", value: options.bundleIDRules.isEmpty ? "None" : "\(options.bundleIDRules.count)")
                }
                NavigationLink {
                    RenameRulesView(title: "Name Rules", rules: $options.nameRules,
                                    matchPrompt: "App name", replacementPrompt: "New name",
                                    footer: "Apps with this name are renamed when signed. Case doesn't matter.")
                } label: {
                    LabeledContent("Name Rules", value: options.nameRules.isEmpty ? "None" : "\(options.nameRules.count)")
                }
            } header: {
                Text("Rename Rules")
            }
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    var fresh = SigningOptions()
                    fresh.ppqSuffix = options.ppqSuffix // keeps re-signed apps updating in place
                    // Rules are the user's own lists, not settings with a default.
                    fresh.bundleIDRules = options.bundleIDRules
                    fresh.nameRules = options.nameRules
                    options = fresh
                }
            }
        }
        .navigationTitle("Default Options")
        .onChange(of: options) { _, new in SigningOptions.defaults = new }
    }
}

/// Settings → Install Method → Server Setup: installing and trusting the install server's local CA.
struct ServerSetupView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var info = ServerCertificate.info
    @State private var trusted = false
    @State private var error: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "seal")
                        .font(.title2)
                        .foregroundStyle(trusted ? Color.green : Color.secondary)
                    VStack(alignment: .leading) {
                        Text(trusted ? "Ready" : "One-Time Setup").font(.headline)
                        Text(trusted ? "Signet can install apps." : "Do these three steps once.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if !trusted {
                Section {
                    Button("Download Profile in Safari") { downloadProfile() }
                } header: {
                    Text("1. Download the Profile")
                } footer: {
                    Text("Tap **Allow** in Safari, then come back.")
                }
                Section("2. Install It") {
                    Text("Open **Settings → General → VPN & Device Management**, tap **Signet Install Certificate**, then **Install**.")
                }
                Section("3. Turn On Full Trust") {
                    Text("Open **Settings → General → About → Certificate Trust Settings** and turn on **\(info?.authorityName ?? "Signet Local CA")**.")
                }
            }

            Section {
                Button("Check Again") { Task { await refresh() } }
                if let info {
                    LabeledText("Certificate", info.authorityName)
                    LabeledText("Expires", info.expires.formatted(date: .abbreviated, time: .omitted))
                }
                Button("Create New Certificate", role: .destructive) { confirmReset = true }
            } footer: {
                Text("This certificate only works for Signet on this iPhone, never for websites.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Server Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .confirmationDialog("Create a new certificate?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Create New Certificate", role: .destructive) {
                do {
                    info = try ServerCertificate.regenerate()
                    try InstallServer.shared.restartIfRunning()
                    Task { await refresh() }
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } message: {
            Text("You'll need to install and trust it again.")
        }
    }

    private func refresh() async {
        do {
            info = try ServerCertificate.ensure()
        } catch {
            self.error = error.localizedDescription
        }
        trusted = await Task.detached { ServerCertificate.isTrusted }.value
    }

    private func downloadProfile() {
        do {
            let url = try InstallServer.shared.serveProfile(try ServerCertificate.profile())
            // Keep the server alive while Safari, now in front, downloads the profile.
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "Profile") {
                UIApplication.shared.endBackgroundTask(task)
            }
            UIApplication.shared.open(url)
            Task {
                try? await Task.sleep(for: .seconds(25))
                UIApplication.shared.endBackgroundTask(task)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The open-source components in Signet and their licences, from Resources/Acknowledgements.txt
/// (made by scripts/make-acknowledgements.py).
struct AcknowledgementsView: View {
    @State private var paragraphs: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) { // small enough to lay out at once; lazy left gaps when jumping
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    if paragraph.hasPrefix("# ") {
                        Text(verbatim: String(paragraph.dropFirst(2))).font(.headline).padding(.top, 16)
                    } else if paragraph.hasPrefix("## ") {
                        Text(verbatim: String(paragraph.dropFirst(3))).font(.subheadline.weight(.semibold)).padding(.top, 8)
                    } else {
                        Text(verbatim: paragraph).font(.footnote).textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard paragraphs.isEmpty, let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        }
    }
}
