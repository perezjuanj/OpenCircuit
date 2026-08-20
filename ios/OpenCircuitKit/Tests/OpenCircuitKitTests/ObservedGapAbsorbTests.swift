import XCTest
@testable import OpenCircuitKit

/// OBSERVED-GAP GUARD on the BACKWARD cluster chain (`BulkSleep.latestNightRecords` :1010-1024,
/// constant `BulkSleep.observedGapAbsorbCoverageCut`).
///
/// THE CASE IT TARGETS — 🟢 R3 2026-08-19, reproduced byte-exactly from that ring's own epochs by
/// `SleepAbsorbProbeTests`: an awake-but-STILL 71-min evening block 20:24:34 → 21:35:36 clears
/// `minSleepDuration`, is admitted as a NIGHT by `SleepWindow.isOvernightBlock` (its midpoint
/// 21:00:05 clears the 21:00 cliff), and the backward chain then bridges the 43-min gap to the real
/// night that began 22:18:36 — dragging the reported in-bed start two hours earlier than the wearer's
/// own corrected 22:24. The gap it bridges holds **17 of an expected 17.2 records**: those epochs
/// exist and the detector looked at them and did not call them sleep. That is measured awake time,
/// not the missing-drain hole the chain was written for (`BulkSleep.swift:1005-1009`).
///
/// ⚠️ THE DEFAULT IS 0.65 = ON. See the constant's doc comment for why that value (a measured
/// reachability bound, not a fit to the labelled score) and for the standing cost: on the 2026-08-19
/// corpus the guard changes exactly two nights, and the second one (R3 2026-08-12, coverage 0.894)
/// carries no recoverable in-bed ground truth, so the corpus cannot say whether the guard helps it
/// or truncates a genuinely fragmented night. `= 0` is the one-constant revert and is pinned
/// byte-identical below.
final class ObservedGapAbsorbTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_780_000_000)   // ~2026, after syncEpoch

    private func record(at date: Date, still: Bool, seed: Int = 0) -> BulkRecord {
        let counter = UInt32(Int(date.timeIntervalSince1970) - Command.syncEpoch)
        var b = [UInt8](repeating: 0, count: BulkRecord.length)
        b[0] = UInt8((counter >> 24) & 0xff); b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff);  b[3] = UInt8(counter & 0xff)
        if still {
            for k in 10 ..< 15 { b[k] = 1 }
        } else {
            // Elevated AND varied — a constant plateau de-floors to STILL (the flat-motion fixture
            // trap) and would never split the block.
            let jitter = UInt8(seed % 5)
            b[10] = 8 &+ jitter; b[11] = 12; b[12] = 20 &+ jitter; b[13] = 6; b[14] = 10
        }
        return BulkRecord(b)!
    }

    private func still(_ start: Date, _ end: Date) -> [BulkRecord] {
        stride(from: 0, to: end.timeIntervalSince(start), by: 150)
            .map { record(at: start.addingTimeInterval($0), still: true) }
    }

    private func moving(_ start: Date, _ end: Date) -> [BulkRecord] {
        stride(from: 0, to: end.timeIntervalSince(start), by: 150).enumerated()
            .map { record(at: start.addingTimeInterval($1), still: false, seed: $0) }
    }

    /// Local `hour`:`min` on the day containing `base`. `isOvernightBlock` is a LOCAL-midpoint rule,
    /// so fixtures must be anchored on local clock time or they drift by CI locale.
    private func at(_ hour: Int, _ min: Int = 0, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: base))!
        return cal.date(byAdding: .minute, value: hour * 60 + min, to: day)!
    }

    /// Juan's shape: a still 20:30→21:40 evening block (70 min, midpoint 21:05 — it clears the 21:00
    /// cliff by five minutes, exactly as his 20:24→21:35 block cleared it by five seconds), 35 min of
    /// RECORDED movement, then the real night 22:15→06:00. Both blocks are "overnight" by the
    /// midpoint rule, so master chains them across the observed gap.
    private func juanShapedUnion() -> [BulkRecord] {
        still(at(20, 30), at(21, 40))
            + moving(at(21, 40), at(22, 15))
            + still(at(22, 15), at(6, 0, dayOffset: 1))
    }

    private func firstKept(_ scoped: [BulkRecord]) -> Date? { scoped.map { $0.date() }.min() }

    // MARK: - The kill switch

    /// `= 0` IS THE OFF SWITCH AND IT IS BYTE-IDENTICAL TO THE PRE-GUARD CODE. Asserted on a fixture
    /// the shipped default DOES change (checked in the same test), so this cannot go vacuous: if the
    /// guard ever stopped firing here, the second half of this test fails rather than passing quietly.
    func testZeroCutIsByteIdenticalToPreGuardScoping() {
        let union = juanShapedUnion()

        // OFF: pre-guard behaviour — the evening block IS absorbed, so the slice reaches back to it.
        let off = BulkSleep.latestNightRecords(from: union, observedGapCoverageCut: 0)
        XCTAssertNotNil(firstKept(off))
        XCTAssertLessThanOrEqual(firstKept(off)!, at(20, 30),
                                 "at cut 0 the pre-guard chain must still absorb the evening block — "
                                 + "if this stops being true the kill-switch test has gone vacuous")

        // ON at the shipped default: it must NOT be absorbed. This is what makes the pair meaningful.
        let shipped = BulkSleep.latestNightRecords(from: union)
        XCTAssertGreaterThan(BulkSleep.observedGapAbsorbCoverageCut, 0,
                             "the shipped default is expected to be ON; if it is reverted to 0, "
                             + "flip this test back to a plain no-op assertion")
        XCTAssertNotNil(firstKept(shipped))
        XCTAssertGreaterThan(firstKept(shipped)!, at(21, 40),
                             "at the shipped default the evening block must be declined")
    }

    /// The shipped default must sit at or below the coverage a FULLY OBSERVED gap can actually
    /// produce, or the guard is unreachable for short gaps for a purely arithmetic reason
    /// (`ObservedGapCeilingProbeTests` measures the curve; the floor case is the binding one).
    func testShippedDefaultIsReachableAtTheShortestJudgeableGap() {
        let n = BulkSleep.onsetContiguityGap / Double(BulkRecord.epochSeconds)   // epochs in the floor gap
        let ceilingAtFloor = (n - 1) / n
        XCTAssertLessThanOrEqual(BulkSleep.observedGapAbsorbCoverageCut, ceilingAtFloor,
                                 "cut \(BulkSleep.observedGapAbsorbCoverageCut) exceeds the "
                                 + "\(ceilingAtFloor) a fully observed gap reads at the "
                                 + "\(BulkSleep.onsetContiguityGap / 60) min floor — the guard would "
                                 + "be testing gap LENGTH, not observation")
    }

    /// A negative cut is also OFF (the `> 0` guard), so a mis-set flag degrades to master rather
    /// than to some third behaviour.
    func testNegativeCutIsAlsoOff() {
        let union = juanShapedUnion()
        XCTAssertEqual(BulkSleep.latestNightRecords(from: union, observedGapCoverageCut: -1).map(\.counter),
                       BulkSleep.latestNightRecords(from: union, observedGapCoverageCut: 0).map(\.counter))
    }

    // MARK: - What it does when enabled

    /// ENABLED, the densely-observed 45-min gap is not bridged and the evening block stays out.
    func testEnabledCutDeclinesADenselyObservedGap() {
        let union = juanShapedUnion()
        let on = BulkSleep.latestNightRecords(from: union, observedGapCoverageCut: 0.5)
        XCTAssertNotNil(firstKept(on))
        XCTAssertGreaterThan(firstKept(on)!, at(21, 40),
                             "the evening block must NOT be absorbed once the guard is on")
    }

    /// THE CASE THE CHAIN EXISTS FOR MUST SURVIVE. Two fragments of one night separated by an EMPTY
    /// HOLE — a missed drain, no records at all. Coverage is 0, so the guard declines to decline and
    /// the earlier fragment is still stitched in, at every cut.
    func testEnabledCutStillStitchesAnUnobservedHole() {
        let union = still(at(22, 0), at(1, 0, dayOffset: 1))            // fragment 1
            + still(at(4, 0, dayOffset: 1), at(7, 0, dayOffset: 1))     // fragment 2, 3 h hole between
        for cut in [0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
            let on = BulkSleep.latestNightRecords(from: union, observedGapCoverageCut: cut)
            XCTAssertNotNil(firstKept(on), "cut \(cut)")
            XCTAssertLessThanOrEqual(firstKept(on)!, at(22, 0),
                                     "cut \(cut): a multi-drain hole must still be stitched")
        }
    }

    /// ⚠️ THE COST, ASSERTED RATHER THAN HIDDEN. A GENUINELY FRAGMENTED night — asleep 22:00, up and
    /// moving 01:00→01:45 with the ring on the finger and recording, asleep again until 07:00 — is
    /// indistinguishable from Juan's evening block by this discriminator: both gaps are densely
    /// observed. With the guard ON the first bout is dropped and the night opens at 01:45.
    /// This is the known false-positive class, and it is now SHIPPED ON: the assertion below is the
    /// standing cost of the default, not a hypothetical.
    func testEnabledCutAlsoDropsARealMidNightBout() {
        let union = still(at(22, 0), at(1, 0, dayOffset: 1))
            + moving(at(1, 0, dayOffset: 1), at(1, 45, dayOffset: 1))
            + still(at(1, 45, dayOffset: 1), at(7, 0, dayOffset: 1))
        let off = BulkSleep.latestNightRecords(from: union, observedGapCoverageCut: 0)
        let on = BulkSleep.latestNightRecords(from: union)   // shipped default
        XCTAssertLessThanOrEqual(firstKept(off)!, at(22, 0), "master keeps the first bout")
        XCTAssertGreaterThan(firstKept(on)!, at(1, 0, dayOffset: 1),
                             "the guard drops it — documented cost, not a surprise")
    }

    /// A gap at or below `onsetContiguityGap` (450 s) is detector granularity, never judged. Both
    /// real corpus cases of this shape (R1 2026-08-16, R3 2026-07-04) are ~30 s splits.
    func testShortDetectorSplitIsNeverJudged() {
        let union = still(at(22, 0), at(1, 0, dayOffset: 1))
            + moving(at(1, 0, dayOffset: 1), at(1, 5, dayOffset: 1))   // 300 s < 450 s
            + still(at(1, 5, dayOffset: 1), at(7, 0, dayOffset: 1))
        for cut in [0.1, 0.5, 1.0] {
            let on = BulkSleep.latestNightRecords(from: union, observedGapCoverageCut: cut)
            XCTAssertNotNil(firstKept(on), "cut \(cut)")
            XCTAssertLessThanOrEqual(firstKept(on)!, at(22, 0),
                                     "cut \(cut): a sub-450 s split must never be treated as a gap")
        }
    }
}
