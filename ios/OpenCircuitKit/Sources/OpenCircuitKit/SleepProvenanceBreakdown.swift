// SPLIT A NIGHT INTO WHAT WE MEASURED AND WHAT THE USER TOLD US — and decide which numbers we are
// entitled to publish.
//
// This is the enforcement point for clause 3 of the provenance rule (`SleepProvenance`):
// asserted-UNMEASURED time never enters a derived number. `SleepStaging.Summary` is deliberately
// left provenance-BLIND — it stays the DISPLAY headline, because clause 1 says an assertion wins for
// display and a user who dragged their window to 06:43 must not be told they slept until 02:37.
// Everything a third party could mistake for a measurement is computed here instead.
//
// WHAT COUNTS AS MEASURED. `.measured` and `.assertedOverMeasured` both do. The second is a user
// LABEL sitting on real recorded ground — the label wins for display and the ground is real, so the
// span belongs in both numerator and denominator. Only `.asserted` — a claim over nothing — is
// excluded. Getting this backwards would delete the user's corrections from their own statistics.
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
    /// Asleep the user asserted over ground holding no records at all.
    public let assertedAsleep: TimeInterval
    /// Awake over covered ground.
    public let measuredAwake: TimeInterval
    /// Awake the user asserted over ground holding no records at all.
    public let assertedAwake: TimeInterval
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
    public var coverageFraction: Double {
        totalInBed > 0 ? coveredInBed / totalInBed : 0
    }

    /// The headline the CARD shows: measured plus asserted. Clause 1 — an assertion wins for display.
    public var displayedAsleep: TimeInterval { measuredAsleep + assertedAsleep }
    public var displayedAwake: TimeInterval { measuredAwake + assertedAwake }

    /// True when any of this night's displayed sleep is a claim over nothing.
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

    /// A one-line reason a number was withheld, for the export and the diagnostics bundle. `nil`
    /// when nothing is withheld.
    public var withheldReason: String? {
        guard tuning.withholdingEnabled, hasAssertedTime else { return nil }
        let unmeasured = max(0, totalInBed - coveredInBed)
        let mins = Int((unmeasured / 60).rounded())
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
            coveredInBed = sum { $0.stage != .inBed && !$0.provenance.isUnmeasured }
        } else {
            totalInBed = sum { $0.stage == .inBed }
            coveredInBed = sum { $0.stage == .inBed && !$0.provenance.isUnmeasured }
        }

        measuredAsleep = sum { asleepStages.contains($0.stage) && !$0.provenance.isUnmeasured }
        assertedAsleep = sum { asleepStages.contains($0.stage) && $0.provenance.isUnmeasured }
        measuredAwake = sum { $0.stage == .awake && !$0.provenance.isUnmeasured }
        assertedAwake = sum { $0.stage == .awake && $0.provenance.isUnmeasured }
        measuredLight = sum { $0.stage == .asleepCore && !$0.provenance.isUnmeasured }
        measuredDeep = sum { $0.stage == .asleepDeep && !$0.provenance.isUnmeasured }
        measuredREM = sum { $0.stage == .asleepREM && !$0.provenance.isUnmeasured }

        // Longest unmeasured run: merge the asserted spans (the in-bed layer and the stage layer
        // overlap, so a naive max over segments would report the shorter of two views of one hole).
        let assertedSpans = segments
            .filter { $0.provenance.isUnmeasured && $0.end > $0.start }
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

public extension Array where Element == SleepSegment {
    /// Everything except claims over nothing — the filter for a DERIVED STATISTIC.
    ///
    /// ⚠️ NOT the Apple Health filter. This drops the unmeasured part of the `.inBed` layer too,
    /// which is right for a denominator ("covered in-bed") and wrong for Health, where the in-bed
    /// span is a user claim we have no reason to doubt. Use `healthPublishable` there.
    var measuredOnly: [SleepSegment] { filter { !$0.provenance.isUnmeasured } }

    /// What may be written to Apple Health.
    ///
    /// Keeps the WHOLE `.inBed` layer — asserted or not — because in-bed is a statement about where
    /// the body was, the user is the better authority, and we hold no competing measurement. Drops
    /// every other segment whose ground holds no records: an `.asleepCore` block over a four-hour
    /// hole is the defect, and an `.awake` block over the same hole is the same claim in the other
    /// direction. Both spans remain covered by the `.inBed` sample, which is exactly how Apple's own
    /// Sleep UI represents "in bed, not known to be asleep".
    ///
    /// Deliberately NOT `.asleepUnspecified`: every reader that reports "time asleep" — Apple's
    /// Sleep UI included — sums `asleepCore + asleepDeep + asleepREM + asleepUnspecified`, so it
    /// would land in third-party totals identically to `.asleepCore`. It looks like a compromise and
    /// functions as the status quo.
    var healthPublishable: [SleepSegment] {
        filter { $0.stage == .inBed || !$0.provenance.isUnmeasured }
    }

    /// True when any segment is a claim over ground holding no records.
    var containsAssertedTime: Bool { contains { $0.provenance.isUnmeasured } }

    /// Asleep seconds that would reach Health today but must not — the retraction quantity.
    var unmeasuredAsleepSeconds: TimeInterval {
        let asleep: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]
        return filter { asleep.contains($0.stage) && $0.provenance.isUnmeasured }
            .reduce(0) { $0 + Swift.max(0, $1.duration) }
    }
}
