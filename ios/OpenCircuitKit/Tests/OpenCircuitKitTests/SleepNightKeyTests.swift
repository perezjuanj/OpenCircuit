import XCTest
@testable import OpenCircuitKit

final class SleepNightKeyTests: XCTestCase {

    /// Fixed zone so the assertions don't move with the machine running them. America/New_York is
    /// the device the collision was proven on (UTC-4 in August).
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func day(_ y: Int, _ mo: Int, _ d: Int) -> Date { at(y, mo, d, 0, 0) }

    // MARK: the proven collision

    /// 🔒 THE REGRESSION THIS FILE EXISTS FOR. Two consecutive real nights from a device on
    /// 2026-08-08: bedtime crossed midnight in OPPOSITE directions, so the old
    /// `startOfDay(inBedStart)` key mapped BOTH onto 2026-08-07 and the second night was dropped.
    func testConsecutiveNightsStraddlingMidnightGetDistinctKeys() {
        // night 08-06 -> 08-07: bed 00:13, wake 08:57 (bedtime AFTER midnight)
        let first = SleepNightKey.night(inBedStart: at(2026, 8, 7, 0, 13),
                                        inBedEnd: at(2026, 8, 7, 8, 57), calendar: cal)
        // night 08-07 -> 08-08: bed 23:56, wake 09:45 (bedtime BEFORE midnight)
        let second = SleepNightKey.night(inBedStart: at(2026, 8, 7, 23, 56),
                                         inBedEnd: at(2026, 8, 8, 9, 45), calendar: cal)

        XCTAssertEqual(first, day(2026, 8, 7))
        XCTAssertEqual(second, day(2026, 8, 8))
        XCTAssertNotEqual(first, second, "two consecutive nights must never share an upsert key")

        // And prove the OLD rule is what collided, so this test can't silently pass on a regression
        // that reverts the anchor.
        XCTAssertEqual(cal.startOfDay(for: at(2026, 8, 7, 0, 13)),
                       cal.startOfDay(for: at(2026, 8, 7, 23, 56)),
                       "start-anchored keys collided — that is the bug being fixed")
    }

    // MARK: the rule

    func testKeyIsTheWakeDayForAPreMidnightBedtime() {
        XCTAssertEqual(SleepNightKey.night(inBedStart: at(2026, 8, 4, 22, 26),
                                           inBedEnd: at(2026, 8, 5, 8, 59), calendar: cal),
                       day(2026, 8, 5))
    }

    func testKeyIsUnchangedForANightFullyInsideOneDay() {
        // bed 01:34 -> wake 08:50 on the same calendar day: start- and end-anchored agree.
        XCTAssertEqual(SleepNightKey.night(inBedStart: at(2026, 8, 3, 1, 34),
                                           inBedEnd: at(2026, 8, 3, 8, 50), calendar: cal),
                       day(2026, 8, 3))
    }

    /// A wake exactly at midnight belongs to the day it ends on — `startOfDay` of 00:00 is itself.
    func testWakeExactlyAtMidnight() {
        XCTAssertEqual(SleepNightKey.night(inBedStart: at(2026, 8, 7, 21, 0),
                                           inBedEnd: day(2026, 8, 8), calendar: cal),
                       day(2026, 8, 8))
    }

    // MARK: degenerate windows

    /// An empty or inverted window has no end to anchor to; it must still produce a deterministic
    /// key rather than trapping or returning a distantPast sentinel.
    func testInvertedWindowFallsBackToTheStartDay() {
        XCTAssertEqual(SleepNightKey.night(inBedStart: at(2026, 8, 7, 23, 56),
                                           inBedEnd: at(2026, 8, 7, 20, 0), calendar: cal),
                       day(2026, 8, 7))
    }

    func testZeroLengthWindowFallsBackToTheStartDay() {
        let t = at(2026, 8, 7, 23, 56)
        XCTAssertEqual(SleepNightKey.night(inBedStart: t, inBedEnd: t, calendar: cal),
                       day(2026, 8, 7))
    }

    // MARK: segments overload

    func testSegmentsOverloadUsesTheEnvelopeNotTheFirstSegment() {
        let segs = [
            SleepSegment(start: at(2026, 8, 7, 23, 56), end: at(2026, 8, 8, 2, 0), stage: .asleepCore),
            SleepSegment(start: at(2026, 8, 8, 2, 0), end: at(2026, 8, 8, 9, 45), stage: .asleepDeep),
        ]
        XCTAssertEqual(SleepNightKey.night(for: segs, calendar: cal), day(2026, 8, 8))
    }

    func testSegmentsOverloadIsNilWhenThereAreNoSegments() {
        XCTAssertNil(SleepNightKey.night(for: [], calendar: cal))
    }

    /// Out-of-order segments must key off the true envelope, not array position.
    func testSegmentsOverloadIsOrderIndependent() {
        let a = SleepSegment(start: at(2026, 8, 8, 2, 0), end: at(2026, 8, 8, 9, 45), stage: .asleepDeep)
        let b = SleepSegment(start: at(2026, 8, 7, 23, 56), end: at(2026, 8, 8, 2, 0), stage: .asleepCore)
        XCTAssertEqual(SleepNightKey.night(for: [a, b], calendar: cal),
                       SleepNightKey.night(for: [b, a], calendar: cal))
    }

    // MARK: rekeyed (drives the one-shot migration)

    func testRekeyedIsNilWhenTheStoredKeyIsAlreadyCorrect() {
        XCTAssertNil(SleepNightKey.rekeyed(storedNight: day(2026, 8, 3),
                                           inBedStart: at(2026, 8, 3, 1, 34),
                                           inBedEnd: at(2026, 8, 3, 8, 50), calendar: cal))
    }

    func testRekeyedMovesAPreMidnightBedtimeRowToItsWakeDay() {
        XCTAssertEqual(SleepNightKey.rekeyed(storedNight: day(2026, 8, 4),
                                             inBedStart: at(2026, 8, 4, 22, 26),
                                             inBedEnd: at(2026, 8, 5, 8, 59), calendar: cal),
                       day(2026, 8, 5))
    }

    /// Idempotence: running the migration twice must move nothing the second time.
    func testRekeyedIsIdempotent() {
        let start = at(2026, 8, 4, 22, 26), end = at(2026, 8, 5, 8, 59)
        let moved = SleepNightKey.rekeyed(storedNight: day(2026, 8, 4),
                                          inBedStart: start, inBedEnd: end, calendar: cal)
        XCTAssertEqual(moved, day(2026, 8, 5))
        XCTAssertNil(SleepNightKey.rekeyed(storedNight: moved!,
                                           inBedStart: start, inBedEnd: end, calendar: cal),
                     "a re-keyed row must not move again on a second migration pass")
    }

    /// A stored key that isn't already midnight-aligned still compares correctly — the migration
    /// must not move a row just because its stored value carries a time component.
    func testRekeyedNormalisesTheStoredKeyBeforeComparing() {
        XCTAssertNil(SleepNightKey.rekeyed(storedNight: at(2026, 8, 3, 6, 30),
                                           inBedStart: at(2026, 8, 3, 1, 34),
                                           inBedEnd: at(2026, 8, 3, 8, 50), calendar: cal))
    }
}
