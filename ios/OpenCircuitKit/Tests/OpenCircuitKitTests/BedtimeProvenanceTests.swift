import XCTest
@testable import OpenCircuitKit

/// The night this exists for (#193 → #198): the ring charged 22:19:38–22:35:12 on 2026-08-08,
/// records resume 22:36:18, and the app prints 22:36:18 as "bedtime" with no qualification.
/// The classifier must call that edge what it is — a resumption — without inventing a cause.
final class BedtimeProvenanceTests: XCTestCase {

    /// 2026-08-08 22:36:18 local, the real resumption instant from #193.
    private let resumed = Date(timeIntervalSince1970: 1_786_602_978)
    private func t(_ offsetFromResumed: TimeInterval) -> Date {
        resumed.addingTimeInterval(offsetFromResumed)
    }

    // MARK: The #198 night

    func testTheChargeCycleNightIsNotWitnessed() {
        // Last wrist HR before the charge cycle: 22:19:38 is 16m40s (1000 s) before the resume.
        let verdict = BedtimeProvenance.classify(
            inBedStart: resumed,
            lastMeasurementBefore: t(-1000),
            earliestRetainedMeasurement: t(-14 * 86_400))
        XCTAssertEqual(verdict, .resumedAfterGap(1000))
        XCTAssertTrue(BedtimeProvenance.needsQualification(verdict))
    }

    // MARK: Continuity

    func testUnbrokenStreamIsWitnessed() {
        // One epoch (150 s) before the edge — an intact stream.
        let verdict = BedtimeProvenance.classify(
            inBedStart: resumed,
            lastMeasurementBefore: t(-150),
            earliestRetainedMeasurement: t(-14 * 86_400))
        XCTAssertEqual(verdict, .witnessed)
        XCTAssertFalse(BedtimeProvenance.needsQualification(verdict))
    }

    func testOneDroppedEpochStillCountsAsContinuous() {
        // Two cadences: a single unparsed/dropped epoch must not be reported to the user as a gap.
        let verdict = BedtimeProvenance.classify(
            inBedStart: resumed,
            lastMeasurementBefore: t(-BedtimeProvenance.continuousToleranceSeconds),
            earliestRetainedMeasurement: t(-14 * 86_400))
        XCTAssertEqual(verdict, .witnessed)
    }

    func testJustBeyondToleranceIsAGap() {
        let verdict = BedtimeProvenance.classify(
            inBedStart: resumed,
            lastMeasurementBefore: t(-BedtimeProvenance.continuousToleranceSeconds - 1),
            earliestRetainedMeasurement: t(-14 * 86_400))
        XCTAssertEqual(verdict, .resumedAfterGap(BedtimeProvenance.continuousToleranceSeconds + 1))
    }

    func testToleranceIsBoundedByTheEpochCadence() {
        // The documented rationale is "two 150 s cadences". A future edit that inflates this would
        // start calling real multi-epoch gaps "witnessed".
        XCTAssertEqual(BedtimeProvenance.continuousToleranceSeconds, 300)
    }

    // MARK: Absence vs non-retention — the distinction that must not collapse

    func testNoPriorMeasurementWithDeepRetentionIsEvidence() {
        let verdict = BedtimeProvenance.classify(
            inBedStart: resumed,
            lastMeasurementBefore: nil,
            earliestRetainedMeasurement: t(-7 * 86_400))
        XCTAssertEqual(verdict, .noPriorMeasurement)
        XCTAssertTrue(BedtimeProvenance.needsQualification(verdict))
    }

    func testNoPriorMeasurementAtTheRetentionEdgeIsUnknown() {
        // The oldest row we hold sits INSIDE the evidence window, so the absence of anything
        // earlier says nothing about the wearer — it says our retention stops there.
        let verdict = BedtimeProvenance.classify(
            inBedStart: resumed,
            lastMeasurementBefore: nil,
            earliestRetainedMeasurement: t(-BedtimeProvenance.priorEvidenceWindowSeconds + 1))
        XCTAssertEqual(verdict, .unknown)
    }

    func testEmptyStoreIsUnknownNotWitnessed() {
        let verdict = BedtimeProvenance.classify(
            inBedStart: resumed, lastMeasurementBefore: nil, earliestRetainedMeasurement: nil)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertTrue(BedtimeProvenance.needsQualification(verdict),
                      "'we did not look' must never render as an unqualified measured bedtime")
    }

    // MARK: Caller hazards

    func testMeasurementAtOrAfterTheEdgeIsUnknownNotANegativeGap() {
        for offset in [0.0, 60.0] {
            let verdict = BedtimeProvenance.classify(
                inBedStart: resumed,
                lastMeasurementBefore: t(offset),
                earliestRetainedMeasurement: t(-14 * 86_400))
            XCTAssertEqual(verdict, .unknown, "offset \(offset) must not produce a negative gap")
        }
    }

    // MARK: The qualification rule

    func testOnlyWitnessedEarnsAnUnqualifiedBedtime() {
        XCTAssertFalse(BedtimeProvenance.needsQualification(.witnessed))
        XCTAssertTrue(BedtimeProvenance.needsQualification(.resumedAfterGap(600)))
        XCTAssertTrue(BedtimeProvenance.needsQualification(.noPriorMeasurement))
        XCTAssertTrue(BedtimeProvenance.needsQualification(.unknown))
    }
}
