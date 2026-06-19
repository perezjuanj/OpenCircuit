// Pure reminder-firing predicates (#84). Three kinds: sedentary/move, ring-not-worn,
// and bedtime wind-down. All logic is side-effect-free — callers route survivors through
// the shared `NotificationGate` (DND + backoff) in `HealthNotificationCenter`.
//
// "Activity" for the sedentary rule is a nonzero step delta from the ring. The caller
// supplies `lastActivityAt` (from UserDefaults). nil → false (never a cold-launch nag).

import Foundation

// MARK: - Reminder kinds

/// Stable identifiers for each reminder type. The raw value is used as the
/// `UNUserNotificationRequest` identifier AND as the de-dupe key in the shared
/// `HealthNotificationStore` — must stay stable across launches.
public enum ReminderKind: String, CaseIterable, Sendable {
    case sedentary = "reminder.sedentary"
    case wear      = "reminder.wear"
    case bedtime   = "reminder.bedtime"
}

// MARK: - Sedentary / move reminder

/// Fire if the user has been physically inactive for longer than `interval` and we're
/// inside the daily active window. "Activity" = a nonzero step delta from the ring;
/// `lastActivityAt` is nil until the first step arrives so the rule stays silent on a
/// fresh session / day the ring isn't worn (never a false positive).
public struct SedentaryReminder: Equatable, Sendable {
    /// Inactivity threshold before firing.
    public var interval: TimeInterval
    /// Minutes-since-midnight window within which the reminder may fire. Default 08:00–21:00.
    public var activeStartMinutes: Int
    public var activeEndMinutes: Int

    public init(interval: TimeInterval = 50 * 60,
                activeStartMinutes: Int = 8 * 60,
                activeEndMinutes: Int = 21 * 60) {
        self.interval = interval
        self.activeStartMinutes = activeStartMinutes
        self.activeEndMinutes = activeEndMinutes
    }

    /// True when inactive for ≥ `interval` AND inside the active window.
    public func shouldFire(lastActivityAt: Date?, now: Date,
                           calendar: Calendar = .current) -> Bool {
        guard let last = lastActivityAt else { return false }
        guard now.timeIntervalSince(last) >= interval else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m >= activeStartMinutes && m < activeEndMinutes
    }
}

// MARK: - Wear reminder

/// Fire if we have ever connected to the ring but ring data has gone silent for
/// longer than `noDataInterval`. Opt-in (default off) — never fires before the first
/// connection (`everConnected = false`).
public struct WearReminder: Equatable, Sendable {
    /// Gap without ring data that triggers the reminder.
    public var noDataInterval: TimeInterval

    public init(noDataInterval: TimeInterval = 20 * 60) {
        self.noDataInterval = noDataInterval
    }

    /// True when data from the ring has been absent for ≥ `noDataInterval` and the ring
    /// has been connected at least once in this session.
    public func shouldFire(lastRingDataAt: Date?, now: Date, everConnected: Bool) -> Bool {
        guard everConnected else { return false }
        guard let last = lastRingDataAt else { return true }   // ever connected but no data
        return now.timeIntervalSince(last) >= noDataInterval
    }
}

// MARK: - Bedtime reminder

/// Fire once inside the window [bedMinutes − minutesBefore, bedMinutes) to give the
/// user a heads-up before their configured bedtime. The window is in minutes-since-
/// midnight and wraps past midnight correctly. Returns false when bed == wake (schedule
/// not configured), matching `SleepWindow`'s convention.
public struct BedtimeReminder: Equatable, Sendable {
    /// How many minutes before the bedtime the window opens.
    public var minutesBefore: Int

    public init(minutesBefore: Int = 30) {
        self.minutesBefore = minutesBefore
    }

    /// True when the current time-of-day falls inside [bed − minutesBefore, bed).
    public func shouldFire(now: Date, bedMinutes: Int, wakeMinutes: Int,
                           calendar: Calendar = .current) -> Bool {
        guard bedMinutes != wakeMinutes else { return false }   // not configured
        let windowStart = (bedMinutes - minutesBefore + 1440) % 1440
        let windowEnd   = bedMinutes
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minuteInWindow(m, start: windowStart, end: windowEnd)
    }

    private func minuteInWindow(_ m: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        if start < end  { return m >= start && m < end }
        return m >= start || m < end   // wraps past midnight
    }
}
