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
//     the stager made while data kept arriving), 4 stop and resume after 7.5 / 33.0 / 241.9 /
//     243.6 min (a PROVABLE data edge), and 7 have nothing usable within 12 h (unprovable — "the
//     ring stopped" and "you synced at wake" are the same picture).
//     ⚠️ THAT PARTITION WAS 10 / 5 / 6 UNTIL 2026-08-20, and the fifth "resume" was not one:
//     `R3_2026-08-04`'s next record sits 243.2 min later in a DIFFERENT capture artifact
//     (`R3_2026-08-05.b64`), so it measured the owner's export schedule, not the ring. Corpus
//     evidence now has to be bracketed inside ONE artifact; see the header of
//     `SleepCoverageMeasureTests`, which prints this partition rather than asking you to trust it.
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
    /// the sorted gaps after the in-bed end are, in minutes (n = 14; printed as TABLE 0 by
    /// `SleepCoverageMeasureTests`, re-copy from there rather than editing by hand):
    ///
    ///     0.1 · 1.0 · 1.0 · 1.0 · 1.0 · 1.5 · 1.5 · 2.0 · 2.5 · 2.5 · 7.5 · 33.0 · 241.9 · 243.6
    ///
    /// (A 15th value, 243.2, was listed here until 2026-08-20 and was never a measured gap:
    /// `R3_2026-08-04`'s next record is in another capture artifact. It is withheld now, and its
    /// removal changes nothing else — the firing set stays 5 / 21 because that night still fires
    /// legitimately on its FRONT edge.)
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

    /// How far past the in-bed end a material hole may BEGIN and still be part of this night.
    ///
    /// ⚠️ THIS EXISTS BECAUSE THE ONE-RECORD LOOKAHEAD BELOW IS DEFEATABLE BY A SINGLE EPOCH, and
    /// that is not hypothetical — it is the tester night that prompted it. `40CFFE2E` (Gen 2 Air,
    /// FR04.009), night 2026-09-01, read out of her own diagnostics export: in-bed end 01:32:21Z,
    /// the epoch archive's LAST record at 01:32:51Z (**30 s** — well inside
    /// `continuousToleranceSeconds`), then NOTHING for 14549.95 s until a live heart rate at
    /// 05:35:20Z. She got up at 07:30 local. The two-argument `classify` answers `.witnessed` on
    /// that night: the most reassuring verdict this type can give, on a night missing four hours,
    /// and her export carries it as `wakeVerdict: "witnessed"`.
    ///
    /// ⚠️ NOTE WHERE THE DEFEATING RECORD CAME FROM — `ExportCoverageWitness`'s archive union,
    /// whose whole purpose is to make reported gaps SHRINK because a store-only probe over-reports
    /// them (#198). It is monotone for the single INSTANTS it picks — NOT for the series, see
    /// `ExportCoverageWitness.Edges.measurementsAfterEnd` — and it is right to keep, but it means
    /// the single-step rule can be
    /// defeated by the one epoch the union exists to contribute. The walk is what makes the union
    /// safe: filling a gap can no longer end the enquiry.
    ///
    /// The corpus's own two 246-minute nights
    /// (`R2_2026-08-17`, `R2_2026-08-18`) are caught only because their holes begin EXACTLY at the
    /// in-bed end; move either hole a single 30 s epoch later and they go silent too.
    ///
    /// So the lookahead walks the CONTINUOUS RUN that starts at the in-bed end instead of taking
    /// one step, and this bounds how long that walk may last. A bound is required: a ring worn
    /// through the day keeps emitting at the 150 s cadence, so an unbounded walk would eventually
    /// find some ordinary daytime disconnect and report it as a hole in the night.
    ///
    /// ⚠️ IT IS THE CONTINUITY TOLERANCE, DELIBERATELY — NOT A NEW NUMBER. It was 600 s until a
    /// review pointed out the thing that matters here: **the corpus contains ZERO nights of the
    /// shape this walk acts on** (a record inside the bound, then a material hole — 0 of 21; the
    /// other 21 all either break at 0.0 min, which the single-step rule already caught, or run unbroken
    /// past every candidate bound). So "TABLE 1 is byte-identical" says the change is INERT on the
    /// corpus; it says nothing about its false-positive rate, and a rule of three puts the 95 %
    /// upper bound around 14 % of nights. A free parameter chosen on n = 1 against an unpopulated
    /// input class is the worst kind, so the parameter is gone: this now aliases
    /// `continuousToleranceSeconds`, which has its own independent justification (two 150 s epochs,
    /// enough to absorb a single dropped or unparsed one) and is the same constant the walk already
    /// uses to decide what "continuous" means. One tolerance, one meaning.
    ///
    /// What that costs: a ring worn more than ~5 min past the staged wake and then removed is
    /// `.witnessed` and silent, exactly as on master. That is the ordinary morning-charge routine,
    /// and it is the false-positive class the review named. What it keeps: the tester night's hole
    /// begins **30 s** past the edge, so it still fires.
    ///
    /// `0` is the KILL SWITCH — the walk never runs and the array overload reproduces the
    /// two-argument one exactly, which `testWalkKillSwitchReproducesSingleStep` asserts.
    public static var resumeRunMaxSeconds: TimeInterval { continuousToleranceSeconds }

    /// Classify the trailing edge of a night's in-bed window.
    ///
    /// - Parameters:
    ///   - inBedEnd: the detected closing edge of the night.
    ///   - firstMeasurementAfter: timestamp of the oldest wrist measurement strictly AFTER
    ///     `inBedEnd`, or nil if there is none. Callers should pass a HEART-RATE observation for the
    ///     same reason `BedtimeProvenance` does: HR is band-guarded to 30…220 bpm, so a charging or
    ///     pocketed ring produces none, while a skin-temp row keeps arriving from a docked ring and
    ///     would call a charge cycle "witnessed".
    ///   - earliestRetainedMeasurement: timestamp of the OLDEST measurement still on disk, used to
    ///     tell "the ring stopped recording" from "retention no longer reaches this night". nil when
    ///     the caller has no retention information (on device that means an empty store, in which
    ///     case there is no successor either), and the raw verdict then stands — deliberate: the
    ///     corpus harness withholds the field on nights whose leading edge is undeterminable, and
    ///     `R2_2026-08-17`, one of the two 246-minute nights this whole classifier exists for, is
    ///     one of them. This parameter has NO DEFAULT on purpose; see the retention note below.
    /// - Returns: `.unknown` when there is no later measurement — the honest answer, because the
    ///   store having nothing after the edge is exactly as consistent with "you synced at wake" as
    ///   with "the ring stopped". This branch has ZERO labelled validation (6 of 21 corpus nights
    ///   land there and the corpus cannot adjudicate one of them), so it must stay SILENT in the UI.
    ///
    /// ⚠️ THE RETENTION GUARD, AND WHY IT LIVES HERE RATHER THAN IN THE CALLER. `StoredSample` rows
    /// are pruned at `LocalStore.sampleRetentionDays` (30) on every launch while
    /// `StoredSleepSummary` is kept long-term, so a night older than that keeps its row and loses
    /// every raw sample around it. The two edges then behave completely differently:
    ///
    ///   • FRONT: `latestSample(before:)` returns nil (everything earlier was pruned) and
    ///     `BedtimeProvenance` answers `.unknown`, because retention cannot reach back far enough.
    ///     Silent, correct, and it gets that for free from the `earliestRetainedMeasurement` it
    ///     already takes.
    ///   • BACK: `earliestSample(after:)` happily returns the OLDEST SURVIVING ROW — the retention
    ///     boundary, days later. Read as a resume, that makes the card say "nothing was recorded
    ///     between 07:12 and <three weeks later>": routine local housekeeping reported as a hole in
    ///     the night.
    ///
    /// This guard used to sit in `SleepConfidence.assess`, which meant the OBVIOUS API — this
    /// function — was the unsafe one, and any second caller would have had to remember to reapply
    /// it. It is now here, mirroring the leading edge, and the parameter is required so the mistake
    /// cannot be made by omission. The test is the data itself rather than a copy of the retention
    /// constant: if the oldest row we still hold is NEWER than the night's trailing edge, then
    /// everything at and after that edge has been pruned, so the "next" measurement is a boundary,
    /// not evidence, and `.unknown` — which ships silent — is the honest answer.
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
    public static func classify(inBedEnd: Date,
                                firstMeasurementAfter: Date?,
                                earliestRetainedMeasurement: Date?) -> Verdict {
        // Retention no longer reaches this night's end ⇒ whatever comes "after" it is the pruning
        // boundary, not the ring resuming. See the note above.
        if let earliest = earliestRetainedMeasurement, earliest > inBedEnd { return .unknown }
        guard let next = firstMeasurementAfter else { return .unknown }
        // A measurement at or before the edge is not "after" it; treat a caller that passes one as
        // giving no usable evidence rather than silently computing a negative gap. (Mirrors
        // BedtimeProvenance's caller hazard, which the corpus harness trips constantly: the newest
        // record INSIDE the window is always ≤ inBedEnd.)
        guard next > inBedEnd else { return .unknown }
        let gap = next.timeIntervalSince(inBedEnd)
        return gap <= continuousToleranceSeconds ? .witnessed : .stoppedThenResumed(gap)
    }

    /// Classify the trailing edge against the WHOLE run of measurements that follows it.
    ///
    /// Strictly additive over the two-argument version: it returns that verdict unchanged except
    /// when it is `.witnessed`, which it may upgrade to `.stoppedThenResumed`. It can never silence
    /// a stop, never invent an `.unknown`, and never flag a night the single-step rule already
    /// cleared for any reason other than a real hole beginning within `resumeRunLimit` of the edge.
    ///
    /// - Parameters:
    ///   - measurementsAfter: wrist measurements after `inBedEnd`, same HR-only discipline as the
    ///     two-argument version. Order and duplicates do not matter — it sorts and filters. Entries
    ///     at or before `inBedEnd` are dropped rather than allowed to compute a negative gap.
    ///   - resumeRunLimit: how far past `inBedEnd` a hole may BEGIN. `0` disables the walk.
    public static func classify(inBedEnd: Date,
                                measurementsAfter: [Date],
                                earliestRetainedMeasurement: Date?,
                                resumeRunLimit: TimeInterval = resumeRunMaxSeconds) -> Verdict {
        stoppage(inBedEnd: inBedEnd,
                 measurementsAfter: measurementsAfter,
                 earliestRetainedMeasurement: earliestRetainedMeasurement,
                 resumeRunLimit: resumeRunLimit).verdict
    }

    /// A verdict together with the instant its silence BEGAN — the last measurement before the hole.
    ///
    /// ⚠️ THIS TYPE EXISTS BECAUSE THE WALK BROKE AN INVARIANT THE SINGLE-STEP RULE HELD FOR FREE.
    /// Under one step the silence always began at `inBedEnd`, so a caller could render the hole as
    /// `inBedEnd … inBedEnd + gap` and be exactly right. The walk can consume records first, so the
    /// gap it measures runs between two POST-EDGE records and `inBedEnd + gap` names an instant that
    /// never happened — both endpoints wrong, by up to `resumeRunLimit`.
    ///
    /// Measured on the review's probe: in-bed end 01:46, records at +60/+210 s, stream resumes
    /// 05:16. Rendered from the edge the card says the silence began at 01:46 and ended at 05:12:30;
    /// it began at 01:49:30 and ended at 05:16. Both endpoints wrong.
    /// ⚠️ The probe originally ran to +510 s. At the shipped `resumeRunMaxSeconds` that input is
    /// `.witnessed` and silent — see `testARingWornSeveralMinutesPastWakeThenRemovedStaysSilent` —
    /// so the example is stated at a length the shipped bound can actually reach.
    ///
    /// `silenceBegan` restores the invariant **`silenceBegan + gap == the record that resumed`**.
    /// It is nil for every verdict that names no hole.
    public struct Stoppage: Equatable, Sendable {
        public let verdict: Verdict
        /// Last measurement before the silence, or `inBedEnd` when the silence starts at the edge.
        /// nil unless `verdict` is `.stoppedThenResumed`.
        public let silenceBegan: Date?

        public init(verdict: Verdict, silenceBegan: Date?) {
            self.verdict = verdict
            self.silenceBegan = silenceBegan
        }
    }

    /// The walk, reporting WHERE the silence began as well as how long it lasted.
    public static func stoppage(inBedEnd: Date,
                                measurementsAfter: [Date],
                                earliestRetainedMeasurement: Date?,
                                resumeRunLimit: TimeInterval = resumeRunMaxSeconds) -> Stoppage {
        let ordered = measurementsAfter.filter { $0 > inBedEnd }.sorted()
        let base = classify(inBedEnd: inBedEnd,
                            firstMeasurementAfter: ordered.first,
                            earliestRetainedMeasurement: earliestRetainedMeasurement)
        // Only a `.witnessed` can be wrong in the direction this walk exists to fix. A
        // `.stoppedThenResumed` already names a hole and an `.unknown` already says we cannot tell;
        // re-deciding either from the same rows could only make the verdict less honest.
        guard case .witnessed = base, resumeRunLimit > 0 else {
            // The single-step rule's hole, when it has one, begins at the edge by construction.
            if case .stoppedThenResumed = base {
                return Stoppage(verdict: base, silenceBegan: inBedEnd)
            }
            return Stoppage(verdict: base, silenceBegan: nil)
        }

        var previous = inBedEnd
        for m in ordered {
            let gap = m.timeIntervalSince(previous)
            if gap > continuousToleranceSeconds {
                return Stoppage(verdict: .stoppedThenResumed(gap), silenceBegan: previous)
            }
            previous = m
            // The run carried on well past the edge, so the night genuinely ended while the ring
            // was still measuring. Anything later is daytime, not this night.
            if previous.timeIntervalSince(inBedEnd) > resumeRunLimit {
                return Stoppage(verdict: .witnessed, silenceBegan: nil)
            }
        }
        // The run reached the end of what we hold without breaking. Unchanged from `base` on
        // purpose: "our archive stops here" is the `.unknown` story, but the single-step rule
        // already called this `.witnessed` and this function must not silence or re-label it.
        return Stoppage(verdict: .witnessed, silenceBegan: nil)
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
