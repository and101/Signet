import SwiftUI
import PhotosUI
import Zsign

struct SignView: View {
    let app: LibraryApp

    @Environment(CertificateStore.self) private var certificates
    @Environment(LibraryStore.self) private var library
    @Environment(InstallManager.self) private var installer
    @Environment(Router.self) private var router
    @Environment(GitHubStore.self) private var github

    @State private var options = SigningOptions.defaults
    @State private var certificateID: UUID?
    @State private var automaticBundleID: String?
    @State private var iconItem: PhotosPickerItem?
    @State private var showTweakPicker = false
    @State private var existingDylibs: [String] = []
    @State private var detection: InstalledApps.Detection?
    @State private var signing = false
    @State private var log: [String] = []
    @State private var error: String?
    @State private var signedApp: LibraryApp?
    /// The tracked GitHub repo whose signing defaults were applied, set once on first appearance.
    @State private var repoDefaults: TrackedRepo?
    @State private var appliedRepoDefaults = false
    @FocusState private var isEditing: Bool

    private let bundleIDRow = "bundleID"

    private var certificate: CertificateRecord? { certificates.certificate(certificateID) }
    private var effectiveBundleID: String {
        let requested = options.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return requested.isEmpty ? app.bundleID : requested
    }

    /// Set only when the bundle ID would actually stop signing.
    private var bundleIDRequirement: String? {
        certificate?.bundleIDRequirement(for: effectiveBundleID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: log.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
                .onChange(of: bundleIDRequirement != nil) { _, blocked in
                    // The row grows with its error; keep the value clear of the keyboard's Done button.
                    if blocked { withAnimation { proxy.scrollTo(bundleIDRow, anchor: .center) } }
                }
        }
    }

    private var form: some View {
        Form {
            header

            Section {
                if certificates.certificates.isEmpty {
                    Button("Add a Certificate") {
                        router.tab = .certificates
                        router.showAddCertificate = true
                    }
                } else {
                    Picker("Sign With", selection: $certificateID) {
                        ForEach(certificates.certificates) { cert in
                            Text(cert.nickname).tag(Optional(cert.id))
                        }
                    }
                }
            } header: {
                Text("Certificate")
            } footer: {
                if let problem = certificate?.problem {
                    Text("This certificate is \(problem.lowercased()), so apps signed with it won't open.")
                        .foregroundStyle(.red)
                }
            }

            Section {
                field("Name", text: $options.appName, placeholder: app.name)
                field("Bundle ID", text: $options.bundleID, placeholder: app.bundleID,
                      error: bundleIDRequirement)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .id(bundleIDRow)
                if let detection {
                    installedAppRow(detection)
                }
                field("Version", text: $options.version, placeholder: app.version)
                    .keyboardType(.decimalPad)
                field("Minimum iOS", text: $options.minimumOSVersion, placeholder: app.minimumOSVersion ?? "Unchanged")
                    .keyboardType(.decimalPad)
                PhotosPicker(selection: $iconItem, matching: .images) {
                    LabeledContent("Icon") {
                        if let data = options.customIcon, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        } else {
                            Text("Original").foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                if options.customIcon != nil {
                    Button("Reset Icon", role: .destructive) { options.customIcon = nil; iconItem = nil }
                }
            } header: {
                Text("Customize")
            } footer: {
                if let repoDefaults {
                    Text("Using defaults from \(repoDefaults.fullName).")
                }
            }

            Section {
                ForEach(options.injectFiles, id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: tweakIcon(for: file))
                }
                .onDelete { offsets in
                    for file in offsets.map({ options.injectFiles[$0] }) { Paths.removeIfTemporary(file) }
                    options.injectFiles.remove(atOffsets: offsets)
                }
                Button { showTweakPicker = true } label: { Label("Add .dylib, .framework or .deb", systemImage: "plus") }
                if !options.injectFiles.isEmpty {
                    Toggle("Weak Inject", isOn: $options.weakInject)
                    Toggle("Fix Jailbreak Paths", isOn: $options.fixSubstratePaths)
                    Toggle("Add ElleKit When Needed", isOn: $options.bundleElleKit)
                }
            } header: {
                Text("Inject Tweaks")
            } footer: {
                Text("To add a .framework, compress it in Files first. ElleKit is added when a tweak needs it.")
            }

            if !existingDylibs.isEmpty {
                Section {
                    ForEach(existingDylibs, id: \.self) { dylib in
                        Toggle(isOn: Binding(
                            get: { options.removeLoadCommands.contains(dylib) },
                            set: { remove in
                                options.removeLoadCommands.removeAll { $0 == dylib }
                                if remove { options.removeLoadCommands.append(dylib) }
                            }
                        )) {
                            Text(dylib).font(.caption.monospaced()).lineLimit(2)
                        }
                    }
                } header: {
                    Text("Remove Load Commands")
                } footer: {
                    Text("Removes dylibs from the app, like tweaks already injected.")
                }
            }

            Section("Options") {
                SigningToggles(options: $options)
            }

            if !log.isEmpty {
                Section("Log") {
                    ForEach(Array(log.enumerated()), id: \.offset) { index, line in
                        Text(line).font(.caption.monospaced()).id(index)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditing = false }
            }
        }
        .bottomActionBar {
            // Hidden while typing so it can't cover the field being edited.
            if !isEditing {
                Button {
                    Task { await sign() }
                } label: {
                    HStack(spacing: 8) {
                        if signing { ProgressView() }
                        Text(signing ? "Signing…" : "Sign")
                    }
                    .frame(maxWidth: .infinity)
                }
                .prominentAction()
                .disabled(signing || certificate == nil || bundleIDRequirement != nil)
            }
        }
        .navigationTitle("Sign")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $signedApp) { app in
            SignedAppView(appID: app.id)
        }
        .onAppear {
            // onAppear fires again when coming back from the signed app; only apply repo defaults once.
            if !appliedRepoDefaults {
                appliedRepoDefaults = true
                applyRepoDefaults()
            }
            if certificateID == nil { certificateID = certificates.defaultCertificate?.id }
            updateSuggestedBundleID()
        }
        .onChange(of: certificateID) { _, _ in updateSuggestedBundleID() }
        .onChange(of: options.ppqProtection) { _, _ in updateSuggestedBundleID() }
        .task {
            await loadDylibs()
            await findInstalledApp()
        }
        .onChange(of: iconItem) { _, item in
            Task { options.customIcon = try? await item?.loadTransferable(type: Data.self) }
        }
        .copyingFileImporter(isPresented: $showTweakPicker, allowedContentTypes: [.dylib, .zip, .data], allowsMultipleSelection: true) { urls in
            for url in urls {
                do { options.injectFiles.append(contentsOf: try TweakInjector.unpackPicked(url)) } catch { self.error = error.localizedDescription }
            }
        }
        .alert("Signing Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                AppIcon(url: app.iconURL, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title3.bold())
                    Text(app.bundleID).font(.footnote).foregroundStyle(.secondary)
                    Text("Version \(app.version) (\(app.build)) · \(app.size.formattedBytes)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A labelled text row. `error` stays inside the row so the bottom bar can't cover it while typing.
    private func field(_ title: String, text: Binding<String>, placeholder: String, error: String? = nil) -> some View {
        LabeledContent {
            TextField(title, text: text, prompt: Text(placeholder))
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
                .focused($isEditing)
        } label: {
            Text(title)
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    /// Offers the bundle ID of an installed copy of this app, so signing updates it instead of adding another.
    /// When iOS hides installed apps, offers the bundle IDs this app was signed or installed with instead.
    @ViewBuilder private func installedAppRow(_ detection: InstalledApps.Detection) -> some View {
        let others = detection.matches.filter { $0.bundleID != effectiveBundleID }
        let current = detection.matches.first { $0.bundleID == effectiveBundleID }
        let title = detection.systemCanSee ? "Use Installed App's Bundle ID" : "Use a Previous Bundle ID"

        VStack(alignment: .leading, spacing: 6) {
            if others.count == 1, let match = others.first {
                Button { useBundleID(match.bundleID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(title, systemImage: "arrow.down.app")
                        Text("\(match.bundleID) · \(describe(match.evidence))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.bundleID) { match in
                        Button { useBundleID(match.bundleID) } label: {
                            Text(match.bundleID)
                            Text(describe(match.evidence))
                        }
                    }
                } label: {
                    Label(title, systemImage: "arrow.down.app")
                }
            }

            if let current {
                Label(current.evidence == .installed ? "The installed app uses this bundle ID"
                      : "This app was \(describe(current.evidence).lowercased()) with this bundle ID",
                      systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else if detection.systemCanSee, detection.matches.isEmpty {
                Text("Not installed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !detection.systemCanSee {
                Text(detection.matches.isEmpty
                     ? "Signet can't see installed apps, and this app hasn't been signed here before."
                     : "Signet can't see installed apps. These are bundle IDs used here before.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func describe(_ evidence: InstalledApps.Match.Evidence) -> String {
        switch evidence {
        case .installed: "Installed"
        case .previouslyInstalled: "Installed before"
        case .signedBefore: "Signed before"
        }
    }

    private func useBundleID(_ bundleID: String) {
        automaticBundleID = nil // a certificate change shouldn't replace the user's choice
        options.bundleID = bundleID
    }

    private func findInstalledApp() async {
        let app = app
        let apps = library.apps
        detection = await Task.detached { InstalledApps.detect(for: app, in: apps) }.value
    }

    private func tweakIcon(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "framework": "shippingbox"
        case "deb": "archivebox"
        default: "puzzlepiece.extension"
        }
    }

    private func loadDylibs() async {
        let appURL = app.appURL
        existingDylibs = await Task.detached {
            guard let executable = AppImporter.mainExecutable(of: appURL) else { return [] }
            return Zsign.listDylibs(appExecutable: executable.path)
                .filter { !$0.hasPrefix("/System/") && !$0.hasPrefix("/usr/lib/") }
        }.value
    }

    /// Uses the certificate and bundle ID set for the GitHub repo this app was downloaded from.
    private func applyRepoDefaults() {
        guard let repo = github.repo(for: app) else { return }
        let certificateID = repo.certificateID.flatMap { certificates.certificate($0)?.id }
        let bundleID = repo.defaultBundleID
        guard certificateID != nil || bundleID != nil else { return }
        repoDefaults = repo
        if let certificateID { self.certificateID = certificateID }
        if let bundleID { useBundleID(bundleID) }
    }

    private func updateSuggestedBundleID() {
        let current = options.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == automaticBundleID else {
            automaticBundleID = nil
            return
        }
        let suggestion = certificate?.bundleID(for: app.bundleID, options: options)
        automaticBundleID = suggestion
        options.bundleID = suggestion ?? ""
    }

    private func sign() async {
        guard let certificate else { return }
        signing = true
        log = []
        defer { signing = false }

        let options = options
        let source = app
        do {
            let result = try await Signer.shared.sign(source, with: certificate, options: options) { line in
                Task { @MainActor in log.append(line) }
            }
            let saved = library.add(result)
            SigningOptions.defaults = options
            // Only remove the original once the signed copy is safely recorded.
            if options.deleteOriginalAfterSigning, saved {
                library.delete(source.id)
            }
            signedApp = result
            if options.installAfterSigning {
                await installer.install(result)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Behaviour toggles shared by the sign screen and the defaults screen in Settings.
struct SigningToggles: View {
    @Binding var options: SigningOptions

    var body: some View {
        Toggle("Remove Device Restrictions", isOn: $options.removeSupportedDevices)
        Toggle("Enable File Sharing", isOn: $options.enableFileSharing)
        Toggle("Remove URL Schemes", isOn: $options.removeURLSchemes)
        Toggle("Remove App Extensions", isOn: $options.removePlugins)
        Toggle("Remove Watch App", isOn: $options.removeWatchApp)
        Toggle("Force Full Screen (iPad)", isOn: $options.forceFullScreen)
        Toggle("Don't Embed Provisioning Profile", isOn: $options.removeProvisioningFile)
        Toggle("Merge App Entitlements", isOn: $options.mergeEntitlements)
        Toggle("Compress IPA", isOn: $options.compressIPA)
        Toggle("Install After Signing", isOn: $options.installAfterSigning)
        Toggle("Delete Original After Signing", isOn: $options.deleteOriginalAfterSigning)
        Toggle("Add Suffix for PPQ Certificates", isOn: $options.ppqProtection)
    }
}
