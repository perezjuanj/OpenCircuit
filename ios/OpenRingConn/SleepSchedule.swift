import Foundation
import HealthKit
import OpenRingKit

// Sleep-schedule abstraction.
//
// The app needs to bound a "night window" (today: for the overnight skin-temp average;
// later: to constrain on-device sleep detection). We get that window from the user's
// sleep schedule behind ONE protocol with TWO implementations and ONE swap point:
//
//   • `ManualSleepSchedule`     — works TODAY with no entitlement; reads a user-set
//                                 bedtime + wake (minutes-since-midnight, @AppStorage).
//   • `HealthKitSleepSchedule`  — reads the REAL iOS Sleep schedule from HealthKit's
//                                 `sleepAnalysis` samples. Compiles now, but returns nil
//                                 when unauthorized / no entitlement (we ship without the
//                                 HealthKit entitlement — see ios/project.yml).
//   • `SleepSchedule.current`   — the swap point: prefer HealthKit when it returns data,
//                                 else fall back to the manual schedule.
//
// "Flipping the switch" once a paid dev account is approved == enabling the HealthKit
// entitlement (uncomment the `entitlements:` block in ios/project.yml, re-run
// `xcodegen generate`) and granting read access at the prompt. `HealthKitWriter.request-
// Authorization` already requests `sleepAnalysis` READ, so no auth-code change is needed:
// with the entitlement on, `HealthKitSleepSchedule` starts returning data and wins at the
// selector — no change in THIS file or its callers.

/// Returns the user's sleep window (bedtime → wake) for the night around `date`.
protocol SleepScheduleProviding {
    func sleepWindow(forNightEndingNear date: Date) async -> DateInterval?
}

// MARK: - Persistence keys (shared by the provider and the settings UI)

/// `@AppStorage`/`UserDefaults` keys for the manual schedule. The settings UI writes
/// these via `@AppStorage`; `ManualSleepSchedule` reads the same keys from `UserDefaults`.
enum SleepScheduleDefaults {
    static let enabled = "sleepSchedule.enabled"
    static let bedMinutes = "sleepSchedule.bedMinutes"
    static let wakeMinutes = "sleepSchedule.wakeMinutes"

    /// Defaults: disabled, bed 22:30, wake 06:30. Disabled-by-default means the manual
    /// window does NOT override the existing stored-sleep span unless the user opts in.
    static let defaultBedMinutes = 22 * 60 + 30   // 1350
    static let defaultWakeMinutes = 6 * 60 + 30    // 390

    /// Register defaults so `integer(forKey:)` returns the intended bed/wake (not 0)
    /// before the user has ever opened settings.
    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            bedMinutes: defaultBedMinutes,
            wakeMinutes: defaultWakeMinutes,
        ])
    }
}

// MARK: - Manual schedule (works today, no entitlement)

/// Reads a user-set bedtime + wake time-of-day and builds the night's `DateInterval`
/// via OpenRingKit's pure `SleepWindow` math (cross-midnight aware). Returns nil when the
/// user hasn't enabled a manual schedule.
struct ManualSleepSchedule: SleepScheduleProviding {
    var enabled: Bool
    var bedMinutes: Int
    var wakeMinutes: Int

    /// Build from `UserDefaults` (the same store the `@AppStorage` settings UI writes to).
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> ManualSleepSchedule {
        SleepScheduleDefaults.register(defaults)
        return ManualSleepSchedule(
            enabled: defaults.bool(forKey: SleepScheduleDefaults.enabled),
            bedMinutes: defaults.integer(forKey: SleepScheduleDefaults.bedMinutes),
            wakeMinutes: defaults.integer(forKey: SleepScheduleDefaults.wakeMinutes)
        )
    }

    func sleepWindow(forNightEndingNear date: Date) async -> DateInterval? {
        guard enabled else { return nil }
        return SleepWindow.interval(bedMinutes: bedMinutes,
                                    wakeMinutes: wakeMinutes,
                                    nightEndingNear: date)
    }
}

// MARK: - HealthKit schedule (compiles now, no-ops without entitlement)

/// Derives the night's window from recent `sleepAnalysis` samples (the iOS Sleep
/// schedule / Sleep Focus writes `inBed`; watches/other apps write `asleep*`). Returns
/// nil — never crashes — when HealthKit is unavailable, unauthorized, or has no entitlement.
struct HealthKitSleepSchedule: SleepScheduleProviding {
    private let store = HKHealthStore()
    /// How far back from `date` to look for the night's samples.
    var lookback: TimeInterval = 18 * 3600

    func sleepWindow(forNightEndingNear date: Date) async -> DateInterval? {
        // Guard 1: device/platform support (Simulator without Health, etc.).
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let sleepType = HKCategoryType(.sleepAnalysis)

        // Guard 2: authorization. We only SHARE today (see HealthKitWriter), so read of
        // sleepAnalysis is not authorized and the query below returns empty/errors — which
        // we treat as "no schedule" and fall back. Once the entitlement is enabled and the
        // user grants read access, the query returns real samples and this wins. We do NOT
        // request authorization here (avoids a permission prompt on a passive lookup).
        let inBed = HKCategoryValueSleepAnalysis.inBed.rawValue
        let asleepValues = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)

        let start = date.addingTimeInterval(-lookback)
        let end = date.addingTimeInterval(6 * 3600)   // allow an in-progress morning
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                     options: .strictStartDate)

        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, result, _ in
                cont.resume(returning: (result as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return nil }

        // Prefer explicit `inBed` spans (the iOS Sleep schedule); fall back to asleep spans.
        let relevant = samples.filter { $0.value == inBed }
        let pool = relevant.isEmpty ? samples.filter { asleepValues.contains($0.value) } : relevant
        guard let earliest = pool.map(\.startDate).min(),
              let latest = pool.map(\.endDate).max(),
              latest > earliest else { return nil }
        return DateInterval(start: earliest, end: latest)
    }
}

// MARK: - Swap point

/// The single place that decides which schedule wins. HealthKit (the real iOS Sleep
/// schedule) is preferred when it returns data; otherwise the manual schedule. This is
/// the one symbol whose behavior changes when the HealthKit entitlement is later enabled.
enum SleepSchedule {
    static func current(forNightEndingNear date: Date,
                        healthKit: SleepScheduleProviding = HealthKitSleepSchedule(),
                        manual: SleepScheduleProviding = ManualSleepSchedule.fromDefaults())
        async -> DateInterval? {
        if let hk = await healthKit.sleepWindow(forNightEndingNear: date) { return hk }
        return await manual.sleepWindow(forNightEndingNear: date)
    }
}
