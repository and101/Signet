import XCTest
@testable import Signet

final class ActivityLogTests: XCTestCase {
    func testTracksLatestStepAndOutcome() {
        var log = ActivityLog()
        XCTAssertEqual(log.outcome, .idle)
        XCTAssertTrue(log.isEmpty)
        log.start()
        log.append("Copying…")
        log.append("Signing…")
        XCTAssertEqual(log.outcome, .running)
        XCTAssertEqual(log.latest, "Signing…")
        log.finish(.failed, "Signing failed.")
        XCTAssertEqual(log.outcome, .failed)
        XCTAssertEqual(log.latest, "Signing failed.")
        XCTAssertEqual(log.entries.map(\.id), [0, 1, 2])
        XCTAssertEqual(log.text.split(separator: "\n").count, 3)
        XCTAssertTrue(log.text.hasSuffix("Signing failed."))
    }

    func testStartClearsTheLastRun() {
        var log = ActivityLog()
        log.start()
        log.append("Old")
        log.finish(.succeeded)
        log.start()
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.outcome, .running)
    }
}
