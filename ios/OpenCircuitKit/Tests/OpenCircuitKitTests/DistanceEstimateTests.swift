import XCTest
@testable import OpenCircuitKit

final class DistanceEstimateTests: XCTestCase {

    // MARK: Stride math

    func testStrideMale() {
        // 170 cm × 0.415 = 70.55 cm
        XCTAssertEqual(DistanceEstimate.strideCm(heightCm: 170, sex: .male), 70.55, accuracy: 0.001)
    }

    func testStrideFemale() {
        // 165 cm × 0.413 = 68.145 cm
        XCTAssertEqual(DistanceEstimate.strideCm(heightCm: 165, sex: .female), 68.145, accuracy: 0.001)
    }

    func testStrideZeroHeight() {
        XCTAssertEqual(DistanceEstimate.strideCm(heightCm: 0, sex: .male), 0, accuracy: 0.001)
    }

    // MARK: Distance in metres

    func testDistanceMale170cm10000Steps() {
        // 10000 × 70.55 cm / 100 = 7055 m
        let m = DistanceEstimate.meters(steps: 10_000, heightCm: 170, sex: .male)
        XCTAssertEqual(m, 7055.0, accuracy: 0.01)
    }

    func testDistanceFemale165cm8000Steps() {
        // 8000 × 68.145 cm / 100 = 5451.6 m
        let m = DistanceEstimate.meters(steps: 8_000, heightCm: 165, sex: .female)
        XCTAssertEqual(m, 5451.6, accuracy: 0.01)
    }

    func testDistanceZeroSteps() {
        XCTAssertEqual(DistanceEstimate.meters(steps: 0, heightCm: 170, sex: .male), 0)
    }

    func testDistanceNegativeStepsReturnsZero() {
        XCTAssertEqual(DistanceEstimate.meters(steps: -100, heightCm: 170, sex: .male), 0)
    }

    // MARK: UserProfile overload

    func testDistanceViaProfile() {
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 180, sex: .male)
        // 180 × 0.415 = 74.7 cm; 5000 × 74.7 / 100 = 3735 m
        let m = DistanceEstimate.meters(steps: 5_000, profile: profile)
        XCTAssertEqual(m, 3735.0, accuracy: 0.01)
    }
}
