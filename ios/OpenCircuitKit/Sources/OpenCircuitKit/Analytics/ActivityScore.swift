// Daily Activity Score (#95) — an on-device ESTIMATE of how active the day was,
// scored 0–100 with tiers, from the same three daily activity goals the app already
// tracks in GoalsCardView: STEPS, ACTIVE MINUTES (elevated-HR), and ACTIVE CALORIES.
//
// WHY a goal-attainment proxy and NOT the RingConn app's headline number: the app's
// Activity Score is a proprietary combination of 4 CALIBRATED intensity buckets
// (Vigorous/Moderate/Low/Inactive durations) that live in the still-uncaptured
// 历史活动响应 activity record (#93) — proven cloud-computed, NOT on our BLE wire. We
// must not fabricate those 4 buckets (see ExerciseMinutes.swift's header). Instead we
// score the day against the user's OWN step / active-minute / active-kcal goals — every
// input is a value we genuinely decode (steps, 0x4c[4] HR) or derive (ExerciseMinutes,
// Calories), none invented. It is an on-device ESTIMATE — label it as such in the UI —
// not the app's algorithm, which we can't see.
//
// Tiers ≥85 / 70–84 / <70 reuse the shipped SleepScore house tier convention (this project's
// own cut-offs). The RingConn app's own activity-tier cut-offs are unseen, so we do NOT claim
// parity with them.

import Foundation

public enum ActivityScore {
    /// Quality tiers, matching the app's cut-offs and SleepScore.Tier.
    public enum Tier: String, Equatable, Sendable {
        case excellent          // ≥ 85
        case good               // 70–84
        case needsImprovement   // < 70

        public static func of(_ score: Int) -> Tier {
            if score >= 85 { return .excellent }
            if score >= 70 { return .good }
            return .needsImprovement
        }
    }

    /// Inputs: each is a daily current value paired with its goal. All are values the app
    /// already computes for the Goals ring (steps from the descriptor counter, active
    /// minutes from `ExerciseMinutes.estimate`, active kcal from `Calories`). A factor
    /// whose goal is ≤ 0 (unset / disabled) is dropped and the rest are renormalised.
    public struct Input: Equatable, Sendable {
        public var steps: Int
        public var stepGoal: Int
        public var activeMinutes: Double
        public var activeMinutesGoal: Double
        public var activeKcal: Double
        public var activeKcalGoal: Double

        public init(steps: Int, stepGoal: Int,
                    activeMinutes: Double, activeMinutesGoal: Double,
                    activeKcal: Double, activeKcalGoal: Double) {
            self.steps = steps
            self.stepGoal = stepGoal
            self.activeMinutes = activeMinutes
            self.activeMinutesGoal = activeMinutesGoal
            self.activeKcal = activeKcal
            self.activeKcalGoal = activeKcalGoal
        }
    }

    /// The result plus each factor's 0…1 goal-attainment (handy for a breakdown view).
    public struct Result: Equatable, Sendable {
        public let score: Int
        public let tier: Tier
        public let factors: [Factor: Double]   // each 0…1 (attainment, capped at 1)
        public enum Factor: String, Equatable, Sendable, CaseIterable {
            case steps, activeMinutes, activeKcal
        }
    }

    /// Default factor weights (sum need not be 1 — renormalised over the PRESENT factors).
    /// Steps carry the most reliable signal (a direct on-ring count); active minutes reward
    /// sustained exertion; active calories are a lighter energy modifier (partly derived
    /// from steps + HR, so weighted least to avoid double-counting movement volume).
    static let factorWeights: [Result.Factor: Double] = [
        .steps: 0.45, .activeMinutes: 0.35, .activeKcal: 0.20,
    ]

    /// Goal-attainment Activity Score (0–100) with tiers. Pure; unit-tested.
    public static func score(_ input: Input) -> Result {
        var f: [Result.Factor: Double] = [:]

        // Each factor is current/goal, capped at 1 — exceeding a goal is "full credit",
        // never > 100 %. A non-positive goal drops the factor (renormalised below).
        if input.stepGoal > 0 {
            f[.steps] = clamp(Double(input.steps) / Double(input.stepGoal))
        }
        if input.activeMinutesGoal > 0 {
            f[.activeMinutes] = clamp(input.activeMinutes / input.activeMinutesGoal)
        }
        if input.activeKcalGoal > 0 {
            f[.activeKcal] = clamp(input.activeKcal / input.activeKcalGoal)
        }

        // Weighted mean over the PRESENT factors only, so a disabled goal doesn't drag the
        // score toward zero.
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

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
