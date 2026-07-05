// Local health-alert policy — the PURE decision layer shared by the high-HR / low-SpO2 /
// elevated-HR-while-inactive alerts (#73) AND the skin-temp / fever notifications (#85).
//
// The ring has NO vibration motor, so every alert is a phone notification (pp.txt:46223
// "App can receive the following notifications only when connected to the ring"). This file
// holds only the THRESHOLD + DE-DUPE + DND (quiet-hours) math — no Apple frameworks — so it
// unit-tests on the CLI. The `UNUserNotificationCenter` glue + UserDefaults persistence live
// in the app target (HealthNotificationCenter.swift), which routes BOTH tickets through this
// ONE engine (a single quiet-hours window, a single de-dupe namespace).
//
// Thresholds are user-configurable with sensible defaults — never a hardcoded reading of a
// person's data. Evidence: `highHrRemind`/`highHrRemindEnable`, `keyHeartRateReminderValue`;
// `lowSpo2Value`, `keyLowSpO2Detected` (SpO2 severity ≥95 / 90-95 / 75-90 / <75); 10-min
// sustained-while-non-exercising HR trigger (pp.txt:45915). Fever (0x14) + the four skin-temp
// flags (0x10–0x13) come from `SkinTempBaseline` (#69) and `VitalsBaseline` (#72).

import Foundation

/// Every user-facing health notification, across #73 (HR/SpO2), #85 (temp/fever),
/// #84 (reminders), and #86 (charging complete). One enum = one de-dupe namespace,
/// so the same condition can't re-fire from two code paths.
public enum HealthNotification: String, CaseIterable, Codable, Sendable {
    // #73 — heart rate & blood oxygen
    case highHR
    case lowSpO2
    case elevatedHRInactive
    // #85 — skin temperature (the four SkinTempBaseline flags) + fever
    case skinTempRise            // 0x12 skinTempAbnormalRise
    case skinTempDrop            // 0x13 skinTempAbnormalDrop
    case skinTempFluctuationRise // 0x10 skinTempFluctuationRise
    case skinTempFluctuationDrop // 0x11 skinTempFluctuationDrop
    case fever                   // 0x14 feverAbnormal (HR + temp cross-reference, #72)
    // #84 — app-side reminders
    case sedentaryReminder = "reminder.sedentary"
    case wearReminder      = "reminder.wear"
    case bedtimeReminder   = "reminder.bedtime"
    // #86 — battery charging complete
    case chargingComplete  = "battery.chargingComplete"
}

// MARK: - Quiet hours (shared DND window)

/// A single nightly quiet-hours window, shared by every alert. Minutes are since-midnight (the
/// same timezone-free convention as `SleepWindow`), so a window may wrap past midnight.
public struct QuietHours: Equatable, Sendable {
    public var enabled: Bool
    public var startMinutes: Int
    public var endMinutes: Int

    public init(enabled: Bool = false, startMinutes: Int = 22 * 60, endMinutes: Int = 7 * 60) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    /// Whether `date` falls inside the quiet window. Disabled ⇒ never. Handles a window that wraps
    /// past midnight (e.g. 22:00 → 07:00). A zero-length window (start == end) is treated as empty.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinutes != endMinutes else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if startMinutes < endMinutes {           // same-day window
            return m >= startMinutes && m < endMinutes
        }
        return m >= startMinutes || m < endMinutes // wraps past midnight
    }
}

// MARK: - De-dupe / DND gate

/// Decides whether a notification may fire NOW given quiet hours + an anti-spam backoff. Pure so
/// the routing is fully testable; the app persists `lastFired` and posts the survivors.
public struct NotificationGate: Equatable, Sendable {
    /// Minimum spacing between repeats of the SAME notification (anti-spam backoff).
    public var renotifyInterval: TimeInterval
    public init(renotifyInterval: TimeInterval = 2 * 3600) {
        self.renotifyInterval = renotifyInterval
    }

    public func shouldFire(_ n: HealthNotification, now: Date,
                           lastFired: [HealthNotification: Date],
                           quietHours: QuietHours, calendar: Calendar = .current) -> Bool {
        if quietHours.contains(now, calendar: calendar) { return false }
        if let fired = lastFired[n], now.timeIntervalSince(fired) < renotifyInterval { return false }
        return true
    }

    /// The subset of `candidates` allowed to fire now, in stable `HealthNotification.allCases` order.
    public func filter(_ candidates: [HealthNotification], now: Date,
                       lastFired: [HealthNotification: Date],
                       quietHours: QuietHours, calendar: Calendar = .current) -> [HealthNotification] {
        let set = Set(candidates)
        return HealthNotification.allCases.filter {
            set.contains($0) && shouldFire($0, now: now, lastFired: lastFired,
                                           quietHours: quietHours, calendar: calendar)
        }
    }
}

// MARK: - #73 thresholds + evaluator

/// One blood-oxygen reading (percent) with its time. SpO2 is stored as a 0…1 fraction elsewhere;
/// callers convert to whole percent so the threshold reads in the same units the user configures.
public struct SpO2Reading: Equatable, Sendable {
    public let percent: Int
    public let time: Date
    public init(percent: Int, time: Date) { self.percent = percent; self.time = time }
}

/// User-configurable thresholds for the HR/SpO2 alerts (#73). Defaults are conservative and
/// documented; each rule has its own enable flag so a user can opt out per-rule.
public struct HealthAlertThresholds: Equatable, Sendable {
    public var highHREnabled: Bool
    public var highHRBpm: Int
    public var lowSpO2Enabled: Bool
    public var lowSpO2Percent: Int
    public var elevatedHREnabled: Bool
    public var elevatedHRBpm: Int
    public var elevatedSustained: TimeInterval
    /// Max gap between consecutive readings still counted as one continuous elevated run (so a
    /// lone spike hours apart isn't "sustained").
    public var elevatedMaxGap: TimeInterval

    public init(highHREnabled: Bool = true,
                highHRBpm: Int = 120,
                lowSpO2Enabled: Bool = true,
                lowSpO2Percent: Int = 90,
                elevatedHREnabled: Bool = true,
                elevatedHRBpm: Int = 100,
                elevatedSustained: TimeInterval = 10 * 60,
                elevatedMaxGap: TimeInterval = 5 * 60) {
        self.highHREnabled = highHREnabled
        self.highHRBpm = highHRBpm
        self.lowSpO2Enabled = lowSpO2Enabled
        self.lowSpO2Percent = lowSpO2Percent
        self.elevatedHREnabled = elevatedHREnabled
        self.elevatedHRBpm = elevatedHRBpm
        self.elevatedSustained = elevatedSustained
        self.elevatedMaxGap = elevatedMaxGap
    }
}

/// One step-count snapshot's observation window + delta, carrying the device's own timestamps.
/// A pure value type so the #144 activity-gate math is testable off the app's SwiftData
/// `StoredStepSample` model (which is app-target-only). The app maps each `StoredStepSample` to one
/// of these before handing them to `activeStepIntervals`.
public struct StepWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let delta: Int
    public init(start: Date, end: Date, delta: Int) {
        self.start = start; self.end = end; self.delta = delta
    }
}

/// One fired alert with the reading that triggered it (for the "… detected at [time]" copy).
public struct HealthAlertHit: Equatable, Sendable {
    public let notification: HealthNotification
    public let value: Double   // bpm for HR alerts, percent for SpO2
    public let time: Date
    public init(notification: HealthNotification, value: Double, time: Date) {
        self.notification = notification; self.value = value; self.time = time
    }
}

// NOTE: HR alerts intentionally have NO device-timestamp "freshness" gate. All-day HR reaches the
// phone via ~hourly background drains whose device timestamps are routinely 30–60+ min old on
// arrival, evaluated ONCE right after each drain; a freshness window would permanently silence the
// older half of every drain. De-dupe is done here by the per-notification `lastFired` filter in
// `evaluate` (a crossing fires once on first sight and never replays), not by the sample's age.

public enum HealthAlertEvaluator {

    /// The worst (highest) HR reading at/above the threshold, or nil. "High heart rate detected at
    /// [time]" (pp.txt:48405) — an instantaneous crossing.
    public static func highHR(_ samples: [HRSample], thresholdBpm: Int) -> HRSample? {
        samples.filter { $0.bpm >= thresholdBpm }.max { $0.bpm < $1.bpm }
    }

    /// The worst (lowest) SpO2 reading at/below the threshold, or nil. "Low blood oxygen detected
    /// at [time]" (pp.txt:48398).
    public static func lowSpO2(_ readings: [SpO2Reading], thresholdPercent: Int) -> SpO2Reading? {
        readings.filter { $0.percent > 0 && $0.percent <= thresholdPercent }.min { $0.percent < $1.percent }
    }

    /// The reading that COMPLETES a continuous run of HR ≥ threshold spanning ≥ `minDuration`,
    /// or nil. Mirrors the APK's "HR exceeds the set maximum for a continuous 10 minutes while in a
    /// non-exercising state" (pp.txt:45915). The caller is responsible for passing only inactive /
    /// non-exercising samples (#61 sharpens that gate); the sustained-window math is here.
    public static func elevatedHRInactive(_ samples: [HRSample], thresholdBpm: Int,
                                          minDuration: TimeInterval,
                                          maxGap: TimeInterval = 5 * 60) -> HRSample? {
        let sorted = samples.sorted { $0.start < $1.start }
        var runStart: Date?
        var prev: Date?
        for s in sorted {
            guard s.bpm >= thresholdBpm else { runStart = nil; prev = nil; continue }
            if let p = prev, s.start.timeIntervalSince(p) > maxGap {
                runStart = s.start            // gap too big — start a fresh run here
            } else if runStart == nil {
                runStart = s.start
            }
            prev = s.start
            if let rs = runStart, s.start.timeIntervalSince(rs) >= minDuration { return s }
        }
        return nil
    }

    /// Default cap on a step snapshot's window width still treated as a discrete activity burst
    /// (#144). Normal per-reading step windows are the gap between two step readings — seconds on the
    /// live poll, up to a few minutes across a background drain — comfortably under this. A window
    /// WIDER than this is the day-wide `[startOfDay, sampleDate]` FALLBACK that `StoredStepSample`
    /// records on a fresh baseline / day rollover (no prior same-day reading to anchor to); those run
    /// to multiple hours and must be excluded from the gate (see `activeStepIntervals`). Chosen short
    /// on purpose: it cleanly excludes every hours-long fallback, and erring short only risks
    /// under-gating (an occasional post-workout false alarm) — never the catastrophic direction of
    /// suppressing a real cardiac crossing.
    public static let maxActivityWindow: TimeInterval = 30 * 60

    /// Build the concurrent-activity intervals for the HR gate (#144) from step snapshots, dropping:
    ///  - zero/negative-`delta` windows (no actual movement), and
    ///  - windows WIDER than `maxActivityWindow` — the day-wide `[startOfDay, sampleDate]` FALLBACK
    ///    `StoredStepSample` records on a fresh baseline / day rollover. This exclusion is
    ///    SAFETY-CRITICAL: feeding a multi-hour fallback window into `nonExercising` would suppress
    ///    EVERY HR crossing since midnight — including a genuine resting tachycardia — a health-safety
    ///    false negative, the worst outcome. Excluding it costs at most an occasional missed gate (a
    ///    post-workout false alarm), which is the far safer failure direction.
    public static func activeStepIntervals(_ steps: [StepWindow],
                                           maxActivityWindow: TimeInterval = maxActivityWindow)
    -> [(Date, Date)] {
        steps.filter { $0.delta > 0 && $0.end.timeIntervalSince($0.start) <= maxActivityWindow }
             .map { ($0.start, $0.end) }
    }

    /// Drop HR samples that overlap concurrent step activity (or its `pad`-long recovery tail), so
    /// exercise heart rate can't trip the resting high-HR / elevated-while-inactive alarms (#144).
    /// A sample is EXCLUDED when its device timestamp `start` lies inside any `activeIntervals`
    /// window `[from, to]` — or within `pad` after `to`, covering the post-exercise HR recovery
    /// tail. Match is by the DEVICE timestamps carried on BOTH series (never wall-clock arrival):
    /// all-day HR and steps ride in on the same ~hourly background drains with timestamps 30–60+
    /// min old, so only their device times line up.
    ///
    /// KEY SAFETY PROPERTY: this only ever SUPPRESSES on positive evidence of concurrent activity.
    /// An empty `activeIntervals` (no step data synced for the window) returns the series unchanged,
    /// so a genuine resting tachycardia with no steps still fires and missing step data can never
    /// silence a real alert. It never narrows the lookback window — it filters by activity overlap,
    /// not recency.
    public static func nonExercising(_ hr: [HRSample], activeIntervals: [(Date, Date)],
                                     pad: TimeInterval = 10 * 60) -> [HRSample] {
        guard !activeIntervals.isEmpty else { return hr }
        return hr.filter { sample in
            !activeIntervals.contains { interval in
                sample.start >= interval.0 && sample.start <= interval.1.addingTimeInterval(pad)
            }
        }
    }

    /// Evaluate all three #73 rules and return the hits (disabled rules are skipped). `inactiveHR`
    /// is the HR series for the sustained-while-inactive rule; the instantaneous rules use `hr`.
    public static func evaluate(hr: [HRSample], spo2: [SpO2Reading], inactiveHR: [HRSample],
                                thresholds: HealthAlertThresholds,
                                lastFired: [HealthNotification: Date] = [:]) -> [HealthAlertHit] {
        var hits: [HealthAlertHit] = []
        let freshHR = hr.filter { $0.start > (lastFired[.highHR] ?? .distantPast) }
        let freshSpO2 = spo2.filter { $0.time > (lastFired[.lowSpO2] ?? .distantPast) }
        let freshInactiveHR = inactiveHR.filter {
            $0.start > (lastFired[.elevatedHRInactive] ?? .distantPast)
        }

        if thresholds.highHREnabled, let s = highHR(freshHR, thresholdBpm: thresholds.highHRBpm) {
            hits.append(HealthAlertHit(notification: .highHR, value: Double(s.bpm), time: s.start))
        }
        if thresholds.lowSpO2Enabled, let s = lowSpO2(freshSpO2, thresholdPercent: thresholds.lowSpO2Percent) {
            hits.append(HealthAlertHit(notification: .lowSpO2, value: Double(s.percent), time: s.time))
        }
        if thresholds.elevatedHREnabled,
           let s = elevatedHRInactive(freshInactiveHR, thresholdBpm: thresholds.elevatedHRBpm,
                                      minDuration: thresholds.elevatedSustained,
                                      maxGap: thresholds.elevatedMaxGap) {
            hits.append(HealthAlertHit(notification: .elevatedHRInactive, value: Double(s.bpm), time: s.start))
        }
        return hits
    }
}

// MARK: - #85 routing (temp flags + fever → notifications)

public enum TempFeverNotifications {
    /// The #85 skin-temp/fever notifications — the ones that de-dupe per night. Single source of
    /// truth so every classifier (`notifications` routing, the app-side `isTempFever` filter, and
    /// the disclaimer logic) stays in lock-step; adding a skin-temp case means adding it here once.
    public static let notificationSet: Set<HealthNotification> = [
        .skinTempRise, .skinTempDrop, .skinTempFluctuationRise, .skinTempFluctuationDrop, .fever,
    ]

    /// Timezone-stable `yyyymmdd` day key for a night's start-of-day. Used as the per-night ledger
    /// key instead of a raw instant: an instant (`timeIntervalSince1970`) shifts under westward
    /// travel between two syncs of the same night, which could re-fire the duplicate; the calendar
    /// day components do not.
    public static func dayKey(for night: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: night)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// Map the four `SkinTempBaseline` anomaly flags (#69) + the suspected-fever flag (#72) to the
    /// notifications they should raise. Pure flag→notification routing; the de-dupe/DND gate and
    /// posting happen in the shared app-side center. (#85)
    public static func notifications(flags: SkinTempBaseline.AnomalyFlags,
                                     feverSuspected: Bool) -> [HealthNotification] {
        var out: [HealthNotification] = []
        if flags.abnormalRise { out.append(.skinTempRise) }
        if flags.abnormalDrop { out.append(.skinTempDrop) }
        if flags.fluctuationRise { out.append(.skinTempFluctuationRise) }
        if flags.fluctuationDrop { out.append(.skinTempFluctuationDrop) }
        if feverSuspected { out.append(.fever) }
        return out
    }

    /// Per-NIGHT de-dupe for the skin-temp/fever notifications. Each of these flags pertains to ONE
    /// overnight summary, so once we've notified for a given night it must NOT re-fire on later
    /// syncs of the same night — the 2h anti-spam backoff alone would re-raise the same night's flag
    /// every couple hours all day (the user sees the same "skin temperature dropped" alert after
    /// every sync). Keeps only the flags whose night is strictly newer than the last night already
    /// notified for that flag; a fresh night's summary re-arms it. `night` and the map values are
    /// timezone-stable `yyyymmdd` day keys (see `dayKey(for:)`).
    public static func freshForNight(_ candidates: [HealthNotification], night: Int,
                                     lastNotifiedNight: [HealthNotification: Int]) -> [HealthNotification] {
        candidates.filter { n in
            guard let last = lastNotifiedNight[n] else { return true }
            return night > last
        }
    }
}
