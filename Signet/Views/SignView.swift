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
    /// The icon file being read and scaled, if any; cleared by any other icon choice so a slow file can't override it.
    @State private var iconFilePick: UUID?
    @State private var showPhotoPicker = false
    @State private var showIconFilePicker = false
    @State private var alternateIcons: [(name: String, image: UIImage, thumbnail: UIImage)] = []
    @State private var showTweakPicker = false
    @State private var existingDylibs: [String] = []
    @State private var removableItems: [Signer.RemovableItem] = []
    @State private var showEntitlementsPicker = false
    @State private var exported: ExportedIPA?
    @State private var detection: InstalledApps.Detection?
    @State private var signing = false
    @State private var log = ActivityLog()
    @State private var error: String?
    @State private var signedApp: LibraryApp?
    /// The tracked GitHub repo whose signing defaults were applied, set once on first appearance.
    @State private var repoDefaults: TrackedRepo?
    /// The earlier signed copy of this app whose options were applied, set once on first appearance.
    @State private var previousSigning: LibraryApp?
    /// Set when a rename rule from Settings filled in the bundle ID or name.
    @State private var renamedByRule = false
    @State private var appliedRepoDefaults = false
    @FocusState private var isEditing: Bool
    /// Whether a page under Advanced is showing, so errors are shown there rather than on the covered form.
    @State private var onAdvancedPage = false

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
                field("Version", text: versionText($options.version), placeholder: app.version)
                    .keyboardType(.decimalPad)
                field("Minimum iOS", text: versionText($options.minimumOSVersion), placeholder: app.minimumOSVersion ?? "Unchanged")
                    .keyboardType(.decimalPad)
                iconRow
                if options.customIcon != nil {
                    Button("Reset Icon", role: .destructive) { options.customIcon = nil; iconItem = nil; iconFilePick = nil }
                }
            } header: {
                Text("Customize")
            } footer: {
                if let previousSigning {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Using version \(previousSigning.version)'s settings, so this installs over it.")
                        Button("Use My Defaults Instead") { useDefaults() }
                            .font(.footnote)
                    }
                } else if let repoDefaults {
                    Text("Using defaults from \(repoDefaults.fullName).")
                } else if renamedByRule {
                    Text("Renamed by your rules in Settings → Default Options.")
                }
            }

            Section {
                NavigationLink { advancedPage("Tweaks") { tweaksSection } } label: {
                    LabeledContent("Tweaks", value: options.injectFiles.isEmpty ? String(localized: "None") : "\(options.injectFiles.count)")
                }
                if !existingDylibs.isEmpty || !removableItems.isEmpty {
                    NavigationLink { advancedPage("Remove From App") { removalSections } } label: {
                        LabeledContent("Remove From App", value: removalCount == 0 ? String(localized: "None") : "\(removalCount)")
                    }
                }
                NavigationLink { advancedPage("Appearance") { appearanceSection } } label: {
                    LabeledContent("Appearance", value: options.interfaceStyle == .unchanged && options.appearance == .unchanged
                                   ? String(localized: "Unchanged") : String(localized: "Custom"))
                }
                NavigationLink { advancedPage("Entitlements") { entitlementsSection } } label: {
                    LabeledContent("Entitlements", value: options.entitlementsFile?.lastPathComponent ?? String(localized: "From Profile"))
                }
                NavigationLink { advancedPage("Options") { SigningToggles(options: $options) } } label: {
                    Text("Options")
                }
            } header: {
                Text("Advanced")
            } footer: {
                if !ungrantedEntitlements.isEmpty {
                    Text("Your profile doesn't grant some custom entitlements, so iOS will refuse to install the app.")
                        .foregroundStyle(.orange)
                }
            }

            if !log.isEmpty, !signing {
                Section("Last Signing") {
                    ActivityStatusRow(log: log)
                    ActivityDetails(log: log)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditing = false }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await exportUnsigned() } } label: {
                        Label("Export Without Signing", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .disabled(signing)
            }
        }
        .sheet(item: $exported) { file in
            ExportedIPASheet(file: file)
                .presentationDetents([.medium])
        }
        .bottomActionBar {
            // Hidden while typing so it can't cover the field being edited.
            if !isEditing {
                VStack(spacing: 6) {
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
                    // The current step, in place, instead of a log growing at the bottom of the form.
                    if signing, let step = log.latest {
                        Text(step)
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            .contentTransition(.opacity)
                            .animation(.default, value: step)
                    }
                }
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
                if !applyPreviousSigning() {
                    applyRepoDefaults()
                    applyRenameRules()
                }
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
            // Cleared when another source picks the icon; that choice must stand.
            guard let item else { return }
            iconFilePick = nil
            Task {
                // Scaled to icon size when chosen, so a full-size photo isn't kept or decoded again.
                guard let data = try? await item.loadTransferable(type: Data.self), iconItem == item else { return }
                let icon = await Task.detached(operation: { IconImage.normalizedCustomIcon(data) }).value
                // Checked again after scaling: another icon may have been chosen meanwhile, and that choice stands.
                guard iconItem == item else { return }
                guard let icon else {
                    error = "That photo isn't an image Signet can use."
                    return
                }
                options.customIcon = icon
            }
        }
        .alert("Signing Failed", isPresented: Binding(get: { !onAdvancedPage && error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Advanced pages

    /// Removals chosen on the Remove From App page.
    private var removalCount: Int {
        let removable = Set(removableItems.map(\.path))
        return options.removeLoadCommands.filter(existingDylibs.contains).count
            + options.removePaths.filter(removable.contains).count
    }

    /// A page under Advanced. Errors from its pickers show here, since the sign form underneath can't present.
    private func advancedPage<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        Form { content() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { onAdvancedPage = true }
            .onDisappear { onAdvancedPage = false }
            .alert("Couldn't Add File", isPresented: Binding(get: { onAdvancedPage && error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    @ViewBuilder private var tweaksSection: some View {
        Section {
            ForEach(options.injectFiles, id: \.self) { file in
                Label(file.lastPathComponent, systemImage: tweakIcon(for: file))
            }
            .onDelete { offsets in
                for file in offsets.map({ options.injectFiles[$0] }) { Paths.removeIfTemporary(file) }
                options.injectFiles.remove(atOffsets: offsets)
            }
            Button { showTweakPicker = true } label: { Label("Add .dylib, .framework or .deb", systemImage: "plus") }
                .copyingFileImporter(isPresented: $showTweakPicker, allowedContentTypes: [.dylib, .zip, .data], allowsMultipleSelection: true) { urls in
                    for url in urls {
                        do { options.injectFiles.append(contentsOf: try TweakInjector.unpackPicked(url)) } catch { self.error = error.localizedDescription }
                    }
                }
            if !options.injectFiles.isEmpty {
                Toggle("Weak Inject", isOn: $options.weakInject)
                Toggle("Fix Jailbreak Paths", isOn: $options.fixSubstratePaths)
                Toggle("Add ElleKit When Needed", isOn: $options.bundleElleKit)
                Toggle("Inject Into Extensions", isOn: $options.injectIntoExtensions)
            }
        } header: {
            Text("Inject Tweaks")
        } footer: {
            Text("Zip a .framework in Files before adding it. ElleKit is added when needed.")
        }
    }

    @ViewBuilder private var removalSections: some View {
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

        if !removableItems.isEmpty {
            Section {
                ForEach(removableItems, id: \.path) { item in
                    removalRow(item)
                }
            } header: {
                Text("Frameworks & Extensions")
            } footer: {
                Text("Removing a framework the app uses makes it crash when it opens.")
            }
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        Section {
            Picker("Interface", selection: $options.interfaceStyle) {
                Text("Unchanged").tag(SigningOptions.InterfaceStyle.unchanged)
                Text("Classic").tag(SigningOptions.InterfaceStyle.classic)
                Text("Liquid Glass").tag(SigningOptions.InterfaceStyle.liquidGlass)
            }
            Picker("Light or Dark", selection: $options.appearance) {
                Text("Unchanged").tag(SigningOptions.Appearance.unchanged)
                Text("Always Light").tag(SigningOptions.Appearance.light)
                Text("Always Dark").tag(SigningOptions.Appearance.dark)
            }
        } footer: {
            switch options.interfaceStyle {
            case .unchanged: EmptyView()
            case .classic: Text("Keeps the look from before iOS 26. Only affects apps built for iOS 26.")
            case .liquidGlass: Text("Marks the app as built for iOS 26 so it gets Liquid Glass. Some apps may break.")
            }
        }
    }

    @ViewBuilder private var entitlementsSection: some View {
        Section {
            if let file = options.entitlementsFile {
                LabeledContent("Custom Entitlements", value: file.lastPathComponent)
                Button("Remove Custom Entitlements", role: .destructive) {
                    Paths.removeIfTemporary(file)
                    options.entitlementsFile = nil
                }
            } else {
                Button { showEntitlementsPicker = true } label: { Label("Use an Entitlements File", systemImage: "doc.badge.gearshape") }
                    .copyingFileImporter(isPresented: $showEntitlementsPicker, allowedContentTypes: [.propertyList, .xml, .data]) { urls in
                        guard let url = urls.first else { return }
                        do {
                            _ = try EntitlementsMerger.read(url)
                            options.entitlementsFile = url
                        } catch {
                            Paths.removeIfTemporary(url)
                            self.error = error.localizedDescription
                        }
                    }
            }
        } footer: {
            if options.entitlementsFile != nil {
                let missing = ungrantedEntitlements
                if missing.isEmpty {
                    Text("Used instead of the profile's entitlements. Merge App Entitlements is ignored.")
                } else {
                    Text("Your profile doesn't grant \(missing.joined(separator: ", ")), so iOS will refuse to install the app.")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Optional. By default, apps get the profile's entitlements, or merged ones if that's on.")
            }
        }
    }

    private var iconRow: some View {
        Menu {
            Button { showPhotoPicker = true } label: { Label("Choose from Photos", systemImage: "photo") }
            Button { showIconFilePicker = true } label: { Label("Choose from Files", systemImage: "folder") }
            if !alternateIcons.isEmpty {
                Section("The App's Own Icons") {
                    ForEach(alternateIcons, id: \.name) { icon in
                        Button {
                            iconItem = nil
                            iconFilePick = nil
                            options.customIcon = icon.image.pngData()
                        } label: {
                            Label { Text(icon.name) } icon: { Image(uiImage: icon.thumbnail) }
                        }
                    }
                }
            }
        } label: {
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $iconItem, matching: .images)
        // Attached here rather than to the form, which already has the tweak picker's sheet.
        .copyingFileImporter(isPresented: $showIconFilePicker, allowedContentTypes: [.image]) { urls in
            guard let url = urls.first else { return }
            iconItem = nil
            // Read and scaled off the main thread; a later choice made meanwhile wins.
            let pick = UUID()
            iconFilePick = pick
            Task {
                let icon = await Task.detached(operation: { () -> Data? in
                    defer { Paths.removeIfTemporary(url) }
                    return (try? Data(contentsOf: url)).flatMap(IconImage.normalizedCustomIcon)
                }).value
                guard iconFilePick == pick, iconItem == nil else { return }
                guard let icon else {
                    error = "That file isn't an image Signet can read."
                    return
                }
                options.customIcon = icon
            }
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
    private func field(_ title: LocalizedStringKey, text: Binding<String>, placeholder: String, error: String? = nil) -> some View {
        LabeledContent {
            TextField(title, text: text, prompt: Text(verbatim: placeholder))
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(title))
                .focused($isEditing)
        } label: {
            Text(title)
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    /// The decimal pad types the region's separator, often a comma; versions always use dots.
    private func versionText(_ text: Binding<String>) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = SigningOptions.versionWithDots($0) })
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
        case .installed: String(localized: "Installed")
        case .previouslyInstalled: String(localized: "Installed before")
        case .signedBefore: String(localized: "Signed before")
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

    @ViewBuilder private func removalRow(_ item: Signer.RemovableItem) -> some View {
        let removedByToggle = item.kind == .appExtension && options.removePlugins
        Toggle(isOn: Binding(
            get: { removedByToggle || options.removePaths.contains(item.path) },
            set: { remove in
                options.removePaths.removeAll { $0 == item.path }
                if remove { options.removePaths.append(item.path) }
            }
        )) {
            Label {
                Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1)
                if removedByToggle {
                    Text("Removed by Remove App Extensions")
                } else if item.isLinked {
                    Text("Used by the app").foregroundStyle(.orange)
                }
            } icon: {
                switch item.kind {
                case .appExtension: Image(systemName: "puzzlepiece.extension")
                case .framework: Image(systemName: "square.stack.3d.up")
                case .library: Image(systemName: "doc")
                }
            }
        }
        .disabled(removedByToggle)
    }

    /// Keys the custom entitlements claim that the chosen certificate's profile doesn't grant.
    private var ungrantedEntitlements: [String] {
        guard let file = options.entitlementsFile, let certificate,
              let custom = try? EntitlementsMerger.read(file),
              let profile = try? ProvisioningProfile(url: certificate.profileURL) else { return [] }
        return EntitlementsMerger.ungranted(custom, profile: profile.entitlements)
    }

    private func tweakIcon(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "framework": "square.stack.3d.up"
        case "deb": "archivebox"
        default: "doc"
        }
    }

    private func loadDylibs() async {
        let appURL = app.appURL
        removableItems = await Task.detached { Signer.removableItems(in: appURL) }.value
        alternateIcons = await Task.detached {
            // Menus draw images at their own size, so shrink them to row height.
            AppImporter.alternateIcons(in: appURL).map { icon in
                (icon.name, icon.image, icon.image.preparingThumbnail(of: CGSize(width: 30, height: 30)) ?? icon.image)
            }
        }.value
        existingDylibs = await Task.detached {
            guard let executable = AppImporter.mainExecutable(of: appURL) else { return [] }
            return Zsign.listDylibs(appExecutable: executable.path)
                .filter { !$0.hasPrefix("/System/") && !$0.hasPrefix("/usr/lib/") }
        }.value
    }

    /// Signs an update the way the last version was signed: same certificate, bundle ID, tweaks, icon and options.
    /// - Returns: false if this app hasn't been signed here before.
    private func applyPreviousSigning() -> Bool {
        let key = SourceUpdates.key(for: app)
        guard let previous = library.signedApps.first(where: { SourceUpdates.key(for: $0) == key && $0.signingOptionsData != nil }),
              var remembered = previous.rememberedOptions else { return false }
        remembered.version = "" // the new version's own
        let saved = SigningOptions.defaults
        remembered.bundleIDRules = saved.bundleIDRules
        remembered.nameRules = saved.nameRules
        options = remembered
        previousSigning = previous
        if let id = previous.certificateID, certificates.certificate(id) != nil { certificateID = id }
        useBundleID(previous.bundleID)
        return true
    }

    private func useDefaults() {
        iconFilePick = nil
        options = SigningOptions.defaults
        previousSigning = nil
        iconItem = nil
        automaticBundleID = nil
        certificateID = certificates.defaultCertificate?.id
        renamedByRule = false
        applyRepoDefaults()
        applyRenameRules()
        updateSuggestedBundleID()
    }

    /// Fills in the bundle ID and name from the user's rename rules, where nothing more specific already did.
    private func applyRenameRules() {
        if options.appName.trimmingCharacters(in: .whitespaces).isEmpty, let name = options.ruleName(for: app.name) {
            options.appName = name
            renamedByRule = true
        }
        if options.bundleID.trimmingCharacters(in: .whitespaces).isEmpty, let bundleID = options.ruleBundleID(for: app.bundleID) {
            useBundleID(bundleID)
            renamedByRule = true
        }
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

    /// Applies the changes without signing, for signing the IPA somewhere else.
    private func exportUnsigned() async {
        signing = true
        log.start()
        defer { signing = false }
        var options = options
        // The certificate's automatic bundle ID (PPQ suffix, wildcard namespace) only matters when signing.
        if let automaticBundleID, options.bundleID == automaticBundleID { options.bundleID = "" }
        let source = app
        do {
            let url = try await Signer.shared.exportModified(source, options: options) { line in
                Task { @MainActor in log.append(line) }
            }
            log.finish(.succeeded, "Exported \(url.lastPathComponent)")
            exported = ExportedIPA(url: url)
        } catch {
            log.finish(.failed, error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    private func sign() async {
        guard let certificate else { return }
        signing = true
        log.start()
        defer { signing = false }

        let options = options
        let source = app
        do {
            let result = try await Signer.shared.sign(source, with: certificate, options: options) { line in
                Task { @MainActor in log.append(line) }
            }
            log.finish(.succeeded, "Signed \(result.name) \(result.version)")
            try library.addOrRemove(result)
            // Options loaded from an earlier version of this app are that app's, not the user's defaults.
            if previousSigning == nil {
                SigningOptions.defaults = options.asDefaultsKeepingSavedRules
            }
            // Only remove the original once the signed copy is safely recorded.
            if options.deleteOriginalAfterSigning {
                library.delete(source.id)
            }
            signedApp = result
            if options.installAfterSigning {
                await installer.install(result)
            }
        } catch {
            log.finish(.failed, error.localizedDescription)
            self.error = error.localizedDescription
        }
    }
}

struct ExportedIPA: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Shown after exporting an unsigned IPA: where it is, and a way to send it on.
private struct ExportedIPASheet: View {
    let file: ExportedIPA
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).imageScale(.large).foregroundStyle(.green)
                Text("Exported Without Signing").font(.headline)
                Text(file.url.lastPathComponent).font(.callout.monospaced()).multilineTextAlignment(.center)
                Text("Saved in Files → On My iPhone → Signet → Exports. Sign it elsewhere before installing.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton { dismiss() } }
            }
        }
    }
}

/// Behaviour toggles shared by the sign screen and the defaults screen in Settings, in their own sections.
struct SigningToggles: View {
    @Binding var options: SigningOptions
    /// Footer for the last section, e.g. how the defaults screen's values are used.
    var note: LocalizedStringKey?

    var body: some View {
        Section("App") {
            Toggle("Remove Device Restrictions", isOn: $options.removeSupportedDevices)
            Toggle("Enable File Sharing", isOn: $options.enableFileSharing)
            Toggle("Force Full Screen (iPad)", isOn: $options.forceFullScreen)
            Toggle("Enable ProMotion (120 Hz)", isOn: $options.enableProMotion)
            Toggle("Enable Game Mode", isOn: $options.enableGameMode)
        }
        Section("Remove") {
            Toggle("URL Schemes", isOn: $options.removeURLSchemes)
            Toggle("App Extensions", isOn: $options.removePlugins)
            Toggle("Watch App", isOn: $options.removeWatchApp)
        }
        Section {
            Toggle("Merge App Entitlements", isOn: $options.mergeEntitlements)
            Toggle("Don't Embed Provisioning Profile", isOn: $options.removeProvisioningFile)
            Toggle("Add Suffix for PPQ Certificates", isOn: $options.ppqProtection)
        } header: {
            Text("Signing")
        } footer: {
            Text("The suffix stops a signed app sharing an App Store app's ID, which can get the certificate revoked.")
        }
        Section {
            Toggle("Compress IPA", isOn: $options.compressIPA)
            Toggle("Install After Signing", isOn: $options.installAfterSigning)
            Toggle("Delete Original After Signing", isOn: $options.deleteOriginalAfterSigning)
        } header: {
            Text("After Signing")
        } footer: {
            if let note { Text(note) }
        }
    }
}
