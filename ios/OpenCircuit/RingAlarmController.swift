import Foundation
import UserNotifications
import OpenCircuitKit
import os

/// What the alarm needs from the ring to buzz it: `RingSession` in the app, a fake in the tests.
@MainActor
protocol RingAlarmBuzzer: AnyObject {
    var supportsVibration: Bool { get }
    var lastVibrationBlock: RingAlarmBlock? { get }
    func vibrateBurst(_ pattern: VibrationPattern, count: Int, spacing: TimeInterval) -> Bool
}

extension RingSession: RingAlarmBuzzer {}

/// `RingAlarmController.decide`: the Kit's decision, plus the one-shot's end (decision 52g).
enum RingAlarmStep: Equatable {
    case idle
    case fire(scheduled: Date, lateBy: TimeInterval)
    case missed(scheduled: Date)
    /// A one-shot whose occurrence was already handled: turn it off, no buzz.
    case expired
}

/// Owns the vibrating wake-up alarm: where it's stored, when it fires, and what to tell the user
/// when it doesn't.
///
/// ══ WHY THIS IS SHAPED THE WAY IT IS ══
///
/// iOS will not run our code at a wall-clock instant in the background — no surviving timer, and a
/// delivered local notification doesn't execute anything. See the header of `RingAlarm.swift` for
/// the full argument. The consequence for this file is a two-track design:
///
///   • The BUZZ is opportunistic. `evaluate` is called from every scrap of runtime the app gets —
///     the keepalive tick, a CoreBluetooth background wake, scene activation, the BGTask — and
///     fires on the first one at or after the alarm time. Accuracy is bounded by how often the
///     ring pushes a frame, not by a clock we own.
///   • The NOTIFICATION is guaranteed. `UNCalendarNotificationTrigger` is scheduled by the OS and
///     fires regardless of what our process is doing. It defaults ON because it is the only half
///     of this feature that can actually be promised to someone who needs to wake up.
///
/// State is UserDefaults, not SwiftData, and deliberately: this is one small struct with no
/// relationships and no queries, and every SwiftData schema change on this project owes a
/// migration rehearsal on real hardware (docs/RUNBOOK_SCHEMA_MIGRATION_REHEARSAL.md — a past build
/// deleted every raw history row on upgrade). An alarm clock is not worth that risk surface.
@MainActor
final class RingAlarmController {
    static let shared = RingAlarmController()

    private let log = Logger(subsystem: "com.standardsoftwaresolutions.opencircuit", category: "alarm")
    private let defaults: UserDefaults

    enum Key {
        static let alarm = "alarm.ring.config"
        /// The SCHEDULED time of the last occurrence we acted on — fired or recorded missed. Storing
        /// the occurrence (not the moment we acted) is what makes firing idempotent across the many
        /// wake-ups one morning produces.
        static let lastHandled = "alarm.ring.lastHandledOccurrence"
        static let lastOutcome = "alarm.ring.lastOutcome"
        static let lastOutcomeAt = "alarm.ring.lastOutcomeAt"
        /// Mirror app notifications onto the ring's motor. OFF by default — this is an opt-in
        /// haptic, and a ring that starts buzzing after an update is a support ticket.
        static let buzzAlerts = "vibration.buzzAlerts"
        /// A Shortcuts "Once" alarm (#260, decision 52g): the one occurrence it fires for. Absent for
        /// every repeating alarm, so an alarm set on the screen behaves exactly as before.
        static let oneShot = "alarm.ring.oneShotOccurrence.v1"
    }

    /// Identifier for the OS-scheduled backup alert.
    private static let notificationID = "alarm.ring.backup"
    /// The backup alert's text (held to `NotificationBudget` by `AllNotificationsFitTests`).
    nonisolated static let backupCopy = (title: "Alarm", body: "Time to wake up.")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Stored configuration

    var alarm: RingAlarm {
        get {
            guard let data = defaults.data(forKey: Key.alarm),
                  let decoded = try? JSONDecoder().decode(RingAlarm.self, from: data) else {
                return RingAlarm()
            }
            return decoded
        }
        set {
            // A one-shot stays one only while its time, days and on/off are untouched: a pattern or
            // backup-alert change keeps it, a schedule edit makes it an ordinary alarm.
            let old = alarm
            let keep = oneShotOccurrence.flatMap { occurrence in
                (old.hour, old.minute, old.weekdays, old.isEnabled)
                    == (newValue.hour, newValue.minute, newValue.weekdays, newValue.isEnabled) ? occurrence : nil
            }
            store(newValue, oneShot: keep)
        }
    }

    /// Stores the alarm and its one-shot occurrence (nil: repeating), then re-places the backup alert.
    private func store(_ newValue: RingAlarm, oneShot: Date?) {
        guard let data = try? JSONEncoder().encode(newValue) else { return }
        defaults.set(data, forKey: Key.alarm)
        if let oneShot {
            defaults.set(oneShot.timeIntervalSince1970, forKey: Key.oneShot)
        } else {
            defaults.removeObject(forKey: Key.oneShot)
        }
        // Changing the time must not leave the OLD occurrence looking unhandled (which would
        // fire the moment the user finished editing) nor the new one looking handled.
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastHandled)
        refreshBackupNotification(for: newValue)
    }

    /// The one occurrence a Shortcuts "Once" alarm fires for; nil for a repeating alarm.
    var oneShotOccurrence: Date? {
        let t = defaults.double(forKey: Key.oneShot)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Shortcuts' Set Wake Alarm (#260, decision 52g): the time, days and on, keeping the person's
    /// pattern, burst and backup-alert settings. `once`: fire for the first occurrence after `now` only
    /// (`oneShotOccurrence`), then turn off; the days are that occurrence's weekday.
    /// Returns the alarm as stored and its one-shot occurrence.
    @discardableResult
    func setFromShortcut(hour: Int, minute: Int, weekdays: Set<Int>, once: Bool, now: Date = Date(),
                         calendar: Calendar = .current) -> (alarm: RingAlarm, oneShot: Date?) {
        var next = alarm
        next.isEnabled = true
        next.hour = hour
        next.minute = minute
        var oneShot: Date?
        if once, let occurrence = Self.oneShotOccurrence(hour: hour, minute: minute, after: now, calendar: calendar) {
            oneShot = occurrence
            next.weekdays = [calendar.component(.weekday, from: occurrence)]
        } else {
            next.weekdays = weekdays
        }
        store(next, oneShot: oneShot)
        return (next, oneShot)
    }

    /// Turns the alarm off (Shortcuts' Clear, or a one-shot that is done), keeping everything else.
    func turnOff() {
        var off = alarm
        off.isEnabled = false
        store(off, oneShot: nil)
    }

    /// The first `hour:minute` strictly after `now` (decision 52g: "the first at or after the moment it was
    /// set"; the minute's own start, 07:00:00, is before a moment like 07:00:20). The strap's request does
    /// the same (`Calendar.nextDate(after:)`, `StrapWakeAlarmPlanner.isExpired`), so a Once set inside its own
    /// minute goes to the next day on both devices (review-261b S-B: it was stored for this minute and,
    /// with `lastHandled` stamped at the set, expired unbuzzed).
    static func oneShotOccurrence(hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date? {
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if today > now { return today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)
    }

    /// The Kit's `RingAlarmSchedule.decide` for a repeating alarm, unchanged. A one-shot fires for its
    /// one occurrence only, within the same grace, and never for a later one (decision 52g, after 52e):
    /// past the grace it is missed, and once handled it is expired. Either way it then turns off.
    static func decide(alarm: RingAlarm, oneShot: Date?, now: Date, lastHandledAt: Date?,
                       grace: TimeInterval = RingAlarmSchedule.defaultGrace,
                       calendar: Calendar = .current) -> RingAlarmStep {
        guard let oneShot else {
            switch RingAlarmSchedule.decide(alarm: alarm, now: now, lastHandledAt: lastHandledAt, grace: grace,
                                            calendar: calendar) {
            case .idle: return .idle
            case .fire(let scheduled, let lateBy): return .fire(scheduled: scheduled, lateBy: lateBy)
            case .missed(let scheduled): return .missed(scheduled: scheduled)
            }
        }
        guard alarm.isEnabled, now >= oneShot else { return .idle }
        if let lastHandledAt, lastHandledAt >= oneShot { return .expired }
        let lateBy = now.timeIntervalSince(oneShot)
        return lateBy <= grace ? .fire(scheduled: oneShot, lateBy: lateBy) : .missed(scheduled: oneShot)
    }

    private var lastHandledOccurrence: Date? {
        let t = defaults.double(forKey: Key.lastHandled)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func markHandled(_ occurrence: Date) {
        defaults.set(occurrence.timeIntervalSince1970, forKey: Key.lastHandled)
    }

    /// A one-line, plain-language account of what the alarm last did — including the failures.
    /// Shown in settings; a wake-up alarm that stays silent without explanation is the worst
    /// outcome this feature has, so the explanation is part of the feature.
    var lastOutcome: String? { defaults.string(forKey: Key.lastOutcome) }

    private func setOutcome(_ text: String) {
        defaults.set(text, forKey: Key.lastOutcome)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastOutcomeAt)
    }

    var lastOutcomeAt: Date? {
        let t = defaults.double(forKey: Key.lastOutcomeAt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The next time the alarm is set to go off, for the settings screen.
    func nextFireDate(now: Date = Date()) -> Date? {
        let a = alarm
        guard a.isEnabled else { return nil }
        if let oneShot = oneShotOccurrence { return oneShot > now ? oneShot : nil }
        return RingAlarmSchedule.nextOccurrence(after: now, alarm: a)
    }

    // MARK: - Firing

    /// Decide and act. Cheap, idempotent, and safe to call from anywhere that has runtime — that
    /// is the whole strategy: we can't pick the moment, so we take every moment offered.
    func evaluate(session: (any RingAlarmBuzzer)?, now: Date = Date()) {
        let a = alarm
        let oneShot = oneShotOccurrence
        switch Self.decide(alarm: a, oneShot: oneShot, now: now, lastHandledAt: lastHandledOccurrence) {
        case .idle:
            return

        case .expired:
            turnOff()
            log.notice("one-shot alarm already handled; turned off")

        case .missed(let scheduled):
            markHandled(scheduled)
            setOutcome("Missed the \(Self.clock(scheduled)) alarm — the app got no chance to run "
                + "near that time, so the ring was never told to buzz.")
            log.notice("alarm MISSED for \(scheduled, privacy: .public) — no runtime inside the grace window")
            if oneShot != nil { turnOff() }   // a one-shot never fires for a later occurrence (52g)

        case .fire(let scheduled, let lateBy):
            guard let session, session.supportsVibration else {
                // Don't mark handled: a ring may reconnect inside the grace window and still make it.
                setOutcome("Waiting to buzz the \(Self.clock(scheduled)) alarm — no Gen 3 ring connected yet.")
                return
            }
            guard session.vibrateBurst(a.pattern,
                                       count: a.clampedBurstCount,
                                       spacing: a.clampedBurstSpacing) else {
                // Transient: stay unhandled and retry on the next scrap of runtime. If the whole
                // grace window passes this way, `decide` returns `.missed` and it gets recorded.
                setOutcome(Self.blockedMessage(session.lastVibrationBlock, scheduled: scheduled))
                log.notice("alarm blocked (\(session.lastVibrationBlock?.rawValue ?? "unknown", privacy: .public)) — will retry inside the grace window")
                return
            }
            markHandled(scheduled)
            setOutcome(Self.firedMessage(scheduled: scheduled, lateBy: lateBy, bursts: a.clampedBurstCount))
            log.notice("alarm FIRED for \(scheduled, privacy: .public), \(Int(lateBy), privacy: .public)s late")
            if oneShot != nil { turnOff() }   // its one occurrence is done (52g)
        }
    }

    /// The upcoming alarm if we are inside its warm-up window — the cue for `RingSession` to start
    /// holding the link open. nil at every other moment, including when the alarm is off.
    func warmUpTarget(now: Date = Date()) -> Date? {
        let target = RingAlarmSchedule.warmUpTarget(alarm: alarm, now: now)
        // A one-shot warms up for its own occurrence only.
        if let oneShot = oneShotOccurrence, target != oneShot { return nil }
        return target
    }

    /// Whether this occurrence has already been fired or written off, so the warm-up can stop
    /// polling the instant its job is done instead of running out a fixed tail.
    func isHandled(_ occurrence: Date) -> Bool {
        guard let last = lastHandledOccurrence else { return false }
        return last >= occurrence
    }

    /// Whether app notifications should also buzz the ring.
    var buzzAlertsEnabled: Bool {
        get { defaults.bool(forKey: Key.buzzAlerts) }
        set { defaults.set(newValue, forKey: Key.buzzAlerts) }
    }

    /// Mirror a notification the app has just decided to post onto the ring's motor.
    ///
    /// Deliberately downstream of every gate that decides WHETHER to notify — quiet hours, the
    /// anti-spam backoff, the per-reminder toggles — so this can only ever add a haptic to a
    /// notification the user was already going to get. It never introduces one. Silent no-op on
    /// any ring without a motor, and `vibrate` itself declines while the ring is charging or the
    /// link is busy: a missed buzz on a notification is not worth contending the BLE link for.
    func buzzForAlert() {
        // Ring only: with the Helio Strap active the ring is not touched (decision 1, #215).
        guard buzzAlertsEnabled, ActiveDeviceChoiceStore.persisted() == .ringConn else { return }
        RingScanner.shared.session?.vibrate(.notification)
    }

    /// Buzz right now so the user can feel the pattern they picked. Returns nil on success, or a
    /// user-facing reason it didn't happen.
    func testBuzz(session: RingSession?) -> String? {
        guard let session else { return "No ring connected." }
        guard session.supportsVibration else {
            return "This ring doesn't have a vibration motor that OpenCircuit can drive."
        }
        guard session.vibrate(alarm.pattern) else {
            return Self.blockedMessage(session.lastVibrationBlock, scheduled: nil)
        }
        return nil
    }

    // MARK: - The guaranteed half: an OS-scheduled backup alert

    /// Ask for notification permission and (re)place the backup alert. Called whenever the alarm
    /// changes and once at launch, because a `UNCalendarNotificationTrigger` is the only part of
    /// this feature that survives the app being suspended, killed, or force-quit.
    func refreshBackupNotification(for alarm: RingAlarm? = nil) {
        let a = alarm ?? self.alarm
        let center = UNUserNotificationCenter.current()
        // Clear BOTH shapes (the every-day single request and the per-weekday set) before placing
        // anything, so switching between them can't leave an orphan firing on a day the user
        // removed. Identifiers are stable, so this is exact rather than a best-effort sweep.
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.notificationID] + (1...7).map { "\(Self.notificationID).\($0)" })
        guard a.isEnabled, a.backupNotification else { return }
        // A one-shot's backup alert is one non-repeating notification at its one occurrence (52g).
        let oneShot = alarm == nil || alarm == self.alarm ? oneShotOccurrence : nil

        let triggers = Self.backupTriggers(alarm: a, oneShot: oneShot)

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = Self.backupCopy.title
            content.body = Self.backupCopy.body
            content.sound = .default
            for trigger in triggers {
                center.add(UNNotificationRequest(
                    identifier: trigger.identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: trigger.components, repeats: trigger.repeats)))
            }
        }
    }

    /// The backup alert's calendar triggers. A one-shot (decision 52g): ONE non-repeating trigger at its
    /// one occurrence. Otherwise repeating, one per weekday the alarm runs on; an empty `weekdays` set
    /// means every day, which is a single hour/minute trigger with no weekday component.
    static func backupTriggers(alarm a: RingAlarm, oneShot: Date?,
                               calendar: Calendar = .current) -> [(identifier: String, components: DateComponents, repeats: Bool)] {
        if let oneShot {
            return [(notificationID, calendar.dateComponents([.year, .month, .day, .hour, .minute], from: oneShot), false)]
        }
        if a.weekdays.isEmpty {
            return [(notificationID, DateComponents(hour: a.hour, minute: a.minute), true)]
        }
        return a.weekdays.sorted().map { weekday in
            ("\(notificationID).\(weekday)", DateComponents(hour: a.hour, minute: a.minute, weekday: weekday), true)
        }
    }

    // MARK: - Copy

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    private static func firedMessage(scheduled: Date, lateBy: TimeInterval, bursts: Int) -> String {
        let times = bursts == 1 ? "once" : "\(bursts) times"
        // Report the lateness rather than implying we hit the mark — the buzz rides on whatever
        // runtime iOS handed us, and pretending otherwise would make a real delay look like a
        // ring fault the next time someone investigates one.
        if lateBy < 60 {
            return "Buzzed \(times) at the \(clock(scheduled)) alarm."
        }
        let minutes = Int((lateBy / 60).rounded())
        return "Buzzed \(times) for the \(clock(scheduled)) alarm, about \(minutes) min late — "
            + "the ring wasn't heard from any sooner."
    }

    private static func blockedMessage(_ block: RingAlarmBlock?, scheduled: Date?) -> String {
        let subject = scheduled.map { "the \(clock($0)) alarm" } ?? "the buzz"
        switch block {
        case .ringOnCharger:
            return "Skipped \(subject) — the ring is in its charging case."
        case .ringUnsupported:
            return "Skipped \(subject) — this ring has no vibration motor OpenCircuit can drive."
        case .linkNotReady:
            return "Waiting on \(subject) — the ring isn't connected right now."
        case .ringBusy, .none:
            return "Waiting on \(subject) — the ring is busy syncing; it'll retry shortly."
        }
    }
}
