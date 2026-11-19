import SwiftUI
import UIKit

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
            Text(installer.phase ?? "Waiting for iOS…")
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
        case .installing(let name, let progress):
            Text("Installing \(name)").font(.headline)
            if let progress {
                ProgressView(value: progress)
                Text(installer.phase.map { "\($0) \(Int(progress * 100))%" } ?? "\(Int(progress * 100))% installed")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
                Text(installer.phase ?? "iOS is installing the app…").foregroundStyle(.secondary)
            }
        case .installed(let name):
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).imageScale(.large).foregroundStyle(.green)
            Text("\(name) Installed").font(.headline)
            Text("If it won't open, trust the developer in Settings → General → VPN & Device Management.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            if let bundleID = installer.installedBundleID, InstallProgress.canOpenApps {
                Button("Open") {
                    InstallProgress.open(bundleID)
                    installer.dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        case .finished(let name):
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).imageScale(.large).foregroundStyle(.green)
            Text("\(name) Sent to iOS").font(.headline)
            Text("Check your Home Screen. If it won't open, trust the developer in Settings → General → VPN & Device Management.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Image(systemName: "xmark.circle.fill").font(.largeTitle).imageScale(.large).foregroundStyle(.red)
            Text("Install Failed").font(.headline)
            Text(message).multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            if installer.serverFallback != nil {
                Button("Use the Install Server Instead") { installer.retryWithServer() }
                    .buttonStyle(.borderedProminent)
            }
            if installer.failedDirectly {
                Button {
                    UIPasteboard.general.string = DirectInstallDiagnostics.text(installer.directLog)
                } label: {
                    Label("Copy Details", systemImage: "doc.on.doc")
                }
                .font(.footnote)
            }
        case .confirmingSelfUpdate(let name, let differentTeam):
            Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle).imageScale(.large).foregroundStyle(.tint)
            Text("Update to \(name)?").font(.headline)
            Text("Signet will close while iOS installs it. Reopen it in a few seconds.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            if differentTeam {
                Text("This update is signed by a different team, so saved certificate passwords may be lost. Back up first in Settings → Back Up.")
                    .multilineTextAlignment(.center).font(.callout).foregroundStyle(.orange)
            }
            Button("Update Signet") { installer.confirmSelfUpdate() }
                .buttonStyle(.borderedProminent)
        case .closingForUpdate:
            ProgressView().controlSize(.large)
            Text("Updating Signet").font(.headline)
            Text("Signet is closing so iOS can finish. Reopen it in a few seconds.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
        }
    }
}
