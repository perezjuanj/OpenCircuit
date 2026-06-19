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
    public static let idealDurationSeconds = 60 * 60 * 8

    /// Score from a sleep duration in seconds.
    public static func score(durationSeconds: Int) -> Double {
        let ratio = Double(durationSeconds) / Double(idealDurationSeconds)   // #28: graded, not a step
        return min(max(ratio * 100.0, 0.0), 100.0)
    }

    /// Convenience for a start/end span.
    public static func score(start: Date, end: Date) -> Double {
        score(durationSeconds: Int(end.timeIntervalSince(start)))
    }

    // MARK: - Composite 0–100 sleep score (#70)
    //
    // The duration-only `score` above (the ported openwhoop piece, #28) is NOT the
    // RingConn app's headline number. The app's Sleep Score is a 6-FACTOR composite
    // (pp.txt:47425): "Time Asleep, Sleep Stages, Sleep Efficiency, Heart Rate,
    // Temperature, and Time Awake", with tiers ≥85 / 70–84 / <70.
    //
    // We reproduce that SHAPE from what we actually decode, and degrade gracefully when an
    // optional input is missing (no resting HR / no temp baseline): the missing factor is
    // dropped and the remaining factors are renormalised, rather than fabricating a value.
    // It is an on-device ESTIMATE — label it as such in the UI — not the app's proprietary
    // algorithm, which we can't see.

    /// Quality tiers, matching the app's cut-offs.
    public enum Tier: String, Equatable, Sendable {
        case excellent   // ≥ 85
        case good        // 70–84
        case needsImprovement  // < 70

        public static func of(_ score: Int) -> Tier {
            if score >= 85 { return .excellent }
            if score >= 70 { return .good }
            return .needsImprovement
        }
    }

    /// Inputs to the composite, all derived from decoded data. Optional inputs (`restingHR`,
    /// `tempOffsetC`) are dropped from the weighting when nil so the score never invents them.
    public struct CompositeInput: Equatable, Sendable {
        public var totalAsleep: TimeInterval
        public var timeAwake: TimeInterval
        public var efficiency: Double          // 0…1 (already shipped in SleepCardView)
        public var deep: TimeInterval
        public var light: TimeInterval
        public var rem: TimeInterval
        public var restingHR: Double?          // night's resting/avg HR, bpm (optional)
        public var tempOffsetC: Double?        // nightly skin-temp offset from baseline (optional)
        public var sleepGoal: TimeInterval     // target time asleep (default 8 h)

        public init(totalAsleep: TimeInterval, timeAwake: TimeInterval, efficiency: Double,
                    deep: TimeInterval, light: TimeInterval, rem: TimeInterval,
                    restingHR: Double? = nil, tempOffsetC: Double? = nil,
                    sleepGoal: TimeInterval = TimeInterval(idealDurationSeconds)) {
            self.totalAsleep = totalAsleep
            self.timeAwake = timeAwake
            self.efficiency = efficiency
            self.deep = deep
            self.light = light
            self.rem = rem
            self.restingHR = restingHR
            self.tempOffsetC = tempOffsetC
            self.sleepGoal = sleepGoal
        }
    }

    /// The composite result plus each factor's 0…1 sub-score (handy for a breakdown view).
    public struct Composite: Equatable, Sendable {
        public let score: Int
        public let tier: Tier
        public let factors: [Factor: Double]   // each 0…1
        public enum Factor: String, Equatable, Sendable, CaseIterable {
            case timeAsleep, stages, efficiency, heartRate, temperature, timeAwake
        }
    }

    /// Default factor weights (sum need not be 1 — we renormalise over the PRESENT factors).
    /// Time asleep + efficiency carry the most signal; HR and temperature are lighter
    /// modifiers, mirroring how the app frames them as secondary contributors.
    static let factorWeights: [Composite.Factor: Double] = [
        .timeAsleep: 0.30, .stages: 0.20, .efficiency: 0.20,
        .heartRate: 0.10, .temperature: 0.10, .timeAwake: 0.10,
    ]

    /// 6-factor composite Sleep Score (0–100) with tiers. Pure; unit-tested.
    public static func composite(_ input: CompositeInput) -> Composite {
        var f: [Composite.Factor: Double] = [:]

        // Time asleep: linear vs the goal, capped at 1 (the duration factor REUSES the ported
        // ratio idea, #28, but against the personal goal rather than a fixed 8 h).
        f[.timeAsleep] = clamp(input.sleepGoal > 0 ? input.totalAsleep / input.sleepGoal : 0)

        // Stages: reward a healthy share of restorative sleep (Deep + REM). Adults spend
        // ~13–23 % in deep and ~20–25 % in REM; ~40 % combined is a reasonable "ideal" target.
        let asleep = max(input.deep + input.light + input.rem, 1)
        let restorative = (input.deep + input.rem) / asleep
        f[.stages] = clamp(restorative / 0.40)

        // Efficiency: 0.85+ is excellent (the app calls 80–100 % optimal). Map [0.5, 0.95]→[0,1].
        f[.efficiency] = clamp((input.efficiency - 0.50) / (0.95 - 0.50))

        // Time awake: less awake-in-bed is better. 0 min → 1, ≥60 min → 0.
        f[.timeAwake] = clamp(1 - input.timeAwake / (60 * 60))

        // Heart rate (optional): a lower sleeping HR is generally better recovery. Map a broad
        // [45, 75] bpm band to [1, 0]; outside it clamps. Omitted entirely when no HR decoded.
        if let hr = input.restingHR {
            f[.heartRate] = clamp((75 - hr) / (75 - 45))
        }

        // Temperature (optional): closer to baseline is better. |offset| 0 → 1, ≥1 °C → 0,
        // matching the ±1 °C "normal" band. Omitted when no baseline yet.
        if let off = input.tempOffsetC {
            f[.temperature] = clamp(1 - abs(off) / SkinTempBaseline.normalDeviationC)
        }

        // Weighted mean over the PRESENT factors only (renormalise so a missing optional
        // factor doesn't silently drag the score toward zero).
        var num = 0.0, den = 0.0
        for (factor, value) in f {
            let w = factorWeights[factor] ?? 0
            num += w * value
            den += w
        }
        let raw = den > 0 ? num / den : 0
        let score = Int((raw * 100).rounded())
        return Composite(score: score, tier: .of(score), factors: f)
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
