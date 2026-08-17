import XCTest
@testable import OpenCircuitKit

/// `SleepEdit.widenRecorded` — the keptManualEdit anchor-widening rules.
///
/// 🟢 Device case 2026-08-16: an edited night's recorded anchors froze at a truncated staging
/// (wake 06:04) while later drains held the real morning; the ±3 h clamp pinned every re-edit at
/// 09:04. Widening must be outward-only, sentinel-aware, and a no-op when nothing grows.
final class SleepEditWidenRecordedTests: XCTestCase {

    private func d(_ h: Int, _ m: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + TimeInterval(h * 3600 + m * 60))
    }
    private func w(_ s: Date, _ e: Date, onset: Date? = nil, wake: Date? = nil) -> SleepEdit.RecordedWindow {
        .init(inBedStart: s, inBedEnd: e, sleepOnset: onset ?? s, sleepWake: wake ?? e)
    }

    func testFullerStagingWidensBothEdges() {
        let out = SleepEdit.widenRecorded(stored: w(d(3), d(6)), incoming: w(d(2, 30), d(9)))
        XCTAssertEqual(out, w(d(2, 30), d(9)))
    }

    func testTheDeviceCaseWakeGrows() {
        // Recorded froze at 03:44→06:04; the 09:13 restage must pull the wake anchor forward so the
        // clamp (recorded wake + 3 h) finally reaches the real ~10:15 wake.
        let stored = w(d(3, 44), d(6, 4))
        let out = try! XCTUnwrap(SleepEdit.widenRecorded(stored: stored,
                                                         incoming: w(d(3, 44), d(9, 13))))
        XCTAssertEqual(out.sleepWake, d(9, 13))
        XCTAssertEqual(out.inBedStart, d(3, 44), "the untouched edge stays put")
    }

    func testThinnerStagingIsANoOp() {
        XCTAssertNil(SleepEdit.widenRecorded(stored: w(d(3), d(9)), incoming: w(d(4), d(8))),
                     "widening never shrinks — a partial later slice changes nothing")
    }

    func testIdenticalStagingIsANoOp() {
        XCTAssertNil(SleepEdit.widenRecorded(stored: w(d(3), d(9)), incoming: w(d(3), d(9))))
    }

    func testUnknownStoredWindowAdoptsIncoming() {
        let sentinel = SleepEdit.RecordedWindow(inBedStart: .distantPast, inBedEnd: .distantPast,
                                                sleepOnset: .distantPast, sleepWake: .distantPast)
        let out = SleepEdit.widenRecorded(stored: sentinel, incoming: w(d(3), d(9)))
        XCTAssertEqual(out, w(d(3), d(9)))
    }

    func testUnknownIncomingWindowIsANoOp() {
        let sentinel = SleepEdit.RecordedWindow(inBedStart: .distantPast, inBedEnd: .distantPast,
                                                sleepOnset: .distantPast, sleepWake: .distantPast)
        XCTAssertNil(SleepEdit.widenRecorded(stored: w(d(3), d(9)), incoming: sentinel))
    }

    func testUnknownIncomingSleepWindowLeavesStoredSleepAnchors() {
        // In-bed grows but the incoming staging found no asleep block: the stored onset/wake — the
        // clamp's primary anchors — must not be clobbered by sentinels.
        let stored = w(d(3), d(6), onset: d(3, 10), wake: d(5, 50))
        var incoming = w(d(3), d(9))
        incoming.sleepOnset = .distantPast
        incoming.sleepWake = .distantPast
        let out = try! XCTUnwrap(SleepEdit.widenRecorded(stored: stored, incoming: incoming))
        XCTAssertEqual(out.inBedEnd, d(9))
        XCTAssertEqual(out.sleepOnset, d(3, 10))
        XCTAssertEqual(out.sleepWake, d(5, 50))
    }
}
