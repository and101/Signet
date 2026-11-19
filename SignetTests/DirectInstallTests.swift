import XCTest
@testable import Signet
import IDevice

/// Direct install without an iPhone: settings, the self-update rules, pairing-file checks, and failures coming
/// back as errors rather than crashes or hangs.
final class DirectInstallTests: XCTestCase {
    private var savedDefaults: [String: Any?] = [:]
    private let keys = [DirectInstall.methodKey, DirectInstall.addressKey, DirectInstall.portKey,
                        "directInstallDiscoveredPort", "directInstallStagedPaths", "directInstallPendingSelfUpdate",
                        "directInstallSelfUpdateTrail"]

    override func setUp() {
        Paths.prepare()
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for (key, value) in savedDefaults { UserDefaults.standard.set(value ?? nil, forKey: key) }
    }

    private func app(bundleID: String, original: String?) -> LibraryApp {
        var app = LibraryApp(kind: .signed, name: "Signet", bundleID: bundleID, version: "1.1", build: "2",
                             appFolderName: "Signet.app", size: 0)
        app.originalBundleID = original
        return app
    }

    // MARK: - Settings

    func testDefaults() {
        XCTAssertEqual(DirectInstall.method, .server)
        XCTAssertEqual(DirectInstall.address, "10.7.0.1")
        XCTAssertNil(DirectInstall.manualPort)
        XCTAssertNil(DirectInstall.discoveredPort)
        XCTAssertEqual(DirectInstall.stagedPaths, [])
    }

    func testManualPortAndAddress() {
        UserDefaults.standard.set(" 50123 ", forKey: DirectInstall.portKey)
        XCTAssertEqual(DirectInstall.manualPort, 50123)
        UserDefaults.standard.set("0", forKey: DirectInstall.portKey)
        XCTAssertNil(DirectInstall.manualPort, "0 means automatic")
        UserDefaults.standard.set("nope", forKey: DirectInstall.portKey)
        XCTAssertNil(DirectInstall.manualPort)
        UserDefaults.standard.set("  ", forKey: DirectInstall.addressKey)
        XCTAssertEqual(DirectInstall.address, "10.7.0.1", "blank falls back to LocalDevVPN's address")
        UserDefaults.standard.set("10.8.0.1", forKey: DirectInstall.addressKey)
        XCTAssertEqual(DirectInstall.address, "10.8.0.1")
    }

    func testDiscoveredPortAndPendingUpdateRoundTrip() {
        DirectInstall.discoveredPort = 62000
        XCTAssertEqual(DirectInstall.discoveredPort, 62000)
        DirectInstall.discoveredPort = nil
        XCTAssertNil(DirectInstall.discoveredPort)
        let pending = DirectInstall.PendingSelfUpdate(version: "1.1", build: "7", bundlePath: "/a", date: Date(timeIntervalSince1970: 5))
        DirectInstall.pendingSelfUpdate = pending
        XCTAssertEqual(DirectInstall.pendingSelfUpdate, pending)
        DirectInstall.pendingSelfUpdate = nil
        XCTAssertNil(DirectInstall.pendingSelfUpdate)
    }

    // MARK: - Self-update rules

    func testOtherAppsAreNotSelfUpdates() {
        let other = app(bundleID: "com.example.app", original: "com.example.app")
        XCTAssertEqual(SelfUpdateCheck.evaluate(app: other, runningBundleID: "ember.wax.signet", runningTeamID: "AAA", signingTeamID: "BBB"),
                       .otherApp)
    }

    func testSameBundleIDIsAnUpdate() {
        let update = app(bundleID: "ember.wax.signet", original: "ember.wax.signet")
        XCTAssertEqual(SelfUpdateCheck.evaluate(app: update, runningBundleID: "ember.wax.signet", runningTeamID: "AAA", signingTeamID: "AAA"),
                       .update(differentTeam: false))
        XCTAssertEqual(SelfUpdateCheck.evaluate(app: update, runningBundleID: "ember.wax.signet", runningTeamID: "AAA", signingTeamID: "BBB"),
                       .update(differentTeam: true))
        // Without both teams known, don't warn.
        XCTAssertEqual(SelfUpdateCheck.evaluate(app: update, runningBundleID: "ember.wax.signet", runningTeamID: nil, signingTeamID: "BBB"),
                       .update(differentTeam: false))
        XCTAssertEqual(SelfUpdateCheck.evaluate(app: update, runningBundleID: "ember.wax.signet", runningTeamID: "AAA", signingTeamID: nil),
                       .update(differentTeam: false))
    }

    func testSignetUnderACustomBundleIDUpdatesItself() {
        // Signet installed as com.me.signet, updated with an IPA re-signed to the same ID.
        let update = app(bundleID: "com.me.signet", original: "ember.wax.signet")
        XCTAssertEqual(SelfUpdateCheck.evaluate(app: update, runningBundleID: "com.me.signet", runningTeamID: nil, signingTeamID: nil),
                       .update(differentTeam: false))
    }

    func testCopyWithAnotherBundleIDIsASeparateApp() {
        let copy = app(bundleID: "ember.wax.signet.k3x9qa", original: "ember.wax.signet")
        XCTAssertEqual(SelfUpdateCheck.evaluate(app: copy, runningBundleID: "ember.wax.signet", runningTeamID: nil, signingTeamID: nil),
                       .separateCopy)
    }

    // MARK: - Pairing files

    func testRejectsLockdownAndOtherFiles() throws {
        let folder = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(folder) }
        let lockdown = folder.appendingPathComponent("lockdown.plist")
        let keys: [String: Any] = ["HostCertificate": Data([1]), "HostPrivateKey": Data([1]),
                                   "RootCertificate": Data([1]), "DeviceCertificate": Data([1])]
        try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0).write(to: lockdown)
        XCTAssertThrowsError(try DirectInstall.importPairingFile(from: lockdown)) { error in
            XCTAssertTrue(error.localizedDescription.contains("older lockdown pairing file"))
        }
        let junk = folder.appendingPathComponent("junk.plist")
        try Data("hello".utf8).write(to: junk)
        XCTAssertThrowsError(try DirectInstall.importPairingFile(from: junk)) { error in
            XCTAssertTrue(error.localizedDescription.contains("isn't a pairing file"))
        }
        XCTAssertFalse(DirectInstaller.isRemotePairingFile(lockdown))
        XCTAssertTrue(DirectInstaller.isLockdownPairingFile(lockdown))
    }

    // MARK: - Installer failures

    func testUnreachableAddressFailsQuickly() async {
        let started = Date()
        let reachable = await DirectInstaller.isReachable(address: "127.0.0.1", port: 49152, timeout: 2)
        XCTAssertFalse(reachable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testConnectWithoutAPairingFileIsAnError() {
        let installer = DirectInstaller(pairingFileURL: URL(fileURLWithPath: "/nonexistent"), address: "127.0.0.1")
        XCTAssertThrowsError(try installer.connect(port: 49152)) { error in
            XCTAssertEqual((error as? DirectInstaller.Failure)?.stage, .pairingFile)
        }
    }

    func testStagesNeedAConnection() throws {
        let installer = DirectInstaller(pairingFileURL: URL(fileURLWithPath: "/nonexistent"), address: "127.0.0.1")
        XCTAssertThrowsError(try installer.upload(URL(fileURLWithPath: "/dev/null")) { _ in })
        XCTAssertThrowsError(try installer.install(remotePath: "/PublicStaging/signet-1.ipa", bundleID: nil) { _ in })
        XCTAssertEqual(try installer.removeStaged(["/elsewhere/file.ipa"]), [], "only Signet's staged files are touched")
        XCTAssertThrowsError(try installer.removeStaged(["/PublicStaging/signet-1.ipa"]))
    }

    func testPhaseNames() {
        let phases = [5, 15, 20, 30, 40, 50, 60, 70, 80, 90, 100].map(DirectInstaller.phase(forPercent:))
        XCTAssertEqual(Set(phases).count, phases.count)
        XCTAssertEqual(DirectInstaller.phase(forPercent: 0), "Preparing the app…")
        XCTAssertEqual(DirectInstaller.phase(forPercent: 100), "Installed")
    }

    // MARK: - Install manager

    @MainActor
    func testDirectInstallWithoutPairingFileOffersTheServer() async throws {
        guard !DirectInstall.hasPairingFile else { throw XCTSkip("A real pairing file is stored in this simulator.") }
        let fm = FileManager.default
        var app = app(bundleID: "com.example.direct", original: "com.example.direct")
        try fm.createDirectory(at: app.directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: app.directory) }
        try Data("ipa".utf8).write(to: app.ipaURL)
        app.size = 3
        let manager = InstallManager()
        await manager.install(app, method: .direct)
        guard case .failed(let message) = manager.state else { return XCTFail("expected a failure, got \(manager.state)") }
        XCTAssertTrue(message.contains("pairing file"))
        XCTAssertEqual(manager.serverFallback?.id, app.id)
        manager.dismiss()
        XCTAssertNil(manager.serverFallback)
    }

    func testSelfUpdateDetection() {
        let sent = Date(timeIntervalSince1970: 1_000_000)
        let pending = DirectInstall.PendingSelfUpdate(version: "1.1", build: "2", bundlePath: "/containers/A/Signet.app", date: sent)
        // A new container, or the same path with a folder made after the update was sent.
        XCTAssertTrue(pending.wasInstalled(nowAt: "/containers/B/Signet.app", bundleCreated: nil))
        XCTAssertTrue(pending.wasInstalled(nowAt: "/containers/A/Signet.app", bundleCreated: sent.addingTimeInterval(20)))
        // Same place, older folder: nothing was installed.
        XCTAssertFalse(pending.wasInstalled(nowAt: "/containers/A/Signet.app", bundleCreated: sent.addingTimeInterval(-3600)))
        XCTAssertFalse(pending.wasInstalled(nowAt: "/containers/A/Signet.app", bundleCreated: nil))
    }

    @MainActor
    func testPendingSelfUpdateIsReportedOnce() async {
        let manager = InstallManager()
        DirectInstall.pendingSelfUpdate = .init(version: "9.9", build: "1", bundlePath: "/elsewhere/Signet.app", date: Date())
        manager.checkPendingSelfUpdate()
        XCTAssertNil(DirectInstall.pendingSelfUpdate, "reported once")
        try? await Task.sleep(for: .seconds(1)) // the alert is raised after the first screen is up
        XCTAssertTrue(manager.selfUpdateResult?.hasPrefix("Signet updated") ?? false)
        XCTAssertTrue(DirectInstall.selfUpdateTrail.last?.contains("Launch check") ?? false, "the check is logged")

        manager.selfUpdateResult = nil
        DirectInstall.pendingSelfUpdate = .init(version: "9.9", build: "1", bundlePath: Bundle.main.bundlePath,
                                                date: Date().addingTimeInterval(3600))
        manager.checkPendingSelfUpdate()
        try? await Task.sleep(for: .seconds(1))
        XCTAssertTrue(manager.selfUpdateResult?.contains("didn't update") ?? false)
    }

    func testConnectingGivesUpAfterTheTimeLimit() async throws {
        // A real pairing file and a local server that accepts the connection but never answers: the library
        // blocks waiting for the handshake, exactly like an iPhone that stops responding.
        let folder = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(folder) }
        let pairingURL = folder.appendingPathComponent("pairing.plist")
        var pairing: OpaquePointer?
        XCTAssertNil(rp_pairing_file_generate("SignetTests", &pairing))
        XCTAssertNil(rp_pairing_file_write(pairing, pairingURL.path))
        rp_pairing_file_free(pairing)

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 4) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let port = UInt16(bigEndian: address.sin_port)

        let installer = DirectInstaller(pairingFileURL: pairingURL, address: "127.0.0.1")
        let started = Date()
        do {
            _ = try await installer.connect(port: port, timeout: 1)
            XCTFail("a server that never answers can't connect")
        } catch let failure as DirectInstaller.Failure {
            XCTAssertEqual(failure.stage, .tunnel)
            XCTAssertTrue(failure.localizedDescription.contains("didn't answer"), failure.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "gives up at the limit instead of waiting for the library")
    }

    func testFindsLinksThatLeaveTheApp() throws {
        let fm = FileManager.default
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let app = root.appendingPathComponent("A.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("A"))
        try Data().write(to: root.appendingPathComponent("victim"))
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("Frameworks/inside.dylib").path, withDestinationPath: "../A")
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("Frameworks/outside.dylib").path, withDestinationPath: "../../victim")
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("absolute").path, withDestinationPath: "/etc/hosts")
        XCTAssertEqual(Set(AppImporter.escapingSymlinks(in: app)), ["Frameworks/outside.dylib", "absolute"])
    }
}
