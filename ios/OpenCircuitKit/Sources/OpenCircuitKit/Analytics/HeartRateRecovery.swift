// HeartRateRecovery.swift — heart rate recovery after a workout (#337, decision 82d).
//
// Peak = the highest reading in the workout's ACTIVE time. HRR1 = peak − the reading nearest
// end + 60 s, HRR2 = peak − the reading nearest end + 120 s, each only when that reading is within
// 10 s of its mark. Computed only when the peak reached zone 4; otherwise "not measured" with a
// reason the UI states in words. Nothing is interpolated or defaulted.
//
// The zone-4 lower bound is an INPUT: the caller reads it through the zone classifier for the person
// (`zoneFourLowerBound(classify:)`), whatever source of bounds is current. No percentage lives here.
//
// A reading's instant is its `end`: a workout reading spans the moment before it was received
// (the strap's the second before, `StrapWorkoutSampleLine`), and a history instant has
// `end == start`. Device-agnostic and pure: no HealthKit, no clock.

import Foundation

public enum HeartRateRecovery {

    /// The two marks after the workout's end (decision 82d).
    public static let oneMinute: TimeInterval = 60
    public static let twoMinutes: TimeInterval = 120
    /// How far from its mark a reading may be and still count (inclusive).
    public static let tolerance: TimeInterval = 10
    /// The recovery window (decision 82b): 120 s, plus up to 10 s to catch the +120 s reading.
    public static let window: TimeInterval = twoMinutes
    public static var windowLimit: TimeInterval { window + tolerance }

    /// Why one value was not measured.
    public enum NotMeasured: Equatable, Sendable {
        /// No reading in the workout's active time, so there is no peak.
        case noWorkoutHeartRate
        /// The peak stayed below zone 4 (`peak` < `zoneFourLowerBound`).
        case peakBelowZoneFour(peak: Int, zoneFourLowerBound: Int)
        /// No reading within `tolerance` of the mark.
        case noReadingNearMark
    }

    public enum Value: Equatable, Sendable {
        /// `drop` = peak − `reading` (bpm); `at` is that reading's instant.
        case measured(drop: Int, reading: Int, at: Date)
        case notMeasured(NotMeasured)

        public var drop: Int? {
            if case .measured(let drop, _, _) = self { return drop }
            return nil
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// The highest active-time reading, nil when there was none.
        public let peak: Int?
        public let oneMinute: Value
        public let twoMinutes: Value

        public init(peak: Int?, oneMinute: Value, twoMinutes: Value) {
            self.peak = peak
            self.oneMinute = oneMinute
            self.twoMinutes = twoMinutes
        }
    }

    /// HRR1 and HRR2 for one workout.
    /// - activeReadings: the readings inside the workout's running stretches. Only those at or
    ///   before `end` count toward the peak.
    /// - recoveryReadings: readings after `end` (only those within `tolerance` of a mark are used).
    /// - zoneFourLowerBound: the lowest bpm the person's zone classifier puts in zone 4 or above.
    public static func measure(activeReadings: [HRSample], recoveryReadings: [HRSample], end: Date,
                               zoneFourLowerBound: Int) -> Outcome {
        guard let peak = activeReadings.filter({ $0.end <= end }).map(\.bpm).max() else {
            return Outcome(peak: nil, oneMinute: .notMeasured(.noWorkoutHeartRate),
                           twoMinutes: .notMeasured(.noWorkoutHeartRate))
        }
        guard peak >= zoneFourLowerBound else {
            let reason = NotMeasured.peakBelowZoneFour(peak: peak, zoneFourLowerBound: zoneFourLowerBound)
            return Outcome(peak: peak, oneMinute: .notMeasured(reason), twoMinutes: .notMeasured(reason))
        }
        return Outcome(peak: peak,
                       oneMinute: value(peak: peak, nearest: end.addingTimeInterval(oneMinute), in: recoveryReadings),
                       twoMinutes: value(peak: peak, nearest: end.addingTimeInterval(twoMinutes), in: recoveryReadings))
    }

    /// The reading nearest `mark` within `tolerance`; on a tie the earlier one.
    private static func value(peak: Int, nearest mark: Date, in readings: [HRSample]) -> Value {
        var best: (sample: HRSample, off: TimeInterval)?
        for sample in readings {
            let off: TimeInterval = abs(sample.end.timeIntervalSince(mark))
            guard off <= tolerance else { continue }
            if let current = best, current.off < off || (current.off == off && current.sample.end <= sample.end) {
                continue
            }
            best = (sample, off)
        }
        guard let reading = best?.sample else { return .notMeasured(.noReadingNearMark) }
        return .measured(drop: peak - reading.bpm, reading: reading.bpm, at: reading.end)
    }

    /// The lowest bpm `classify` puts in zone 4 or above, or nil when no plausible bpm reaches it.
    /// Pass the person's zone classifier, e.g. `{ HRZoneClassifier.zone(bpm: $0, maxHR: maxHR) }`.
    public static func zoneFourLowerBound(classify: (Int) -> HRZone?) -> Int? {
        LiveHR.validBPM.first { (classify($0)?.rawValue ?? 0) >= zoneFour }
    }

    /// `HRZone`'s raw value for zone 4.
    static let zoneFour = 4
}
