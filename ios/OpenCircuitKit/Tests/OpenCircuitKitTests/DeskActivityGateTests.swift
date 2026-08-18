import XCTest
@testable import OpenCircuitKit

// #204 — the DESK-ACTIVITY wake gate.
//
// 🟢 GROUNDED on two ground-truthed evenings from one wearer (FR02.018, Gen 2, Australia/Melbourne)
// who was sitting at a computer. The primary `[10:15]` motion channel reads the SAME value at a
// keyboard as it does in deep sleep — 0 of 61 epochs above baseline on 2026-08-17, 0 of 157 during
// that night's real sleep — so the detector could not break the run and produced ONE unbroken
// 14 h 03 m "sleep" block, 17:49:54 → 07:53:12, with sleep credited from 19:40.
//
// The ring's OWN activity magnitudes (`[15:23)`, 🟢 #195) do separate the two. Share of epochs
// reading ALL-ZERO, measured on both nights:
//     real sleep            72 % / 79 %
//     at a computer          0 % /  2 %
//     up and about           0 % / 10 %
//     evening dozing        14 %
// The gate thresholds that share over a rolling window. Replayed byte-exactly against both archives
// it moves the 2026-08-18 night 19:40 → 01:20 (wearer reports being at a computer until 00:30) and
// leaves the already-correct 2026-08-16 night at 01:02 against a shipped 01:00.
//
// ⚠️ FIXTURE DISCIPLINE (the flat-motion trap, inherited from SleepStagingLeadingWakeTests): a
// CONSTANT motion byte de-floors to STILL, so an "awake" stretch built from a constant value stages
// as SLEEP. That is exactly the shape under test — the evening must be awake on the ACTIVITY
// MAGNITUDES ALONE — so every fixture keeps `[10:15]` uniformly still and each test asserts its
// premise (the kill-switch run) before asserting the fix.
final class DeskActivityGateTests: XCTestCase {

    private let step: UInt32 = 150
    private let base: UInt32 = 0x0c220000

    /// Pack five 12-bit magnitudes into `[15:23)` exactly as `activityMagnitudes` decodes them:
    /// magnitude *k* is nibbles 3k, 3k+1, 3k+2 counting from the HIGH nibble of `[15]`.
    private func packMagnitudes(_ m: [Int], into b: inout [UInt8]) {
        var nibbles = [UInt8]()
        for v in m {
            nibbles.append(UInt8((v >> 8) & 0xf))
            nibbles.append(UInt8((v >> 4) & 0xf))
            nibbles.append(UInt8(v & 0xf))
        }
        for (i, n) in nibbles.enumerated() {
            let idx = 15 + i / 2
            if i.isMultiple(of: 2) { b[idx] = (b[idx] & 0x0f) | (n << 4) }
            else { b[idx] = (b[idx] & 0xf0) | n }
        }
    }

    /// One epoch. `magnitude` 0 ⇒ the ring says nothing moved; > 0 ⇒ it recorded activity.
    /// `motion` stays uniform so the primary channel always reads STILL (see fixture discipline).
    private func rec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 0, magnitude: Int,
                     motion: UInt8 = 1) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr
        b[5] = hrv
        b[8] = hrv > 0 ? 0x62 : 0x12          // sleep-vitals vs activity template
        for k in 0 ..< 5 { b[10 + k] = motion }
        packMagnitudes([Int](repeating: magnitude, count: 5), into: &b)
        return BulkRecord(b)!
    }

    private func date(_ counter: UInt32) -> Date {
        Date(timeIntervalSince1970: Double(Int(counter) + Command.syncEpoch))
    }

    /// `eveningEpochs` still-but-ACTIVE epochs (non-zero magnitudes), then `nightEpochs` still and
    /// quiet ones. Motion is uniformly still throughout, so ONLY the magnitudes differ.
    private func night(eveningEpochs: Int, nightEpochs: Int,
                       eveningMagnitude: Int = 300) -> [BulkRecord] {
        var out: [BulkRecord] = []
        for i in 0 ..< eveningEpochs {
            out.append(rec(base + UInt32(i) * step, hr: 75, magnitude: eveningMagnitude))
        }
        for i in 0 ..< nightEpochs {
            out.append(rec(base + UInt32(eveningEpochs + i) * step, hr: 55, hrv: 55, magnitude: 0))
        }
        return out
    }

    private func mainBlock(_ records: [BulkRecord], threshold: Double) -> ActivityPeriod? {
        ActivityPeriod.mainSleepBlock(
            ActivityPeriod.detectFromMotion(BulkSleep.motionTimeline(from: records),
                                            temperatureSamples: [],
                                            heartRateSamples: BulkSleep.heartRateTimeline(from: records),
                                            sleepVitalTimes: BulkSleep.sleepVitalTimeline(from: records),
                                            activityQuiet: BulkSleep.activityQuietTimeline(from: records),
                                            threshold: threshold))
    }

    // MARK: - The fix

    func testDeskEveningIsSplitOffTheNight() {
        let evening = 60, nightLen = 120           // 2 h 30 m desk, then 5 h asleep
        let records = night(eveningEpochs: evening, nightEpochs: nightLen)
        let nightStart = date(base + UInt32(evening) * step)

        // PREMISE (kill switch): with the gate off the evening and the night are ONE block that
        // opens at the very first epoch — the reported bug shape.
        guard let off = mainBlock(records, threshold: 0) else { return XCTFail("no block with gate off") }
        XCTAssertEqual(off.start, date(base), "premise: gate off welds evening to night")
        XCTAssertGreaterThan(nightStart.timeIntervalSince(off.start), 2 * 3600)

        // FIX: the block now opens at the night, within one rolling half-window of its true start.
        guard let on = mainBlock(records, threshold: ActivityPeriod.deskWakeZeroShareThreshold) else {
            return XCTFail("no block with gate on")
        }
        let halfWindow = Double(ActivityPeriod.deskWakeWindowEpochs / 2) * Double(BulkRecord.epochSeconds)
        XCTAssertEqual(on.start.timeIntervalSince(nightStart), 0, accuracy: halfWindow,
                       "block should open at the quiet night, not the desk evening")
        XCTAssertGreaterThan(on.start.timeIntervalSince(off.start), 2 * 3600 - halfWindow)
    }

    // MARK: - Safety properties

    func testKillSwitchIsByteIdenticalToOmittingTheTimeline() {
        let records = night(eveningEpochs: 60, nightEpochs: 120)
        let motion = BulkSleep.motionTimeline(from: records)
        let withTimelineDisabled = ActivityPeriod.detectFromMotion(
            motion, activityQuiet: BulkSleep.activityQuietTimeline(from: records), threshold: 0)
        let withoutTimeline = ActivityPeriod.detectFromMotion(motion)
        XCTAssertEqual(withTimelineDisabled, withoutTimeline,
                       "threshold 0 must be byte-identical to pre-#204")
    }

    func testEmptyActivityTimelineIsANoOp() {
        let records = night(eveningEpochs: 60, nightEpochs: 120)
        let motion = BulkSleep.motionTimeline(from: records)
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion, activityQuiet: []),
                       ActivityPeriod.detectFromMotion(motion))
    }

    func testAllQuietNightIsUntouched() {
        // Every epoch reads all-zero magnitudes — a motionless archive. The gate must not fire.
        let records = (0 ..< 120).map { rec(base + UInt32($0) * step, hr: 55, hrv: 55, magnitude: 0) }
        let motion = BulkSleep.motionTimeline(from: records)
        XCTAssertEqual(
            ActivityPeriod.detectFromMotion(motion,
                                            activityQuiet: BulkSleep.activityQuietTimeline(from: records)),
            ActivityPeriod.detectFromMotion(motion),
            "a night the ring reports as motionless must be unchanged")
    }

    func testOccasionalStirringDoesNotVetoSleep() {
        // A real night stirs: ~25 % of the wearer's measured sleep epochs carry non-zero magnitudes.
        // Every 4th epoch active is well inside the window threshold and must stay asleep.
        var records: [BulkRecord] = []
        for i in 0 ..< 160 {
            records.append(rec(base + UInt32(i) * step, hr: 55, hrv: 55,
                               magnitude: i.isMultiple(of: 4) ? 400 : 0))
        }
        guard let block = mainBlock(records, threshold: ActivityPeriod.deskWakeZeroShareThreshold) else {
            return XCTFail("stirring night lost its block entirely")
        }
        XCTAssertEqual(block.start, date(base), "a stirring night must keep its full span")
    }

    // MARK: - Units

    func testRollingShareThresholdBoundary() {
        // 20 epochs, 7 quiet ⇒ share 0.35 at the centre. The predicate is STRICTLY less-than, so a
        // window sitting exactly ON the threshold counts as sleep, not wake.
        let quiet = (0 ..< 20).map {
            ActivityQuietSample(time: self.date(self.base + UInt32($0) * self.step), quiet: $0 < 7)
        }
        let atThreshold = ActivityPeriod.deskActivityAwake(quiet, threshold: 0.35, windowEpochs: 20)
        let justAbove = ActivityPeriod.deskActivityAwake(quiet, threshold: 0.36, windowEpochs: 20)
        XCTAssertFalse(atThreshold[10], "share == threshold is not awake (strict <)")
        XCTAssertTrue(justAbove[10], "share just under threshold is awake")
    }

    func testZeroThresholdMarksNothingAwake() {
        let quiet = (0 ..< 20).map {
            ActivityQuietSample(time: self.date(self.base + UInt32($0) * self.step), quiet: false)
        }
        XCTAssertFalse(ActivityPeriod.deskActivityAwake(quiet, threshold: 0, windowEpochs: 18).contains(true))
    }

    func testEpochIndexRefusesToMatchAcrossADataHole() {
        let starts = [date(base), date(base + step)]
        // A sample one step past the LAST epoch belongs to no epoch — it sits in the hole after it.
        XCTAssertNil(ActivityPeriod.epochIndex(for: date(base + step * 2), starts: starts))
        XCTAssertEqual(ActivityPeriod.epochIndex(for: date(base + step + 30), starts: starts), 1)
        XCTAssertNil(ActivityPeriod.epochIndex(for: date(base - 1), starts: starts),
                     "a sample before the first epoch matches nothing")
    }

    func testIdleEpochsAreExcludedFromTheEvidence() {
        // The idle/unworn template zeroes the activity block BY TEMPLATE, not by measurement, so it
        // must not vouch for the stillness of the epochs around it.
        var idle = [UInt8](repeating: 0, count: 23)
        idle[0] = UInt8(base >> 24); idle[1] = UInt8((base >> 16) & 0xFF)
        idle[2] = UInt8((base >> 8) & 0xFF); idle[3] = UInt8(base & 0xFF)
        idle[4] = 0x05; idle[5] = 0x00; idle[6] = 0x0c; idle[7] = 0x00; idle[9] = 0x0a
        for k in 0 ..< 5 { idle[10 + k] = 1 }
        let idleRecord = BulkRecord(idle)!
        XCTAssertEqual(idleRecord.layout, .idle, "premise: this is the idle template")

        let records = [idleRecord, rec(base + step, hr: 75, magnitude: 300)]
        let quiet = BulkSleep.activityQuietTimeline(from: records)
        XCTAssertEqual(quiet.count, 1, "the idle epoch contributes no evidence")
        XCTAssertFalse(quiet[0].quiet)
    }
}
