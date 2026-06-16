import XCTest
@testable import OpenRingKit

// Auto-reconnect backoff (#35): grows the gap between consecutive failed reconnects so a ring
// left on the charger isn't hammered, and flips to the calm "unreachable" state after a few
// tries. Asserts the schedule + thresholds so a regression (e.g. reverting to immediate retry)
// is caught.
final class ReconnectBackoffTests: XCTestCase {

    func testScheduleGrowsThenCaps() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 1), 1)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 2), 5)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 3), 30)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 4), 30)   // capped
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 99), 30)  // stays capped
    }

    func testZeroOrNegativeAttemptIsImmediate() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: 0), 0)
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: -3), 0)
    }

    func testDelayIsMonotonicNonDecreasing() {
        var prev = ReconnectBackoff.delay(forAttempt: 0)
        for attempt in 1...12 {
            let d = ReconnectBackoff.delay(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(d, prev)
            prev = d
        }
    }

    func testCalmStateOnlyAfterThreshold() {
        XCTAssertFalse(ReconnectBackoff.shouldSurfaceCalmState(attempts: 0))
        XCTAssertFalse(ReconnectBackoff.shouldSurfaceCalmState(attempts: 2))
        XCTAssertTrue(ReconnectBackoff.shouldSurfaceCalmState(attempts: 3))
        XCTAssertTrue(ReconnectBackoff.shouldSurfaceCalmState(attempts: 10))
    }
}
