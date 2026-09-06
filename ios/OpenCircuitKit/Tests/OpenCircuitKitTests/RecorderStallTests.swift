// `RecorderStall.verdict` must never blame the ring for something we did not measure.
//
// The scenario every test here is anchored to is the real one: a Gen 2 Air export whose newest
// 0x4c epoch was 4 h 04 m old at 01:52 local while the ring was connected and skin temperature
// was 12 s fresh, and whose manual sync at 01:52 returned `outcome=empty ack=true 4c=0`.

import XCTest
@testable import OpenCircuitKit

final class RecorderStallTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    /// A ring handing over epochs on the normal 150 s cadence is recording — nothing to say.
    func testFreshHeadIsRecording() {
        XCTAssertEqual(RecorderStall.verdict(newestEpochAt: ago(0.05),
                                             completedDrainsSinceHeadMoved: 9,
                                             isCharging: false, now: now),
                       .recording)
    }

    /// THE HONESTY CASE. Stale head, but we have not drained enough times to know whose fault it
    /// is. Must NOT accuse the ring.
    func testStaleButUndrainedIsNotARingFault() {
        for drains in 0 ..< RecorderStall.minimumUnmovedDrains {
            XCTAssertEqual(RecorderStall.verdict(newestEpochAt: ago(4),
                                                 completedDrainsSinceHeadMoved: drains,
                                                 isCharging: false, now: now),
                           .unknownNotDrained,
                           "\(drains) completed drains cannot prove a stall")
        }
    }

    /// ONE completed-but-empty drain is explicitly not enough: a drain exiting on the end marker
    /// has been observed handing over more epochs on the next open.
    func testOneEmptyDrainIsNotAStall() {
        XCTAssertEqual(RecorderStall.verdict(newestEpochAt: ago(17),
                                             completedDrainsSinceHeadMoved: 1,
                                             isCharging: false, now: now),
                       .unknownNotDrained)
    }

    /// The tester's actual state: 4 h stale, repeatedly drained, connected, not charging.
    func testTheTesterCaseIsCalledAStall() {
        XCTAssertEqual(RecorderStall.verdict(newestEpochAt: ago(4.07),
                                             completedDrainsSinceHeadMoved: 3,
                                             isCharging: false, now: now),
                       .stalled(since: ago(4.07)))
    }

    /// A ring on the charger legitimately records nothing. Charging outranks the drain count, so
    /// a docked ring can never produce a fault message.
    func testChargingIsNeverAFault() {
        XCTAssertEqual(RecorderStall.verdict(newestEpochAt: ago(17),
                                             completedDrainsSinceHeadMoved: 99,
                                             isCharging: true, now: now),
                       .expectedWhileCharging)
    }

    /// No epochs at all is not a stall — it is a ring we have never drained.
    func testNoEpochsIsUnknownNotStalled() {
        XCTAssertEqual(RecorderStall.verdict(newestEpochAt: nil,
                                             completedDrainsSinceHeadMoved: 99,
                                             isCharging: false, now: now),
                       .unknownNotDrained)
    }

    /// The threshold is a real boundary, not an accident: just inside it stays quiet, just outside
    /// it reports. Pins `staleAfter` against a silent retune.
    func testStaleAfterBoundaryHolds() {
        let justFresh = now.addingTimeInterval(-RecorderStall.staleAfter + 1)
        XCTAssertEqual(RecorderStall.verdict(newestEpochAt: justFresh,
                                             completedDrainsSinceHeadMoved: 9,
                                             isCharging: false, now: now),
                       .recording)
        let justStale = now.addingTimeInterval(-RecorderStall.staleAfter)
        XCTAssertEqual(RecorderStall.verdict(newestEpochAt: justStale,
                                             completedDrainsSinceHeadMoved: 9,
                                             isCharging: false, now: now),
                       .stalled(since: justStale))
    }
}
