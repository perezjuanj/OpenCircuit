// Vibrating wake-up alarm driven by the Gen 3 motor (`RingVibration`).
//
// ══ READ THIS BEFORE TRUSTING THE ALARM ══
//
// iOS cannot run our code at a wall-clock instant in the background. There is no timer that
// survives suspension, `BGTaskScheduler` is explicitly opportunistic (the system decides when,
// and "when" can be hours off or never), and a delivered local notification does NOT wake the
// app to execute anything. So a ring buzz at exactly 06:30 is not something this platform can
// promise, and no amount of engineering on our side changes that.
//
// What we DO have is `bluetooth-central` background execution plus CoreBluetooth state
// restoration (RingScanner): while the ring is connected, every frame it pushes hands the app a
// slice of runtime in the background. Overnight the ring is heard from regularly, so the design
// is "fire on the first breath of runtime at or after the alarm time", and the honest accuracy
// claim is *bounded by frame cadence*, not by a clock we control.
//
// Two consequences we own rather than hide:
//
//  1. The buzz can be LATE. `grace` bounds how late is still useful — past it the alarm is
//     recorded `.missed` and deliberately NOT delivered, because a wake-up buzz 40 minutes after
//     the user is already up is worse than none. The miss is surfaced, never swallowed.
//  2. The buzz can be MISSED ENTIRELY (ring on the charger, link down, app terminated by the
//     user — a force-quit stops CoreBluetooth relaunch, see the steps-undercount finding). This
//     is exactly why `RingAlarm.backupNotification` exists and defaults ON: a
//     `UNCalendarNotificationTrigger` is scheduled by the OS itself and fires whatever our
//     process is doing. The ring buzz is the nice version; the notification is the one that is
//     actually guaranteed to wake someone.
//
// A native firmware alarm — where the ring keeps its own clock and buzzes with the phone out of
// the picture — would sidestep all of this. We have no evidence one exists: the official app's
// Vibration settings screen lists reminder toggles and a do-not-disturb window and no alarm, and
// `0x0b` is the only motor opcode ever seen on the wire. 🔴 Unknown, not ruled out. If a capture
// ever turns one up, this whole file becomes a scheduling shim over it.
//
// Pure Foundation (no UserNotifications, no CoreBluetooth) so every rule below unit-tests on the CLI.

import Foundation

// MARK: - The alarm

public struct RingAlarm: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Local wall-clock hour, 0–23.
    public var hour: Int
    /// Local wall-clock minute, 0–59.
    public var minute: Int
    /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday) the alarm repeats on.
    /// EMPTY MEANS EVERY DAY — see `repeats(onWeekday:)`. There is no one-shot mode: an alarm you
    /// have to re-arm each night is a worse product than one you switch off.
    public var weekdays: Set<Int>
    public var pattern: VibrationPattern
    /// How many times to buzz, spaced `burstSpacing` apart. One buzz is easy to sleep through.
    public var burstCount: Int
    /// Seconds between bursts.
    public var burstSpacing: TimeInterval
    /// Also schedule an OS-level local notification at the same time. Defaults ON: it is the only
    /// part of this feature the platform actually guarantees (see the header note).
    public var backupNotification: Bool

    public init(isEnabled: Bool = false,
                hour: Int = 7,
                minute: Int = 0,
                weekdays: Set<Int> = [],
                pattern: VibrationPattern = .notification,
                burstCount: Int = 3,
                burstSpacing: TimeInterval = 4,
                backupNotification: Bool = true) {
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.pattern = pattern
        self.burstCount = burstCount
        self.burstSpacing = burstSpacing
        self.backupNotification = backupNotification
    }

    /// Empty `weekdays` = every day. Any other set is taken literally.
    public func repeats(onWeekday weekday: Int) -> Bool {
        weekdays.isEmpty || weekdays.contains(weekday)
    }

    /// Bursts, clamped to something a motor and a sleeping human can both survive.
    public var clampedBurstCount: Int { min(max(burstCount, 1), 10) }
    public var clampedBurstSpacing: TimeInterval { min(max(burstSpacing, 2), 30) }
}

// MARK: - What the scheduler decided, and why

/// The outcome of one evaluation. `.skip` carries a reason so the UI can tell the user what
/// happened instead of leaving them to guess why the ring stayed quiet — a silent alarm with no
/// explanation is the single worst failure this feature has.
public enum RingAlarmDecision: Equatable, Sendable {
    /// Buzz now. `scheduled` is the wall-clock time the alarm was set for; `lateBy` is how far
    /// past it we actually got runtime. Report `lateBy` rather than implying we hit the mark.
    case fire(scheduled: Date, lateBy: TimeInterval)
    /// The alarm's moment passed without us ever getting runtime inside `grace`. Recorded, not
    /// delivered — and worth showing the user, because it means the mechanism failed, not the clock.
    case missed(scheduled: Date)
    /// Nothing to do (disabled, already handled, or the time simply hasn't come).
    case idle
}

/// Why a due alarm was not delivered to the motor. Distinct from `.missed`: these are conditions
/// we can see and explain right now.
public enum RingAlarmBlock: String, Equatable, Sendable {
    case ringOnCharger
    case ringUnsupported
    case linkNotReady
    case ringBusy
}

// MARK: - Scheduling

public enum RingAlarmSchedule {
    /// How late a wake-up buzz is still worth delivering. Past this the alarm is `.missed`.
    ///
    /// 15 minutes is a judgement call, not a measurement: long enough to absorb a quiet overnight
    /// link (the night keepalive is 60 s and the ring's own pushes are intermittent — a couple of
    /// minutes of silence is ordinary), short enough that the buzz still lands inside the window
    /// where being woken is the point.
    public static let defaultGrace: TimeInterval = 15 * 60

    /// How long before the alarm to start holding the link open. See `warmUpTarget`.
    ///
    /// 5 minutes against a ring that pushes something roughly every 2.5 minutes gives us about two
    /// chances to catch an opening — enough to make catching one likely without burning radio for
    /// any longer than the problem needs.
    public static let defaultWarmUp: TimeInterval = 5 * 60

    /// The upcoming occurrence if `now` is inside its warm-up window, else nil.
    ///
    /// ══ WHY A WARM-UP EXISTS ══
    ///
    /// A suspended app cannot start a BLE write — the ring has to hand us the first slice of
    /// runtime, and it does that on its own ~2.5 min beat. That bounds how late the buzz can be if
    /// we simply wait. But once we ARE running, a request/response chain renews itself: every
    /// write we send comes back as a CoreBluetooth callback, and every callback is another slice.
    /// This project already depends on exactly that — the overnight history drain runs to
    /// completion while suspended because its own page acks keep renewing the window.
    ///
    /// So: take the first opening in the last few minutes before the alarm and hold the link from
    /// there through the alarm time, and the buzz goes out in seconds instead of on the ring's
    /// next spontaneous beat. It cannot make the alarm certain — we still need ONE opening inside
    /// the window to start from — but it converts "late by up to the push cadence" into "late by
    /// the poll interval", which is the difference between minutes and seconds.
    public static func warmUpTarget(alarm: RingAlarm,
                                    now: Date,
                                    warmUp: TimeInterval = defaultWarmUp,
                                    calendar: Calendar = .current) -> Date? {
        guard alarm.isEnabled, warmUp > 0 else { return nil }
        guard let next = nextOccurrence(after: now, alarm: alarm, calendar: calendar) else { return nil }
        return next.timeIntervalSince(now) <= warmUp ? next : nil
    }

    /// The most recent moment this alarm was scheduled to go off at or before `now`, or nil if
    /// there wasn't one in the last week (which only happens for a sparse `weekdays` set).
    ///
    /// Walks back day by day rather than doing calendar arithmetic on a fixed 86 400 s day, so a
    /// DST transition can't shift the alarm by an hour. `date(bySettingHour:)` resolves the times
    /// that don't exist on a spring-forward morning to the next valid instant.
    public static func mostRecentOccurrence(onOrBefore now: Date,
                                            alarm: RingAlarm,
                                            calendar: Calendar = .current) -> Date? {
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now),
                  let candidate = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute,
                                                second: 0, of: day) else { continue }
            guard candidate <= now else { continue }
            let weekday = calendar.component(.weekday, from: candidate)
            if alarm.repeats(onWeekday: weekday) { return candidate }
        }
        return nil
    }

    /// The next moment this alarm will go off strictly after `now`. Used for the settings screen's
    /// "next alarm" line and to place the backup notification.
    public static func nextOccurrence(after now: Date,
                                      alarm: RingAlarm,
                                      calendar: Calendar = .current) -> Date? {
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let candidate = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute,
                                                second: 0, of: day) else { continue }
            guard candidate > now else { continue }
            let weekday = calendar.component(.weekday, from: candidate)
            if alarm.repeats(onWeekday: weekday) { return candidate }
        }
        return nil
    }

    /// Decide what to do with `alarm` right now.
    ///
    /// - Parameters:
    ///   - lastHandledAt: the scheduled time of the last occurrence we already acted on (fired OR
    ///     recorded missed). NOT the time we acted — storing the OCCURRENCE is what makes this
    ///     idempotent across the many wake-ups a single morning produces. nil = never handled.
    ///   - grace: how late a buzz is still worth delivering.
    ///
    /// Called on every scrap of background runtime, so it must be cheap and must never fire twice
    /// for one morning.
    public static func decide(alarm: RingAlarm,
                              now: Date,
                              lastHandledAt: Date?,
                              grace: TimeInterval = defaultGrace,
                              calendar: Calendar = .current) -> RingAlarmDecision {
        guard alarm.isEnabled else { return .idle }
        guard let scheduled = mostRecentOccurrence(onOrBefore: now, alarm: alarm,
                                                   calendar: calendar) else { return .idle }
        // Already dealt with this occurrence (or a later one — a clock change can walk `scheduled`
        // backwards, and re-firing an alarm the user has already been woken by is unforgivable).
        if let lastHandledAt, lastHandledAt >= scheduled { return .idle }
        let lateBy = now.timeIntervalSince(scheduled)
        if lateBy <= grace { return .fire(scheduled: scheduled, lateBy: lateBy) }
        return .missed(scheduled: scheduled)
    }
}
