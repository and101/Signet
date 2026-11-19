import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @Environment(CertificateStore.self) private var store
    @Environment(Router.self) private var router
    @State private var checking = false
    @State private var certificateToDelete: CertificateRecord?

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            List {
                ForEach(store.certificates) { cert in
                    NavigationLink(value: cert.id) { CertificateRow(cert: cert, isDefault: cert.id == store.defaultID) }
                        .swipeToDelete {
                            certificateToDelete = cert
                        } actions: {
                            if cert.id != store.defaultID {
                                Button { store.defaultID = cert.id } label: {
                                    Label("Make Default", systemImage: "star")
                                }
                                .tint(.orange)
                            }
                        }
                }
            }
            .overlay {
                if store.certificates.isEmpty {
                    ContentUnavailableView {
                        Label("No Certificates", systemImage: "checkmark.seal")
                    } description: {
                        Text("Add a .p12 and its provisioning profile to start signing.")
                    } actions: {
                        Button("Add Certificate") { router.showAddCertificate = true }
                    }
                }
            }
            .certificateDeleteConfirmation(item: $certificateToDelete) { store.delete($0.id) }
            .navigationTitle("Certificates")
            .navigationDestination(for: UUID.self) { CertificateDetailView(id: $0) }
            .refreshable { await store.checkAll() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.certificates.isEmpty {
                        Button {
                            Task { checking = true; await store.checkAll(); checking = false }
                        } label: {
                            if checking { ProgressView() } else { Label("Check Status", systemImage: "arrow.clockwise") }
                        }
                        .disabled(checking)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.showAddCertificate = true } label: { Label("Add Certificate", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $router.showAddCertificate) {
                AddCertificateView()
            }
        }
    }
}

private extension View {
    func certificateDeleteConfirmation(
        item: Binding<CertificateRecord?>,
        perform: @escaping (CertificateRecord) -> Void
    ) -> some View {
        destructiveConfirmation(
            item: item,
            title: { "Delete \($0.nickname)?" },
            message: { _ in "Apps you already signed aren't affected." },
            perform: perform
        )
    }
}

struct CertificateRow: View {
    let cert: CertificateRecord
    let isDefault: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(cert.nickname)
                if isDefault {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(.footnote)
                        .accessibilityLabel("Default")
                }
            }
            Text(cert.teamName).font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { statusLine.lineLimit(1) }
                VStack(alignment: .leading, spacing: 2) { statusLine }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        StatusBadge(cert: cert)
        Text(summary).font(.footnote).foregroundStyle(.secondary)
    }

    private var summary: String {
        cert.isExpired
            ? cert.distributionKind
            : "\(cert.distributionKind) · Expires \(cert.expirationDate.formatted(.relative(presentation: .named)))"
    }
}

/// Only appears when something is wrong, like Feather's pills.
struct StatusBadge: View {
    let cert: CertificateRecord

    var body: some View {
        if let problem = cert.problem {
            Badge(text: problem, color: .red)
        }
    }
}

struct AddCertificateView: View {
    @Environment(CertificateStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    private enum Picking { case p12, profile }

    @State private var p12: URL?
    @State private var profile: URL?
    @State private var password = ""
    @State private var nickname = ""
    @State private var picking: Picking = .p12
    @State private var showImporter = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    fileButton("Certificate (.p12)", file: p12) { picking = .p12; showImporter = true }
                    fileButton("Provisioning Profile", file: profile) { picking = .profile; showImporter = true }
                }
                Section {
                    SecureField("Password", text: $password)
                    TextField("Nickname (optional)", text: $nickname)
                } footer: {
                    Text("Saved in the keychain on this iPhone.")
                }
            }
            .navigationTitle("Add Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.disabled(p12 == nil || profile == nil)
                    }
                }
            }
            .copyingFileImporter(
                isPresented: $showImporter,
                allowedContentTypes: picking == .p12 ? [.pkcs12, .data] : [.mobileProvision, .data]
            ) { urls in
                let target = picking
                guard let url = urls.first else { return }
                do {
                    let copy = try copyPickedFile(url)
                    if target == .p12 { p12 = copy } else { profile = copy }
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .alert("Couldn't Add Certificate", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .onAppear {
                if let pending = router.pendingP12 { p12 = pending; router.pendingP12 = nil }
                if let pending = router.pendingProfile { profile = pending; router.pendingProfile = nil }
                if let pending = router.pendingPassword { password = pending; router.pendingPassword = nil }
            }
        }
    }

    private func fileButton(_ title: LocalizedStringKey, file: URL?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent(title) {
                if let file {
                    HStack(spacing: 6) {
                        Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Text("Choose").foregroundStyle(.tint)
                }
            }
        }
        .tint(.primary)
    }

    private func save() async {
        guard let p12, let profile else { return }
        saving = true
        defer { saving = false }
        do {
            try await store.add(p12: p12, profile: profile, password: password, nickname: nickname)
            // The store keeps its own copies; drop the temporary ones.
            Paths.removeIfTemporary(p12)
            Paths.removeIfTemporary(profile)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Also deletes picked files that weren't saved, so cancelling doesn't leave copies behind.
    private func close() {
        if let p12 { Paths.removeIfTemporary(p12) }
        if let profile { Paths.removeIfTemporary(profile) }
        router.showAddCertificate = false
        dismiss()
    }
}

struct CertificateDetailView: View {
    let id: UUID
    @Environment(CertificateStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var nickname = ""
    @State private var certificateToDelete: CertificateRecord?
    @State private var confirmSendToLiveContainer = false
    @State private var shareError: String?

    private func sendToLiveContainer(_ cert: CertificateRecord) async {
        do {
            try await CertificateSharing.authenticate(reason: "Send \(cert.nickname) to LiveContainer")
            let p12 = try Data(contentsOf: cert.p12URL)
            guard let url = CertificateSharing.liveContainerURL(p12: p12, password: cert.password),
                  await UIApplication.shared.open(url) else {
                shareError = "LiveContainer isn't installed, or didn't open."
                return
            }
        } catch {
            shareError = error.localizedDescription
        }
    }

    var body: some View {
        if let cert = store.certificate(id) {
            List {
                Section {
                    HStack {
                        Text("Nickname")
                        TextField("Nickname", text: $nickname, prompt: Text(cert.teamName))
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .submitLabel(.done)
                            .onSubmit { store.rename(id, to: nickname) }
                    }
                    LabeledText("Status", statusText(cert))
                    Button {
                        Task { checking = true; await store.checkRevocation(id); checking = false }
                    } label: {
                        HStack {
                            Text("Check Status")
                            if checking { Spacer(); ProgressView() }
                        }
                    }
                    if let checked = cert.revocationCheckedAt {
                        LabeledText("Last Checked", checked.formatted(date: .abbreviated, time: .shortened))
                    }
                    if store.defaultID != id {
                        Button("Make Default") { store.defaultID = id }
                    }
                }

                Section {
                    LabeledText("Name", cert.certificateName)
                    LabeledText("Team", "\(cert.teamName) (\(cert.teamID))")
                } header: {
                    Text("Certificate")
                } footer: {
                    if cert.certificateMatchesProfile == false {
                        Text("This certificate doesn't match its profile. Signing will fail.")
                            .foregroundStyle(.red)
                    }
                }

                Section("Provisioning Profile") {
                    LabeledText("Name", cert.profileName)
                    LabeledText("Type", cert.distributionKind)
                    if let ppq = cert.ppqCheck { LabeledText("PPQ Check", ppq ? "On" : "Off") }
                    LabeledText("App ID", cert.bundleIDPattern)
                    LabeledText("Created", cert.creationDate.formatted(date: .abbreviated, time: .omitted))
                    LabeledText("Expires", cert.expirationDate.formatted(date: .abbreviated, time: .omitted))
                    if let devices = cert.provisionedDeviceCount {
                        LabeledText("Devices", "\(devices)")
                    } else if cert.provisionsAllDevices {
                        LabeledText("Devices", "All")
                    }
                }

                Section("Entitlements") {
                    ForEach(cert.entitlements.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key).font(.caption.monospaced())
                            Text(cert.entitlements[key] ?? "").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button { confirmSendToLiveContainer = true } label: {
                        Label("Send to LiveContainer", systemImage: "square.and.arrow.up.on.square")
                    }
                } footer: {
                    Text("LiveContainer uses it to sign the apps it runs. Anyone with it can sign apps as you.")
                }

                Section {
                    Button("Delete Certificate", role: .destructive) { certificateToDelete = cert }
                }
            }
            .confirmationDialog("Send \(cert.nickname) to LiveContainer?", isPresented: $confirmSendToLiveContainer,
                                titleVisibility: .visible) {
                Button("Send") { Task { await sendToLiveContainer(cert) } }
            } message: {
                Text("LiveContainer gets the certificate and its password.")
            }
            .alert("Couldn't Send", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shareError ?? "")
            }
            .certificateDeleteConfirmation(item: $certificateToDelete) {
                store.delete($0.id)
                dismiss()
            }
            .navigationTitle(cert.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { nickname = cert.nickname }
            .onDisappear { if !nickname.isEmpty, nickname != cert.nickname { store.rename(id, to: nickname) } }
        }
    }

    private func statusText(_ cert: CertificateRecord) -> String {
        if let problem = cert.problem { return problem }
        switch cert.revocation {
        case .valid: return String(localized: "Valid")
        case .unknown: return String(localized: "Couldn't Verify")
        default: return String(localized: "Not Checked")
        }
    }
}
