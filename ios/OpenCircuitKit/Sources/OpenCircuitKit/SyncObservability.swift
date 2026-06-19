// Observability/alerting policy (#44). As an always-on tracker the app can fail silently —
// a throttled background task, a revoked Health grant, a ring left off the charger. This holds
// the PURE decision logic for when to warn the user (staleness + low-battery thresholds and the
// per-condition debounce) plus a bounded ring-buffer helper, so the policy unit-tests on the CLI
// without any Apple frameworks. The UserDefaults persistence + UNUserNotificationCenter glue
// lives in the app target (Observability/ObservabilityStore.swift).

import Foundation

/// The silent-failure conditions worth a local notification.
public enum SyncAlert: String, CaseIterable, Codable, Sendable {
    case notSynced       // no successful ring sync in > staleSyncThreshold
    case lowBattery      // ring battery at/under lowBatteryThreshold
    case healthAuthLost  // Health share access was granted before and is now off
}

/// Thresholds + debounce for the silent-failure alerts. Pure value type: the app feeds it the
/// current observed state and the last time each alert fired, and it returns which alerts should
/// fire now — never firing the same condition twice inside `renotifyInterval`.
public struct SyncAlertPolicy: Sendable, Equatable {
    /// No successful sync in this long → `notSynced`.
    public var staleSyncThreshold: TimeInterval
    /// Ring battery at/under this percent → `lowBattery`.
    public var lowBatteryThreshold: Int
    /// Minimum spacing between repeat notifications of the SAME condition (anti-spam).
    public var renotifyInterval: TimeInterval

    public init(staleSyncThreshold: TimeInterval = 6 * 3600,
                lowBatteryThreshold: Int = 15,
                renotifyInterval: TimeInterval = 6 * 3600) {
        self.staleSyncThreshold = staleSyncThreshold
        self.lowBatteryThreshold = lowBatteryThreshold
        self.renotifyInterval = renotifyInterval
    }

    /// The conditions currently true, ignoring debounce.
    /// - `lastSuccessfulSync == nil` is treated as "no baseline yet" (a brand-new user who has
    ///   never synced is NOT nagged) — staleness only fires relative to a prior success.
    /// - `batteryPercent == nil` (e.g. the background session is torn down) skips the battery
    ///   check rather than firing a false low-battery alert.
    /// - `healthAuthLost` only fires when Health was authorized before (`healthEverAuthorized`)
    ///   and is now off — so a user who simply never opted into Health isn't told it "broke".
    public func activeConditions(now: Date,
                                 lastSuccessfulSync: Date?,
                                 batteryPercent: Int?,
                                 healthAuthorized: Bool,
                                 healthEverAuthorized: Bool) -> Set<SyncAlert> {
        var conditions: Set<SyncAlert> = []
        if let last = lastSuccessfulSync, now.timeIntervalSince(last) > staleSyncThreshold {
            conditions.insert(.notSynced)
        }
        if let battery = batteryPercent, battery <= lowBatteryThreshold {
            conditions.insert(.lowBattery)
        }
        if healthEverAuthorized && !healthAuthorized {
            conditions.insert(.healthAuthLost)
        }
        return conditions
    }

    /// Which alerts to actually post now: an active condition whose last notification is older
    /// than `renotifyInterval` (or never sent). Returned in a stable `SyncAlert.allCases` order.
    public func alertsToFire(now: Date,
                             lastSuccessfulSync: Date?,
                             batteryPercent: Int?,
                             healthAuthorized: Bool,
                             healthEverAuthorized: Bool,
                             lastFired: [SyncAlert: Date]) -> [SyncAlert] {
        let active = activeConditions(now: now,
                                      lastSuccessfulSync: lastSuccessfulSync,
                                      batteryPercent: batteryPercent,
                                      healthAuthorized: healthAuthorized,
                                      healthEverAuthorized: healthEverAuthorized)
        return SyncAlert.allCases.filter { alert in
            guard active.contains(alert) else { return false }
            if let fired = lastFired[alert], now.timeIntervalSince(fired) < renotifyInterval {
                return false
            }
            return true
        }
    }
}

/// Append-and-cap helper for a fixed-size ring buffer (the background-task outcome log, #44).
/// Trims from the FRONT so the newest `limit` entries survive. Pure so the app's JSON-in-
/// UserDefaults log stays trivially testable.
public enum BoundedLog {
    public static func appendCapped<Element>(_ element: Element,
                                             to list: [Element],
                                             limit: Int) -> [Element] {
        guard limit > 0 else { return [] }
        var out = list
        out.append(element)
        if out.count > limit { out.removeFirst(out.count - limit) }
        return out
    }
}
