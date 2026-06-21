import XCTest
@testable import OpenCircuitKit

/// P1 guard: staging a multi-night EpochArchive union must describe LAST night, not the earliest
/// block `findSleep` returns. `latestNightRecords` scopes to the most recent overnight block.
final class LatestNightRecordsTests: XCTestCase {

    /// A still (motion baseline `1`) worn epoch at `date`.
    private func stillRecord(at date: Date) -> BulkRecord {
        let counter = UInt32(Int(date.timeIntervalSince1970) - Command.syncEpoch)
        var b = [UInt8](repeating: 0, count: BulkRecord.length)
        b[0] = UInt8((counter >> 24) & 0xff); b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff);  b[3] = UInt8(counter & 0xff)
        for k in 10 ..< 15 { b[k] = 1 }   // [10:15] still baseline
        return BulkRecord(b)!
    }

    /// ~3 h of still epochs at 150 s spacing from `start`.
    private func night(startingAt start: Date, epochs: Int = 72) -> [BulkRecord] {
        (0 ..< epochs).map { stillRecord(at: start.addingTimeInterval(Double($0) * 150)) }
    }

    /// 02:00 local on the day containing `base`, then +`dayOffset` days. 2–5 a.m. is overnight in
    /// every timezone, so the block's midpoint passes `isOvernightBlock` regardless of CI locale.
    private func twoAM(_ base: Date, dayOffset: Int) -> Date {
        let cal = Calendar.current
        let twoAM = cal.date(byAdding: .hour, value: 2, to: cal.startOfDay(for: base))!
        return cal.date(byAdding: .day, value: dayOffset, to: twoAM)!
    }

    func testTwoNightUnionScopesToLatestNight() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)   // ~2026, comfortably after syncEpoch
        let n1Start = twoAM(base, dayOffset: 0)
        let n2Start = twoAM(base, dayOffset: 1)
        // Union with the prior night LAST in the array — proves selection isn't array-order based.
        let union = night(startingAt: n2Start) + night(startingAt: n1Start)

        let scoped = BulkSleep.latestNightRecords(from: union)

        XCTAssertFalse(scoped.isEmpty)
        // Everything kept is from night 2 (no prior-night records leak through the 30-min margin).
        let cutoff = n2Start.addingTimeInterval(-31 * 60)
        XCTAssertTrue(scoped.allSatisfy { $0.date() >= cutoff },
                      "prior night's records must be excluded")
        // And night 2 is fully retained (its ~72 epochs, give or take the margin).
        XCTAssertGreaterThanOrEqual(scoped.count, 70)
    }

    func testSingleNightReturnedWhole() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let only = night(startingAt: twoAM(base, dayOffset: 0))
        XCTAssertEqual(BulkSleep.latestNightRecords(from: only).count, only.count)
    }

    /// A night handed off in TWO fragments (a data gap from a dropped buffer / missed drain) must be
    /// returned WHOLE — both fragments — not clipped to the latest block. This is the record-level half
    /// of the shrink fix; previously only the latest fragment survived.
    func testFragmentedNightReturnsBothFragments() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let anchor = twoAM(base, dayOffset: 0)                 // 02:00 local
        let p1Start = anchor.addingTimeInterval(-3 * 3600)     // ~23:00 prev — 3 h fragment
        let p2Start = anchor.addingTimeInterval(40 * 60)       // 02:40 — 3 h fragment, ~43 min gap
        let p1 = night(startingAt: p1Start)
        let p2 = night(startingAt: p2Start)
        // Prior night, 1 day earlier, must NOT be absorbed into the cluster.
        let prior = night(startingAt: twoAM(base, dayOffset: -1))
        let union = p2 + prior + p1                            // shuffled order

        let scoped = BulkSleep.latestNightRecords(from: union)

        // Both of last night's fragments are retained …
        XCTAssertEqual(scoped.count, p1.count + p2.count,
                       "both fragments of last night are kept (stitched), prior night excluded")
        // … and none of the prior night leaks in (cluster gap > maxIntraNightGap).
        let priorCutoff = p1Start.addingTimeInterval(-31 * 60)
        XCTAssertTrue(scoped.allSatisfy { $0.date() >= priorCutoff }, "prior night excluded")
        // The earliest kept record is from fragment 1, not fragment 2.
        XCTAssertLessThan(scoped.map { $0.date() }.min()!, p2Start, "fragment 1 is retained, not clipped")
    }

    func testNoOvernightBlockReturnsInputUnchanged() {
        // A still block at ~14:00 local (daytime nap) — not overnight → input returned unchanged so
        // the caller stages exactly as before.
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let cal = Calendar.current
        let twoPM = cal.date(byAdding: .hour, value: 14, to: cal.startOfDay(for: base))!
        let nap = night(startingAt: twoPM)
        XCTAssertEqual(BulkSleep.latestNightRecords(from: nap).count, nap.count)
    }
}
