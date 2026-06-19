import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the overnight stress mapping (#71). Asserts the RMSSD→score curve
/// is monotonic decreasing, the app's band thresholds, the median-based overnight score, and
/// the per-band state durations. No fabricated health values.
final class SleepStressTests: XCTestCase {

    func testBandThresholds() {
        XCTAssertEqual(SleepStress.Band.of(1), .relaxed)
        XCTAssertEqual(SleepStress.Band.of(29), .relaxed)
        XCTAssertEqual(SleepStress.Band.of(30), .normal)
        XCTAssertEqual(SleepStress.Band.of(59), .normal)
        XCTAssertEqual(SleepStress.Band.of(60), .medium)
        XCTAssertEqual(SleepStress.Band.of(79), .medium)
        XCTAssertEqual(SleepStress.Band.of(80), .high)
        XCTAssertEqual(SleepStress.Band.of(100), .high)
    }

    func testScoreIsMonotonicDecreasingInRMSSD() {
        // Higher HRV → lower stress.
        let lowHRV = SleepStress.score(rmssdMs: 15)
        let midHRV = SleepStress.score(rmssdMs: 40)
        let highHRV = SleepStress.score(rmssdMs: 70)
        XCTAssertGreaterThan(lowHRV, midHRV)
        XCTAssertGreaterThan(midHRV, highHRV)
    }

    func testScoreClampedToReferenceWindow() {
        // Beyond the reference bounds the score saturates, never escaping 0…100.
        let veryHigh = SleepStress.score(rmssdMs: 200)
        let veryLow = SleepStress.score(rmssdMs: 2)
        XCTAssertEqual(veryHigh, Int(SleepStress.lowScore))
        XCTAssertEqual(veryLow, Int(SleepStress.highScore))
        XCTAssertGreaterThanOrEqual(veryHigh, 0)
        XCTAssertLessThanOrEqual(veryLow, 100)
    }

    func testRestedBoundIsRelaxedAndStressedBoundIsHigh() {
        XCTAssertEqual(SleepStress.Band.of(SleepStress.score(rmssdMs: SleepStress.restedRMSSD)), .relaxed)
        XCTAssertEqual(SleepStress.Band.of(SleepStress.score(rmssdMs: SleepStress.stressedRMSSD)), .high)
    }

    func testOvernightScoreUsesMedian() {
        // Median of [10,40,40,40,200] is 40; the lone outliers don't drag it.
        let s = SleepStress.overnightScore(rmssd: [10, 40, 40, 40, 200])
        XCTAssertEqual(s, SleepStress.score(rmssdMs: 40))
        XCTAssertNil(SleepStress.overnightScore(rmssd: []))
        XCTAssertNil(SleepStress.overnightScore(rmssd: [0, 0]), "non-positive RMSSD dropped")
    }

    func testStateDurations() {
        // Two relaxed (high HRV) + one high-stress (low HRV) epoch.
        let durations = SleepStress.stateDurations(rmssd: [70, 70, 15], epochSeconds: 150)
        XCTAssertEqual(durations[.relaxed] ?? 0, 300, accuracy: 1e-9)
        XCTAssertEqual(durations[.high] ?? 0, 150, accuracy: 1e-9)
        XCTAssertNil(durations[.medium])
    }
}
