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

    func testEvaluateSuppressesReadingsAtOrBeforeLastFired() {
        let thresholds = HealthAlertThresholds(highHRBpm: 120,
                                               lowSpO2Percent: 90,
                                               elevatedHRBpm: 100)
        let oldInactiveRun = [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6),
                              hr(106, 1, 9), hr(112, 1, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: [hr(130, 2)],
            spo2: [SpO2Reading(percent: 85, time: at(2))],
            inactiveHR: oldInactiveRun,
            thresholds: thresholds,
            lastFired: [.highHR: at(3), .lowSpO2: at(3), .elevatedHRInactive: at(3)])

        XCTAssertTrue(hits.isEmpty, "old threshold crossings must not replay after the backoff expires")
    }

    func testEvaluateAllowsFreshInactiveRunAfterLastFired() {
        let thresholds = HealthAlertThresholds(highHREnabled: false,
                                               lowSpO2Enabled: false,
                                               elevatedHRBpm: 100)
        let freshRun = [hr(105, 4, 0), hr(108, 4, 3), hr(110, 4, 6),
                        hr(106, 4, 9), hr(112, 4, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: [],
            spo2: [],
            inactiveHR: freshRun,
            thresholds: thresholds,
            lastFired: [.elevatedHRInactive: at(3)])

        XCTAssertEqual(hits.map(\.notification), [.elevatedHRInactive])
        XCTAssertEqual(hits.first?.value, 112)
    }

    // MARK: Background-drain latency (30–60 min old timestamps) — de-dupe is the ONLY gate

    func testDrainLatencyOldHighHRCrossingFiresOnFirstSight() {
        // All-day HR arrives via an ~hourly background drain: the phone evaluates ONCE, right after
        // the drain, and the crossing's device timestamp is already ~45 min old on arrival. With the
        // 30-min device-timestamp freshness window removed, a not-yet-fired crossing must still alert
        // once — otherwise every legitimate background high-HR event in the older half of a drain is
        // permanently silenced.
        let thresholds = HealthAlertThresholds(highHRBpm: 120,
                                               lowSpO2Enabled: false,
                                               elevatedHREnabled: false)
        let hits = HealthAlertEvaluator.evaluate(
            hr: [hr(145, 9, 15)],   // ~45 min before the post-drain evaluation at ~10:00
            spo2: [],
            inactiveHR: [],
            thresholds: thresholds,
            lastFired: [:])
        XCTAssertEqual(hits.map(\.notification), [.highHR])
        XCTAssertEqual(hits.first?.value, 145)
    }

    func testDrainLatencyOldSustainedRunFiresOnFirstSight() {
        // A sustained elevated-while-inactive run whose 10-min completion is ~40 min old on arrival.
        // The previous 40-min fetch window collapsed the 24h lookback to now-40min and silenced
        // exactly this run; over the restored wide window it must alert once.
        let thresholds = HealthAlertThresholds(highHREnabled: false,
                                               lowSpO2Enabled: false,
                                               elevatedHRBpm: 100,
                                               elevatedSustained: 10 * 60)
        let run = [hr(105, 9, 0), hr(108, 9, 3), hr(110, 9, 6), hr(106, 9, 9), hr(112, 9, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: [],
            spo2: [],
            inactiveHR: run,
            thresholds: thresholds,
            lastFired: [:])
        XCTAssertEqual(hits.map(\.notification), [.elevatedHRInactive])
        XCTAssertEqual(hits.first?.value, 112)
    }

    func testDrainLatencyFiredCrossingDoesNotReplayOnNextDrain() {
        // Once a crossing has fired (its time recorded in `lastFired`), the next hourly drain
        // re-delivers the SAME hours-old samples. The per-notification `lastFired` filter — now the
        // entire stale-replay guard — must drop them so they don't post a second phone alert.
        let thresholds = HealthAlertThresholds(highHRBpm: 120,
                                               lowSpO2Enabled: false,
                                               elevatedHRBpm: 100,
                                               elevatedSustained: 10 * 60)
        let redeliveredHigh = [hr(145, 9, 15)]
        let redeliveredRun = [hr(105, 9, 0), hr(108, 9, 3), hr(110, 9, 6),
                              hr(106, 9, 9), hr(112, 9, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: redeliveredHigh,
            spo2: [],
            inactiveHR: redeliveredRun,
            thresholds: thresholds,
            lastFired: [.highHR: at(9, 15), .elevatedHRInactive: at(9, 12)])
        XCTAssertTrue(hits.isEmpty, "already-fired crossings must not replay on the next drain")
    }

    // MARK: #144 activity gate (nonExercising)

    func testNonExercisingDropsHROverlappingSteps() {
        // A high HR concurrent with a stepping window is dropped; a high HR in a still window survives.
        let stepping = (at(10, 0), at(10, 20))          // 20-min walk
        let series = [hr(165, 10, 10),                  // during the walk → excluded
                      hr(122, 14, 0)]                   // still period → kept
        let filtered = HealthAlertEvaluator.nonExercising(series, activeIntervals: [stepping], pad: 10 * 60)
        XCTAssertEqual(filtered.map(\.bpm), [122])
    }

    func testNonExercisingExcludesRecoveryTail() {
        // A crossing within the `pad` recovery tail AFTER the walk ends is still excluded…
        let stepping = (at(10, 0), at(10, 20))
        let inTail = [hr(150, 10, 25)]                  // 5 min after the walk, inside the 10-min pad
        XCTAssertTrue(HealthAlertEvaluator.nonExercising(inTail, activeIntervals: [stepping], pad: 10 * 60).isEmpty)
        // …but beyond the pad it survives (recovery is over).
        let afterTail = [hr(150, 10, 35)]               // 15 min after → outside the 10-min pad
        XCTAssertEqual(HealthAlertEvaluator.nonExercising(afterTail, activeIntervals: [stepping], pad: 10 * 60).count, 1)
    }

    func testNonExercisingNoStepDataSuppressesNothing() {
        // Missing step data must NEVER silence a real crossing — empty intervals returns the series as-is.
        let series = [hr(165, 10, 10), hr(122, 14, 0)]
        XCTAssertEqual(HealthAlertEvaluator.nonExercising(series, activeIntervals: [], pad: 10 * 60), series)
    }

    func testNonExercisingGatedEvaluateOnlyAlertsStillCrossing() {
        // End-to-end: gate a mixed series then evaluate. The exercising 165 bpm is suppressed while the
        // still-period resting crossing (128 bpm, no concurrent steps) still fires exactly once (#144).
        let thresholds = HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
        let stepping = (at(10, 0), at(10, 20))
        let mixed = [hr(165, 10, 10),                   // exercising → suppressed
                     hr(128, 14, 0)]                    // resting crossing → alerts
        let gated = HealthAlertEvaluator.nonExercising(mixed, activeIntervals: [stepping])
        let hits = HealthAlertEvaluator.evaluate(hr: gated, spo2: [], inactiveHR: gated, thresholds: thresholds)
        XCTAssertEqual(hits.map(\.notification), [.highHR])
        XCTAssertEqual(hits.first?.value, 128)
    }

    // MARK: #144 activeStepIntervals — the production step-source path + day-wide fallback guard

    func testActiveStepIntervalsKeepsNarrowNonzeroWindows() {
        // A normal per-reading window (a few minutes, nonzero delta) becomes a gate interval.
        let w = [StepWindow(start: at(10, 0), end: at(10, 3), delta: 40)]
        let intervals = HealthAlertEvaluator.activeStepIntervals(w)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.0, at(10, 0))
        XCTAssertEqual(intervals.first?.1, at(10, 3))
    }

    func testActiveStepIntervalsDropsZeroDeltaWindow() {
        let w = [StepWindow(start: at(10, 0), end: at(10, 3), delta: 0)]
        XCTAssertTrue(HealthAlertEvaluator.activeStepIntervals(w).isEmpty)
    }

    func testActiveStepIntervalsExcludesDayWideFallbackWindow() {
        // SAFETY GUARD: a fresh-baseline / rollover reading records a day-wide [startOfDay, sampleDate]
        // window. It MUST NOT become a gate interval — otherwise it blankets the whole day.
        let dayWide = [StepWindow(start: at(0, 0), end: at(10, 15), delta: 900)]   // 10h15m fallback
        XCTAssertTrue(HealthAlertEvaluator.activeStepIntervals(dayWide).isEmpty,
                      "day-wide fallback window must not become a gate interval")
        // The boundary: a window exactly at the cap is kept; just over it is dropped.
        let atCap  = [StepWindow(start: at(10, 0), end: at(10, 30), delta: 5)]     // == 30 min
        let overCap = [StepWindow(start: at(10, 0), end: at(10, 31), delta: 5)]    // 31 min
        XCTAssertEqual(HealthAlertEvaluator.activeStepIntervals(atCap).count, 1)
        XCTAssertTrue(HealthAlertEvaluator.activeStepIntervals(overCap).isEmpty)
    }

    func testDayWideFallbackWindowCannotSuppressGenuineCrossing() {
        // End-to-end safety: a resting crossing at 08:30 (no narrow activity) must STILL fire even
        // when a day-wide fallback step window [00:00, 10:15] is present — the guard drops that window
        // so it can't blanket-suppress the morning (the catastrophic false-negative this guards).
        let thresholds = HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
        let steps = [StepWindow(start: at(0, 0), end: at(10, 15), delta: 900)]     // day-wide fallback only
        let intervals = HealthAlertEvaluator.activeStepIntervals(steps)
        let crossing = [hr(150, 8, 30)]                                            // resting, no concurrent steps
        let gated = HealthAlertEvaluator.nonExercising(crossing, activeIntervals: intervals)
        let hits = HealthAlertEvaluator.evaluate(hr: gated, spo2: [], inactiveHR: gated, thresholds: thresholds)
        XCTAssertEqual(hits.map(\.notification), [.highHR],
                       "a day-wide fallback window must never silence a real crossing")
    }

    func testNarrowWindowGateEngagesOnRealStepData() {
        // The gate DOES engage on real narrow windows (proving it's not a no-op): 165 bpm concurrent
        // with a 3-min stepping window is suppressed, while a resting 128 bpm in a still period fires.
        let thresholds = HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
        let steps = [StepWindow(start: at(10, 0), end: at(10, 3), delta: 60)]
        let intervals = HealthAlertEvaluator.activeStepIntervals(steps)
        let mixed = [hr(165, 10, 1),   // exercising → suppressed
                     hr(128, 14, 0)]   // resting crossing → alerts
        let gated = HealthAlertEvaluator.nonExercising(mixed, activeIntervals: intervals)
        let hits = HealthAlertEvaluator.evaluate(hr: gated, spo2: [], inactiveHR: gated, thresholds: thresholds)
        XCTAssertEqual(hits.map(\.notification), [.highHR])
        XCTAssertEqual(hits.first?.value, 128)
    }

    // MARK: #137 bedtime reminder bypasses the quiet-hours gate (caller-side split)

    func testBedtimeReminderBypassesQuietHoursWhileVitalsStayMuted() {
        // Reproduces the `evaluateReminders` split: `now` is 22:45 — inside BOTH the default
        // 22:00–07:00 quiet window AND a typical [22:30, 23:00) bedtime window. A body-vital alert
        // stays muted (no regression), while the bedtime reminder — gated with quiet DISABLED —
        // survives, and the anti-spam backoff still de-dupes it so it fires at most once per night.
        let gate = NotificationGate()
        let quiet = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        let now = at(22, 45)
        // Body-vital alert: still suppressed during quiet hours.
        XCTAssertTrue(gate.filter([.highHR], now: now, lastFired: [:], quietHours: quiet).isEmpty)
        // Bedtime reminder: gated with quiet disabled → fires even though `now` is inside quiet hours.
        XCTAssertEqual(gate.filter([.bedtimeReminder], now: now, lastFired: [:],
                                   quietHours: QuietHours(enabled: false)), [.bedtimeReminder])
        // Backoff still applies: a second eval later in the same window is suppressed (fires once/night).
        XCTAssertTrue(gate.filter([.bedtimeReminder], now: at(22, 50),
                                  lastFired: [.bedtimeReminder: now],
                                  quietHours: QuietHours(enabled: false)).isEmpty)
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
        let night = TempFeverNotifications.dayKey(for: at(3), calendar: cal)   // this overnight's summary
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
        let lastNightDate = cal.startOfDay(for: at(3))
        let lastNight = TempFeverNotifications.dayKey(for: lastNightDate, calendar: cal)
        let newerNight = TempFeverNotifications.dayKey(
            for: cal.date(byAdding: .day, value: 1, to: lastNightDate)!, calendar: cal)
        let fresh = TempFeverNotifications.freshForNight(
            [.skinTempFluctuationDrop], night: newerNight,
            lastNotifiedNight: [.skinTempFluctuationDrop: lastNight])
        XCTAssertEqual(fresh, [.skinTempFluctuationDrop], "a new night's summary re-arms the alert")
        // A stale (older) recompute of a night we've moved past must not re-fire.
        XCTAssertTrue(TempFeverNotifications.freshForNight(
            [.skinTempFluctuationDrop], night: lastNight,
            lastNotifiedNight: [.skinTempFluctuationDrop: newerNight]).isEmpty)
    }

    func testDayKeyIsTimezoneStableAcrossWestwardTravel() {
        // The SAME night instant, keyed after westward travel (offset decreasing) between two syncs.
        // The old ledger stored `startOfDay(...).timeIntervalSince1970`, whose instant shifts later
        // under that travel and re-fires the duplicate; the yyyymmdd day key must stay put.
        var east = Calendar(identifier: .gregorian)
        east.timeZone = TimeZone(identifier: "America/New_York")!    // UTC-4 in June
        var west = Calendar(identifier: .gregorian)
        west.timeZone = TimeZone(identifier: "America/Los_Angeles")! // UTC-7 in June
        // 2026-06-17 12:00 UTC → 08:00 in ET, 05:00 in PT: same calendar day in both zones.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let night = utc.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12))!
        XCTAssertEqual(TempFeverNotifications.dayKey(for: night, calendar: east),
                       TempFeverNotifications.dayKey(for: night, calendar: west),
                       "day key must be stable across timezone shifts of the same night")
        // Sanity: the discarded start-of-day instants really do differ across the two zones.
        XCTAssertNotEqual(east.startOfDay(for: night), west.startOfDay(for: night))
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
