// Wellness Balance / readiness (#97) — a composite daily readiness score (0–100) that
// weight-combines the sub-scores we already compute: last night's Sleep Score, overnight
// recovery (the inverse of overnight stress), Vitals Status vs the personal baseline, and the
// day's Activity Score (#95). Tiers 85–100 Excellent / 60–84 Good / 0–59 Needs Improvement.
//
// Every factor is OPTIONAL and dropped (renormalised over the present factors) when its source
// hasn't landed yet — so a morning with a sleep summary but no activity data still yields an
// honest readiness, never a fabricated one. It is an on-device ESTIMATE, labeled as such in the
// UI; it is NOT the RingConn app's proprietary readiness number.
//
// Weighting rationale: readiness is recovery-dominant. Sleep is the single biggest recovery
// driver, then overnight autonomic recovery (stress/HRV), then vitals-vs-baseline, with the
// day's activity a lighter contributor. Weights need not sum to 1 — renormalised on present.

import Foundation

public enum WellnessBalance {
    /// Readiness tiers per #97 (this project's own readiness bands: 85–100 / 60–84 / 0–59).
    /// The "good" floor is 60 — intentionally more lenient than SleepScore/ActivityScore's 70 —
    /// because readiness has no direct RingConn-app equivalent to match, and one low sub-score
    /// shouldn't tip an otherwise-recovered day into "needs improvement".
    public enum Tier: String, Equatable, Sendable {
        case excellent          // ≥ 85
        case good               // 60–84
        case needsImprovement   // < 60

        public static func of(_ score: Int) -> Tier {
            if score >= 85 { return .excellent }
            if score >= 60 { return .good }
            return .needsImprovement
        }
    }

    /// Sub-scores, each optional so a missing one is renormalised out rather than invented.
    public struct Input: Equatable, Sendable {
        public var sleepScore: Int?                     // 0–100 (StoredSleepSummary.sleepScore)
        public var overnightStress: Int?                // 1–100 overnight stress (higher = MORE stress)
        public var vitalsStatus: VitalsBaseline.Status? // normal / watch / anomaly
        public var activityScore: Int?                  // 0–100 (#95)

        public init(sleepScore: Int? = nil, overnightStress: Int? = nil,
                    vitalsStatus: VitalsBaseline.Status? = nil, activityScore: Int? = nil) {
            self.sleepScore = sleepScore
            self.overnightStress = overnightStress
            self.vitalsStatus = vitalsStatus
            self.activityScore = activityScore
        }
    }

    /// The composite plus each factor's 0…1 sub-score (for a breakdown view).
    public struct Result: Equatable, Sendable {
        public let score: Int
        public let tier: Tier
        public let factors: [Factor: Double]   // each 0…1
        public enum Factor: String, Equatable, Sendable, CaseIterable {
            case sleep, recovery, vitals, activity
        }
    }

    /// Default factor weights (sum need not be 1 — renormalised over the PRESENT factors).
    static let factorWeights: [Result.Factor: Double] = [
        .sleep: 0.40, .recovery: 0.25, .vitals: 0.20, .activity: 0.15,
    ]

    /// Composite readiness (0–100) with tiers. Returns nil when NO sub-score is available, so the
    /// UI shows "—" rather than a meaningless 0. Pure; unit-tested.
    public static func score(_ input: Input) -> Result? {
        var f: [Result.Factor: Double] = [:]

        if let s = input.sleepScore {
            f[.sleep] = clamp01(Double(s) / 100)
        }
        if let st = input.overnightStress {
            // `overnightStress` is the SleepStress overnight score, which clamps to
            // [SleepStress.lowScore, SleepStress.highScore] (15…90) — NOT the full 1…100. Map that
            // ACTUAL achievable range to a 0…1 recovery factor (higher stress ⇒ lower recovery) so
            // recovery spans the full 0…1 instead of the compressed [0.10, 0.85] a naive
            // `1 − stress/100` would give. Values outside the range clamp.
            let lo = SleepStress.lowScore, hi = SleepStress.highScore
            f[.recovery] = clamp01((hi - Double(st)) / (hi - lo))
        }
        if let v = input.vitalsStatus {
            f[.vitals] = vitalsFactor(v)
        }
        if let a = input.activityScore {
            f[.activity] = clamp01(Double(a) / 100)
        }

        guard !f.isEmpty else { return nil }

        var num = 0.0, den = 0.0
        for (factor, value) in f {
            let w = factorWeights[factor] ?? 0
            num += w * value
            den += w
        }
        let raw = den > 0 ? num / den : 0
        let score = Int((raw * 100).rounded())
        return Result(score: score, tier: .of(score), factors: f)
    }

    /// Readiness ANCHORED on last night: returns nil unless a sleep sub-score is present, so a day
    /// with only activity data never synthesises a readiness from activity alone (discipline: never
    /// fabricate a health value from a weak signal). This is the entry point the UI headline should
    /// call; the unanchored `score` above is the general renormalising blender. Pure; unit-tested.
    public static func anchoredScore(_ input: Input) -> Result? {
        input.sleepScore == nil ? nil : score(input)
    }

    /// Vitals Status → recovery factor. A clean baseline is full credit; a "watch" halves it; an
    /// anomaly (a Significant outlier or a suspected fever) zeroes it.
    static func vitalsFactor(_ status: VitalsBaseline.Status) -> Double {
        switch status {
        case .normal:  return 1.0
        case .watch:   return 0.5
        case .anomaly: return 0.0
        }
    }

    // MARK: - Trend

    public enum Trend: String, Equatable, Sendable { case up, steady, down }

    /// Today's readiness vs the mean of recent prior scores, with a `deadband` so tiny wiggles
    /// read as steady. `prior` is recent readiness scores (any order); steady when empty.
    public static func trend(today: Int, prior: [Int], deadband: Int = 3) -> Trend {
        guard !prior.isEmpty else { return .steady }
        let mean = Double(prior.reduce(0, +)) / Double(prior.count)
        let delta = Double(today) - mean
        if delta > Double(deadband) { return .up }
        if delta < -Double(deadband) { return .down }
        return .steady
    }

    private static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
}
