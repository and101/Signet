import Foundation
import Observation
import UIKit

/// Drives an install, through the local server (over the air) or directly through a pairing file, and reports
/// progress to the UI.
@MainActor @Observable
final class InstallManager {
    enum State: Equatable {
        case idle
        /// Waiting for iOS to fetch the manifest (the system prompt is showing or about to).
        case waiting(appName: String)
        /// iOS fetched the manifest; waiting for the user to confirm and installd to request the IPA.
        case manifestServed(appName: String)
        case transferring(appName: String, progress: Double)
        /// The IPA is with iOS, which is installing it. Progress is nil until iOS reports a fraction.
        case installing(appName: String, progress: Double?)
        /// iOS finished installing the app.
        case installed(appName: String)
        /// The IPA reached iOS, but Signet can't tell whether the install worked.
        case finished(appName: String)
        case failed(String)
        /// Direct install of Signet itself: waiting for the user to agree to Signet closing.
        case confirmingSelfUpdate(appName: String, differentTeam: Bool)
        /// The update to Signet is with iOS; Signet is about to quit so iOS can replace it.
        case closingForUpdate(appName: String)
    }

    private(set) var state: State = .idle
    private var token: String?
    private var bundleID: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var watchdog: Task<Void, Never>?
    private var progressWatch: Task<Void, Never>?
    /// The bundle ID of the app last installed, for the Open button.
    private(set) var installedBundleID: String?
    /// The build iOS had installed under this bundle ID before the install; see `InstallWatch.confirmed`.
    private var buildBefore: String??
    private var expectedBuild = ""

    /// What's happening, in plain words, while connecting or installing directly.
    private(set) var phase: String?
    /// A direct install that couldn't connect, which the server method can install instead.
    private(set) var serverFallback: LibraryApp?
    /// The steps of the last direct install, for its Details and Copy Diagnostics.
    private(set) var directLog = ActivityLog()
    /// After a direct self-update, how it went, shown once on the next launch.
    var selfUpdateResult: String?
    private var pendingSelfUpdateApp: LibraryApp?
    /// The team of the certificate an app was signed with, to warn before a self-update changes team.
    var teamLookup: (UUID?) -> String? = { _ in nil }

    init() {
        InstallServer.shared.onProgress = { [weak self] token, sent, total in
            Task { @MainActor in self?.update(token: token, sent: sent, total: total) }
        }
        InstallServer.shared.onRequest = { [weak self] token, file in
            Task { @MainActor in self?.requested(token: token, file: file) }
        }
    }

    func install(_ app: LibraryApp, method: InstallMethod = DirectInstall.method) async {
        serverFallback = nil
        phase = nil
        if method == .direct {
            await installDirectly(app)
            return
        }
        do {
            guard FileManager.default.fileExists(atPath: app.ipaURL.path) else {
                throw AppError("The signed IPA is missing. Sign the app again.")
            }
            if ServerCertificate.info?.isExpired != false {
                try ServerCertificate.ensure()
                try InstallServer.shared.restartIfRunning()
            }
            guard await Task.detached(operation: { ServerCertificate.isTrusted }).value else {
                throw AppError("Set up Settings → Install Certificate first. It's a one-time step.")
            }
            let hosted = InstallServer.HostedApp(
                ipa: app.ipaURL,
                icon: FileManager.default.fileExists(atPath: app.iconURL.path) ? app.iconURL : nil,
                bundleID: app.bundleID,
                // The manifest's bundle-version is compared with CFBundleVersion, the build number.
                bundleVersion: app.build,
                title: app.name
            )
            try await InstallServer.shared.ensureResponsive()
            let (token, url) = try await Task.detached { try InstallServer.shared.host(hosted) }.value
            self.token = token
            self.bundleID = app.bundleID
            expectedBuild = app.build
            let bundleID = app.bundleID
            buildBefore = await Task.detached { InstallWatch.installedBuild(bundleID) }.value
            state = .waiting(appName: app.name)
            beginBackgroundTask()
            guard await UIApplication.shared.open(url) else {
                throw AppError("iOS refused to open the install link.")
            }
            startWatchdog(token: token, appName: app.name)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Revives the server after a suspension so it's ready before the user taps Install.
    func appBecameActive() {
        switch state {
        case .idle, .finished, .failed:
            Task { try? await InstallServer.shared.ensureResponsive() }
        case .waiting, .manifestServed, .transferring, .installing, .installed, .confirmingSelfUpdate, .closingForUpdate:
            break
        }
    }

    func dismiss() {
        state = .idle
        token = nil
        phase = nil
        serverFallback = nil
        pendingSelfUpdateApp = nil
        watchdog?.cancel()
        progressWatch?.cancel()
        endBackgroundTask()
    }

    private func requested(token: String, file: String) {
        guard token == self.token, file == "manifest.plist", case .waiting(let name) = state else { return }
        state = .manifestServed(appName: name)
    }

    private func update(token: String, sent: Int64, total: Int64) {
        guard token == self.token, let name = state.appName else { return }
        if sent >= total {
            // Only the first completion counts; a small IPA can finish before any progress was reported.
            switch state {
            case .waiting, .manifestServed, .transferring: break
            default: return
            }
            if let bundleID { InstallHistory.record(bundleID) }
            watchdog?.cancel()
            watchInstall(appName: name)
        } else {
            // A late or repeated request mustn't pull a finished transfer back.
            switch state {
            case .waiting, .manifestServed, .transferring:
                state = .transferring(appName: name, progress: Double(sent) / Double(max(total, 1)))
            default:
                break
            }
        }
    }

    /// Follows iOS's own install after the transfer, keeping Signet awake until it ends.
    private func watchInstall(appName: String) {
        guard let bundleID, InstallProgress.isAvailable else {
            finish(.finished(appName: appName))
            return
        }
        state = .installing(appName: appName, progress: nil)
        let token = token
        progressWatch?.cancel()
        progressWatch = Task { [weak self] in
            var watch = InstallWatch()
            while !Task.isCancelled {
                let fraction = await Task.detached { InstallProgress.fraction(for: bundleID) }.value
                guard let self, self.token == token, !Task.isCancelled else { return }
                switch watch.step(progress: fraction) {
                case .installing(let progress):
                    self.state = .installing(appName: appName, progress: progress)
                case .installed:
                    // Progress also disappears when an install fails, so only claim success with evidence.
                    let after = await Task.detached { InstallWatch.installedBuild(bundleID) }.value
                    let confirmed = InstallWatch.confirmed(before: self.buildBefore, after: after, expected: self.expectedBuild)
                    self.installedBundleID = bundleID
                    self.finish(confirmed ? .installed(appName: appName) : .finished(appName: appName))
                    return
                case .unknown:
                    self.finish(.finished(appName: appName))
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func finish(_ final: State) {
        state = final
        progressWatch?.cancel()
        endBackgroundTask()
    }

    /// Turns a silent failure into an explanation instead of an endless spinner.
    private func startWatchdog(token: String, appName: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.token == token else { return }
            if case .waiting = self.state {
                // Start from a fresh server next time in case this one stopped accepting connections.
                Task.detached { InstallServer.shared.stop() }
                self.fail("""
                iOS never contacted the install server. Tap Install to try again; the server has been restarted. \
                If it keeps failing, check the Signet certificate is still trusted in \
                Settings → General → About → Certificate Trust Settings.
                """)
                return
            }
            // After the manifest, waiting is normal: the user may not have tapped Install yet.
            try? await Task.sleep(for: .seconds(100))
            guard !Task.isCancelled, self.token == token else { return }
            if case .manifestServed = self.state {
                self.fail("""
                iOS fetched the install manifest but never downloaded the app. If you tapped Install, \
                check the home screen for an error, then try again with this app kept open.
                """)
            }
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        watchdog?.cancel()
        progressWatch?.cancel()
        endBackgroundTask()
    }

    /// iOS downloads the IPA after the user confirms the prompt, often with us in the background.
    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Install") { [weak self] in
            // Only the UIKit task has run out; the silent audio is what keeps the install going from here.
            Task { @MainActor in self?.endUIKitTask() }
        }
        KeepAlive.shared.start()
    }

    /// Ends the install's background time: the UIKit task and the silent audio.
    private func endBackgroundTask() {
        KeepAlive.shared.stop()
        endUIKitTask()
    }

    private func endUIKitTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Direct install

extension InstallManager {
    /// Uploads the IPA to the iPhone's staging folder and asks its installer to install it, through the pairing
    /// file's tunnel. Connection problems offer the server method instead.
    private func installDirectly(_ app: LibraryApp, confirmedSelfUpdate: Bool = false) async {
        guard FileManager.default.fileExists(atPath: app.ipaURL.path) else {
            fail("The signed IPA is missing. Sign the app again.")
            return
        }
        guard DirectInstall.hasPairingFile else {
            serverFallback = app
            fail("Direct install needs a pairing file. Set it up in Settings → Install Method, or use the install server.")
            return
        }
        let selfUpdate = SelfUpdateCheck.evaluate(app: app, runningBundleID: Bundle.main.bundleIdentifier,
                                                  runningTeamID: SelfUpdateCheck.runningTeamID,
                                                  signingTeamID: teamLookup(app.certificateID))
        switch selfUpdate {
        case .separateCopy:
            serverFallback = app
            fail("This copy of Signet has a different bundle ID (\(app.bundleID)), so it would install as a separate app "
                 + "without your library or certificates. To update Signet, sign it with "
                 + "\(Bundle.main.bundleIdentifier ?? "Signet's own bundle ID"). To install it as a separate app anyway, "
                 + "use the install server.")
            return
        case .update(let differentTeam) where !confirmedSelfUpdate:
            pendingSelfUpdateApp = app
            state = .confirmingSelfUpdate(appName: app.name, differentTeam: differentTeam)
            return
        default:
            break
        }
        let isSelfUpdate = selfUpdate != .otherApp

        let token = UUID().uuidString
        self.token = token
        directLog.start()
        directLog.append("Installing \(app.name) \(app.version) (\(app.size.formattedBytes)) directly")
        state = .waiting(appName: app.name)
        phase = "Connecting to your iPhone…"
        if !isSelfUpdate { beginBackgroundTask() }
        DirectInstaller.startLibraryLog()

        let installer = DirectInstaller(pairingFileURL: DirectInstall.pairingFileURL, address: DirectInstall.address) { line in
            Task { @MainActor in self.directLog.append(line) }
        }
        var remote: String?
        do {
            guard let port = await Self.resolvePort() else {
                throw DirectInstaller.Failure(stage: .connect, message:
                    "Can't reach this iPhone through the VPN. Check LocalDevVPN is connected and Wi-Fi is on, then try again.")
            }
            let version = try await Task.detached { try installer.connect(port: port) }.value
            guard self.token == token else { return }
            directLog.append("Connected to iOS \(version)")
            await Self.removeLeftovers(with: installer)

            phase = nil
            state = .transferring(appName: app.name, progress: 0)
            let ipa = app.ipaURL
            let uploaded = try await Task.detached {
                try installer.upload(ipa, staged: { DirectInstall.stagedPaths.append($0) }) { fraction in
                    Task { @MainActor in
                        guard self.token == token else { return }
                        self.state = .transferring(appName: app.name, progress: fraction)
                    }
                }
            }.value
            remote = uploaded
            guard self.token == token else { return }
            directLog.append("Uploaded to \(uploaded)")

            state = .installing(appName: app.name, progress: nil)
            phase = DirectInstaller.phase(forPercent: 0)
            if isSelfUpdate {
                DirectInstall.pendingSelfUpdate = .init(version: app.version, build: app.build)
            }
            let bundleID = app.bundleID
            let appName = app.name
            try await Task.detached {
                try installer.install(remotePath: uploaded, bundleID: bundleID, requestSent: {
                    guard isSelfUpdate else { return }
                    Task { @MainActor in self.closeForSelfUpdate(appName: appName) }
                }) { fraction in
                    Task { @MainActor in
                        guard self.token == token else { return }
                        self.state = .installing(appName: appName, progress: fraction)
                        self.phase = DirectInstaller.phase(forPercent: Int(fraction * 100))
                    }
                }
            }.value
            DirectInstall.pendingSelfUpdate = nil
            InstallHistory.record(bundleID)
            directLog.finish(.succeeded, "Installed \(app.name) \(app.version)")
            await Self.removeStaged([uploaded], with: installer)
            guard self.token == token else { return }
            installedBundleID = bundleID
            phase = nil
            finish(.installed(appName: app.name))
        } catch {
            DirectInstall.pendingSelfUpdate = nil
            directLog.finish(.failed, error.localizedDescription)
            if let remote { await Self.removeStaged([remote], with: installer) }
            guard self.token == token else { return }
            let stage = (error as? DirectInstaller.Failure)?.stage
            if stage == .connect || stage == .pairingFile { serverFallback = app }
            phase = nil
            fail(stage == .pairingFile
                 ? "\(error.localizedDescription). The pairing file may have expired (it does after an iOS update or reset); make a new one with iloader."
                 : error.localizedDescription)
        }
    }

    /// The user agreed to Signet closing to update itself.
    func confirmSelfUpdate() {
        guard let app = pendingSelfUpdateApp else { return }
        pendingSelfUpdateApp = nil
        Task { await installDirectly(app, confirmedSelfUpdate: true) }
    }

    /// Installs with the server method after a direct install couldn't connect.
    func retryWithServer() {
        guard let app = serverFallback else { return }
        serverFallback = nil
        Task { await install(app, method: .server) }
    }

    /// iOS won't replace Signet while it runs (on iOS 27 an install of itself waits at 0% until it's closed), so
    /// once the request is on its way, go to the Home Screen and quit. iOS finishes on its own.
    private func closeForSelfUpdate(appName: String) {
        state = .closingForUpdate(appName: appName)
        endBackgroundTask()
        Task {
            try? await Task.sleep(for: .seconds(2))
            UserDefaults.standard.synchronize()
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            try? await Task.sleep(for: .milliseconds(500))
            exit(0)
        }
    }

    /// Reports a direct self-update from the previous launch, once.
    func checkPendingSelfUpdate() {
        guard let pending = DirectInstall.pendingSelfUpdate else { return }
        DirectInstall.pendingSelfUpdate = nil
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? pending.version
        selfUpdateResult = build == pending.build
            ? "Signet updated to \(version)."
            : "Signet didn't update to \(pending.version). Try installing it again."
    }

    /// The manual port, else the last one found, else the usual one, else a Bonjour search.
    private static func resolvePort() async -> UInt16? {
        let address = DirectInstall.address
        if let manual = DirectInstall.manualPort { return manual }
        for candidate in [DirectInstall.discoveredPort, DirectInstaller.defaultPort].compactMap({ $0 }) {
            if await DirectInstaller.isReachable(address: address, port: candidate) { return candidate }
        }
        if let found = await DirectInstaller.discoverPort(), await DirectInstaller.isReachable(address: address, port: found) {
            DirectInstall.discoveredPort = found
            return found
        }
        return nil
    }

    private static func removeLeftovers(with installer: DirectInstaller) async {
        let leftovers = DirectInstall.stagedPaths
        guard !leftovers.isEmpty else { return }
        await removeStaged(leftovers, with: installer)
    }

    private static func removeStaged(_ paths: [String], with installer: DirectInstaller) async {
        guard let removed = try? await Task.detached(operation: { try installer.removeStaged(paths) }).value else { return }
        DirectInstall.stagedPaths.removeAll { removed.contains($0) }
    }

    /// Checks the whole connection for Settings: pairing file, VPN, tunnel. Returns the iOS version.
    static func testDirectConnection() async throws -> String {
        guard DirectInstall.hasPairingFile else { throw AppError("Import a pairing file first.") }
        DirectInstaller.startLibraryLog()
        guard let port = await resolvePort() else {
            throw AppError("Can't reach this iPhone through the VPN. Check LocalDevVPN is connected and Wi-Fi is on.")
        }
        let installer = DirectInstaller(pairingFileURL: DirectInstall.pairingFileURL, address: DirectInstall.address)
        let version = try await Task.detached { try installer.connect(port: port) }.value
        await removeLeftovers(with: installer)
        return version
    }
}

extension InstallManager.State {
    var appName: String? {
        switch self {
        case .waiting(let name), .manifestServed(let name), .transferring(let name, _), .installing(let name, _),
             .installed(let name), .finished(let name), .confirmingSelfUpdate(let name, _), .closingForUpdate(let name): name
        case .idle, .failed: nil
        }
    }
}
