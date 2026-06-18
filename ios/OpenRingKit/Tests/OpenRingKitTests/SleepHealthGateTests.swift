import XCTest
@testable import OpenRingKit

final class SleepHealthGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNilNeverSettled() {
        XCTAssertFalse(SleepHealthGate.isSettled(latestSegmentEnd: nil, now: now))
    }

    func testInProgressNightNotSettled() {
        // Last epoch 3 min ago — still asleep / block could grow.
        let end = now.addingTimeInterval(-3 * 60)
        XCTAssertFalse(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }

    func testFinishedNightSettled() {
        // Woke 40 min ago — block won't grow.
        let end = now.addingTimeInterval(-40 * 60)
        XCTAssertTrue(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }

    func testExactlyAtMarginIsSettled() {
        let end = now.addingTimeInterval(-SleepHealthGate.settleMargin)
        XCTAssertTrue(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }

    func testJustInsideMarginNotSettled() {
        let end = now.addingTimeInterval(-SleepHealthGate.settleMargin + 1)
        XCTAssertFalse(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }
}
