import XCTest
@testable import OpenCircuitKit

/// Checks the RSSI→proximity mapping that drives Find My Ring (#96).
final class RingProximityTests: XCTestCase {

    func testBandBucketsAreContiguousAndOrdered() {
        XCTAssertEqual(RingProximity.band(forRSSI: -40), .veryClose)
        XCTAssertEqual(RingProximity.band(forRSSI: -55), .veryClose)
        XCTAssertEqual(RingProximity.band(forRSSI: -56), .close)
        XCTAssertEqual(RingProximity.band(forRSSI: -68), .close)
        XCTAssertEqual(RingProximity.band(forRSSI: -69), .nearby)
        XCTAssertEqual(RingProximity.band(forRSSI: -80), .nearby)
        XCTAssertEqual(RingProximity.band(forRSSI: -81), .far)
        XCTAssertEqual(RingProximity.band(forRSSI: -95), .far)
        XCTAssertEqual(RingProximity.band(forRSSI: -96), .searching)
    }

    func testNilAndBogusRSSIReadAsSearching() {
        XCTAssertEqual(RingProximity.band(forRSSI: nil), .searching)
        // CoreBluetooth's "not available" sentinel is 127 — must not read as very close.
        XCTAssertEqual(RingProximity.band(forRSSI: 127), .searching)
    }

    func testDistanceMonotonicallyGrowsAsSignalWeakens() throws {
        let near = try XCTUnwrap(RingProximity.approximateMeters(forRSSI: -55))
        let mid  = try XCTUnwrap(RingProximity.approximateMeters(forRSSI: -70))
        let far  = try XCTUnwrap(RingProximity.approximateMeters(forRSSI: -85))
        XCTAssertLessThan(near, mid)
        XCTAssertLessThan(mid, far)
        // At the 1 m reference power the model should return ≈ 1 m.
        let atRef = try XCTUnwrap(RingProximity.approximateMeters(forRSSI: -59))
        XCTAssertEqual(atRef, 1.0, accuracy: 0.05)
    }

    func testDistanceTextBucketsEnds() {
        XCTAssertNil(RingProximity.distanceText(forRSSI: nil))
        XCTAssertNil(RingProximity.distanceText(forRSSI: 127))          // no signal → no text
        XCTAssertEqual(RingProximity.distanceText(forRSSI: -40), "Right here")
        XCTAssertEqual(RingProximity.distanceText(forRSSI: -95), "≈ 20+ ft")
        // A mid value produces a concrete "≈ N ft".
        let mid = RingProximity.distanceText(forRSSI: -68)
        XCTAssertTrue(mid?.hasPrefix("≈ ") == true && mid?.hasSuffix(" ft") == true, "got \(mid ?? "nil")")
    }

    func testSignalFractionClampsToUnitRange() {
        XCTAssertEqual(RingProximity.signalFraction(forRSSI: nil), 0)
        XCTAssertEqual(RingProximity.signalFraction(forRSSI: -40), 1.0, accuracy: 0.001)  // clamps at -45
        XCTAssertEqual(RingProximity.signalFraction(forRSSI: -95), 0.0, accuracy: 0.001)
        XCTAssertEqual(RingProximity.signalFraction(forRSSI: -70), 0.5, accuracy: 0.001)
    }
}
