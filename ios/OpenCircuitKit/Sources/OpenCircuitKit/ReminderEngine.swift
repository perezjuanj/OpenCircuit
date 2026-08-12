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

/// Fire when the ring appears to be OFF THE FINGER. Opt-in (default off) — never fires before the
/// first connection (`everConnected = false`).
///
/// ══ SILENCE IS NOT EVIDENCE OF NOT-WEARING ══
///
/// 🟢 A tester reported "alerts that the ring is not detected even though I am wearing it… once or
/// twice a day, and overnight" (2026-08-12). Their diagnostics bundle shows why: the sync activity
/// log is dominated by `session replaced — no drain ran` and the epoch archive carries multi-hour
/// holes — the BLE LINK drops routinely while the ring keeps recording perfectly well on the
/// finger, and the backlog lands on the next successful drain. The old predicate ("no frame in
/// 20 min") measured the health of OUR CONNECTION and reported it to the user as a fact about
/// their ring. It is wrong for exactly the population it fires on hardest — the users whose link is
/// flakiest — and the user can do nothing about it, which is the definition of a bad alert.
///
/// So silence is now only ONE necessary condition. Three suppressions carry the actual evidence:
///
///  1. `isConnected` — a live link with a quiet notify pipe means the ring is right there. Whatever
///     is wrong, "put your ring back on" is the wrong instruction.
///  2. `lastWornEvidenceAt` — the newest DEVICE timestamp we hold for an epoch the ring recorded
///     while WORN (an epoch carrying a heart rate; the unworn template decodes no HR at all — see
///     `BulkRecord.Layout.idle`). This arrives late by design, on the drain that heals the gap, and
///     it is retro-active proof that the silent window was worn. Only silence NEWER than that proof
///     can still be a genuine take-off.
///  3. `inSleepWindow` — the tester got this at night. Nobody acts on a wear nag while asleep, and
///     the overnight link is the least reliable of all; a nag here is pure cost.
///
/// The default interval is also an hour rather than 20 minutes: a background drain cadence measured
/// in tens of minutes made 20 min indistinguishable from a normal quiet stretch.
public struct WearReminder: Equatable, Sendable {
    /// Gap without ring data that triggers the reminder.
    public var noDataInterval: TimeInterval

    public init(noDataInterval: TimeInterval = 60 * 60) {
        self.noDataInterval = noDataInterval
    }

    /// True when the ring looks genuinely un-worn: nothing has arrived for ≥ `noDataInterval`, we
    /// are not currently connected, we are not inside the user's sleep window, and no drained epoch
    /// proves the ring was on the finger during the silence.
    ///
    /// - Parameters:
    ///   - lastRingDataAt: newest moment ANY frame arrived (wall-clock), or nil.
    ///   - everConnected: a ring has been paired at least once. nil-safe gate, unchanged.
    ///   - lastWornEvidenceAt: newest DEVICE timestamp of an epoch recorded while worn, or nil when
    ///     we hold none. Deliberately compared against `now`, not against `lastRingDataAt`: it is
    ///     proof about the RING'S OWN timeline, so it must age out on the same clock the silence does.
    ///   - isConnected: a ring is connected right now.
    ///   - inSleepWindow: `now` falls inside the user's configured sleep schedule.
    public func shouldFire(lastRingDataAt: Date?, now: Date, everConnected: Bool,
                           lastWornEvidenceAt: Date? = nil,
                           isConnected: Bool = false,
                           inSleepWindow: Bool = false) -> Bool {
        guard everConnected, !isConnected, !inSleepWindow else { return false }
        // Positive proof the ring was worn recently outranks the absence of frames. A worn epoch
        // dated within `noDataInterval` of now means the ring was on the finger for the very
        // stretch the silence rule is about to complain about.
        if let worn = lastWornEvidenceAt, now.timeIntervalSince(worn) < noDataInterval {
            return false
        }
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
