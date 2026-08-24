// SPLIT A NIGHT INTO WHAT WE MEASURED AND WHAT THE USER TOLD US — and decide which numbers we are
// entitled to publish.
//
// This is the enforcement point for clause 3 of the provenance rule (`SleepProvenance`):
// asserted-UNMEASURED time never enters a derived number. `SleepStaging.Summary` is deliberately
// left provenance-BLIND — it stays the DISPLAY headline, because clause 1 says an assertion wins for
// display and a user who dragged their window to 06:43 must not be told they slept until 02:37.
// Everything a third party could mistake for a measurement is computed here instead.
//
// WHAT COUNTS AS MEASURED. `.measured` and `.assertedOverMeasured` both do (`hasMeasurement`). The
// second is a user LABEL sitting on real recorded ground — the label wins for display and the ground
// is real, so the span belongs in both numerator and denominator. Getting this backwards would
// delete the user's corrections from their own statistics.
//
// THREE BUCKETS, NOT TWO, AND THE THIRD IS LOAD-BEARING. `.asserted` is a claim over ground we can
// PROVE holds no records, and it is the only thing excluded from a derived number. Ground our
// retained records cannot reach is `.assertedCoverageUnknown` and lands in its own `unknown*`
// bucket: counted in the display total, published to Health unlabelled, never quoted as either
// measurement or hole. Collapsing it into `asserted` is precisely how retention got read as absence
// (measured: 403 asleep-minutes to 0.0 in Apple Health — see `MeasuredCoverage.trusted(for:)`).
//
// ⚠️ "EXCLUDED FROM A DERIVED NUMBER" IS NOT "KEPT OUT OF APPLE HEALTH" — not since 2026-08-24.
// Asserted sleep reaches Health tagged `HKMetadataKeyWasUserEntered`; what it stays out of is
// efficiency, the score, the stage minutes and the headache features, all of which are computed
// here. `SleepHealthPublication` at the bottom of this file owns the Health half.
//
// 🟢 WORKED EXAMPLE, re-derived from raw bytes 2026-08-20 (`R2_2026-08-18`, Gen 2 Air, Europe/Paris):
//   in-bed window 23:24 → 06:43 (439 min), of which 195.1 min is covered ground (fraction 0.444)
//   measured asleep 159.1 min · asserted asleep 243.9 min · measured awake 36.0 min
//   efficiency over covered ground = 159.1 / 195.1 = 0.8155 — versus the 0.9180 the app shipped,
//   which is exactly (9422 + 14758) / 26340 and counts a 246-minute block over 2 %-covered ground.
//
// NOTHING HERE FIRES ON AN UNEDITED NIGHT. `SleepStaging.classify` emits only `.measured` segments,
// so a staged night's breakdown is all-measured, `coverageFraction == 1`, and every number is
// published exactly as before. That is a deliberate scope choice backed by measurement: the audit
// found the ordinary staging path asserts 22.4 asleep-minutes across all 21 staged corpus nights
// (worst single hole 4.9 min), so there is nothing there worth withholding a number over. The edit
// path asserted 485.6 minutes across 2 nights. Coverage is tested where the damage is.

import Foundation

/// Measured-versus-asserted totals for one night, plus the publish/withhold verdicts.
public struct SleepProvenanceBreakdown: Equatable, Sendable {

    /// Thresholds for withholding a derived number. Provisional and deliberately round.
    ///
    /// ⚠️ THESE ARE NOT FITTED, AND MUST NOT BE QUOTED AS IF THEY WERE. They are set to round values
    /// that behave correctly on the two device-proven nights and are inert on a fully-covered one.
    /// The corpus cannot fit them honestly: it holds 5 labelled nights against
    /// `SleepEditLabel.minimumNightsToFit = 10`, with no control set, and the one good labelled night
    /// is silent for an export-slicing artifact rather than for a measured reason. Set them from real
    /// per-device coverage data before any of this becomes user-visible.
    public struct Tuning: Equatable, Sendable {
        /// Least covered in-bed time over which an efficiency RATIO is worth publishing. A ratio
        /// needs a denominator; below this the number says more about the gap than the sleep.
        /// Same order as `SleepConfidence.minNightForFlag` (5 h), one step lower because this is
        /// covered ground rather than wall-clock.
        public var minCoveredInBedForEfficiency: TimeInterval
        /// Coverage at or above which a single summary verdict (the sleep score) may be assembled.
        /// The score's dominant factor is `timeAsleep` at weight 0.30 (`SleepScore.swift:93`) and
        /// "how long did she sleep" is precisely the question an uncovered night cannot answer.
        public var minCoverageForScore: Double
        /// Set `false` to restore pre-provenance behaviour: nothing is ever withheld. The kill
        /// switch for this whole layer, independent of `SleepEdit`'s `coverage:` kill switch.
        public var withholdingEnabled: Bool

        public init(minCoveredInBedForEfficiency: TimeInterval = 3 * 3600,
                    minCoverageForScore: Double = 0.75,
                    withholdingEnabled: Bool = true) {
            self.minCoveredInBedForEfficiency = minCoveredInBedForEfficiency
            self.minCoverageForScore = minCoverageForScore
            self.withholdingEnabled = withholdingEnabled
        }

        public static let `default` = Tuning()
        /// Publish everything, exactly as before provenance existed.
        public static let neverWithhold = Tuning(withholdingEnabled: false)
    }

    // MARK: - Totals (seconds)

    /// In-bed span the user is claiming, measured or not — the honest "time in bed".
    public let totalInBed: TimeInterval
    /// The part of `totalInBed` the ring actually recorded across.
    public let coveredInBed: TimeInterval
    /// Asleep (core + deep + REM) over covered ground.
    public let measuredAsleep: TimeInterval
    /// Asleep the user asserted over ground we can PROVE holds no records.
    public let assertedAsleep: TimeInterval
    /// Asleep the user asserted over ground our retained records cannot speak about at all — neither
    /// measured nor provably empty. Counted in the display total and published to Health, exactly as
    /// before provenance existed; kept in its own bucket so it is never quoted as either of the
    /// other two.
    public let unknownAsleep: TimeInterval
    /// Awake over covered ground.
    public let measuredAwake: TimeInterval
    /// Awake the user asserted over ground we can PROVE holds no records.
    public let assertedAwake: TimeInterval
    /// Awake over ground our retained records cannot speak about. See `unknownAsleep`.
    public let unknownAwake: TimeInterval
    /// Per-stage seconds over covered ground only. Unmeasured time has no defensible stage.
    public let measuredLight: TimeInterval
    public let measuredDeep: TimeInterval
    public let measuredREM: TimeInterval
    /// Longest single unmeasured run inside the in-bed window.
    public let longestUnmeasuredGap: TimeInterval

    private let tuning: Tuning

    // MARK: - Verdicts

    /// Share of the in-bed window the ring recorded across, 0…1. 1 on any night with no asserted
    /// time — which is every unedited night.
    ///
    /// ⚠️ UNKNOWN GROUND IS NOT IN THE NUMERATOR. A night whose window reaches back past our oldest
    /// retained record reports a LOW fraction for a reason that is partly about our retention and
    /// only partly about the ring — read `unknownAsleep`/`unknownInBed` before quoting this as a
    /// statement about the device.
    public var coverageFraction: Double {
        totalInBed > 0 ? coveredInBed / totalInBed : 0
    }

    /// In-bed time our retained records cannot speak about — the part of `totalInBed` that is
    /// neither `coveredInBed` nor a proven hole.
    public let unknownInBed: TimeInterval

    /// The headline the CARD shows: everything, however we came by it. Clause 1 — an assertion wins
    /// for display.
    public var displayedAsleep: TimeInterval { measuredAsleep + assertedAsleep + unknownAsleep }
    public var displayedAwake: TimeInterval { measuredAwake + assertedAwake + unknownAwake }

    /// True when any of this night's displayed sleep is a claim over ground we can prove holds no
    /// records. Deliberately NOT true for unknown ground: that is the pre-provenance situation, and
    /// flagging it would caveat every night older than the archive.
    public var hasAssertedTime: Bool { assertedAsleep > 0 || assertedAwake > 0 }

    /// Sleep efficiency over COVERED GROUND ONLY — `nil` when there is not enough covered in-bed
    /// time for the ratio to mean anything.
    ///
    /// ⚠️ `nil` MEANS WITHHELD AND MUST BE RENDERED AS "—". **Never persist 0 for it.**
    /// `LocalStore.swift:235` reads `inBed = efficiency > 0 ? asleep / efficiency : asleep + awake`,
    /// so a stored zero is a live SENTINEL that silently reconstructs in-bed from the wrong
    /// quantities for every downstream reader, the headache row included.
    public var efficiency: Double? {
        guard coveredInBed > 0 else { return nil }
        if tuning.withholdingEnabled, coveredInBed < tuning.minCoveredInBedForEfficiency { return nil }
        return measuredAsleep / coveredInBed
    }

    /// Whether a single summary verdict (the sleep score) can be honestly assembled for this night.
    ///
    /// CHECKED AT SOURCE, and it changes the build: `sleepScore` is NOT a headache feature.
    /// `HeadacheEngine.swift:136-142` consumes efficiency, `awakeMin` and `asleepMin` only. So
    /// withholding the score perturbs the headache engine by exactly zero.
    public var isScorable: Bool {
        guard tuning.withholdingEnabled else { return true }
        guard totalInBed > 0 else { return false }
        return coverageFraction >= tuning.minCoverageForScore
    }

    /// In-bed time we can PROVE holds no records — `totalInBed` less the covered part AND less the
    /// part our retained records cannot speak about. This is the only quantity entitled to be
    /// described in words as "holds no ring data".
    public var provenUnmeasuredInBed: TimeInterval {
        max(0, totalInBed - coveredInBed - unknownInBed)
    }

    /// A one-line reason a number was withheld, for the export and the diagnostics bundle. `nil`
    /// when nothing is withheld.
    ///
    /// ⚠️ IT COUNTS ONLY PROVEN GROUND. Using `totalInBed - coveredInBed` here would fold in the
    /// unknown bucket and state as fact that the ring recorded nothing across minutes we simply no
    /// longer hold records for — 🟢 143 of the 389 minutes this sentence used to claim on
    /// `R2_2026-08-17` were exactly that.
    public var withheldReason: String? {
        guard tuning.withholdingEnabled, hasAssertedTime else { return nil }
        let mins = Int((provenUnmeasuredInBed / 60).rounded())
        return "\(mins) min of this night's \(Int((totalInBed / 60).rounded())) min in-bed window "
            + "holds no ring data"
    }

    // MARK: - Construction

    public init(segments: [SleepSegment], tuning: Tuning = .default) {
        self.tuning = tuning
        func sum(_ predicate: (SleepSegment) -> Bool) -> TimeInterval {
            segments.filter(predicate).reduce(0) { $0 + max(0, $1.duration) }
        }
        let asleepStages: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]

        // In-bed. Sum the `.inBed` layer when there is one — a stitched multi-fragment night carries
        // one per fragment and the inter-fragment gaps must not count (the same rule
        // `SleepStaging.summary` applies at `:937-941`). Fall back to the staged total otherwise, so
        // a stage-only synthetic input still has a denominator.
        let inBedLayer = segments.filter { $0.stage == .inBed }
        if inBedLayer.isEmpty {
            let staged = sum { $0.stage != .inBed }
            totalInBed = staged
            coveredInBed = sum { $0.stage != .inBed && $0.provenance.hasMeasurement }
            unknownInBed = sum { $0.stage != .inBed && $0.provenance.isCoverageUnknown }
        } else {
            totalInBed = sum { $0.stage == .inBed }
            coveredInBed = sum { $0.stage == .inBed && $0.provenance.hasMeasurement }
            unknownInBed = sum { $0.stage == .inBed && $0.provenance.isCoverageUnknown }
        }

        measuredAsleep = sum { asleepStages.contains($0.stage) && $0.provenance.hasMeasurement }
        assertedAsleep = sum { asleepStages.contains($0.stage) && $0.provenance.isProvenUnmeasured }
        unknownAsleep = sum { asleepStages.contains($0.stage) && $0.provenance.isCoverageUnknown }
        measuredAwake = sum { $0.stage == .awake && $0.provenance.hasMeasurement }
        assertedAwake = sum { $0.stage == .awake && $0.provenance.isProvenUnmeasured }
        unknownAwake = sum { $0.stage == .awake && $0.provenance.isCoverageUnknown }
        measuredLight = sum { $0.stage == .asleepCore && $0.provenance.hasMeasurement }
        measuredDeep = sum { $0.stage == .asleepDeep && $0.provenance.hasMeasurement }
        measuredREM = sum { $0.stage == .asleepREM && $0.provenance.hasMeasurement }

        // Longest PROVEN unmeasured run: merge the asserted spans (the in-bed layer and the stage
        // layer overlap, so a naive max over segments would report the shorter of two views of one
        // hole). Unknown ground is excluded on purpose — a gap we cannot vouch for must not be
        // reported as "the ring recorded nothing for N hours".
        let assertedSpans = segments
            .filter { $0.provenance.isProvenUnmeasured && $0.end > $0.start }
            .map { $0.start ..< $0.end }
        longestUnmeasuredGap = MeasuredCoverage(intervals: assertedSpans).intervals
            .map { $0.upperBound.timeIntervalSince($0.lowerBound) }
            .max() ?? 0
    }

    /// Whole minutes, for cards, exports and the store. `efficiency` stays a `Double?` on purpose —
    /// see the warning on it.
    public var minutes: (inBed: Int, coveredInBed: Int,
                         measuredAsleep: Int, assertedAsleep: Int,
                         measuredAwake: Int, assertedAwake: Int,
                         light: Int, deep: Int, rem: Int) {
        func m(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
        return (m(totalInBed), m(coveredInBed),
                m(measuredAsleep), m(assertedAsleep),
                m(measuredAwake), m(assertedAwake),
                m(measuredLight), m(measuredDeep), m(measuredREM))
    }
}

/// One night's segments, split by what Apple Health must be told about each of them.
///
/// Three buckets, and the third is kept EMPTY on purpose. `withheld` is what this app declines to
/// write at all; today's rule withholds nothing, but the concept is load-bearing — its one consumer
/// is a DELETE-EXCLUSION predicate (`HealthKitWriter.deletePriorEditedNightSleep`), and a rule that
/// ever starts withholding again must not also start deleting across the ground it withheld.
/// Deriving the predicate's input from this partition rather than from a free-standing filter is
/// what keeps those two answers married.
public struct SleepHealthPublication: Equatable, Sendable {
    /// Written as ordinary samples: the ring measured this ground, or we cannot prove it did not.
    public let measured: [SleepSegment]
    /// Written with `HKMetadataKeyWasUserEntered: true` — the wearer's own account of ground we can
    /// PROVE holds no records.
    public let userEntered: [SleepSegment]
    /// Not written at all. Empty under today's rule; see the type's note.
    public let withheld: [SleepSegment]
    /// Everything that reaches Health, in the caller's original order.
    public let published: [SleepSegment]

    public init(measured: [SleepSegment], userEntered: [SleepSegment],
                withheld: [SleepSegment], published: [SleepSegment]) {
        self.measured = measured
        self.userEntered = userEntered
        self.withheld = withheld
        self.published = published
    }
}

public extension Array where Element == SleepSegment {
    /// Everything except claims over nothing — the filter for a DERIVED STATISTIC.
    ///
    /// ⚠️ NOT the Apple Health filter. This drops the unmeasured part of the `.inBed` layer too,
    /// which is right for a denominator ("covered in-bed") and wrong for Health, where the in-bed
    /// span is a user claim we have no reason to doubt. Use `healthPublishable` there.
    var measuredOnly: [SleepSegment] { filter { $0.provenance.hasMeasurement } }

    /// HOW THIS NIGHT IS SPLIT FOR APPLE HEALTH — the single place that decides what reaches Health
    /// and how each sample must be tagged. `healthPublishable` and `withheldSpans` are both derived
    /// from it, so "what we write" and "what we declined to write" can never disagree.
    ///
    /// ⚠️ 2026-08-24: THIS WAS A FILTER AND IS NOW A PARTITION, AND THE CHANGE IS DELIBERATE. Build
    /// 47 DROPPED every non-`.inBed` segment over proven-empty ground. The maintainer reversed that
    /// half of the decision after the tester report this partition exists for: she corrected a night
    /// the ring had stopped recording through, and her correction never reached Apple Health while
    /// the official RingConn app's did. Sleep the wearer asserts over ground the ring did not record
    /// now REACHES Health — as the stage her edit assigned, carrying
    /// `HKMetadataKeyWasUserEntered: true` so the sample states its own provenance to every reader.
    ///
    /// What did NOT change is the honest accounting: `.asserted` time is still excluded from every
    /// derived number here (clause 3), still named on the Sleep card, and still distinguishable in
    /// Health itself. What changed is that we no longer silently subtract a wearer's own account of
    /// her night from the one surface she checks it against.
    ///
    /// The `.inBed` layer is published whole either way — in-bed is a statement about where the body
    /// was, the user is the better authority, and we hold no competing measurement. The part of it
    /// sitting over a PROVEN hole is tagged like any other asserted span: the tag answers "who says
    /// so", and there the answer is her, whatever the stage. The rest of the layer
    /// (`.assertedOverMeasured` — her boundary over ground the ring recorded) is not tagged, because
    /// there the ring corroborates her.
    ///
    /// ⚠️ THE TAG DOES NOT EXCLUDE THE SAMPLE FROM APPLE'S "TIME ASLEEP", AND THAT IS THE ACCEPTED
    /// CONSEQUENCE OF THE DECISION — not an oversight. 🟢 On the 2026-08-24 tester night her Health
    /// headline goes back to the card's 434 min: 218 measured + 216 tagged, once
    /// `SleepProvenanceRederivation` has reclaimed the 1350 s her archive filled in after she saved
    /// (195 + 239 without it — the split her export was frozen at).
    /// `HKMetadataKeyWasUserEntered` is a provenance flag, not a filter: every reader that reports
    /// time asleep still sums the sample.
    ///
    /// It is also why the tagged samples keep the STAGE her edit assigned instead of collapsing to
    /// `.asleepUnspecified`. That was considered as a middle ground and rejected on the same
    /// arithmetic: Apple's Sleep UI sums `asleepCore + asleepDeep + asleepREM + asleepUnspecified`,
    /// so it would change no total anywhere while discarding the one thing the wearer actually told
    /// us. (Until 2026-08-24 this paragraph used that argument to reject `.asleepUnspecified` in
    /// favour of publishing NOTHING; the argument survives the reversal, the conclusion does not.)
    var healthPublication: SleepHealthPublication {
        var measured: [SleepSegment] = []
        var userEntered: [SleepSegment] = []
        for segment in self {
            // ONE PREDICATE, EVERY STAGE. A `.asleepCore` block over a four-hour hole, an `.awake`
            // block over the same hole and the `.inBed` span across it are the same claim by the
            // same person; splitting them by stage would mean two of the three carried her name and
            // one did not. `.assertedCoverageUnknown` is NOT tagged: "we cannot say whether the ring
            // recorded here" is not "she told us", and mislabelling it would make every night older
            // than the ~30 h archive look hand-entered.
            if segment.provenance.isProvenUnmeasured {
                userEntered.append(segment)
            } else {
                measured.append(segment)
            }
        }
        return SleepHealthPublication(measured: measured, userEntered: userEntered,
                                      withheld: [], published: self)
    }

    /// What may be written to Apple Health — every segment, since the partition above withholds
    /// nothing. Kept as the write set (and as the set the watermarks are pinned from) so a future
    /// rule that DOES withhold something is honoured at both places by construction.
    var healthPublishable: [SleepSegment] { healthPublication.published }

    /// The subset of `healthPublishable` that must carry `HKMetadataKeyWasUserEntered: true`.
    var healthUserEntered: [SleepSegment] { healthPublication.userEntered }

    /// True when any segment is a claim over ground we can PROVE holds no records.
    var containsAssertedTime: Bool { contains { $0.provenance.isProvenUnmeasured } }

    /// Asleep seconds that reach Health as the WEARER'S OWN ENTRY — tagged
    /// `HKMetadataKeyWasUserEntered`, counted in Apple's Time Asleep, and named on the Sleep card.
    ///
    /// Until 2026-08-24 this was the RETRACTION quantity: the same seconds, withheld instead of
    /// tagged. The number is unchanged and so is its meaning ("asleep over ground we can prove holds
    /// no records") — only its destination changed, which is why the breadcrumb that prints it and
    /// the two device nights it was measured on still line up.
    var unmeasuredAsleepSeconds: TimeInterval {
        let asleep: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]
        return filter { asleep.contains($0.stage) && $0.provenance.isProvenUnmeasured }
            .reduce(0) { $0 + Swift.max(0, $1.duration) }
    }

    /// The spans this app is DECLINING to publish — the exact ground a coverage-driven shrink would
    /// remove from a Health write. Merged, so overlapping stage/in-bed views of one hole count once.
    ///
    /// ⚠️ ITS ONE PRODUCTION CONSUMER IS A DELETE PREDICATE, AND THAT IS THE POINT. Withholding a
    /// span from our own write is reversible — the next sync can add it. Deleting Apple Health
    /// samples across the same span is not, and it would take with it whatever an earlier, better-
    /// informed run of this app had already written there. See `deletePriorEditedNightSleep`.
    ///
    /// ⚠️ 2026-08-24: IT IS DERIVED FROM `healthPublication.withheld`, SO IT IS EMPTY TODAY, AND
    /// KEEPING IT HONEST IS WHY. Asserted sleep is now PUBLISHED (tagged user-entered) rather than
    /// withheld. Had this stayed a free-standing "asserted spans" filter it would have gone on
    /// naming ground we DO write — and the delete-exclusion it feeds would then protect the freshly
    /// written samples from the very cleanup that removes the PREVIOUS write over the same ground.
    /// Every re-edit and every re-derivation would leave a duplicate night in Apple Health.
    var withheldSpans: [DateInterval] {
        let spans = healthPublication.withheld.filter { $0.end > $0.start }
            .map { $0.start ..< $0.end }
        return MeasuredCoverage(intervals: spans).intervals
            .map { DateInterval(start: $0.lowerBound, end: $0.upperBound) }
    }
}
