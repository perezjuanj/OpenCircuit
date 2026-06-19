// Stress — Baevsky Stress Index, ported from openwhoop-algos/src/stress.rs.
// Pure function of RR intervals (ms); result is a 0…10 scale. Device-agnostic.
//
// ⚠️ Same RR-availability caveat as HRV (PROTOCOL.md §5 🔴). openwhoop falls back
// to BPM-derived RR when real RR is scarce; that fallback lives at the call site
// (it needs the per-reading bpm/rr split), so this file ports only the core index.

import Foundation

public enum Stress {
    /// Baevsky's standard 50 ms histogram bin width.
    static let binWidth = 50

    /// Stress index from RR intervals (ms). Mirrors `StressCalcParams::stress_score`.
    /// Constant RR (zero variability) returns the max, 10.0.
    public static func index(rr: [Int]) -> Double {
        let count = rr.count
        let minRR = rr.min() ?? 0
        let maxRR = rr.max() ?? 0

        // Histogram, 50 ms bins. On tie, the higher bin key wins (matches Rust
        // BTreeMap max_by, which returns the last maximal element in key order).
        var bins: [Int: Int] = [:]
        for v in rr { bins[v / binWidth, default: 0] += 1 }
        var modeBin = 0, modeFreq = 0
        for key in bins.keys.sorted() {
            let freq = bins[key]!
            if freq >= modeFreq { modeFreq = freq; modeBin = key }
        }
        let mode = modeBin * binWidth + binWidth / 2

        let vr = Double(maxRR - minRR) / 1000.0
        if vr < 0.0001 { return 10.0 }

        let aMode = Double(modeFreq) / Double(count) * 100.0
        return min((aMode / (2.0 * vr * Double(mode) / 1000.0)).rounded(), 1000.0) / 100.0
    }
}
