import Foundation
import OpenRingKit
import UserNotifications

// THE shared local-notification service for health alerts (#73) and skin-temp/fever
// notifications (#85). There is exactly ONE of these engines: a single quiet-hours/DND window,
// a single anti-spam de-dupe namespace, lazy UNUserNotifications authorization. Both tickets
// route their conditions through `post`. The PURE threshold/de-dupe/DND math lives in
// OpenRingKit (HealthAlerts.swift); this file is the UserDefaults persistence + the
// UNUserNotificationCenter glue + the data gathering from LocalStore.
//
// Separate from the observability alerts (ObservabilityStore.swift / LocalAlertCenter): those
// warn about the TRACKER failing silently (not synced / Health-auth lost). These are BODY-vital
// alerts the user opted into. They share the same app-wide notification authorization, but keep
// their own settings, de-dupe lane, and copy (each carries the "not a medical device" disclaimer).

// MARK: - Reminder settings (#84)

/// `@AppStorage`/`UserDefaults` keys + defaults for the three app-side reminders (#84).
/// Registered so `bool(forKey:)`/`integer(forKey:)` return the intended value on first run,
/// mirroring the pattern in `HealthAlertDefaults`.
enum ReminderDefaults {
    static let sedentaryEnabled    = "reminder.sedentary.enabled"
    static let sedentaryIntervalMin = "reminder.sedentary.intervalMin"
    static let wearEnabled          = "reminder.wear.enabled"
    static let bedtimeEnabled       = "reminder.bedtime.enabled"
    static let bedtimeMinutesBefore = "reminder.bedtime.minutesBefore"

    /// UserDefaults key written by RingSession when a nonzero step delta arrives.
    /// Read by `evaluateReminders` to decide whether the user has been sedentary.
    static let lastActivityAt = "reminder.lastActivityAt"

    /// UserDefaults key written by RingSession whenever ANY ring data frame arrives. DURABLE
    /// (survives session teardown on background/disconnect), unlike the ephemeral
    /// `session.lastFrameAt` which resets to nil on a cold launch. The wear reminder reads this
    /// so it tracks actual "ring data went silent" rather than transient BLE-connection state.
    static let lastRingDataAt = "reminder.lastRingDataAt"

    static func register(_ d: UserDefaults = .standard) {
        d.register(defaults: [
            sedentaryEnabled:    true,
            sedentaryIntervalMin: 50,
            wearEnabled:         false,
            bedtimeEnabled:      false,
            bedtimeMinutesBefore: 30,
        ])
    }
}

// MARK: - Settings (shared by the engine and the settings UI)

/// `@AppStorage`/`UserDefaults` keys + defaults for the health-alert thresholds and quiet hours.
/// The settings UI writes these via `@AppStorage`; the engine reads the same keys here. Defaults
/// are registered so `integer(forKey:)`/`bool(forKey:)` return the intended value before the user
/// has ever opened settings (mirrors `SleepScheduleDefaults`).
enum HealthAlertDefaults {
    static let highHREnabled = "alerts.highHR.enabled"
    static let highHRBpm = "alerts.highHR.bpm"
    static let lowSpO2Enabled = "alerts.lowSpO2.enabled"
    static let lowSpO2Percent = "alerts.lowSpO2.percent"
    static let elevatedHREnabled = "alerts.elevatedHR.enabled"
    static let elevatedHRBpm = "alerts.elevatedHR.bpm"
    static let tempFeverEnabled = "alerts.tempFever.enabled"
    static let quietEnabled = "alerts.quiet.enabled"
    static let quietStartMinutes = "alerts.quiet.startMinutes"
    static let quietEndMinutes = "alerts.quiet.endMinutes"

    // Defaults mirror OpenRingKit's HealthAlertThresholds / QuietHours so the UI and the pure
    // layer agree out of the box.
    static let defaultHighHRBpm = 120
    static let defaultLowSpO2Percent = 90
    static let defaultElevatedHRBpm = 100
    static let defaultQuietStart = 22 * 60
    static let defaultQuietEnd = 7 * 60

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            highHREnabled: true,
            highHRBpm: defaultHighHRBpm,
            lowSpO2Enabled: true,
            lowSpO2Percent: defaultLowSpO2Percent,
            elevatedHREnabled: true,
            elevatedHRBpm: defaultElevatedHRBpm,
            tempFeverEnabled: true,
            quietEnabled: false,
            quietStartMinutes: defaultQuietStart,
            quietEndMinutes: defaultQuietEnd,
        ])
    }

    static func thresholds(_ d: UserDefaults = .standard) -> HealthAlertThresholds {
        register(d)
        return HealthAlertThresholds(
            highHREnabled: d.bool(forKey: highHREnabled),
            highHRBpm: d.integer(forKey: highHRBpm),
            lowSpO2Enabled: d.bool(forKey: lowSpO2Enabled),
            lowSpO2Percent: d.integer(forKey: lowSpO2Percent),
            elevatedHREnabled: d.bool(forKey: elevatedHREnabled),
            elevatedHRBpm: d.integer(forKey: elevatedHRBpm))
    }

    static func quietHours(_ d: UserDefaults = .standard) -> QuietHours {
        register(d)
        return QuietHours(enabled: d.bool(forKey: quietEnabled),
                          startMinutes: d.integer(forKey: quietStartMinutes),
                          endMinutes: d.integer(forKey: quietEndMinutes))
    }

    static func tempFeverEnabledValue(_ d: UserDefaults = .standard) -> Bool {
        register(d); return d.bool(forKey: tempFeverEnabled)
    }
}

// MARK: - De-dupe persistence

/// Persists when each `HealthNotification` last fired, so the pure `NotificationGate` can enforce
/// the anti-spam backoff across launches. UserDefaults-backed (schema-free, thread-safe), like
/// `ObservabilityStore`'s alert lane — kept separate so the two alert systems can't collide.
struct HealthNotificationStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    private static let key = "alerts.health.lastFired"   // [HealthNotification.rawValue: epoch]

    func lastFired() -> [HealthNotification: Date] {
        let raw = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        var out: [HealthNotification: Date] = [:]
        for (k, v) in raw where v > 0 {
            if let n = HealthNotification(rawValue: k) { out[n] = Date(timeIntervalSince1970: v) }
        }
        return out
    }

    func markFired(_ notifs: [HealthNotification], at now: Date = Date()) {
        guard !notifs.isEmpty else { return }
        var raw = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        for n in notifs { raw[n.rawValue] = now.timeIntervalSince1970 }
        defaults.set(raw, forKey: Self.key)
    }
}

// MARK: - The engine

@MainActor
struct HealthNotificationCenter {
    var store = HealthNotificationStore()
    var gate = NotificationGate()
    private var center: UNUserNotificationCenter { .current() }

    /// How far back instantaneous HR/SpO2 alerts (#73) look for a threshold crossing. Covers an
    /// overnight sync that finishes in the morning; the de-dupe backoff stops it from re-nagging.
    static let instantLookback: TimeInterval = 12 * 3600
    /// Window for the sustained-elevated-HR-while-inactive rule.
    static let inactiveLookback: TimeInterval = 24 * 3600

    /// Evaluate ALL health-alert conditions (#73 + #85) from the store (+ optional live session),
    /// then post a debounced notification for each survivor. Safe to call liberally — a no-op when
    /// nothing crosses a threshold or everything is inside the backoff/quiet window.
    func evaluate(store localStore: LocalStore, session: RingSession?, now: Date = Date()) async {
        var candidates: [HealthNotification] = []
        var hitByNotif: [HealthNotification: HealthAlertHit] = [:]

        // --- #73: high HR / low SpO2 / elevated-HR-while-inactive --------------------------------
        let thresholds = HealthAlertDefaults.thresholds()
        let instantSince = now.addingTimeInterval(-Self.instantLookback)
        let inactiveSince = now.addingTimeInterval(-Self.inactiveLookback)
        let lastFired = store.lastFired()
        // Only consider HR/SpO2 readings NEWER than the last time that notification fired, so a
        // single morning spike alerts ONCE rather than re-firing every backoff window (the 2h
        // backoff is shorter than the 12h lookback, so without this the worst reading in the
        // window would keep being re-returned and re-announced for hours). (#73 fix)
        let hrSince = max(instantSince, lastFired[.highHR] ?? .distantPast)
        let spo2Since = max(instantSince, lastFired[.lowSpO2] ?? .distantPast)

        // Stored readings + the just-synced in-memory batch (so a fresh sync is reflected at once).
        var hr = ((try? localStore.recentSamples(kind: .heartRate, since: instantSince)) ?? [])
            .filter { $0.start > hrSince }
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        var spo2 = ((try? localStore.recentSamples(kind: .spo2, since: instantSince)) ?? [])
            .filter { $0.start > spo2Since }
            .map { SpO2Reading(percent: Int(($0.value * 100).rounded()), time: $0.start) }
        let inactiveHR = ((try? localStore.recentSamples(kind: .heartRate, since: inactiveSince)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }

        if let synced = session?.historySamples {
            hr += synced.filter { $0.kind == .heartRate && $0.value > 0 && $0.start > hrSince }
                .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
            spo2 += synced.filter { $0.kind == .spo2 && $0.value > 0 && $0.start > spo2Since }
                .map { SpO2Reading(percent: Int(($0.value * 100).rounded()), time: $0.start) }
        }

        for hit in HealthAlertEvaluator.evaluate(hr: hr, spo2: spo2, inactiveHR: inactiveHR,
                                                 thresholds: thresholds) {
            candidates.append(hit.notification)
            hitByNotif[hit.notification] = hit
        }

        // --- #85: skin-temp anomaly flags + suspected fever ------------------------------------
        if HealthAlertDefaults.tempFeverEnabledValue() {
            candidates += tempFeverCandidates(store: localStore)
        }

        // --- Route survivors through the ONE shared gate (quiet hours + backoff) ---------------
        let quiet = HealthAlertDefaults.quietHours()
        let fire = gate.filter(candidates, now: now, lastFired: lastFired, quietHours: quiet)
        guard !fire.isEmpty, await ensureAuthorized() else { return }
        for n in fire { await post(n, hit: hitByNotif[n]) }
        store.markFired(fire, at: now)
    }

    /// Compute the latest night's skin-temp anomaly flags (#69) + suspected fever (#72), then map
    /// them to notifications (#85). Reuses the SAME canonical SkinTempBaseline offset the Sleep card
    /// shows — temperature is not recomputed for fever.
    private func tempFeverCandidates(store: LocalStore) -> [HealthNotification] {
        guard let latest = try? store.latestSleepSummary(), latest.skinTempC > 0 else { return [] }
        let nights = ((try? store.recentSleepSummaries(limit: 40)) ?? []).filter { $0.skinTempC > 0 }
        let cal = Calendar.current
        let tonightDay = cal.startOfDay(for: latest.night)
        let prior = nights
            .filter { cal.startOfDay(for: $0.night) != tonightDay }
            .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
        let previousNight = prior.max { $0.night < $1.night }?.celsius
        let report = SkinTempBaseline.report(tonight: latest.skinTempC, priorNights: prior,
                                             previousNight: previousNight)

        // Fever: resting-HR baseline vs today + the canonical temp offset (#72 owns the logic).
        let fever = suspectedFever(store: store, tempOffsetC: report.offsetC)
        return TempFeverNotifications.notifications(flags: report.flags, feverSuspected: fever)
    }

    /// Resting-HR daily series → personal baseline, cross-referenced with the temp offset for the
    /// fever flag. Returns false on insufficient history (never a false positive).
    private func suspectedFever(store: LocalStore, tempOffsetC: Double?) -> Bool {
        guard let tempOffsetC else { return false }
        let since = Date().addingTimeInterval(-Double(VitalsBaseline.Config().maxBaselineDays + 2) * 86_400)
        let hr = ((try? store.recentSamples(kind: .heartRate, since: since)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let daily = RestingHR.dailyValues(hr: hr).sorted { $0.day < $1.day }
        guard let today = daily.last?.bpm else { return false }
        let prior = daily.dropLast().map(\.bpm)
        return VitalsBaseline.suspectedFever(restingHRToday: today, restingHRPrior: Array(prior),
                                             skinTempOffsetC: tempOffsetC)
    }

    // MARK: - Reminders (#84)

    /// Evaluate all three app-side reminders (sedentary / wear / bedtime) and fire any
    /// survivors through the ONE shared gate (quiet hours + anti-spam backoff). Safe to
    /// call liberally — a no-op when nothing crosses a threshold or everything is held by
    /// the gate. Pass `sleepEnabled = true` and the configured bed/wake minutes to enable
    /// the bedtime reminder; pass `sleepEnabled = false` to skip it.
    func evaluateReminders(session: RingSession?,
                           sleepBedMinutes: Int, sleepWakeMinutes: Int, sleepEnabled: Bool,
                           now: Date = Date()) async {
        ReminderDefaults.register()
        let d = UserDefaults.standard
        var candidates: [HealthNotification] = []

        // Sedentary / move reminder
        if d.bool(forKey: ReminderDefaults.sedentaryEnabled) {
            let interval = TimeInterval(d.integer(forKey: ReminderDefaults.sedentaryIntervalMin)) * 60
            let r = SedentaryReminder(interval: max(interval, 10 * 60))
            let lastActivityEpoch = d.double(forKey: ReminderDefaults.lastActivityAt)
            let lastActivityAt: Date? = lastActivityEpoch > 0
                ? Date(timeIntervalSince1970: lastActivityEpoch) : nil
            if r.shouldFire(lastActivityAt: lastActivityAt, now: now) {
                candidates.append(.sedentaryReminder)
            }
        }

        // Wear reminder
        if d.bool(forKey: ReminderDefaults.wearEnabled) {
            let r = WearReminder()
            // "ever connected" = a ring identifier has been persisted by RingScanner. Tolerant of
            // both the multi-ring list and the pre-migration single key (a background launch may run
            // this before RingScanner has migrated). (#multi-ring)
            let hasSavedRing = (d.stringArray(forKey: "com.openringconn.ring.peripheralIDs")?.isEmpty == false)
                || d.string(forKey: "com.openringconn.ring.peripheralID") != nil
            // Use the DURABLE last-frame timestamp (survives cold launch / session teardown), not
            // the ephemeral session value — otherwise the reminder fires "Put your ring back on"
            // on every cold foreground while the ring is actually worn and merely reconnecting.
            // Take the most recent of the durable and (if present) live session timestamps.
            let durableEpoch = d.double(forKey: ReminderDefaults.lastRingDataAt)
            let durable: Date? = durableEpoch > 0 ? Date(timeIntervalSince1970: durableEpoch) : nil
            let lastData = [durable, session?.lastFrameAt].compactMap { $0 }.max()
            if r.shouldFire(lastRingDataAt: lastData, now: now, everConnected: hasSavedRing) {
                candidates.append(.wearReminder)
            }
        }

        // Bedtime reminder
        if sleepEnabled, d.bool(forKey: ReminderDefaults.bedtimeEnabled) {
            let minutesBefore = d.integer(forKey: ReminderDefaults.bedtimeMinutesBefore)
            let r = BedtimeReminder(minutesBefore: max(minutesBefore, 5))
            if r.shouldFire(now: now, bedMinutes: sleepBedMinutes, wakeMinutes: sleepWakeMinutes) {
                candidates.append(.bedtimeReminder)
            }
        }

        guard !candidates.isEmpty else { return }
        let quiet = HealthAlertDefaults.quietHours()
        let fire = gate.filter(candidates, now: now, lastFired: store.lastFired(), quietHours: quiet)
        guard !fire.isEmpty, await ensureAuthorized() else { return }
        for n in fire { await post(n, hit: nil) }
        store.markFired(fire, at: now)
    }

    // MARK: - Charging complete (#86)

    /// Post a "ring fully charged" notification, routed through the shared gate so it
    /// respects quiet hours and the anti-spam backoff. Called by ContentView when
    /// `BatteryTTE.justReachedFull` fires. (#86)
    func postChargingComplete(store localStore: LocalStore) async {
        let candidates: [HealthNotification] = [.chargingComplete]
        let quiet = HealthAlertDefaults.quietHours()
        let fire = gate.filter(candidates, now: Date(), lastFired: store.lastFired(), quietHours: quiet)
        guard !fire.isEmpty, await ensureAuthorized() else { return }
        for n in fire { await post(n, hit: nil) }
        store.markFired(fire)
    }

    /// Request notification authorization LAZILY — only the first time there's actually something
    /// to post, so a user who never crosses a threshold is never prompted. These are alerts the
    /// user opted into in Settings, so we request a standard (visible) authorization.
    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    /// Body-vital alerts carry the medical disclaimer; #84 lifestyle reminders and the #86
    /// charging-complete banner do NOT (they aren't sensor-vital readings). This matches the
    /// stated intent in `copy(for:)` ("no medical disclaimer appended — they're lifestyle
    /// reminders"), which the previous unconditional append in `post` contradicted.
    private static func appendsDisclaimer(_ n: HealthNotification) -> Bool {
        switch n {
        case .highHR, .lowSpO2, .elevatedHRInactive,
             .skinTempRise, .skinTempDrop, .skinTempFluctuationRise, .skinTempFluctuationDrop,
             .fever:
            return true
        case .sedentaryReminder, .wearReminder, .bedtimeReminder, .chargingComplete:
            return false
        }
    }

    private func post(_ n: HealthNotification, hit: HealthAlertHit?) async {
        let content = UNMutableNotificationContent()
        let copy = Self.copy(for: n, hit: hit)
        content.title = copy.title
        content.body = Self.appendsDisclaimer(n) ? copy.body + "\n\n" + Self.disclaimer : copy.body
        content.sound = .default
        // One pending request per condition (stable id) — re-posting just refreshes it.
        let request = UNNotificationRequest(identifier: "alerts.health.\(n.rawValue)",
                                            content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: Copy

    /// The medical-disclaimer line carried on EVERY health/fever notification, per the APK
    /// (pp.txt:45929 / 46204): "Note: This product is not a medical device …".
    static let disclaimer =
        "Note: OpenCircuit is not a medical device. These reminders are based on ring sensor "
        + "data only and are not a diagnosis. If you feel unwell, consult a qualified medical professional."

    private static func timeString(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: date)
    }

    static func copy(for n: HealthNotification, hit: HealthAlertHit?) -> (title: String, body: String) {
        let at = timeString(hit?.time)
        switch n {
        case .highHR:
            let bpm = hit.map { Int($0.value) }
            return ("High heart rate",
                    "High heart rate detected"
                    + (bpm.map { " (\($0) bpm)" } ?? "")
                    + (at.isEmpty ? "" : " at \(at)") + ".")
        case .lowSpO2:
            let pct = hit.map { Int($0.value) }
            return ("Low blood oxygen",
                    "Low blood oxygen detected"
                    + (pct.map { " (\($0)%)" } ?? "")
                    + (at.isEmpty ? "" : " at \(at)") + " (estimate).")
        case .elevatedHRInactive:
            let bpm = hit.map { Int($0.value) }
            return ("Elevated heart rate while inactive",
                    "Your heart rate stayed elevated"
                    + (bpm.map { " (above \($0) bpm)" } ?? "")
                    + " for over 10 minutes while you were inactive. This can indicate a change in how you feel.")
        case .skinTempRise:
            return ("Skin temperature elevated",
                    "Your overnight skin temperature is well above your personal baseline (estimate).")
        case .skinTempDrop:
            return ("Skin temperature low",
                    "Your overnight skin temperature is well below your personal baseline (estimate).")
        case .skinTempFluctuationRise:
            return ("Skin temperature jumped",
                    "Your overnight skin temperature rose sharply versus the previous night (estimate).")
        case .skinTempFluctuationDrop:
            return ("Skin temperature dropped",
                    "Your overnight skin temperature fell sharply versus the previous night (estimate).")
        case .fever:
            return ("Possible fever signs",
                    "Your skin temperature and heart rate are both elevated above your baseline, "
                    + "which can accompany suspected fever symptoms (estimate).")
        // #84 reminders — no medical disclaimer appended (they're lifestyle reminders)
        case .sedentaryReminder:
            return ("Move reminder",
                    "You've been inactive for a while — time to move! (estimated)")
        case .wearReminder:
            return ("Ring not detected",
                    "Put your ring back on to continue tracking.")
        case .bedtimeReminder:
            return ("Bedtime reminder",
                    "Time to wind down for bed.")
        // #86 battery
        case .chargingComplete:
            return ("Ring fully charged",
                    "Your RingConn ring has reached 100% — disconnect the charger (estimated).")
        }
    }
}
