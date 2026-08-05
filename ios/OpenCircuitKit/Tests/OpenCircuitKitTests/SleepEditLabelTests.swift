import XCTest
@testable import OpenCircuitKit

final class SleepEditLabelTests: XCTestCase {

    private let night = Date(timeIntervalSince1970: 1_780_000_000)
    private func t(_ minutes: Double) -> Date { night.addingTimeInterval(minutes * 60) }

    private func label(onsetErr: Double?, wakeErr: Double?) -> SleepEditLabel {
        SleepEditLabel(night: night,
                       recordedOnset: onsetErr.map { t(100 + $0) },
                       recordedWake: wakeErr.map { t(600 + $0) },
                       trueOnset: onsetErr == nil ? nil : t(100),
                       trueWake: wakeErr == nil ? nil : t(600))
    }

    // MARK: - Error arithmetic

    func testWakeErrorIsPositiveWhenTheDetectorHeldTheNightOpenTooLong() {
        let l = label(onsetErr: nil, wakeErr: 50)
        XCTAssertEqual(l.wakeErrorMinutes ?? 0, 50, accuracy: 0.001)
        XCTAssertNil(l.onsetErrorMinutes)
        XCTAssertTrue(l.isUsable)
    }

    func testOnsetErrorIsNegativeWhenTheDetectorCalledSleepTooEarly() {
        XCTAssertEqual(label(onsetErr: -22, wakeErr: nil).onsetErrorMinutes ?? 0, -22, accuracy: 0.001)
    }

    func testLabelWithNeitherEdgeIsNotUsable() {
        XCTAssertFalse(SleepEditLabel(night: night).isUsable)
    }

    // MARK: - Filtering

    func testPickerFrictionIsNotALabel() {
        let noise = [label(onsetErr: 1, wakeErr: 2), label(onsetErr: -2, wakeErr: 1)]
        XCTAssertTrue(SleepEditLabels.usable(noise).isEmpty,
                      "a one- or two-minute nudge is not an assertion that the detector was wrong")
    }

    func testARealCorrectionOnEitherEdgeQualifies() {
        XCTAssertEqual(SleepEditLabels.usable([label(onsetErr: 0, wakeErr: 50)]).count, 1)
        XCTAssertEqual(SleepEditLabels.usable([label(onsetErr: 40, wakeErr: 0)]).count, 1)
    }

    // MARK: - Accuracy

    /// Mean must be SIGNED so a systematically-late detector is visible; a mean-absolute would
    /// report the same number whether we run late every night or scatter both ways.
    func testMeanErrorIsSignedSoSystematicBiasSurvives() {
        let allLate = [label(onsetErr: nil, wakeErr: 40),
                       label(onsetErr: nil, wakeErr: 50),
                       label(onsetErr: nil, wakeErr: 60)]
        let scattered = [label(onsetErr: nil, wakeErr: -50),
                         label(onsetErr: nil, wakeErr: 50),
                         label(onsetErr: nil, wakeErr: 50)]
        XCTAssertEqual(SleepEditLabels.accuracy(allLate).meanWakeError ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(SleepEditLabels.accuracy(scattered).meanWakeError ?? 0, 16.667, accuracy: 0.01)
        // …while the typical magnitude is the same for both.
        XCTAssertEqual(SleepEditLabels.accuracy(allLate).medianAbsWakeError ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(SleepEditLabels.accuracy(scattered).medianAbsWakeError ?? 0, 50, accuracy: 0.001)
    }

    /// "No evidence" must not read as "no error".
    func testAbsentEdgeIsNilNotZero() {
        let a = SleepEditLabels.accuracy([label(onsetErr: nil, wakeErr: 40)])
        XCTAssertNil(a.meanOnsetError)
        XCTAssertNil(a.medianAbsOnsetError)
        XCTAssertNotNil(a.meanWakeError)
    }

    func testAccuracyOfNothingIsAllNil() {
        let a = SleepEditLabels.accuracy([])
        XCTAssertEqual(a.count, 0)
        XCTAssertNil(a.meanWakeError)
        XCTAssertNil(a.medianAbsWakeError)
    }

    func testMedianAbsoluteIsRobustToOneWildNight() {
        let labels = (0..<8).map { _ in label(onsetErr: nil, wakeErr: 30) } + [label(onsetErr: nil, wakeErr: 900)]
        XCTAssertEqual(SleepEditLabels.accuracy(labels).medianAbsWakeError ?? 0, 30, accuracy: 0.001)
    }

    // MARK: - The fit gate

    func testOneNightIsNeverEnoughToFit() {
        XCTAssertFalse(SleepEditLabels.isFittable([label(onsetErr: nil, wakeErr: 50)]),
                       "change-control N8: a knob may not be promoted off a single night")
    }

    func testFitGateCountsOnlyRealCorrections() {
        let friction = (0..<20).map { _ in label(onsetErr: 1, wakeErr: 1) }
        XCTAssertFalse(SleepEditLabels.isFittable(friction),
                       "twenty one-minute nudges are not twenty labels")
        let real = (0..<SleepEditLabels.minimumNightsToFit).map { _ in label(onsetErr: nil, wakeErr: 40) }
        XCTAssertTrue(SleepEditLabels.isFittable(real))
    }
}
