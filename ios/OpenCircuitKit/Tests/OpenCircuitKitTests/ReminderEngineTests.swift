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

    func testSedentaryDoesNotFireWithFreshActivityWithinInterval() {
        // #145: once a foreground sync lands a fresh step delta, the gap is < interval → no nudge.
        // The bug was evaluating this rule PRE-sync against a stale `lastActivityAt` (gap ≥ interval);
        // the app-layer fix defers the evaluation to post-sync so `lastActivityAt` is fresh like this.
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let fresh = now1000.addingTimeInterval(-(5 * 60))   // moved 5 min ago
        XCTAssertFalse(r.shouldFire(lastActivityAt: fresh, now: now1000, calendar: cal))
    }

    // MARK: - SedentaryReminder: a ring on the charger is not a user sitting still

    /// The reported false positive. The ring has been on the charger for the last hour, so no step
    /// delta has arrived and `lastActivityAt` is an hour stale — which is exactly what genuine
    /// inactivity looks like. The live charging byte says otherwise.
    func testSedentaryDoesNotFireWhileOnTheCharger() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(60 * 60))
        XCTAssertFalse(r.shouldFire(lastActivityAt: last, now: now1000,
                                    isOnCharger: true, calendar: cal))
    }

    /// The same stretch seen after the fact — the ring is back on the finger (or merely
    /// disconnected, so no live byte), but the last thing we OBSERVED was it off the finger, five
    /// minutes ago. The unmeasured stretch must not be charged to the user as stillness.
    func testSedentaryDoesNotFireWhenTheRingWasOffTheFingerInsideTheWindow() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(60 * 60))
        XCTAssertFalse(r.shouldFire(lastActivityAt: last, now: now1000,
                                    lastOffFingerAt: now1000.addingTimeInterval(-(5 * 60)),
                                    calendar: cal))
    }

    /// …and the suppression expires: once the ring has been back on the finger for a full interval,
    /// the stillness has actually been measured and the nudge is earned again. This is the test that
    /// keeps the fix from silently disabling the whole reminder for anyone who ever charges.
    func testSedentaryFiresOnceTheRingHasBeenBackOnTheFingerForAFullInterval() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(3 * 3600))
        XCTAssertTrue(r.shouldFire(lastActivityAt: last, now: now1000,
                                   lastOffFingerAt: now1000.addingTimeInterval(-(51 * 60)),
                                   calendar: cal))
    }

    /// A future-dated off-finger stamp (ring clock drift / a timezone change between the frame and
    /// this pass) is "as fresh as possible", not "infinitely old" — clamped, so it suppresses.
    func testSedentaryClampsAFutureDatedOffFingerStamp() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(3 * 3600))
        XCTAssertFalse(r.shouldFire(lastActivityAt: last, now: now1000,
                                    lastOffFingerAt: now1000.addingTimeInterval(30 * 60),
                                    calendar: cal))
    }

    /// The charge that happens with the LINK DOWN: no descriptor arrives to stamp either of the
    /// signals above, and the first frame after the reconnect is warm and current — but we heard
    /// nothing at all across the window, so we measured no stillness to complain about.
    func testSedentaryDoesNotFireWhenTheRingWasSilentForTheWholeWindow() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(2 * 3600))
        XCTAssertFalse(r.shouldFire(lastActivityAt: last, now: now1000,
                                    lastRingDataAt: now1000.addingTimeInterval(-(2 * 3600)),
                                    calendar: cal))
    }

    /// A ring that IS reporting — frames landing right up to now — and still no steps is the case
    /// the reminder is for. The silence suppression must not extend to it.
    func testSedentaryFiresWhenFramesAreArrivingButNoStepsAre() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(51 * 60))
        XCTAssertTrue(r.shouldFire(lastActivityAt: last, now: now1000,
                                   lastRingDataAt: now1000.addingTimeInterval(-60),
                                   calendar: cal))
    }

    /// The new inputs are suppressions only — omitted (an old build's persisted state, or a session
    /// that has seen no descriptor yet), the rule behaves exactly as it did before. In particular a
    /// nil `lastRingDataAt` is "no information", not "silent forever".
    func testSedentaryUnchangedWhenNoWearEvidenceIsAvailable() {
        let r = SedentaryReminder(interval: 50 * 60, activeStartMinutes: 8 * 60, activeEndMinutes: 21 * 60)
        let last = now1000.addingTimeInterval(-(51 * 60))
        XCTAssertTrue(r.shouldFire(lastActivityAt: last, now: now1000,
                                   isOnCharger: false, lastOffFingerAt: nil,
                                   lastRingDataAt: nil, calendar: cal))
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

    // MARK: - WearReminder: silence is not evidence of not-wearing

    /// The reported false positive. A tester's link drops for an hour while she is demonstrably
    /// wearing the ring; the drain that follows carries worn epochs covering that hour. The
    /// reminder must not have fired, and must not fire now.
    func testWearDoesNotFireWhenDrainedEpochsProveTheRingWasWorn() {
        let r = WearReminder(noDataInterval: 60 * 60)
        let now = Date()
        XCTAssertFalse(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-90 * 60), now: now,
                                    everConnected: true,
                                    lastWornEvidenceAt: now.addingTimeInterval(-10 * 60)))
    }

    /// …but worn evidence that is itself older than the silence window proves nothing about now.
    func testWearStillFiresWhenTheWornEvidenceIsAlsoStale() {
        let r = WearReminder(noDataInterval: 60 * 60)
        let now = Date()
        XCTAssertTrue(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-3 * 3600), now: now,
                                   everConnected: true,
                                   lastWornEvidenceAt: now.addingTimeInterval(-3 * 3600)))
    }

    /// "Put your ring back on" is the wrong instruction while the ring is connected.
    func testWearDoesNotFireWhileConnected() {
        let r = WearReminder(noDataInterval: 60 * 60)
        let now = Date()
        XCTAssertFalse(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-3 * 3600), now: now,
                                    everConnected: true, isConnected: true))
        // …and the nil-data path is gated the same way, not just the interval path.
        XCTAssertFalse(r.shouldFire(lastRingDataAt: nil, now: now,
                                    everConnected: true, isConnected: true))
    }

    /// The tester also got this overnight. A wear nag inside the user's own sleep schedule is
    /// never actionable.
    func testWearDoesNotFireInsideTheSleepWindow() {
        let r = WearReminder(noDataInterval: 60 * 60)
        let now = Date()
        XCTAssertFalse(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-3 * 3600), now: now,
                                    everConnected: true, inSleepWindow: true))
        XCTAssertFalse(r.shouldFire(lastRingDataAt: nil, now: now,
                                    everConnected: true, inSleepWindow: true))
    }

    /// A genuinely removed ring — silent, disconnected, awake hours, and the newest worn epoch is
    /// older than the silence window — still fires. The suppressions must not disable the feature.
    func testWearStillFiresForAGenuinelyRemovedRing() {
        let r = WearReminder(noDataInterval: 60 * 60)
        let now = Date()
        XCTAssertTrue(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-2 * 3600), now: now,
                                   everConnected: true,
                                   lastWornEvidenceAt: now.addingTimeInterval(-2 * 3600),
                                   isConnected: false, inSleepWindow: false))
    }

    func testWearDefaultIntervalIsAnHour() {
        XCTAssertEqual(WearReminder().noDataInterval, 60 * 60)
    }

    // MARK: - WearReminder: a docked ring was detected, not lost

    /// The charger false positive: the link has been down for 90 min, but the last frame we hold
    /// said the ring was on the charger. "Ring not detected · put your ring back on" is both untrue
    /// and un-actionable — the user is charging on purpose.
    func testWearDoesNotFireWhenTheLastFrameSaidOnTheCharger() {
        let r = WearReminder(noDataInterval: 60 * 60, chargerGrace: 4 * 3600)
        let now = Date()
        XCTAssertFalse(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-90 * 60), now: now,
                                    everConnected: true, lastKnownOnCharger: true))
    }

    /// The suppression is bounded, not absolute: a ring that came off the charger straight into a
    /// drawer stops being "probably still charging" once the charge could long since have finished.
    func testWearFiresOnceTheChargerEvidenceAgesPastTheGrace() {
        let r = WearReminder(noDataInterval: 60 * 60, chargerGrace: 4 * 3600)
        let now = Date()
        XCTAssertTrue(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-5 * 3600), now: now,
                                   everConnected: true, lastKnownOnCharger: true))
    }

    /// A ring whose last frame showed it WORN and then went silent is the genuine case the rule
    /// exists for — the charger suppression must not swallow it.
    func testWearStillFiresWhenTheLastFrameDidNotSayCharger() {
        let r = WearReminder(noDataInterval: 60 * 60, chargerGrace: 4 * 3600)
        let now = Date()
        XCTAssertTrue(r.shouldFire(lastRingDataAt: now.addingTimeInterval(-90 * 60), now: now,
                                   everConnected: true, lastKnownOnCharger: false))
    }

    /// With no frame ever recorded there is no timestamp to age the charger evidence against, so
    /// the flag cannot suppress: "ever paired, never heard from" stays a fire.
    func testWearFiresWithNilDataEvenIfTheChargerFlagIsSet() {
        let r = WearReminder(noDataInterval: 60 * 60, chargerGrace: 4 * 3600)
        XCTAssertTrue(r.shouldFire(lastRingDataAt: nil, now: Date(),
                                   everConnected: true, lastKnownOnCharger: true))
    }

    func testWearDefaultChargerGraceIsFourHours() {
        XCTAssertEqual(WearReminder().chargerGrace, 4 * 3600)
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
