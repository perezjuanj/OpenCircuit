// THE THREE EXPORT CLAIMS WE COULD NOT SUPPORT, AND THE ASSERTIONS THAT KEEP THEM SUPPORTED.
//
// Each block below pins one defect from the 2026-08-26 tester investigation:
//   1. `coverageFraction` is measured over a window whose right edge IS the last record, so it is
//      STRUCTURALLY incapable of falling when the recording stops at the wake. Proven here by
//      construction rather than argued: the same records score 1.0000/no-gaps against the detected
//      window and well under 1 against a wake the recording did not define.
//   2. `edgeProvenance` mixed two frames of reference — recorded-window coverage against post-edit
//      totals — with nothing in the file saying which. `durationBasis` now says.
//   3. `measuredAwakeSec` counted a wearer's own awake label over recorded ground as a measurement.
//
// ⚠️ THE INPUTS HERE ARE SYNTHETIC, and deliberately so: what is being tested is arithmetic and
// serialization, not fidelity to a night. The REAL-fixture version of claim 1 — the same
// falsifiability proof driven by a device-proven tester night's committed recording spans — lives in
// `SleepProvenanceTesterNightTests.testCoverageInTheDetectedWindowCannotSeeTheFourHourHole`. No
// number in this file is quoted as a measurement of anything.

import XCTest
@testable import OpenCircuitKit

final class ExportHonestyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// One heart-rate instant every 150 s (the ring's own epoch step) across `[from, to)`.
    private func epochs(from: Date, to: Date) -> [Date] {
        var out: [Date] = []
        var t = from
        while t < to {
            out.append(t)
            t = t.addingTimeInterval(150)
        }
        return out
    }

    // MARK: - 1. The detected window cannot falsify itself

    func testDetectedWindowCoverageIsPerfectOnANightWhoseRecordingStoppedAtTheWake() throws {
        // Six hours of unbroken epochs, and then nothing. The detected window is what the staging
        // built out of those epochs, so it ENDS where they end.
        let detectedStart = at(0)
        let detectedEnd = at(360)
        let witness = epochs(from: detectedStart, to: detectedEnd)

        let detected = ExportCoverage.assess(sampleTimes: witness,
                                             from: detectedStart, to: detectedEnd)
        XCTAssertEqual(detected.coverageFraction, 1.0, accuracy: 1e-9,
                       "the window is defined by the records, so it is always full of them")
        XCTAssertTrue(detected.gaps.isEmpty,
                      "and the four missing hours are OUTSIDE it, so there is nothing to report")

        // The wearer's schedule says she gets up at +600 min. Nothing about that instant came from
        // the recording, which is the only property that makes the next number able to fall.
        let reference = try XCTUnwrap(ExportReferenceCoverage.assess(
            sampleTimes: witness, detectedStart: detectedStart, detectedEnd: detectedEnd,
            referenceEnd: at(600), reference: .manualScheduleWake))

        XCTAssertEqual(reference.assessment.coverageFraction, 360.0 / 600.0, accuracy: 0.01,
                       "six recorded hours out of the ten she says she was in bed")
        XCTAssertEqual(reference.assessment.gaps.count, 1)
        XCTAssertEqual(reference.assessment.gaps.first?.seconds ?? 0, 240 * 60, accuracy: 150,
                       "the hole the detected window could not see, now inside the window")
        XCTAssertEqual(reference.beyondDetectedEndSeconds, 240 * 60, accuracy: 1e-9)
        XCTAssertLessThan(reference.assessment.coverageFraction, detected.coverageFraction,
                          "the whole point: one of these two numbers can be wrong")
    }

    func testAFullyCoveredNightScoresTheSameAgainstBothWindows() throws {
        // The mirror case, and the one that stops the new number being a permanent accusation: when
        // the recording really does run to the reference, both measurements agree.
        let start = at(0)
        let wake = at(480)
        let reference = try XCTUnwrap(ExportReferenceCoverage.assess(
            sampleTimes: epochs(from: start, to: wake), detectedStart: start, detectedEnd: wake,
            referenceEnd: wake, reference: .manualScheduleWake))
        XCTAssertEqual(reference.assessment.coverageFraction, 1.0, accuracy: 1e-9)
        XCTAssertTrue(reference.assessment.gaps.isEmpty)
        XCTAssertEqual(reference.beyondDetectedEndSeconds, 0, accuracy: 1e-9)
    }

    func testAReferenceEarlierThanTheDetectedEndIsStillPublishedWithANegativeDelta() throws {
        // A wearer who slept past their schedule. The measurement is over a SHORTER span than the
        // detected window and is not comparable with it — so it is published with the sign that says
        // so, rather than dropped because it flatters nobody.
        let start = at(0)
        let detectedEnd = at(480)
        let reference = try XCTUnwrap(ExportReferenceCoverage.assess(
            sampleTimes: epochs(from: start, to: detectedEnd),
            detectedStart: start, detectedEnd: detectedEnd,
            referenceEnd: at(400), reference: .manualScheduleWake))
        XCTAssertEqual(reference.beyondDetectedEndSeconds, -80 * 60, accuracy: 1e-9)
    }

    func testAReferenceAtOrBeforeTheBedtimeIsRefusedRatherThanMeasuredAsZero() {
        // A non-positive window has no denominator, and 0 would read as a total outage.
        XCTAssertNil(ExportReferenceCoverage.assess(
            sampleTimes: epochs(from: at(0), to: at(60)),
            detectedStart: at(0), detectedEnd: at(60),
            referenceEnd: at(0), reference: .manualScheduleWake))
    }

    // MARK: - 1b. Both names, and the explicit "could not check"

    func testCoverageEmitsTheHonestNameBesideTheShippedOne() {
        let coverage = ExportCoverage.assess(sampleTimes: epochs(from: at(0), to: at(360)),
                                             from: at(0), to: at(360))
        let obj = json(session(coverage: coverage))
        guard let block = obj["coverage"] as? [String: Any] else {
            return XCTFail("coverage block missing")
        }
        XCTAssertEqual(block["coverageWithinDetectedWindow"] as? Double,
                       block["coverageFraction"] as? Double,
                       "same number, and the second name is the one that states its frame")
        XCTAssertNotNil(block["coverageFraction"],
                        "the shipped key stays: the schema version is unchanged and these files are "
                        + "already in third-party hands")
    }

    func testAnUnavailableReferenceIsSaidOutLoudRatherThanOmitted() {
        // The defect in miniature: "the check found nothing wrong" and "the check could not run"
        // must not serialize identically.
        let coverage = ExportCoverage.assess(sampleTimes: epochs(from: at(0), to: at(360)),
                                             from: at(0), to: at(360))
        let obj = json(session(coverage: coverage,
                               referenceCoverage: .unavailable(
                                   reason: ExportReferenceCoverage.Outcome.noManualSleepSchedule)))
        guard let block = obj["referenceCoverage"] as? [String: Any] else {
            return XCTFail("referenceCoverage must be emitted even when there is no reference")
        }
        XCTAssertTrue(block["reference"] is NSNull, "null, not a fabricated denominator")
        XCTAssertEqual(block["unavailableReason"] as? String, "noManualSleepSchedule")
        XCTAssertNil(block["coverageToReference"], "nothing was measured, so nothing is reported")
    }

    func testTheCSVAlwaysSaysWhetherTheReferenceCheckCouldRun() throws {
        let coverage = ExportCoverage.assess(sampleTimes: epochs(from: at(0), to: at(360)),
                                             from: at(0), to: at(360))
        func sourceColumn(_ row: ExportEngine.SleepSessionRow) -> String {
            ExportEngineTests.parseCSV(ExportEngine.sleepSessionsCSV([row]))[1][31]
        }
        XCTAssertEqual(sourceColumn(session(coverage: coverage,
                                            referenceCoverage: .unavailable(reason: "x"))), "none")
        let measured = try XCTUnwrap(ExportReferenceCoverage.assess(
            sampleTimes: epochs(from: at(0), to: at(360)),
            detectedStart: at(0), detectedEnd: at(360),
            referenceEnd: at(600), reference: .manualScheduleWake))
        XCTAssertEqual(sourceColumn(session(coverage: coverage,
                                            referenceCoverage: .measured(measured))),
                       "manualScheduleWake")
        XCTAssertEqual(sourceColumn(session()), "",
                       "a night with no coverage window at all has nothing to say either way")
    }

    // MARK: - 2. One frame of reference per block, and it is named

    func testEdgeProvenanceStatesWhichNightsTotalsFedTheDurationVerdict() {
        let assessment = SleepConfidence.assess(asleep: 7 * 3600, inBed: 8 * 3600, coverage: nil)
        let recorded = ExportEngine.SleepEdgeProvenanceRow(
            windowStart: at(0), windowEnd: at(480), assessment: assessment)
        XCTAssertEqual(recorded.durationBasis, "recorded",
                       "the default is the frame the EDGES are measured in")
        let edited = ExportEngine.SleepEdgeProvenanceRow(
            windowStart: at(0), windowEnd: at(480), assessment: assessment,
            durationBasis: ExportEngine.SleepEdgeProvenanceRow.durationBasisEdited)
        let block = json(session(edgeProvenance: edited))["edgeProvenance"] as? [String: Any]
        XCTAssertEqual(block?["durationBasis"] as? String, "edited")
    }

    // MARK: - 3. An assertion is not a measurement

    func testAWearersAwakePaintOverRecordedGroundIsNoLongerCalledMeasured() {
        // The shape of the tester night: the only `.awake` block on the night is her own label,
        // sitting on ground the ring DID record. It used to be published as `measuredAwakeSec`.
        let segments = [
            SleepSegment(start: at(0), end: at(480), stage: .inBed,
                         provenance: .assertedOverMeasured),
            SleepSegment(start: at(0), end: at(35), stage: .awake,
                         provenance: .assertedOverMeasured),
            SleepSegment(start: at(35), end: at(480), stage: .asleepCore),
        ]
        let b = SleepProvenanceBreakdown(segments: segments)
        XCTAssertEqual(b.measuredAwake, 0,
                       "the ring's own staging called none of this awake")
        XCTAssertEqual(b.assertedOverMeasuredAwake, 35 * 60,
                       "her 35 minutes to fall asleep, named as hers")
        XCTAssertEqual(b.displayedAwake, 35 * 60,
                       "clause 1 is untouched — the card still shows every minute of it")
    }

    func testTheAwakeBucketsStillCloseOnTheDisplayedTotal() {
        let segments = [
            SleepSegment(start: at(0), end: at(400), stage: .inBed),
            SleepSegment(start: at(0), end: at(10), stage: .awake),
            SleepSegment(start: at(10), end: at(30), stage: .awake, provenance: .assertedOverMeasured),
            SleepSegment(start: at(30), end: at(70), stage: .awake, provenance: .asserted),
            SleepSegment(start: at(70), end: at(150), stage: .awake,
                         provenance: .assertedCoverageUnknown),
            SleepSegment(start: at(150), end: at(400), stage: .asleepCore),
        ]
        let b = SleepProvenanceBreakdown(segments: segments)
        XCTAssertEqual(b.measuredAwake + b.assertedOverMeasuredAwake
                        + b.assertedAwake + b.unknownAwake,
                       b.displayedAwake, accuracy: 1e-9)
        XCTAssertEqual(b.measuredAwake, 10 * 60)
        XCTAssertEqual(b.assertedOverMeasuredAwake, 20 * 60)
        XCTAssertEqual(b.assertedAwake, 40 * 60)
        XCTAssertEqual(b.unknownAwake, 80 * 60)
    }

    func testTheAsleepSubTotalIsASubsetAndMovesNoPublishedNumber() {
        // `measuredAsleep` stays the efficiency numerator — narrowing it would move a health number.
        // The relabelled part is STATED instead, and stating it must not change the arithmetic.
        let segments = [
            SleepSegment(start: at(0), end: at(600), stage: .inBed),
            SleepSegment(start: at(0), end: at(300), stage: .asleepCore),
            SleepSegment(start: at(300), end: at(600), stage: .asleepCore,
                         provenance: .assertedOverMeasured),
        ]
        let b = SleepProvenanceBreakdown(segments: segments)
        XCTAssertEqual(b.measuredAsleep, 600 * 60, "unchanged: both halves sit on recorded ground")
        XCTAssertEqual(b.assertedOverMeasuredAsleep, 300 * 60, "and half of it carries her label")
        XCTAssertEqual(b.displayedAsleep, b.measuredAsleep + b.assertedAsleep + b.unknownAsleep,
                       "the subset must not appear in the sum")
        XCTAssertEqual(try XCTUnwrap(b.efficiency), 1.0, accuracy: 1e-12)
    }

    func testPerStageAssertedTotalsCountOnlyProvableHoles() {
        // What the Sleep card hatches. `.assertedCoverageUnknown` is excluded on purpose — it
        // behaves exactly as this app behaved before provenance existed, and marking it would put a
        // caveat on every night older than the ~30 h epoch archive.
        let segments = [
            SleepSegment(start: at(0), end: at(300), stage: .inBed),
            SleepSegment(start: at(0), end: at(100), stage: .asleepCore, provenance: .asserted),
            SleepSegment(start: at(100), end: at(140), stage: .asleepDeep, provenance: .asserted),
            SleepSegment(start: at(140), end: at(170), stage: .asleepREM, provenance: .asserted),
            SleepSegment(start: at(170), end: at(200), stage: .asleepCore,
                         provenance: .assertedCoverageUnknown),
            SleepSegment(start: at(200), end: at(300), stage: .asleepCore),
        ]
        let b = SleepProvenanceBreakdown(segments: segments)
        XCTAssertEqual(b.assertedLight, 100 * 60)
        XCTAssertEqual(b.assertedDeep, 40 * 60)
        XCTAssertEqual(b.assertedREM, 30 * 60)
        XCTAssertEqual(b.assertedAwake, 0)
    }

    func testAnUneditedNightHatchesNothingAndPublishesNoProvenanceSummary() {
        // `SleepStaging.classify` emits only `.measured`, so the card and the export are unchanged
        // for every night nobody corrected. This is the inertness lock for all of the above.
        let segments = [
            SleepSegment(start: at(0), end: at(480), stage: .inBed),
            SleepSegment(start: at(0), end: at(20), stage: .awake),
            SleepSegment(start: at(20), end: at(480), stage: .asleepCore),
        ]
        let b = SleepProvenanceBreakdown(segments: segments)
        XCTAssertFalse(b.hasAssertedTime)
        XCTAssertEqual(b.assertedLight + b.assertedDeep + b.assertedREM + b.assertedAwake, 0)
        XCTAssertEqual(b.assertedOverMeasuredAwake, 0)
        XCTAssertEqual(b.assertedOverMeasuredAsleep, 0)
        XCTAssertEqual(b.measuredAwake, 20 * 60)
        XCTAssertNil(json(session(hypnogram: segments))["provenanceSummary"],
                     "no summary is emitted for a night with nothing to qualify")
    }

    func testTheProvenanceSummaryPublishesBothSidesOfTheSplit() {
        let segments = [
            SleepSegment(start: at(0), end: at(400), stage: .inBed),
            SleepSegment(start: at(0), end: at(30), stage: .awake, provenance: .assertedOverMeasured),
            SleepSegment(start: at(30), end: at(200), stage: .asleepCore),
            SleepSegment(start: at(200), end: at(400), stage: .asleepCore, provenance: .asserted),
        ]
        guard let summary = json(session(hypnogram: segments))["provenanceSummary"]
                as? [String: Any] else {
            return XCTFail("an asserted night must publish its split")
        }
        XCTAssertEqual(summary["measuredAwakeSec"] as? Double, 0)
        XCTAssertEqual(summary["assertedOverMeasuredAwakeSec"] as? Double, 30 * 60)
        XCTAssertEqual(summary["assertedOverMeasuredAsleepSec"] as? Double, 0)
        XCTAssertEqual(summary["measuredAsleepSec"] as? Double, 170 * 60)
        XCTAssertEqual(summary["assertedAsleepSec"] as? Double, 200 * 60)
    }

    func testTheNotesNameEveryClaimThisFilePins() {
        let notes = json(session())["notes"] as? [String: String]
        XCTAssertTrue(notes?["coverage"]?.contains("coverageWithinDetectedWindow") == true)
        XCTAssertTrue(notes?["referenceCoverage"]?.contains("manualScheduleWake") == true)
        XCTAssertTrue(notes?["referenceCoverage"]?.contains("REFERENCE and not a") == true,
                      "it must not be presented as ground truth")
        XCTAssertTrue(notes?["provenanceSummary"]?.contains("OVER GROUND THE RING RECORDED") == true)
        XCTAssertTrue(notes?["edgeProvenance"]?.contains("durationBasis") == true)
    }

    // MARK: - Fixtures

    private func session(hypnogram: [SleepSegment] = [],
                         coverage: ExportCoverage.Assessment? = nil,
                         referenceCoverage: ExportReferenceCoverage.Outcome? = nil,
                         edgeProvenance: ExportEngine.SleepEdgeProvenanceRow? = nil)
        -> ExportEngine.SleepSessionRow {
        ExportEngine.SleepSessionRow(
            sessionID: "night-test", night: t0,
            inBedStart: at(0), inBedEnd: at(480),
            hypnogram: hypnogram,
            summary: ExportEngine.SleepRow(night: t0, asleepMin: 420, deepMin: 60, lightMin: 300,
                                           remMin: 60, awakeMin: 60, efficiency: 0.875,
                                           skinTempC: 34.0, sleepScore: 80, stressScore: 30),
            coverage: coverage,
            referenceCoverage: referenceCoverage,
            edgeProvenance: edgeProvenance)
    }

    /// The whole JSON bundle for one session, parsed. Session keys are read out of
    /// `sleepSessions[0]`; top-level keys (`notes`) straight off the root.
    private func json(_ row: ExportEngine.SleepSessionRow) -> [String: Any] {
        guard let text = ExportEngine.toJSON(samples: [], sleep: [], daily: [],
                                             now: t0, sleepSessions: [row]),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("the bundle must serialize")
            return [:]
        }
        var merged = (root["sleepSessions"] as? [[String: Any]])?.first ?? [:]
        for (key, value) in root where merged[key] == nil { merged[key] = value }
        return merged
    }
}
