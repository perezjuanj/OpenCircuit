import Foundation
import UserNotifications
import OpenCircuitKit
import os

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
    }

    /// Identifier for the OS-scheduled backup alert.
    private static let notificationID = "alarm.ring.backup"

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
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.alarm)
            // Changing the time must not leave the OLD occurrence looking unhandled (which would
            // fire the moment the user finished editing) nor the new one looking handled.
            defaults.set(Date().timeIntervalSince1970, forKey: Key.lastHandled)
            refreshBackupNotification(for: newValue)
        }
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
        return RingAlarmSchedule.nextOccurrence(after: now, alarm: a)
    }

    // MARK: - Firing

    /// Decide and act. Cheap, idempotent, and safe to call from anywhere that has runtime — that
    /// is the whole strategy: we can't pick the moment, so we take every moment offered.
    func evaluate(session: RingSession?, now: Date = Date()) {
        let a = alarm
        switch RingAlarmSchedule.decide(alarm: a, now: now, lastHandledAt: lastHandledOccurrence) {
        case .idle:
            return

        case .missed(let scheduled):
            markHandled(scheduled)
            setOutcome("Missed the \(Self.clock(scheduled)) alarm — the app got no chance to run "
                + "near that time, so the ring was never told to buzz.")
            log.notice("alarm MISSED for \(scheduled, privacy: .public) — no runtime inside the grace window")

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
        }
    }

    /// The upcoming alarm if we are inside its warm-up window — the cue for `RingSession` to start
    /// holding the link open. nil at every other moment, including when the alarm is off.
    func warmUpTarget(now: Date = Date()) -> Date? {
        RingAlarmSchedule.warmUpTarget(alarm: alarm, now: now)
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
        guard buzzAlertsEnabled else { return }
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

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Alarm"
            content.body = "Time to wake up."
            content.sound = .default
            // Repeating calendar trigger, one per weekday the alarm runs on. An empty `weekdays`
            // set means every day, which is a single hour/minute trigger with no weekday component.
            var requests: [UNNotificationRequest] = []
            if a.weekdays.isEmpty {
                var comps = DateComponents()
                comps.hour = a.hour
                comps.minute = a.minute
                requests.append(UNNotificationRequest(
                    identifier: Self.notificationID,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
            } else {
                for weekday in a.weekdays.sorted() {
                    var comps = DateComponents()
                    comps.weekday = weekday
                    comps.hour = a.hour
                    comps.minute = a.minute
                    requests.append(UNNotificationRequest(
                        identifier: "\(Self.notificationID).\(weekday)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
                }
            }
            for request in requests { center.add(request) }
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
