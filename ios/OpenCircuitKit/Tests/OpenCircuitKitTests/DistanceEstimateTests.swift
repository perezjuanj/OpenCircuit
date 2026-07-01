import XCTest
@testable import OpenCircuitKit

final class DistanceEstimateTests: XCTestCase {

    // MARK: Per-step constant (PROTOCOL.md §5.3.1 — RingConn's own fixed multiplier)

    func testMetersPerStepConstant() {
        XCTAssertEqual(DistanceEstimate.metersPerStep, 0.248, accuracy: 0.0001)
    }

    // MARK: Distance in metres

    func testDistance10000Steps() {
        // 10000 × 0.248 = 2480 m
        XCTAssertEqual(DistanceEstimate.meters(steps: 10_000), 2480.0, accuracy: 0.01)
    }

    func testDistance8000Steps() {
        // 8000 × 0.248 = 1984 m
        XCTAssertEqual(DistanceEstimate.meters(steps: 8_000), 1984.0, accuracy: 0.01)
    }

    func testDistanceZeroSteps() {
        XCTAssertEqual(DistanceEstimate.meters(steps: 0), 0)
    }

    func testDistanceNegativeStepsReturnsZero() {
        XCTAssertEqual(DistanceEstimate.meters(steps: -100), 0)
    }
}
