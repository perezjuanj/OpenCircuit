// PROVENANCE — the unit-level contract, plus the real-bytes fixture from the tester night that
// produced 403 min asleep at 0.377 coverage.
//
// Every test in the REAL-BYTES section fails on master, because on master `SleepEdit.recompute`
// takes no record timestamps at all and there is no provenance to assert on. The synthetic tests
// pin the kill switch and the arithmetic; the corpus test (`SleepProvenanceCorpusTests`, separate
// file) measures the whole corpus.

import XCTest
@testable import OpenCircuitKit

// MARK: - MeasuredCoverage

final class MeasuredCoverageTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testConsecutiveEpochsMergeIntoOneInterval() {
        // Three touching 150 s epochs must coalesce. If they did not, `partition` would emit
        // zero-length "gaps" between every pair and a continuous night would look shredded.
        let c = MeasuredCoverage(recordDates: [at(0), at(150), at(300)], epochSeconds: 150)
        XCTAssertEqual(c.intervals.count, 1)
        XCTAssertEqual(c.intervals.first?.lowerBound, at(0))
        XCTAssertEqual(c.intervals.first?.upperBound, at(450))
    }

    func testGapIsReportedAsUnmeasured() {
        let c = MeasuredCoverage(recordDates: [at(0), at(600)], epochSeconds: 150)
        XCTAssertEqual(c.measuredDuration(in: at(0) ..< at(750)), 300)
        XCTAssertEqual(c.unmeasuredPortions(of: at(0) ..< at(750)).count, 1)
        XCTAssertEqual(c.longestGap(in: at(0) ..< at(750)), 450)
        XCTAssertEqual(c.fraction(of: at(0) ..< at(750)), 300.0 / 750.0, accuracy: 1e-12)
    }

    func testPartitionTilesTheRangeExactly() {
        // A hole in the tiling would silently drop time off a night, so pin the property.
        let c = MeasuredCoverage(recordDates: [at(100), at(900)], epochSeconds: 150)
        let range = at(0) ..< at(1200)
        let parts = c.partition(range)
        XCTAssertEqual(parts.first?.range.lowerBound, range.lowerBound)
        XCTAssertEqual(parts.last?.range.upperBound, range.upperBound)
        for (a, b) in zip(parts, parts.dropFirst()) {
            XCTAssertEqual(a.range.upperBound, b.range.lowerBound, "partition left a hole")
        }
        let total = parts.reduce(0.0) { $0 + $1.range.upperBound.timeIntervalSince($1.range.lowerBound) }
        XCTAssertEqual(total, 1200, accuracy: 1e-9)
    }

    func testEmptyCoverageMakesEverythingUnmeasured() {
        XCTAssertEqual(MeasuredCoverage.empty.measuredDuration(in: at(0) ..< at(1000)), 0)
        XCTAssertEqual(MeasuredCoverage.empty.partition(at(0) ..< at(1000)).count, 1)
        XCTAssertEqual(MeasuredCoverage.empty.partition(at(0) ..< at(1000)).first?.ground, .unmeasured)
    }
}

// MARK: - The retention guard (M2)
//
// RETENTION MUST NEVER READ AS ABSENCE. Coverage comes from a rolling ~30 h archive; a night older
// than that holds no records for a reason that has nothing to do with the ring. Measured on the
// branch these tests were added to: an un-guarded read of a fully-recorded night edited two days
// later published 0.0 asleep minutes to Apple Health where the shipped build published 403.0.

final class MeasuredCoverageTrustTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    func testAWindowHoldingNoRecordAtAllIsUNKNOWNRatherThanEmpty() {
        // The retention case in one line: every record we still hold is from AFTER the night.
        let night = at(0) ..< at(480)
        let archive = MeasuredCoverage(recordDates: [at(3000), at(3150)], epochSeconds: 150)
        XCTAssertEqual(archive.fraction(of: night), 0, "the raw read really does say zero coverage")
        XCTAssertNil(archive.trusted(for: night),
                     "…and zero coverage over a window we hold nothing for is UNKNOWN, not empty")
    }

    func testOneRecordInsideTheWindowIsEnoughToTrustIt() {
        let night = at(0) ..< at(480)
        let archive = MeasuredCoverage(recordDates: [at(-600), at(200)], epochSeconds: 150)
        let trusted = try? XCTUnwrap(archive.trusted(for: night))
        XCTAssertEqual(trusted?.intervals, archive.intervals, "trusting must not change the ground")
        XCTAssertEqual(trusted?.provenFrom, at(-600))
    }

    func testGroundOlderThanOurOldestRecordIsUnknownAndTheRestIsStillProven() throws {
        // One record at minute 100, covering one 150 s epoch. A window opening at minute -60 reaches
        // back past everything we hold.
        let archive = MeasuredCoverage(recordDates: [at(100)], epochSeconds: 150)
        let night = at(-60) ..< at(480)
        let trusted = try XCTUnwrap(archive.trusted(for: night))
        let parts = trusted.partition(night)
        XCTAssertEqual(parts.map(\.ground), [.unknown, .measured, .unmeasured],
                       "before the oldest record = unknown; after it, silence is evidence")
        XCTAssertEqual(parts[0].range, at(-60) ..< at(100))
        XCTAssertEqual(parts[2].range, at(102.5) ..< at(480))
    }

    func testAGapStraddlingTheHorizonIsSplitAtIt() throws {
        // Two record islands; the window opens inside the earlier one's past.
        let archive = MeasuredCoverage(intervals: [at(0) ..< at(60), at(200) ..< at(260)])
        let trusted = try XCTUnwrap(archive.trusted(for: at(-100) ..< at(300)))
        let parts = trusted.partition(at(-100) ..< at(300))
        XCTAssertEqual(parts.map(\.ground), [.unknown, .measured, .unmeasured, .measured, .unmeasured])
        XCTAssertEqual(parts[0].range, at(-100) ..< at(0), "split exactly at the oldest record")
    }

    func testTrustIsRefusedForAReversedOrEmptyWindow() {
        let archive = MeasuredCoverage(recordDates: [at(0)], epochSeconds: 150)
        XCTAssertNil(archive.trusted(for: at(10) ..< at(10)))
        XCTAssertNil(MeasuredCoverage.empty.trusted(for: at(0) ..< at(100)))
    }
}

// MARK: - The SECOND Health construction reads LABELS, and must not be re-guarded
//
// `LocalStore.pendingSleepEditHealthWrites` builds Health segments straight from the user's anchors
// and holds no records, so it recovers the decision from the stored labels. Running THAT through
// `MeasuredCoverage.trusted(for:)` substitutes "the first non-hole LABEL" for "our oldest RECORD",
// and the substitution always favours publishing: any hole at the START of a night sits before the
// first non-hole label, so it comes back `.unknown` instead of the `.unmeasured` the records proved.
// 🟢 Measured through the real path in `SleepEditStoreTests`: a proven-empty hour reached Apple
// Health as `.asleepCore`. `ProvenanceLabelCoverage` has no `trusted(for:)` — the call no longer
// compiles.

final class ProvenanceLabelCoverageTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    /// A stored hypnogram whose FIRST label is a proven hole, exactly as the primary path writes it
    /// when the wearer drags bedtime back into ground the records prove empty.
    private var labels: [SleepSegment] {
        [SleepSegment(start: at(0), end: at(60), stage: .inBed, provenance: .asserted),
         SleepSegment(start: at(0), end: at(60), stage: .asleepCore, provenance: .asserted),
         SleepSegment(start: at(60), end: at(480), stage: .inBed),
         SleepSegment(start: at(60), end: at(480), stage: .asleepCore)]
    }

    /// ⚠️ RE-BASELINED 2026-08-24. The label recovery is unchanged and is what this test is for: a
    /// hole the records PROVED empty must still come back `.unmeasured`, never softened to
    /// `.unknown`. What changed is the consequence — build 47 withheld the fill from Apple Health;
    /// the maintainer reversed that, so the hour is now PUBLISHED carrying
    /// `HKMetadataKeyWasUserEntered`. The assertion follows the label to its new destination rather
    /// than being weakened: it still pins that exactly the proven hour, and only it, is treated as
    /// the wearer's own account.
    func testALeadingPROVENHoleIsStillAHoleAndItsFillIsTaggedUserEntered() throws {
        let cov = try XCTUnwrap(MeasuredCoverage.fromProvenanceLabels(labels))
        let parts = cov.partition(at(0) ..< at(480))
        XCTAssertEqual(parts.map(\.ground), [.unmeasured, .measured],
                       "the labels proved this hour empty; recovering them must not soften it")

        // What `pendingSleepEditHealthWrites` does with those pieces, verbatim.
        let filled = parts.map {
            SleepSegment(start: $0.range.lowerBound, end: $0.range.upperBound, stage: .asleepCore,
                         provenance: SleepEdit.provenance(for: $0.ground))
        }
        XCTAssertEqual(SleepStaging.totalAsleep(filled.healthPublishable), 480 * 60, accuracy: 1,
                       "the whole window reaches Health — the wearer's account included")
        XCTAssertEqual(SleepStaging.totalAsleep(filled.healthUserEntered), 60 * 60, accuracy: 1,
                       "…and exactly the 60-minute proven hole is tagged as entered by her")
        XCTAssertTrue(filled.withheldSpans.isEmpty, "nothing is withheld ⇒ nothing may be deleted")
    }

    func testGroundLabelledCoverageUNKNOWNCountsAsCoveredAndPublishes() throws {
        // The retention case, already decided by the records-based call: `.assertedCoverageUnknown`
        // is "we cannot say", which publishes. Recovering it must not turn it into a hole.
        let withUnknown = [
            SleepSegment(start: at(0), end: at(60), stage: .asleepCore,
                         provenance: .assertedCoverageUnknown),
            SleepSegment(start: at(60), end: at(120), stage: .asleepCore, provenance: .asserted),
            SleepSegment(start: at(120), end: at(480), stage: .asleepCore),
        ]
        let cov = try XCTUnwrap(MeasuredCoverage.fromProvenanceLabels(withUnknown))
        XCTAssertEqual(cov.partition(at(0) ..< at(480)).map(\.ground),
                       [.measured, .unmeasured, .measured])
    }

    func testAHypnogramWithNoPROVENHoleReturnsNilSoTheCallerKeepsItsOldBehaviour() {
        let allMeasured = [SleepSegment(start: at(0), end: at(480), stage: .asleepCore)]
        XCTAssertNil(MeasuredCoverage.fromProvenanceLabels(allMeasured),
                     "fully covered and pre-provenance are indistinguishable — do not guess")
        let unknownOnly = [SleepSegment(start: at(0), end: at(480), stage: .asleepCore,
                                        provenance: .assertedCoverageUnknown)]
        XCTAssertNil(MeasuredCoverage.fromProvenanceLabels(unknownOnly))
    }
}

final class SleepEditRetentionGuardTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    /// A fully-recorded night: base staging across the whole window, and the user nudges wake by
    /// 10 minutes. This is the M2 scenario — the only variable is how old the archive is.
    private var base: [SleepSegment] {
        [SleepSegment(start: at(0), end: at(480), stage: .inBed),
         SleepSegment(start: at(0), end: at(480), stage: .asleepCore)]
    }
    private var times: SleepEdit.Times {
        SleepEdit.Times(inBedStart: at(0), sleepOnset: at(0), sleepWake: at(490))
    }

    func testAnArchiveThatRolledPastTheNightCannotShrinkIt() {
        // Two days later: the archive holds only recent records, none from this night.
        let rolled = MeasuredCoverage(recordDates: [at(4000), at(4150)], epochSeconds: 150)
        let out = SleepEdit.recompute(baseSegments: base, times: times, coverage: rolled)
        let master = SleepEdit.recompute(baseSegments: base, times: times, coverage: nil)

        XCTAssertEqual(out, master, "a night the archive cannot speak about must behave as master")
        XCTAssertFalse(out.containsAssertedTime)
        XCTAssertEqual(SleepStaging.totalAsleep(out.healthPublishable),
                       SleepStaging.totalAsleep(master.healthPublishable),
                       "…and Apple Health must receive exactly what it received before")
        XCTAssertTrue(out.withheldSpans.isEmpty, "nothing withheld ⇒ nothing can be deleted")
    }

    func testTheSameNightSTILLSHRINKSWhileTheArchiveHoldsIt() {
        // The guard must not be a blanket off-switch: with the records still in hand, the 10-minute
        // extension past the last record is invented and is tagged as such.
        let held = MeasuredCoverage(intervals: [at(0) ..< at(480)])
        let out = SleepEdit.recompute(baseSegments: base, times: times, coverage: held)
        XCTAssertTrue(out.containsAssertedTime)
        XCTAssertEqual(SleepProvenanceBreakdown(segments: out).assertedAsleep, 600, accuracy: 1,
                       "the 10 minutes past the last record are the user's claim")
    }

    func testAHalfRetainedNightPublishesTheUnREACHABLEHalfAndWithholdsTheProvenHole() {
        // RETENTION CUT THIS NIGHT IN TWO, and it cut the staging with it — both come from the same
        // archive, so the surviving base covers only the retained half (240→480). The user's window
        // still runs 0→490.
        //
        //   0   → 240  we hold no records AND cannot reach back that far  → UNKNOWN → published
        //   240 → 480  records, staged                                    → measured
        //   480 → 490  past our newest record, and we hold everything after it → proven hole
        let retainedBase = [SleepSegment(start: at(240), end: at(480), stage: .inBed),
                            SleepSegment(start: at(240), end: at(480), stage: .asleepCore)]
        let half = MeasuredCoverage(intervals: [at(240) ..< at(480)])
        let out = SleepEdit.recompute(baseSegments: retainedBase, times: times, coverage: half)
        let b = SleepProvenanceBreakdown(segments: out)

        XCTAssertEqual(b.unknownAsleep, 240 * 60, accuracy: 1,
                       "the pre-archive half is UNKNOWN, not a hole")
        XCTAssertEqual(b.assertedAsleep, 600, accuracy: 1, "only the tail is proven unmeasured")
        XCTAssertEqual(b.measuredAsleep, 240 * 60, accuracy: 1)
        XCTAssertEqual(b.displayedAsleep, 490 * 60, accuracy: 1, "the card total is untouched")
        XCTAssertEqual(b.unknownInBed, 240 * 60, accuracy: 1)

        // ⚠️ RE-BASELINED 2026-08-24. Health keeps the unknown half — that is still the whole point
        // of the third bucket, and it is still written UNLABELLED, because "we cannot say" is not
        // "she told us". What changed is the 10 proven minutes: they used to be withheld (and were
        // the only thing that could gate a delete), and are now published carrying the user-entered
        // tag. `withheldSpans` is therefore empty, which is exactly what the delete-exclusion
        // predicate must see — see `withheldSpans`' own note.
        let published = out.healthPublishable
        XCTAssertEqual(SleepStaging.totalAsleep(published), 490 * 60, accuracy: 1,
                       "the whole 490-minute window she asserted now reaches Health")
        XCTAssertEqual(SleepStaging.totalAsleep(out.healthUserEntered), 600, accuracy: 1,
                       "only the 10 PROVEN minutes are tagged; the unknown half is not hers to own")
        XCTAssertTrue(out.withheldSpans.isEmpty, "nothing withheld ⇒ nothing may be deleted")
    }
}

// MARK: - The kill switch

final class SleepEditProvenanceKillSwitchTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    /// A night with a base recording, an extension past it, and a bedtime-to-onset gap — i.e. every
    /// fill site in the file exercised at once.
    private var base: [SleepSegment] {
        [SleepSegment(start: at(0), end: at(120), stage: .inBed),
         SleepSegment(start: at(10), end: at(60), stage: .asleepCore),
         SleepSegment(start: at(60), end: at(90), stage: .asleepDeep),
         SleepSegment(start: at(90), end: at(120), stage: .asleepREM)]
    }
    private var times: SleepEdit.Times {
        SleepEdit.Times(inBedStart: at(-30), sleepOnset: at(5), sleepWake: at(300))
    }

    func testNilCoverageEmitsOnlyMeasuredSegments() {
        let out = SleepEdit.recompute(baseSegments: base, times: times, coverage: nil)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.provenance == .measured },
                      "the kill switch must leave every segment `.measured`")
        XCTAssertFalse(out.containsAssertedTime)
    }

    func testNilCoverageIsIdenticalToTheDefaultParameter() {
        // The default argument IS the kill switch — a caller that never heard of provenance gets
        // exactly master's behaviour.
        XCTAssertEqual(SleepEdit.recompute(baseSegments: base, times: times),
                       SleepEdit.recompute(baseSegments: base, times: times, coverage: nil))
    }

    func testFullCoverageProducesTheSameSPANSAsTheKillSwitch() {
        // Coverage that spans everything must not change the SHAPE of the night, only its labels.
        // (Adjacent same-stage pieces are not re-merged, so compare the union of spans per stage.)
        let full = MeasuredCoverage(intervals: [at(-1000) ..< at(1000)])
        let off = SleepEdit.recompute(baseSegments: base, times: times, coverage: nil)
        let on = SleepEdit.recompute(baseSegments: base, times: times, coverage: full)
        func spanByStage(_ segs: [SleepSegment]) -> [SleepStage: TimeInterval] {
            Dictionary(segs.map { ($0.stage, $0.duration) }, uniquingKeysWith: +)
        }
        XCTAssertEqual(spanByStage(off), spanByStage(on))
        XCTAssertFalse(on.containsAssertedTime, "fully-covered ground can never be `.asserted`")
    }

    func testWindowOverloadKillSwitchIsAlsoInert() {
        let w = SleepEdit.Window(inBedStart: at(-30), inBedEnd: at(300))
        let out = SleepEdit.recompute(baseSegments: base, window: w, coverage: nil)
        XCTAssertEqual(out, SleepEdit.recompute(baseSegments: base, window: w))
        XCTAssertTrue(out.allSatisfy { $0.provenance == .measured })
    }
}

// MARK: - The arithmetic

final class SleepProvenanceBreakdownTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    func testAssertedSleepIsExcludedFromDerivedNumbersButNotFromTheHeadline() {
        let segs = [
            SleepSegment(start: at(0), end: at(100), stage: .inBed),
            SleepSegment(start: at(100), end: at(400), stage: .inBed, provenance: .asserted),
            SleepSegment(start: at(0), end: at(100), stage: .asleepCore),
            SleepSegment(start: at(100), end: at(400), stage: .asleepCore, provenance: .asserted),
        ]
        let b = SleepProvenanceBreakdown(segments: segs)
        XCTAssertEqual(b.measuredAsleep, 100 * 60)
        XCTAssertEqual(b.assertedAsleep, 300 * 60)
        XCTAssertEqual(b.displayedAsleep, 400 * 60, "clause 1: the assertion wins for display")
        XCTAssertEqual(b.totalInBed, 400 * 60)
        XCTAssertEqual(b.coveredInBed, 100 * 60)
        XCTAssertEqual(b.coverageFraction, 0.25, accuracy: 1e-12)
        XCTAssertEqual(b.longestUnmeasuredGap, 300 * 60)
        XCTAssertNil(b.efficiency, "100 min of covered in-bed is below the ratio floor — withhold")
        XCTAssertFalse(b.isScorable)
    }

    func testAssertedOverMeasuredCountsNormally() {
        // The user relabelled ground the ring DID record. Their label wins and the ground is real,
        // so it belongs in both numerator and denominator. Getting this backwards would delete the
        // user's own corrections from their own statistics.
        let segs = [
            SleepSegment(start: at(0), end: at(600), stage: .inBed, provenance: .assertedOverMeasured),
            SleepSegment(start: at(0), end: at(480), stage: .asleepCore, provenance: .assertedOverMeasured),
            SleepSegment(start: at(480), end: at(600), stage: .awake, provenance: .assertedOverMeasured),
        ]
        let b = SleepProvenanceBreakdown(segments: segs)
        XCTAssertEqual(b.assertedAsleep, 0)
        XCTAssertEqual(b.measuredAsleep, 480 * 60)
        XCTAssertEqual(b.coverageFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(b.efficiency), 0.8, accuracy: 1e-12)
        XCTAssertTrue(b.isScorable)
    }

    func testUnstagedNightIsUnaffected() {
        // Every segment `SleepStaging.classify` emits is `.measured`, so an unedited night must
        // publish exactly what it published before provenance existed.
        let segs = [
            SleepSegment(start: at(0), end: at(480), stage: .inBed),
            SleepSegment(start: at(0), end: at(60), stage: .awake),
            SleepSegment(start: at(60), end: at(480), stage: .asleepCore),
        ]
        let b = SleepProvenanceBreakdown(segments: segs)
        XCTAssertFalse(b.hasAssertedTime)
        XCTAssertNil(b.withheldReason)
        XCTAssertEqual(b.coverageFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(b.efficiency), 420.0 / 480.0, accuracy: 1e-12)
        XCTAssertTrue(b.isScorable)
    }

    func testWithholdingCanBeTurnedOff() {
        let segs = [
            SleepSegment(start: at(0), end: at(400), stage: .inBed, provenance: .asserted),
            SleepSegment(start: at(0), end: at(400), stage: .asleepCore, provenance: .asserted),
        ]
        let b = SleepProvenanceBreakdown(segments: segs, tuning: .neverWithhold)
        XCTAssertTrue(b.isScorable)
        XCTAssertNil(b.efficiency, "no covered ground at all -> still nil; nil is not a threshold verdict")
        XCTAssertNil(b.withheldReason)
    }

    func testEfficiencyIsNeverZeroAsAWithholdSignal() {
        // ⚠️ LocalStore.swift:235 reads `inBed = efficiency > 0 ? asleep / efficiency : asleep + awake`.
        // A stored 0 is a live SENTINEL that silently rewrites in-bed for every downstream reader.
        // Withholding MUST be `nil`, never 0.
        let segs = [
            SleepSegment(start: at(0), end: at(400), stage: .inBed, provenance: .asserted),
            SleepSegment(start: at(0), end: at(400), stage: .asleepCore, provenance: .asserted),
        ]
        let b = SleepProvenanceBreakdown(segments: segs)
        XCTAssertNil(b.efficiency)
        if let e = b.efficiency { XCTAssertNotEqual(e, 0, "0 is the LocalStore:235 sentinel") }
    }
}

// MARK: - Codec

final class SleepHypnogramCodecProvenanceTests: XCTestCase {

    func testAllMeasuredNightEncodesToTheHISTORICALBYTES() {
        // The whole backward-compatibility story rests on this: an unedited night's stored bytes
        // must not change at all, so no install re-writes its history on upgrade.
        let segs = [
            SleepSegment(start: Date(timeIntervalSince1970: 1_700_000_000),
                         end: Date(timeIntervalSince1970: 1_700_000_150), stage: .asleepDeep),
            SleepSegment(start: Date(timeIntervalSince1970: 1_700_000_150),
                         end: Date(timeIntervalSince1970: 1_700_000_300), stage: .asleepCore),
        ]
        XCTAssertEqual(String(data: SleepHypnogramCodec.encode(segs), encoding: .utf8),
                       "[[1700000000,1700000150,3],[1700000150,1700000300,2]]")
    }

    func testProvenanceRoundTrips() {
        let segs = [
            SleepSegment(start: Date(timeIntervalSince1970: 1_700_000_000),
                         end: Date(timeIntervalSince1970: 1_700_000_150), stage: .asleepCore),
            SleepSegment(start: Date(timeIntervalSince1970: 1_700_000_150),
                         end: Date(timeIntervalSince1970: 1_700_000_300), stage: .asleepCore,
                         provenance: .asserted),
            SleepSegment(start: Date(timeIntervalSince1970: 1_700_000_300),
                         end: Date(timeIntervalSince1970: 1_700_000_450), stage: .awake,
                         provenance: .assertedOverMeasured),
        ]
        let data = SleepHypnogramCodec.encode(segs)
        XCTAssertEqual(String(data: data, encoding: .utf8),
                       "[[1700000000,1700000150,2],[1700000150,1700000300,2,1],[1700000300,1700000450,1,2]]")
        XCTAssertEqual(SleepHypnogramCodec.decode(data), segs)
    }

    func testLegacyThreeElementRowsDecodeAsMeasured() {
        let data = Data("[[1700000000,1700000150,3],[1700000150,1700000300,2]]".utf8)
        XCTAssertTrue(SleepHypnogramCodec.decode(data).allSatisfy { $0.provenance == .measured })
    }

    func testUnknownProvenanceCodeKeepsTheSegment() {
        // Losing a minute of real sleep is worse than losing its label.
        let data = Data("[[1700000000,1700000150,3,99]]".utf8)
        let out = SleepHypnogramCodec.decode(data)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.provenance, .measured)
        XCTAssertEqual(out.first?.stage, .asleepDeep)
    }

    func testFiveOrTwoElementRowsAreStillRefused() {
        XCTAssertEqual(SleepHypnogramCodec.decode(Data("[[1,2,3,1,9]]".utf8)), [])
        XCTAssertEqual(SleepHypnogramCodec.decode(Data("[[1700000000,1700000150]]".utf8)), [])
    }
}

// MARK: - SleepSegment Codable tolerance

final class SleepSegmentCodableProvenanceTests: XCTestCase {

    func testLegacyJSONWithoutProvenanceDecodes() throws {
        // `EpochArchiveStore.loadPendingSleepSegments` (:145) JSON-decodes `[SleepSegment]` written
        // by an EARLIER build. A strict decode would fail and the `?? []` fallback would silently
        // drop a drain's pending segments on the first launch after upgrade.
        let json = #"[{"start":757382400,"end":757386000,"stage":"asleepCore"}]"#
        let out = try JSONDecoder().decode([SleepSegment].self, from: Data(json.utf8))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.provenance, .measured)
    }

    func testMeasuredSegmentsEncodeWithoutTheProvenanceKey() throws {
        let seg = SleepSegment(start: Date(timeIntervalSince1970: 0),
                               end: Date(timeIntervalSince1970: 60), stage: .awake)
        let text = String(data: try JSONEncoder().encode([seg]), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("provenance"),
                       "a measured segment's JSON must stay readable by an older build")
    }

    func testAssertedSegmentRoundTrips() throws {
        let seg = SleepSegment(start: Date(timeIntervalSince1970: 0),
                               end: Date(timeIntervalSince1970: 60), stage: .asleepCore,
                               provenance: .asserted)
        let data = try JSONEncoder().encode([seg])
        XCTAssertEqual(try JSONDecoder().decode([SleepSegment].self, from: data), [seg])
    }
}


// MARK: - Decoding a label we do not recognise

final class SleepSegmentProvenanceDecodeTests: XCTestCase {

    /// A future (or corrupt) provenance string must cost the LABEL, never the SLEEP.
    /// `decodeIfPresent(SleepProvenance.self)` would throw, and one throw fails the whole array —
    /// which at `EpochArchiveStore.loadPendingSleepSegments`'s `?? []` silently drops a drain's
    /// pending segments.
    ///
    /// ⚠️ AND IT MUST NOT DEGRADE TO `.measured`. `encode(to:)` omits the key for `.measured`, so a
    /// PRESENT value was written to mean something else — reading it as "a sensor saw this span" is
    /// the one reading its writer ruled out, and it is how invented sleep reaches Apple Health.
    func testAnUnrecognisedProvenanceDegradesToCoverageUnknownInsteadOfFailingTheArray() throws {
        let json = """
        [{"start": 700000000, "end": 700003600, "stage": "asleepCore", "provenance": "fromTheFuture"},
         {"start": 700003600, "end": 700007200, "stage": "asleepDeep"}]
        """
        let segs = try JSONDecoder().decode([SleepSegment].self, from: Data(json.utf8))
        XCTAssertEqual(segs.count, 2, "one unreadable label must not drop two hours of sleep")
        XCTAssertEqual(segs.map(\.provenance), [.assertedCoverageUnknown, .measured],
                       "present-but-unreadable is 'we cannot say'; absent is measured")
        // Still published — the degrade costs a caveat, never the user's sleep.
        XCTAssertEqual(SleepStaging.totalAsleep(segs.healthPublishable), 7200, accuracy: 1)
        // …but never counted as a measurement.
        XCTAssertEqual(SleepProvenanceBreakdown(segments: segs).measuredAsleep, 3600, accuracy: 1)
    }

    /// A provenance value of the wrong TYPE must not fail the array either — `decodeIfPresent`
    /// throws on a type mismatch, and that throw would cost the whole drain's pending segments.
    func testAProvenanceOfTheWrongTypeCostsOnlyTheLabel() throws {
        let json = """
        [{"start": 700000000, "end": 700003600, "stage": "asleepCore", "provenance": 3},
         {"start": 700003600, "end": 700007200, "stage": "asleepDeep"}]
        """
        let segs = try JSONDecoder().decode([SleepSegment].self, from: Data(json.utf8))
        XCTAssertEqual(segs.count, 2, "a malformed label must not drop two hours of sleep")
        XCTAssertEqual(segs.map(\.provenance), [.assertedCoverageUnknown, .measured])
    }

    func testEveryKnownProvenanceStillRoundTrips() throws {
        let t = Date(timeIntervalSince1970: 700_000_000)
        for p in SleepProvenance.allCases {
            let seg = SleepSegment(start: t, end: t.addingTimeInterval(600), stage: .awake,
                                   provenance: p)
            let back = try JSONDecoder().decode(SleepSegment.self,
                                                from: try JSONEncoder().encode(seg))
            XCTAssertEqual(back, seg, "\(p.rawValue) did not survive a round trip")
        }
    }
}
