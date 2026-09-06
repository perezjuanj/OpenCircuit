// A user-facing live HR must never be a single poll frame. See `LiveHR.settled`.
//
// The fixture in `testTheRealCaptureSpreadIsWhyThisExists` is the exact locked sequence
// `RingKitVerify` decodes from the FR02.018 poll capture — the only real one the repo holds.

import XCTest
@testable import OpenCircuitKit

final class LiveHRSettlingTests: XCTestCase {

    /// Below the window there is NO answer yet — the caller must keep saying "measuring…"
    /// rather than showing the newest frame, which is the defect being fixed.
    func testNoReadingUntilTheWindowFills() {
        for n in 0 ..< LiveHR.settleSampleCount {
            XCTAssertNil(LiveHR.settled(Array(repeating: 70, count: n)),
                         "\(n) locked frames must not produce a finished reading")
        }
        XCTAssertEqual(LiveHR.settled(Array(repeating: 70, count: LiveHR.settleSampleCount)), 70)
    }

    /// THE REGRESSION. The real capture's locked frames span 61…91 inside one read; the last
    /// frame is 61. Showing that raw is the "abnormally low" reading a tester reported.
    func testTheRealCaptureSpreadIsWhyThisExists() {
        let realLocked = [82, 84, 88, 90, 91, 66, 61]   // RingKitVerify `realHRFrames`, warm-up dropped
        XCTAssertEqual(realLocked.last, 61, "the raw last-frame display would show 61")
        let settled = LiveHR.settled(realLocked)
        XCTAssertEqual(settled, 88, "median of the last 5 (88,90,91,66,61 -> 88)")
        XCTAssertGreaterThan(settled!, realLocked.last!,
                             "settling must lift the answer off the low tail frame")
    }

    /// One dropout frame cannot move the answer — the 2-sample breakdown point the constant's
    /// doc claims. Both a low spike and a high spike are rejected.
    func testASingleOutlierCannotMoveTheAnswer() {
        // sorted [30,70,70,71,71] -> 70; the low spike is discarded, not averaged in.
        XCTAssertEqual(LiveHR.settled([70, 71, 30, 70, 71]), 70)
        // sorted [70,70,71,71,210] -> 71; likewise for the high spike.
        XCTAssertEqual(LiveHR.settled([70, 71, 210, 70, 71]), 71)
    }

    /// Only the most recent window counts, so a read that genuinely changes converges rather
    /// than being anchored by stale frames.
    func testOnlyTheTrailingWindowCounts() {
        XCTAssertEqual(LiveHR.settled([40, 40, 40, 40, 90, 91, 92, 93, 94]), 92)
    }

    /// `settled` consumes values that already passed `decodeLocked`, so the band guard is the
    /// caller's job — pin that contract so nobody "helpfully" re-filters here and changes the
    /// median's breakdown behaviour.
    func testTakesTheTrendVerbatimAndDoesNotRefilter() {
        XCTAssertEqual(LiveHR.settled([30, 30, 30, 30, 30]), 30, "30 is in band and must survive")
    }
}
