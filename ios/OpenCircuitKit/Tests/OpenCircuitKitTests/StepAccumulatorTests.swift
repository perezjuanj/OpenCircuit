import XCTest
@testable import OpenCircuitKit

// Step accumulation (#34; premise re-derived in #192).
//
// The descriptor's `[4:6]` field is a QUARTER-HOUR BUCKET — steps since the last :00/:15/:30/:45,
// cleared at each boundary (🟢 measured over 10,327 descriptor frames from two rings: 268 drops,
// every one at a wall-clock quarter boundary; max value ever observed 746 against 2,611–4,566-step
// days). These cases pin the fold that turns that into a daily total, and — just as importantly —
// pin the two "obvious" fixes that the corpus says are WRONG:
//   * crediting the raw value in full whenever the wall clock crosses a boundary (+4.9 % OVER),
//   * the same with a lag margin (+8.2 % OVER),
// both of which double-count the ring's ≤108 s clear lag. The fold's own residual is the other
// way and much smaller (1.3 % under). Steps have no ring-side backlog, so an over-count is exactly
// as permanent as an under-count.
final class StepAccumulatorTests: XCTestCase {

    // MARK: - The fold

    func testClimbWithinABucketCountsOnlyTheIncrement() {
        // The keepalive re-reads the descriptor every ~30–60 s. While the bucket climbs, only the
        // newly-taken steps are new.
        let u = StepAccumulator.update(previousRaw: 100, newRaw: 150, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 50)
        XCTAssertFalse(u.isReset)
    }

    func testFlatBucketAddsNothing() {
        // Same raw counter twice in a row must add 0 — otherwise every keepalive poll re-credits
        // the whole bucket.
        let u = StepAccumulator.update(previousRaw: 4321, newRaw: 4321, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 0)
        XCTAssertFalse(u.isReset)
    }

    func testBucketRollCreditsTheNewBucketWhole() {
        // Real shape, 2026-08-08 18:28:30 → 18:32:48 on `RingConn Gen2-03AD`: the 18:15 bucket
        // closed at 83 and the 18:30 bucket was already at 58. 58 is a NEW quarter's steps, not a
        // continuation, so it is credited whole. This is the ORDINARY case (~24×/day measured) —
        // it is what makes the fold "sum the observed buckets".
        let u = StepAccumulator.update(previousRaw: 83, newRaw: 58, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 58)
        XCTAssertTrue(u.isReset)
    }

    func testRollToZeroCreditsNothing() {
        // The most common roll of all: the next bucket has not started counting yet.
        // 2026-08-08 17:14:52 (98) → 17:16:41 (0).
        let u = StepAccumulator.update(previousRaw: 98, newRaw: 0, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 0)
        XCTAssertTrue(u.isReset)
    }

    func testFirstReadingHasNoBaselineCreditsTheBucketSoFar() {
        // previousRaw == nil (first run / fresh pairing / reinstall): credit the bucket we
        // connected in. Crediting 0 would drop the steps already counted in that quarter.
        let u = StepAccumulator.update(previousRaw: nil, newRaw: 800, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 800)
        XCTAssertFalse(u.isReset)
    }

    func testDayRolloverCreditsTheBucketWholeEvenWhenTheRawClimbed() {
        // Across midnight the two readings are certainly in different buckets, so the new value is
        // a fresh bucket and is credited whole — never `newRaw - previousRaw`.
        let u = StepAccumulator.update(previousRaw: 200, newRaw: 300, dayChanged: true)
        XCTAssertEqual(u.deltaToAdd, 300)
        XCTAssertFalse(u.isReset)
    }

    func testDayRolloverWithADropIsStillJustARoll() {
        let u = StepAccumulator.update(previousRaw: 900, newRaw: 50, dayChanged: true)
        XCTAssertEqual(u.deltaToAdd, 50)
        XCTAssertTrue(u.isReset)
    }

    func testWraparoundIsIndistinguishableFromABucketRoll() {
        // The counter is 16-bit (DeviceStatus.steps, max 65535). A wrap, a reboot and a bucket
        // roll all present as a drop and are all handled the same way: count the new value.
        let u = StepAccumulator.update(previousRaw: 65500, newRaw: 30, dayChanged: false)
        XCTAssertEqual(u.deltaToAdd, 30)
        XCTAssertTrue(u.isReset)
    }

    func testResetFlagIsNeverSetOnAClimb() {
        XCTAssertFalse(StepAccumulator.update(previousRaw: 10, newRaw: 20, dayChanged: false).isReset)
        XCTAssertFalse(StepAccumulator.update(previousRaw: 10, newRaw: 20, dayChanged: true).isReset)
    }

    func testDeltaIsNeverNegative() {
        for previous in [0, 1, 97, 746, 65535] {
            for new in [0, 1, 97, 746, 65535] {
                for dayChanged in [false, true] {
                    let u = StepAccumulator.update(previousRaw: previous, newRaw: new, dayChanged: dayChanged)
                    XCTAssertGreaterThanOrEqual(u.deltaToAdd, 0, "\(previous)→\(new) day=\(dayChanged)")
                    XCTAssertLessThanOrEqual(u.deltaToAdd, max(new, new - previous))
                }
            }
        }
    }

    // MARK: - The fold over a REAL captured bucket series

    /// Verbatim `[4:6]` values from `opencircuit-diagnostics-2026-08-09T14-06-14Z.txt`
    /// (`RingConn Gen2-03AD`, FR02.018), 2026-08-08 16:54:09 → 17:29:53 local. Three buckets:
    /// 16:45 climbs to 98, 17:00 (the boundary the ring crossed without a visible drop) and 17:15.
    private static let realSeries0808: [Int] = [
        11, 18, 18, 18, 37, 58,          // 16:45 bucket
        63, 70, 70, 70, 70, 70, 78, 78, 78, 98, 98, 98, 98, 98, 98,   // 17:00 bucket
        0, 0, 0, 0, 0, 9, 9, 9, 9, 9, 9, 9,                            // 17:15 bucket
    ]

    func testFoldOverARealCapturedSeriesSumsTheObservedBuckets() {
        var previous: Int?
        var total = 0
        for raw in Self.realSeries0808 {
            total += StepAccumulator.update(previousRaw: previous, newRaw: raw, dayChanged: false).deltaToAdd
            previous = raw
        }
        // 98 (the merged 16:45+17:00 run, which is the measured 1.3 % under-count: the 17:00
        // boundary passed without a visible drop, so the 16:45 bucket's 58 is absorbed) + 9.
        XCTAssertEqual(total, 107)
        // What the two rejected "fixes" would have produced on this same series is strictly more,
        // and this is the exact shape that makes them over-count: 58 would be credited twice.
        XCTAssertLessThan(total, 107 + 58)
    }

    func testARolledBucketIsNeverCreditedTwice() {
        // The invariant that keeps the fold honest: over a monotone-then-rolled series, the credit
        // for the whole run can never exceed the sum of the values the ring actually reported at
        // its bucket ends.
        let series = [0, 40, 90, 0, 25, 25, 12]     // roll at index 3, and a late roll at index 6
        var previous: Int?
        var total = 0
        for raw in series {
            total += StepAccumulator.update(previousRaw: previous, newRaw: raw, dayChanged: false).deltaToAdd
            previous = raw
        }
        XCTAssertEqual(total, 90 + 25 + 12)
    }

    func testSummingDeltasReconstructsASessionOfBuckets() {
        let readings: [(prev: Int?, raw: Int)] = [
            (nil, 0),      // baseline, empty bucket
            (0, 400),      // +400
            (400, 1200),   // +800  → this bucket closes at 1200
            (1200, 0),     // roll
            (0, 300),      // +300
            (300, 800),    // +500  → closes at 800
        ]
        var total = 0
        for r in readings {
            total += StepAccumulator.update(previousRaw: r.prev, newRaw: r.raw, dayChanged: false).deltaToAdd
        }
        XCTAssertEqual(total, 2000)
    }

    // MARK: - Bucket boundaries

    private func date(_ hhmmss: String, tz: String = "America/New_York") -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: tz)!
        return f.date(from: "2026-08-08 " + hhmmss)!
    }

    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    func testBucketStartFloorsToTheQuarterHour() {
        let cal = calendar("America/New_York")
        XCTAssertEqual(StepAccumulator.bucketStart(for: date("17:14:52"), calendar: cal), date("17:00:00"))
        XCTAssertEqual(StepAccumulator.bucketStart(for: date("17:16:41"), calendar: cal), date("17:15:00"))
        XCTAssertEqual(StepAccumulator.bucketStart(for: date("00:00:00"), calendar: cal), date("00:00:00"))
        XCTAssertEqual(StepAccumulator.bucketStart(for: date("23:59:59"), calendar: cal), date("23:45:00"))
    }

    func testBucketStartIsCorrectInAHalfHourOffsetZone() {
        // Asia/Kolkata is UTC+05:30, so flooring the UNIX epoch to 900 s would land 30 min off.
        // The ring's quarter is a LOCAL wall-clock quarter, so this must floor to :15 local.
        let cal = calendar("Asia/Kolkata")
        let t = date("17:22:03", tz: "Asia/Kolkata")
        XCTAssertEqual(StepAccumulator.bucketStart(for: t, calendar: cal), date("17:15:00", tz: "Asia/Kolkata"))
    }

    func testBucketStartIsAWallClockFloorNotAnEpochFloor() {
        // Every UTC offset in use today is a whole multiple of 15 min, so flooring the UNIX epoch
        // to 900 s happens to agree with the local wall clock everywhere — which makes that shortcut
        // untestable against a real zone, and quietly wrong for any offset that is not (pre-1972
        // zones ran on odd LMT offsets, and a Calendar can be handed any zone at all). Pin the
        // wall-clock reading with a synthetic +05:40 offset, where an epoch floor lands at :10.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 5 * 3600 + 40 * 60)!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = cal.timeZone
        let sample = f.date(from: "2026-08-08 17:22:03")!
        XCTAssertEqual(StepAccumulator.bucketStart(for: sample, calendar: cal),
                       f.date(from: "2026-08-08 17:15:00")!)
    }

    func testBucketLengthIsFifteenMinutes() {
        XCTAssertEqual(StepAccumulator.bucketSeconds, 900)
    }

    // MARK: - The HealthKit window

    func testWindowStartUsesThePreviousReadingWhenItIsInsideTheBucket() {
        // The steady case: descriptors ~1.8 min apart inside one bucket. Nothing to clamp.
        let cal = calendar("America/New_York")
        let start = StepAccumulator.windowStart(sampleDate: date("17:12:22"),
                                                previousSampleAt: date("17:11:41"),
                                                dayStart: date("00:00:00"),
                                                calendar: cal)
        XCTAssertEqual(start, date("17:11:41"))
    }

    func testWindowStartFloorsAStalePreviousReadingToTheBucket() {
        // A reconnect after a 3-hour gap used to stamp the window at the LAST reading, claiming a
        // bucket's steps were spread over three hours of Apple Health.
        let cal = calendar("America/New_York")
        let start = StepAccumulator.windowStart(sampleDate: date("17:40:00"),
                                                previousSampleAt: date("14:31:00"),
                                                dayStart: date("00:00:00"),
                                                calendar: cal)
        XCTAssertEqual(start, date("17:30:00"))
    }

    func testWindowStartOnTheDaysFirstReadingIsTheBucketNotMidnight() {
        // Measured on the corpus: 07-06 21:43:32 credited 48 steps with a window starting at local
        // midnight — a 21.7-hour Health sample for a quarter-hour of walking.
        let cal = calendar("America/New_York")
        let start = StepAccumulator.windowStart(sampleDate: date("21:43:32"),
                                                previousSampleAt: nil,
                                                dayStart: date("00:00:00"),
                                                calendar: cal)
        XCTAssertEqual(start, date("21:30:00"))
    }

    func testWindowStartAllowsForTheRingsClearLag() {
        // A frame arriving 41 s after a boundary can still be carrying the PREVIOUS bucket
        // (measured lag up to 108 s), so the window is allowed to reach back one bucket.
        let cal = calendar("America/New_York")
        let start = StepAccumulator.windowStart(sampleDate: date("17:15:41"),
                                                previousSampleAt: nil,
                                                dayStart: date("00:00:00"),
                                                calendar: cal)
        XCTAssertEqual(start, date("17:00:00"))
        // Well clear of the lag window, it does NOT reach back.
        let settled = StepAccumulator.windowStart(sampleDate: date("17:20:00"),
                                                  previousSampleAt: nil,
                                                  dayStart: date("00:00:00"),
                                                  calendar: cal)
        XCTAssertEqual(settled, date("17:15:00"))
    }

    func testWindowStartNeverCrossesMidnight() {
        // Just after midnight the lag allowance would reach into yesterday; the day clamp keeps
        // the sample on its own day's row.
        let cal = calendar("America/New_York")
        let start = StepAccumulator.windowStart(sampleDate: date("00:01:00"),
                                                previousSampleAt: nil,
                                                dayStart: date("00:00:00"),
                                                calendar: cal)
        XCTAssertEqual(start, date("00:00:00"))
    }

    func testWindowStartRejectsAPreviousReadingFromTheFuture() {
        // A stale/cross-session timestamp must never produce an inverted window.
        let cal = calendar("America/New_York")
        let start = StepAccumulator.windowStart(sampleDate: date("17:20:00"),
                                                previousSampleAt: date("18:00:00"),
                                                dayStart: date("00:00:00"),
                                                calendar: cal)
        XCTAssertEqual(start, date("17:15:00"))
        XCTAssertLessThanOrEqual(start, date("17:20:00"))
    }

    func testWindowStartIsAlwaysWithinTheDayAndNotAfterTheSample() {
        let cal = calendar("America/New_York")
        let sample = date("13:07:09")
        for previous in [nil, date("00:00:00"), date("12:00:00"), date("13:07:09"), date("23:00:00")] as [Date?] {
            let start = StepAccumulator.windowStart(sampleDate: sample,
                                                    previousSampleAt: previous,
                                                    dayStart: date("00:00:00"),
                                                    calendar: cal)
            XCTAssertGreaterThanOrEqual(start, date("00:00:00"))
            XCTAssertLessThanOrEqual(start, sample)
        }
    }
}
