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
}
