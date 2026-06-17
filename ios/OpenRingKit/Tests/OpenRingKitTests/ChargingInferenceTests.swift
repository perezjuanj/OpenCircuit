import XCTest
@testable import OpenRingKit

// Charging inference from battery % trend (#60): fires only on a strictly rising
// sequence of ≥ 2 readings; any flat, falling, or mixed pattern returns false.
final class ChargingInferenceTests: XCTestCase {

    // MARK: Degenerate inputs

    func testEmptyTrendReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: []))
    }

    func testSingleReadingReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [75]))
    }

    // MARK: Rising (charging)

    func testTwoRisingReadingsReturnsTrue() {
        XCTAssertTrue(ChargingInference.inferred(from: [74, 76]))
    }

    func testThreeRisingReadingsReturnsTrue() {
        XCTAssertTrue(ChargingInference.inferred(from: [74, 76, 78]))
    }

    func testFourRisingReadingsReturnsTrue() {
        XCTAssertTrue(ChargingInference.inferred(from: [60, 65, 70, 75]))
    }

    func testRisingByOneReturnsTrueEachPair() {
        // Single-unit increments still count as rising.
        XCTAssertTrue(ChargingInference.inferred(from: [80, 81, 82]))
    }

    // MARK: Non-rising (not charging)

    func testFlatTwoReadingsReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [75, 75]))
    }

    func testFlatThreeReadingsReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [75, 75, 75]))
    }

    func testFallingTwoReadingsReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [80, 78]))
    }

    func testFallingThreeReadingsReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [80, 78, 76]))
    }

    // MARK: Mixed (one pair not rising → whole sequence fails)

    func testMixedRisingThenFlatReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [74, 76, 76]))
    }

    func testMixedRisingThenFallingReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [74, 76, 75]))
    }

    func testMixedFlatThenRisingReturnsFalse() {
        XCTAssertFalse(ChargingInference.inferred(from: [74, 74, 76]))
    }
}
