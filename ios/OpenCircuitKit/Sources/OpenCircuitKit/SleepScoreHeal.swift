// Repair for the build-47/48 "correcting a night deleted my score" scar.
//
// THE DEFECT. Builds 47 and 48 zeroed `sleepScore` whenever the night's provenance breakdown was
// not `isScorable` (coverage under `SleepProvenanceBreakdown.minCoverageForScore`). It was meant as
// honesty; the wearer read it as data loss, because `0` is this column's app-wide "never computed"
// SENTINEL — the Sleep card hides the badge on `score > 0`, Trends filters it out, and Readiness
// drops for the whole day. Worse, the rule had exactly ONE production consumer and it was that
// line, so it could only ever fire on a wearer's own CORRECTION: a badly-measured night the app got
// wrong on its own kept a confident score.
//
// Build 49 removed the rule (`LocalStore.applySleepEdit`) but deliberately did NOT heal rows already
// written — `rederiveEditedNightProvenance` leaves `sleepScore` as saved, and nothing else in the
// app re-scores a stored night. So a wearer who corrected a night on b47/b48 upgrades to b49 and
// STILL sees no Sleep-Score badge and no Readiness for that day, with no action available that
// changes it except editing the night a second time. This type is the one-shot repair.
//
// ⚠️ IT RECOMPUTES FROM THE STORED HYPNOGRAM, NEVER FROM THE ROW'S ROUNDED MINUTES, and that is the
// whole reason it lives here rather than as three lines in `LocalStore`. `applySleepEdit` built the
// score from a second-precision `SleepStaging.Summary`; `row.asleepMin` and friends are that summary
// put through `Int((t / 60).rounded())`. Rebuilding from the minutes would hand `SleepScore` a
// different input than the one the number was originally built from and move it by a point or two
// for no reason the wearer could ever see. The hypnogram is second-precision and is what the summary
// was derived from, so it reconstructs the original input exactly.
//
// ⚠️ THE BASIS IS DISPLAY, NOT MEASURED — assertion-INCLUSIVE, matching clause 1 of the provenance
// rule and matching every other number on the row (`asleepMin`, `efficiency`). This function must
// NOT filter to `measuredOnly`: doing so would recompute a *different, lower* score than the one
// build 46 would have stored for the same night, which is a silent restatement of the wearer's
// night rather than a repair of a missing value. The honesty signals stay where they are
// (`sleepBasis`, `measuredEfficiency`, `coverageFraction`, the card's caveat line).

import Foundation

public enum SleepScoreHeal {

    /// Rebuild the second-precision `SleepStaging.Summary` a stored hypnogram was scored from.
    ///
    /// Mirrors `SleepStaging.Summary` exactly: `inBed` is the sum of the `.inBed` layer (data gaps
    /// are not in-bed and therefore contribute nothing), `light`/`deep`/`rem` are the three asleep
    /// stages, and `totalAsleep` / `efficiency` fall out of the type's own accessors. Every segment
    /// counts whatever its provenance, per clause 1.
    ///
    /// Returns nil when the segments cannot describe a night — no `.inBed` span, or no asleep time
    /// at all. Both make `efficiency` meaningless (`SleepStaging.Summary.efficiency` returns 0 on a
    /// zero in-bed) and would score a night we cannot actually describe.
    public static func summary(from segments: [SleepSegment]) -> SleepStaging.Summary? {
        guard !segments.isEmpty else { return nil }
        // One pass, explicit accumulators: a per-stage `filter`/`reduce` chain here is what the
        // Swift type-checker chokes on ("unable to type-check in reasonable time").
        var inBed: TimeInterval = 0, awake: TimeInterval = 0
        var light: TimeInterval = 0, deep: TimeInterval = 0, rem: TimeInterval = 0
        for segment in segments {
            let d = segment.duration
            switch segment.stage {
            case .inBed: inBed += d
            case .awake: awake += d
            case .asleepCore: light += d
            case .asleepDeep: deep += d
            case .asleepREM: rem += d
            }
        }
        guard inBed > 0, light + deep + rem > 0 else { return nil }
        return SleepStaging.Summary(inBed: inBed, awake: awake,
                                    light: light, deep: deep, rem: rem)
    }

    /// The score a scarred row should be repaired to, or nil when it must be left alone.
    ///
    /// `SleepScore.composite` is called with exactly the argument list `LocalStore.applySleepEdit`
    /// uses, so a healed row and a freshly-edited one agree by construction. `restingHR` and
    /// `tempOffsetC` are omitted for the same reason they are omitted there: the edit path does not
    /// have them either, and `SleepScore` renormalises over the factors it was given rather than
    /// fabricating the missing ones.
    ///
    /// Returns nil — leave the row untouched — when the summary cannot be rebuilt, or when the
    /// recomputed score is itself 0. A 0 result would write the sentinel back and achieve nothing,
    /// and it is the one case where "repaired" and "still broken" are indistinguishable afterwards.
    public static func healedScore(hypnogram segments: [SleepSegment]) -> Int? {
        guard let s = summary(from: segments) else { return nil }
        let score = SleepScore.composite(.init(
            totalAsleep: s.totalAsleep, timeAwake: s.awake,
            efficiency: s.efficiency,
            deep: s.deep, light: s.light, rem: s.rem)).score
        return score > 0 ? score : nil
    }

    // NOTE ON THE ROW PREDICATE. "Is this row a scar?" is `isManuallyEdited && sleepScore == 0 &&
    // sleepBasis != .unknown`, and it lives in `LocalStore.healWithheldSleepScores` rather than
    // here: `SleepBasis` is an app-target enum and the Kit must not grow a second copy that could
    // drift. Three properties of it are worth recording where the recompute lives:
    //
    //  • ⚠️ THE BASIS CLAUSE IS `!= .unknown`, NOT `== .assertedTagged`. An earlier draft used the
    //    latter on the reasoning that the withhold "could only fire on a night carrying asserted
    //    time". THAT REASONING IS WRONG: the withhold's own predicate was `isScorable == false`,
    //    which is COVERAGE-based and never consulted the basis. A scarred row can be stamped
    //    `.measuredOnly` two ways — an edit over UNKNOWN ground (`.assertedCoverageUnknown` is not
    //    counted by `hasAssertedTime`), and `rederiveEditedNightProvenance` upgrading every
    //    `.asserted` span to `.assertedOverMeasured` as the archive grows. The narrow clause left
    //    both permanently unhealed.
    //
    //  • ⚠️ It must NOT be gated on `isScorable == false` either. Coverage MOVES for the same
    //    reason, so re-testing the withhold's own predicate today would strand exactly the rows
    //    that healed themselves in every other respect.
    //
    //  • Legacy `.unknown` rows stay OUT on purpose: their split is genuinely unrecoverable, and
    //    `backfillSleepProvenance` explicitly refuses to invent one for an edited row.
}
