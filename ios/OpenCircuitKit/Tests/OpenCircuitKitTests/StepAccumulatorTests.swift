import XCTest
@testable import OpenCircuitKit

// Step accumulation (#34): fold the ring's since-handoff raw counter into per-day deltas,
// reset-aware and midnight-aware. These cases pin the behavior the live BLE path can't
// easily test: a normal climb, the no-baseline first reading, a mid-day reset/handoff vs the
// expected midnight reset, a 16-bit wraparound, and "no movement" (which must NOT double-count).
final class StepAccumulatorTests: XCTestCase {

    func testClimbCountsTheDelta() {
        let u = StepAccumulator.update(previousRaw: 100, newRaw: 150, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 50)
        XCTAssertFalse(u.isReset)
        XCTAssertFalse(u.isAnomalousReset)
    }

    func testNoMovementAddsNothing() {
        // Same raw counter twice in a row must add 0 — the keepalive re-reads the descriptor
        // every cycle, so a flat counter must not keep crediting steps.
        let u = StepAccumulator.update(previousRaw: 4321, newRaw: 4321, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 0)
        XCTAssertFalse(u.isReset)
    }

    func testFirstReadingHasNoBaselineAndCountsNothing() {
        // previousRaw == nil: we can't tell how many raw steps predate us, so adopt the reading
        // as the baseline and count none (don't retro-count someone else's steps onto today).
        let u = StepAccumulator.update(previousRaw: nil, newRaw: 8000, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 0)
        XCTAssertFalse(u.isReset)
        XCTAssertFalse(u.isAnomalousReset)
    }

    func testMidDayResetCountsNewValueAndFlagsAnomaly() {
        // Counter dropped within the same day (official app took over / ring rebooted): the new
        // value is the post-reset count, and it's surfaced as anomalous so the caller can log it.
        let u = StepAccumulator.update(previousRaw: 5000, newRaw: 120, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 120)
        XCTAssertTrue(u.isReset)
        XCTAssertTrue(u.isAnomalousReset)
    }

    func testMidnightResetCountsNewValueButIsNotAnomalous() {
        // A drop across midnight is the official app's normal daily reset — still a reset (add
        // the new value to the new day), but NOT anomalous.
        let u = StepAccumulator.update(previousRaw: 9000, newRaw: 50, dayChanged: true)
        XCTAssertEqual(u.deltaToAdd, 50)
        XCTAssertTrue(u.isReset)
        XCTAssertFalse(u.isAnomalousReset)
    }

    func testMidnightClimbCreditsIncrementalDeltaToNewDay() {
        // Official app NOT running: the ring's counter keeps climbing across midnight. The
        // incremental delta (not the whole counter) is what the new day earns — anything else
        // would bleed the prior day's accumulated baseline into the new day.
        let u = StepAccumulator.update(previousRaw: 9000, newRaw: 9100, dayChanged: true)
        XCTAssertEqual(u.deltaToAdd, 100)
        XCTAssertFalse(u.isReset)
        XCTAssertFalse(u.isAnomalousReset)
    }

    func testWraparoundIsTreatedAsAReset() {
        // The counter is 16-bit (DeviceStatus.steps, max 65535). A wrap near the top reads as a
        // drop and is treated as a reset (count the wrapped value) — indistinguishable from a
        // real reset without more data, and a 65k-step handoff window is implausible anyway.
        let u = StepAccumulator.update(previousRaw: 65500, newRaw: 30, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 30)
        XCTAssertTrue(u.isReset)
    }

    func testResetFlagIsNeverSetOnAClimb() {
        // isAnomalousReset must only ever be true alongside isReset.
        for dayChanged in [true, false] {
            let u = StepAccumulator.update(previousRaw: 10, newRaw: 20, dayChanged: dayChanged)
            XCTAssertFalse(u.isReset)
            XCTAssertFalse(u.isAnomalousReset)
        }
    }

    func testSummingDeltasReconstructsADayOfSteps() {
        // End-to-end fold: a session's worth of readings (a climb, a mid-day reset, more climb)
        // should sum to the steps actually taken: 0→1200, reset, 0→800 = 2000.
        let readings: [(prev: Int?, raw: Int)] = [
            (nil, 0),      // baseline
            (0, 400),      // +400
            (400, 1200),   // +800
            (1200, 0),     // reset (official app handed off) — counter back to 0
            (0, 300),      // +300
            (300, 800),    // +500
        ]
        var total = 0
        for r in readings {
            total += StepAccumulator.update(previousRaw: r.prev, newRaw: r.raw, dayChanged: false).deltaToAdd
        }
        XCTAssertEqual(total, 400 + 800 + 0 + 300 + 500)   // 2000
    }
}
