import CoreBluetooth
import XCTest
@testable import OpenCircuit

/// Unit tests for the pure Bluetooth-availability mapping (#134). This is the function the connect
/// card switches on to decide between "Scan & connect", "Turn on Bluetooth", "Allow in Settings", or
/// the first-run system prompt — so its state/authorization → availability table must stay exact.
final class BTAvailabilityTests: XCTestCase {

    // notDetermined authorization wins regardless of central state — the app hasn't been granted
    // Bluetooth yet, so a tap must go create the central and prompt (it never allocates one to read
    // this, which is the whole point of #142's fresh-install-no-prompt guarantee).
    func testNotDeterminedRegardlessOfCentralState() {
        XCTAssertEqual(RingScanner.btAvailability(centralState: nil, authorization: .notDetermined),
                       .notDetermined)
        XCTAssertEqual(RingScanner.btAvailability(centralState: .poweredOn, authorization: .notDetermined),
                       .notDetermined)
    }

    // denied + restricted both mean "the user can't grant it from a tap" → route to Settings.
    func testDeniedAndRestrictedMapToDenied() {
        XCTAssertEqual(RingScanner.btAvailability(centralState: .poweredOn, authorization: .denied),
                       .denied)
        XCTAssertEqual(RingScanner.btAvailability(centralState: nil, authorization: .restricted),
                       .denied)
    }

    // Authorized but the central hasn't been created yet (lazy, #142) → ready, so a tap creates it
    // and scans.
    func testAuthorizedNilCentralIsReady() {
        XCTAssertEqual(RingScanner.btAvailability(centralState: nil, authorization: .allowedAlways),
                       .ready)
    }

    // Authorized + the radio is off → the actionable "Turn on Bluetooth" branch.
    func testAuthorizedPoweredOffIsPoweredOff() {
        XCTAssertEqual(RingScanner.btAvailability(centralState: .poweredOff, authorization: .allowedAlways),
                       .poweredOff)
    }

    // Authorized + powered on → ready to scan.
    func testAuthorizedPoweredOnIsReady() {
        XCTAssertEqual(RingScanner.btAvailability(centralState: .poweredOn, authorization: .allowedAlways),
                       .ready)
    }

    // Authorized but mid-transition (.unknown/.resetting) → treat as ready so the tap proceeds; the
    // pending-scan path completes once .poweredOn actually arrives.
    func testAuthorizedTransientStatesAreReady() {
        XCTAssertEqual(RingScanner.btAvailability(centralState: .unknown, authorization: .allowedAlways),
                       .ready)
        XCTAssertEqual(RingScanner.btAvailability(centralState: .resetting, authorization: .allowedAlways),
                       .ready)
    }
}
