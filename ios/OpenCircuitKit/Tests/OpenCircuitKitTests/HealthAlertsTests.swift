import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the local health-alert engine: thresholds (#73), flag routing (#85),
/// quiet-hours DND, and the anti-spam de-dupe gate. No real health values.
final class HealthAlertsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func at(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: h, minute: m))!
    }
    private func hr(_ bpm: Int, _ h: Int, _ m: Int = 0) -> HRSample { HRSample(bpm: bpm, start: at(h, m)) }

    // MARK: #73 threshold rules

    func testHighHRPicksWorstReading() {
        let s = [hr(80, 9), hr(125, 10), hr(140, 11), hr(90, 12)]
        let hit = HealthAlertEvaluator.highHR(s, thresholdBpm: 120)
        XCTAssertEqual(hit?.bpm, 140)
        XCTAssertNil(HealthAlertEvaluator.highHR([hr(80, 9), hr(100, 10)], thresholdBpm: 120))
    }

    func testLowSpO2PicksWorstReading() {
        let r = [SpO2Reading(percent: 97, time: at(2)), SpO2Reading(percent: 88, time: at(3)),
                 SpO2Reading(percent: 91, time: at(4))]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)?.percent, 88)
        // Zero/invalid placeholders are ignored.
        XCTAssertNil(HealthAlertEvaluator.lowSpO2([SpO2Reading(percent: 0, time: at(2))], thresholdPercent: 90))
        XCTAssertNil(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 80))
    }

    func testElevatedHRInactiveSustained() {
        // 5 readings ≥100 spanning 10 min (epochs ~2.5 min apart) → fires on the last.
        let s = [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6), hr(106, 1, 9), hr(112, 1, 12)]
        let hit = HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100, minDuration: 10 * 60)
        XCTAssertEqual(hit?.bpm, 112)
    }

    func testElevatedHRInactiveTooShort() {
        // Elevated for only ~6 min → no fire.
        let s = [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6)]
        XCTAssertNil(HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100, minDuration: 10 * 60))
    }

    func testElevatedHRInactiveResetsBelowThreshold() {
        // A dip below threshold breaks the run; the later cluster is too short on its own.
        let s = [hr(105, 1, 0), hr(108, 1, 3), hr(70, 1, 6), hr(110, 1, 9), hr(112, 1, 12)]
        XCTAssertNil(HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100, minDuration: 10 * 60))
    }

    func testElevatedHRInactiveGapBreaksRun() {
        // Two elevated readings 30 min apart — gap exceeds maxGap, so not one continuous run.
        let s = [hr(110, 1, 0), hr(112, 1, 30)]
        XCTAssertNil(HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100,
                                                             minDuration: 10 * 60, maxGap: 5 * 60))
    }

    func testEvaluateRespectsEnableFlags() {
        let highOnly = HealthAlertThresholds(highHREnabled: true, lowSpO2Enabled: false, elevatedHREnabled: false)
        let hits = HealthAlertEvaluator.evaluate(
            hr: [hr(130, 10)],
            spo2: [SpO2Reading(percent: 85, time: at(3))],
            inactiveHR: [],
            thresholds: highOnly)
        XCTAssertEqual(hits.map(\.notification), [.highHR])
    }

    // MARK: #85 flag routing

    func testTempFeverRouting() {
        var flags = SkinTempBaseline.AnomalyFlags()
        flags.abnormalRise = true
        flags.fluctuationDrop = true
        let notifs = TempFeverNotifications.notifications(flags: flags, feverSuspected: true)
        XCTAssertEqual(Set(notifs), [.skinTempRise, .skinTempFluctuationDrop, .fever])
        XCTAssertTrue(TempFeverNotifications.notifications(flags: SkinTempBaseline.AnomalyFlags(),
                                                          feverSuspected: false).isEmpty)
    }

    func testFreshForNightDropsAlreadyNotifiedNight() {
        let night = cal.startOfDay(for: at(3))          // this overnight's summary
        let cands: [HealthNotification] = [.skinTempFluctuationDrop, .fever]
        // Same night already notified for the fluctuation drop → drop it, keep the unnotified fever.
        let fresh = TempFeverNotifications.freshForNight(
            cands, night: night, lastNotifiedNight: [.skinTempFluctuationDrop: night])
        XCTAssertEqual(fresh, [.fever], "same night must not re-fire the same flag")
        // No prior night for either → both survive.
        XCTAssertEqual(TempFeverNotifications.freshForNight(cands, night: night, lastNotifiedNight: [:]),
                       cands)
    }

    func testFreshForNightReArmsOnNewerNight() {
        let lastNight = cal.startOfDay(for: at(3))
        let newerNight = cal.date(byAdding: .day, value: 1, to: lastNight)!
        let fresh = TempFeverNotifications.freshForNight(
            [.skinTempFluctuationDrop], night: newerNight,
            lastNotifiedNight: [.skinTempFluctuationDrop: lastNight])
        XCTAssertEqual(fresh, [.skinTempFluctuationDrop], "a new night's summary re-arms the alert")
        // A stale (older) recompute of a night we've moved past must not re-fire.
        XCTAssertTrue(TempFeverNotifications.freshForNight(
            [.skinTempFluctuationDrop], night: lastNight,
            lastNotifiedNight: [.skinTempFluctuationDrop: newerNight]).isEmpty)
    }

    // MARK: Quiet hours (DND)

    func testQuietHoursWrapsMidnight() {
        let q = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertTrue(q.contains(at(23), calendar: cal))
        XCTAssertTrue(q.contains(at(2), calendar: cal))
        XCTAssertFalse(q.contains(at(12), calendar: cal))
        XCTAssertFalse(q.contains(at(7), calendar: cal), "end is exclusive")
    }

    func testQuietHoursDisabled() {
        let q = QuietHours(enabled: false, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertFalse(q.contains(at(2), calendar: cal))
    }

    // MARK: De-dupe / DND gate

    func testGateSuppressesDuringQuietHours() {
        let gate = NotificationGate()
        let q = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertFalse(gate.shouldFire(.highHR, now: at(2), lastFired: [:], quietHours: q, calendar: cal))
        XCTAssertTrue(gate.shouldFire(.highHR, now: at(12), lastFired: [:], quietHours: q, calendar: cal))
    }

    func testGateRenotifyBackoff() {
        let gate = NotificationGate(renotifyInterval: 2 * 3600)
        let last: [HealthNotification: Date] = [.lowSpO2: at(10)]
        let q = QuietHours(enabled: false)
        // 1h later — still inside backoff.
        XCTAssertFalse(gate.shouldFire(.lowSpO2, now: at(11), lastFired: last, quietHours: q, calendar: cal))
        // 3h later — backoff elapsed.
        XCTAssertTrue(gate.shouldFire(.lowSpO2, now: at(13), lastFired: last, quietHours: q, calendar: cal))
        // A DIFFERENT condition is independent.
        XCTAssertTrue(gate.shouldFire(.highHR, now: at(11), lastFired: last, quietHours: q, calendar: cal))
    }

    func testGateFilterStableOrder() {
        let gate = NotificationGate()
        let q = QuietHours(enabled: false)
        let out = gate.filter([.fever, .highHR, .lowSpO2], now: at(12), lastFired: [:],
                              quietHours: q, calendar: cal)
        // Returned in HealthNotification.allCases order: highHR, lowSpO2, …, fever.
        XCTAssertEqual(out, [.highHR, .lowSpO2, .fever])
    }
}
