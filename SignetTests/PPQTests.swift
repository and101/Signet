import XCTest
@testable import Signet

final class PPQTests: XCTestCase {
    private func record(_ pattern: String, ppq: Bool?) -> CertificateRecord {
        var cert = CertificateRecord(
            nickname: "", certificateName: "", teamName: "", teamID: "TEAM", profileName: "",
            applicationIdentifier: "TEAM.\(pattern)", creationDate: .now, expirationDate: .distantFuture,
            provisionsAllDevices: false, entitlements: [:])
        cert.ppqCheck = ppq
        return cert
    }

    private var options: SigningOptions {
        var options = SigningOptions()
        options.ppqSuffix = "k3x9qa"
        return options
    }

    func testPPQProfilesGetTheSuffix() {
        XCTAssertEqual(record("*", ppq: true).bundleID(for: "com.google.ios.youtube", options: options),
                       "com.google.ios.youtube.k3x9qa")
        XCTAssertEqual(record("app.example.only", ppq: true).bundleID(for: "com.google.ios.youtube", options: options),
                       "com.google.ios.youtube.k3x9qa", "exact App ID profiles keep the app's ID, plus the suffix")
        XCTAssertEqual(record("com.example.*", ppq: true).bundleID(for: "org.app", options: options),
                       "com.example.org.app.k3x9qa", "namespaced first, then suffixed")
        XCTAssertNil(record("*", ppq: true).bundleID(for: "com.app.k3x9qa", options: options), "never added twice")
    }

    func testNoSuffixWithoutPPQOrWhenTurnedOff() {
        XCTAssertNil(record("*", ppq: false).bundleID(for: "com.app", options: options))
        XCTAssertNil(record("*", ppq: nil).bundleID(for: "com.app", options: options))
        var off = options
        off.ppqProtection = false
        XCTAssertNil(record("*", ppq: true).bundleID(for: "com.app", options: off))
        var noSuffix = options
        noSuffix.ppqSuffix = ""
        XCTAssertNil(record("*", ppq: true).bundleID(for: "com.app", options: noSuffix))
    }

    func testProfileFlagIsRead() throws {
        let url = try Paths.newTempDirectory().appendingPathComponent("ppq.mobileprovision")
        defer { Paths.removeIfTemporary(url) }
        let plist: [String: Any] = ["Name": "PPQ", "TeamIdentifier": ["TEAM"], "PPQCheck": true,
                                    "Entitlements": ["application-identifier": "TEAM.*"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        XCTAssertTrue(try ProvisioningProfile(url: url).ppqCheck)
    }

    func testSuffixIsCreatedOnceAndSurvivesReset() {
        let key = "defaultSigningOptions"
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let suffix = SigningOptions.defaults.ppqSuffix
        XCTAssertEqual(suffix.count, 6)
        XCTAssertTrue(suffix.first!.isLetter)
        XCTAssertEqual(SigningOptions.defaults.ppqSuffix, suffix, "stable between reads")

        SigningOptions.defaults = SigningOptions() // e.g. "Reset to Defaults" without a suffix
        XCTAssertEqual(SigningOptions.defaults.ppqSuffix, suffix, "a reset keeps the suffix")
    }
}
