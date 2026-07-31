import Foundation
import OpenCircuitKit
import UserNotifications
import UIKit

// THE shared local-notification service for health alerts (#73) and skin-temp/fever
// notifications (#85). There is exactly ONE of these engines: a single quiet-hours/DND window,
// a single anti-spam de-dupe namespace, lazy UNUserNotifications authorization. Both tickets
// route their conditions through `post`. The PURE threshold/de-dupe/DND math lives in
// OpenCircuitKit (HealthAlerts.swift); this file is the UserDefaults persistence + the
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

    // Defaults mirror OpenCircuitKit's HealthAlertThresholds / QuietHours so the UI and the pure
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

    // Per-night ledger for the skin-temp/fever notifications (#85). Separate from `lastFired` (the
    // rolling anti-spam backoff) because these flags describe ONE overnight summary and must fire at
    // most once per night regardless of how many syncs land that day — see
    // `TempFeverNotifications.freshForNight`. Stores each flag's already-notified night start-of-day.
    private static let nightKey = "alerts.health.lastNight"   // [HealthNotification.rawValue: yyyymmdd dayKey]

    func lastNotifiedNight() -> [HealthNotification: Int] {
        // A pre-migration install stored fractional epoch instants here; those fail the `[String: Int]`
        // cast so the ledger reads empty and re-arms once — a bounded, one-time re-fire on upgrade.
        let raw = defaults.dictionary(forKey: Self.nightKey) as? [String: Int] ?? [:]
        var out: [HealthNotification: Int] = [:]
        for (k, v) in raw where v > 0 {
            if let n = HealthNotification(rawValue: k) { out[n] = v }
        }
        return out
    }

    func markNight(_ notifs: [HealthNotification], night: Int) {
        guard !notifs.isEmpty else { return }
        var raw = defaults.dictionary(forKey: Self.nightKey) as? [String: Int] ?? [:]
        for n in notifs { raw[n.rawValue] = night }
        defaults.set(raw, forKey: Self.nightKey)
    }
}

// MARK: - The engine

@MainActor
struct HealthNotificationCenter {
    var store = HealthNotificationStore()
    var gate = NotificationGate()
    private var center: UNUserNotificationCenter { .current() }

    /// How far back the instantaneous HR / SpO2 alerts (#73) look for a threshold crossing. Wide on
    /// purpose: all-day HR (and overnight SpO2) reaches the phone via ~hourly background drains whose
    /// device timestamps are routinely 30–60+ min old on arrival, and the phone evaluates ONCE right
    /// after each drain. A narrower device-timestamp "freshness" fetch window would permanently
    /// silence the older half of every drain — the legitimate background alerts we most need to
    /// deliver. De-dupe is NOT done here by sample age: the evaluator's per-notification `lastFired`
    /// filter is the sole guard that stops an already-alerted crossing from replaying on later syncs.
    static let instantLookback: TimeInterval = 12 * 3600

    /// Evaluate ALL health-alert conditions (#73 + #85) from the store (+ optional live session),
    /// then post a debounced notification for each survivor. Safe to call liberally — a no-op when
    /// nothing crosses a threshold or everything is inside the backoff/quiet window.
    ///
    /// `restingHRDaily` (#183): a resting-HR daily series the CALLER already computed for the
    /// overnight-signals engine on this same pass, handed over so the fever cross-check below reuses
    /// it instead of repeating the scan (see `restingHRDailySeries`). Leaving it nil — every caller
    /// that doesn't run the engine — keeps the original lazy fetch, so nothing about the fever
    /// verdict changes.
    func evaluate(store localStore: LocalStore, session: RingSession?, now: Date = Date(),
                  restingHRDaily: [RestingHR.DailyValue]? = nil) async {
        var candidates: [HealthNotification] = []
        var hitByNotif: [HealthNotification: HealthAlertHit] = [:]

        // --- #73: high HR / low SpO2 / elevated-HR-while-inactive --------------------------------
        let thresholds = HealthAlertDefaults.thresholds()
        let instantSince = now.addingTimeInterval(-Self.instantLookback)
        let lastFired = store.lastFired()
        // Fetch the whole recent window (stored + the just-synced in-memory batch) and let the pure
        // evaluator's per-notification `lastFired` filter do the de-dupe. HR is fetched over the SAME
        // wide window as SpO2 — never a 30-min device-timestamp freshness window — so a crossing that
        // rode in on the older half of an hourly background drain (timestamps 30–60+ min old) still
        // alerts once. The future guard (`start <= now`) is applied uniformly to HR and SpO2.
        var hr = ((try? localStore.recentSamples(kind: .heartRate, since: instantSince)) ?? [])
            .filter { $0.start <= now }
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        var spo2 = ((try? localStore.recentSamples(kind: .spo2, since: instantSince)) ?? [])
            .filter { $0.start <= now }
            .map { SpO2Reading(percent: Int(($0.value * 100).rounded()), time: $0.start) }

        if let synced = session?.historySamples {
            hr += synced.filter {
                $0.kind == .heartRate && $0.value > 0 && $0.start >= instantSince && $0.start <= now
            }
                .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
            spo2 += synced.filter {
                $0.kind == .spo2 && $0.value > 0 && $0.start >= instantSince && $0.start <= now
            }
                .map { SpO2Reading(percent: Int(($0.value * 100).rounded()), time: $0.start) }
        }

        // --- #144: activity gate for the HR rules ------------------------------------------------
        // Exercise HR routinely crosses 120 bpm, so the raw high-HR / elevated-while-inactive rules
        // would fire a false "high heart rate" alarm after every workout. Gate them on concurrent
        // step activity. Steps live ONLY in `StoredStepSample` (persisted by `addDailySteps`), NOT in
        // the `StoredSample` table that `recentSamples`/`historySamples` read — those carry only
        // HR/HRV/SpO2/RR/temp — so the windows MUST come from `stepSamples(from:to:)`. By the time we
        // evaluate (post-sync in the foreground, post-drain in the background) the sync has already
        // committed the same-window step rows, so this reads the freshly-synced activity.
        //
        // `activeStepIntervals` drops zero-delta windows AND the day-wide `[startOfDay, sampleDate]`
        // fallback window that a fresh-baseline / rollover reading records (that guard is
        // safety-critical — a multi-hour window would suppress a genuine resting crossing). Steps and
        // HR share device timestamps, so they line up by device time. SpO2 is NOT gated. With no
        // step windows the series is returned unchanged, so a real resting crossing still alerts.
        let stepWindows = ((try? localStore.stepSamples(from: instantSince, to: now)) ?? [])
            .map { StepWindow(start: $0.start, end: $0.end, delta: $0.delta) }
        let stepIntervals = HealthAlertEvaluator.activeStepIntervals(stepWindows)
        let nonExercisingHR = HealthAlertEvaluator.nonExercising(hr, activeIntervals: stepIntervals)

        // Both the instantaneous high-HR and the sustained-while-inactive rule read the non-exercising
        // series over the same wide window; the evaluator's own `lastFired` filter gives once-per-event
        // de-dupe. SpO2 (`spo2`) is passed unfiltered — its rule is unaffected by the activity gate.
        for hit in HealthAlertEvaluator.evaluate(hr: nonExercisingHR, spo2: spo2,
                                                 inactiveHR: nonExercisingHR,
                                                 thresholds: thresholds,
                                                 lastFired: lastFired) {
            candidates.append(hit.notification)
            hitByNotif[hit.notification] = hit
        }

        // Read the per-night / per-day ledger ONCE. The #85 temp family and the #183 morning verdict
        // share the single `alerts.health.lastNight` map — it is keyed by `rawValue`, so the two
        // families cannot collide — and both branches below need it. Hoisted from the inline read
        // it replaces; same value, same pass, nothing writes to it in between.
        let dayLedger = store.lastNotifiedNight()

        // --- #85: skin-temp anomaly flags + suspected fever ------------------------------------
        // These flags describe ONE overnight summary, so they de-dupe per night (not by the 2h
        // backoff): once a night is notified, later syncs of the same night are dropped here so the
        // user doesn't get the same "skin temperature dropped" alert after every sync. A new night's
        // summary re-arms them.
        var tempNightKey: Int?
        // nil = the temp/fever branch did not run this pass, so the fever verdict has not been
        // computed yet (see the #183 branch, which needs it for its own suppression).
        var feverSuspected: Bool?
        if HealthAlertDefaults.tempFeverEnabledValue() {
            let temp = tempFeverCandidates(store: localStore, restingHRDaily: restingHRDaily)
            feverSuspected = temp.fever
            if let night = temp.night {
                let key = TempFeverNotifications.dayKey(for: night)
                tempNightKey = key
                candidates += TempFeverNotifications.freshForNight(
                    temp.candidates, night: key, lastNotifiedNight: dayLedger)
            }
        }

        // --- #183: the morning overnight-signals verdict ----------------------------------------
        // A MEASUREMENT of a night that is already over — "last night was unusual for you", plus
        // what drifted. Never a forecast; the copy rule and its arithmetic live on
        // `HeadacheSignsNotifications` in the Kit.
        //
        // De-dupes per CALENDAR DAY on the shared night ledger, NOT on the rolling 2 h backoff:
        // a once-a-morning verdict under a 2 h backoff re-fires all day after every sync, which is
        // the exact bug the #85 temp flags hit (documented at `TempFeverNotifications.freshForNight`).
        var headacheDayKey: Int?
        var headacheRowDay: Date?
        var headacheSignals: [HeadacheSignals.Feature] = []
        if let ready = headacheCandidate(store: localStore, now: now, lastNotifiedDay: dayLedger,
                                         feverSuspected: feverSuspected,
                                         restingHRDaily: restingHRDaily) {
            candidates.append(.headacheSigns)
            headacheDayKey = ready.dayKey
            headacheRowDay = ready.rowDay
            headacheSignals = ready.signals
        }

        // --- Route survivors through the ONE shared gate (quiet hours + backoff) ---------------
        let quiet = HealthAlertDefaults.quietHours()
        let fire = gate.filter(candidates, now: now, lastFired: lastFired, quietHours: quiet)
        guard !fire.isEmpty else { return }
        // Reserve the survivors against the anti-spam backoff SYNCHRONOUSLY — there is no `await`
        // between reading `lastFired` above and this write, so on the main actor a second concurrent
        // evaluate() (the app-open scene-active probe and the sync-complete trigger both fire and
        // each starts its own Task) reads the mark and is gated out, instead of both passing and
        // double-posting the same alert. This must stay BEFORE the ensureAuthorized() suspension —
        // that's what closes the window. `markNight`, by contrast, is deferred until AFTER auth
        // succeeds: unlike the 2h backoff the night ledger has no time-based self-heal (it only
        // re-arms on a strictly newer night), so claiming a night here would silently swallow a
        // real fever/skin-temp flag for the whole day if auth was denied and nothing was posted.
        store.markFired(fire, at: now)
        guard await ensureAuthorized() else { return }
        if let tempNightKey { store.markNight(fire.filter(Self.isTempFever), night: tempNightKey) }
        // Same deferral, same reason (#183): the day ledger only re-arms on a strictly NEWER day, so
        // claiming today before a successful post would swallow this morning's verdict for the whole
        // day if authorization was denied. The 2 h backoff above is the self-healing retry — it
        // expires inside the delivery window, so a denied-then-granted user still hears it today.
        if let headacheDayKey, fire.contains(.headacheSigns) {
            store.markNight([.headacheSigns], night: headacheDayKey)
            // Record on the frozen row that this day actually alerted. This is the auto-retire
            // quality monitor's denominator: it can only ask "did flagging help this user?" if it
            // knows which flagged days were shown to them.
            //
            // Keyed on the ROW'S OWN `day`, carried out of `headacheCandidate` as a plain value
            // BEFORE the `await` above — not a recomputed `startOfDay(for: now)`, and not a field
            // read off the `@Model` after a suspension. A device that changed timezone since the
            // freeze recomputes `startOfDay` differently, and `markRiskAlerted` matches on `day`
            // exactly, so a recomputed key would silently mark nothing.
            if let headacheRowDay { try? localStore.markRiskAlerted(day: headacheRowDay) }
        }
        for n in fire { await post(n, hit: hitByNotif[n], signals: headacheSignals) }
    }

    /// Whether `n` is one of the #85 skin-temp/fever notifications that de-dupe per night (see
    /// `markNight`). Membership is the single `TempFeverNotifications.notificationSet` source of
    /// truth, so a new skin-temp case can't silently miss the ledger and regress to every-2h re-fire.
    private static func isTempFever(_ n: HealthNotification) -> Bool {
        TempFeverNotifications.notificationSet.contains(n)
    }

    /// Compute the latest night's skin-temp anomaly flags (#69) + suspected fever (#72), then map
    /// them to notifications (#85). Reuses the SAME canonical SkinTempBaseline offset the Sleep card
    /// shows — temperature is not recomputed for fever.
    ///
    /// Also returns the raw `fever` verdict, so the #183 morning-verdict branch can reuse THIS
    /// computation for its own fever suppression instead of assembling a second skin-temp report
    /// off a second 40-night fetch. One owner for "is this a fever morning", so the fever alert and
    /// the suppression it drives can never disagree.
    private func tempFeverCandidates(store: LocalStore,
                                     restingHRDaily: [RestingHR.DailyValue]?)
        -> (candidates: [HealthNotification], night: Date?, fever: Bool) {
        guard let latest = try? store.latestSleepSummary(), latest.skinTempC > 0 else {
            // No usable overnight temperature ⇒ no temp offset ⇒ `VitalsBaseline.suspectedFever`
            // would return false anyway (it requires one). Reporting `false` here is that same
            // answer, not a substituted value.
            return ([], nil, false)
        }
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
        let fever = suspectedFever(store: store, tempOffsetC: report.offsetC,
                                   restingHRDaily: restingHRDaily)
        let notifs = TempFeverNotifications.notifications(flags: report.flags, feverSuspected: fever)
        return (notifs, tonightDay, fever)
    }

    /// The ~30-day resting-HR daily series, ascending by day. Lifted verbatim out of
    /// `suspectedFever` (#72) so it can be computed ONCE per evaluate pass and read by two
    /// consumers — the fever cross-check below and the overnight-signals engine (#183).
    ///
    /// Not `private`: the three background delivery paths that run the engine
    /// (`RingSession.deliverBackgroundResults`, the BGTask handler, the Sleep Focus-off runner)
    /// compute it here and hand the SAME array to both, because this fetch is the expensive part of
    /// a pass — `StoredSample` has no index on `start`, so a ~30-day scan runs on the main actor
    /// several times an hour and paying for it twice is not affordable on a bounded background wake.
    ///
    /// Byte-identical to the inline version it replaces: same window (`maxBaselineDays + 2` days
    /// back from `Date()` — deliberately NOT the caller's `now`, unchanged), same
    /// `recentSamples(kind: .heartRate,)` fetch and try?-to-empty fallback, same `HRSample` mapping,
    /// same `RestingHR.dailyValues` defaults, same ascending sort.
    func restingHRDailySeries(store: LocalStore) -> [RestingHR.DailyValue] {
        let since = Date().addingTimeInterval(-Double(VitalsBaseline.Config().maxBaselineDays + 2) * 86_400)
        let hr = ((try? store.recentSamples(kind: .heartRate, since: since)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        return RestingHR.dailyValues(hr: hr).sorted { $0.day < $1.day }
    }

    /// Resting-HR daily series → personal baseline, cross-referenced with the temp offset for the
    /// fever flag. Returns false on insufficient history (never a false positive).
    ///
    /// `restingHRDaily` is the series the caller already computed on this pass, or nil. Nil keeps the
    /// original LAZY behaviour exactly: the fetch happens only after the `tempOffsetC` guard passes,
    /// so a pass that never reaches a temp offset still costs no scan.
    private func suspectedFever(store: LocalStore, tempOffsetC: Double?,
                                restingHRDaily: [RestingHR.DailyValue]?) -> Bool {
        guard let tempOffsetC else { return false }
        let daily = restingHRDaily ?? restingHRDailySeries(store: store)
        guard let today = daily.last?.bpm else { return false }
        let prior = daily.dropLast().map(\.bpm)
        return VitalsBaseline.suspectedFever(restingHRToday: today, restingHRPrior: Array(prior),
                                             skinTempOffsetC: tempOffsetC)
    }

    // MARK: - #183 morning overnight-signals verdict

    /// UserDefaults key the AUTO-RETIRE QUALITY MONITOR writes when this user's own logged headaches
    /// show that flagging is not helping them. READ-ONLY here — the monitor owns every write.
    ///
    /// The per-user statistics the plan of record specified as a PERMISSION GATE ("no alert until
    /// your own labels show the detector beats chance") are still computed; their polarity is simply
    /// inverted. Gating on proof meant ~10 months of silence for a typical episodic user (§1.1) for
    /// a notification that only ever claims to have MEASURED something, so the alert now unlocks at
    /// the natural floor (21 frozen days, below which there is no band at all) and the statistics
    /// switch it back off for the users it demonstrably does not help.
    ///
    /// Declared here rather than in `HeadacheDefaults` only because that file is not owned by this
    /// change; the string is the canonical one and should be hoisted into `HeadacheDefaults` when
    /// the monitor lands, WITHOUT changing its value (a rename orphans every retired user's flag).
    static let headacheRetiredKey = "headache.alerts.retired"

    /// Whether this morning's FROZEN overnight-signals verdict should raise the notification, and
    /// which signals to name in it. `nil` = do not fire.
    ///
    /// Gates are ordered CHEAPEST FIRST because this runs on every evaluate pass — several times an
    /// hour, on background wakes. The early returns only ORDER the work: every one of them mirrors a
    /// condition that `HeadacheSignsNotifications.candidates` re-checks, and that Kit call is the
    /// single shipped decision (it is what the CLI tests exercise).
    ///
    /// SUPPRESSION IS RE-DERIVED AS OF NOW, not read off the frozen row (which has no such column,
    /// deliberately). The frozen row records what was true when the score was taken, hours earlier;
    /// suppression answers a different question — "should we interrupt this person right now" — and
    /// a headache logged after the freeze must silence the alert. The SCORE is untouched either way.
    private func headacheCandidate(store: LocalStore, now: Date,
                                   lastNotifiedDay: [HealthNotification: Int],
                                   feverSuspected: Bool?,
                                   restingHRDaily: [RestingHR.DailyValue]?)
        -> (dayKey: Int, rowDay: Date, signals: [HeadacheSignals.Feature])? {
        // A background launch never renders any view, so it cannot rely on the UI having registered
        // defaults — an unregistered read returns a spurious `false` that happens to match today's
        // documented default and would silently stop matching if it ever changed.
        HeadacheDefaults.register()
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: HeadacheDefaults.enabled)
        let retired = defaults.bool(forKey: Self.headacheRetiredKey)
        guard enabled, !retired else { return nil }

        let dayKey = HeadacheSignsNotifications.dayKey(for: now)
        guard HeadacheSignsNotifications.withinDeliveryWindow(now),
              !HeadacheSignsNotifications.freshForDay([.headacheSigns], day: dayKey,
                                                      lastNotifiedDay: lastNotifiedDay).isEmpty
        else { return nil }

        // The BAND OF RECORD — the frozen row, never a live recompute, so the alert cannot disagree
        // with the card the user opens two seconds later.
        guard let frozen = HeadacheEngine().frozenToday(store: store, now: now) else { return nil }
        let band = HeadacheSignals.Band(rawValue: frozen.bandRaw)
        guard band == .flagged else { return nil }

        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let tuning = HeadacheSignals.Tuning()
        // Counted over the SAME trailing window the band was taken against (`HeadacheEngine.snapshot`
        // builds `priorIndices` from exactly this range). A lifetime count would unlock a user whose
        // 21 rows are spread over two years and whose percentile budget is therefore built on almost
        // nothing. `riskDays` is `[from, to)`, so today's own row is excluded — the same convention
        // the banding window uses.
        let bandStart = cal.date(byAdding: .day, value: -tuning.bandWindowDays, to: day) ?? day
        let frozenDayCount = ((try? store.riskDays(from: bandStart, to: day)) ?? []).count

        // A severity-1 (`notPresent`) entry records the ABSENCE of a headache, so it must not
        // suppress anything — the same distinction the Apple Health import refuses to blur.
        let end = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let loggedToday = ((try? store.headacheEntries(from: day, to: end)) ?? [])
            .contains { $0.onset <= now && $0.severityRaw != 1 }
        // Reuse the fever verdict the temp branch already computed this pass; only pay for it here
        // when that branch did not run (the user turned the temp/fever alerts off).
        let fever = feverSuspected
            ?? tempFeverCandidates(store: store, restingHRDaily: restingHRDaily).fever
        let suppression: HeadacheSignals.Suppression? = fever ? .fever
            : (loggedToday ? .headacheAlreadyLogged : nil)

        guard !HeadacheSignsNotifications.candidates(
                enabled: enabled, band: band, suppressedBy: suppression,
                frozenDayCount: frozenDayCount, retired: retired, now: now,
                lastNotifiedDay: lastNotifiedDay, tuning: tuning, calendar: cal).isEmpty
        else { return nil }

        // Flatten everything the fire path needs OUT of the `@Model` here, before any suspension.
        return (dayKey, frozen.day,
                HeadacheSignsNotifications.topSignals(Self.weightedContributions(frozen)))
    }

    /// Each feature's WEIGHTED share of the frozen index (effective weight × ramp position), read
    /// back out of the row's `contributionsJSON`.
    ///
    /// Absent features are dropped rather than mapped to 0: `HeadacheContributionRecord.c` is `nil`
    /// for "we did not measure this", and a 0 means "measured, and ordinary". Collapsing the two is
    /// the fabrication this whole feature is written to avoid, and here it would additionally put a
    /// feature we never measured into the sentence naming what drifted.
    private static func weightedContributions(_ row: StoredHeadacheRisk)
        -> [HeadacheSignals.Feature: Double] {
        HeadacheRiskCoding.decodeContributions(row.contributionsJSON)
            .compactMapValues { record in
                guard let contribution = record.c, contribution > 0 else { return nil }
                return record.w * contribution
            }
    }

    // MARK: - Reminders (#84)

    /// Evaluate all three app-side reminders (sedentary / wear / bedtime) and fire any
    /// survivors through the ONE shared gate (quiet hours + anti-spam backoff). Safe to
    /// call liberally — a no-op when nothing crosses a threshold or everything is held by
    /// the gate. Pass `sleepEnabled = true` and the configured bed/wake minutes to enable
    /// the bedtime reminder; pass `sleepEnabled = false` to skip it.
    ///
    /// `includeSedentary` (#145): the sedentary rule reads the persisted `lastActivityAt`, which is
    /// STALE before a foreground sync lands the walk's step delta — so evaluating it pre-sync fires a
    /// false "time to move!" right after activity (and the 2h backoff then suppresses the real one).
    /// The caller passes `false` on the plain scene-active pass (wear + bedtime still evaluate there,
    /// since they don't need fresh step data) and `true` only after a sync completes, so the rule
    /// runs against fresh data.
    func evaluateReminders(session: RingSession?,
                           sleepBedMinutes: Int, sleepWakeMinutes: Int, sleepEnabled: Bool,
                           includeSedentary: Bool = true,
                           now: Date = Date()) async {
        ReminderDefaults.register()
        let d = UserDefaults.standard
        var candidates: [HealthNotification] = []

        // Sedentary / move reminder — only when `includeSedentary` (post-sync), so it never fires on
        // a stale pre-sync `lastActivityAt` reading (#145).
        if includeSedentary, d.bool(forKey: ReminderDefaults.sedentaryEnabled) {
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
            let hasSavedRing = (d.stringArray(forKey: "com.opencircuit.ring.peripheralIDs")?.isEmpty == false)
                || d.string(forKey: "com.opencircuit.ring.peripheralID") != nil
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
        let lastFired = store.lastFired()
        // #137: the bedtime reminder is a user-SCHEDULED wind-down self-reminder, not a body-vital
        // alert the user is trying to mute overnight. Its only firing window is
        // [bed − minutesBefore, bed), which for a typical post-22:00 bedtime falls entirely inside the
        // default 22:00–07:00 quiet window — so routing it through the shared quiet gate would suppress
        // it every single night. Split it out: bedtime bypasses the quiet-hours mute but STILL gets the
        // anti-spam backoff (via `lastFired`), so it fires at most once per night. Every OTHER reminder
        // (wear / sedentary) stays under the quiet gate unchanged — no regression to the overnight mute.
        let bedtime = candidates.filter { $0 == .bedtimeReminder }
        let others  = candidates.filter { $0 != .bedtimeReminder }
        var fire = gate.filter(others, now: now, lastFired: lastFired, quietHours: quiet)
        fire += gate.filter(bedtime, now: now, lastFired: lastFired, quietHours: QuietHours(enabled: false))
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

    /// UserDefaults flag: we've already attempted the one-time provisional→full upgrade prompt for
    /// the opted-in body-vital alerts (#133). iOS only ever presents that upgrade prompt once, so
    /// this stops us re-attempting on every toggle/alert fire and makes the user's choice stick —
    /// "Keep Delivering Quietly" stays provisional (silent), "Turn Off" → `.denied` (the #136 banner
    /// then surfaces so they can re-enable). Shared by the engine's `ensureAuthorized()`
    /// and the Settings opt-in path (`requestFullAuthorizationIfNeeded`).
    static let fullAuthRequestedKey = "alerts.health.fullAuthRequested"

    /// Request notification authorization LAZILY — only the first time there's actually something
    /// to post, so a user who never crosses a threshold is never prompted. These are alerts the
    /// user opted into in Settings, so we request a standard (visible) authorization.
    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .ephemeral:
            return true
        case .provisional:
            // A provisional-only grant (won first by the nightly morning-summary / observability
            // paths, #133) delivers EVERY notification silently — including the high-HR / low-SpO2 /
            // fever alerts the user opted into. Attempt the one-time upgrade to full alert+sound+badge
            // so those surface with a banner + sound, then deliver regardless of the outcome:
            // provisional delivery still beats dropping the alert. This does NOT touch the provisional
            // REQUEST sites in RingSession / ObservabilityStore — those stay quiet by design.
            await requestFullAuthorizationIfNeeded()
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    /// Escalate a provisional (or not-yet-determined) grant to FULL alert+sound+badge notification
    /// authorization for the opted-in body-vital alerts (#133). Call from a FOREGROUND consent
    /// moment — the Settings ▸ Health-alerts opt-in toggles — where iOS can actually present the
    /// prompt (a background wake-drain cannot). This pre-empts the provisional grant that the
    /// morning-summary / observability paths would otherwise win first, so an enabled alert delivers
    /// loudly instead of silently.
    ///
    /// Idempotent + flag-guarded (`fullAuthRequestedKey`): attempts the upgrade at most once, since
    /// iOS shows the provisional→explicit prompt only a single time. A prior choice is respected
    /// (we don't nag): "Keep Delivering Quietly" stays provisional, "Turn Off" → `.denied`.
    /// Already-authorized/ephemeral is a no-op.
    /// Deliberately leaves the morning-summary (`RingSession`) / observability (`ObservabilityStore`)
    /// request sites untouched — those are SUPPOSED to stay provisional.
    func requestFullAuthorizationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.fullAuthRequestedKey) else { return }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined, .provisional:
            // iOS can only present the permission prompt while the app is FOREGROUND-ACTIVE. If we
            // requested here in the background — e.g. an opted-in alert firing during an hourly
            // wake-drain, and these alerts are ON BY DEFAULT — no prompt would appear, yet the
            // one-shot flag below would still be burned, permanently stranding a provisional user
            // (#133). So gate on `.active`: a background provisional fire still DELIVERS (the caller
            // `ensureAuthorized()` returns true for `.provisional`), and the flag stays unburned so
            // the next foreground eval or the Settings toggle presents the real upgrade prompt.
            guard UIApplication.shared.applicationState == .active else { return }
            // Foreground: iOS presents the standard opt-in prompt (or the provisional→explicit
            // upgrade prompt). Mark attempted regardless of the result — the prompt is one-shot.
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            defaults.set(true, forKey: Self.fullAuthRequestedKey)
        case .authorized, .ephemeral:
            // Already delivering visibly — record so we skip the probe next time.
            defaults.set(true, forKey: Self.fullAuthRequestedKey)
        default:
            // .denied: respect it (the Settings banner, #136, is where the user re-enables). Leave
            // the flag unset so a later re-enable can still upgrade to full when it next fires.
            break
        }
    }

    /// Body-vital alerts carry the medical disclaimer; #84 lifestyle reminders and the #86
    /// charging-complete banner do NOT (they aren't sensor-vital readings). This matches the
    /// stated intent in `copy(for:)` ("no medical disclaimer appended — they're lifestyle
    /// reminders"), which the previous unconditional append in `post` contradicted.
    private static func appendsDisclaimer(_ n: HealthNotification) -> Bool {
        // Exhaustive (no `default`) so a new enum case forces a compile-time decision here. The
        // temp/fever cases resolve through the shared `TempFeverNotifications.notificationSet` so
        // this and `isTempFever` can never drift.
        switch n {
        case .highHR, .lowSpO2, .elevatedHRInactive:
            return true
        case .sedentaryReminder, .wearReminder, .bedtimeReminder, .chargingComplete:
            return false
        case .skinTempRise, .skinTempDrop, .skinTempFluctuationRise, .skinTempFluctuationDrop, .fever:
            return TempFeverNotifications.notificationSet.contains(n)
        case .headacheSigns:
            // YES — it is built entirely from ring sensor readings, and it is the one alert a user is
            // most likely to over-read as a prediction. The disclaimer's "not a diagnosis" line is
            // the second half of the copy rule the body's own "it is not a forecast" starts.
            return true
        }
    }

    private func post(_ n: HealthNotification, hit: HealthAlertHit?,
                      signals: [HeadacheSignals.Feature] = []) async {
        let content = UNMutableNotificationContent()
        let copy = Self.copy(for: n, hit: hit, signals: signals)
        content.title = copy.title
        content.body = Self.appendsDisclaimer(n) ? copy.body + "\n\n" + Self.disclaimer : copy.body
        content.sound = .default
        // Carry the category ONLY for #183, so the notification lands in the category AppDelegate
        // registered — which deliberately declares NO ACTIONS (see the label-bias note there).
        // Everything else keeps the empty default category, unchanged.
        if n == .headacheSigns {
            content.categoryIdentifier = HeadacheSignsNotifications.categoryIdentifier
        }
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

    /// `signals` is used only by `.headacheSigns` — the ring-derived features that drifted furthest,
    /// already ranked. Defaulted so every other call site (and `HealthAlertCopyTests`) is unchanged.
    static func copy(for n: HealthNotification, hit: HealthAlertHit?,
                     signals: [HeadacheSignals.Feature] = []) -> (title: String, body: String) {
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
            // Cite the user's CONFIGURED threshold, not the completing sample's bpm. `hit.value` here is
            // the reading that finished the 10-min run (HealthAlerts elevatedHRInactive), NOT the peak
            // and NOT the threshold — phrasing it as "above N bpm" misrepresented N as the trigger.
            let threshold = HealthAlertDefaults.thresholds().elevatedHRBpm
            return ("Elevated heart rate while inactive",
                    "Your heart rate stayed above your \(threshold) bpm threshold "
                    + "for over 10 minutes while you were inactive. This can indicate a change in how you feel.")
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
        // #183 — the morning overnight-signals verdict. The copy lives in the Kit (pure, CLI-tested)
        // because its wording is the load-bearing part of the design, not a presentation detail:
        // it reports WHAT WE MEASURED and never what we predict, and the word "headache" must not
        // appear in the title or body at all. `HeadacheSignsNotifications` carries the full
        // reasoning and `HealthAlertsHeadacheTests` pins it.
        case .headacheSigns:
            return HeadacheSignsNotifications.copy(topSignals: signals)
        }
    }
}
