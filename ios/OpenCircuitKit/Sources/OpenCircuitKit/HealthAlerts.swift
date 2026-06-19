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

/// One fired alert with the reading that triggered it (for the "… detected at [time]" copy).
public struct HealthAlertHit: Equatable, Sendable {
    public let notification: HealthNotification
    public let value: Double   // bpm for HR alerts, percent for SpO2
    public let time: Date
    public init(notification: HealthNotification, value: Double, time: Date) {
        self.notification = notification; self.value = value; self.time = time
    }
}

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

    /// Evaluate all three #73 rules and return the hits (disabled rules are skipped). `inactiveHR`
    /// is the HR series for the sustained-while-inactive rule; the instantaneous rules use `hr`.
    public static func evaluate(hr: [HRSample], spo2: [SpO2Reading], inactiveHR: [HRSample],
                                thresholds: HealthAlertThresholds) -> [HealthAlertHit] {
        var hits: [HealthAlertHit] = []
        if thresholds.highHREnabled, let s = highHR(hr, thresholdBpm: thresholds.highHRBpm) {
            hits.append(HealthAlertHit(notification: .highHR, value: Double(s.bpm), time: s.start))
        }
        if thresholds.lowSpO2Enabled, let s = lowSpO2(spo2, thresholdPercent: thresholds.lowSpO2Percent) {
            hits.append(HealthAlertHit(notification: .lowSpO2, value: Double(s.percent), time: s.time))
        }
        if thresholds.elevatedHREnabled,
           let s = elevatedHRInactive(inactiveHR, thresholdBpm: thresholds.elevatedHRBpm,
                                      minDuration: thresholds.elevatedSustained,
                                      maxGap: thresholds.elevatedMaxGap) {
            hits.append(HealthAlertHit(notification: .elevatedHRInactive, value: Double(s.bpm), time: s.start))
        }
        return hits
    }
}

// MARK: - #85 routing (temp flags + fever → notifications)

public enum TempFeverNotifications {
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
}
