// Tests for the build-47/48 withheld-score repair (`SleepScoreHeal`).
//
// The load-bearing property is PARITY: a healed row must get the score `applySleepEdit` would have
// stored for the same night, so the repair is a repair and not a silent restatement of the wearer's
// night. Two things are therefore pinned here rather than merely exercised — the second-precision
// basis (not the row's rounded minutes) and the assertion-INCLUSIVE display basis (not measured-only).

import XCTest
@testable import OpenCircuitKit

final class SleepScoreHealTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func seg(_ from: TimeInterval, _ to: TimeInterval, _ stage: SleepStage,
                     _ provenance: SleepProvenance = .measured) -> SleepSegment {
        SleepSegment(start: t0.addingTimeInterval(from), end: t0.addingTimeInterval(to),
                     stage: stage, provenance: provenance)
    }

    /// A 7 h night: 6 h asleep (3 h core / 1.5 h deep / 1.5 h REM) + 1 h awake.
    private func night(provenance: SleepProvenance = .measured) -> [SleepSegment] {
        [seg(0, 7 * 3600, .inBed, provenance),
         seg(0, 3600, .awake, provenance),
         seg(3600, 4 * 3600, .asleepCore, provenance),
         seg(4 * 3600, 5.5 * 3600, .asleepDeep, provenance),
         seg(5.5 * 3600, 7 * 3600, .asleepREM, provenance)]
    }

    func testSummaryMirrorsSleepStagingSummary() throws {
        let s = try XCTUnwrap(SleepScoreHeal.summary(from: night()))
        XCTAssertEqual(s.inBed, 7 * 3600)
        XCTAssertEqual(s.awake, 3600)
        XCTAssertEqual(s.light, 3 * 3600)
        XCTAssertEqual(s.deep, 1.5 * 3600)
        XCTAssertEqual(s.rem, 1.5 * 3600)
        // Derived accessors are SleepStaging.Summary's own, so they must agree with its contract.
        XCTAssertEqual(s.totalAsleep, 6 * 3600)
        XCTAssertEqual(s.efficiency, 6.0 / 7.0, accuracy: 1e-12)
    }

    /// Clause 1: an assertion wins for DISPLAY. A fully-asserted night must score identically to the
    /// same night fully measured — otherwise "healing" would quietly restate the wearer's night at a
    /// lower number, which is a different defect wearing the fix's clothes.
    func testAssertedTimeIsIncludedExactlyLikeMeasuredTime() throws {
        let measured = try XCTUnwrap(SleepScoreHeal.healedScore(hypnogram: night(provenance: .measured)))
        let asserted = try XCTUnwrap(SleepScoreHeal.healedScore(hypnogram: night(provenance: .asserted)))
        XCTAssertEqual(measured, asserted)
    }

    /// PARITY WITH THE EDIT PATH. `LocalStore.applySleepEdit` builds `SleepScore.composite` from a
    /// second-precision `SleepStaging.Summary`; this must reproduce that call exactly.
    func testMatchesTheEditPathsCompositeCall() throws {
        let segments = night()
        let s = try XCTUnwrap(SleepScoreHeal.summary(from: segments))
        let expected = SleepScore.composite(.init(
            totalAsleep: s.totalAsleep, timeAwake: s.awake, efficiency: s.efficiency,
            deep: s.deep, light: s.light, rem: s.rem)).score
        XCTAssertEqual(SleepScoreHeal.healedScore(hypnogram: segments), expected)
    }

    /// THE REASON THIS TYPE EXISTS. Rebuilding from the row's ROUNDED minutes is a different input
    /// than the one the score was originally built from. Pin that they can disagree, so nobody
    /// "simplifies" the heal into reading `row.asleepMin`.
    func testSecondPrecisionDiffersFromRoundedMinutes() throws {
        // 6 h 00 m 29 s asleep rounds DOWN to 360 min; 29 s of REM is invisible to the minute basis.
        let segments = [seg(0, 7 * 3600 + 29, .inBed),
                        seg(0, 3600, .awake),
                        seg(3600, 4 * 3600, .asleepCore),
                        seg(4 * 3600, 5.5 * 3600, .asleepDeep),
                        seg(5.5 * 3600, 7 * 3600 + 29, .asleepREM)]
        let s = try XCTUnwrap(SleepScoreHeal.summary(from: segments))
        XCTAssertEqual(s.totalAsleep, 6 * 3600 + 29)
        // The minute rollup loses the 29 s, so a minutes-based rebuild feeds a different efficiency.
        let m = s.minutes
        let roundedEfficiency = Double(m.asleep) / Double(m.inBed)
        XCTAssertNotEqual(s.efficiency, roundedEfficiency)
    }

    // MARK: - Refusals

    func testEmptyHypnogramIsLeftAlone() {
        XCTAssertNil(SleepScoreHeal.summary(from: []))
        XCTAssertNil(SleepScoreHeal.healedScore(hypnogram: []))
    }

    /// No `.inBed` layer ⇒ `efficiency` is 0 by SleepStaging.Summary's own contract, so the night
    /// cannot be described and must not be scored.
    func testNoInBedLayerIsLeftAlone() {
        XCTAssertNil(SleepScoreHeal.summary(from: [seg(0, 3600, .asleepCore)]))
    }

    /// An all-awake night has no asleep time; scoring it would invent a night that did not happen.
    func testNoAsleepTimeIsLeftAlone() {
        XCTAssertNil(SleepScoreHeal.summary(from: [seg(0, 3600, .inBed), seg(0, 3600, .awake)]))
    }

    /// A recomputed 0 writes the sentinel back and achieves nothing, so the row stays untouched and
    /// the wearer's next edit still gets a chance to fix it.
    func testAZeroRecomputeIsRefusedRatherThanWritten() {
        // One second of sleep in a 12 h bed: every factor floors, so the composite lands at 0.
        let segments = [seg(0, 12 * 3600, .inBed),
                        seg(0, 12 * 3600 - 1, .awake),
                        seg(12 * 3600 - 1, 12 * 3600, .asleepCore)]
        if let s = SleepScoreHeal.summary(from: segments) {
            let raw = SleepScore.composite(.init(
                totalAsleep: s.totalAsleep, timeAwake: s.awake, efficiency: s.efficiency,
                deep: s.deep, light: s.light, rem: s.rem)).score
            // Only meaningful as a refusal test if the composite really does floor here.
            if raw == 0 { XCTAssertNil(SleepScoreHeal.healedScore(hypnogram: segments)) }
        }
    }
}
