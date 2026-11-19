import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var trusted = false
    @State private var storage = StorageUsage()
    @State private var cleaning = false
    @State private var cleanupResult: String?
    @State private var backup = BackupFlow()
    @State private var hasSavedIndex = false
    @State private var confirmDeleteIndex = false
    @AppStorage(KeepAlive.settingKey) private var keepAlive = true
    @AppStorage(DirectInstall.methodKey) private var installMethod = InstallMethod.server.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { DefaultOptionsView() } label: {
                        Label { Text("Default Signing Options") } icon: { SettingsIcon("slider.horizontal.3", color: .gray) }
                    }
                }

                Section {
                    NavigationLink {
                        InstallCertificateView()
                    } label: {
                        LabeledContent {
                            Text(trusted ? "Trusted" : "Set Up")
                        } label: {
                            Label { Text("Install Certificate") } icon: { SettingsIcon("checkmark.shield.fill", color: .green) }
                        }
                    }
                    NavigationLink {
                        InstallMethodView()
                    } label: {
                        LabeledContent {
                            Text(installMethod == InstallMethod.direct.rawValue ? "Direct" : "Server")
                        } label: {
                            Label { Text("Install Method") } icon: { SettingsIcon("arrow.down.app.fill", color: .blue) }
                        }
                    }
                } footer: {
                    Text(installMethod == InstallMethod.direct.rawValue
                         ? "Direct install doesn't need the certificate; it's used if you switch back to the install server."
                         : "The certificate is a one-time setup needed to install apps.")
                }

                Section {
                    Toggle(isOn: $keepAlive) {
                        Label { Text("Keep Running During Installs") } icon: { SettingsIcon("waveform", color: .orange) }
                    }
                } footer: {
                    Text("Plays silence while an app installs, so the install can finish with Signet in the background. It doesn't stop your music.")
                }

                BackupSection(flow: backup)

                Section {
                    LabeledText("Library", storage.library.formattedBytes)
                    LabeledText("Certificates", storage.certificates.formattedBytes)
                    LabeledText("Temporary Files", storage.temporary.formattedBytes)
                    LabeledText("Total", storage.total.formattedBytes)
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
                } header: {
                    Text("Storage")
                } footer: {
                    Text(storageFooter)
                }

                if hasSavedIndex {
                    Section {
                        Button("Delete Saved Library List", role: .destructive) { confirmDeleteIndex = true }
                    } footer: {
                        Text("Your library list was damaged and a copy was saved. Until you delete it, Clean Up leaves unknown folders alone.")
                    }
                }

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
                } header: {
                    Text("About")
                } footer: {
                    Text("Signing by zsign (MIT). Only use certificates and apps you're allowed to.")
                }
            }
            .navigationTitle("Settings")
            .backupPresentations(backup)
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
                computeSizes()
                Task { trusted = await Task.detached { ServerCertificate.isTrusted }.value }
            }
        }
    }

    private var storageFooter: String {
        let base = "Clears temporary files and leftovers. To free more space, delete old apps in Library."
        guard let cleanupResult else { return base }
        return cleanupResult + "\n\n" + base
    }

    private func computeSizes() {
        Task {
            storage = await Task.detached(priority: .utility) { StorageUsage.measure() }.value
        }
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
            Section {
                SigningToggles(options: $options)
            } footer: {
                Text("Used each time you sign. Changes on the Sign screen are saved here too.")
            }
            Section {
                NavigationLink {
                    RenameRulesView(title: "Bundle ID Rules", rules: $options.bundleIDRules,
                                    matchPrompt: "com.example.app", replacementPrompt: "com.me.app",
                                    footer: "When an app with this bundle ID is signed, Signet uses the new one. Rules don't apply when an app is signed with an earlier version's settings.")
                } label: {
                    LabeledContent("Bundle ID Rules", value: options.bundleIDRules.isEmpty ? "None" : "\(options.bundleIDRules.count)")
                }
                NavigationLink {
                    RenameRulesView(title: "Name Rules", rules: $options.nameRules,
                                    matchPrompt: "App name", replacementPrompt: "New name",
                                    footer: "When an app with this name is signed, Signet renames it. Matching ignores upper and lower case.")
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

/// Walks the user through installing and trusting the app's local CA.
struct InstallCertificateView: View {
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
                Text("This certificate only works for Signet on this iPhone. It can't be used for any website.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Install Certificate")
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
