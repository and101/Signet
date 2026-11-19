import XCTest
@testable import Signet

/// Direct install without an iPhone: settings, the self-update rules, pairing-file checks, and failures coming
/// back as errors rather than crashes or hangs.
final class DirectInstallTests: XCTestCase {
    private var savedDefaults: [String: Any?] = [:]
    private let keys = [DirectInstall.methodKey, DirectInstall.addressKey, DirectInstall.portKey,
                        "directInstallDiscoveredPort", "directInstallStagedPaths", "directInstallPendingSelfUpdate"]

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
        DirectInstall.pendingSelfUpdate = .init(version: "1.1", build: "7", bundlePath: "/a")
        XCTAssertEqual(DirectInstall.pendingSelfUpdate, .init(version: "1.1", build: "7", bundlePath: "/a"))
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

    func testSelfUpdateNeedsANewBundleContainer() {
        // Reinstalling the same build still moves Signet to a new container; staying put means nothing installed.
        let pending = DirectInstall.PendingSelfUpdate(version: "1.1", build: "2", bundlePath: "/containers/A/Signet.app")
        XCTAssertTrue(pending.wasInstalled(nowAt: "/containers/B/Signet.app"))
        XCTAssertFalse(pending.wasInstalled(nowAt: "/containers/A/Signet.app"))
    }

    @MainActor
    func testPendingSelfUpdateIsReportedOnce() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let manager = InstallManager()
        DirectInstall.pendingSelfUpdate = .init(version: "9.9", build: build, bundlePath: "/elsewhere/Signet.app")
        manager.checkPendingSelfUpdate()
        XCTAssertNotNil(manager.selfUpdateResult)
        XCTAssertTrue(manager.selfUpdateResult?.hasPrefix("Signet updated") ?? false)
        XCTAssertNil(DirectInstall.pendingSelfUpdate)

        manager.selfUpdateResult = nil
        DirectInstall.pendingSelfUpdate = .init(version: "9.9", build: build, bundlePath: Bundle.main.bundlePath)
        manager.checkPendingSelfUpdate()
        XCTAssertTrue(manager.selfUpdateResult?.contains("didn't update") ?? false)
    }
}
