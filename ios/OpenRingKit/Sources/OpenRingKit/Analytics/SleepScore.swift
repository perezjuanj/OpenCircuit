// Sleep score — adapted from openwhoop-algos/src/sleep.rs `sleep_score`.
// Device-agnostic: a function of sleep duration only. 0…100.
//
// openwhoop computes `duration / 8h` in INTEGER units, which collapses the score to a
// 0-or-100 step function (anything < 8h → 0, ≥ 8h → 100) — useless as a daily metric:
// a 7h45m night scores 0 (#28). We compute the ratio in floating point so the score
// grades linearly with duration and clamps at the 8h ideal: 4h → 50, 6h → 75, 8h+ → 100.

import Foundation

public enum SleepScore {
    /// Ideal sleep duration in seconds (8h).
    static let idealDurationSeconds = 60 * 60 * 8

    /// Score from a sleep duration in seconds.
    public static func score(durationSeconds: Int) -> Double {
        let ratio = Double(durationSeconds) / Double(idealDurationSeconds)   // #28: graded, not a step
        return min(max(ratio * 100.0, 0.0), 100.0)
    }

    /// Convenience for a start/end span.
    public static func score(start: Date, end: Date) -> Double {
        score(durationSeconds: Int(end.timeIntervalSince(start)))
    }
}
