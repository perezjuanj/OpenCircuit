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
/// ⚠️ THE DEFAULT IS 0.95 = ON. See the constant's doc comment for why that value (a completeness
/// threshold read off the measured gap geometry, not a fit to the labelled score). On the
/// 2026-08-19 corpus it changes exactly ONE night — this one — and leaves 20 of 21 staged nights
/// bit-for-bit identical. A lower cut (anything ≤ 0.894) additionally moves `R3_2026-08-12`, whose
/// bridged gap is genuinely missing an epoch and which carries no recoverable in-bed ground truth,
/// so the corpus cannot say whether that would help it or truncate a fragmented night.
/// `= 0` is the one-constant revert and is pinned byte-identical below.
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

    /// The shipped default must be REACHABLE at every gap length the guard is allowed to judge.
    ///
    /// ⚠️ This test previously asserted `cut <= (n-1)/n` at the shortest judgeable gap, on the model
    /// that a fully observed gap tops out at `(n-1)/n`. That model assumes both gap endpoints sit on
    /// the 150 s record grid. They do not — the endpoints are `ActivityPeriod` block boundaries — and
    /// with off-grid endpoints a full gap reaches `⌈L⌉/L`, which EXCEEDS 1.0 at non-integer `L`.
    /// The corpus proves it: `R3_2026-08-19`'s 43-min bridge reads 0.988 where the old model said
    /// 0.930 was the maximum. See `ObservedGapCeilingProbeTests` for the measured band.
    ///
    /// The honest statement is therefore weaker and is what is asserted here: every cut ≤ 1.0 is
    /// reachable. At gaps under ~60 min a fully observed gap can also read BELOW 0.95 in an unlucky
    /// alignment, in which case the guard declines to fire — a false negative that reproduces
    /// master's behaviour, which is the safe direction.
    func testShippedDefaultIsReachableAtEveryJudgeableGapLength() {
        let cadence = Double(BulkRecord.epochSeconds)
        let cut = BulkSleep.observedGapAbsorbCoverageCut
        XCTAssertLessThanOrEqual(cut, 1.0, "a cut above 1.0 would need a super-complete gap")

        for gapMinutes in [7.5, 10.0, 20.0, 30.0, 43.0, 60.0, 360.0] {
            let gap = gapMinutes * 60.0
            guard gap > BulkSleep.onsetContiguityGap else { continue }
            var maxInterior = 0
            for step in 0..<Int(cadence) {
                var count = 0
                var t = Double(step)
                while t < gap { if t > 0 { count += 1 }; t += cadence }
                maxInterior = max(maxInterior, count)
            }
            let achievable = Double(maxInterior) / (gap / cadence)
            XCTAssertGreaterThanOrEqual(achievable, cut,
                                        "cut \(cut) is unreachable at a \(gapMinutes) min gap "
                                        + "(max achievable \(achievable)) — the guard would be inert "
                                        + "there for an arithmetic reason, not a physical one")
        }
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

    // MARK: - The declined-bridge re-anchor (`BulkSleep.declinedBridgeMayReanchor`)

    /// 🟢 THE REAL TESTER SHAPE THE RE-ANCHOR EXISTS FOR (Gen 2, FR02.018, 2026-08-24).
    ///
    /// A LONG first bout, a completely-observed hour awake, then a SHORTER trailing bout. The tail
    /// ends latest so it anchors; the guard then declines the bridge back (the gap is real, observed
    /// awake time — the guard is right about that), and master is left with the SHORT bout standing
    /// alone as "the night". On her real archive that slice re-detected as `.active` and the night
    /// staged as ZERO segments — every drain from 04:47 onward reported `noStagedSegments`, so the
    /// stored row froze and ~1 h 32 m of measured sleep never landed.
    ///
    /// The rule asserted here needs no threshold: **the guard may separate two bouts, but it may
    /// never make the SMALLER bout the night.** The two bouts still are NOT bridged — that is the
    /// guard's actual purpose and it is preserved (asserted below).
    func testDeclinedBridgeReanchorsOntoTheLongerOrphanedBout() {
        let union = still(at(20, 30), at(2, 45, dayOffset: 1))            // 6 h 15 m — the real night
            + moving(at(2, 45, dayOffset: 1), at(3, 45, dayOffset: 1))    // 60 min, fully observed
            + still(at(3, 45, dayOffset: 1), at(6, 0, dayOffset: 1))      // 2 h 15 m — the short tail

        let master = BulkSleep.latestNightRecords(from: union, declinedBridgeMayReanchor: false)
        XCTAssertNotNil(firstKept(master))
        XCTAssertGreaterThan(firstKept(master)!, at(2, 45, dayOffset: 1),
                             "the fixture must reproduce the defect under master, or this test is "
                             + "vacuous: the short tail should be all that survives")

        let fixed = BulkSleep.latestNightRecords(from: union)
        XCTAssertNotNil(firstKept(fixed))
        XCTAssertLessThanOrEqual(firstKept(fixed)!, at(20, 30).addingTimeInterval(150),
                                 "the re-anchor must return the LONGER first bout")
        // …and it must still NOT bridge: the observed awake hour stays outside the night, so the
        // slice must end before the tail. (The +30 min `margin` in `latestNightRecords` is why this
        // compares against 03:15 rather than 02:45.)
        XCTAssertLessThan(fixed.map { $0.date() }.max()!, at(3, 45, dayOffset: 1),
                          "the re-anchor must not become a back-door bridge across measured awake time")
    }

    /// ⚠️ THE BOUND THAT KEEPS THE RE-ANCHOR FROM EATING THE PREVIOUS NIGHT — and it is not
    /// hypothetical. Written after the first draft of the re-anchor, which omitted
    /// `maxIntraNightGap`, was MEASURED re-anchoring the Gen 2 Air tester's 08-23 22:45 → 02:41
    /// night onto her PREVIOUS night (08-23 01:01 → 08:54, 473 min, 13 h 50 m earlier): the ring
    /// records all day, so the daytime span between them is ≥ 0.95 covered and the coverage test
    /// alone "declines" it. Staged 08-23 01:01 → 09:06 in place of the real night, `dStart` −1304 min.
    ///
    /// The re-anchor may only rescue a block the GUARD orphaned — never one the DISTANCE rule
    /// already, and correctly, rejected.
    func testReanchorNeverReachesBackPastMaxIntraNightGap() {
        // A long previous night, a full day of worn records, then a shorter real night.
        let union = still(at(1, 0), at(8, 54))                             // 7 h 54 m, previous night
            + moving(at(8, 54), at(22, 45))                                // all-day worn coverage
            + still(at(22, 45), at(2, 41, dayOffset: 1))                   // 3 h 56 m, the real night

        let scoped = BulkSleep.latestNightRecords(from: union)
        XCTAssertNotNil(firstKept(scoped))
        XCTAssertGreaterThan(firstKept(scoped)!, at(20, 0),
                             "the real night must survive — a re-anchor onto the previous night is "
                             + "the ANCHOR EVICTION failure `latestNightRecords` is built to prevent")
        XCTAssertEqual(BulkSleep.latestNightRecords(from: union, declinedBridgeMayReanchor: false)
                        .map { $0.date() },
                       scoped.map { $0.date() },
                       "with the distance bound respected, this shape must be identical either way")
    }

    /// `declinedBridgeMayReanchor == false` is the kill switch and must be byte-identical to the
    /// pre-re-anchor code. Asserted on the fixture the default DOES change, so it cannot go vacuous.
    func testReanchorKillSwitchIsByteIdentical() {
        let union = still(at(20, 30), at(2, 45, dayOffset: 1))
            + moving(at(2, 45, dayOffset: 1), at(3, 45, dayOffset: 1))
            + still(at(3, 45, dayOffset: 1), at(6, 0, dayOffset: 1))

        let off = BulkSleep.latestNightRecords(from: union, declinedBridgeMayReanchor: false)
        let on = BulkSleep.latestNightRecords(from: union)
        XCTAssertNotEqual(off.map { $0.date() }, on.map { $0.date() },
                          "if these ever match, this kill-switch test has gone vacuous")
        XCTAssertTrue(BulkSleep.declinedBridgeMayReanchor,
                      "the shipped default is expected to be ON; if it is reverted, flip this test")
    }

    /// The re-anchor is strictly NARROWER than reverting the guard, and this pins the difference.
    /// When the LATER bout is the longer one — the shape `testEnabledCutAlsoDropsARealMidNightBout`
    /// asserts — nothing changes, because no smaller bout is being promoted over a larger one.
    /// ⚠️ That remains a real, known, UNFIXED cost of the guard (a genuine first bout is still
    /// dropped when the second is longer); the re-anchor does not claim to address it.
    func testReanchorDoesNotFireWhenTheLaterBoutIsLonger() {
        let union = still(at(22, 0), at(1, 0, dayOffset: 1))
            + moving(at(1, 0, dayOffset: 1), at(1, 45, dayOffset: 1))
            + still(at(1, 45, dayOffset: 1), at(7, 0, dayOffset: 1))
        XCTAssertEqual(BulkSleep.latestNightRecords(from: union).map { $0.date() },
                       BulkSleep.latestNightRecords(from: union, declinedBridgeMayReanchor: false)
                        .map { $0.date() },
                       "a longer later bout is not a smaller-bout promotion — leave it alone")
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
