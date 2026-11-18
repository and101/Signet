import SwiftUI

struct SignedAppView: View {
    let appID: UUID

    @Environment(LibraryStore.self) private var library
    @Environment(InstallManager.self) private var installer
    @Environment(\.dismiss) private var dismiss
    @State private var appToDelete: LibraryApp?

    var body: some View {
        if let app = library.app(appID) {
            List {
                Section {
                    VStack(spacing: 10) {
                        AppIcon(url: app.iconURL, size: 96)
                        Text(app.name).font(.title2.bold())
                        Text(app.bundleID).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section("Details") {
                    LabeledText("Version", "\(app.version) (\(app.build))")
                    LabeledText("Size", app.size.formattedBytes)
                    if let minOS = app.minimumOSVersion { LabeledText("Minimum iOS", minOS) }
                    if let cert = app.certificateName { LabeledText("Signed With", cert) }
                    LabeledText("Signed", app.dateAdded.formatted(date: .abbreviated, time: .shortened))
                    LabeledText("File", "Library/\(app.id.uuidString.prefix(8))…/\(app.ipaFileName)")
                }

                Section {
                    Button("Delete", role: .destructive) { appToDelete = app }
                }
            }
            .bottomActionBar {
                Button {
                    Task { await installer.install(app) }
                } label: {
                    Text("Install").frame(maxWidth: .infinity)
                }
                .prominentAction()
            }
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: app.ipaURL) { Label("Share IPA", systemImage: "square.and.arrow.up") }
                }
            }
            .destructiveConfirmation(
                item: $appToDelete,
                title: { "Delete \($0.name)?" },
                message: { _ in "If the app is installed, it stays on your iPhone." },
                perform: {
                    library.delete($0.id)
                    dismiss()
                }
            )
        } else {
            ContentUnavailableView("App Deleted", systemImage: "trash")
        }
    }
}

struct InstallProgressView: View {
    @Environment(InstallManager.self) private var installer

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                status
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton { installer.dismiss() } }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch installer.state {
        case .idle:
            EmptyView()
        case .waiting(let name):
            ProgressView().controlSize(.large)
            Text("Installing \(name)").font(.headline)
            Text("Waiting for iOS…")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        case .manifestServed(let name):
            ProgressView().controlSize(.large)
            Text("Installing \(name)").font(.headline)
            Text("Tap **Install** when asked, and keep Signet open until it finishes.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        case .transferring(let name, let progress):
            Text("Installing \(name)").font(.headline)
            ProgressView(value: progress)
            Text("\(Int(progress * 100))% transferred").foregroundStyle(.secondary)
        case .finished(let name):
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).imageScale(.large).foregroundStyle(.green)
            Text("\(name) Sent to iOS").font(.headline)
            Text("Check your Home Screen. If it won't open, trust the developer in Settings → General → VPN & Device Management.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Image(systemName: "xmark.circle.fill").font(.largeTitle).imageScale(.large).foregroundStyle(.red)
            Text("Install Failed").font(.headline)
            Text(message).multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
        }
    }
}
