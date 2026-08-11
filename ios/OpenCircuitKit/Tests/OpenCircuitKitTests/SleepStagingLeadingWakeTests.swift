import XCTest
@testable import OpenCircuitKit

// #202 — sleep ONSET manufactured by eroding the awake run that OPENS the block.
//
// 🟢 GROUNDED on the 2026-08-10→11 Gen-3 tester night (FR05.010, build 39, Europe/Paris), replayed
// byte-exactly from that wearer's own `0x4c` records. The motion channel is the `1,1,1,1,1`
// placeholder across the head of the night, so HR is the only lever, and the HR gate DID fire
// correctly: the block opens 21:56:39 and the first four in-block epochs smooth to 72, 72, 67, 66
// against a night floor of 48 and a wake threshold of 66. `erodeShortHRWake` then wiped all four —
// the run is HR-only and 4 < `minHRWakeRunEpochs` (5) — and `sleepSpan` anchored onset on the very
// first epoch, reporting the wearer asleep at 21:58:39 AT HR 74, 26 bpm above the night's floor and
// 13 minutes before HR reached its resting level.
//
// Neither onset pass can undo it, which is why the fix belongs in the erosion and not in a
// threshold: `markDescentOnsetAwake` needs an evening→floor descent of `onsetMinDescentBPM` and the
// elevated head is only 4 of the 12 epochs its median samples (evening 55, floor 48, descent 7),
// and `markLeadInWakeOnset` needs a surviving sustained awake run — which erosion has just removed.
//
// The fix is a SCOPING correction, not a retune: erosion repairs a hole punched IN sleep, and the
// head run has no sleep before it. `rescueSecondBoutHRWake` already states the same asymmetry as
// design intent (its guard (d) exists so "the leading edge is never touched"). With the head exempt
// the tester's night opens at 22:08:39 instead of 21:58:39; over the 10-night local export corpus
// no other night moves by one epoch.
//
// ⚠️ FIXTURE DISCIPLINE (the flat-motion trap): a CONSTANT motion byte de-floors to STILL, so an
// "awake" stretch built from a constant high value stages as SLEEP. That is exactly the shape under
// test here — the head must be awake on HR ALONE — so the fixtures keep motion uniformly still and
// every `classify` case asserts its premise (the kill-switch run) before asserting the fix.
final class SleepStagingLeadingWakeTests: XCTestCase {

    private let step: UInt32 = 150
    private let base: UInt32 = 0x0c220000

    /// A still sleep-vitals epoch carrying HR + HRV. Mirrors `SleepContinuationTests.vrec`.
    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 55, motion: UInt8 = 1) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// A moving activity epoch — the getting-up that closes the night.
    private func arec(_ counter: UInt32, motion: UInt8 = 0x14) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[8] = 0x12
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    private func date(_ counter: UInt32) -> Date {
        Date(timeIntervalSince1970: Double(Int(counter) + Command.syncEpoch))
    }

    /// The #202 shape: `headEpochs` still-but-ELEVATED epochs opening the block, then a long flat
    /// sleep at `sleepHR`, then a moving offset. Motion is uniformly still through head and sleep, so
    /// the head is awake on HR alone — exactly the placeholder night this was measured on.
    private func elevatedHeadNight(headEpochs: Int = 4, headHR: UInt8 = 74,
                                   sleepHR: UInt8 = 50, sleepEpochs: Int = 120)
        -> (records: [BulkRecord], blockStart: Date, firstSleep: Date) {
        var recs: [BulkRecord] = []
        var c = base
        let blockStart = date(c)
        for _ in 0..<headEpochs { recs.append(vrec(c, hr: headHR)); c += step }
        let firstSleep = date(c)
        for _ in 0..<sleepEpochs { recs.append(vrec(c, hr: sleepHR)); c += step }
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        return (recs, blockStart, firstSleep)
    }

    private func onset(_ segs: [SleepSegment]) -> Date? { SleepStaging.sleepWindow(segs)?.onset }

    // MARK: - The pass itself

    /// The defect, stated at the level it happens: a short HR-only run at index 0 is erased.
    func testUnguardedErosionErasesTheRunThatOpensTheBlock() {
        var awake = [true, true, true, true] + [Bool](repeating: false, count: 40)
        SleepStaging.erodeShortHRWake(&awake, motionAwake: [Bool](repeating: false, count: 44),
                                      minRun: 5, protectsLeading: false)
        XCTAssertFalse(awake.contains(true), "pre-#202 behaviour: the head run is eroded away")
    }

    func testHeadRunIsExemptWhenProtected() {
        var awake = [true, true, true, true] + [Bool](repeating: false, count: 40)
        SleepStaging.erodeShortHRWake(&awake, motionAwake: [Bool](repeating: false, count: 44),
                                      minRun: 5, protectsLeading: true)
        XCTAssertEqual(awake.prefix(4), [true, true, true, true])
        XCTAssertFalse(awake.dropFirst(4).contains(true))
    }

    /// The exemption is for the HEAD ONLY — the interior rule it was written for is untouched.
    func testInteriorShortRunIsStillEroded() {
        var awake = [Bool](repeating: false, count: 40)
        for i in 20..<23 { awake[i] = true }
        SleepStaging.erodeShortHRWake(&awake, motionAwake: [Bool](repeating: false, count: 40),
                                      minRun: 5, protectsLeading: true)
        XCTAssertFalse(awake.contains(true), "a REM-ish bump inside sleep must still erode")
    }

    /// A run at index 0 that is already long enough is unaffected either way — the exemption adds
    /// nothing where erosion would not have fired.
    func testLongHeadRunIsUnchangedByTheExemption() {
        let start = [Bool](repeating: true, count: 8) + [Bool](repeating: false, count: 30)
        var on = start, off = start
        let motionless = [Bool](repeating: false, count: 38)
        SleepStaging.erodeShortHRWake(&on, motionAwake: motionless, minRun: 5, protectsLeading: true)
        SleepStaging.erodeShortHRWake(&off, motionAwake: motionless, minRun: 5, protectsLeading: false)
        XCTAssertEqual(on, start)
        XCTAssertEqual(off, start)
    }

    /// A head run containing MOTION was already exempt (a real movement is awake however brief), so
    /// the two settings must agree there too.
    func testMotionBearingHeadRunAgreesOnBothSettings() {
        let start = [true, true] + [Bool](repeating: false, count: 30)
        var motion = [Bool](repeating: false, count: 32); motion[1] = true
        var on = start, off = start
        SleepStaging.erodeShortHRWake(&on, motionAwake: motion, minRun: 5, protectsLeading: true)
        SleepStaging.erodeShortHRWake(&off, motionAwake: motion, minRun: 5, protectsLeading: false)
        XCTAssertEqual(on, start)
        XCTAssertEqual(off, start)
    }

    /// Whatever else it does, the exemption may only ADD leading awake — it can never mark an epoch
    /// asleep that the un-guarded sweep left awake. This is what bounds the change: onset can move
    /// later, never earlier, and time asleep can only fall.
    func testExemptionOnlyEverAddsAwake() {
        for seed in 0..<200 {
            var awake = (0..<40).map { ($0 &* 7 &+ seed) % 5 < 2 }
            let motion = (0..<40).map { ($0 &* 11 &+ seed) % 9 == 0 }
            var off = awake
            SleepStaging.erodeShortHRWake(&awake, motionAwake: motion, minRun: 5, protectsLeading: true)
            SleepStaging.erodeShortHRWake(&off, motionAwake: motion, minRun: 5, protectsLeading: false)
            for i in awake.indices where off[i] {
                XCTAssertTrue(awake[i], "seed \(seed) index \(i): protection turned an awake epoch asleep")
            }
        }
    }

    // MARK: - Wiring (fails if the call site loses the flag)

    func testElevatedHeadNoLongerAnchorsOnset() {
        let night = elevatedHeadNight()
        let unguarded = SleepStaging.classify(from: night.records,
                                              tuning: SleepStaging.Tuning(protectsLeadingHRWake: false))
        // Premise: without the exemption the night really does open ON the elevated head.
        XCTAssertEqual(onset(unguarded), night.blockStart,
                       "premise failed — the fixture is not reproducing the #202 shape")

        let guarded = SleepStaging.classify(from: night.records)
        XCTAssertEqual(onset(guarded), night.firstSleep,
                       "onset must move off the elevated head to the first genuinely-settled epoch")
    }

    /// The in-bed envelope is set by the motion block, not by this pass: the night must not shrink,
    /// only be re-labelled. The recovered minutes become awake-IN-BED.
    func testInBedWindowIsUnchangedAndTheRecoveredHeadBecomesAwake() {
        let night = elevatedHeadNight()
        let off = SleepStaging.summary(
            SleepStaging.classify(from: night.records,
                                  tuning: SleepStaging.Tuning(protectsLeadingHRWake: false))).minutes
        let on = SleepStaging.summary(SleepStaging.classify(from: night.records)).minutes
        XCTAssertEqual(on.inBed, off.inBed, "time in bed is the motion block's, and must not move")
        XCTAssertGreaterThan(on.awake, off.awake)
        XCTAssertEqual(off.asleep - on.asleep, on.awake - off.awake,
                       "the head is re-labelled, not discarded")
    }

    /// A night that genuinely falls asleep at once must be byte-identical under both settings —
    /// the exemption fires only where the HR gate found a real elevated head.
    func testFastOnsetNightIsByteIdentical() {
        var recs: [BulkRecord] = []
        var c = base
        for _ in 0..<120 { recs.append(vrec(c, hr: 50)); c += step }
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let off = SleepStaging.classify(from: recs,
                                        tuning: SleepStaging.Tuning(protectsLeadingHRWake: false))
        let on = SleepStaging.classify(from: recs)
        XCTAssertEqual(on, off)
    }

    /// The kill switch is real: `false` restores the pre-#202 output exactly.
    func testKillSwitchRestoresPreFixStaging() {
        let night = elevatedHeadNight()
        let off = SleepStaging.classify(from: night.records,
                                        tuning: SleepStaging.Tuning(protectsLeadingHRWake: false))
        XCTAssertEqual(onset(off), night.blockStart)
        XCTAssertNotEqual(onset(off), onset(SleepStaging.classify(from: night.records)))
    }
}
