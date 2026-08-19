import XCTest
@testable import OpenCircuitKit

/// `SleepConfidence.assess` adds the acquisition question — did the recording cover the night? — to
/// the duration question, without moving the duration answer.
///
/// The numbers below are the corpus's own, replayed on master `f042639`:
///
///   night           in-bed   eff      worst edge err   what shipped says today
///   R2_2026-08-18   253 min  0.9873   −246 min         nothing (under the 5 h gate)
///   R2_2026-08-17   102 min  1.0000   −246 min         nothing (under the 5 h gate)
///   R3_2026-08-15   558 min  0.9534   −8 min           `.durationLikelyHigh`  ← the ONLY labelled
///                                                        night it fires on, and it is the GOOD one
final class SleepConfidenceCoverageTests: XCTestCase {

    private func mins(_ m: Double) -> TimeInterval { m * 60 }

    /// 2026-08-18 02:37:02 +02:00 — `R2_2026-08-18`'s detected in-bed end.
    private let end = Date(timeIntervalSince1970: 1_787_013_422)
    /// 2026-08-17 22:24:25 +02:00 — the same night's detected in-bed start (253 min earlier).
    private var start: Date { end.addingTimeInterval(-mins(252.6167)) }

    private func coverage(before: TimeInterval?,
                          after: TimeInterval?,
                          earliestDaysBack: Double = 14) -> SleepConfidence.Coverage {
        SleepConfidence.Coverage(
            inBedStart: start,
            inBedEnd: end,
            lastMeasurementBeforeStart: before.map { start.addingTimeInterval(-$0) },
            firstMeasurementAfterEnd: after.map { end.addingTimeInterval($0) },
            earliestRetainedMeasurement: start.addingTimeInterval(-earliestDaysBack * 86_400))
    }

    // MARK: - The nights this exists for

    func testTruncatedNightReportsTheGapNotAnOverCount() {
        // R2_2026-08-18 exactly: 253 min in bed at 0.9873, recording resumes 241.9 min later.
        let a = SleepConfidence.assess(asleep: mins(249), inBed: mins(253),
                                       coverage: coverage(before: 150, after: 14_515))
        XCTAssertEqual(a.reasons, [.noRecordingAfterWake(from: end, silentFor: 14_515)])
        XCTAssertTrue(a.hasAcquisitionReason)
        // And the legacy verdict is untouched — .normal, because 253 min is under the 5 h gate.
        XCTAssertEqual(a.level, .normal)
        XCTAssertEqual(a.wake, .stoppedThenResumed(14_515))
    }

    func testShortTruncatedNightStillFlagsBecauseTheGateIsDurationOnly() {
        // R2_2026-08-17: 102 min in bed at efficiency 1.0000 — three times below minNightForFlag.
        // "Nothing was recorded for 4 hours after this" is exactly as true of a 102-minute night as
        // of a 9-hour one, so the acquisition test must NOT inherit the duration test's length gate.
        let a = SleepConfidence.assess(asleep: mins(102), inBed: mins(102),
                                       coverage: coverage(before: nil, after: 14_616))
        XCTAssertTrue(a.flags)
        XCTAssertLessThan(mins(102), SleepConfidence.minNightForFlag)
    }

    func testTheGoodNightStaysSilentOnAcquisition() {
        // R3_2026-08-15, worst edge error 8 min: the corpus's ONE accurate labelled night. Its
        // trailing edge is a data edge like every other night's (all 21 are), but the stream is
        // dense on both sides — so no acquisition reason may fire. A flag here is worse than none.
        let a = SleepConfidence.assess(asleep: mins(532), inBed: mins(558),
                                       coverage: coverage(before: 90, after: 90))
        XCTAssertFalse(a.hasAcquisitionReason)
        XCTAssertEqual(a.wake, .witnessed)
        XCTAssertEqual(a.bedtime, .witnessed)
    }

    func testStagingErrorNightIsADesignedFalseNegative() {
        // R3_2026-08-19: −119 min at the FRONT with dense data on both edges (0.5 min before,
        // 1.5 min after). That is a STAGING miss, not an acquisition one, and an acquisition flag
        // must be silent there. Anyone quoting this rule's hit rate has to say so.
        let a = SleepConfidence.assess(asleep: mins(713), inBed: mins(768),
                                       coverage: coverage(before: 30, after: 90))
        XCTAssertFalse(a.flags, "no acquisition reason, and eff 0.9277 is under implausibleEfficiency")
    }

    // MARK: - The duration verdict is preserved, and yields

    func testLevelIsAlwaysExactlyTheLegacyClassification() {
        // Every combination of totals × coverage must leave `level` equal to the shipped primitive.
        let totals: [(Double, Double)] = [(572, 579), (553, 629), (68, 70), (249, 253), (0, 0)]
        let covers: [SleepConfidence.Coverage?] = [
            nil,
            coverage(before: 150, after: 150),
            coverage(before: 14_515, after: 14_515),
            coverage(before: nil, after: nil),
        ]
        for (asleep, inBed) in totals {
            for c in covers {
                XCTAssertEqual(
                    SleepConfidence.assess(asleep: mins(asleep), inBed: mins(inBed), coverage: c).level,
                    SleepConfidence.classify(asleep: mins(asleep), inBed: mins(inBed)),
                    "coverage must never move the duration verdict (\(asleep)/\(inBed))")
            }
        }
    }

    func testNoCoverageReducesToTheLegacyVerdict() {
        let flagged = SleepConfidence.assess(asleep: mins(572), inBed: mins(579), coverage: nil)
        XCTAssertEqual(flagged.reasons, [.durationLikelyHigh])
        XCTAssertEqual(flagged.bedtime, .unknown)
        XCTAssertEqual(flagged.wake, .unknown)

        let quiet = SleepConfidence.assess(asleep: mins(553), inBed: mins(629), coverage: nil)
        XCTAssertFalse(quiet.flags)
    }

    func testAcquisitionSuppressesTheOppositeClaim() {
        // A 9.5 h night at 98.8 % efficiency whose recording ALSO stopped for 4 h. Both tests fire;
        // only one may be shown, because "your duration reads high" and "4 hours are missing" are
        // contradictory statements about the same night.
        let a = SleepConfidence.assess(asleep: mins(572), inBed: mins(579),
                                       coverage: coverage(before: 150, after: 14_515))
        XCTAssertEqual(a.level, .durationLikelyHigh, "the legacy verdict is still reported")
        XCTAssertFalse(a.reasons.contains(.durationLikelyHigh), "but it is not offered as copy")
        XCTAssertEqual(a.primary, .noRecordingAfterWake(from: end, silentFor: 14_515))
    }

    // MARK: - Precedence and multiplicity

    func testBothEdgesHoleyReportsBothBackEdgeFirst() {
        let a = SleepConfidence.assess(asleep: mins(249), inBed: mins(253),
                                       coverage: coverage(before: 14_478, after: 14_515))
        XCTAssertEqual(a.reasons, [
            .noRecordingAfterWake(from: end, silentFor: 14_515),
            .noRecordingBeforeBedtime(until: start, silentFor: 14_478),
        ], "the back edge leads: it is where both 246-min corpus errors are and it has no other surface")
    }

    func testReasonsCarryTheInstantTheCopyWillPrint() {
        // The point of the whole exercise: "no recording after 02:37 for about 4 hours", not "this
        // night may be incomplete". The instant is the detected edge, i.e. the wake the card already
        // prints — so the caveat and the headline cannot disagree.
        guard case .noRecordingAfterWake(let at, let gap)? =
                SleepConfidence.assess(asleep: mins(249), inBed: mins(253),
                                       coverage: coverage(before: 150, after: 14_515)).primary else {
            return XCTFail("expected a back-edge gap reason")
        }
        XCTAssertEqual(at, end)
        XCTAssertEqual(gap, 14_515, accuracy: 0.001)
    }

    // MARK: - Threshold behaviour

    func testSubMaterialGapsProduceNothing() {
        // 7.5 min (R2_2026-08-02) and 33.0 min (R5_2026-08-11) are real gaps that the corpus cannot
        // adjudicate — neither is labelled. They must not reach the user at the default cut.
        for gapMinutes in [7.5, 33.0] {
            let a = SleepConfidence.assess(asleep: mins(249), inBed: mins(253),
                                           coverage: coverage(before: nil, after: gapMinutes * 60))
            XCTAssertFalse(a.flags, "\(gapMinutes) min must stay under the default material cut")
        }
    }

    func testKillSwitchSilencesAcquisitionEntirely() {
        let a = SleepConfidence.assess(asleep: mins(249), inBed: mins(253),
                                       coverage: coverage(before: 14_478, after: 14_515),
                                       materialGapSeconds: .infinity)
        XCTAssertFalse(a.flags)
        XCTAssertEqual(a.wake, .stoppedThenResumed(14_515), "the measurement is still reported")
    }

    func testZeroThresholdIsMaximallyLoudForSweeps() {
        let a = SleepConfidence.assess(asleep: mins(249), inBed: mins(253),
                                       coverage: coverage(before: 301, after: 301),
                                       materialGapSeconds: 0)
        XCTAssertEqual(a.reasons.count, 2)
    }

    func testUnknownEdgesNeverFlagAtAnyThreshold() {
        // 6 of 21 corpus nights have nothing after the in-bed end at all. "The ring stopped" and
        // "you synced at wake" are the same picture, so this branch ships silent — even at 0.
        for threshold in [0.0, WakeProvenance.materialGapSeconds] {
            let a = SleepConfidence.assess(asleep: mins(249), inBed: mins(253),
                                           coverage: coverage(before: nil, after: nil,
                                                              earliestDaysBack: 0),
                                           materialGapSeconds: threshold)
            XCTAssertFalse(a.hasAcquisitionReason, "threshold \(threshold)")
            XCTAssertEqual(a.wake, .unknown)
        }
    }

    // MARK: - Summary overload

    func testSummaryOverloadMatchesThePrimitive() {
        let s = SleepStaging.Summary(inBed: mins(253), awake: mins(4),
                                     light: mins(160), deep: mins(40), rem: mins(49))
        let c = coverage(before: 150, after: 14_515)
        XCTAssertEqual(SleepConfidence.assess(s, coverage: c),
                       SleepConfidence.assess(asleep: s.totalAsleep, inBed: s.inBed, coverage: c))
    }
}
