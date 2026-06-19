import XCTest
@testable import OpenCircuitKit

final class ReminderEngineTests: XCTestCase {

    // Calendar fixed to UTC so minute-of-day maths are locale-independent in CI.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    // A "now" that maps to 10:00 UTC (600 minutes since midnight) on 2024-01-15.
    private var now1000: Date {
        var c = DateComponents()
        c.year = 2024; c.month = 1; c.day = 15
        c.hour = 10; c.minute = 0; c.second = 0; c.timeZone = TimeZone(secondsFromGMT: 0)
        return cal.date(from: c)!
    }

    // 22:45 UTC — outside the default 08:00–21:00 active window.
    private var now2245: Date {
        var c = DateComponents()
        c.year = 2024; c.month = 1; c.day = 15
        c.hour = 22; c.minute = 45; c.second = 0; c.timeZone = TimeZone(secondsFromGMT: 0)
        return cal.date(from: c)!
    }

    // MARK: - SedentaryReminder

    func testSedentaryFiresAfterInterval() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(51 * 60))  // 51 min ago
        XCTAssertTrue(r.shouldFire(lastActivityAt: last, now: now1000, calendar: cal))
    }

    func testSedentaryDoesNotFireBeforeInterval() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(49 * 60))  // only 49 min ago
        XCTAssertFalse(r.shouldFire(lastActivityAt: last, now: now1000, calendar: cal))
    }

    func testSedentaryDoesNotFireOutsideActiveHours() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now2245.addingTimeInterval(-(60 * 60))   // 1 h ago, but it's 22:45 now
        XCTAssertFalse(r.shouldFire(lastActivityAt: last, now: now2245, calendar: cal))
    }

    func testSedentaryDoesNotFireWithNilLastActivity() {
        let r = SedentaryReminder()
        XCTAssertFalse(r.shouldFire(lastActivityAt: nil, now: now1000, calendar: cal))
    }

    // MARK: - WearReminder

    func testWearFiresAfterInterval() {
        let r = WearReminder(noDataInterval: 20 * 60)
        let last = Date().addingTimeInterval(-(21 * 60))
        XCTAssertTrue(r.shouldFire(lastRingDataAt: last, now: Date(), everConnected: true))
    }

    func testWearDoesNotFireBeforeInterval() {
        let r = WearReminder(noDataInterval: 20 * 60)
        let last = Date().addingTimeInterval(-(19 * 60))
        XCTAssertFalse(r.shouldFire(lastRingDataAt: last, now: Date(), everConnected: true))
    }

    func testWearDoesNotFireIfNeverConnected() {
        let r = WearReminder(noDataInterval: 20 * 60)
        XCTAssertFalse(r.shouldFire(lastRingDataAt: nil, now: Date(), everConnected: false))
    }

    func testWearFiresWhenNilDataButEverConnected() {
        let r = WearReminder(noDataInterval: 20 * 60)
        // nil lastRingDataAt + everConnected = true → fire (ring disappeared)
        XCTAssertTrue(r.shouldFire(lastRingDataAt: nil, now: Date(), everConnected: true))
    }

    // MARK: - BedtimeReminder (normal window, no midnight wrap)

    // Bed at 23:00 (1380 min), minutesBefore = 30 → window is [22:30, 23:00).
    func testBedtimeFiresInsideWindow() {
        let r = BedtimeReminder(minutesBefore: 30)
        // now = 22:45 (1365 min) — inside [1350, 1380)
        let now = now2245  // 22:45 UTC
        XCTAssertTrue(r.shouldFire(now: now, bedMinutes: 1380, wakeMinutes: 7 * 60, calendar: cal))
    }

    func testBedtimeDoesNotFireOutsideWindow() {
        let r = BedtimeReminder(minutesBefore: 30)
        // now = 10:00 — far from [22:30, 23:00)
        XCTAssertFalse(r.shouldFire(now: now1000, bedMinutes: 1380, wakeMinutes: 7 * 60, calendar: cal))
    }

    func testBedtimeDoesNotFireWhenBedEqualsWake() {
        let r = BedtimeReminder(minutesBefore: 30)
        XCTAssertFalse(r.shouldFire(now: now1000, bedMinutes: 600, wakeMinutes: 600, calendar: cal))
    }

    // MARK: - BedtimeReminder (window wraps midnight)

    // Bed at 01:00 (60 min), minutesBefore = 30 → window is [00:30, 01:00).
    func testBedtimeWrapsAroundMidnightFires() {
        let r = BedtimeReminder(minutesBefore: 30)
        // now = 00:45 (45 min) — inside wrapping window [30, 60)
        var c = DateComponents()
        c.year = 2024; c.month = 1; c.day = 15
        c.hour = 0; c.minute = 45; c.timeZone = TimeZone(secondsFromGMT: 0)
        let now0045 = cal.date(from: c)!
        XCTAssertTrue(r.shouldFire(now: now0045, bedMinutes: 60, wakeMinutes: 7 * 60, calendar: cal))
    }

    func testBedtimeWrapsAroundMidnightDoesNotFireOutside() {
        let r = BedtimeReminder(minutesBefore: 30)
        // now = 10:00 — not inside [30, 60)
        XCTAssertFalse(r.shouldFire(now: now1000, bedMinutes: 60, wakeMinutes: 7 * 60, calendar: cal))
    }

    // Bed = 23:45 (1425 min), minutesBefore = 30 → window [1395, 1425) = [23:15, 23:45)
    // Wraps? No, both are before midnight — purely same-day window.
    func testBedtimeNearMidnightSameDay() {
        let r = BedtimeReminder(minutesBefore: 30)
        // now = 23:20 → 1400 min — inside [1395, 1425)
        var c = DateComponents()
        c.year = 2024; c.month = 1; c.day = 15
        c.hour = 23; c.minute = 20; c.timeZone = TimeZone(secondsFromGMT: 0)
        let now2320 = cal.date(from: c)!
        XCTAssertTrue(r.shouldFire(now: now2320, bedMinutes: 1425, wakeMinutes: 7 * 60, calendar: cal))
    }
}
