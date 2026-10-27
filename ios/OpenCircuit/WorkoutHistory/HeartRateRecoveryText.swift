// HeartRateRecoveryText.swift — heart rate recovery in words (#337, decision 82d), for the strap
// workout's summary and the workout detail. Pure: an outcome in, sentences out. A value that wasn't
// measured says so, with the reason; nothing is filled in.

import Foundation
import OpenCircuitKit

enum HeartRateRecoveryText {

    /// "1 min -N bpm, 2 min -M bpm", with "not measured" in place of a missing value; "Not measured"
    /// when neither was.
    static func values(_ outcome: HeartRateRecovery.Outcome) -> String {
        if outcome.oneMinute.drop == nil, outcome.twoMinutes.drop == nil { return "Not measured" }
        return "1 min \(value(outcome.oneMinute)), 2 min \(value(outcome.twoMinutes))"
    }

    /// The summary's line: "Heart rate recovery: 1 min -N bpm, 2 min -M bpm".
    static func headline(_ outcome: HeartRateRecovery.Outcome) -> String {
        let values = values(outcome)
        return "Heart rate recovery: " + (values == "Not measured" ? "not measured" : values)
    }

    /// A drop is how far heart rate fell from the peak: "-N bpm". One that rose says "+N bpm".
    private static func value(_ value: HeartRateRecovery.Value) -> String {
        guard let drop = value.drop else { return "not measured" }
        return drop >= 0 ? "-\(drop) bpm" : "+\(-drop) bpm"
    }

    /// Why each missing value is missing, in words; empty when both were measured. `closedBy` (the
    /// summary knows it, the detail doesn't) says what ended the recording early.
    static func reasons(_ outcome: HeartRateRecovery.Outcome, closedBy: RecoveryWindowClose? = nil) -> [String] {
        switch outcome.oneMinute {
        case .notMeasured(.noWorkoutHeartRate):
            return ["Not measured: no heart rate was recorded during the workout."]
        case .notMeasured(.peakBelowZoneFour(let peak, let bound)):
            return ["Not measured: heart rate peaked at \(peak) bpm, below zone 4 (from \(bound) bpm). "
                    + "Recovery is measured after workouts that reach zone 4."]
        default:
            break
        }
        var reasons: [String] = []
        if case .notMeasured(.noReadingNearMark) = outcome.oneMinute { reasons.append(missing("1 min", "1 minute", closedBy)) }
        if case .notMeasured(.noReadingNearMark) = outcome.twoMinutes { reasons.append(missing("2 min", "2 minutes", closedBy)) }
        return reasons
    }

    private static func missing(_ label: String, _ mark: String, _ closedBy: RecoveryWindowClose?) -> String {
        let base = "\(label) not measured: no heart-rate reading within 10 seconds of \(mark) after End"
        switch closedBy {
        case .skipped: return base + " (recording was skipped)."
        case .linkLost: return base + " (the strap disconnected)."
        case .newWorkout: return base + " (a new workout started)."
        case .complete, nil: return base + "."
        }
    }
}
