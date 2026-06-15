import XCTest
@testable import OpenRingKit

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
}
