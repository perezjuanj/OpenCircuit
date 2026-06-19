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
}
