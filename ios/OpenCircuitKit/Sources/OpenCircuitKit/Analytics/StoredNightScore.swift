// Score a night that is already STORED, from the rows the app holds for it — #246, decision 48.
//
// WHY THIS EXISTS. The ring scores a night as it persists it (`RingSession.computeSleepExtras`),
// straight off the `BulkRecord`s it just drained. Nothing else in the app could ever reproduce that
// number, so a night stored by any OTHER path — the Helio Strap's, whose records are parsed records
// and not `BulkRecord`s at all — kept `sleepScore == 0`, which is this column's app-wide "never
// computed" sentinel. Readiness is anchored on last night's Sleep Score
// (`WellnessBalance.anchoredScore` returns nil without one), so a strap wearer's Readiness card was
// permanently empty while every input for the score sat in the store.
//
// So this is the SAME formula, expressed over stored-row inputs instead of ring epochs:
//   • `SleepScore.composite` over the night's segments (`SleepStaging.summary`),
//   • `RestingHR.value` for the HR factor,
//   • the skin-temp offset against the SAME DEVICE's prior nights (`SkinTempBaseline.baseline`),
//   • `SleepStress.overnightScore` over the night's RMSSD for overnight recovery.
//
// ⚠️ IT TAKES VALUES, NOT A DEVICE, AND IT KNOWS NOTHING ABOUT ANY PROTOCOL. Which rows belong to
// the night, and which device measured them, is the store's job (decisions 28 and 29) — see
// `LocalStore+HelioNightScore.swift`. Keeping that out of here is what lets the same function serve
// both the store-time path and the repair pass, so a night scored at sync time and the same night
// scored later from its stored hypnogram cannot disagree.
//
// ⚠️ THE HRV STATISTIC IS 🟡. The strap's HRV is taken as RMSSD on Amazfit's product-line
// documentation (decision 44); no capture has compared the byte with the vendor app's number. So
// `stressScore` — overnight recovery — rests on an unconfirmed statistic wherever a strap feeds it.
// `SleepStress` wants RMSSD and that is what it is given; if the statistic turns out to be SDNN the
// mapping is wrong, and the fix belongs at the one place the value is read, not here.
//
// ⚠️ `nil` MEANS "NO SCORE", AND A COMPUTED 0 IS `nil`. `StoredSleepSummary.sleepScore` and
// `stressScore` use 0 as "not computed" (the Sleep card hides the badge, Trends filters it out,
// Readiness drops for the day), so a genuine 0 and a missing value are indistinguishable once
// stored. Reporting a computed 0 as a score would write the sentinel back and claim a repair that
// changed nothing — the same trap `SleepScoreHeal.healedScore` refuses.

import Foundation

public enum StoredNightScore {

    /// Everything the composite needs for ONE stored night. Every field is already-stored data: no
    /// device, no timeline, no raw records.
    public struct Input: Equatable, Sendable {
        /// The night's staged segments (the stored hypnogram, or the staging about to be stored).
        public var segments: [SleepSegment]
        /// The night's heart-rate readings, for the HR factor and the resting-HR estimate.
        public var heartRate: [HRSample]
        /// The night's RMSSD values in ms (🟡 for a strap — see the file header).
        public var rmssd: [Int]
        /// The night's own mean sleeping skin temperature in °C, nil (or ≤ 0) when none was judged.
        public var skinTempC: Double?
        /// PRIOR nights' means from the SAME DEVICE (decision 29), excluding this night.
        public var priorNights: [SkinTempBaseline.NightlyTemp]

        public init(segments: [SleepSegment], heartRate: [HRSample] = [], rmssd: [Int] = [],
                    skinTempC: Double? = nil, priorNights: [SkinTempBaseline.NightlyTemp] = []) {
            self.segments = segments
            self.heartRate = heartRate
            self.rmssd = rmssd
            self.skinTempC = skinTempC
            self.priorNights = priorNights
        }
    }

    /// What the night scores. `nil` is "no score" in every field — never 0 (see the file header).
    public struct Scores: Equatable, Sendable {
        /// Composite 0–100 Sleep Score, nil when the night can't be described or scored 0.
        public let sleepScore: Int?
        /// Overnight stress 1–100 (overnight recovery is its inverse), nil with no usable HRV.
        public let stressScore: Int?
        /// The resting/asleep HR the composite's HR factor was given, nil when no HR was usable.
        public let restingHR: Double?
        /// The skin-temp offset the composite's temperature factor was given, nil without BOTH a
        /// nightly mean and a same-device baseline.
        public let tempOffsetC: Double?
        /// The factors behind `sleepScore`, from the same composite call; nil exactly when
        /// `sleepScore` is nil. The caller saves it with the score (`SleepScoreFactors`).
        public let factors: SleepScoreFactors?

        public init(sleepScore: Int?, stressScore: Int?, restingHR: Double?, tempOffsetC: Double?,
                    factors: SleepScoreFactors? = nil) {
            self.sleepScore = sleepScore
            self.stressScore = stressScore
            self.restingHR = restingHR
            self.tempOffsetC = tempOffsetC
            self.factors = factors
        }
    }

    /// Score one stored night. Pure.
    ///
    /// The composite's optional factors are passed as-is: `SleepScore.composite` renormalises over
    /// the factors it was given rather than inventing a resting HR or a temperature offset, so a
    /// night with no baseline yet scores on the factors it does have (and "Learning your usual",
    /// decision 29, is the honest answer for the tile).
    public static func scores(_ input: Input) -> Scores {
        // The night's RMSSD → overnight stress. Independent of whether the night is scorable at all:
        // an unscorable night with HRV still has a recovery number, and the caller stores each
        // column on its own.
        let stressScore = SleepStress.overnightScore(rmssd: input.rmssd)
        let restingHR = RestingHR.value(hr: input.heartRate, sleep: input.segments)
        // Decision 29: the baseline is the same device's own prior nights, and it is the CALLER that
        // guarantees that. `SkinTempBaseline.baseline` returns nil under `minBaselineNights`, which
        // is exactly the "no usual yet" case, so the offset then drops out of the composite.
        let baseline = SkinTempBaseline.baseline(priorNights: input.priorNights)
        let tempOffsetC: Double? = {
            guard let nightly = input.skinTempC, nightly > 0, let baseline else { return nil }
            return nightly - baseline
        }()

        let summary = SleepStaging.summary(input.segments)
        // ⚠️ NOT SCORABLE IS NOT A SCORE OF 0. With no asleep time `efficiency` is 0 and the stage
        // factor is 0, but `timeAwake` can still be full marks — so the composite would hand back a
        // confident-looking number for a night we cannot describe as sleep at all. Same guard as
        // `SleepScoreHeal.summary`'s `light + deep + rem > 0`.
        guard !input.segments.isEmpty, summary.totalAsleep > 0, summary.inBed > 0 else {
            return Scores(sleepScore: nil, stressScore: stressScore,
                          restingHR: restingHR, tempOffsetC: tempOffsetC)
        }
        // EXACTLY the ring's argument list (`RingSession.computeSleepExtras`), including its default
        // `sleepGoal`: the two paths must produce the same number for the same night, so neither may
        // grow an argument the other doesn't pass.
        let scored = SleepScoreFactors.scored(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem,
            restingHR: restingHR, tempOffsetC: tempOffsetC), producer: .strap)
        return Scores(sleepScore: scored.score > 0 ? scored.score : nil,
                      stressScore: stressScore, restingHR: restingHR, tempOffsetC: tempOffsetC,
                      factors: scored.score > 0 ? scored : nil)
    }
}
