import Foundation

// Headache signals — a per-user "how unusual was last night, for you?" index (#183, Phase 2).
//
// READ THIS BEFORE CHANGING A CONSTANT.
//
// 1. THIS IS AN ESTIMATE, AND A WEAK ONE. The published ceiling for physiology-only headache
//    forecasting is AUC ≈ 0.62–0.68. At the operating point below (flag the top 10 % of a user's
//    own days) that means:
//
//      AUC 0.65, 4 headache days/month → ~26 % precision, ~23 % recall, ~0.8 alerts/week.
//      In plain words: about THREE IN FOUR flagged days will not become a headache, and about
//      THREE IN FOUR headaches will not be flagged.
//
//    Nothing here may be presented as a probability, a percentage chance, or a risk. The index is
//    a RELATIVE position on one person's own scale and means nothing across people.
//
// 2. WE SCORE HOW UNUSUAL A NIGHT WAS, IN EITHER DIRECTION — NOT HOW BAD IT WAS. Every feature
//    except `arousalLetdown` and `perimenstrual` contributes UNSIGNED |z|. That is the correct
//    response to a measured fact: pre-attack signal directions INVERT between people (in the one
//    nocturnal-wearable study, one participant's migraines followed short sleep and another's
//    followed long; higher minimum PRV predicted headache). A population-signed rule would be
//    actively wrong for a large fraction of users. The cost is real and must stay stated in the UI:
//    it roughly halves usable information, and an unusually RESTORATIVE night scores the same as a
//    bad one.
//
// 3. THINGS THIS CANNOT TELL APART, by construction: a hangover, a late night out, and a hard
//    training day all produce the same signature as a prodrome. Named in the shipped copy rather
//    than hidden.
//
// 4. Not a medical device. Not a diagnosis. The detector writes NOTHING to Apple Health — the only
//    thing that ever reaches Health from this feature is what the user typed.
//
// Weights follow the cited evidence rather than intuition — in particular sleep DURATION and
// FRAGMENTATION are deliberately demoted, because the largest prospective diary study concluded
// short sleep and low quality were *not* temporally associated with migraine and found
// fragmentation associated in the WRONG direction; only sleep EFFICIENCY reached day-1
// significance. See docs/HEADACHE_SIGNALS.md §3.4 for the full table and citations.
//
// Pure Foundation, no Apple frameworks, so it unit-tests on the CLI.
public enum HeadacheSignals {

    // MARK: - Features

    public enum Feature: String, CaseIterable, Sendable {
        case sleepEfficiencyDrop
        case arousalLetdown
        case hrvDeviation
        case restingHRDeviation
        case sleepFragmentation
        case sleepDurationDeviation
        case scheduleShift
        case skinTempDeviation
        case perimenstrual

        /// Absolute deviation below which the feature contributes exactly 0 regardless of z, so a
        /// person with a very tight baseline is not flagged on a 1-LSB wobble.
        public var noiseFloor: Double {
            switch self {
            case .restingHRDeviation:     return 5      // 🟡 VitalsBaseline.Config().minDeltaRestingHR
            case .hrvDeviation:           return 8      // 🟡 .minDeltaHRV
            case .skinTempDeviation:      return 0.3    // 🟡 SkinTempBaseline.fluctuationBaselineGateC
            case .sleepEfficiencyDrop:    return 5      // 🟢 %-pt; Bertisch day-1 signal was ≤90 % vs ~95 %
            case .sleepFragmentation:     return 15     // 🔴 PROVISIONAL, minutes
            case .sleepDurationDeviation: return 30     // 🔴 PROVISIONAL, minutes
            case .scheduleShift:          return 30     // 🟡 half the 60-min SD TrendsEngine.sleepRegularity maps to 0
            // Deliberately 0, and NOT the 0.5 the plan first specified. This feature's value is a
            // DIFFERENCE OF TWO z-SCORES, so it never passes through `RobustBaseline.z` as a raw
            // reading and has no divisor to floor: the two underlying day-HR values are floored at
            // `restingHRDeviation.noiseFloor` (5 bpm, the right unit for them), and the resulting
            // z-difference is gated by `Tuning.onsetZ` (1.0). A declared 0.5 here would be an
            // unconsumed constant that reads like shipped behaviour and is inert even if wired up,
            // since onsetZ is already stricter.
            case .arousalLetdown:         return 0
            case .perimenstrual:          return 0      // binary
            }
        }

        /// Weight in the renormalised pool. The eight ring-derived features sum to exactly 1.00;
        /// `perimenstrual` is additive and ring-fenced (see `isRingDerived`).
        public var weight: Double {
            switch self {
            case .sleepEfficiencyDrop:    return 0.18   // 🟢 Bertisch day-1 OR 1.39 — the only sleep term with support
            case .arousalLetdown:         return 0.18   // 🟢 Lipton 2014 OR 1.5–1.9 for a stress DECLINE
            case .hrvDeviation:           return 0.14   // 🟡 Koenig g=−0.63 is BETWEEN-person; within-person ~flat ictally
            case .restingHRDeviation:     return 0.14   // 🟢 JHP 2026 ranked HR features third
            case .sleepFragmentation:     return 0.10   // 🟢 demoted — Bertisch's day-0 association ran the wrong way
            case .sleepDurationDeviation: return 0.10   // 🟢 demoted — "not temporally associated"
            case .scheduleShift:          return 0.08   // 🔴 PROVISIONAL — plausible, no prospective wearable evidence
            case .skinTempDeviation:      return 0.08   // 🟢 kept low; strongest temp result is an N=2 study
            case .perimenstrual:          return 0.20   // 🟢 MacGregor perimenstrual estrogen withdrawal
            }
        }

        /// Whether the feature comes from the RING. `perimenstrual` is a calendar lookup and must
        /// never count toward the minimum that decides whether we measured enough to score at all.
        public var isRingDerived: Bool { self != .perimenstrual }

        /// Features that can ANCHOR a verdict. A day made only of cycle phase, schedule and skin
        /// temperature has measured nothing about how the person actually slept or how their
        /// autonomic state moved, and must not synthesise a verdict out of context alone.
        public static let anchors: Set<Feature> = [
            .sleepEfficiencyDrop, .sleepFragmentation, .sleepDurationDeviation,
            .hrvDeviation, .restingHRDeviation,
        ]
    }

    public enum AbsentReason: String, Equatable, Sendable {
        case noBaseline, noDataThisDay, featureDisabled, lowCoverage, notApplicable
    }

    public enum Band: Int, Equatable, Sendable, Comparable {
        case typical = 0, elevated = 1, flagged = 2
        public static func < (a: Band, b: Band) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Suppression: String, Equatable, Sendable {
        case fever, headacheAlreadyLogged
    }

    // MARK: - Tuning

    /// Every constant, defaulted. `Equatable`/`Sendable`, house style — a caller that constructs
    /// `Tuning()` gets exactly the shipped behaviour, so a test can vary one knob without
    /// re-specifying the world.
    public struct Tuning: Equatable, Sendable {
        /// Below this |z| a feature contributes exactly 0, so an ordinary day scores 0 rather than
        /// a fabricated "low risk 23 %". 🔴 PROVISIONAL. Set below `VitalsBaseline`'s minor z (1.5)
        /// because a soft composite should start counting before the vitals engine calls it Minor.
        public var onsetZ: Double = 1.0
        /// 🟡 Numerically equal to `VitalsBaseline.Config().significantZ`, but COPIED AS A LITERAL
        /// on purpose. Reading it live would let a future vitals retune silently move the headache
        /// scale — and because frozen rows are never recomputed, that would mix two different
        /// scales inside a single evaluation and invalidate every stored index.
        public var saturationZ: Double = 2.5
        /// Skin temp ramps in °C, not z. 🟡 copied from `VitalsBaseline.Config().tempMinorC` /
        /// `.tempSignificantC` (the latter = `SkinTempBaseline.normalDeviationC`).
        public var tempOnsetC: Double = 0.5
        public var tempSaturationC: Double = 1.0

        /// Minimum RING-derived features present before a score exists at all. 🔴 PROVISIONAL.
        public var minRingFeaturesForScore: Int = 4
        /// No single feature may exceed this share of the renormalised pool. 🔴 PROVISIONAL.
        /// Without it, a sparse day of {perimenstrual, scheduleShift, skinTemp, sleepDuration} lets
        /// a CALENDAR LOOKUP supply 43 % of a top-band day with no ring measurement contributing.
        public var maxSingleFeatureShare: Double = 0.35
        /// Iterative cap passes. Three is enough for nine features and bounds the loop.
        public var maxCapPasses: Int = 3

        /// A ring-buffer-truncated night is the most common bad night in this app, and it looks
        /// exactly like a genuinely short, fragmented one. Halve the two features most prone to
        /// that false positive rather than dropping the night. 🔴 PROVISIONAL.
        public var truncatedSleepQuality: Double = 0.5

        /// Banding percentiles over the user's OWN trailing frozen indices. 🔴 PROVISIONAL —
        /// chosen to hit the ~0.8 alerts/week budget, NOT an accuracy target. A fixed score
        /// threshold fires constantly for a noisy person and never for a stable one.
        public var elevatedPercentile: Double = 0.75
        public var flaggedPercentile: Double = 0.90
        /// Below this many prior frozen days there is no band, ever: the 90th percentile of n=21
        /// already interpolates near the 3rd-highest point. 🔴 PROVISIONAL.
        public var minDaysForBanding: Int = 21
        /// Trailing window the percentiles are taken over. 🔴 PROVISIONAL.
        public var bandWindowDays: Int = 60
        /// `.flagged` additionally requires this many features each contributing ≥
        /// `contributingThreshold`. This encodes the thesis as an enforceable invariant: the top
        /// band can NEVER be reached by thresholding one input. 🔴 PROVISIONAL.
        public var minContributingFeatures: Int = 3
        public var contributingThreshold: Double = 0.5

        /// Ring silence that flips the card to `.interrupted` rather than emitting a
        /// normal-looking day. 🟢 24 h is RingConn's own confirmed threshold for the same purpose.
        public var dataGapHours: Double = 24

        public init() {}
    }

    // MARK: - Input

    /// One feature's today-value plus the trailing prior series it is scored against.
    /// `prior` must NOT include today.
    public struct Series: Equatable, Sendable {
        public var today: Double
        public var prior: [Double]
        public init(today: Double, prior: [Double]) {
            self.today = today
            self.prior = prior
        }
    }

    /// Everything one day's assessment needs, as plain values. Deliberately free of SwiftData,
    /// HealthKit and CoreBluetooth types so the whole decision is CLI-testable.
    public struct DayInput: Equatable, Sendable {
        public var day: Date
        public var now: Date
        /// When the ring last delivered anything. `nil` = never.
        public var lastRingDataAt: Date?

        public var restingHR: Series?
        public var hrvSDNN: Series?
        public var sleepEfficiencyPct: Series?
        public var sleepFragmentationMin: Series?
        public var sleepDurationMin: Series?

        /// The CANONICAL skin-temp offset from `SkinTempBaseline` — never re-derived here, so the
        /// nightly temperature story stays single-sourced.
        public var skinTempOffsetC: Double?

        /// In-bed start today and on prior nights, minutes since midnight (wrap-aware).
        public var inBedStartMinutes: Int?
        public var priorInBedStartMinutes: [Int]

        /// Daytime mean HR for D−1 and D−2 plus the series they are scored against, for the
        /// let-down term. Kept as raw inputs so the z-arithmetic stays in this file.
        public var dayHRPrevious: Double?
        public var dayHRTwoDaysAgo: Double?
        public var dayHRPrior: [Double]

        /// `nil` when cycle tracking is off or the user has logged too little to know.
        public var isPerimenstrual: Bool?

        public var sleepLikelyTruncated: Bool
        public var feverSuspected: Bool
        public var headacheAlreadyLoggedToday: Bool

        /// Trailing FROZEN indices, oldest → newest, excluding today.
        public var priorIndices: [Int]

        public init(day: Date,
                    now: Date,
                    lastRingDataAt: Date? = nil,
                    restingHR: Series? = nil,
                    hrvSDNN: Series? = nil,
                    sleepEfficiencyPct: Series? = nil,
                    sleepFragmentationMin: Series? = nil,
                    sleepDurationMin: Series? = nil,
                    skinTempOffsetC: Double? = nil,
                    inBedStartMinutes: Int? = nil,
                    priorInBedStartMinutes: [Int] = [],
                    dayHRPrevious: Double? = nil,
                    dayHRTwoDaysAgo: Double? = nil,
                    dayHRPrior: [Double] = [],
                    isPerimenstrual: Bool? = nil,
                    sleepLikelyTruncated: Bool = false,
                    feverSuspected: Bool = false,
                    headacheAlreadyLoggedToday: Bool = false,
                    priorIndices: [Int] = []) {
            self.day = day
            self.now = now
            self.lastRingDataAt = lastRingDataAt
            self.restingHR = restingHR
            self.hrvSDNN = hrvSDNN
            self.sleepEfficiencyPct = sleepEfficiencyPct
            self.sleepFragmentationMin = sleepFragmentationMin
            self.sleepDurationMin = sleepDurationMin
            self.skinTempOffsetC = skinTempOffsetC
            self.inBedStartMinutes = inBedStartMinutes
            self.priorInBedStartMinutes = priorInBedStartMinutes
            self.dayHRPrevious = dayHRPrevious
            self.dayHRTwoDaysAgo = dayHRTwoDaysAgo
            self.dayHRPrior = dayHRPrior
            self.isPerimenstrual = isPerimenstrual
            self.sleepLikelyTruncated = sleepLikelyTruncated
            self.feverSuspected = feverSuspected
            self.headacheAlreadyLoggedToday = headacheAlreadyLoggedToday
            self.priorIndices = priorIndices
        }
    }

    // MARK: - Output

    public struct Contribution: Equatable, Sendable {
        public let feature: Feature
        /// `nil` when absent — NEVER 0. A missing input is not a normal reading, and collapsing the
        /// two is the single easiest way to fabricate a health value.
        public let z: Double?
        /// 0…1 ramp position. `nil` when absent.
        public let contribution: Double?
        /// Weight actually used after quality multipliers and the single-feature cap.
        public let effectiveWeight: Double
        public let absentReason: AbsentReason?

        public var isPresent: Bool { contribution != nil }
    }

    public struct Assessment: Equatable, Sendable {
        public let day: Date
        /// 0…100, a RELATIVE index on this user's own scale. Not a probability. Not comparable
        /// between people.
        public let index: Int
        public let band: Band
        public let contributions: [Contribution]
        public let ringFeatureCount: Int
        /// Present ring weight / 1.00 — how much of the intended signal we actually measured.
        public let coverageFraction: Double
        public let suppressedBy: Suppression?
    }

    public enum Verdict: Equatable, Sendable {
        case notEnabled
        case buildingBaseline(daysRemaining: Int)
        case interrupted(since: Date?)
        case insufficientData(missing: [Feature: AbsentReason])
        case scored(Assessment)
    }

    // MARK: - Assessment

    /// Assess one day. Gates run in order and each returns early — see docs/HEADACHE_SIGNALS.md §3.9.
    public static func assess(_ input: DayInput, tuning: Tuning = Tuning()) -> Verdict {
        // GATE 1 — ring silence. Say "we stopped looking because you took the ring off" rather than
        // emitting a normal-looking day built from nothing.
        if let last = input.lastRingDataAt {
            if input.now.timeIntervalSince(last) >= tuning.dataGapHours * 3600 {
                return .interrupted(since: last)
            }
        } else {
            return .interrupted(since: nil)
        }

        var contributions: [Contribution] = []
        var absent: [Feature: AbsentReason] = [:]

        func add(_ feature: Feature, z: Double?, reason: AbsentReason? = nil, quality: Double = 1.0) {
            if let z {
                let ramp = rampContribution(feature: feature, z: z, tuning: tuning)
                contributions.append(Contribution(feature: feature, z: z, contribution: ramp,
                                                  effectiveWeight: feature.weight * quality,
                                                  absentReason: nil))
            } else {
                let r = reason ?? .noDataThisDay
                absent[feature] = r
                contributions.append(Contribution(feature: feature, z: nil, contribution: nil,
                                                  effectiveWeight: 0, absentReason: r))
            }
        }

        // Unsigned |z| features driven by a trailing series.
        func seriesZ(_ series: Series?, _ feature: Feature) -> (Double?, AbsentReason?) {
            guard let series else { return (nil, .noDataThisDay) }
            guard let stats = RobustBaseline.stats(series.prior) else { return (nil, .noBaseline) }
            return (abs(RobustBaseline.z(today: series.today, stats: stats,
                                         noiseFloor: feature.noiseFloor)), nil)
        }

        let (effZ, effReason) = seriesZ(input.sleepEfficiencyPct, .sleepEfficiencyDrop)
        add(.sleepEfficiencyDrop, z: effZ, reason: effReason)

        let (hrvZ, hrvReason) = seriesZ(input.hrvSDNN, .hrvDeviation)
        add(.hrvDeviation, z: hrvZ, reason: hrvReason)

        let (rhrZ, rhrReason) = seriesZ(input.restingHR, .restingHRDeviation)
        add(.restingHRDeviation, z: rhrZ, reason: rhrReason)

        // Sleep duration + fragmentation carry the truncation quality multiplier: a night cut short
        // by the ring's buffer looks identical to a genuinely short, broken one.
        let sleepQuality = input.sleepLikelyTruncated ? tuning.truncatedSleepQuality : 1.0
        let (fragZ, fragReason) = seriesZ(input.sleepFragmentationMin, .sleepFragmentation)
        add(.sleepFragmentation, z: fragZ, reason: fragReason, quality: sleepQuality)

        let (durZ, durReason) = seriesZ(input.sleepDurationMin, .sleepDurationDeviation)
        add(.sleepDurationDeviation, z: durZ, reason: durReason, quality: sleepQuality)

        // Skin temp: ramps in °C off the CANONICAL offset, not a re-derived z.
        if let offset = input.skinTempOffsetC {
            contributions.append(Contribution(
                feature: .skinTempDeviation, z: offset,
                contribution: clamp01((abs(offset) - tuning.tempOnsetC)
                                      / max(tuning.tempSaturationC - tuning.tempOnsetC, .leastNormalMagnitude)),
                effectiveWeight: Feature.skinTempDeviation.weight, absentReason: nil))
        } else {
            absent[.skinTempDeviation] = .noDataThisDay
            contributions.append(Contribution(feature: .skinTempDeviation, z: nil, contribution: nil,
                                              effectiveWeight: 0, absentReason: .noDataThisDay))
        }

        // Schedule shift: circular, so a 23:50-vs-00:10 sleeper is regular, not maximally irregular.
        if let todayStart = input.inBedStartMinutes,
           let habitual = RobustBaseline.circularMedianMinutes(input.priorInBedStartMinutes),
           input.priorInBedStartMinutes.count >= RobustBaseline.minBaselineDays {
            let deltaMin = Double(RobustBaseline.circularDeltaMinutes(todayStart, habitual))
            let floor = Feature.scheduleShift.noiseFloor
            add(.scheduleShift, z: deltaMin / max(floor, .leastNormalMagnitude))
        } else {
            add(.scheduleShift, z: nil,
                reason: input.inBedStartMinutes == nil ? .noDataThisDay : .noBaseline)
        }

        // Let-down: SIGNED. A FALL in arousal from D−2 to D−1 is the risk direction (Lipton 2014),
        // so a RISE contributes nothing rather than being folded back in by abs().
        if let prev = input.dayHRPrevious, let prev2 = input.dayHRTwoDaysAgo,
           let stats = RobustBaseline.stats(input.dayHRPrior) {
            let z1 = RobustBaseline.z(today: prev, stats: stats,
                                      noiseFloor: Feature.restingHRDeviation.noiseFloor)
            let z2 = RobustBaseline.z(today: prev2, stats: stats,
                                      noiseFloor: Feature.restingHRDeviation.noiseFloor)
            add(.arousalLetdown, z: max(0, z2 - z1))   // positive = arousal fell
        } else {
            // Name the real cause. A short-but-non-empty prior series is a BASELINE problem ("we
            // don't know your usual daytime heart rate yet"), not a data problem ("the ring gave us
            // nothing"). Reporting the latter for the former told a first-week user their ring was
            // failing, and it also starved gate 2's cold-start detection, which counts exactly the
            // ring features absent for `.noBaseline`.
            let hasBaseline = RobustBaseline.stats(input.dayHRPrior) != nil
            add(.arousalLetdown, z: nil, reason: hasBaseline ? .noDataThisDay : .noBaseline)
        }

        // Cycle phase: binary, and ring-fenced by both guards below.
        if let peri = input.isPerimenstrual {
            contributions.append(Contribution(feature: .perimenstrual, z: peri ? 1 : 0,
                                              contribution: peri ? 1 : 0,
                                              effectiveWeight: Feature.perimenstrual.weight,
                                              absentReason: nil))
        } else {
            contributions.append(Contribution(feature: .perimenstrual, z: nil, contribution: nil,
                                              effectiveWeight: 0, absentReason: .notApplicable))
        }

        // GATE 2 — cold start. Distinguish "we do not know you yet" (a first-week user, who should
        // be told we are learning) from "the ring gave us nothing" (a data failure). Those need
        // different words, and getting it wrong tells a brand-new user their ring is broken.
        //
        // The test is whether the MISSING BASELINES alone would have carried us to the minimum. It
        // deliberately is NOT "every absent reason is .noBaseline": skin temperature has no
        // baseline of its own (it consumes `SkinTempBaseline`'s canonical offset), so a nil offset
        // records `.noDataThisDay` while a non-nil one makes the feature PRESENT. Those two
        // conditions are mutually exclusive by construction, which made the original formulation
        // unreachable — `.buildingBaseline` could never be returned at all.
        let ringPresent = contributions.filter { $0.isPresent && $0.feature.isRingDerived }
        let noBaselineRing = absent.filter { $0.key.isRingDerived && $0.value == .noBaseline }.count
        if ringPresent.count < tuning.minRingFeaturesForScore,
           noBaselineRing >= tuning.minRingFeaturesForScore - ringPresent.count {
            let priorDays = maxPriorDays(input)
            return .buildingBaseline(
                daysRemaining: max(0, RobustBaseline.minBaselineDays - priorDays))
        }

        // GATE 3 — coverage. `perimenstrual` is EXCLUDED from this count: a calendar lookup is not
        // a measurement, and letting it satisfy the minimum would allow a scored day on which the
        // ring measured almost nothing.
        guard ringPresent.count >= tuning.minRingFeaturesForScore else {
            return .insufficientData(missing: absent)
        }

        // GATE 4 — anchor. Context alone (cycle + schedule + temperature) never synthesises a verdict.
        guard ringPresent.contains(where: { Feature.anchors.contains($0.feature) }) else {
            return .insufficientData(missing: absent)
        }

        // Weight capping, then renormalisation over PRESENT features only.
        let capped = applySingleFeatureCap(contributions, tuning: tuning)
        let totalWeight = capped.reduce(0.0) { $0 + $1.effectiveWeight }
        guard totalWeight > 0 else { return .insufficientData(missing: absent) }
        let weighted = capped.reduce(0.0) { $0 + $1.effectiveWeight * ($1.contribution ?? 0) }
        let index = Int((100 * weighted / totalWeight).rounded())

        let ringWeightPresent = capped.filter { $0.isPresent && $0.feature.isRingDerived }
            .reduce(0.0) { $0 + $1.feature.weight }
        let band = self.band(index: index, priorIndices: input.priorIndices,
                             contributions: capped, tuning: tuning)

        // GATE 5/6 — suppression. The score is still computed and SHOWN; only the notification
        // candidate is withheld. Fever wins because HRV↓ + RHR↑ + temp↑ IS the fever signature and
        // the existing fever alert is the more actionable one — two interrupts for one
        // physiological event devalues both.
        let suppression: Suppression? = input.feverSuspected ? .fever
            : (input.headacheAlreadyLoggedToday ? .headacheAlreadyLogged : nil)

        return .scored(Assessment(
            day: input.day, index: index, band: band, contributions: capped,
            ringFeatureCount: ringPresent.count,
            coverageFraction: min(1, ringWeightPresent),
            suppressedBy: suppression))
    }

    /// Band today's index against the user's OWN trailing frozen indices — a false-alarm BUDGET,
    /// not an accuracy threshold.
    public static func band(index: Int,
                            priorIndices: [Int],
                            contributions: [Contribution] = [],
                            tuning: Tuning = Tuning()) -> Band {
        let window = priorIndices.count > tuning.bandWindowDays
            ? Array(priorIndices.suffix(tuning.bandWindowDays)) : priorIndices
        guard window.count >= tuning.minDaysForBanding else { return .typical }

        // A percentile budget has NO FLOOR, and that is a real problem for the people it is meant to
        // protect. For a very stable user whose trailing indices are mostly 0, an index of 0 sits at
        // or above p75 — so a night on which literally nothing deviated would band `.elevated` and
        // the card would say "last night was unusual for you". That is simply false, and it is the
        // exact failure the percentile design exists to avoid (bounded annoyance regardless of how
        // quiet a person's physiology is).
        //
        // The floor lives HERE rather than in view copy so the FROZEN band is right too: a band
        // corrected only at render time would still be wrong in the stored row, in the Diagnostics
        // export, and in every Phase-3 statistic computed off it.
        guard index > 0 else { return .typical }
        if !contributions.isEmpty,
           !contributions.contains(where: { ($0.contribution ?? 0) > 0 }) { return .typical }
        let sorted = window.map(Double.init).sorted()
        let value = Double(index)
        if value >= percentile(sorted, tuning.flaggedPercentile) {
            // The top band can never be reached by thresholding ONE input.
            let contributing = contributions.filter {
                ($0.contribution ?? 0) >= tuning.contributingThreshold
            }.count
            if contributions.isEmpty || contributing >= tuning.minContributingFeatures {
                return .flagged
            }
            return .elevated
        }
        if value >= percentile(sorted, tuning.elevatedPercentile) { return .elevated }
        return .typical
    }

    // MARK: - Internals

    /// How many prior nights we actually hold, for the cold-start "n more nights" message.
    ///
    /// The LONGEST series wins: reporting the shortest would pin the count at 0 forever for a user
    /// whose skin-temp capture is patchy but whose sleep history is fine, and tell them on night 30
    /// that they still have 7 nights to go. Note it cannot be derived from `priorIndices` — those
    /// only start accumulating once a day actually scores, which is the very thing being gated.
    static func maxPriorDays(_ input: DayInput) -> Int {
        var counts = [
            input.restingHR?.prior.count ?? 0,
            input.hrvSDNN?.prior.count ?? 0,
            input.sleepEfficiencyPct?.prior.count ?? 0,
            input.sleepFragmentationMin?.prior.count ?? 0,
            input.sleepDurationMin?.prior.count ?? 0,
        ]
        counts.append(input.priorInBedStartMinutes.count)
        return counts.max() ?? 0
    }

    static func rampContribution(feature: Feature, z: Double, tuning: Tuning) -> Double {
        let span = max(tuning.saturationZ - tuning.onsetZ, .leastNormalMagnitude)
        return clamp01((abs(z) - tuning.onsetZ) / span)
    }

    /// No single feature may exceed `maxSingleFeatureShare` of the renormalised pool. Iterative,
    /// because scaling one weight down changes every other share.
    static func applySingleFeatureCap(_ contributions: [Contribution],
                                      tuning: Tuning) -> [Contribution] {
        var out = contributions
        for _ in 0..<tuning.maxCapPasses {
            let total = out.reduce(0.0) { $0 + $1.effectiveWeight }
            guard total > 0 else { return out }
            guard let idx = out.indices.max(by: { out[$0].effectiveWeight < out[$1].effectiveWeight }),
                  out[idx].effectiveWeight / total > tuning.maxSingleFeatureShare else { return out }
            // Solve w' / (total - w + w') = share  ⇒  w' = share·(total - w) / (1 - share)
            let others = total - out[idx].effectiveWeight
            let share = tuning.maxSingleFeatureShare
            let capped = share * others / max(1 - share, .leastNormalMagnitude)
            let c = out[idx]
            out[idx] = Contribution(feature: c.feature, z: c.z, contribution: c.contribution,
                                    effectiveWeight: capped, absentReason: c.absentReason)
        }
        return out
    }

    /// Linear-interpolated percentile over a SORTED array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .infinity }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (rank - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
}
