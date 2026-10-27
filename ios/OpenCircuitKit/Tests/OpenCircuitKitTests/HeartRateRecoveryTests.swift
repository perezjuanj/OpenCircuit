import XCTest
@testable import OpenCircuitKit

// Heart rate recovery (#337, decision 82d): the pure table. Every time and reading is synthetic.
final class HeartRateRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    /// The workout ends here; recovery marks are end + 60 s and end + 120 s.
    private var end: Date { t0.addingTimeInterval(1_800) }
    private let bound = 150

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func after(_ s: TimeInterval) -> Date { end.addingTimeInterval(s) }

    /// A reading whose instant is `instant`, spanning the second before it (the strap's shape).
    private func reading(_ bpm: Int, _ instant: Date) -> HRSample {
        HRSample(bpm: bpm, start: instant.addingTimeInterval(-1), end: instant)
    }

    /// A workout that peaked at `peak` in its last minute.
    private func workout(peak: Int) -> [HRSample] {
        [reading(120, at(600)), reading(140, at(1_200)), reading(peak, at(1_790)), reading(peak - 5, at(1_800))]
    }

    private func measure(peak: Int = 170, recovery: [HRSample]) -> HeartRateRecovery.Outcome {
        HeartRateRecovery.measure(activeReadings: workout(peak: peak), recoveryReadings: recovery,
                                  end: end, zoneFourLowerBound: bound)
    }

    // MARK: Measured

    func testBothValuesAreThePeakMinusTheReadingsAtOneAndTwoMinutes() {
        let recovery = stride(from: 1.0, through: 130, by: 1).map { s in
            reading(s == 60 ? 140 : s == 120 ? 115 : 150, after(s))
        }
        let outcome = measure(recovery: recovery)
        XCTAssertEqual(outcome.peak, 170)
        XCTAssertEqual(outcome.oneMinute, .measured(drop: 30, reading: 140, at: after(60)))
        XCTAssertEqual(outcome.twoMinutes, .measured(drop: 55, reading: 115, at: after(120)))
    }

    func testTheNearestReadingToEachMarkIsUsed() {
        let outcome = measure(recovery: [reading(150, after(53)), reading(140, after(58)), reading(130, after(63)),
                                         reading(120, after(116)), reading(110, after(123))])
        XCTAssertEqual(outcome.oneMinute.drop, 30, "58 s is 2 s off, 63 s is 3 s off")
        XCTAssertEqual(outcome.twoMinutes.drop, 60, "123 s is 3 s off, 116 s is 4 s off")
    }

    func testOnATieTheEarlierReadingIsUsed() {
        let outcome = measure(recovery: [reading(130, after(62)), reading(140, after(58))])
        XCTAssertEqual(outcome.oneMinute, .measured(drop: 30, reading: 140, at: after(58)))
    }

    func testAReadingExactlyTenSecondsOffCounts() {
        let outcome = measure(recovery: [reading(140, after(50)), reading(120, after(130))])
        XCTAssertEqual(outcome.oneMinute.drop, 30)
        XCTAssertEqual(outcome.twoMinutes.drop, 50)
    }

    func testAPeakExactlyAtTheZoneFourBoundIsMeasured() {
        let outcome = measure(peak: bound, recovery: [reading(130, after(60))])
        XCTAssertEqual(outcome.oneMinute.drop, 20)
    }

    func testARecoveryReadingAboveThePeakIsANegativeDropNotAnError() {
        let outcome = measure(recovery: [reading(175, after(60))])
        XCTAssertEqual(outcome.oneMinute.drop, -5)
    }

    // MARK: Not measured

    func testAReadingJustOverTenSecondsOffDoesNotCount() {
        let outcome = measure(recovery: [reading(140, after(49.9)), reading(120, after(130.1))])
        XCTAssertEqual(outcome.oneMinute, .notMeasured(.noReadingNearMark))
        XCTAssertEqual(outcome.twoMinutes, .notMeasured(.noReadingNearMark))
    }

    func testAMissingOneMinuteReadingLeavesTwoMinutesMeasured() {
        let outcome = measure(recovery: [reading(140, after(20)), reading(120, after(120))])
        XCTAssertEqual(outcome.oneMinute, .notMeasured(.noReadingNearMark))
        XCTAssertEqual(outcome.twoMinutes.drop, 50)
    }

    func testSkippedAfterNinetySecondsMeasuresOnlyTheFirstMinute() {
        let recovery = stride(from: 1.0, through: 90, by: 1).map { reading(140, after($0)) }
        let outcome = measure(recovery: recovery)
        XCTAssertEqual(outcome.oneMinute.drop, 30)
        XCTAssertEqual(outcome.twoMinutes, .notMeasured(.noReadingNearMark))
    }

    func testAPeakBelowZoneFourMeasuresNothingAndSaysWhy() {
        let outcome = measure(peak: bound - 1, recovery: [reading(120, after(60)), reading(110, after(120))])
        let reason = HeartRateRecovery.NotMeasured.peakBelowZoneFour(peak: bound - 1, zoneFourLowerBound: bound)
        XCTAssertEqual(outcome.peak, bound - 1)
        XCTAssertEqual(outcome.oneMinute, .notMeasured(reason))
        XCTAssertEqual(outcome.twoMinutes, .notMeasured(reason))
    }

    func testNoWorkoutHeartRateMeasuresNothing() {
        let outcome = HeartRateRecovery.measure(activeReadings: [], recoveryReadings: [reading(120, after(60))],
                                                end: end, zoneFourLowerBound: bound)
        XCTAssertNil(outcome.peak)
        XCTAssertEqual(outcome.oneMinute, .notMeasured(.noWorkoutHeartRate))
        XCTAssertEqual(outcome.twoMinutes, .notMeasured(.noWorkoutHeartRate))
    }

    func testNoRecoveryReadingsMeasuresNothing() {
        let outcome = measure(recovery: [])
        XCTAssertEqual(outcome.oneMinute, .notMeasured(.noReadingNearMark))
        XCTAssertEqual(outcome.twoMinutes, .notMeasured(.noReadingNearMark))
    }

    // MARK: Readings outside their window

    func testAnActiveReadingAfterTheEndIsNotThePeak() {
        let active = workout(peak: 160) + [reading(190, after(30))]
        let outcome = HeartRateRecovery.measure(activeReadings: active, recoveryReadings: [reading(130, after(60))],
                                                end: end, zoneFourLowerBound: bound)
        XCTAssertEqual(outcome.peak, 160)
        XCTAssertEqual(outcome.oneMinute.drop, 30)
    }

    func testAReadingOutsideTheRecoveryWindowIsNotUsedForTheTwoMinuteMark() {
        let outcome = measure(recovery: [reading(120, after(140))])
        XCTAssertEqual(outcome.twoMinutes, .notMeasured(.noReadingNearMark))
    }

    // MARK: The zone-4 bound comes from the classifier

    func testTheZoneFourBoundIsTheClassifiersFirstZoneFourBPM() {
        let maxHR = 180
        let bound = HeartRateRecovery.zoneFourLowerBound { HRZoneClassifier.zone(bpm: $0, maxHR: maxHR) }
        let found = try? XCTUnwrap(bound)
        guard let found else { return XCTFail("no bound") }
        XCTAssertEqual(HRZoneClassifier.zone(bpm: found, maxHR: maxHR)?.rawValue, 4)
        XCTAssertLessThan(HRZoneClassifier.zone(bpm: found - 1, maxHR: maxHR)?.rawValue ?? 0, 4)
    }

    func testTheZoneFourBoundFollowsWhateverTheClassifierSays() {
        XCTAssertEqual(HeartRateRecovery.zoneFourLowerBound { $0 >= 123 ? HRZone(rawValue: 4) : HRZone(rawValue: 3) }, 123)
        XCTAssertEqual(HeartRateRecovery.zoneFourLowerBound { $0 >= 140 ? HRZone(rawValue: 5) : nil }, 140)
        XCTAssertNil(HeartRateRecovery.zoneFourLowerBound { _ in HRZone(rawValue: 3) })
    }
}
