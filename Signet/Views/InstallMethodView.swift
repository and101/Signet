import SwiftUI
import UIKit

/// Settings → Install Method: choose between the install server and direct install, and set up direct install
/// with a checklist that ticks itself off.
struct InstallMethodView: View {
    @Environment(InstallManager.self) private var installer
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @AppStorage(DirectInstall.methodKey) private var method = InstallMethod.server.rawValue
    @AppStorage(DirectInstall.addressKey) private var address = ""
    @AppStorage(DirectInstall.portKey) private var port = ""
    @State private var hasPairingFile = DirectInstall.hasPairingFile
    @State private var showPairingPicker = false
    @State private var confirmRemove = false
    @State private var vpnReachable: Bool?
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var message: String?

    private enum TestResult: Equatable {
        case ready(iOS: String)
        case failed(String)
    }

    static let iloaderURL = URL(string: "https://github.com/nab138/iloader/releases/latest")!
    static let localDevVPNURL = URL(string: "localdevvpn://")!
    static let localDevVPNStoreURL = URL(string: "https://apps.apple.com/app/id6755608044")!

    var body: some View {
        Form {
            Section {
                Picker("Install Method", selection: $method) {
                    Text("Install Server").tag(InstallMethod.server.rawValue)
                    Text("Direct (Beta)").tag(InstallMethod.direct.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                if method == InstallMethod.direct.rawValue {
                    Text("Installs straight to this iPhone's installer, like a computer does. Faster and more reliable, with no install certificate. Needs a pairing file made once on a computer, and LocalDevVPN.")
                } else {
                    Text("Serves the app from Signet and installs it over the air. Needs the install certificate from Settings.")
                }
            }

            if method == InstallMethod.direct.rawValue {
                pairingStep
                vpnStep
                testStep
                advanced
            }
        }
        .navigationTitle("Install Method")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: method) { await refreshVPN() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from LocalDevVPN or the Files app.
            if phase == .active { Task { await refreshVPN() } }
        }
        .copyingFileImporter(isPresented: $showPairingPicker, allowedContentTypes: [.propertyList, .xml, .data]) { urls in
            guard let url = urls.first else { return }
            defer { Paths.removeIfTemporary(url) }
            do {
                try DirectInstall.importPairingFile(from: url)
                hasPairingFile = true
                testResult = nil
            } catch {
                message = error.localizedDescription
            }
        }
        .confirmationDialog("Remove the pairing file?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                DirectInstall.removePairingFile()
                hasPairingFile = false
                testResult = nil
            }
        } message: {
            Text("Direct install stops working until you import a new one.")
        }
        .alert("Pairing File", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Steps

    private var pairingStep: some View {
        Section {
            SetupStepRow(number: 1, title: "Pairing File", done: hasPairingFile,
                         status: hasPairingFile ? "Imported" : "Not imported")
            Button(hasPairingFile ? "Replace Pairing File" : "Import Pairing File") { showPairingPicker = true }
            if !hasPairingFile {
                Link("Get iloader", destination: Self.iloaderURL)
            } else {
                Button("Remove Pairing File", role: .destructive) { confirmRemove = true }
            }
        } footer: {
            Text("On a Mac or PC, install iloader, connect this iPhone with a cable and choose Manage Pairing File. Export the remote-pairing file (PairingFile_RemoteRP.plist), send it to this iPhone and import it here. Make a new one after updating or resetting the iPhone.")
        }
    }

    private var vpnStep: some View {
        Section {
            SetupStepRow(number: 2, title: "LocalDevVPN", done: vpnReachable,
                         status: vpnReachable == nil ? "Checking…" : vpnReachable == true ? "Connected" : "Not connected")
            if vpnReachable != true {
                Button("Open LocalDevVPN") {
                    Task {
                        let opened = await UIApplication.shared.open(Self.localDevVPNURL)
                        if !opened { openURL(Self.localDevVPNStoreURL) }
                    }
                }
            }
            Button("Check Again") { Task { await refreshVPN() } }
        } footer: {
            Text("LocalDevVPN lets Signet reach this iPhone's installer. Install it from the App Store, connect it, and keep it on while installing. Wi-Fi needs to be on.")
        }
    }

    private var testStep: some View {
        Section {
            SetupStepRow(number: 3, title: "Test Connection", done: testResult.map { if case .ready = $0 { true } else { false } },
                         status: testStatus)
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || !hasPairingFile)
        } footer: {
            if case .failed(let reason) = testResult {
                Text(reason).foregroundStyle(.red)
            } else {
                Text("Checks the pairing file and the VPN together. Installs use direct install once this works.")
            }
        }
    }

    private var testStatus: String {
        switch testResult {
        case nil: testing ? "Testing…" : "Not tested"
        case .ready(let version): "Ready: iPhone on iOS \(version)"
        case .failed: "Failed"
        }
    }

    private var advanced: some View {
        Section {
            DisclosureGroup("Advanced") {
                LabeledContent("VPN Address") {
                    TextField(DirectInstaller.defaultAddress, text: $address)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Pairing Port") {
                    TextField("Automatic", text: $port)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                Button {
                    UIPasteboard.general.string = DirectInstallDiagnostics.text(installer.directLog)
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
            }
        } footer: {
            Text("Direct install uses idevice by Jackson Coxson (MIT licence).")
        }
    }

    // MARK: - Actions

    private func refreshVPN() async {
        guard method == InstallMethod.direct.rawValue else { return }
        vpnReachable = nil
        let address = DirectInstall.address
        let port = DirectInstall.manualPort ?? DirectInstall.discoveredPort ?? DirectInstaller.defaultPort
        vpnReachable = await DirectInstaller.isReachable(address: address, port: port)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        testResult = nil
        do {
            let version = try await InstallManager.testDirectConnection()
            testResult = .ready(iOS: version)
            vpnReachable = true
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }
}

/// A numbered setup step that shows a tick once it's done.
private struct SetupStepRow: View {
    let number: Int
    let title: String
    /// nil while unknown.
    let done: Bool?
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done == true ? Color.green : Color.secondary.opacity(0.2)).frame(width: 28, height: 28)
                if done == true {
                    Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.footnote.bold()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status).font(.footnote).foregroundStyle(done == false ? .orange : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Everything useful for a direct-install bug report, for Copy Details and Copy Diagnostics.
enum DirectInstallDiagnostics {
    static func text(_ log: ActivityLog) -> String {
        let device = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = [
            "Signet \(version) (\(build)) direct install",
            "\(device.model), \(device.systemName) \(device.systemVersion)",
            "Address \(DirectInstall.address), port \(DirectInstall.manualPort.map(String.init) ?? "automatic")"
                + (DirectInstall.discoveredPort.map { " (found \($0))" } ?? ""),
            "Pairing file: \(DirectInstall.hasPairingFile ? "imported" : "none")",
            "",
            log.isEmpty ? "No direct install yet." : log.text,
        ]
        if let library = try? String(contentsOf: DirectInstaller.libraryLogURL, encoding: .utf8), !library.isEmpty {
            lines += ["", "--- idevice log (last 150 lines) ---"] + library.split(separator: "\n").suffix(150).map(String.init)
        }
        return lines.joined(separator: "\n")
    }
}
