import XCTest
@testable import OpenCircuitKit

// Recency math shared by the Goals Sleep ring credit (#147) and the Sleep-card missed-night
// banner (#148). Pure date math on a fixed UTC calendar so "local midnight" is deterministic
// in CI. Schedule under test: bed 22:30 → wake 06:30 (an 8 h window crossing midnight).
final class MissedNightTests: XCTestCase {

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

    private let bed = 22 * 60 + 30    // 22:30
    private let wake = 6 * 60 + 30    // 06:30

    // MARK: morningWake — stays pinned to THIS morning's wake all waking day (#148 Bug 2)

    func testMorningWakeMorning() {
        let w = MissedNight.morningWake(now: date("2026-06-15T08:00:00Z"),
                                        bedMinutes: bed, wakeMinutes: wake, calendar: utc)
        XCTAssertEqual(w, date("2026-06-15T06:30:00Z"))
    }

    func testMorningWakeEveningStillTodaysWake() {
        // 20:00 — the NEAREST wake is tomorrow 06:30; morningWake must step back to today's 06:30
        // so the banner doesn't vanish in the evening.
        let w = MissedNight.morningWake(now: date("2026-06-15T20:00:00Z"),
                                        bedMinutes: bed, wakeMinutes: wake, calendar: utc)
        XCTAssertEqual(w, date("2026-06-15T06:30:00Z"))
    }

    func testMorningWakeLateEveningBeforeBed() {
        // 22:00, just before tonight's bed — still today's wake.
        let w = MissedNight.morningWake(now: date("2026-06-15T22:00:00Z"),
                                        bedMinutes: bed, wakeMinutes: wake, calendar: utc)
        XCTAssertEqual(w, date("2026-06-15T06:30:00Z"))
    }

    func testMorningWakeMidSleepIsAheadOfNow() {
        // 03:00, mid-sleep — this morning's wake (today 06:30) is still AHEAD of now, so the
        // `now > wake` gate keeps a 3 a.m. glance from ever claiming a miss.
        let w = MissedNight.morningWake(now: date("2026-06-15T03:00:00Z"),
                                        bedMinutes: bed, wakeMinutes: wake, calendar: utc)
        XCTAssertEqual(w, date("2026-06-15T06:30:00Z"))
        XCTAssertGreaterThan(w!, date("2026-06-15T03:00:00Z"))   // future ⇒ gate false
    }

    func testMorningWakeDegenerateScheduleNil() {
        XCTAssertNil(MissedNight.morningWake(now: date("2026-06-15T08:00:00Z"),
                                             bedMinutes: 390, wakeMinutes: 390, calendar: utc))
    }

    // MARK: endedToday — the credit gate (#147)

    func testEndedTodayNightEndedToday() {
        // Night ended this morning (00:24 today) → credited.
        XCTAssertTrue(MissedNight.endedToday(
            inBedEnd: date("2026-06-15T06:24:00Z"),
            nightKey: date("2026-06-14T00:00:00Z"),
            now: date("2026-06-15T09:00:00Z"), calendar: utc))
    }

    func testEndedTwoDaysAgoNotCredited() {
        // A 2-day-old night still has positive minutes but must NOT be credited.
        XCTAssertFalse(MissedNight.endedToday(
            inBedEnd: date("2026-06-13T06:30:00Z"),
            nightKey: date("2026-06-12T00:00:00Z"),
            now: date("2026-06-15T09:00:00Z"), calendar: utc))
    }

    func testLegacyDistantPastEndUsesNightKeyNotCredited() {
        // Legacy rollup: inBedEnd unknown (nil) → falls back to the start-of-day key, which on a
        // later day is not today → not credited.
        XCTAssertFalse(MissedNight.endedToday(
            inBedEnd: nil,
            nightKey: date("2026-06-13T00:00:00Z"),
            now: date("2026-06-15T09:00:00Z"), calendar: utc))
    }

    func testLegacyNightKeyIsTodayIsCredited() {
        // A legacy rollup whose start-of-day key IS today → credited (best available signal).
        XCTAssertTrue(MissedNight.endedToday(
            inBedEnd: nil,
            nightKey: date("2026-06-15T00:00:00Z"),
            now: date("2026-06-15T09:00:00Z"), calendar: utc))
    }

    // MARK: status / isMissing — the banner (#148)

    private func status(now: String, nightWake: Date?, wakeKnown: Bool = true,
                        lastSyncAt: Date?) -> MissedNight.Status {
        MissedNight.status(now: date(now), bedMinutes: bed, wakeMinutes: wake,
                           nightWake: nightWake, wakeKnown: wakeKnown,
                           lastSyncAt: lastSyncAt, calendar: utc)
    }

    // The core acceptance case: a STALE stored night (ended 2 days ago) with a post-wake sync.
    private let staleNight = "2026-06-13T06:30:00Z"

    func testMissingInMorningAfterPostWakeSync() {
        // 08:00, sync completed at 07:30 (after this morning's 06:30 wake), stale night → missing.
        XCTAssertEqual(status(now: "2026-06-15T08:00:00Z",
                              nightWake: date(staleNight),
                              lastSyncAt: date("2026-06-15T07:30:00Z")), .missing)
    }

    func testStillMissingInEvening() {
        // 20:00 same day, same post-wake sync — must STILL be missing (Bug 2 fix).
        XCTAssertEqual(status(now: "2026-06-15T20:00:00Z",
                              nightWake: date(staleNight),
                              lastSyncAt: date("2026-06-15T07:30:00Z")), .missing)
    }

    func testNotSyncedYetBeforeAnyPostWakeSync() {
        // 08:00 but the last sync was YESTERDAY (before this morning's wake) → not synced yet,
        // NOT an alarming miss (Bug 1 fix).
        XCTAssertEqual(status(now: "2026-06-15T08:00:00Z",
                              nightWake: date(staleNight),
                              lastSyncAt: date("2026-06-14T18:00:00Z")), .notSyncedYet)
    }

    func testNotSyncedYetWhenNoSyncEverRecorded() {
        XCTAssertEqual(status(now: "2026-06-15T08:00:00Z",
                              nightWake: date(staleNight),
                              lastSyncAt: nil), .notSyncedYet)
    }

    func testNotMissingWhenNightEndedToday() {
        // Night ended today → ok even long after wake and after a sync.
        XCTAssertEqual(status(now: "2026-06-15T20:00:00Z",
                              nightWake: date("2026-06-15T06:24:00Z"),
                              lastSyncAt: date("2026-06-15T07:30:00Z")), .ok)
    }

    func testNotMissingMidSleep() {
        // 03:00 mid-sleep, stale stored night, a sync landed yesterday — must NOT flag a miss
        // before this morning's wake.
        XCTAssertEqual(status(now: "2026-06-15T03:00:00Z",
                              nightWake: date(staleNight),
                              lastSyncAt: date("2026-06-14T18:00:00Z")), .ok)
    }

    func testLegacyWakeUnknownNeverMissing() {
        XCTAssertEqual(status(now: "2026-06-15T08:00:00Z",
                              nightWake: nil, wakeKnown: false,
                              lastSyncAt: date("2026-06-15T07:30:00Z")), .ok)
    }

    // The exact acceptance assertions spelled out in #148.
    func testAcceptanceIsMissingMatrix() {
        func missing(_ now: String, _ sync: Date?) -> Bool {
            MissedNight.isMissing(now: date(now), bedMinutes: bed, wakeMinutes: wake,
                                  nightWake: date(staleNight), wakeKnown: true,
                                  lastSyncAt: sync, calendar: utc)
        }
        XCTAssertTrue(missing("2026-06-15T08:00:00Z", date("2026-06-15T07:30:00Z")))   // post-wake sync
        XCTAssertTrue(missing("2026-06-15T20:00:00Z", date("2026-06-15T07:30:00Z")))   // evening, same
        XCTAssertFalse(missing("2026-06-15T08:00:00Z", date("2026-06-14T18:00:00Z")))  // no post-wake sync
    }

    // MARK: cross-check the invariant that ties #147 and #148 together

    func testMissingImpliesCreditWithheld() {
        // For every hour of the day, whenever the banner says `.missing`, the credit gate must be
        // false (empty ring) — the two surfaces can never contradict.
        for hour in 0..<24 {
            let now = date(String(format: "2026-06-15T%02d:00:00Z", hour))
            let st = MissedNight.status(now: now, bedMinutes: bed, wakeMinutes: wake,
                                        nightWake: date(staleNight), wakeKnown: true,
                                        lastSyncAt: date("2026-06-15T07:30:00Z"), calendar: utc)
            if st == .missing {
                XCTAssertFalse(MissedNight.endedToday(inBedEnd: date(staleNight),
                                                      nightKey: date("2026-06-12T00:00:00Z"),
                                                      now: now, calendar: utc),
                               "credit must be withheld while banner is .missing @\(hour)h")
            }
        }
    }
}
