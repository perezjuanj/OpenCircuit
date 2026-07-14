import XCTest
@testable import OpenCircuit

/// Locks the `bgphase` diagnostic line format that the #119 early-termination fix relies on for
/// on-device validation. The activity-log export is parsed by eye (and by future tooling) to tell a
/// CONNECT-overrun apart from a DRAIN-overrun and to confirm the flush-first mirror actually landed,
/// so the field order and the `n/a`/`ms` rendering must not drift.
final class BGPhaseBreadcrumbTests: XCTestCase {
    func testCompletedAppRefreshRunRendersAllDurations() {
        let line = RingBackgroundSyncService.bgPhaseBreadcrumb(
            appRefresh: true, connectToReadyMS: 1200, drainMS: 8400, flushMS: 620,
            ready: true, gotData: true, preMirrored: false, mirrored: true)
        XCTAssertEqual(
            line,
            "kind=appRefresh connect=1200ms drain=8400ms flush=620ms ready=true gotData=true preMirrored=false mirrored=true")
    }

    func testConnectOverrunRendersNilsAsNotApplicable() {
        // Ring never became ready this wake → connect and drain are nil. This is the CONNECT-overrun
        // signature the 7d log couldn't distinguish; the flush-first backlog mirror can still land.
        let line = RingBackgroundSyncService.bgPhaseBreadcrumb(
            appRefresh: true, connectToReadyMS: nil, drainMS: nil, flushMS: 300,
            ready: false, gotData: false, preMirrored: true, mirrored: false)
        XCTAssertEqual(
            line,
            "kind=appRefresh connect=n/a drain=n/a flush=300ms ready=false gotData=false preMirrored=true mirrored=false")
    }

    func testDrainOverrunRendersConnectButNilDrain() {
        // Connected fast, but the drain never finished inside the window → drain=n/a while connect has
        // a value. This is the DRAIN-overrun signature (F3-relevant).
        let line = RingBackgroundSyncService.bgPhaseBreadcrumb(
            appRefresh: true, connectToReadyMS: 900, drainMS: nil, flushMS: 0,
            ready: true, gotData: true, preMirrored: false, mirrored: false)
        XCTAssertEqual(
            line,
            "kind=appRefresh connect=900ms drain=n/a flush=0ms ready=true gotData=true preMirrored=false mirrored=false")
    }

    func testProcessingKindRendered() {
        let line = RingBackgroundSyncService.bgPhaseBreadcrumb(
            appRefresh: false, connectToReadyMS: 50, drainMS: 12000, flushMS: 800,
            ready: true, gotData: true, preMirrored: false, mirrored: true)
        XCTAssertTrue(line.hasPrefix("kind=processing "), line)
    }
}
