// Sleep score — ported from openwhoop-algos/src/sleep.rs `sleep_score`.
// Device-agnostic: a function of sleep duration only. 0…100.
//
// Fix (#28): openwhoop's Rust code computes the ratio in integer arithmetic
// which produces a step function (0 for <8h, 100 for ≥8h). That is not a
// usable health metric; this port uses floating-point ratio so a 6h night
// scores 75 and a 7h45m night scores ~97. Clamped to 0…100 (overshoot → 100).

import Foundation

public enum SleepScore {
    /// Ideal sleep duration in seconds (8h).
    static let idealDurationSeconds = 60 * 60 * 8

    /// Score from a sleep duration in seconds. 4h → 50, 6h → 75, 8h → 100, >8h → 100.
    public static func score(durationSeconds: Int) -> Double {
        let ratio = Double(durationSeconds) / Double(idealDurationSeconds)
        return min(max(ratio * 100.0, 0.0), 100.0)
    }

    /// Convenience for a start/end span.
    public static func score(start: Date, end: Date) -> Double {
        score(durationSeconds: Int(end.timeIntervalSince(start)))
    }
}
