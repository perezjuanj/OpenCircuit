// Overnight / sleep stress score from sleep-window HRV — #71.
//
// ⚠️ This is a NEW mapping, NOT the ported `Analytics/Stress.swift`. That file is Baevsky's
// Stress Index over RR INTERVALS (0…10), and we do NOT decode RR intervals (PROTOCOL §5 🔴),
// so it is unusable here. The ONLY HRV we decode is the per-epoch RMSSD at `0x4c[5]` 🟢 during
// the sleep window — so this builds a defensible RMSSD→stress-band mapping from that single
// statistic instead.
//
// SCOPE: OVERNIGHT / SLEEP stress only. All-day/daytime stress needs daytime HRV, which lives
// in the UNDECODED activity-epoch `[15:22]` payload (or 0x47 PPG, #38) — a separate, blocked
// ticket (#94). Label this "overnight/sleeping stress (estimate)", never all-day.
//
// Bands follow the app's own thresholds (pp.txt:45236 / 0x12678): a 1–100 score where
//   1–29  = relaxed/low, 30–59 = normal, 60–79 = medium, 80–100 = high,
// and "Stress index is measured by Heart Rate Variability (HRV)". Higher HRV ⇒ more
// parasympathetic (rested) ⇒ LOWER stress; lower HRV ⇒ HIGHER stress. The RMSSD→score curve
// below is a HEURISTIC reference range (no fabricated health values) and is labeled an estimate
// in the UI; the band thresholds themselves are the app's.

import Foundation

public enum SleepStress {

    /// App stress bands over a 1–100 score.
    public enum Band: String, Equatable, Sendable, CaseIterable {
        case relaxed   // 1–29
        case normal    // 30–59
        case medium    // 60–79
        case high      // 80–100

        public static func of(_ score: Int) -> Band {
            switch score {
            case ..<30: return .relaxed
            case ..<60: return .normal
            case ..<80: return .medium
            default: return .high
            }
        }

        public var label: String {
            switch self {
            case .relaxed: return "Relaxed"
            case .normal: return "Normal"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }

    /// Reference RMSSD bounds (ms) for the mapping. At/above `restedRMSSD` the score floors
    /// near "relaxed"; at/below `stressedRMSSD` it tops out near "high". These bracket a broad,
    /// defensible adult nocturnal RMSSD range; the curve interpolates in LOG space between them
    /// (HRV is approximately log-normal), so it grades smoothly rather than stepping.
    public static let restedRMSSD = 70.0
    public static let stressedRMSSD = 15.0
    /// Score endpoints the bounds map to (kept inside, not at, the 1/100 extremes so a single
    /// value isn't over-claimed as a perfect/worst night).
    static let lowScore = 15.0    // maps to a "relaxed" reading
    static let highScore = 90.0   // maps to a "high" reading

    /// Map a single RMSSD (ms) to a 0–100 overnight stress score (higher = more stress).
    /// Monotonic decreasing in RMSSD, clamped to the reference window. Defensible heuristic.
    public static func score(rmssdMs: Double) -> Int {
        let rmssd = max(rmssdMs, 1)   // guard log(0)
        let hi = log(restedRMSSD), lo = log(stressedRMSSD)
        // t = 0 at the rested bound, 1 at the stressed bound.
        let t = (hi - log(rmssd)) / (hi - lo)
        let clamped = min(max(t, 0), 1)
        let s = lowScore + clamped * (highScore - lowScore)
        return Int(s.rounded())
    }

    /// Overnight stress from the night's per-epoch RMSSD values. Uses the MEDIAN RMSSD (robust
    /// to the odd noisy epoch) as the night's representative HRV. nil when there's no HRV
    /// (e.g. a connection-free night, or SpO2-only epochs). Non-positive values are dropped.
    public static func overnightScore(rmssd: [Int]) -> Int? {
        let valid = rmssd.filter { $0 > 0 }.sorted()
        guard !valid.isEmpty else { return nil }
        let median = Double(valid[valid.count / 2])
        return score(rmssdMs: median)
    }

    /// Convenience: overnight stress straight from the night's sleep-vitals records.
    public static func overnightScore(records: [BulkRecord]) -> Int? {
        overnightScore(rmssd: records.compactMap { $0.hrvRMSSD })
    }

    /// Time spent in each stress band across the night, by classifying EACH epoch's RMSSD and
    /// multiplying by the epoch length. Lets the UI show "X min relaxed · Y min high" honestly
    /// from the data, not from the single nightly score. Epochs with no/invalid RMSSD are skipped.
    public static func stateDurations(rmssd: [Int],
                                      epochSeconds: Int = BulkRecord.epochSeconds) -> [Band: TimeInterval] {
        var out: [Band: TimeInterval] = [:]
        for v in rmssd where v > 0 {
            out[Band.of(score(rmssdMs: Double(v))), default: 0] += TimeInterval(epochSeconds)
        }
        return out
    }

    public static func stateDurations(records: [BulkRecord]) -> [Band: TimeInterval] {
        stateDurations(rmssd: records.compactMap { $0.hrvRMSSD })
    }
}
