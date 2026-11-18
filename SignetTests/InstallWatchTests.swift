import XCTest
@testable import Signet

final class InstallWatchTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testReportsProgressThenInstalledWhenItDisappears() {
        var watch = InstallWatch(started: start)
        XCTAssertEqual(watch.step(progress: nil, now: at(1)), .installing(nil), "iOS hasn't started yet")
        XCTAssertEqual(watch.step(progress: 0.3, now: at(2)), .installing(0.3))
        XCTAssertEqual(watch.step(progress: 0.8, now: at(3)), .installing(0.8))
        XCTAssertEqual(watch.step(progress: nil, now: at(4)), .installed)
    }

    func testCompleteProgressCountsAsInstalled() {
        var watch = InstallWatch(started: start)
        XCTAssertEqual(watch.step(progress: 1, now: at(1)), .installed)
    }

    func testUnknownIfIOSNeverReportsProgress() {
        var watch = InstallWatch(started: start)
        XCTAssertEqual(watch.step(progress: nil, now: at(InstallWatch.startTimeout - 1)), .installing(nil))
        XCTAssertEqual(watch.step(progress: nil, now: at(InstallWatch.startTimeout + 1)), .unknown)
    }

    func testUnknownIfInstallTakesTooLong() {
        var watch = InstallWatch(started: start)
        XCTAssertEqual(watch.step(progress: 0.5, now: at(10)), .installing(0.5))
        XCTAssertEqual(watch.step(progress: 0.5, now: at(InstallWatch.overallTimeout + 1)), .unknown)
    }

    func testProgressCallsAreSafeInTheSimulator() {
        // Whatever this iOS offers, asking about an app that isn't installing must not crash.
        _ = InstallProgress.isAvailable
        XCTAssertNil(InstallProgress.fraction(for: "com.example.not-installing.\(UUID().uuidString)"))
    }

    func testConfirmedOnlyWithEvidence() {
        // A new app appears, or an update changes the build: confirmed.
        XCTAssertTrue(InstallWatch.confirmed(before: .some(nil), after: .some("42"), expected: "42"))
        XCTAssertTrue(InstallWatch.confirmed(before: .some("41"), after: .some("42"), expected: "42"))
        // The old build is still there, or nothing was installed: the install failed or can't be told apart.
        XCTAssertFalse(InstallWatch.confirmed(before: .some("41"), after: .some("41"), expected: "42"))
        XCTAssertFalse(InstallWatch.confirmed(before: .some(nil), after: .some(nil), expected: "42"))
        // Reinstalling the same build looks the same whether or not it worked.
        XCTAssertFalse(InstallWatch.confirmed(before: .some("42"), after: .some("42"), expected: "42"))
        // iOS hides installed apps.
        XCTAssertFalse(InstallWatch.confirmed(before: nil, after: .some("42"), expected: "42"))
        XCTAssertFalse(InstallWatch.confirmed(before: .some(nil), after: nil, expected: "42"))
    }
}
