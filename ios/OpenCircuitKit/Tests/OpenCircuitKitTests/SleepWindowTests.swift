import XCTest
@testable import OpenCircuitKit

// Window math for the sleep-schedule abstraction. Pure date math (UTC calendar so the
// assertions are timezone-stable), mirroring what `ManualSleepSchedule` does in the app.
final class SleepWindowTests: XCTestCase {

    /// Fixed UTC calendar so "local midnight" is deterministic in CI.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // bed 22:30 → wake 06:30: an 8 h window that crosses midnight. Reference is the
    // afternoon AFTER the night, so the chosen wake is that same morning and the bedtime
    // lands on the PREVIOUS calendar day.
    func testCrossMidnightWindow() {
        let ref = date("2026-06-15T14:00:00Z")   // afternoon
        let w = SleepWindow.interval(bedMinutes: 22 * 60 + 30,   // 1350
                                     wakeMinutes: 6 * 60 + 30,    // 390
                                     nightEndingNear: ref,
                                     calendar: utc)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.end, date("2026-06-15T06:30:00Z"))     // this morning's wake
        XCTAssertEqual(w?.start, date("2026-06-14T22:30:00Z"))   // previous evening's bed
        XCTAssertEqual(w?.duration ?? 0, 8 * 3600, accuracy: 1)
    }

    // bed 01:00 → wake 06:30: a same-day (no midnight cross) window.
    func testSameDayWindow() {
        let ref = date("2026-06-15T14:00:00Z")
        let w = SleepWindow.interval(bedMinutes: 1 * 60,         // 60
                                     wakeMinutes: 6 * 60 + 30,   // 390
                                     nightEndingNear: ref,
                                     calendar: utc)
        XCTAssertEqual(w?.start, date("2026-06-15T01:00:00Z"))
        XCTAssertEqual(w?.end, date("2026-06-15T06:30:00Z"))
        XCTAssertEqual(w?.duration ?? 0, 5.5 * 3600, accuracy: 1)
    }

    // The wake nearest the reference is chosen. At 02:00 (mid-sleep) the in-progress
    // night's wake (a few hours ahead) is nearer than the prior morning's.
    func testPicksNearestWake() {
        let ref = date("2026-06-15T02:00:00Z")
        let w = SleepWindow.interval(bedMinutes: 22 * 60 + 30,
                                     wakeMinutes: 6 * 60 + 30,
                                     nightEndingNear: ref,
                                     calendar: utc)
        XCTAssertEqual(w?.end, date("2026-06-15T06:30:00Z"))
        XCTAssertEqual(w?.start, date("2026-06-14T22:30:00Z"))
    }

    // A degenerate bed == wake schedule yields no window (rather than a 24 h or 0-length one).
    func testDegenerateScheduleIsNil() {
        let ref = date("2026-06-15T14:00:00Z")
        XCTAssertNil(SleepWindow.interval(bedMinutes: 390, wakeMinutes: 390,
                                          nightEndingNear: ref, calendar: utc))
    }

    func testMinutesHelper() {
        XCTAssertEqual(SleepWindow.minutes(hour: 22, minute: 30), 1350)
        XCTAssertEqual(SleepWindow.minutes(hour: 0, minute: 0), 0)
    }

    // MARK: isOvernightBlock — gate that keeps a worn daytime block from being staged as
    // "last night" and overwriting the real night (adversarial review #1).

    // A pre-midnight onset (23:00 → 07:00) is overnight.
    func testOvernightPreMidnight() {
        XCTAssertTrue(SleepWindow.isOvernightBlock(
            start: date("2026-06-14T23:00:00Z"), end: date("2026-06-15T07:00:00Z"), calendar: utc))
    }

    // A post-midnight onset (01:00 → 08:00) is overnight (matches the PRIOR day's night anchor).
    func testOvernightPostMidnight() {
        XCTAssertTrue(SleepWindow.isOvernightBlock(
            start: date("2026-06-15T01:00:00Z"), end: date("2026-06-15T08:00:00Z"), calendar: utc))
    }

    // An afternoon nap (13:00 → 15:00) is NOT overnight — the case the gate exists to reject.
    func testAfternoonNapNotOvernight() {
        XCTAssertFalse(SleepWindow.isOvernightBlock(
            start: date("2026-06-15T13:00:00Z"), end: date("2026-06-15T15:00:00Z"), calendar: utc))
    }

    // A long sedentary daytime block (10:00 → 16:00, e.g. a meeting/movie marathon) is NOT overnight.
    func testLongDaytimeBlockNotOvernight() {
        XCTAssertFalse(SleepWindow.isOvernightBlock(
            start: date("2026-06-15T10:00:00Z"), end: date("2026-06-15T16:00:00Z"), calendar: utc))
    }

    // An early-evening onset (19:30 → 04:00) is overnight (overlaps the same-day 18:00 anchor).
    func testEarlyEveningOnsetOvernight() {
        XCTAssertTrue(SleepWindow.isOvernightBlock(
            start: date("2026-06-14T19:30:00Z"), end: date("2026-06-15T04:00:00Z"), calendar: utc))
    }

    // MARK: habitualInterval — the adaptive skin-temp capture window (tracks real sleep hours)

    /// A consistently LATE sleeper (onset ~00:30, wake ~09:30) must get a window that COVERS that
    /// night — the bug the fixed 22:30→06:30 default caused (woke 3 h after the window closed, so
    /// no temp was ever captured). With margins the learned window starts before onset and ends
    /// well after wake.
    func testLateSleeperWindowCoversTheNight() throws {
        let onsets = [date("2026-06-13T00:30:00Z"), date("2026-06-14T00:40:00Z"),
                      date("2026-06-15T00:20:00Z")]
        let wakes  = [date("2026-06-13T09:30:00Z"), date("2026-06-14T09:20:00Z"),
                      date("2026-06-15T09:40:00Z")]
        let ref = date("2026-06-15T14:00:00Z")
        let w = try XCTUnwrap(SleepWindow.habitualInterval(onsets: onsets, wakes: wakes,
                                                           nightEndingNear: ref, calendar: utc))
        // The actual night (00:37 → 09:34) falls inside the learned window.
        XCTAssertLessThanOrEqual(w.start, date("2026-06-15T00:37:00Z"), "window starts before real onset")
        XCTAssertGreaterThanOrEqual(w.end, date("2026-06-15T09:34:00Z"), "window ends after real wake — the fix")
        // And the old fixed default (06:30) would NOT have covered the 09:34 wake.
        XCTAssertGreaterThan(w.end, date("2026-06-15T06:30:00Z"))
    }

    /// Onsets straddling midnight (23:50 and 00:30) must average to ~00:10, not to midday — the
    /// circular-median unwrap. A naive arithmetic mean would land the window start near noon.
    func testOnsetsAcrossMidnightAverageCorrectly() {
        let onsets = [date("2026-06-12T23:50:00Z"), date("2026-06-14T00:30:00Z"),
                      date("2026-06-15T00:10:00Z")]
        let wakes  = [date("2026-06-13T07:00:00Z"), date("2026-06-14T07:10:00Z"),
                      date("2026-06-15T06:50:00Z")]
        let ref = date("2026-06-15T14:00:00Z")
        let w = SleepWindow.habitualInterval(onsets: onsets, wakes: wakes, nightEndingNear: ref,
                                             bedMargin: 0, wakeMargin: 0, calendar: utc)!
        // Median onset ≈ 00:10 → window start that morning's 00:10 (not ~12:00).
        XCTAssertEqual(w.start, date("2026-06-15T00:10:00Z"))
        XCTAssertEqual(w.end, date("2026-06-15T07:00:00Z"))
    }

    /// Median (not mean) ignores a single fragmented outlier night (a 04:00 onset / early wake)
    /// so the learned window stays anchored to the habitual hours.
    func testOutlierNightDoesNotDragWindow() {
        let onsets = [date("2026-06-12T22:30:00Z"), date("2026-06-13T22:40:00Z"),
                      date("2026-06-14T04:00:00Z"),   // outlier
                      date("2026-06-15T22:35:00Z")]
        let wakes  = [date("2026-06-13T06:30:00Z"), date("2026-06-14T06:40:00Z"),
                      date("2026-06-14T05:00:00Z"),   // outlier
                      date("2026-06-16T06:35:00Z")]
        let ref = date("2026-06-16T14:00:00Z")
        let w = SleepWindow.habitualInterval(onsets: onsets, wakes: wakes, nightEndingNear: ref,
                                             bedMargin: 0, wakeMargin: 0, calendar: utc)!
        // Onset median ≈ 22:35 (the outlier 04:00 is unwrapped to 28:00 and sorts last → not picked).
        let comps = utc.dateComponents([.hour], from: w.start)
        XCTAssertGreaterThanOrEqual(comps.hour ?? 0, 22, "habitual evening onset, not the 04:00 outlier")
    }

    /// Fewer than `minNights` usable nights ⇒ nil (caller falls back to the fixed default).
    func testInsufficientHistoryYieldsNil() {
        let ref = date("2026-06-15T14:00:00Z")
        XCTAssertNil(SleepWindow.habitualInterval(
            onsets: [date("2026-06-15T00:30:00Z")], wakes: [date("2026-06-15T09:30:00Z")],
            nightEndingNear: ref, calendar: utc), "one night is not enough to trust a window")
    }
}
