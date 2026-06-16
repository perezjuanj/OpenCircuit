import XCTest
@testable import OpenRingKit

// Parity tests for the analytics ported from openwhoop-algos. The RR vectors and
// assertions mirror openwhoop's own Rust unit tests so the Swift port is provably
// equivalent. Runs under `swift test` once Xcode is the active toolchain.
final class AnalyticsTests: XCTestCase {

    // MARK: HRV / RMSSD (sleep.rs)

    func testRMSSD() {
        XCTAssertEqual(HRV.rmssd([800, 900, 1000]), 100)  // diffs 100,100 -> 100
        XCTAssertNil(HRV.rmssd([800]))
    }

    func testCleanRR() {
        XCTAssertEqual(HRV.cleanRR([[800, 900], [1000], []]), [800, 900, 1000])
        XCTAssertEqual(HRV.cleanRR([[0, 900], [0]]), [900])
    }

    // MARK: Stress — Baevsky index (stress.rs)

    func testStressConstantRRReturnsMax() {
        XCTAssertEqual(Stress.index(rr: Array(repeating: 750, count: 120)), 10.0)
    }

    func testStressModerateVariability() {
        let rr = [667, 674, 682, 690, 682, 652, 638, 632, 625, 619, 612, 619, 606, 594, 583,
                  577, 566, 561, 561, 556, 556, 550, 556, 556, 556, 556, 550, 550, 545, 541,
                  531, 531, 531, 531, 531, 536, 541, 545, 550, 556, 561, 566, 571, 577, 577,
                  583, 583, 583, 588, 594, 594, 600, 600, 600, 600, 594, 600, 612, 619, 625,
                  632, 632, 632, 625, 625, 619, 619, 619, 612, 606, 594, 600, 600, 600, 600,
                  606, 606, 606, 606, 600, 606, 612, 612, 612, 612, 612, 612, 612, 612, 619,
                  612, 612, 612, 619, 619, 625, 625, 625, 632, 638, 645, 645, 638, 638, 632,
                  625, 625, 625, 625, 632, 638, 632, 632, 625, 625, 625, 625, 625, 619, 612]
        let score = Stress.index(rr: rr)
        XCTAssertGreaterThan(score, 0.0)
        XCTAssertLessThanOrEqual(score, 10.0)
    }

    func testStressLowVariability() {
        let rr = [1000, 984, 1017, 1017, 1017, 1017, 1017, 1000, 1000, 1000, 1000, 1000, 984,
                  984, 984, 984, 984, 984, 984, 984, 952, 952, 952, 952, 938, 952, 952, 952,
                  968, 968, 968, 968, 984, 984, 984, 984, 968, 968, 968, 968, 968, 968, 968,
                  968, 968, 968, 968, 968, 968, 968, 968, 968, 968, 952, 952, 952, 952, 952,
                  952, 952, 938, 938, 938, 938, 938, 923, 923, 938, 938, 938, 938, 938, 938,
                  938, 938, 938, 938, 938, 938, 923, 923, 923, 938, 938, 952, 952, 952, 952,
                  968, 968, 968, 984, 984, 984, 984, 968, 968, 968, 984, 984, 984, 984, 968,
                  968, 968, 968, 968, 952, 952, 952, 952, 938, 952, 952, 952, 968, 968, 952,
                  952, 952]
        XCTAssertGreaterThan(Stress.index(rr: rr), 0.0)
    }

    // MARK: Strain — Edwards TRIMP (strain.rs)

    func testStrainTooFewReadingsIsNil() {
        XCTAssertNil(Strain(maxHR: 200, restingHR: 60).calculate(bpms: Array(repeating: 80, count: 500)))
    }

    func testStrainInvalidHRParamsIsNil() {
        XCTAssertNil(Strain(maxHR: 60, restingHR: 60).calculate(bpms: Array(repeating: 80, count: 600)))
        XCTAssertNil(Strain(maxHR: 50, restingHR: 60).calculate(bpms: Array(repeating: 80, count: 600)))
    }

    func testRestingHRProducesZeroStrain() {
        XCTAssertEqual(Strain(maxHR: 190, restingHR: 60).calculate(bpms: Array(repeating: 65, count: 600)), 0.0)
    }

    func testHighHRProducesHighStrain() {
        let s = Strain(maxHR: 190, restingHR: 60).calculate(bpms: Array(repeating: 170, count: 1800))
        XCTAssertGreaterThan(s ?? 0, 10.0)
    }

    func testStrainCappedAt21() {
        XCTAssertEqual(Strain(maxHR: 190, restingHR: 60).calculate(bpms: Array(repeating: 190, count: 86400)), 21.0)
    }

    // MARK: Sleep score (#28 fix: graded floating-point ratio, not integer step)

    func testSleepScoreGraded() {
        // 4h = 50%, 6h = 75%, 8h = 100%, >8h clamped to 100%
        XCTAssertEqual(SleepScore.score(durationSeconds: 4 * 3600), 50.0)
        XCTAssertEqual(SleepScore.score(durationSeconds: 6 * 3600), 75.0)
        XCTAssertEqual(SleepScore.score(durationSeconds: 8 * 3600), 100.0)
        XCTAssertEqual(SleepScore.score(durationSeconds: 24 * 3600), 100.0)  // clamped
        XCTAssertEqual(SleepScore.score(durationSeconds: 0), 0.0)
    }

    func testSleepScoreConvenienceInit() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(8 * 3600)
        XCTAssertEqual(SleepScore.score(start: start, end: end), 100.0)
    }
}
