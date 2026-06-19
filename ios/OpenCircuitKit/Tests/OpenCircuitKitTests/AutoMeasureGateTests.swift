import XCTest
@testable import OpenCircuitKit

// Auto-measure wear gate (#56): infers "not worn" from consecutive auto-measures that never
// lock (🟢) plus an optional cold raw skin-temp reading (🟡), and backs the probe interval off
// exponentially so a ring on the charger isn't probed every 10 min. Asserts the inference +
// the backoff schedule so a regression (e.g. reverting to a fixed cadence) is caught. No
// charging-flag byte is consulted (undecoded — #61).
final class AutoMeasureGateTests: XCTestCase {

    // MARK: not-worn inference

    func testWornUntilThresholdWithoutTemperature() {
        XCTAssertFalse(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 0))
        XCTAssertFalse(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 1),
                       "one transient miss (e.g. a moving hand) is not yet not-worn")
        XCTAssertTrue(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 2))
        XCTAssertTrue(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 9))
    }

    func testWarmSkinTempIsAlwaysWorn() {
        // A warm reading is direct evidence of wear even after many missed locks.
        XCTAssertFalse(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 9, rawSkinTempC: 32))
        XCTAssertFalse(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 0, rawSkinTempC: 30))
    }

    func testColdSkinTempConfirmsNotWornAfterOneMiss() {
        // Cold alone (no miss yet) is NOT enough — a worn-but-cool ring would have locked.
        XCTAssertFalse(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 0, rawSkinTempC: 22),
                       "cold reading with no failed lock is not conclusive")
        XCTAssertTrue(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 1, rawSkinTempC: 22),
                      "cold + a missed lock ⇒ not worn")
    }

    func testThresholdBoundaryMatchesWornMinTemperature() {
        let worn = ActivityPeriod.wornMinTemperatureC   // 28 °C
        XCTAssertFalse(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 1, rawSkinTempC: worn),
                       "exactly at the worn threshold counts as worn")
        XCTAssertTrue(AutoMeasureGate.appearsNotWorn(consecutiveNoLock: 1, rawSkinTempC: worn - 0.1))
    }

    // MARK: backoff schedule

    private let base: TimeInterval = 600     // 10 min
    private let cap: TimeInterval = 7200     // 2 h

    func testIntervalStaysAtBaseWhileWorn() {
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 0), base)
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 1), base,
                       "a single miss without temp evidence does not back off yet")
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 9, rawSkinTempC: 33),
                       base, "warm skin ⇒ keep the normal cadence")
    }

    func testIntervalDoublesOnceNotWornThenCaps() {
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 2), 1200) // ×2
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 3), 2400) // ×4
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 4), 4800) // ×8
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 5), cap,  // ×16 → cap 7200
                       "base ×16 = 9600 is clamped to the 2 h cap")
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 99), cap,
                       "stays capped")
    }

    func testColdTempBacksOffFromTheFirstConfirmedMiss() {
        // Cold + 1 miss is not-worn, but the first backed-off interval is still `base`
        // (0 doublings) — it ramps from there.
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 1, rawSkinTempC: 21), base)
        XCTAssertEqual(AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 2, rawSkinTempC: 21), 1200)
    }

    func testIntervalIsMonotonicNonDecreasing() {
        var prev = AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: 0)
        for n in 1...12 {
            let v = AutoMeasureGate.interval(base: base, cap: cap, consecutiveNoLock: n)
            XCTAssertGreaterThanOrEqual(v, prev)
            prev = v
        }
    }
}
