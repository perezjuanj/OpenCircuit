// #193 — the leading edge must not be carried across an UNOBSERVED data hole.
//
// Two coupled behaviours, both gated by the single `motionGapSubSampleCorrection` kill switch:
//   1. `detect`'s gap-break budget is measured in SAMPLE space, but `BulkSleep.motionTimeline`
//      expands each 150 s epoch into five samples at `start + k*30 s`, so the distance between the
//      last sample of one epoch and the first of the next is `hole - 120 s`. Without the correction
//      the detector under-measures every hole by exactly 120 s.
//   2. `filterMerge` may not hand a short run's boundary to a run on the far side of a hole.
//
// 🟢 GROUNDED on 2026-08-09 (AD/Gen2, build 39). The ring sat in its charging case 22:19:38 →
// 22:35:12 — 59 `0x10`/`0x87` descriptors with the decoded charger byte `[2] == 0x04`, battery
// 58 % → 81 %, 3936 → 4385 mV, skin temp 23.8–25.1 °C — leaving a 1281 s hole between the records
// at 22:14:57 and 22:36:18. `BulkSleep.contiguousFragments` (record-to-record, 1200 s) split there;
// `detect` saw 1161 s and did not, so `BulkSleep.mainSleep` returned a block opening at 22:10:27,
// 26 min before the ring was back on a wrist and spanning the whole charge cycle. Both fixtures
// below reproduce that shape.
//
// ⚠️ FIXTURE DISCIPLINE (the flat-motion trap): a CONSTANT motion value de-floors to STILL, so an
// "awake" stretch expressed as a constant high value stages as SLEEP and the assertions go vacuous.
// The awake stretches here are therefore expressed as a HIGH value punctuated by periodic dips, so
// the rolling low-percentile floor stays low and the samples genuinely read as movement. Every
// fixture asserts its own premise before asserting the behaviour under test.

import XCTest
@testable import OpenCircuitKit

final class DataHoleFenceTests: XCTestCase {

    private let epoch: TimeInterval = 150
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Build a motion timeline exactly the way `BulkSleep.motionTimeline` does: five samples per
    /// 150 s epoch at `start + k*30 s`.
    private func timeline(_ epochs: [(start: Date, values: [Float])]) -> [MotionSample] {
        var out: [MotionSample] = []
        for e in epochs {
            for k in 0 ..< 5 {
                out.append(MotionSample(time: e.start.addingTimeInterval(Double(k) * 30),
                                        movement: e.values[k]))
            }
        }
        return out
    }

    /// A moving epoch: high, with one dip, so the rolling p10 floor stays low and the de-floored
    /// magnitude is genuinely large (NOT a flat plateau, which would cancel to still).
    private func moving(_ i: Int) -> [Float] {
        i.isMultiple(of: 3) ? [1, 60, 55, 70, 65] : [58, 62, 54, 71, 66]
    }
    /// A still epoch: the Gen-2 idle floor.
    private let still: [Float] = [1, 1, 1, 1, 1]

    /// active head → short still stub → HOLE → long still night.
    /// `holeSeconds` is the distance between RECORD starts across the hole.
    private func chargeShapedNight(holeSeconds: TimeInterval,
                                   stubEpochs: Int = 4,
                                   headEpochs: Int = 12,
                                   tailEpochs: Int = 200)
    -> (timeline: [MotionSample], stubStart: Date, postHoleStart: Date) {
        var epochs: [(start: Date, values: [Float])] = []
        var t = t0
        for i in 0 ..< headEpochs { epochs.append((t, moving(i))); t = t.addingTimeInterval(epoch) }
        let stubStart = t
        for _ in 0 ..< stubEpochs { epochs.append((t, still)); t = t.addingTimeInterval(epoch) }
        // `t` currently points one epoch past the last stub record; step back to that record and
        // then forward by the hole, so `holeSeconds` really is record-start to record-start.
        let postHoleStart = t.addingTimeInterval(-epoch).addingTimeInterval(holeSeconds)
        t = postHoleStart
        for _ in 0 ..< tailEpochs { epochs.append((t, still)); t = t.addingTimeInterval(epoch) }
        return (timeline(epochs), stubStart, postHoleStart)
    }

    // MARK: - the kill switch and its arithmetic

    func testCorrectionEqualsTheMotionTimelineSubSampleSpan() {
        // `motionTimeline` emits k = 0…4 at 30 s, so the last sub-sample sits 4 × 30 = 120 s past
        // the epoch start. The correction MUST equal that span or the budget is arbitrary.
        XCTAssertEqual(ActivityPeriod.motionGapSubSampleCorrection, 4 * 30)
    }

    func testTheMotionTimelineReallyPutsItsLastSampleOneCorrectionPastTheEpochStart() {
        // Pins the premise the correction is derived from, against the real builder — so a change to
        // `motionTimeline`'s expansion cannot silently invalidate the constant.
        let recs = TestRecordBuilder.records(count: 2, startingAt: t0, motion: [1, 1, 1, 1, 1])
        let tl = BulkSleep.motionTimeline(from: recs)
        let firstEpochSamples = tl.filter { $0.time < t0.addingTimeInterval(epoch) }
        XCTAssertEqual(firstEpochSamples.count, 5)
        XCTAssertEqual(firstEpochSamples.last!.time.timeIntervalSince(t0),
                       ActivityPeriod.motionGapSubSampleCorrection)
    }

    // MARK: - 1. the gap-break budget

    func testAHoleJustOverTheRecordBudgetBreaksTheRun() {
        // 1281 s — the measured 2026-08-09 charge hole. In sample space that is 1161 s, which is
        // UNDER the raw 1200 s budget: only the correction makes the detector break here.
        let n = chargeShapedNight(holeSeconds: 1281)
        let periods = ActivityPeriod.detectFromMotion(n.timeline)
        XCTAssertFalse(periods.contains { $0.start < n.stubStart.addingTimeInterval(epoch)
                                          && $0.end > n.postHoleStart },
                       "no period may span the hole")
    }

    func testAHoleUnderTheRecordBudgetStillBridges() {
        // 1000 s is a real hole but under `gravityMaxGap` at BOTH ends of the arithmetic. Guards
        // against the correction over-breaking ordinary drain jitter (measured: 5–30 min holes are
        // routine while the ring is worn — see `BulkSleep.onsetContiguityGap`).
        let n = chargeShapedNight(holeSeconds: 1000)
        let periods = ActivityPeriod.detectFromMotion(n.timeline)
        let block = ActivityPeriod.mainSleepBlock(periods)
        XCTAssertNotNil(block)
        // The exact boundary is where the rolling still-classification flips inside the stub; what
        // matters is that the night still OPENS BEFORE the hole, exactly as before #193.
        XCTAssertLessThan(block!.start, n.postHoleStart,
                          "a sub-budget hole must still bridge, exactly as before #193")
    }

    func testTheBudgetBoundaryIsTheRecordGapNotTheSampleGap() {
        // 1201 s of records = 1081 s of samples: over the corrected budget (1080), under the raw one.
        let over = chargeShapedNight(holeSeconds: 1201)
        XCTAssertEqual(ActivityPeriod.mainSleepBlock(ActivityPeriod.detectFromMotion(over.timeline))?.start,
                       over.postHoleStart)
        // 1200 s of records = 1080 s of samples: NOT over the corrected budget (strict `>`), so the
        // run is not broken and the night still opens before the hole.
        let under = chargeShapedNight(holeSeconds: 1200)
        let underStart = ActivityPeriod.mainSleepBlock(ActivityPeriod.detectFromMotion(under.timeline))?.start
        XCTAssertNotNil(underStart)
        XCTAssertLessThan(underStart!, under.postHoleStart)
    }

    // MARK: - 2. the merge fence

    func testShortStillStubDoesNotDonateItsStartAcrossTheHole() {
        // THE 2026-08-09 SHAPE. The stub is 4 epochs = 10 min, i.e. under
        // `activityChangeThreshold` (15 min), so `filterMerge` wants to hand its START to the run
        // after it — which lives on the far side of the charge hole. That is what put the night's
        // leading edge 26 min before the ring was back on a wrist.
        let n = chargeShapedNight(holeSeconds: 1281)
        let periods = ActivityPeriod.detectFromMotion(n.timeline)
        let block = ActivityPeriod.mainSleepBlock(periods)
        XCTAssertNotNil(block, "the long still tail must still be detected as the night")
        XCTAssertEqual(block!.start, n.postHoleStart,
                       "the night must open on the first OBSERVED epoch after the hole, not on the "
                       + "pre-hole stub")
        XCTAssertGreaterThan(block!.start, n.stubStart)
    }

    func testTheStubIsFoldedIntoThePrecedingRunRatherThanDropped() {
        // The fence must not silently delete measured time: the stub joins the run BEFORE the hole.
        let n = chargeShapedNight(holeSeconds: 1281)
        let periods = ActivityPeriod.detectFromMotion(n.timeline)
        let covering = periods.first { $0.start <= n.stubStart && $0.end >= n.stubStart }
        XCTAssertNotNil(covering, "the stub's time must still be covered by some period")
        XCTAssertLessThan(covering!.start, n.stubStart, "…by the run that precedes the hole")
    }

    func testAHoleFreeTimelineIsUnaffectedByTheFence() {
        // Byte-identity guard: with no hole, `afterHole` is false everywhere and `filterMerge` runs
        // openwhoop's branch order. A 10-min still stub inside a moving stretch still merges.
        var epochs: [(start: Date, values: [Float])] = []
        var t = t0
        for i in 0 ..< 12 { epochs.append((t, moving(i))); t = t.addingTimeInterval(epoch) }
        for _ in 0 ..< 4 { epochs.append((t, still)); t = t.addingTimeInterval(epoch) }
        for i in 0 ..< 12 { epochs.append((t, moving(i))); t = t.addingTimeInterval(epoch) }
        let periods = ActivityPeriod.detectFromMotion(timeline(epochs))
        XCTAssertFalse(periods.contains { $0.activity == .sleep },
                       "a sub-threshold still stub between two moving runs is absorbed, not promoted")
    }

    // MARK: - the fence is symmetric: a stub AFTER the hole may not reach back either

    func testTailStubAfterAHoleDoesNotExtendTheNightBackAcrossIt() {
        // Mirror of the leading-edge case at the TRAILING edge: a long night, a hole, then a short
        // still stub at the end of the data. `filterMerge`'s last-segment branch would hand the
        // stub's END to the run before the hole, growing the night across unobserved time — the
        // same class of artefact #190 fixed at the wake.
        var epochs: [(start: Date, values: [Float])] = []
        var t = t0
        for _ in 0 ..< 200 { epochs.append((t, still)); t = t.addingTimeInterval(epoch) }
        let lastPreHole = t.addingTimeInterval(-epoch)
        t = lastPreHole.addingTimeInterval(1281)
        let postHoleStart = t
        for _ in 0 ..< 4 { epochs.append((t, still)); t = t.addingTimeInterval(epoch) }

        let periods = ActivityPeriod.detectFromMotion(timeline(epochs))
        let block = ActivityPeriod.mainSleepBlock(periods)
        XCTAssertNotNil(block)
        XCTAssertLessThan(block!.end, postHoleStart,
                          "the night must end on the last OBSERVED epoch before the hole")
    }

    func testShortStubFencedByAHoleIsNotUsedToJoinTwoMovingRuns() {
        // `filterMerge`'s prev+next branch swallows a short run when its NEIGHBOURS agree — here
        // both neighbours are `.active`, so without the fence the two moving runs would be welded
        // into one period spanning the hole.
        var epochs: [(start: Date, values: [Float])] = []
        var t = t0
        for i in 0 ..< 12 { epochs.append((t, moving(i))); t = t.addingTimeInterval(epoch) }
        let lastPreHole = t.addingTimeInterval(-epoch)
        t = lastPreHole.addingTimeInterval(1281)
        let postHoleStart = t
        for _ in 0 ..< 4 { epochs.append((t, still)); t = t.addingTimeInterval(epoch) }
        for i in 0 ..< 12 { epochs.append((t, moving(i))); t = t.addingTimeInterval(epoch) }

        let periods = ActivityPeriod.detectFromMotion(timeline(epochs))
        XCTAssertFalse(periods.contains { $0.start <= lastPreHole && $0.end >= postHoleStart },
                       "no period may be welded across the hole — got \(periods.map { "\($0.activity) \($0.start.timeIntervalSince(t0))→\($0.end.timeIntervalSince(t0))" }) hole \(lastPreHole.timeIntervalSince(t0))→\(postHoleStart.timeIntervalSince(t0))")
    }

    // MARK: - the whole pipeline, through BulkSleep

    func testMainSleepDoesNotOpenBeforeAChargeShapedHole() {
        // End-to-end through the real record type and `BulkSleep.mainSleep`, which is what
        // `latestNightRecords`, `NapDetection` and `personalSleepBaseline` all consume.
        var recs: [BulkRecord] = []
        var t = t0
        for i in 0 ..< 12 {
            recs += TestRecordBuilder.records(count: 1, startingAt: t, motion: moving(i), heartRate: 70)
            t = t.addingTimeInterval(epoch)
        }
        let stubStart = t
        for _ in 0 ..< 4 {
            recs += TestRecordBuilder.records(count: 1, startingAt: t, motion: [1, 1, 1, 1, 1], heartRate: 62)
            t = t.addingTimeInterval(epoch)
        }
        let postHoleStart = t.addingTimeInterval(-epoch).addingTimeInterval(1281)
        t = postHoleStart
        for _ in 0 ..< 200 {
            recs += TestRecordBuilder.records(count: 1, startingAt: t, motion: [1, 1, 1, 1, 1], heartRate: 50)
            t = t.addingTimeInterval(epoch)
        }
        let block = BulkSleep.mainSleep(from: recs)
        XCTAssertNotNil(block)
        XCTAssertEqual(block!.start, postHoleStart)
        XCTAssertGreaterThan(block!.start, stubStart)
    }
}

/// Minimal 23-byte `0x4c` record builder for these fixtures. Layout follows PROTOCOL.md §5.3:
/// `[0:4]` epoch counter (BE), `[4]` HR, `[5]` HRV, `[8]` SpO2/sentinel, `[10:15]` motion.
enum TestRecordBuilder {
    static func records(count: Int, startingAt start: Date, motion: [Float],
                        heartRate: Int = 60) -> [BulkRecord] {
        (0 ..< count).compactMap { i in
            let t = start.addingTimeInterval(Double(i) * 150)
            let counter = UInt32(Int(t.timeIntervalSince1970) - Command.syncEpoch)
            var b = [UInt8](repeating: 0, count: 23)
            b[0] = UInt8((counter >> 24) & 0xff); b[1] = UInt8((counter >> 16) & 0xff)
            b[2] = UInt8((counter >> 8) & 0xff);  b[3] = UInt8(counter & 0xff)
            b[4] = UInt8(clamping: heartRate)
            b[8] = 0x12                                  // "no SpO2 here" sentinel → activity layout
            for k in 0 ..< 5 { b[10 + k] = UInt8(clamping: Int(motion[k])) }
            return BulkRecord(b)
        }
    }
}
