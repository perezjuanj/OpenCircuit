// HRV (RMSSD) — ported from openwhoop's openwhoop-algos/src/sleep.rs
// (calculate_rmssd / rolling_hrv / clean_rr). Device-agnostic time-series math.
//
// ⚠️ Whoop-specific INPUT assumption (CLAUDE.md: only analytics port across):
// these consume per-beat RR intervals in milliseconds. Whether RingConn reports
// RR at all — and at what cadence — is 🔴 unconfirmed (PROTOCOL.md §5). Wiring
// these to real ring data is gated on a capture; the math itself is general.
//
// Note vs HealthKit: HealthKit stores HRV as SDNN, but openwhoop computes RMSSD
// (see HEALTHKIT_MAPPING.md). We port RMSSD faithfully; conversion/choice of what
// to write to HealthKit is a Phase 4 decision, not made here.

import Foundation

public enum HRV {

    /// RMSSD over one window of RR intervals (ms): sqrt(mean of squared successive
    /// differences). nil for windows shorter than 2. Integer result truncates
    /// toward zero to match openwhoop's `as u64`.
    public static func rmssd(_ window: [Int]) -> Int? {
        guard window.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<window.count {
            let d = Double(window[i] - window[i - 1])
            sumSq += d * d
        }
        let mean = sumSq / Double(window.count - 1)
        return Int(mean.squareRoot())
    }

    /// Rolling RMSSD over consecutive windows of `windowSize` (openwhoop uses 300).
    /// Returns one RMSSD per window position; empty if fewer than `windowSize` RRs.
    public static func rollingRMSSD(_ rr: [Int], windowSize: Int = 300) -> [Int] {
        guard windowSize >= 2, rr.count >= windowSize else { return [] }
        var out: [Int] = []
        out.reserveCapacity(rr.count - windowSize + 1)
        for start in 0...(rr.count - windowSize) {
            if let v = rmssd(Array(rr[start ..< start + windowSize])) { out.append(v) }
        }
        return out
    }

    /// Flatten per-reading RR sample groups and drop non-positive artifacts.
    /// Mirrors openwhoop `clean_rr`.
    public static func cleanRR(_ groups: [[Int]]) -> [Int] {
        groups.flatMap { $0 }.filter { $0 > 0 }
    }

    /// Summary of rolling HRV across a span (e.g. a night). nil if no windows.
    public struct Summary: Equatable, Sendable {
        public let min: Int
        public let max: Int
        public let avg: Int
    }

    public static func summary(_ rr: [Int], windowSize: Int = 300) -> Summary? {
        let series = rollingRMSSD(rr, windowSize: windowSize)
        guard let lo = series.min(), let hi = series.max(), !series.isEmpty else { return nil }
        let avg = series.reduce(0, +) / series.count   // integer mean, as openwhoop
        return Summary(min: lo, max: hi, avg: avg)
    }
}
