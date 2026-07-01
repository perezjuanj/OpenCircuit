import XCTest
@testable import OpenCircuitKit

// Step accumulation (#34): the descriptor carries the ring's current-day count, so repeated
// same-day reads must add only the incremental delta while the first read of a new day must
// recover that day's already-accumulated total. These cases pin that behavior without needing
// the live BLE path in test.
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

    func testFirstReadingHasNoBaselineCreditsFullRawCount() {
        // previousRaw == nil (first run / fresh pairing / reinstall): credit the full raw count
        // as today's steps so far, same as a reset — otherwise a fresh pairing silently drops
        // every step already on the ring (the #34 failure mode this type exists to prevent).
        let u = StepAccumulator.update(previousRaw: nil, newRaw: 8000, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 8000)
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
        // A new calendar day always starts from the ring's current-day total. If the raw count
        // also dropped overnight, surface it as a non-anomalous reset for logging only.
        let u = StepAccumulator.update(previousRaw: 9000, newRaw: 50, dayChanged: true)
        XCTAssertEqual(u.deltaToAdd, 50)
        XCTAssertTrue(u.isReset)
        XCTAssertFalse(u.isAnomalousReset)
    }

    func testFirstReadingOnNewDayCreditsFullCurrentDayTotal() {
        // Missing the morning's first few reads must NOT lose those already-taken steps. Even if
        // today's raw has already climbed past yesterday's last reading, the new day earns the
        // full current-day total, not just the difference from yesterday.
        let u = StepAccumulator.update(previousRaw: 2000, newRaw: 3000, dayChanged: true)
        XCTAssertEqual(u.deltaToAdd, 3000)
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
        let sameDay = StepAccumulator.update(previousRaw: 10, newRaw: 20, dayChanged: false)
        XCTAssertFalse(sameDay.isReset)
        XCTAssertFalse(sameDay.isAnomalousReset)

        let newDay = StepAccumulator.update(previousRaw: 10, newRaw: 20, dayChanged: true)
        XCTAssertFalse(newDay.isReset)
        XCTAssertFalse(newDay.isAnomalousReset)
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
