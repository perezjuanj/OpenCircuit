// What a stored Sleep Score is made of — the explainer behind the badge on the Sleep card.
//
// Only the Int `sleepScore` is persisted on a night row. The composite that produced it
// (`SleepScore.composite`) is built in four places with DIFFERENT optional inputs, so a breakdown has
// to be REBUILT from what the row still holds and then CHECKED against the stored number:
//
//   • `RingSession.computeSleepExtras` — ring nights: all six factors. Resting HR comes from the raw
//     records and the temperature offset from the ring's own prior nights.
//   • `StoredNightScore.scores`        — strap nights: the same six factors over the strap's own rows.
//   • `LocalStore.applySleepEdit` / `SleepScoreHeal.healedScore` — an EDITED night: the four
//     duration-driven factors only. There is no HR and no temperature, so the breakdown must not
//     show them.
//
// ⚠️ A BREAKDOWN IS ONLY EVER SHOWN IF IT ADDS UP TO THE BADGE. `rebuild` recomputes the composite
// from the night's stored inputs and returns nil unless that equals the stored score exactly. A
// breakdown that disagrees with the number beside it is worse than none.
//
// TWO SOURCES, ONE RULE. The primary source is the night's SAVED entry (`SleepScoreFactors`), taken by
// the writer in the same call that produced the score: `make(saved:storedScore:)` shows it only while
// its score is still the row's. The fallback is a REBUILD from the row, and only where that was
// measured to be exact: a night edited by the wearer reproduced on every night of one real phone store
// (counts only, `reports/sleep-score-breakdown.md`). A ring night's resting HR comes from raw records
// that are not kept, and a strap night's HR rows keep arriving after the score is written, so those
// producers reproduced on well under 90 % of nights and `make(_:)` declines them
// (`Producer.isReproducible`). Old ring/strap nights, scored before entries were saved, show nothing.
//
// Pure value-type math; nothing here changes the score, the weights or the mappings.

import Foundation

public struct SleepScoreBreakdown: Equatable, Sendable {

    /// Which code produced the stored score, i.e. which optional inputs it was given.
    public enum Producer: String, Codable, Equatable, Sendable, CaseIterable {
        case ring       // `RingSession.computeSleepExtras`: HR + temperature offset when present
        case strap      // `StoredNightScore`: HR + temperature offset when present
        case edited     // `applySleepEdit` / `SleepScoreHeal`: never HR, never temperature

        /// Whether a night from this producer can be REBUILT from its stored row closely enough to be
        /// shown without a saved entry. Decided by measurement, not by argument: see the file header.
        public var isReproducible: Bool {
            switch self {
            case .edited: return true
            case .ring, .strap: return false
            }
        }
    }

    /// What a night row still holds, plus the two optional inputs the producer may have used.
    public struct Night: Equatable, Sendable {
        public var storedScore: Int
        public var producer: Producer
        public var asleepMin: Int           // total asleep, whole minutes (deep + light + REM)
        public var awakeMin: Int
        public var deepMin: Int
        public var lightMin: Int
        public var remMin: Int
        public var efficiency: Double       // 0…1, as stored
        public var restingHR: Double?       // ignored for `.edited`
        public var tempOffsetC: Double?     // ignored for `.edited`
        public var sleepGoal: TimeInterval

        public init(storedScore: Int, producer: Producer,
                    asleepMin: Int, awakeMin: Int, deepMin: Int, lightMin: Int, remMin: Int,
                    efficiency: Double, restingHR: Double? = nil, tempOffsetC: Double? = nil,
                    sleepGoal: TimeInterval = TimeInterval(SleepScore.idealDurationSeconds)) {
            self.storedScore = storedScore
            self.producer = producer
            self.asleepMin = asleepMin
            self.awakeMin = awakeMin
            self.deepMin = deepMin
            self.lightMin = lightMin
            self.remMin = remMin
            self.efficiency = efficiency
            self.restingHR = restingHR
            self.tempOffsetC = tempOffsetC
            self.sleepGoal = sleepGoal
        }
    }

    /// One line of the breakdown.
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: SleepScore.Composite.Factor { factor }
        public let factor: SleepScore.Composite.Factor
        /// Share of the score this factor carries AFTER renormalising over the present factors, 0…1.
        public let weight: Double
        /// The factor's 0–100 sub-score.
        public let subScore: Int
        /// The measured value with its unit, e.g. "6 h 52 m of 8 h goal".
        public let valueText: String

        public var title: String {
            switch factor {
            case .timeAsleep: return "Time asleep"
            case .stages: return "Sleep stages"
            case .efficiency: return "Efficiency"
            case .heartRate: return "Heart rate"
            case .temperature: return "Temperature"
            case .timeAwake: return "Time awake"
            }
        }

        /// "37.5%" / "20%" — whole when it is whole, one decimal otherwise.
        public var weightText: String {
            let pct = weight * 100
            let rounded = (pct * 10).rounded() / 10
            return rounded == rounded.rounded() ? "\(Int(rounded))%" : String(format: "%.1f%%", rounded)
        }
    }

    public let rows: [Row]
    /// The recomputed score — equal to the stored one by construction (see `rebuild`).
    public let score: Int

    /// The sentence under the list.
    public static let footnote = "Weighted average of the factors above. Missing factors are left out and the rest re-weighted."

    // MARK: - Entry points

    /// The breakdown for a night's SAVED entry: nil unless there is one, its score is still the row's
    /// `storedScore`, and its own factors add up to that score. A night re-scored by a path that saved
    /// nothing therefore shows nothing, never the previous score's factors.
    public static func make(saved: SleepScoreFactors?, storedScore: Int) -> SleepScoreBreakdown? {
        guard let saved, storedScore > 0,
              saved.score == storedScore,               // still the row's score
              saved.recomputedScore == saved.score      // and its own factors add up to it
        else { return nil }
        return breakdown(factors: saved.factors, weights: saved.weights,
                         input: saved.inputs.compositeInput, score: saved.score)
    }

    /// The REBUILD the UI may show for a night with no saved entry: nil unless the producer is
    /// reproducible AND the rebuilt score equals the stored one.
    public static func make(_ night: Night) -> SleepScoreBreakdown? {
        night.producer.isReproducible ? rebuild(night) : nil
    }

    /// Rebuild the composite from the row and return its rows, or nil when the recomputed score is
    /// not exactly the stored one (or there is no stored score). Mirrors the producer: an edited
    /// night drops HR and temperature even if the caller handed some in.
    public static func rebuild(_ night: Night) -> SleepScoreBreakdown? {
        guard night.storedScore > 0 else { return nil }
        let usesOptional = night.producer != .edited
        let input = SleepScore.CompositeInput(
            totalAsleep: TimeInterval(night.asleepMin * 60), timeAwake: TimeInterval(night.awakeMin * 60),
            efficiency: night.efficiency,
            deep: TimeInterval(night.deepMin * 60), light: TimeInterval(night.lightMin * 60),
            rem: TimeInterval(night.remMin * 60),
            restingHR: usesOptional ? night.restingHR : nil,
            tempOffsetC: usesOptional ? night.tempOffsetC : nil,
            sleepGoal: night.sleepGoal)
        let entry = SleepScoreFactors.scored(input, producer: night.producer)
        guard entry.score == night.storedScore else { return nil }
        return breakdown(factors: entry.factors, weights: entry.weights, input: input, score: entry.score)
    }

    /// Rows in weight order, each weight renormalised over the PRESENT factors.
    private static func breakdown(factors: [String: Double], weights: [String: Double],
                                  input: SleepScore.CompositeInput, score: Int) -> SleepScoreBreakdown? {
        let present = SleepScore.Composite.Factor.allCases.filter { factors[$0.rawValue] != nil }
        let total = present.reduce(0.0) { $0 + (weights[$1.rawValue] ?? 0) }
        guard total > 0 else { return nil }
        let rows = present.map { factor in
            Row(factor: factor,
                weight: (weights[factor.rawValue] ?? 0) / total,
                subScore: Int(((factors[factor.rawValue] ?? 0) * 100).rounded()),
                valueText: valueText(factor, input: input))
        }
        return SleepScoreBreakdown(rows: rows.sorted { $0.weight > $1.weight }, score: score)
    }

    // MARK: - Value text

    private static func valueText(_ factor: SleepScore.Composite.Factor,
                                  input: SleepScore.CompositeInput) -> String {
        func minutes(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
        switch factor {
        case .timeAsleep:
            return "\(duration(minutes: minutes(input.totalAsleep))) of \(duration(minutes: minutes(input.sleepGoal))) goal"
        case .stages:
            let asleep = max(input.deep + input.light + input.rem, 1)
            return "\(Int(((input.deep + input.rem) / asleep * 100).rounded()))% deep + REM"
        case .efficiency:
            return "\(Int((input.efficiency * 100).rounded()))% efficiency"
        case .heartRate:
            return "\(Int((input.restingHR ?? 0).rounded())) bpm"
        case .temperature:
            let off = input.tempOffsetC ?? 0
            return abs(off) < 0.05 ? "0.0 °C" : String(format: "%+.1f °C", off)
        case .timeAwake:
            return "\(duration(minutes: minutes(input.timeAwake), short: true)) awake"
        }
    }

    /// "6 h 52 m", "8 h", "14 m" — `short` renders minutes as "14 min" for the awake line.
    private static func duration(minutes: Int, short: Bool = false) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return short ? "\(m) min" : "\(m) m" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) \(short ? "min" : "m")"
    }
}
