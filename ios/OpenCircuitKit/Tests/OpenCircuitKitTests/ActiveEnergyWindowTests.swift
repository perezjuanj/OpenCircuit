import XCTest
@testable import OpenCircuitKit

/// Locks the clamps in `ActiveEnergyWindow.resolve`. Each of these is a way the naive
/// "[last flush, now]" window silently corrupts Apple Health — several of them permanently,
/// since `flushActiveCalories` never backfills a past day.
final class ActiveEnergyWindowTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_785_000_000)   // some start-of-day
    private func t(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    // MARK: The reported bug

    func testFirstFlushOfDayStartsAtWakeNotMidnight() {
        // The tester's exact shape: overnight-quiet suppresses drains, so the day's first flush is
        // the ~09:00 wake catch-up. Without `notBefore` this would be [00:00, 09:00] and Health
        // would still paint active energy across the night — "300 calories at 12am".
        let w = ActiveEnergyWindow.resolve(anchor: nil, notBefore: t(7.5), now: t(9), dayStart: day)
        XCTAssertEqual(w?.start, t(7.5))
        XCTAssertEqual(w?.end, t(9))
    }

    func testSubsequentFlushTilesFromThePreviousWindowEnd() {
        // Consecutive deltas must not overlap — HealthKit SUMs activeEnergyBurned.
        let w = ActiveEnergyWindow.resolve(anchor: t(9), notBefore: t(7.5), now: t(10), dayStart: day)
        XCTAssertEqual(w?.start, t(9))
        XCTAssertEqual(w?.end, t(10))
    }

    // MARK: The day floor — the load-bearing clamp

    func testUnsetUserDefaultsEpochAnchorIsClampedToDayStart() {
        // An unset UserDefaults date reads back as Date(timeIntervalSince1970: 0). Unclamped, the
        // first sample after install would span 1970→now and Health would apportion today's kcal
        // across five decades.
        let epoch = Date(timeIntervalSince1970: 0)
        let w = ActiveEnergyWindow.resolve(anchor: epoch, notBefore: nil, now: t(9), dayStart: day)
        XCTAssertEqual(w?.start, day)
    }

    func testAnchorFromAnEarlierDayIsClampedToDayStart() {
        // A multi-day gap (app never opened, no BGTask ran) must not stamp today's delta backwards
        // across days whose totals were already final — that inflation is unretractable.
        let w = ActiveEnergyWindow.resolve(anchor: day.addingTimeInterval(-3 * 86_400),
                                           notBefore: nil, now: t(9), dayStart: day)
        XCTAssertEqual(w?.start, day)
    }

    func testStaleWakeFromAPriorNightIsClampedToDayStart() {
        let w = ActiveEnergyWindow.resolve(anchor: nil, notBefore: day.addingTimeInterval(-2 * 3600),
                                           now: t(9), dayStart: day)
        XCTAssertEqual(w?.start, day)
    }

    func testNoBoundsAtAllFallsBackToTheWholeElapsedDay() {
        // Fresh install mid-day with no sleep summary yet: start-of-day is genuinely the best
        // information available, so this is honest rather than wrong.
        let w = ActiveEnergyWindow.resolve(anchor: nil, notBefore: nil, now: t(15), dayStart: day)
        XCTAssertEqual(w?.start, day)
        XCTAssertEqual(w?.end, t(15))
    }

    // MARK: Tightest bound wins

    func testAnchorWinsWhenItIsLaterThanWake() {
        let w = ActiveEnergyWindow.resolve(anchor: t(11), notBefore: t(7.5), now: t(12), dayStart: day)
        XCTAssertEqual(w?.start, t(11))
    }

    func testAnchorWinsOverWakeOnceAWindowHasBeenWrittenToday() {
        // Anchor is authoritative once today has a written window — `notBefore` is a FIRST-FLUSH
        // floor only. See testNotBeforeIsAFirstFlushFloorAndDoesNotCompressLaterWindows for why
        // re-applying it later would compress a delta into a sliver.
        let w = ActiveEnergyWindow.resolve(anchor: t(2), notBefore: t(7.5), now: t(9), dayStart: day)
        XCTAssertEqual(w?.start, t(2))
    }

    // MARK: Refuse to write rather than throw

    func testFutureAnchorFallsBackToTheDayFloorRatherThanSkipping() {
        // HKHealthStore.save REJECTS end < start, so a future bound must never reach it. Earlier this
        // returned nil, but a nil skips the write WITHOUT advancing the anchor — so a clock
        // step-forward would wedge active energy off until wall-clock caught up, with no self-heal.
        // Discarding the impossible anchor writes now and re-bases it instead.
        let w = ActiveEnergyWindow.resolve(anchor: t(12), notBefore: nil, now: t(9), dayStart: day)
        XCTAssertEqual(w?.start, day)
        XCTAssertEqual(w?.end, t(9))
    }

    func testFutureWakeIsIgnoredRatherThanSkipping() {
        // nightWindow.end can be TONIGHT's. Same reasoning: ignore the impossible floor, don't stall.
        let w = ActiveEnergyWindow.resolve(anchor: nil, notBefore: t(23), now: t(9), dayStart: day)
        XCTAssertEqual(w?.start, day)
    }

    func testZeroWidthWindowYieldsNoWindow() {
        // Two flushes inside the same instant. Skipping is self-healing: the kcal is still owed and
        // rides into the next delta.
        XCTAssertNil(ActiveEnergyWindow.resolve(anchor: t(9), notBefore: nil, now: t(9), dayStart: day))
    }

    func testNowBeforeDayStartYieldsNoWindow() {
        XCTAssertNil(ActiveEnergyWindow.resolve(anchor: nil, notBefore: nil,
                                                now: day.addingTimeInterval(-1), dayStart: day))
    }

    // MARK: Anchor is authoritative once written today (review: night grows on re-stage)

    func testNotBeforeIsAFirstFlushFloorAndDoesNotCompressLaterWindows() {
        // StoredSleepSummary is merge-protected so a night only ever GROWS: the morning-tail rescue
        // and re-stage passes legitimately push inBedEnd LATER hours after wake. If notBefore were
        // re-applied above an anchor already written today, elapsed time the delta genuinely accrued
        // in would be discarded and the whole delta would land in whatever sliver remained.
        let anchor = t(8)
        let grownWake = t(9.5)          // re-stage moved inBedEnd forward, past the anchor
        let w = ActiveEnergyWindow.resolve(anchor: anchor, notBefore: grownWake,
                                           now: t(10), dayStart: day)
        XCTAssertEqual(w?.start, anchor, "an already-written anchor must win over a grown wake time")
    }

    // MARK: A future anchor must not wedge the writer permanently

    func testFutureAnchorIsDiscardedRatherThanWedgingTheWriter() {
        // Clock step-forward (bad RTC before NTP, restored backup, manual date change). A skipped
        // write never advances the anchor, so honouring it would kill active energy until wall-clock
        // caught up — hours with nothing reaching Health and no self-heal path.
        let w = ActiveEnergyWindow.resolve(anchor: t(20), notBefore: t(7.5), now: t(9), dayStart: day)
        XCTAssertNotNil(w, "a future anchor must be discarded, not honoured as a floor")
        XCTAssertEqual(w?.start, t(7.5))
    }

    // MARK: Implausible burn rates widen the window instead of spiking

    func testLargeDeltaOverATinyWindowIsWidenedNotSpiked() {
        // Data arrives in BULK: a drain after hours out of range banks a whole afternoon at once,
        // and a flush seconds after the previous one would otherwise stamp all of it into a
        // sub-minute window — Health then records e.g. 190 kcal in 44 s, forever.
        let w = ActiveEnergyWindow.resolve(anchor: t(9), notBefore: nil,
                                           now: t(9).addingTimeInterval(44), dayStart: day,
                                           kcal: 190)
        let minutes = (w!.duration) / 60.0
        XCTAssertGreaterThan(minutes, 44.0 / 60.0, "window must have been widened")
        XCTAssertLessThanOrEqual(190 / minutes, ActiveEnergyWindow.maxPlausibleKcalPerMinute + 0.001)
    }

    func testWideningNeverEscapesTheDay() {
        // A huge delta early in the day can only widen back to midnight, never into yesterday.
        let w = ActiveEnergyWindow.resolve(anchor: nil, notBefore: nil, now: t(0.5), dayStart: day,
                                           kcal: 5000)
        XCTAssertEqual(w?.start, day)
    }

    func testPlausibleDeltaIsNotWidened() {
        // 5 kcal over 30 min is ~0.17 kcal/min — nowhere near the ceiling, so leave it alone.
        let w = ActiveEnergyWindow.resolve(anchor: t(9), notBefore: nil, now: t(9.5),
                                           dayStart: day, kcal: 5)
        XCTAssertEqual(w?.start, t(9))
    }

    func testZeroKcalDoesNotWiden() {
        let w = ActiveEnergyWindow.resolve(anchor: t(9), notBefore: nil,
                                           now: t(9).addingTimeInterval(10), dayStart: day, kcal: 0)
        XCTAssertEqual(w?.start, t(9))
    }

    // MARK: Invariants that must hold for HealthKit's SUM to stay exact

    func testWindowNeverEscapesTheCalendarDayItBelongsTo() {
        for anchor in [nil, Date(timeIntervalSince1970: 0), t(-5), t(3)] as [Date?] {
            for notBefore in [nil, t(-2), t(7.5)] as [Date?] {
                guard let w = ActiveEnergyWindow.resolve(anchor: anchor, notBefore: notBefore,
                                                         now: t(9), dayStart: day) else { continue }
                XCTAssertGreaterThanOrEqual(w.start, day, "window started before its own day")
                XCTAssertLessThan(w.start, w.end, "window inverted or empty")
                XCTAssertEqual(w.end, t(9))
            }
        }
    }
}
