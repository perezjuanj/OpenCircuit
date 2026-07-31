import Foundation

// Headache signals — the per-user QUALITY MONITOR (#183, Phase 3).
//
// ── POLARITY: THIS IS NOT A PERMISSION GATE ────────────────────────────────────────────────────
// An earlier draft of docs/HEADACHE_SIGNALS.md §5 made this file a gate: no notification until a
// user's own logged headaches proved the detector beat chance. That is roughly a YEAR for a typical
// episodic user (§1.1's power calculation), and most users would never pass it. It was replaced
// deliberately, on two established facts:
//
//   1. RingConn's own bar for the same feature is a 5-day continuous-wear baseline plus a 7-day
//      average, and they publish NO accuracy number anywhere. Their copy is hedged throughout
//      ("Headache SIGNS Alert", "identify early SIGNALS", "POTENTIAL headache symptoms").
//   2. The ~26 % precision ceiling in §1 is an argument against CLAIMING TO PREDICT — not against
//      notifying. "Last night was unusual for you, and here is what drifted" is a MEASUREMENT and
//      is true 100 % of the time. Precision only matters once we assert a headache is coming, and
//      the shipped copy never does: no probability, no score, no "risk", and the word "headache"
//      appears nowhere in the notification title or body.
//
// So the notification unlocks at `HeadacheSignals.Tuning.minDaysForBanding` (21) frozen days — the
// NATURAL floor, because below it `HeadacheSignals.band` has no percentile window, returns
// `.typical` for everything, and there is literally no band to notify about. Everything in this
// file is still computed; it just AUTO-RETIRES the notification for users it demonstrably does not
// help, instead of withholding it from everyone until proven. Same statistics, inverted polarity.
//
// ── THE LABEL-BIAS RULE. READ THIS BEFORE ADDING ANYTHING TO THE NOTIFICATION. ─────────────────
// Every number computed here is valid ONLY while label capture stays INDEPENDENT of the flag.
// The notification therefore carries NO logging action and NO "did you have a headache?" reply
// buttons — even though the earlier plan (§6.4) specified them as the highest-yield adherence fix.
// Those buttons would appear ONLY on flagged days, so labels would be collected disproportionately
// from the days we ourselves flagged. Every precision, lift and p-value below would then be
// inflated BY CONSTRUCTION — invisibly, permanently, and unrecoverably, because afterwards nothing
// can distinguish a spontaneous label from a prompted one.
// Logging lives only on paths that are NOT conditioned on the flag: the Siri intents, the Control
// Centre control, and the daily morning-after card prompt (which deliberately ignores the score for
// exactly this reason). If you are about to add a "helpful" quick-reply to the alert, you are about
// to destroy the only ground truth this feature has.
// ───────────────────────────────────────────────────────────────────────────────────────────────
//
// `.monitoring` IS THE DEFAULT AND IS NOT A FAILURE. Most users will live there for months or
// permanently: a year at the realistic operating point does not produce enough evidence to call the
// detector either way, and §1.1 shows that is expected even for a detector that genuinely works.
// Copy written against `.monitoring` must never read as an error state.
//
// Not a medical device. Nothing here is a diagnosis, and no number here may be presented as the
// probability that a headache is coming.
//
// Pure Foundation, no Apple frameworks, so it unit-tests on the CLI.
public enum HeadacheEvaluation {

    // MARK: - Input

    /// One frozen daily row plus whatever label the user's own log supplies for it.
    ///
    /// A projection of `StoredHeadacheRisk` + `StoredHeadacheEntry` with no SwiftData, HealthKit or
    /// Foundation-calendar dependency, so the whole decision is CLI-testable.
    public struct ScoredDay: Equatable, Sendable {
        /// Start of the calendar day the row covers.
        public let day: Date
        /// When the index was FROZEN. Load-bearing, not decoration: the outcome window opens here,
        /// not at midnight and not at wake. A row frozen at 10:00 must never be credited with a
        /// headache that started at 07:30 — that is retrodiction, and it is exactly the number that
        /// would be quoted as evidence the feature works.
        public let computedAt: Date
        /// The frozen 0…100 index. A relative position on this user's own scale; it is used here
        /// only for RANKING, never as a probability.
        public let index: Int
        public let band: HeadacheSignals.Band
        /// The onset of the headache relevant to this row, if any — see `Tuning.outcomeWindowHours`
        /// and `Tuning.inProgressLookbackHours` for exactly which onsets count. `nil` means the user
        /// logged nothing near this row.
        public let headacheOnset: Date?
        /// The night re-staged after the index was frozen, so the score describes staging the app
        /// itself no longer believes. Excluded from the statistics, never rescored.
        public let sleepRestaged: Bool
        /// Whether the row was frozen after the notification was switched on for this user. Kept so
        /// the anti-nocebo before/since split stays available — see `Scope`.
        public let postUnlock: Bool
        /// Whether a notification actually reached the user for this day (post-suppression,
        /// post-quiet-window, post-ledger). Drives `alertsPerWeek`.
        public let alerted: Bool

        public init(day: Date,
                    computedAt: Date,
                    index: Int,
                    band: HeadacheSignals.Band,
                    headacheOnset: Date? = nil,
                    sleepRestaged: Bool = false,
                    postUnlock: Bool = true,
                    alerted: Bool = false) {
            self.day = day
            self.computedAt = computedAt
            self.index = index
            self.band = band
            self.headacheOnset = headacheOnset
            self.sleepRestaged = sleepRestaged
            self.postUnlock = postUnlock
            self.alerted = alerted
        }
    }

    /// Which rows a `Metrics` run covers. Under the revised design the notification switches on at
    /// day 21, so nearly every row is `.postUnlock` and `.all` is the normal choice; the split
    /// exists so the nocebo question ("did being told make them notice more?") stays ASKABLE rather
    /// than being silently answered by mixing the two populations.
    public enum Scope: String, Equatable, Sendable {
        case all, preUnlock, postUnlock
    }

    // MARK: - Output

    /// Everything measured over one window. Quantities that are genuinely undefined are `nil`, never
    /// 0 — the house rule. A precision of `nil` ("you have never been flagged") and a precision of
    /// 0.0 ("you have been flagged 40 times and none became a headache") are opposite findings and
    /// collapsing them would be a fabricated health value.
    public struct Metrics: Equatable, Sendable {
        /// Days that entered the statistics after every exclusion below.
        public let scoredDays: Int
        /// Eligible days whose outcome window contained a logged headache — i.e. POSITIVES.
        public let labelledDays: Int
        /// Eligible days the detector banded `.flagged`.
        public let flaggedDays: Int
        /// Flagged AND positive.
        public let truePositives: Int

        /// `labelledDays / scoredDays` — how often an average day is followed by a headache.
        public let baseRate: Double?
        /// `truePositives / flaggedDays`.
        public let precision: Double?
        /// `truePositives / labelledDays`.
        public let recall: Double?
        /// `precision / baseRate`. The only quantity here that answers "is being flagged
        /// informative?"; `nil` when either term is undefined or the base rate is 0.
        public let lift: Double?

        /// Mann-Whitney AUC of the frozen index against the label. `nil` when the window contains no
        /// positives or no negatives — AUC is undefined there, not 0.5.
        public let auc: Double?
        /// Hanley-McNeil 95 % interval, clamped to [0, 1].
        public let aucCILow: Double?
        public let aucCIHigh: Double?
        /// EXACT hypergeometric upper tail: the probability that flagging this many days at random
        /// would capture at least this many headaches. `nil` when there is no test to run.
        public let pValue: Double?

        /// Interruptions actually delivered per 7 days of elapsed time across the window.
        public let alertsPerWeek: Double?

        /// Rows dropped because the night re-staged after the index was frozen.
        public let excludedRestaged: Int
        /// Rows dropped because a headache was already under way when the index was frozen.
        public let excludedInProgress: Int
        /// Rows dropped because their 24 h outcome window had not closed yet at `now`.
        public let excludedUnresolved: Int
    }

    public enum Reason: String, Equatable, Sendable {
        /// The 95 % interval for AUC lies at or below chance: measured evidence that ranking by this
        /// index does not order the user's headache days better than a coin.
        case noBetterThanChance
        /// Enough flagged days have accumulated to bound the benefit, and the bound is below the
        /// smallest gain worth interrupting someone for.
        case noUsefulPrecisionGain
    }

    public enum Status: Equatable, Sendable {
        /// Fewer than `minFrozenDaysForNotification` frozen rows exist, so no band exists and there
        /// is nothing to notify about. The only state in which the notification is OFF for a reason
        /// other than measured failure.
        case building(daysRemaining: Int)
        /// Notifying, and the evidence is not strong enough to judge the detector either way. THE
        /// DEFAULT. Not a failure — see the file header.
        case monitoring(Metrics)
        /// Notifying, and this user's own labels say it beats chance.
        case working(Metrics)
        /// The notification has been switched off because the evidence says it does not help.
        case retired(Metrics, reason: Reason)
    }

    // MARK: - Tuning

    /// Every threshold, defaulted, house style. All of the invented ones carry 🔴 PROVISIONAL and a
    /// named calibration plan; the calibration artefact for all of them is the same one, Tier 5 in
    /// docs/HEADACHE_SIGNALS.md §12 — `desktop/headache_backtest.py` over ≥3 testers with ≥50
    /// labelled days each.
    public struct Tuning: Equatable, Sendable {

        /// Trailing window the statistics are measured over. 🟡 365, kept from the plan's §1.1 power
        /// calculation: 180 days cannot reach α = 0.05 even for a detector that genuinely works.
        public var evaluationWindowDays: Int = 365

        /// A frozen row is credited with a headache whose onset falls in
        /// `(computedAt, computedAt + outcomeWindowHours]`. 🟡 24 h — one day of look-ahead, the
        /// same horizon RingConn's own alert implies and the horizon the shipped copy implies.
        public var outcomeWindowHours: Double = 24

        /// An onset in `[computedAt − inProgressLookbackHours, computedAt]` means the headache was
        /// already under way when we scored, so the row is UNCLASSIFIABLE and is dropped from both
        /// terms. 🟡 mirrors `outcomeWindowHours`: an attack older than the outcome horizon is a
        /// different episode, and letting an arbitrarily old onset disqualify a row would let one
        /// mis-entered date silently delete a month of evidence.
        public var inProgressLookbackHours: Double = 24

        /// Frozen rows required before the notification exists at all. 🟡 read live from
        /// `HeadacheSignals.Tuning` so the two cannot drift.
        ///
        /// This is deliberately NOT the copy-as-a-literal treatment `saturationZ` gets. That rule
        /// exists because a frozen index must never be re-scaled after the fact; this is a GATE
        /// recomputed from scratch on every call, so a single source of truth is the safer shape.
        /// If banding ever needs more history, the unlock must move with it — a user who is told
        /// alerts are on but whose rows can never band would have no way to understand why.
        public var minFrozenDaysForNotification: Int = HeadacheSignals.Tuning().minDaysForBanding

        // MARK: Calling it working

        /// 🟢 One-sided-equivalent α for the exact hypergeometric test. Tightened from 0.05 because
        /// `status(_:now:)` is stateless and the UI may call it on every refresh: with no memory of
        /// previous looks, multiplicity can only be controlled by demanding a loud result.
        public var workingAlpha: Double = 0.01
        /// 🔴 PROVISIONAL. Eligible days before `.working` may be claimed at all.
        public var minScoredDaysForWorking: Int = 120
        /// 🟢 Below 8 positives the exact hypergeometric tail cannot reach `workingAlpha` at any
        /// flagging rate, so the claim is unreachable anyway; stating the floor makes the UI able to
        /// say "3 of 8 headaches logged" instead of silently never concluding.
        public var minPositivesForWorking: Int = 8

        // MARK: Retiring it

        // THE MINIMUM EVIDENCE BAR. Retiring on three days of bad luck is exactly as wrong as
        // promoting on three days of good luck, and the arithmetic makes it easy to do by accident:
        // the Hanley-McNeil standard error collapses to ZERO at AUC 0 or 1, so two positives that
        // both happen to score below five negatives produce the interval [0, 0] and would "prove"
        // the detector is worse than chance on a week of data. The bar below is what stops that.

        /// 🔴 PROVISIONAL — 180 eligible days. Justification, and it is not arbitrary: §1.1 computes
        /// that at the realistic operating point (AUC 0.65, 4 headache days/month, top-10 % flagging)
        /// a detector that GENUINELY WORKS still fails α = 0.05 at 180 days. Below that horizon
        /// "no evidence of benefit" is the expected reading for a good detector as much as a useless
        /// one, so retiring there would retire working detectors at a high rate. Calibration plan:
        /// re-derive from the measured per-user AUC distribution once Tier 5 has ≥3 testers.
        public var minScoredDaysForRetirement: Int = 180
        /// 🟢 Symmetry, and the cheapest fairness rule available: never retire on data that could
        /// not have promoted. 8 positives is the floor at which `workingAlpha` is reachable at all,
        /// so it is also the floor at which the opposite conclusion was on the table.
        public var minPositivesForRetirement: Int = 8
        /// 🔴 PROVISIONAL. Precision on fewer than 10 flagged days moves by a full 10 points on one
        /// day, which is noise, not a verdict.
        public var minFlaggedForRetirement: Int = 10

        /// 🟢 Chance. An AUC interval whose UPPER bound sits at or below this is evidence of
        /// ABSENCE, not merely absence of evidence.
        public var chanceAUC: Double = 0.5

        /// 🔴 PROVISIONAL. The smallest precision gain over the user's own base rate that justifies
        /// an interruption: a flagged morning must be at least 5 percentage points likelier to be
        /// followed by a headache than an average morning. Below that the alert costs more attention
        /// than it returns information. Calibration plan: the Tier-5 per-user precision-gain
        /// distribution; if most working users sit under it, it is too high.
        public var minUsefulPrecisionGain: Double = 0.05

        /// 🟢 Two-sided 95 % normal deviate, for the AUC interval the UI displays as "95 % CI".
        public var ciZ: Double = 1.96
        /// 🟢 One-sided 95 % normal deviate, for the one-sided equivalence bound on precision. The
        /// question there is genuinely one-sided ("could the gain still be worth it?"), and using
        /// the two-sided deviate for it would be conservative in the wrong direction — it would keep
        /// a measurably useless alert running for roughly another year.
        public var equivalenceZ: Double = 1.645

        public init() {}
    }

    // MARK: - Metrics

    /// Measure one window. Pure, deterministic, and free of `Calendar` so it cannot move under a
    /// timezone change mid-window.
    public static func metrics(_ days: [ScoredDay],
                               now: Date,
                               tuning: Tuning = Tuning(),
                               scope: Scope = .all) -> Metrics {
        let cutoff = now.addingTimeInterval(-Double(tuning.evaluationWindowDays) * 86_400)
        let outcome = tuning.outcomeWindowHours * 3600
        let lookback = tuning.inProgressLookbackHours * 3600

        var excludedRestaged = 0
        var excludedInProgress = 0
        var excludedUnresolved = 0

        var positiveScores: [Double] = []
        var negativeScores: [Double] = []
        var flagged = 0
        var truePositives = 0
        var alerted = 0
        var earliest: Date?
        var latest: Date?

        for row in days {
            guard row.day >= cutoff, row.computedAt <= now else { continue }
            switch scope {
            case .all: break
            case .preUnlock: guard !row.postUnlock else { continue }
            case .postUnlock: guard row.postUnlock else { continue }
            }

            // Interruptions are counted BEFORE the statistical exclusions, and deliberately so.
            // `alertsPerWeek` describes what happened to the person, not what the detector can be
            // scored on: an alert that fired on a night which later re-staged still woke them up.
            // Counting it only when the row survives into the statistics would under-report the
            // one number a user can check against their own memory.
            if row.alerted { alerted += 1 }
            if earliest == nil || row.day < earliest! { earliest = row.day }
            if latest == nil || row.day > latest! { latest = row.day }

            // EXCLUSION ORDER IS DELIBERATE, because each row is counted at most once.
            //
            // 1. Restaged first: the score describes staging the app no longer believes, so nothing
            //    downstream of it is interpretable. It is never rescored (the freeze invariant,
            //    §3.8) — rescoring with today's fuller baseline is precisely the leak the freeze
            //    exists to prevent.
            if row.sleepRestaged { excludedRestaged += 1; continue }

            // 2. Already in progress: a PERMANENT property of the row, so it outranks "not resolved
            //    yet", which only means "wait". Predicting something that had already started is not
            //    a prediction, and counting it either way is dishonest — as a hit it inflates
            //    precision, as a miss it punishes the detector for an attack it could not have
            //    foreseen.
            if let onset = row.headacheOnset,
               onset <= row.computedAt, onset >= row.computedAt.addingTimeInterval(-lookback) {
                excludedInProgress += 1
                continue
            }

            // 3. Outcome window still open. Dropped ENTIRELY, including rows whose headache has
            //    already been logged: keeping the known-positives while dropping the not-yet-known
            //    would bias the base rate and the precision upward by construction. Excluding the
            //    whole unresolved tail is the only unbiased choice.
            if row.computedAt.addingTimeInterval(outcome) > now { excludedUnresolved += 1; continue }

            let positive: Bool
            if let onset = row.headacheOnset {
                positive = onset > row.computedAt
                    && onset <= row.computedAt.addingTimeInterval(outcome)
            } else {
                positive = false
            }

            let score = Double(row.index)
            if positive { positiveScores.append(score) } else { negativeScores.append(score) }
            if row.band == .flagged {
                flagged += 1
                if positive { truePositives += 1 }
            }
        }

        let scoredDays = positiveScores.count + negativeScores.count
        let labelled = positiveScores.count

        let baseRate: Double? = scoredDays > 0 ? Double(labelled) / Double(scoredDays) : nil
        let precision: Double? = flagged > 0 ? Double(truePositives) / Double(flagged) : nil
        let recall: Double? = labelled > 0 ? Double(truePositives) / Double(labelled) : nil
        let lift: Double? = {
            guard let p = precision, let b = baseRate, b > 0 else { return nil }
            return p / b
        }()

        let a = auc(positiveScores: positiveScores, negativeScores: negativeScores)
        var ciLow: Double?
        var ciHigh: Double?
        if let a, let se = hanleyMcNeilSE(auc: a, nPos: positiveScores.count,
                                          nNeg: negativeScores.count) {
            ciLow = min(max(a - tuning.ciZ * se, 0), 1)
            ciHigh = min(max(a + tuning.ciZ * se, 0), 1)
        }

        // `nil`, not 1.0, when there is nothing to test: "you have never been flagged" is not the
        // same finding as "flagging you told us nothing".
        let p: Double? = (flagged > 0 && labelled > 0)
            ? hypergeometricUpperTail(observed: truePositives, flagged: flagged,
                                      positives: labelled, total: scoredDays)
            : nil

        // Elapsed calendar time across the window, not a count of days: an interruption rate is
        // something the user feels in weeks. Measured between the first and last row we hold rather
        // than out to `now`, because extrapolating across a stretch where the ring was not worn
        // would invent alerts that could never have fired.
        var alertsPerWeek: Double?
        if let earliest, let latest {
            let spanDays = max(1.0, (latest.timeIntervalSince(earliest) / 86_400).rounded() + 1)
            alertsPerWeek = 7 * Double(alerted) / spanDays
        }

        return Metrics(scoredDays: scoredDays,
                       labelledDays: labelled,
                       flaggedDays: flagged,
                       truePositives: truePositives,
                       baseRate: baseRate,
                       precision: precision,
                       recall: recall,
                       lift: lift,
                       auc: a,
                       aucCILow: ciLow,
                       aucCIHigh: ciHigh,
                       pValue: p,
                       alertsPerWeek: alertsPerWeek,
                       excludedRestaged: excludedRestaged,
                       excludedInProgress: excludedInProgress,
                       excludedUnresolved: excludedUnresolved)
    }

    // MARK: - Status

    public static func status(_ days: [ScoredDay],
                              now: Date,
                              tuning: Tuning = Tuning()) -> Status {
        let frozen = frozenRowCount(days, now: now, tuning: tuning)
        if frozen < tuning.minFrozenDaysForNotification {
            return .building(daysRemaining: tuning.minFrozenDaysForNotification - frozen)
        }
        let m = metrics(days, now: now, tuning: tuning)
        // Retirement is evaluated FIRST. The two outcomes are mutually exclusive in practice (an
        // interval cannot have its lower bound above chance and its upper bound at or below it), but
        // where a rule has to break a tie, declining to claim the feature works is the conservative
        // direction for a claim.
        if let reason = shouldRetire(m, tuning: tuning) { return .retired(m, reason: reason) }
        if meetsWorkingBar(m, tuning: tuning) { return .working(m) }
        return .monitoring(m)
    }

    /// Evidence that the detector does NOT help this user, or `nil`.
    ///
    /// Two complementary tests, because "harmful" and "useless" are different findings:
    ///   · `.noBetterThanChance` catches a detector whose ranking is measurably no better than a
    ///     coin — including an actively inverted one.
    ///   · `.noUsefulPrecisionGain` is an EQUIVALENCE test, and it is the one that eventually
    ///     retires a detector sitting exactly at chance. Note what it is NOT: "the precision
    ///     interval overlaps the base rate" would retire almost everybody, because overlapping is
    ///     the definition of `.monitoring` — not enough evidence yet. Only a bound TIGHT ENOUGH to
    ///     rule out a worthwhile gain is evidence of absence.
    ///
    /// ⚠️ CALLER CONTRACT — DO NOT ACT ON ONE RECOMMENDATION. This function is stateless, so asking
    /// it more often finds more bad-luck runs. Measured on synthetic years
    /// (`testChanceLevelDetectorIsEventuallyRetiredButMonitoringDominates`): a chance-level detector
    /// retires for 15 % of users at a single look but 24 % when the same year is re-examined every
    /// 28 days. The app must therefore require the recommendation to PERSIST across consecutive
    /// decision points before switching the notification off — the plan's `decisionIntervalDays` /
    /// `requiredConsecutivePasses` machinery (§5.4), inverted to guard retirement instead of
    /// promotion. Multiplicity here is bounded, not solved.
    public static func shouldRetire(_ m: Metrics, tuning: Tuning = Tuning()) -> Reason? {
        guard m.scoredDays >= tuning.minScoredDaysForRetirement,
              m.labelledDays >= tuning.minPositivesForRetirement,
              m.flaggedDays >= tuning.minFlaggedForRetirement else { return nil }

        if let high = m.aucCIHigh, high <= tuning.chanceAUC { return .noBetterThanChance }

        if let base = m.baseRate,
           let upper = wilsonUpperBound(successes: m.truePositives, trials: m.flaggedDays,
                                        z: tuning.equivalenceZ),
           upper <= base + tuning.minUsefulPrecisionGain {
            return .noUsefulPrecisionGain
        }
        return nil
    }

    /// Evidence that the detector DOES help this user. Deliberately strict: `.working` is the only
    /// state that comes close to an accuracy claim, and the project does not make accuracy claims
    /// cheaply. It grants nothing — the notification is already on — so a strict bar costs the user
    /// nothing but a label.
    public static func meetsWorkingBar(_ m: Metrics, tuning: Tuning = Tuning()) -> Bool {
        guard m.scoredDays >= tuning.minScoredDaysForWorking,
              m.labelledDays >= tuning.minPositivesForWorking,
              let low = m.aucCILow, low > tuning.chanceAUC,
              let p = m.pValue, p <= tuning.workingAlpha else { return false }
        return true
    }

    // MARK: - Internals

    /// Frozen rows inside the evaluation window — restaged ones INCLUDED.
    ///
    /// A restaged row is excluded from the statistics but it is still a real frozen index that sits
    /// in `HeadacheSignals.band`'s percentile window, so it does count toward "is there a band yet".
    /// Note also that `band` takes `priorIndices.suffix(bandWindowDays)` — the last 60 ENTRIES, not
    /// the last 60 calendar days — so the banding precondition reduces to "at least
    /// `minDaysForBanding` frozen rows exist", which is what this counts.
    static func frozenRowCount(_ days: [ScoredDay], now: Date, tuning: Tuning) -> Int {
        let cutoff = now.addingTimeInterval(-Double(tuning.evaluationWindowDays) * 86_400)
        return days.filter { $0.day >= cutoff && $0.computedAt <= now }.count
    }

    /// Mann-Whitney AUC: the probability that a randomly chosen headache day outranks a randomly
    /// chosen ordinary day, with ties split.
    ///
    /// TIE RULE, STATED EXPLICITLY BECAUSE IT DOMINATES HERE: a large share of days share index 0 by
    /// design — every feature inside 1 MAD-unit contributes exactly 0 (`HeadacheSignals.Tuning
    /// .onsetZ`), so an ordinary day scores a true 0 rather than a fabricated small number. A tied
    /// pair counts 0.5, the standard convention and the ONLY one that makes a detector with no
    /// discrimination at all score exactly 0.5. Crediting ties as wins would score a constant
    /// detector — one that emits the same number every single day — as PERFECT.
    ///
    /// Implemented through the midrank identity `AUC = (R⁺ − n⁺(n⁺+1)/2) / (n⁺·n⁻)`, which is
    /// algebraically identical to counting pairs with ties at 0.5 and is O(n log n) rather than
    /// O(n⁺·n⁻). `testAUCMidrankIdentityMatchesPairwiseCount` pins the equivalence on random data.
    static func auc(positiveScores: [Double], negativeScores: [Double]) -> Double? {
        let nPos = positiveScores.count
        let nNeg = negativeScores.count
        guard nPos > 0, nNeg > 0 else { return nil }
        let ranks = midranks(positiveScores + negativeScores)
        let rankSumPositives = ranks.prefix(nPos).reduce(0, +)
        let u = rankSumPositives - Double(nPos) * Double(nPos + 1) / 2
        return u / (Double(nPos) * Double(nNeg))
    }

    /// 1-based ranks with tied values sharing their average rank.
    static func midranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var out = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
            let shared = Double((i + 1) + (j + 1)) / 2
            for k in i...j { out[order[k]] = shared }
            i = j + 1
        }
        return out
    }

    /// Hanley-McNeil standard error of an AUC.
    ///
    /// `Q1 = A/(2−A)`, `Q2 = 2A²/(1+A)`,
    /// `SE = √( [A(1−A) + (n⁺−1)(Q1−A²) + (n⁻−1)(Q2−A²)] / (n⁺·n⁻) )`.
    ///
    /// RESIDUAL, and it is real: Hanley-McNeil is derived for CONTINUOUS scores, and this index is
    /// heavily tied at 0. Ties reduce the variance of U, so the interval this returns is on the WIDE
    /// side for our data — conservative for `.working` (harder to claim) and conservative for
    /// `.noBetterThanChance` (harder to retire), which is the safe direction for both. It is an
    /// approximation, not an exact interval, and the UI must not present it as one. Calibration
    /// plan: compare against a bootstrap interval on real per-user series in Tier 5.
    static func hanleyMcNeilSE(auc a: Double, nPos: Int, nNeg: Int) -> Double? {
        guard nPos > 0, nNeg > 0 else { return nil }
        let q1 = a / (2 - a)
        let q2 = 2 * a * a / (1 + a)
        let numerator = a * (1 - a)
            + Double(nPos - 1) * (q1 - a * a)
            + Double(nNeg - 1) * (q2 - a * a)
        let variance = numerator / (Double(nPos) * Double(nNeg))
        guard variance.isFinite, variance >= 0 else { return nil }
        return variance.squareRoot()
    }

    /// EXACT upper tail `P(X ≥ observed)` for `X ~ Hypergeometric(total, positives, flagged)`.
    ///
    /// This IS the permutation test the plan specified, in closed form. Shuffling the labels while
    /// holding the flags fixed makes the true-positive count exactly hypergeometric, so 2000 seeded
    /// shuffles would be a Monte-Carlo ESTIMATE — with a resolution floor of 1/2001 and its own
    /// sampling noise — of the number computed here without either. Being base-rate-free by
    /// construction (the null preserves the observed base rate) is what makes it usable for a
    /// chronic sufferer, and that property is a feature of the null, not of the shuffling.
    ///
    /// A normal approximation is NOT acceptable here and that is the whole reason this is exact: a
    /// typical user contributes tens of positives, and in exactly that regime the normal
    /// approximation to the hypergeometric is ANTI-CONSERVATIVE in the upper tail — it would report
    /// significance that the exact distribution does not support, on the one number that decides
    /// whether we tell someone the feature works for them.
    ///
    /// Log-factorials are summed here rather than calling `lgamma` because on Darwin `lgamma` is
    /// ambiguous between the C function and the Swift overlay's tuple-returning `lgamma_r`, and
    /// because at these counts a prefix sum of `log(i)` is both exact enough (≈1e-13 relative) and
    /// obviously correct on inspection.
    static func hypergeometricUpperTail(observed: Int,
                                        flagged: Int,
                                        positives: Int,
                                        total: Int) -> Double? {
        guard total > 0, flagged >= 0, positives >= 0,
              flagged <= total, positives <= total, observed >= 0 else { return nil }
        let lo = max(0, flagged + positives - total)
        let hi = min(flagged, positives)
        guard hi >= lo else { return nil }
        if observed <= lo { return 1 }
        if observed > hi { return 0 }

        var logFactorial = [Double](repeating: 0, count: total + 1)
        if total >= 1 {
            var acc = 0.0
            for i in 1...total {
                acc += Foundation.log(Double(i))
                logFactorial[i] = acc
            }
        }
        func logChoose(_ n: Int, _ k: Int) -> Double {
            guard k >= 0, k <= n else { return -.infinity }
            return logFactorial[n] - logFactorial[k] - logFactorial[n - k]
        }

        let logDenominator = logChoose(total, flagged)
        var sum = 0.0
        // Descending, so the smallest terms are accumulated first.
        for k in stride(from: hi, through: observed, by: -1) {
            let logTerm = logChoose(positives, k)
                + logChoose(total - positives, flagged - k)
                - logDenominator
            if logTerm.isFinite { sum += Foundation.exp(logTerm) }
        }
        return min(max(sum, 0), 1)
    }

    /// Wilson score interval upper bound for a proportion. Chosen over the Wald interval because
    /// Wald's bound collapses to the point estimate at 0 successes — which would let "0 of 12
    /// flagged days became a headache" produce a bound of exactly 0 and retire instantly on a
    /// handful of days.
    static func wilsonUpperBound(successes: Int, trials: Int, z: Double) -> Double? {
        guard trials > 0, successes >= 0, successes <= trials else { return nil }
        let n = Double(trials)
        let p = Double(successes) / n
        let z2 = z * z
        let denominator = 1 + z2 / n
        let centre = (p + z2 / (2 * n)) / denominator
        let half = z * ((p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()) / denominator
        return min(max(centre + half, 0), 1)
    }
}
