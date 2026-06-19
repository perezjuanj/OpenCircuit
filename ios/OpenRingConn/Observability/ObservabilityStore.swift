import Foundation
import OpenRingKit
import UserNotifications

// Observability/alerting glue for the always-on tracker (#44). The PURE policy (thresholds +
// debounce + ring-buffer trim) lives in OpenRingKit (`SyncObservability.swift`); this file is the
// app-side persistence + notification plumbing. Deliberately UserDefaults-backed, NOT SwiftData:
// a separate, schema-free store avoids a migration and a collision with the steps lane. Plain
// `struct` over `UserDefaults` (itself thread-safe), so the foreground UI and the background task
// can both record without an actor hop.

/// One recorded sync/background-task outcome for the user-visible activity log.
struct TaskRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case appRefresh   // BGAppRefreshTask (short ~30 s window)
        case processing   // BGProcessingTask (longer window — gives background HR a chance, #45)
        case foreground   // a sync the user triggered / a foreground auto-refresh
    }
    var id = UUID()
    var date: Date
    var kind: Kind
    var success: Bool
    var detail: String?
}

/// Reads/writes the observability timestamps + bounded outcome log in UserDefaults.
struct ObservabilityStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Keep the last N outcomes (newest survive — see `BoundedLog`). Small: this is a debug aid.
    static let logLimit = 40

    private enum Key {
        static let lastSync = "obs.lastSuccessfulSync"
        static let lastHealthWrite = "obs.lastHealthWrite"
        static let bgLastRun = "obs.bgLastRun"
        static let bgLastScheduled = "obs.bgLastScheduled"
        static let log = "obs.taskLog"
        static let alertFired = "obs.alertLastFired"        // [SyncAlert.rawValue: epoch]
        static let healthEverAuthorized = "obs.healthEverAuthorized"
    }

    // MARK: Timestamps

    var lastSuccessfulSync: Date? { date(Key.lastSync) }
    var lastHealthWrite: Date? { date(Key.lastHealthWrite) }
    var bgLastRun: Date? { date(Key.bgLastRun) }
    var bgLastScheduled: Date? { date(Key.bgLastScheduled) }
    var healthEverAuthorized: Bool { defaults.bool(forKey: Key.healthEverAuthorized) }

    private func date(_ key: String) -> Date? {
        let t = defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Latch that Health share access was granted at least once, so a LATER revocation can be
    /// distinguished from "never opted in" (gates the `healthAuthLost` alert).
    func markHealthEverAuthorized() { defaults.set(true, forKey: Key.healthEverAuthorized) }

    // MARK: Recording

    /// Record a sync attempt's outcome. A success bumps "last successful sync"; any
    /// background-originated run (not `.foreground`) bumps "last background run" so the user can
    /// see whether iOS is actually waking the app. Appends to the bounded log either way.
    func recordSyncOutcome(kind: TaskRecord.Kind, success: Bool, detail: String?, at now: Date = Date()) {
        if kind != .foreground { defaults.set(now.timeIntervalSince1970, forKey: Key.bgLastRun) }
        if success { defaults.set(now.timeIntervalSince1970, forKey: Key.lastSync) }
        append(TaskRecord(date: now, kind: kind, success: success, detail: detail))
    }

    /// Record that we mirrored data into Apple Health (drives the "Last Health write" line).
    func recordHealthWrite(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastHealthWrite)
    }

    /// Record that we (re)submitted a BGTask request — lets the UI show "scheduled vs. last run"
    /// so a large gap reads as "iOS is throttling us", not "the app is broken".
    func recordScheduled(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.bgLastScheduled)
    }

    // MARK: Bounded outcome log

    func records() -> [TaskRecord] {
        guard let data = defaults.data(forKey: Key.log),
              let list = try? JSONDecoder().decode([TaskRecord].self, from: data) else { return [] }
        return list
    }

    private func append(_ record: TaskRecord) {
        let capped = BoundedLog.appendCapped(record, to: records(), limit: Self.logLimit)
        if let data = try? JSONEncoder().encode(capped) { defaults.set(data, forKey: Key.log) }
    }

    // MARK: Alert debounce persistence (consumed by SyncAlertPolicy)

    func alertLastFired() -> [SyncAlert: Date] {
        let raw = defaults.dictionary(forKey: Key.alertFired) as? [String: Double] ?? [:]
        var out: [SyncAlert: Date] = [:]
        for (k, v) in raw where v > 0 {
            if let alert = SyncAlert(rawValue: k) { out[alert] = Date(timeIntervalSince1970: v) }
        }
        return out
    }

    func markAlertsFired(_ alerts: [SyncAlert], at now: Date = Date()) {
        var raw = defaults.dictionary(forKey: Key.alertFired) as? [String: Double] ?? [:]
        for a in alerts { raw[a.rawValue] = now.timeIntervalSince1970 }
        defaults.set(raw, forKey: Key.alertFired)
    }
}

/// Posts the debounced silent-failure notifications (#44). One notification per condition per
/// `SyncAlertPolicy.renotifyInterval`; never spams. Authorization is requested LAZILY and
/// provisionally — the first time there's actually something to say — so a healthy user is never
/// prompted on launch and quiet alerts land in Notification Center without an upfront dialog.
struct LocalAlertCenter {
    var store = ObservabilityStore()
    var policy = SyncAlertPolicy()
    // Computed (not a stored property) so the synthesized memberwise init stays internal — i.e.
    // `LocalAlertCenter()` is callable from the other files that fire alerts.
    private var center: UNUserNotificationCenter { .current() }

    /// Evaluate the current state and post a debounced notification for each firing condition.
    /// No-op when nothing's wrong. `batteryPercent == nil` (e.g. the background session is already
    /// torn down) simply skips the low-battery check rather than firing falsely.
    func evaluate(now: Date = Date(), batteryPercent: Int?, healthAuthorized: Bool) async {
        let fire = policy.alertsToFire(
            now: now,
            lastSuccessfulSync: store.lastSuccessfulSync,
            batteryPercent: batteryPercent,
            healthAuthorized: healthAuthorized,
            healthEverAuthorized: store.healthEverAuthorized,
            lastFired: store.alertLastFired())
        guard !fire.isEmpty, await ensureAuthorized() else { return }
        for alert in fire { await post(alert) }
        store.markAlertsFired(fire, at: now)
    }

    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            // Provisional auth posts quietly (no upfront prompt) — appropriate for an alert the
            // user hasn't asked for but would want when something silently breaks.
            return (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) ?? false
        default:
            return false
        }
    }

    private func post(_ alert: SyncAlert) async {
        let content = UNMutableNotificationContent()
        switch alert {
        case .notSynced:
            content.title = "Ring not synced"
            content.body = "OpenCircuit hasn't synced your ring in a while. Open the app to refresh, and check Settings ▸ General ▸ Background App Refresh."
        case .lowBattery:
            content.title = "Ring battery low"
            content.body = "Your RingConn battery is low — charge it soon to keep tracking."
        case .healthAuthLost:
            content.title = "Apple Health access off"
            content.body = "OpenCircuit can no longer write to Apple Health. Re-enable it in Settings ▸ Health ▸ Data Access & Devices."
        }
        // One pending request per condition (stable id) — re-posting just refreshes it.
        let request = UNNotificationRequest(identifier: "obs.alert.\(alert.rawValue)",
                                            content: content, trigger: nil)
        try? await center.add(request)
    }
}
