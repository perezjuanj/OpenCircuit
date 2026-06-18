// Overnight windowed averages — the single source of truth for a night's mean vital
// (HRV / HR / SpO₂ / RR) used by BOTH the Sleep card and the Vitals dashboard, so the two
// can never disagree (the cause of the "HRV 86 ms in Vitals vs 64 ms in Sleep" bug: Vitals
// showed the single newest epoch, Sleep showed the overnight mean).
//
// Pure value-type math over (value, timestamp) pairs — no SwiftData / HealthKit — so it
// unit-tests on macOS. Computes only from real decoded samples; an empty window yields nil
// (rendered as "—"), never a fabricated value.

import Foundation

public enum OvernightAverages {

    /// One timestamped sample value (kind-agnostic — the caller pre-filters to one metric).
    public struct Point: Equatable, Sendable {
        public let value: Double
        public let start: Date
        public init(value: Double, start: Date) {
            self.value = value
            self.start = start
        }
    }

    /// Arithmetic mean of the values whose `start` falls within `window` (inclusive of both
    /// endpoints, matching the Sleep card's in-bed span check), or nil when none qualify.
    public static func mean(_ points: [Point], window: DateInterval) -> Double? {
        var sum = 0.0
        var n = 0
        for p in points where p.start >= window.start && p.start <= window.end {
            sum += p.value
            n += 1
        }
        return n > 0 ? sum / Double(n) : nil
    }
}
