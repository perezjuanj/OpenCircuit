import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for automatic nap detection (#76). Builds a day of 0x4c motion epochs
/// (active / still / active) anchored at a chosen wall-clock via the `epoch` parameter, then
/// asserts a daytime stillness block ≥ 15 min is a nap, while an overnight block, an overlap
/// with the main night, and a sub-15-min block are all rejected.
final class NapDetectionTests: XCTestCase {

    private let step: UInt32 = 150

    /// One epoch with a uniform motion byte (baseline 1 = still; higher = movement).
    private func rec(_ counter: UInt32, motion: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// Build active→still→active records and the `epoch` so that counter 0 lands at `anchorHour`
    /// local today. `activeEpochs`/`stillEpochs` are 2.5-min epochs each.
    private func dayRecords(anchorHour: Int, activeEpochs: Int, stillEpochs: Int)
        -> (records: [BulkRecord], epoch: Int) {
        let cal = Calendar.current
        let anchor = cal.date(byAdding: .hour, value: anchorHour, to: cal.startOfDay(for: Date()))!
        var recs: [BulkRecord] = []
        var c: UInt32 = 0
        for _ in 0..<activeEpochs { recs.append(rec(c, motion: 20)); c += step }
        for _ in 0..<stillEpochs { recs.append(rec(c, motion: 1)); c += step }
        for _ in 0..<activeEpochs { recs.append(rec(c, motion: 20)); c += step }
        return (recs, Int(anchor.timeIntervalSince1970))
    }

    func testDetectsDaytimeNap() {
        // 14:00 anchor; 20-min active, 60-min still nap, 20-min active.
        let (recs, epoch) = dayRecords(anchorHour: 14, activeEpochs: 8, stillEpochs: 24)
        let naps = NapDetection.naps(from: recs, mainSleep: nil, epoch: epoch)
        XCTAssertEqual(naps.count, 1, "one daytime nap")
        let nap = naps[0]
        XCTAssertGreaterThanOrEqual(nap.duration, NapDetection.minNapDuration)
        XCTAssertGreaterThan(nap.asleep, 0)
        XCTAssertFalse(nap.isLongNap, "60-min nap is not a long nap")
        XCTAssertFalse(nap.segments.isEmpty)
    }

    func testRejectsShortStillBlock() {
        // 10-min still block (< 15 min) → not a nap.
        let (recs, epoch) = dayRecords(anchorHour: 14, activeEpochs: 8, stillEpochs: 4)
        let naps = NapDetection.naps(from: recs, mainSleep: nil, epoch: epoch)
        XCTAssertTrue(naps.isEmpty)
    }

    func testRejectsOvernightBlock() {
        // Same shape but at 02:00 — an overnight midpoint is night sleep, not a nap.
        let (recs, epoch) = dayRecords(anchorHour: 2, activeEpochs: 8, stillEpochs: 24)
        let naps = NapDetection.naps(from: recs, mainSleep: nil, epoch: epoch)
        XCTAssertTrue(naps.isEmpty, "overnight stillness is excluded from naps")
    }

    func testExcludesOverlapWithMainSleep() {
        let (recs, epoch) = dayRecords(anchorHour: 14, activeEpochs: 8, stillEpochs: 24)
        // A main-sleep block spanning the whole captured day window → the nap is suppressed.
        let firstT = recs.first!.date(epoch: epoch)
        let lastT = recs.last!.date(epoch: epoch)
        let main = ActivityPeriod(activity: .sleep, start: firstT, end: lastT)
        let naps = NapDetection.naps(from: recs, mainSleep: main, epoch: epoch)
        XCTAssertTrue(naps.isEmpty, "a block overlapping the main night is not double-counted as a nap")
    }
}
