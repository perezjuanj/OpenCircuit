// Did we WATCH the user wake up, or is the "wake" we print just where the data STOPS?
//
// This is the trailing-edge mirror of `BedtimeProvenance` (#198), and it exists because the corpus
// says the back edge is where the damage is. Measured over the 21 staged nights of the sleep corpus
// on master `f042639`:
//
//   • the detected in-bed END sits within ONE 150 s epoch of a real record on 21 of 21 nights
//     (max 145 s) — memory `sleep-wake-is-sync-timestamp` (#190) reproduced across five rings. So
//     "the night ends at a data edge" is TRUE EVERYWHERE and has ZERO discriminating power: scored
//     as a rule it also fires on `R3_2026-08-15`, the most accurate night in the corpus (worst edge
//     error 8 min). A flag on a night we get right is worse than no flag.
//   • what DOES discriminate is whether the stream RESUMES afterwards. Partitioning the same 21
//     nights on what follows the in-bed end: 10 have a record within 300 s (the wake was a decision
//     the stager made while data kept arriving), 5 stop and resume after 7.5 / 33.0 / 241.9 / 243.2 /
//     243.6 min (a PROVABLE data edge), and 6 have nothing within 12 h (unprovable — "the ring
//     stopped" and "you synced at wake" are the same picture).
//   • both 246-minute errors in the corpus (`R2_2026-08-17`, `R2_2026-08-18`) are in that middle
//     group, and both are invisible to everything already shipped: their ~4 h hole begins exactly AT
//     the in-bed end (02:39:14 / 02:37:02), so it is never INSIDE the window that an internal-hole or
//     coverage-fraction test could see. Coverage inside the detected window measures 0.976–1.049 on
//     21 of 21 — vacuous by construction, because the detected window is DEFINED by the records.
//
// ⚠️ IT DELIBERATELY DOES NOT NAME A CAUSE — same bar as `BedtimeProvenance`. A stopped ring, a dead
// battery, a contended resume pointer (#188) and the user taking the ring off are indistinguishable
// from the persisted record stream. It reports THAT the stream was absent and for how long.
//
// ⚠️ IT DOES NOT ESTIMATE THE MISSING SLEEP. On the two back-edge corpus nights the hole happens to
// match the error to within 2.4 and 4.1 min because both testers slept through the whole hole; on
// the front-edge night `R1_2026-08-16` a 241.3 min hole sits against a 120.0 min error because she
// went to bed INSIDE it. The gap BOUNDS the error, it does not estimate it (n = 3). Copy must state
// the measured gap and never an inferred sleep total.
//
// Pure (no Apple frameworks) so it unit-tests on the CLI.

import Foundation

public enum WakeProvenance: Equatable, Sendable {

    /// What the record stream says about the moment the night's in-bed window CLOSES.
    public enum Verdict: Equatable, Sendable {
        /// The stream runs CONTINUOUSLY past the detected wake — the ring was still measuring, so
        /// the edge is a decision the stager made, not the end of the data.
        case witnessed
        /// The stream STOPS at the detected wake and only resumes later. The associated value is how
        /// long the ring recorded nothing afterwards. Sleep may have continued anywhere in that gap.
        case stoppedThenResumed(TimeInterval)
        /// There is no measurement after the detected wake at all, so we cannot tell "the ring
        /// stopped recording" from "you synced the moment you woke up and nothing has arrived since".
        /// Distinct from `witnessed` on purpose: "we did not look" must never read as "we watched".
        case unknown
    }

    /// How close the next measurement must sit to the wake for the stream to count as CONTINUOUS.
    ///
    /// Deliberately the SAME constant as the leading edge — one 0x4c cadence is 150 s, two absorb a
    /// single dropped or unparsed epoch, and a front/back asymmetry here would be unexplainable to
    /// anyone reading the two hints side by side. Aliased rather than redeclared so it cannot drift.
    public static var continuousToleranceSeconds: TimeInterval {
        BedtimeProvenance.continuousToleranceSeconds
    }

    /// How long the stream must be absent before the gap is worth telling the USER about.
    ///
    /// ⚠️ THIS NUMBER IS NOT FITTED, AND THE COMMENT SAYING SO IS PART OF THE NUMBER. On the corpus
    /// the sorted gaps after the in-bed end are, in minutes:
    ///
    ///     0.1 · 1.0 · 1.0 · 1.0 · 1.0 · 1.5 · 1.5 · 2.0 · 2.5 · 2.5 · 7.5 · 33.0 · 241.9 · 243.2 · 243.6
    ///
    /// The distribution is BIMODAL with an EMPTY interval from 33.0 to 241.9 min, so EVERY cut in
    /// (33.0, 241.9] scores identically on the evidence we have. 60 min was chosen for a ~1.8×
    /// margin over the largest gap the corpus cannot adjudicate (33.0 min, `R5_2026-08-11`, Gen 3,
    /// unlabelled) — which is a choice made on n = 1, not a fit. Below 33 min it also flags that Gen
    /// 3 night; below 7.5 min it also flags `R2_2026-08-02`. There is no labelled evidence to choose
    /// among any of them.
    ///
    /// Callers pass it explicitly (`SleepConfidence.assess(…, materialGapSeconds:)`) so a sweep is a
    /// one-line change: `0` makes every non-witnessed edge material (maximally loud) and
    /// `.infinity` is the kill switch — no acquisition reason is ever emitted.
    public static let materialGapSeconds: TimeInterval = 60 * 60

    /// Classify the trailing edge of a night's in-bed window.
    ///
    /// - Parameters:
    ///   - inBedEnd: the detected closing edge of the night.
    ///   - firstMeasurementAfter: timestamp of the oldest wrist measurement strictly AFTER
    ///     `inBedEnd`, or nil if there is none. Callers should pass a HEART-RATE observation for the
    ///     same reason `BedtimeProvenance` does: HR is band-guarded to 30…220 bpm, so a charging or
    ///     pocketed ring produces none, while a skin-temp row keeps arriving from a docked ring and
    ///     would call a charge cycle "witnessed".
    /// - Returns: `.unknown` when there is no later measurement — the honest answer, because the
    ///   store having nothing after the edge is exactly as consistent with "you synced at wake" as
    ///   with "the ring stopped". This branch has ZERO labelled validation (6 of 21 corpus nights
    ///   land there and the corpus cannot adjudicate one of them), so it must stay SILENT in the UI.
    ///
    /// ⚠️ THE INPUT IS OUR ARCHIVE, WHICH LAGS THE RING. Records exist on the ring before any drain
    /// hands them over, so a morning where the app has only reached 02:37 looks identical to a ring
    /// that stopped there. The saving grace is the shape of that error: an incomplete drain produces
    /// NO later measurement, which lands on `.unknown` and says nothing, and the verdict is recomputed
    /// from disk on every render (`SleepCardView.refreshBedtimeProvenance` does this for the leading
    /// edge already), so it corrects itself as the drain catches up. The residual hazard is
    /// OUT-OF-ORDER ingestion — a later page landing before an earlier one would manufacture a gap
    /// that never existed. `ack-implies-retain` (#188) and `in-drain-page-volatility` say that is not
    /// hypothetical, which is the other reason the copy must describe OUR data and never the device.
    ///
    /// There is deliberately NO `noSubsequentMeasurement` counterpart to `BedtimeProvenance`'s
    /// `.noPriorMeasurement`. That case needs "nothing before the edge, yet retention reaches well
    /// before it" — two conditions that cannot both hold when both inputs are read from the same
    /// single-kind store, which is why it is unreachable from `SleepCardView`'s real caller today
    /// (`BedtimeProvenanceTests.testNoPriorMeasurementWithDeepRetentionIsEvidence` only reaches it by
    /// passing a `nil` predecessor alongside a 7-day-old "earliest"). Mirroring a dead branch would
    /// mean shipping copy that can never render.
    public static func classify(inBedEnd: Date, firstMeasurementAfter: Date?) -> Verdict {
        guard let next = firstMeasurementAfter else { return .unknown }
        // A measurement at or before the edge is not "after" it; treat a caller that passes one as
        // giving no usable evidence rather than silently computing a negative gap. (Mirrors
        // BedtimeProvenance's caller hazard, which the corpus harness trips constantly: the newest
        // record INSIDE the window is always ≤ inBedEnd.)
        guard next > inBedEnd else { return .unknown }
        let gap = next.timeIntervalSince(inBedEnd)
        return gap <= continuousToleranceSeconds ? .witnessed : .stoppedThenResumed(gap)
    }

    /// Whether a verdict is worth putting in front of the user.
    ///
    /// Only `.stoppedThenResumed` beyond `threshold` qualifies. `.witnessed` has nothing to report
    /// and `.unknown` has nothing it can support — see the note on `classify`.
    public static func isMaterial(_ verdict: Verdict,
                                  threshold: TimeInterval = materialGapSeconds) -> Bool {
        guard case .stoppedThenResumed(let gap) = verdict else { return false }
        return gap > threshold
    }
}
