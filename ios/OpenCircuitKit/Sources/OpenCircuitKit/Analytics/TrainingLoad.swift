// TrainingLoad.swift — per-workout training load (Edwards' TRIMP) and the weekly trend (#232).
//
// METHOD. Edwards, S. (1993). "High performance training and racing." In: The Heart Rate Monitor
// Book, pp. 113–123. Feet Fleet Press. Time in each of five heart-rate zones (50–60, 60–70, 70–80,
// 80–90 and 90–100 % of maximum heart rate) is multiplied by the zone number (1–5) and summed:
//
//     TRIMP = Σ minutes_in_zone(z) × z,   z = 1…5
//
// INPUT. The workout's own 5-zone breakdown (`WorkoutZoneBreakdown`, #75) — the same numbers the
// workout screen draws as zone bars, so the load always agrees with what the user can see. Those
// zones are the user's `HeartRateZones` (decision 83): by default 50/60/70/80/90 % of max heart rate
// with max = 220 − age, which is Edwards' own zone basis. One documented deviation, in
// `docs/TRAINING_METRICS.md` §1: a minute without a heart-rate reading adds nothing (gaps are never
// filled, #45). Manual max HR, % of reserve and custom bounds move the zones, and so the load.
//
// Device-agnostic: the input is a zone breakdown, whichever wearable produced the heart rate.
// Pure value math, no HealthKit.
//
// NOT `Strain.edwardsTRIMP`: that is openwhoop's %HR-RESERVE variant on 1 Hz series with a
// 600-reading floor, feeding the 0…21 strain scale. This file is Edwards' original %HRmax form over
// the zone time the app already has.

import Foundation

public enum TrainingLoad {

    /// Edwards' TRIMP for one workout: Σ minutes in zone × zone number.
    public static func edwardsTRIMP(_ zones: WorkoutZoneBreakdown) -> Double {
        var total = 0.0
        for zone in HRZone.allCases {
            let minutes = zones.seconds(in: zone) / 60
            total += minutes * Double(zone.rawValue)
        }
        return total
    }

    /// The load to show for a workout, or nil when the workout recorded no heart rate at all.
    ///
    /// nil and 0 mean different things: 0 is a real result (heart rate was recorded and stayed below
    /// zone 1 — Edwards gives that no weight), nil is "nothing to score", which the UI says in
    /// words rather than printing a 0 that would read as a measurement.
    public static func workoutLoad(zones: WorkoutZoneBreakdown, hrSampleCount: Int) -> Double? {
        guard hrSampleCount > 0 else { return nil }
        return edwardsTRIMP(zones)
    }

    /// The max HR (Automatic) the default workout zones are drawn with: `220 − age` with the age
    /// floored at 1, exactly as `WorkoutSessionAggregator` computes it.
    public static func zoneMaxHR(age: Int) -> Int {
        MaxHeartRate.automatic(age: max(age, 1))
    }

    /// Load from a workout's heart-rate series over the default zones for `age` (Automatic max HR,
    /// % of max). The app passes the user's zones to the overload below.
    public static func workoutLoad(hrSamples: [HRSample], age: Int, sessionEnd: Date) -> Double? {
        workoutLoad(hrSamples: hrSamples, zones: HeartRateZones(percentOfMax: zoneMaxHR(age: age)),
                    sessionEnd: sessionEnd)
    }

    /// Load from a workout's heart-rate series — the path for workouts read back out of Apple
    /// Health, where only the samples survive. Same held attribution as the live aggregator.
    public static func workoutLoad(hrSamples: [HRSample], zones: HeartRateZones, sessionEnd: Date) -> Double? {
        guard !hrSamples.isEmpty else { return nil }
        let breakdown = HRZoneClassifier.timeInZonesHeld(
            hrSamples: hrSamples, zones: zones, sessionEnd: sessionEnd)
        return edwardsTRIMP(breakdown)
    }

    // MARK: - Weekly trend

    /// One workout's load, dated by when it ended. `load` nil = the workout had no heart rate.
    public struct DatedLoad: Equatable, Sendable {
        public let end: Date
        public let load: Double?
        public init(end: Date, load: Double?) {
            self.end = end
            self.load = load
        }
    }

    public enum Direction: Equatable, Sendable {
        case higher, similar, lower
    }

    /// The last 7 days' load against the weekly average of the 4 weeks before.
    public struct WeeklyTrend: Equatable, Sendable {
        /// Sum of scored loads ending in (now − 7 d, now].
        public let thisWeek: Double
        /// Workouts in the last 7 days that carried no heart rate (not counted, said so in the UI).
        public let unscoredThisWeek: Int
        /// Mean weekly load over (now − 35 d, now − 7 d], i.e. that window's sum ÷ 4. nil when no
        /// scored workout ended in it: the app can't tell four weeks of rest from four weeks before
        /// it was installed, so it shows no comparison rather than a 0 average.
        public let previousWeeklyAverage: Double?
        /// thisWeek ÷ average − 1. nil without an average (or when the average is 0).
        public let change: Double?
        public let direction: Direction?
    }

    /// Display band, not physiology: within ±10 % of the 4-week average reads as "similar". The
    /// trend makes no injury-risk claim (no acute:chronic ratio thresholds are applied or named).
    public static let similarBand = 0.10

    public static func weeklyTrend(_ loads: [DatedLoad], now: Date) -> WeeklyTrend {
        let day: TimeInterval = 86_400
        let weekStart = now.addingTimeInterval(-7 * day)
        let historyStart = now.addingTimeInterval(-35 * day)

        var thisWeek = 0.0
        var unscored = 0
        var previousSum = 0.0
        var previousScored = 0
        for item in loads where item.end <= now {
            if item.end > weekStart {
                if let load = item.load { thisWeek += load } else { unscored += 1 }
            } else if item.end > historyStart, let load = item.load {
                previousSum += load
                previousScored += 1
            }
        }

        let average: Double? = previousScored > 0 ? previousSum / 4 : nil
        var change: Double?
        var direction: Direction?
        if let average, average > 0 {
            let ratio = thisWeek / average - 1
            change = ratio
            if ratio > similarBand {
                direction = .higher
            } else if ratio < -similarBand {
                direction = .lower
            } else {
                direction = .similar
            }
        }
        return WeeklyTrend(thisWeek: thisWeek, unscoredThisWeek: unscored,
                           previousWeeklyAverage: average, change: change, direction: direction)
    }
}
