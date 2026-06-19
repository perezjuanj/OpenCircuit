// WorkoutSession.swift — Pure workout analytics: HR-zone classification, time-in-zone,
// session aggregation. No HealthKit or CoreLocation imports; all app-framework concerns
// stay in the app target.
//
// Zone boundaries match the APK's SportRecordModel / "Exercise Heart Rate" screen
// (pp.txt:0x515c0, confirmed):
//   Warm-up       50–60% of maxHR  (data below 50% not counted — APK note)
//   Fat burning   61–70% of maxHR
//   Aerobic       71–80% of maxHR
//   Anaerobic     81–90% of maxHR
//   Extreme       91–100% of maxHR
//
// maxHR = 220 − age  (APK pp.txt:0x515c0 calculation formula).
//
// Live-HR (#45) WARNING: The 0x95→0x15 live-HR path is best-effort — it has no
// background-refresh and on-demand polling often misses updates. A long workout
// session is the worst case. This code records only ACTUAL decoded readings; it
// never fills gaps by interpolation or fabrication. Gaps are preserved and surfaced
// to the user. See issue #45 for the underlying reliability constraint.

import Foundation

// MARK: - Sport types

/// Sport types the app supports. Each maps to an HKWorkoutActivityType on the app side.
/// Outdoor types (walking, running, cycling, hiking) enable GPS route capture via
/// CoreLocation; indoor types (strength, yoga, other) do not.
public enum WorkoutSportType: String, Codable, CaseIterable, Sendable {
    case walkingOutdoor
    case runningOutdoor
    case cyclingOutdoor
    case hiking
    case strengthTraining
    case yoga
    case other

    public var displayName: String {
        switch self {
        case .walkingOutdoor: return "Outdoor Walking"
        case .runningOutdoor: return "Outdoor Running"
        case .cyclingOutdoor: return "Outdoor Cycling"
        case .hiking:         return "Hiking"
        case .strengthTraining: return "Strength"
        case .yoga:           return "Yoga"
        case .other:          return "Other"
        }
    }

    /// Whether this sport type benefits from GPS route capture (phone-side CoreLocation).
    /// For indoor types, no route is captured even when location permission is granted.
    public var isOutdoor: Bool {
        switch self {
        case .walkingOutdoor, .runningOutdoor, .cyclingOutdoor, .hiking: return true
        case .strengthTraining, .yoga, .other: return false
        }
    }

    public var systemImageName: String {
        switch self {
        case .walkingOutdoor:    return "figure.walk"
        case .runningOutdoor:    return "figure.run"
        case .cyclingOutdoor:    return "bicycle"
        case .hiking:            return "mountain.2"
        case .strengthTraining:  return "dumbbell"
        case .yoga:              return "figure.yoga"
        case .other:             return "heart.circle"
        }
    }
}

// MARK: - HR Zones

/// Five HR zones matching the APK's SportRecordModel zone schema.
/// "Below zone" (< 50% maxHR) is NOT counted per the APK description.
public enum HRZone: Int, CaseIterable, Sendable {
    case warmUp    = 1   // 50–60%
    case fatBurn   = 2   // 61–70%
    case aerobic   = 3   // 71–80%
    case anaerobic = 4   // 81–90%
    case extreme   = 5   // 91–100%

    public var displayName: String {
        switch self {
        case .warmUp:    return "Warm-up"
        case .fatBurn:   return "Fat Burning"
        case .aerobic:   return "Aerobic"
        case .anaerobic: return "Anaerobic"
        case .extreme:   return "Extreme"
        }
    }

    /// Color token names (used in the app UI; resolved in SwiftUI).
    public var colorName: String {
        switch self {
        case .warmUp:    return "zoneBlue"
        case .fatBurn:   return "zoneGreen"
        case .aerobic:   return "zoneYellow"
        case .anaerobic: return "zoneOrange"
        case .extreme:   return "zoneRed"
        }
    }

    /// Percentage LOWER bound (inclusive) of this zone, as a fraction of maxHR.
    public var lowerFraction: Double {
        switch self {
        case .warmUp:    return 0.50
        case .fatBurn:   return 0.61
        case .aerobic:   return 0.71
        case .anaerobic: return 0.81
        case .extreme:   return 0.91
        }
    }

    /// Percentage UPPER bound (inclusive) of this zone, as a fraction of maxHR.
    public var upperFraction: Double {
        switch self {
        case .warmUp:    return 0.60
        case .fatBurn:   return 0.70
        case .aerobic:   return 0.80
        case .anaerobic: return 0.90
        case .extreme:   return 1.00
        }
    }
}

// MARK: - Zone classifier

/// Pure functions for HR zone classification and time-in-zone accumulation.
public enum HRZoneClassifier {

    /// Classify a single BPM reading against maxHR, returning the zone (or nil if
    /// below 50% of maxHR — per APK, sub-50% readings are not counted in zone distribution).
    public static func zone(bpm: Int, maxHR: Int) -> HRZone? {
        guard maxHR > 0, bpm > 0 else { return nil }
        let frac = Double(bpm) / Double(maxHR)
        for zone in HRZone.allCases.reversed() {
            if frac >= zone.lowerFraction { return zone }
        }
        return nil   // below 50% — not counted
    }

    /// Accumulate time (seconds) spent in each zone from a list of timestamped HR samples.
    /// Only actual decoded readings are counted — no gap filling, no interpolation.
    /// Gaps between samples (e.g. polling misses due to #45 flakiness) are NOT attributed
    /// to any zone; the duration used for each sample is the sample's own interval
    /// (end - start), defaulting to 0 if end == start (instantaneous reading).
    public static func timeInZones(
        hrSamples: [HRSample],
        maxHR: Int
    ) -> WorkoutZoneBreakdown {
        var seconds = [HRZone: Double]()
        for z in HRZone.allCases { seconds[z] = 0 }
        for sample in hrSamples {
            let dur = sample.end.timeIntervalSince(sample.start)
            guard dur > 0, let zone = zone(bpm: sample.bpm, maxHR: maxHR) else { continue }
            seconds[zone, default: 0] += dur
        }
        return WorkoutZoneBreakdown(secondsInZone: seconds)
    }
}

// MARK: - Zone breakdown

/// Time-in-zone breakdown for one workout (seconds per zone).
/// Flat struct (not a dictionary) so Codable synthesis works without custom CodingKey.
public struct WorkoutZoneBreakdown: Equatable, Codable, Sendable {
    public var warmUpSeconds: Double
    public var fatBurnSeconds: Double
    public var aerobicSeconds: Double
    public var anaerobicSeconds: Double
    public var extremeSeconds: Double

    public init(warmUpSeconds: Double = 0, fatBurnSeconds: Double = 0,
                aerobicSeconds: Double = 0, anaerobicSeconds: Double = 0,
                extremeSeconds: Double = 0) {
        self.warmUpSeconds = warmUpSeconds
        self.fatBurnSeconds = fatBurnSeconds
        self.aerobicSeconds = aerobicSeconds
        self.anaerobicSeconds = anaerobicSeconds
        self.extremeSeconds = extremeSeconds
    }

    /// Convenience initialiser from a zone → seconds dictionary (used internally).
    init(secondsInZone: [HRZone: Double]) {
        warmUpSeconds    = secondsInZone[.warmUp]    ?? 0
        fatBurnSeconds   = secondsInZone[.fatBurn]   ?? 0
        aerobicSeconds   = secondsInZone[.aerobic]   ?? 0
        anaerobicSeconds = secondsInZone[.anaerobic] ?? 0
        extremeSeconds   = secondsInZone[.extreme]   ?? 0
    }

    public func seconds(in zone: HRZone) -> Double {
        switch zone {
        case .warmUp:    return warmUpSeconds
        case .fatBurn:   return fatBurnSeconds
        case .aerobic:   return aerobicSeconds
        case .anaerobic: return anaerobicSeconds
        case .extreme:   return extremeSeconds
        }
    }

    /// Total zone-counted seconds (excludes below-50% / not-in-zone intervals).
    public var totalZoneSeconds: Double {
        warmUpSeconds + fatBurnSeconds + aerobicSeconds + anaerobicSeconds + extremeSeconds
    }

    /// Fraction 0…1 for a zone's share of total zone time.
    public func fraction(in zone: HRZone) -> Double {
        let total = totalZoneSeconds
        guard total > 0 else { return 0 }
        return seconds(in: zone) / total
    }
}

// MARK: - Workout summary

/// Completed workout summary. Produced after the session ends; never contains fabricated values.
/// HR stats derive solely from actual decoded samples — gaps from #45 polling flakiness are
/// NOT filled or interpolated.
public struct WorkoutSummary: Equatable, Codable, Sendable {
    /// Sport type selected by the user.
    public let sport: WorkoutSportType
    /// Wall-clock start time of the session.
    public let startDate: Date
    /// Wall-clock end time of the session (when the user tapped Stop).
    public let endDate: Date
    /// Elapsed time in seconds (wall-clock duration, including periods with no HR readings).
    public var durationSeconds: TimeInterval { endDate.timeIntervalSince(startDate) }
    /// Average BPM across all actual decoded HR readings (nil if no readings were captured).
    public let avgHR: Int?
    /// Maximum BPM recorded during the session (nil if no readings).
    public let maxHR: Int?
    /// Estimated active calories from Edwards-TRIMP (ESTIMATE — labeled as such in the UI).
    /// nil if insufficient HR data for a meaningful estimate.
    public let estimatedActiveKcal: Double?
    /// 5-zone HR breakdown from actual sample durations.
    public let zoneBreakdown: WorkoutZoneBreakdown
    /// GPS distance in meters (phone-side CoreLocation). nil for indoor sports or when
    /// location permission was denied.
    public let distanceMeters: Double?
    /// Whether a GPS route was captured (and attached as HKWorkoutRoute in HealthKit).
    public let hasRoute: Bool
    /// Count of actual HR readings captured during the session.
    public let hrSampleCount: Int
    /// True when the user's max HR (220 − age) was used for zone calculations.
    /// Always true for this implementation (formula from APK).
    public let usedFormulaMaxHR: Bool

    public init(
        sport: WorkoutSportType,
        startDate: Date,
        endDate: Date,
        avgHR: Int?,
        maxHR: Int?,
        estimatedActiveKcal: Double?,
        zoneBreakdown: WorkoutZoneBreakdown,
        distanceMeters: Double?,
        hasRoute: Bool,
        hrSampleCount: Int,
        usedFormulaMaxHR: Bool = true
    ) {
        self.sport = sport
        self.startDate = startDate
        self.endDate = endDate
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.estimatedActiveKcal = estimatedActiveKcal
        self.zoneBreakdown = zoneBreakdown
        self.distanceMeters = distanceMeters
        self.hasRoute = hasRoute
        self.hrSampleCount = hrSampleCount
        self.usedFormulaMaxHR = usedFormulaMaxHR
    }
}

// MARK: - Session aggregator

/// Builds a `WorkoutSummary` from accumulated HR samples. Call `add(sample:)` as readings
/// arrive, then `finalize(sport:endDate:distanceMeters:hasRoute:profile:)` to produce the
/// summary. Thread-safety: designed for @MainActor use (all calls from WorkoutSessionManager).
public final class WorkoutSessionAggregator: @unchecked Sendable {

    private var samples: [HRSample] = []
    private let startDate: Date
    private let formulaMaxHR: Int

    /// - Parameters:
    ///   - startDate: When the session started (wall clock).
    ///   - userAge: Used to compute maxHR = 220 − age (APK formula). Must be > 0.
    public init(startDate: Date, userAge: Int) {
        self.startDate = startDate
        self.formulaMaxHR = max(220 - max(userAge, 1), 1)
    }

    /// Record a decoded HR reading. `start` and `end` should bound the interval the
    /// sample represents (so time-in-zone accounting is accurate). For instantaneous
    /// poll results, pass end == start; the zone classifier will still classify the
    /// BPM but contribute 0 s to the zone seconds (it is still counted in avg/max).
    public func add(sample: HRSample) {
        samples.append(sample)
    }

    /// Merge real HR the ring already has for this workout's window (e.g. surfaced by a history
    /// sync) into the captured set, de-duplicating by timestamp. NEVER interpolates or fabricates
    /// — when the store has nothing for the window the captured samples are left untouched (#45).
    public func backfill(_ stored: [HRSample], window: DateInterval) {
        samples = WorkoutHRBackfill.merge(captured: samples, stored: stored, window: window)
    }

    /// Produce the final `WorkoutSummary`. Safe to call with zero samples — all HR
    /// fields will be nil rather than fabricated.
    public func finalize(
        sport: WorkoutSportType,
        endDate: Date,
        distanceMeters: Double?,
        hasRoute: Bool,
        profile: UserProfile
    ) -> WorkoutSummary {
        let avgHR: Int?
        let maxHRValue: Int?
        let estimatedKcal: Double?

        let hrKcal: Double?
        if samples.isEmpty {
            avgHR = nil
            maxHRValue = nil
            hrKcal = nil
        } else {
            let sum = samples.reduce(0) { $0 + $1.bpm }
            avgHR = sum / samples.count
            maxHRValue = samples.map(\.bpm).max()
            // Active calories: Edwards-TRIMP. Requires ≥ 600 samples (Strain.minReadings)
            // to produce a meaningful estimate; returns nil otherwise. LABELED as estimate.
            let trimp = Strain.edwardsTRIMP(
                hrSamples: samples,
                maxHR: formulaMaxHR,
                restingHR: Calories.defaultRestingHR
            )
            hrKcal = trimp.map { $0 * Calories.trimpKcalFactor }
        }
        // Distance-based active-energy fallback: a GPS walk/run/hike/cycle whose HR never locked
        // (the live-HR path rarely locks in motion, #45) would otherwise show "--" active calories.
        // Estimate from the measured GPS distance + body mass instead (clearly labeled an estimate),
        // and surface the LARGER of the HR-TRIMP and distance estimates. nil only when NEITHER a
        // dense-enough HR series nor a distance exists — never fabricated.
        let distKcal = (distanceMeters ?? 0) > 0
            ? Calories.activeKcalFromDistance(meters: distanceMeters!, profile: profile)
            : nil
        estimatedKcal = [hrKcal, distKcal].compactMap { $0 }.max()

        let zones = HRZoneClassifier.timeInZones(hrSamples: samples, maxHR: formulaMaxHR)
        return WorkoutSummary(
            sport: sport,
            startDate: startDate,
            endDate: endDate,
            avgHR: avgHR,
            maxHR: maxHRValue,
            estimatedActiveKcal: estimatedKcal,
            zoneBreakdown: zones,
            distanceMeters: distanceMeters,
            hasRoute: hasRoute,
            hrSampleCount: samples.count,
            usedFormulaMaxHR: true
        )
    }

    /// All samples collected so far (for HealthKit HR series write).
    public var collectedSamples: [HRSample] { samples }
}

// MARK: - HR backfill

/// Pure merge of real stored HR into a workout's captured HR, for filling a workout window from
/// the ring's own on-device record when the live poll missed it (#45). The DURABLE source is the
/// all-day HR stream decode (#99); until that lands this is typically empty for daytime windows,
/// and that empty result is preserved — never interpolated or fabricated (CLAUDE.md).
public enum WorkoutHRBackfill {
    /// Captured + in-window stored HR, de-duplicated by `start` timestamp (captured/live wins on a
    /// tie), sorted ascending. Stored samples outside `window` are ignored.
    public static func merge(captured: [HRSample], stored: [HRSample],
                             window: DateInterval) -> [HRSample] {
        var byStart: [Date: HRSample] = [:]
        for s in stored where window.contains(s.start) { byStart[s.start] = s }
        for s in captured { byStart[s.start] = s }   // captured (live) wins on an exact-timestamp tie
        return byStart.values.sorted { $0.start < $1.start }
    }
}
