import Foundation
import SwiftData
import OpenCircuitKit

/// The user's heart-rate zone choices in UserDefaults, and the ONE reader every zone surface uses
/// (decision 83b). Storage is plain keys so a SwiftUI view can bind `@AppStorage` to them; no
/// SwiftData model is involved. The pure rules (bounds, validation, classification) live in the Kit's
/// `HeartRateZones`.
enum HeartRateZoneDefaults {
    static let methodKey = "hrZones.method"
    /// 0 (or absent) = Automatic (`220 − age`); otherwise the typed value, 100…230.
    static let manualMaxHRKey = "hrZones.manualMaxHR"
    /// Five comma-separated lower bounds, e.g. "95,114,133,152,171".
    static let customBoundsKey = "hrZones.customLowerBounds"

    static func settings(_ defaults: UserDefaults = .standard) -> HeartRateZoneSettings {
        HeartRateZoneSettings(
            method: defaults.string(forKey: methodKey).flatMap(HeartRateZoneMethod.init(rawValue:)) ?? .percentOfMax,
            manualMaxHR: manualMaxHR(defaults),
            customLowerBounds: customBounds(defaults.string(forKey: customBoundsKey))
                ?? HeartRateZoneSettings.defaultCustomLowerBounds)
    }

    /// The typed max HR when it is valid, else nil (Automatic).
    static func manualMaxHR(_ defaults: UserDefaults = .standard) -> Int? {
        let stored = defaults.integer(forKey: manualMaxHRKey)
        return MaxHeartRate.isValidManual(stored) ? stored : nil
    }

    static func save(_ settings: HeartRateZoneSettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.method.rawValue, forKey: methodKey)
        defaults.set(settings.manualMaxHR.flatMap { MaxHeartRate.isValidManual($0) ? $0 : nil } ?? 0,
                     forKey: manualMaxHRKey)
        defaults.set(encode(settings.customLowerBounds), forKey: customBoundsKey)
    }

    static func encode(_ bounds: [Int]) -> String { bounds.map(String.init).joined(separator: ",") }

    /// The stored custom bounds, or nil when the text is absent or not five integers. Validity (strictly
    /// increasing, in range) is `HeartRateZones.isValidCustom`'s call, made when the zones are built.
    static func customBounds(_ text: String?) -> [Int]? {
        guard let text else { return nil }
        let parts = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 5 ? parts : nil
    }

    /// The zones for `profile`. The age is floored at 1, as the workout zones always have been.
    static func zones(profile: UserProfile, restingHR: Double?,
                      defaults: UserDefaults = .standard) -> HeartRateZones {
        HeartRateZones(settings: settings(defaults), age: max(profile.age, 1), restingHR: restingHR)
    }

    /// The user's zones as of now, for a screen that re-derives from stored readings (workout history,
    /// the weekly training load): the stored profile and choices, and for % of reserve the active
    /// device's resting heart rate, read off the main actor.
    @MainActor
    static func currentZones(defaults: UserDefaults = .standard) async -> HeartRateZones {
        let profile = HealthKitWriter.storedUserProfile(defaults)
        var resting: Double?
        if settings(defaults).method == .percentOfReserve, let container = OpenCircuitApp.sharedContainer {
            resting = await HeartRateZoneRestingHR.latest(container: container, log: LocalStore.ownershipLog())
        }
        return zones(profile: profile, restingHR: resting, defaults: defaults)
    }

    /// The zones for a workout that is starting now: the stored profile and choices, and, only for the
    /// % of reserve method, the active device's resting heart rate read from `store`.
    @MainActor
    static func zonesForNewWorkout(profile: UserProfile, store: LocalStore?,
                                   defaults: UserDefaults = .standard) -> HeartRateZones {
        let resting = settings(defaults).method == .percentOfReserve
            ? store.flatMap { HeartRateZoneRestingHR.latest(store: $0) } : nil
        return zones(profile: profile, restingHR: resting, defaults: defaults)
    }
}

/// The resting heart rate % of reserve zones are built on: the newest day of the ACTIVE device's own
/// daily resting-HR series (decision 29: baselines are per device) — the series the Resting HR tile
/// and Vitals Status judge, so a day with too few readings has no value and the previous day's counts.
enum HeartRateZoneRestingHR {
    static let lookbackDays = 14

    /// On the main actor, for the moment a workout starts.
    @MainActor
    static func latest(store: LocalStore, now: Date = Date()) -> Double? {
        let since = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let hr = ((try? store.recentOwnSamples(kind: .heartRate, since: since)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        return RestingHR.dailyValues(hr: hr, daytimeCoverage: RestingHR.dayCoverage)
            .sorted { $0.day < $1.day }.last?.bpm
    }

    /// Off the main actor, for screens: the read is the alert passes' own (`HealthNotificationCenter`).
    static func latest(container: ModelContainer, log: DeviceOwnershipLog, now: Date = Date()) async -> Double? {
        let since = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        return await HealthNotificationCenter.restingHRDailySeries(container: container, since: since, log: log).last?.bpm
    }
}

/// The Profile row's one-line summary of the zone choices.
enum HeartRateZoneSummary {
    static func profileRowValue(age: Int, defaults: UserDefaults = .standard) -> String {
        let settings = HeartRateZoneDefaults.settings(defaults)
        let maxHR = settings.maxHR(age: age)
        return "Max \(maxHR) bpm" + (settings.usesManualMaxHR ? "" : " (auto)")
    }
}
