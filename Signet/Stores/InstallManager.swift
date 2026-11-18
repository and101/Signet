import Foundation
import Observation
import UIKit

/// Drives an over-the-air install through the local server and reports progress to the UI.
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
    }

    private(set) var state: State = .idle
    private var token: String?
    private var bundleID: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var watchdog: Task<Void, Never>?
    private var progressWatch: Task<Void, Never>?
    /// The bundle ID of the app last installed, for the Open button.
    private(set) var installedBundleID: String?

    init() {
        InstallServer.shared.onProgress = { [weak self] token, sent, total in
            Task { @MainActor in self?.update(token: token, sent: sent, total: total) }
        }
        InstallServer.shared.onRequest = { [weak self] token, file in
            Task { @MainActor in self?.requested(token: token, file: file) }
        }
    }

    func install(_ app: LibraryApp) async {
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
        case .waiting, .manifestServed, .transferring, .installing, .installed:
            break
        }
    }

    func dismiss() {
        state = .idle
        token = nil
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
            state = .transferring(appName: name, progress: Double(sent) / Double(max(total, 1)))
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
                    // For a first install, double-check iOS really has it; an update was installed already.
                    let check = await Task.detached { InstalledApps.workingSystemCheck()?(bundleID) }.value
                    self.installedBundleID = bundleID
                    self.finish(check == false ? .finished(appName: appName) : .installed(appName: appName))
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
            Task { @MainActor in self?.endBackgroundTask() }
        }
        KeepAlive.shared.start()
    }

    private func endBackgroundTask() {
        KeepAlive.shared.stop()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension InstallManager.State {
    var appName: String? {
        switch self {
        case .waiting(let name), .manifestServed(let name), .transferring(let name, _), .installing(let name, _),
             .installed(let name), .finished(let name): name
        case .idle, .failed: nil
        }
    }
}
