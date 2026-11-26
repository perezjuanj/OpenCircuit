// Today synthesis (#216) — the one plain-language sentence at the top of the Today tab.
//
// Deterministic templates over numbers the app already computes: Recovery (decision 93: exactly as
// Today's scores card produces it — this type never re-scores anything) and the
// tiles' `BaselineTrend` directions. No model, no randomness, no advice beyond "an easier day may
// help" / "take today gently" — and every missing input degrades to a sentence that SAYS it is
// missing rather than one that guesses around it.
//
// Rule order (first match wins, then clauses are composed):
//   1. no data at all               → say so, point at connect + sync
//   2. newest data older than 36 h  → say how old, point at sync
//   3. readiness states             → lead with Recovery (or why there is none), then the most
//                                     notable vitals clause: concerns first, then positives, then
//                                     "in your usual range"
// Possible fever signs are surfaced ahead of any other clause, but ONLY when Vitals Status itself
// flagged them (`Input.feverSuspected`, its `VitalsBaseline.Report.feverSuspected`: skin temp up
// ≥ 1.0 °C AND resting HR up ≥ 8 bpm against a 7+ day baseline). The tiles' own bands are looser
// (0.3 °C, 2 bpm, 4 days), so both tiles reading "above your usual" is not fever, and this line must
// never say "take today gently" on a screen whose Vitals Status card says nothing is wrong. Each tile
// direction still speaks for itself as an ordinary clause.

import Foundation

public enum TodaySynthesis {

    /// Recovery as Today's scores card ended up showing it (the type keeps its old name; every
    /// user-facing word says "Recovery", decision 93a).
    public enum Readiness: Equatable, Sendable {
        /// A score was computed. `factorCount` is how many sub-scores went into it (1 = sleep alone).
        case scored(score: Int, tier: WellnessBalance.Tier, factorCount: Int)
        /// No night that ended today is stored — a sync can fix this.
        case noNight
        /// Last night is stored but carries no sleep score — a sync cannot fix this.
        case noScore
        /// Not computed yet (first frame, or the card hasn't reported).
        case pending
    }

    public struct Input: Equatable, Sendable {
        public var readiness: Readiness
        public var hrv: BaselineTrend.Direction?
        public var restingHR: BaselineTrend.Direction?
        public var skinTemp: BaselineTrend.Direction?
        /// Vitals Status's own verdict: its report has `feverSuspected`. False while it hasn't reported.
        public var feverSuspected: Bool
        /// Last night's asleep minutes, when a night that ended today is stored.
        public var lastNightSleepMinutes: Int?
        /// Typical asleep minutes over recent nights, for the "short night" rule.
        public var usualSleepMinutes: Double?
        /// Time of the newest stored wearable data of any kind (either device's); nil when there is none.
        public var newestDataAt: Date?
        public var now: Date

        public init(readiness: Readiness = .pending,
                    hrv: BaselineTrend.Direction? = nil,
                    restingHR: BaselineTrend.Direction? = nil,
                    skinTemp: BaselineTrend.Direction? = nil,
                    feverSuspected: Bool = false,
                    lastNightSleepMinutes: Int? = nil,
                    usualSleepMinutes: Double? = nil,
                    newestDataAt: Date?,
                    now: Date) {
            self.readiness = readiness
            self.hrv = hrv
            self.restingHR = restingHR
            self.skinTemp = skinTemp
            self.feverSuspected = feverSuspected
            self.lastNightSleepMinutes = lastNightSleepMinutes
            self.usualSleepMinutes = usualSleepMinutes
            self.newestDataAt = newestDataAt
            self.now = now
        }
    }

    /// Data older than this reads as stale rather than "today".
    public static let staleAfter: TimeInterval = 36 * 3600
    /// A night shorter than this is "short" regardless of the user's usual.
    public static let shortNightMinutes = 360
    /// …or this much shorter than their usual.
    public static let shortVsUsualMinutes = 60.0

    public static func sentence(_ input: Input) -> String {
        guard let newest = input.newestDataAt else {
            return "There's no data from your device yet, so connect and sync it to see today's summary."
        }
        let age = input.now.timeIntervalSince(newest)
        if age > staleAfter {
            let days = Int(age / 86_400)
            // The app only looks back two weeks, so it can't honestly name an age past that.
            let howOld = days <= 1 ? "over a day old" : days >= 14 ? "more than two weeks old" : "\(days) days old"
            return "Your newest data is \(howOld), so sync your device to bring today's summary up to date."
        }

        let concerns = concernClauses(input)
        let positives = positiveClauses(input)
        let steady = steadyClause(input)
        let feverPair = input.feverSuspected
        let feverClause = "skin temperature and resting heart rate are both above your usual"

        switch input.readiness {
        case let .scored(score, tier, factorCount):
            var lead: String
            switch tier {
            case .excellent:        lead = "Recovery is excellent at \(score)"
            case .good:             lead = "Recovery is good at \(score)"
            case .needsImprovement: lead = "Recovery needs improvement at \(score)"
            }
            if factorCount <= 1 { lead += " based on last night's sleep alone" }
            if feverPair { return "\(lead), but \(feverClause), so take today gently." }
            switch tier {
            case .excellent, .good:
                if let c = concerns.first { return "\(lead), though \(c)." }
                if let p = positives.first { return "\(lead), and \(p)." }
                if let s = steady { return "\(lead), with \(s.subject) in your usual range." }
                return "\(lead)."
            case .needsImprovement:
                if let c = concerns.first { return "\(lead), and \(c), so an easier day may help." }
                return "\(lead), so an easier day may help."
            }

        case .noNight, .noScore:
            let lead = input.readiness == .noNight
                ? "Last night's sleep hasn't synced yet, so there's no recovery score"
                : "Last night has no sleep score, so there's no recovery today"
            if feverPair { return "\(lead), but \(feverClause)." }
            if let c = concerns.first ?? positives.first { return "\(lead), but \(c)." }
            if let s = steady { return "\(lead), but \(s.subject) \(s.verb) in your usual range." }
            return "\(lead)."

        case .pending:
            if feverPair { return capitalized(feverClause) + ", so take today gently." }
            if let c = concerns.first ?? positives.first { return capitalized(c) + "." }
            if let s = steady { return capitalized(s.subject) + " \(s.verb) in your usual range." }
            return "Working out today's recovery."
        }
    }

    // MARK: - Clauses

    private static func sleepWasShort(_ i: Input) -> Bool {
        guard let last = i.lastNightSleepMinutes, last > 0 else { return false }
        if last < shortNightMinutes { return true }
        if let usual = i.usualSleepMinutes, usual > 0, Double(last) < usual - shortVsUsualMinutes { return true }
        return false
    }

    private static func concernClauses(_ i: Input) -> [String] {
        var out: [String] = []
        if sleepWasShort(i) { out.append("last night's sleep was short") }
        if i.hrv == .below { out.append("HRV is below your usual") }
        if i.restingHR == .above { out.append("resting heart rate is above your usual") }
        if i.skinTemp == .above { out.append("skin temperature is above your usual") }
        return out
    }

    private static func positiveClauses(_ i: Input) -> [String] {
        var out: [String] = []
        if i.hrv == .above { out.append("HRV is above your usual") }
        if i.restingHR == .below { out.append("resting heart rate is below your usual") }
        return out
    }

    /// The metrics that are known AND within their usual range, with the verb that agrees with them.
    private static func steadyClause(_ i: Input) -> (subject: String, verb: String)? {
        switch (i.hrv == .within, i.restingHR == .within) {
        case (true, true):  return ("HRV and resting heart rate", "are")
        case (true, false): return ("HRV", "is")
        case (false, true): return ("resting heart rate", "is")
        default:            return nil
        }
    }

    private static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
