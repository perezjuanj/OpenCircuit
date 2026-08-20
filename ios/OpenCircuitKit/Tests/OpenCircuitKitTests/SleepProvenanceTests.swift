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
        XCTAssertEqual(MeasuredCoverage.empty.partition(at(0) ..< at(1000)).first?.measured, false)
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
