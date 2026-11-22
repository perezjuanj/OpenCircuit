// The factors behind ONE night's Sleep Score, saved when the score is written, so the Sleep card can
// explain the badge without rebuilding it (see `SleepScoreBreakdown.make(saved:storedScore:)`).
//
// WHY SAVED AND NOT REBUILT. A ring night's resting HR comes from raw records that are not kept, and a
// strap night's heart-rate rows keep arriving after the score is written, so a later rebuild from the
// stored row reproduces the stored score on well under 90 % of nights (measured, counts only, in the
// PR). The only exact record of what a score was made of is the one taken at the moment it was made.
//
// ⚠️ BUILT BY THE SAME CALL THAT PRODUCES THE SCORE. `scored(_:producer:)` runs `SleepScore.composite`
// once and returns the score AND its factors together, and every writer stores `entry.score` as the
// row's `sleepScore`. An entry therefore cannot describe a number other than the one it was saved
// with; whether that number is still the row's is checked at display time.
//
// Pure value type, Codable, no device and no storage: where an entry is kept is the app's business.

import Foundation

public struct SleepScoreFactors: Codable, Equatable, Sendable {

    /// The composite inputs, as given. Mirrors `SleepScore.CompositeInput` (seconds, 0…1, bpm, °C).
    public struct Inputs: Codable, Equatable, Sendable {
        public var totalAsleep: TimeInterval
        public var timeAwake: TimeInterval
        public var efficiency: Double
        public var deep: TimeInterval
        public var light: TimeInterval
        public var rem: TimeInterval
        public var restingHR: Double?
        public var tempOffsetC: Double?
        public var sleepGoal: TimeInterval

        public init(_ input: SleepScore.CompositeInput) {
            totalAsleep = input.totalAsleep
            timeAwake = input.timeAwake
            efficiency = input.efficiency
            deep = input.deep
            light = input.light
            rem = input.rem
            restingHR = input.restingHR
            tempOffsetC = input.tempOffsetC
            sleepGoal = input.sleepGoal
        }

        public var compositeInput: SleepScore.CompositeInput {
            .init(totalAsleep: totalAsleep, timeAwake: timeAwake, efficiency: efficiency,
                  deep: deep, light: light, rem: rem,
                  restingHR: restingHR, tempOffsetC: tempOffsetC, sleepGoal: sleepGoal)
        }
    }

    /// The 0–100 score the row was given.
    public let score: Int
    /// Which writer produced it (for diagnostics; the display does not depend on it).
    public let producer: SleepScoreBreakdown.Producer
    /// Each PRESENT factor's 0…1 sub-score, keyed by `SleepScore.Composite.Factor.rawValue`. A factor
    /// the composite left out (no HR, no temperature baseline) is absent, never 0.
    public let factors: [String: Double]
    /// The raw weight each present factor carried before renormalising, same keys. Saved rather than
    /// read back from `SleepScore.factorWeights`, so an entry keeps adding up to its own score even if
    /// the weights are changed in a later build.
    public let weights: [String: Double]
    public let inputs: Inputs

    public init(score: Int, producer: SleepScoreBreakdown.Producer,
                factors: [String: Double], weights: [String: Double], inputs: Inputs) {
        self.score = score
        self.producer = producer
        self.factors = factors
        self.weights = weights
        self.inputs = inputs
    }

    /// Score a night and capture its factors in one step. Writers store `.score` as the row's
    /// `sleepScore`; nothing else may compute the number they store.
    public static func scored(_ input: SleepScore.CompositeInput,
                              producer: SleepScoreBreakdown.Producer) -> SleepScoreFactors {
        let composite = SleepScore.composite(input)
        var factors: [String: Double] = [:]
        var weights: [String: Double] = [:]
        for (factor, value) in composite.factors {
            factors[factor.rawValue] = value
            weights[factor.rawValue] = SleepScore.factorWeights[factor] ?? 0
        }
        return SleepScoreFactors(score: composite.score, producer: producer,
                                 factors: factors, weights: weights, inputs: Inputs(input))
    }

    /// The weighted mean of the saved factors, rounded the way `SleepScore.composite` rounds, or nil
    /// with no weight. Equal to `score` for any entry `scored` produced.
    public var recomputedScore: Int? {
        var num = 0.0, den = 0.0
        for (key, value) in factors {
            guard let w = weights[key] else { return nil }
            num += w * value
            den += w
        }
        guard den > 0 else { return nil }
        return Int((num / den * 100).rounded())
    }
}
