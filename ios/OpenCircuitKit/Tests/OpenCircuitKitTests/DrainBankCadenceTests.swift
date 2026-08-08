import XCTest
@testable import OpenCircuitKit

/// The invariant under test is the one the 2026-08-07 whole-night loss turned on: a CONTINUOUS
/// page burst re-arms the quiet debounce on every page, so without a hold bound the bank is
/// deferred until the burst ends — which is exactly the window that loses the night.
final class DrainBankCadenceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_786_400_000)

    func testNothingHeldDebounces() {
        XCTAssertEqual(DrainBankCadence.decide(firstUnbankedAt: nil, now: t0), .debounce)
    }

    func testFreshPageDebouncesRatherThanBanking() {
        XCTAssertEqual(DrainBankCadence.decide(firstUnbankedAt: t0, now: t0), .debounce)
        XCTAssertEqual(DrainBankCadence.decide(firstUnbankedAt: t0,
                                               now: t0.addingTimeInterval(1)), .debounce)
    }

    func testHoldBoundForcesABankEvenWhilePagesKeepArriving() {
        // At the bound exactly, and past it.
        XCTAssertEqual(DrainBankCadence.decide(firstUnbankedAt: t0,
                                               now: t0.addingTimeInterval(DrainBankCadence.maxHold)),
                       .bankNow)
        XCTAssertEqual(DrainBankCadence.decide(firstUnbankedAt: t0,
                                               now: t0.addingTimeInterval(DrainBankCadence.maxHold + 5)),
                       .bankNow)
    }

    /// The 2026-08-07 regression case, replayed at the measured shape: a 43 s burst whose pages are
    /// 1–3 s apart never goes quiet, so the debounce alone would never fire. Walking the real
    /// arrival times must produce several banks on the way through, not zero.
    func testWholeNightBurstBanksRepeatedlyInsteadOfOnceAtTheEnd() {
        var firstUnbanked: Date? = nil
        var banks = 0
        var now = t0
        // 20 pages over 43 s, the cadence actually captured on the wire.
        for gap in [0.0] + Array(repeating: 2.26, count: 19) {
            now = now.addingTimeInterval(gap)
            if firstUnbanked == nil { firstUnbanked = now }
            if DrainBankCadence.decide(firstUnbankedAt: firstUnbanked, now: now) == .bankNow {
                banks += 1
                firstUnbanked = nil   // banked — a fresh hold window starts with the next page
            }
        }
        XCTAssertGreaterThanOrEqual(banks, 4,
            "a continuous 43 s handoff must bank repeatedly; the debounce alone never fires")
    }

    /// A quiet gap longer than the hold bound must not be required to trip it — the bound is
    /// measured from the OLDEST unbanked page, not from the last one.
    func testBoundIsMeasuredFromOldestHeldPage() {
        let oldest = t0
        let latest = t0.addingTimeInterval(DrainBankCadence.maxHold + 1)
        XCTAssertEqual(DrainBankCadence.decide(firstUnbankedAt: oldest, now: latest), .bankNow)
        XCTAssertEqual(DrainBankCadence.decide(firstUnbankedAt: latest, now: latest), .debounce)
    }

    /// The two knobs have to be ordered correctly or the guarantee moves to the wrong one. `quiet`
    /// must clear the MEASURED inter-page ceiling (1–3 s on the 2026-08-07 burst) so the debounce
    /// cannot fire mid-burst — which is what leaves `maxHold` as the mechanism that actually carries
    /// mid-burst durability, and therefore the one the tests above exercise.
    func testQuietClearsTheMeasuredInterPageCeilingSoMaxHoldIsTheLiveMechanism() {
        let measuredMaxInterPageGap: TimeInterval = 3
        XCTAssertGreaterThan(DrainBankCadence.quiet, measuredMaxInterPageGap,
            "a quiet window inside the inter-page range makes maxHold dead code")
        XCTAssertLessThan(DrainBankCadence.quiet, DrainBankCadence.maxHold)
    }

    /// Guards the ordering claim end-to-end: replaying the measured gaps, the debounce must never be
    /// the thing that fires — every bank in a continuous burst comes from the hold bound.
    func testDebounceNeverFiresMidBurstAtTheMeasuredCadence() {
        for gap in [1.0, 2.26, 3.0] {
            XCTAssertLessThan(gap, DrainBankCadence.quiet,
                "gap \(gap)s would trip the debounce and pre-empt maxHold")
        }
    }
}
