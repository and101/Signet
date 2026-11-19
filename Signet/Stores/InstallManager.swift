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
    /// Fails a server transfer that stops partway; iOS doesn't say when it gives up on a download.
    private var transferWatch: Task<Void, Never>?
    private var lastTransferProgress = Date()
    static let transferStallTimeout: TimeInterval = 60
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
    /// Whether the current failure came from a direct install, so its details are the ones on offer.
    private(set) var failedDirectly = false
    /// After a direct self-update, how it went, shown once on the next launch.
    var selfUpdateResult: String?
    private var pendingSelfUpdateApp: LibraryApp?
    /// Quits Signet after a self-update request; cancelled if the install fails first.
    private var selfUpdateExit: Task<Void, Never>?
    /// Set once Signet starts leaving for a self-update. Errors after that are the connection closing as Signet
    /// goes, not the install failing: iOS has the request and finishes it.
    private var selfUpdateLeaving = false
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
        // A watcher from an earlier install that was replaced without being dismissed.
        transferWatch?.cancel()
        transferWatch = nil
        serverFallback = nil
        phase = nil
        failedDirectly = false
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
        transferWatch?.cancel()
        transferWatch = nil
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
                lastTransferProgress = Date()
                watchTransfer(token: token, appName: name)
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
        transferWatch?.cancel()
        transferWatch = nil
        endBackgroundTask()
    }

    /// Started on the first progress report; fails the install if the transfer then stalls.
    private func watchTransfer(token: String, appName: String) {
        guard transferWatch == nil else { return }
        transferWatch = Task { [weak self] in
            // Counted in ticks the app was awake for: after a suspension the clock jumps, but no ticks were missed.
            var idleTicks = 0
            var lastSeen = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                guard self.token == token, case .transferring = self.state else { break }
                if self.lastTransferProgress != lastSeen {
                    lastSeen = self.lastTransferProgress
                    idleTicks = 0
                } else {
                    idleTicks += 1
                }
                if Double(idleTicks) * 5 >= Self.transferStallTimeout {
                    self.fail(String(localized: "The download to iOS stopped. Try again with Signet open, or turn on Keep Running During Installs."))
                    return
                }
            }
            self?.transferWatch = nil
        }
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
                self.fail(String(localized: """
                iOS didn't contact the install server, so it was restarted. Try again. If it keeps failing, \
                check Settings → General → About → Certificate Trust Settings.
                """))
                return
            }
            // After the manifest, waiting is normal: the user may not have tapped Install yet.
            try? await Task.sleep(for: .seconds(100))
            guard !Task.isCancelled, self.token == token else { return }
            if case .manifestServed = self.state {
                self.fail(String(localized: """
                iOS didn't download the app. If you tapped Install, check the Home Screen for an error, \
                then try again with Signet open.
                """))
            }
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        watchdog?.cancel()
        progressWatch?.cancel()
        transferWatch?.cancel()
        transferWatch = nil
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
            fail(String(localized: "The signed IPA is missing. Sign the app again."))
            return
        }
        guard DirectInstall.hasPairingFile else {
            serverFallback = app
            fail(String(localized: "Direct install needs a pairing file. Add one in Settings → Install Method, or use the install server."))
            return
        }
        let selfUpdate = SelfUpdateCheck.evaluate(app: app, runningBundleID: Bundle.main.bundleIdentifier,
                                                  runningTeamID: SelfUpdateCheck.runningTeamID,
                                                  signingTeamID: teamLookup(app.certificateID))
        switch selfUpdate {
        case .separateCopy:
            serverFallback = app
            let signetID = Bundle.main.bundleIdentifier ?? "ember.wax.signet"
            fail(String(localized: "This copy has a different bundle ID (\(app.bundleID)), so it would install as a separate Signet without your data. To update, sign it as \(signetID). For a separate copy, use the install server."))
            return
        case .update(let differentTeam) where !confirmedSelfUpdate:
            pendingSelfUpdateApp = app
            state = .confirmingSelfUpdate(appName: app.name, differentTeam: differentTeam)
            return
        default:
            break
        }
        let isSelfUpdate = selfUpdate != .otherApp

        // One direct install (or connection test) at a time: a second one's cleanup could delete the first one's
        // upload, and a closed sheet's install keeps running. Checked and claimed with no suspension in between.
        guard Self.runningDirectInstalls == 0 else {
            fail(String(localized: "Another direct install is still finishing. Try again in a moment."))
            return
        }
        let token = UUID().uuidString
        self.token = token
        directLog.start()
        directLog.append("Installing \(app.name) \(app.version) (\(app.size.formattedBytes)) directly")
        state = .waiting(appName: app.name)
        phase = String(localized: "Connecting to your iPhone…")
        if !isSelfUpdate { beginBackgroundTask() }
        DirectInstaller.startLibraryLog()

        let installer = DirectInstaller(pairingFileURL: DirectInstall.pairingFileURL, address: DirectInstall.address) { line in
            Task { @MainActor in self.directLog.append(line) }
        }
        var remote: String?
        Self.runningDirectInstalls += 1
        defer { Self.runningDirectInstalls -= 1 }
        do {
            guard let port = await Self.resolvePort() else {
                throw DirectInstaller.Failure(stage: .connect, message:
                    String(localized: "Can't reach this iPhone. Check LocalDevVPN is connected and Wi-Fi is on."))
            }
            let version = try await installer.connect(port: port, timeout: DirectInstaller.connectTimeout)
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
                DirectInstall.pendingSelfUpdate = .init(version: app.version, build: app.build,
                                                        bundlePath: Bundle.main.bundlePath, date: Date())
                DirectInstall.recordSelfUpdate("Sending \(app.version) (\(app.build)) from \(Bundle.main.bundlePath)")
            }
            let bundleID = app.bundleID
            let appName = app.name
            try await Task.detached {
                try installer.install(remotePath: uploaded, bundleID: bundleID, requestSent: {
                    guard isSelfUpdate else { return }
                    Task { @MainActor in self.closeForSelfUpdate(appName: appName) }
                }) { fraction in
                    Task { @MainActor in
                        // While closing for a self-update, keep saying so; the install itself carries on.
                        guard self.token == token, self.selfUpdateExit == nil else { return }
                        self.state = .installing(appName: appName, progress: fraction)
                        self.phase = DirectInstaller.phase(forPercent: Int(fraction * 100))
                    }
                }
            }.value
            if isSelfUpdate {
                // Keep the record: the next launch confirms the update.
                DirectInstall.recordSelfUpdate("The installer reported success")
            } else {
                DirectInstall.pendingSelfUpdate = nil
            }
            InstallHistory.record(bundleID)
            directLog.finish(.succeeded, "Installed \(app.name) \(app.version)")
            await Self.removeStaged([uploaded], with: installer)
            guard self.token == token else { return }
            installedBundleID = bundleID
            phase = nil
            finish(.installed(appName: app.name))
        } catch {
            if isSelfUpdate, selfUpdateLeaving {
                // Signet is quitting and iOS is installing; leave the record and the uploaded IPA alone.
                DirectInstall.recordSelfUpdate("Connection closed while leaving (expected): \(error.localizedDescription)")
                return
            }
            if isSelfUpdate { DirectInstall.recordSelfUpdate("Failed before leaving: \(error.localizedDescription)") }
            // Don't quit for a self-update that failed; stay open to show why.
            selfUpdateExit?.cancel()
            selfUpdateExit = nil
            DirectInstall.pendingSelfUpdate = nil
            directLog.finish(.failed, error.localizedDescription)
            if let remote { await Self.removeStaged([remote], with: installer) }
            guard self.token == token else { return }
            let stage = (error as? DirectInstaller.Failure)?.stage
            if stage == .connect || stage == .tunnel || stage == .pairingFile { serverFallback = app }
            failedDirectly = true
            phase = nil
            fail(stage == .pairingFile || stage == .tunnel
                 ? String(localized: "\(error.localizedDescription). The pairing file may have expired after an iOS update or reset. Make a new one with iloader.")
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
        selfUpdateExit = Task {
            // Long enough for a request iOS rejects outright to fail first and cancel this.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.selfUpdateLeaving = true
            DirectInstall.recordSelfUpdate("Request sent; going to the Home Screen and quitting")
            UserDefaults.standard.synchronize()
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            exit(0)
        }
    }

    /// Reports a direct self-update from the previous launch, once.
    func checkPendingSelfUpdate() {
        guard let pending = DirectInstall.pendingSelfUpdate else { return }
        DirectInstall.pendingSelfUpdate = nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? pending.version
        let created = try? Bundle.main.bundleURL.resourceValues(forKeys: [.creationDateKey]).creationDate
        let updated = pending.wasInstalled(nowAt: Bundle.main.bundlePath, bundleCreated: created)
        DirectInstall.recordSelfUpdate("Launch check: now at \(Bundle.main.bundlePath), folder created \(created?.formatted(.iso8601) ?? "unknown"); updated: \(updated)")
        let result = updated
            ? String(localized: "Signet updated to \(version).")
            : String(localized: "Signet didn't update to \(pending.version). Try installing it again.")
        // Shown once the first screen is up; an alert raised during launch can be dropped.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            self.selfUpdateResult = result
        }
    }

    /// The manual port, else the last one found, else the usual one, else a Bonjour search.
    private static func resolvePort() async -> UInt16? {
        let address = DirectInstall.address
        if let manual = DirectInstall.manualPort { return manual }
        for candidate in [DirectInstall.discoveredPort, DirectInstaller.defaultPort].compactMap({ $0 }) {
            if await DirectInstaller.isReachable(address: address, port: candidate) { return candidate }
        }
        for found in await DirectInstaller.discoverPorts() where await DirectInstaller.isReachable(address: address, port: found) {
            DirectInstall.discoveredPort = found
            return found
        }
        return nil
    }

    /// Deletes IPAs earlier installs left on the iPhone: the recorded ones, plus any found in the staging folder.
    /// Direct installs whose work is still running, including ones whose sheet was closed. Their uploads are in
    /// the staging folder and mustn't be cleaned up as leftovers.
    private static var runningDirectInstalls = 0

    /// Deletes IPAs earlier installs left on the iPhone. Only called by the one running direct operation, so no
    /// other upload can be in the staging folder.
    private static func removeLeftovers(with installer: DirectInstaller) async {
        let recorded = DirectInstall.stagedPaths
        guard let found = try? await Task.detached(operation: { try installer.listStaged() }).value else {
            // Couldn't list: try the recorded ones, and keep any that fail for next time.
            if !recorded.isEmpty { await removeStaged(recorded, with: installer) }
            return
        }
        // Recorded files that are no longer there were removed by iOS; forget them.
        DirectInstall.stagedPaths.removeAll { !found.contains($0) }
        guard !found.isEmpty else { return }
        await removeStaged(found, with: installer)
    }

    private static func removeStaged(_ paths: [String], with installer: DirectInstaller) async {
        guard let removed = try? await Task.detached(operation: { try installer.removeStaged(paths) }).value else { return }
        DirectInstall.stagedPaths.removeAll { removed.contains($0) }
    }

    /// Checks the whole connection for Settings: pairing file, VPN, tunnel. Returns the iOS version.
    static func testDirectConnection() async throws -> String {
        guard DirectInstall.hasPairingFile else { throw AppError("Import a pairing file first.") }
        guard runningDirectInstalls == 0 else { throw AppError("A direct install is still running. Try again when it finishes.") }
        runningDirectInstalls += 1
        defer { runningDirectInstalls -= 1 }
        DirectInstaller.startLibraryLog()
        guard let port = await resolvePort() else {
            throw AppError("Can't reach this iPhone. Check LocalDevVPN is connected and Wi-Fi is on.")
        }
        let installer = DirectInstaller(pairingFileURL: DirectInstall.pairingFileURL, address: DirectInstall.address)
        let version: String
        do {
            version = try await installer.connect(port: port, timeout: DirectInstaller.connectTimeout)
        } catch let failure as DirectInstaller.Failure where failure.stage == .tunnel {
            throw AppError(verbatim: String(localized: "\(failure.localizedDescription). The pairing file may have expired after an iOS update or reset. Make a new one with iloader."))
        }
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
