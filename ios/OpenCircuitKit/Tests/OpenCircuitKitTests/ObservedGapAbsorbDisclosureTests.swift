// IS THE EFFICIENCY THE GUARD EXPOSES ACTUALLY DISCLOSED TO THE USER?
//
// Enabling the observed-gap guard corrects the owner's 2026-08-19 bedtime (in-bed start error
// −119 → −5 min) but pushes reported efficiency from 0.928 to 0.990 against a reference of 0.608 —
// the documented in-bed==asleep signal ceiling, EXPOSED by a correct bedtime rather than created by
// the guard. That is only acceptable if the app SAYS SO. This pins that it does.
//
// `SleepCardView.confidenceHint` (`ios/OpenCircuit/SleepCardView.swift:448-462`) renders the note
// only when THREE conditions hold. Two are pure Kit calls and are asserted directly; the third is a
// one-line arithmetic gate in the view, restated here with its source location:
//
//   1. contiguous            — (inBedEnd − inBedStart) <= summary.inBed * 1.15      [view :453-456]
//   2. !isLikelyTruncated    — SleepCaptureCoverage.classify(...) != .likelyTruncated [view :470-480]
//   3. durationLikelyHigh    — SleepConfidence.classify(...) == .durationLikelyHigh   [view :458]
//
// Measured inputs are the `SleepBaselineTests` scoreboard rows for R3_2026-08-19 at cut 0 and at the
// shipped 0.95.

import XCTest
@testable import OpenCircuitKit

final class ObservedGapAbsorbDisclosureTests: XCTestCase {

    // R3_2026-08-19, MEASURED both ways.
    private let inBedMinOff = 768.0, asleepMinOff = 713.0, wallClockMinOff = 768.12
    private let inBedMinOn = 654.0, asleepMinOn = 648.0, wallClockMinOn = 654.08

    /// `SleepCardView.swift:453-456`, restated.
    private func contiguous(wallClockMin: Double, inBedMin: Double) -> Bool {
        guard inBedMin > 0 else { return true }
        return wallClockMin * 60 <= (inBedMin * 60) * 1.15
    }

    /// The full three-gate chain the view applies.
    private func noteWouldRender(wallClockMin: Double, inBedMin: Double, asleepMin: Double) -> Bool {
        let inBed = inBedMin * 60, asleep = asleepMin * 60
        // Gate 2. No manual schedule is needed: a night this long is far past the ring buffer, so
        // `classify` short-circuits to `.full` before it ever looks for a bedtime reference.
        let truncated = SleepCaptureCoverage.classify(
            capturedOnset: Date(), capturedInBed: inBed, scheduledBedtime: nil) == .likelyTruncated
        return contiguous(wallClockMin: wallClockMin, inBedMin: inBedMin)
            && !truncated
            && SleepConfidence.classify(asleep: asleep, inBed: inBed) == .durationLikelyHigh
    }

    /// WITH THE GUARD ON the efficiency is implausible AND the note fires — the exposure is disclosed.
    func testOwnersNightIsFlaggedDurationLikelyHighAfterTheChange() {
        let efficiency = asleepMinOn / inBedMinOn
        XCTAssertEqual(efficiency, 0.990, accuracy: 0.001, "measured post-change efficiency")
        XCTAssertGreaterThan(efficiency, SleepConfidence.implausibleEfficiency)
        XCTAssertGreaterThanOrEqual(inBedMinOn * 60, SleepConfidence.minNightForFlag,
                                    "must clear the multi-hour gate or the flag never applies")
        XCTAssertEqual(SleepConfidence.classify(asleep: asleepMinOn * 60, inBed: inBedMinOn * 60),
                       .durationLikelyHigh)
        XCTAssertTrue(noteWouldRender(wallClockMin: wallClockMinOn,
                                      inBedMin: inBedMinOn, asleepMin: asleepMinOn),
                      "the confidence note must render — otherwise the change turns a DISCLOSED "
                      + "limitation into a SILENT one")
    }

    /// BEFORE the change the same night was under the cut and said nothing. This is what makes the
    /// assertion above meaningful: the guard does not merely inherit an existing warning, it TRIPS one.
    func testTheSameNightWasSilentBeforeTheChange() {
        let efficiency = asleepMinOff / inBedMinOff
        XCTAssertEqual(efficiency, 0.928, accuracy: 0.001, "measured pre-change efficiency")
        XCTAssertLessThan(efficiency, SleepConfidence.implausibleEfficiency)
        XCTAssertEqual(SleepConfidence.classify(asleep: asleepMinOff * 60, inBed: inBedMinOff * 60),
                       .normal)
        XCTAssertFalse(noteWouldRender(wallClockMin: wallClockMinOff,
                                       inBedMin: inBedMinOff, asleepMin: asleepMinOff))
    }

    /// The other night the guard moves, R3_2026-08-12: efficiency 0.855 → 0.963, also above the cut,
    /// so it too gains the note rather than silently inflating.
    func testTheSecondMovedNightIsAlsoFlagged() {
        XCTAssertEqual(SleepConfidence.classify(asleep: 540 * 60, inBed: 631 * 60), .normal,
                       "before: efficiency 0.855")
        XCTAssertEqual(SleepConfidence.classify(asleep: 468 * 60, inBed: 486 * 60), .durationLikelyHigh,
                       "after: efficiency 0.963")
    }
}
