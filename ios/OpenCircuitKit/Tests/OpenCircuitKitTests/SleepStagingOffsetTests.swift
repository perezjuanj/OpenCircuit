import XCTest
@testable import OpenCircuitKit

// Tests for the point-of-no-return OFFSET pass (`markPointOfNoReturnOffset`).
//
// These drive the pass DIRECTLY rather than through a synthetic night, deliberately: a synthetic
// record sequence carries a CONSTANT motion byte, which de-floors to "still" everywhere (see
// `ActivityPeriod.motionAboveLocalFloor`), so a fixture built to look "awake" silently produces
// sleep and the assertion goes vacuous. Feeding the smoothed-HR array straight in keeps every case
// honest about exactly which signal is under test. One integration test at the bottom covers the
// wiring through `classify`.
final class SleepStagingOffsetTests: XCTestCase {

    private let floor: Double = 50

    /// `awake` mask for a night that is asleep everywhere (the pass's input in the common case).
    private func asleepMask(_ n: Int) -> [Bool] { [Bool](repeating: false, count: n) }

    /// Flat sleeping HR with a sustained rise over the last `tail` epochs.
    private func hrRisingAtEnd(n: Int, tail: Int, sleepHR: Double = 52, wakeHR: Double = 62) -> [Double] {
        (0..<n).map { $0 >= n - tail ? wakeHR : sleepHR }
    }

    // MARK: - The default is a no-op

    func testDisabledByDefaultLeavesMaskUntouched() {
        XCTAssertEqual(SleepStaging.Tuning.default.offsetNoReturnMarginBPM, 0,
                       "The offset pass must ship DISABLED until supervised-fit (N8).")
        var awake = asleepMask(60)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hrRisingAtEnd(n: 60, tail: 20),
                                               floor: floor, tuning: .default)
        XCTAssertEqual(awake, before, "margin 0 must be byte-identical to pre-offset staging")
    }

    // MARK: - What it does when enabled

    func testMarksTrailingRunThatNeverReturnsToFloor() {
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hrRisingAtEnd(n: 60, tail: 20),
                                               floor: floor,
                                               tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 4))
        XCTAssertEqual(awake.firstIndex(of: true), 40, "wake should start where the rise begins")
        XCTAssertTrue(awake[40...].allSatisfy { $0 }, "everything after final wake is awake")
        XCTAssertFalse(awake[..<40].contains(true), "nothing before final wake may be touched")
    }

    /// The whole point of the pass: a bump that SETTLES BACK is not final wake, however high.
    func testIgnoresInteriorBumpThatSettlesBack() {
        var hr = [Double](repeating: 52, count: 60)
        for i in 20..<26 { hr[i] = 75 }          // a big mid-night bump…
        // …but the night returns to the floor afterwards and stays there.
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor,
                                               tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 4))
        XCTAssertFalse(awake.contains(true),
                       "a bump that returns to the floor is not final wake — suffix test must reject it")
    }

    /// Suffix-by-construction: the marked region can never be an interior island.
    func testMarkedRegionIsAlwaysASuffix() {
        var hr = [Double](repeating: 52, count: 60)
        for i in 20..<26 { hr[i] = 75 }          // interior bump
        for i in 45..<60 { hr[i] = 62 }          // real final wake
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor,
                                               tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 4))
        let first = awake.firstIndex(of: true)
        XCTAssertEqual(first, 45)
        XCTAssertTrue(awake[45...].allSatisfy { $0 })
        XCTAssertFalse(awake[..<45].contains(true), "the interior bump must stay asleep")
    }

    // MARK: - Safety properties

    /// It must never reach the head, or a globally-elevated night would lose its onset entirely.
    func testCannotReachTheHeadOnAUniformlyElevatedNight() {
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: [Double](repeating: 62, count: 60),
                                               floor: floor,
                                               tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 4))
        XCTAssertFalse(awake.contains(true),
                       "an entirely-above-threshold night has no onset to preserve; refuse to trim")
    }

    /// The revert guard: never trim a night out of existence.
    func testRevertsWhenNoSustainedSleepWouldSurvive() {
        let t = SleepStaging.Tuning(offsetNoReturnMarginBPM: 4)
        // Asleep only for the first few epochs — fewer than `onsetSustainEpochs` — then elevated.
        var hr = [Double](repeating: 62, count: 60)
        for i in 0..<(t.onsetSustainEpochs - 1) { hr[i] = 52 }
        var awake = asleepMask(60)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor, tuning: t)
        XCTAssertEqual(awake, before, "must revert rather than leave the night with no sustained sleep")
    }

    func testNoOpOnEmptyOrMismatchedInput() {
        let t = SleepStaging.Tuning(offsetNoReturnMarginBPM: 4)
        var empty: [Bool] = []
        SleepStaging.markPointOfNoReturnOffset(&empty, smHR: [], floor: floor, tuning: t)
        XCTAssertTrue(empty.isEmpty)

        var awake = asleepMask(10)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: [52, 52], floor: floor, tuning: t)
        XCTAssertEqual(awake, before, "length mismatch must be a no-op, not a crash")
    }

    /// A margin so wide nothing clears it degrades to the pre-offset behaviour.
    func testWideMarginDegradesToNoOp() {
        var awake = asleepMask(60)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hrRisingAtEnd(n: 60, tail: 20),
                                               floor: floor,
                                               tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 40))
        XCTAssertEqual(awake, before)
    }

    /// It must not start at or before an epoch the second-bout rescue reclaimed.
    func testRefusesToStartBeforeARescuedSecondBout() {
        var awake = asleepMask(60)
        // Everything from 30 on is above the floor (a "second bout" sleeping at a higher level).
        var hr = [Double](repeating: 52, count: 60)
        for i in 30..<60 { hr[i] = 62 }
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor, notBefore: 44,
                                               tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 4))
        XCTAssertFalse(awake[..<45].contains(true),
                       "must not reclaim epochs the second-bout rescue already judged asleep")
    }

    // MARK: - Integration through `classify`

    /// End-to-end guard for the defect adversarial review caught: a mid-night wake followed by a
    /// SECOND BOUT sleeping at a HIGHER level than the night's floor never "returns to the floor",
    /// so before the `notBefore` guard the offset scan deleted the whole bout. 🟢 MEASURED then:
    /// 240 min of second-bout sleep → 0, total asleep 485 → 245. This pins it.
    func testSecondBoutAtHigherHRSurvivesTheOffsetPass() {
        let step = UInt32(BulkRecord.epochSeconds)
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c22_0000
        func vrec(_ counter: UInt32, hr: UInt8) -> BulkRecord {
            var b = [UInt8](repeating: 0, count: 23)
            b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
            b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
            b[4] = hr; b[5] = 55; b[8] = 0x62
            for k in 0..<5 { b[10 + k] = 1 }
            return BulkRecord(b)!
        }
        func arec(_ counter: UInt32) -> BulkRecord {
            var b = [UInt8](repeating: 0, count: 23)
            b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
            b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
            b[8] = 0x12
            for k in 0..<5 { b[10 + k] = 0x14 }
            return BulkRecord(b)!
        }
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<96 { recs.append(vrec(c, hr: 50)); c += step }   // first bout, 50 bpm
        for _ in 0..<4  { recs.append(arec(c)); c += step }           // mid-night wake
        for _ in 0..<96 { recs.append(vrec(c, hr: 71)); c += step }   // second bout, 71 bpm
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let base = SleepStaging.totalAsleep(SleepStaging.classify(from: recs))
        let withOffset = SleepStaging.totalAsleep(
            SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 4)))
        XCTAssertEqual(withOffset, base, accuracy: 1,
                       "the offset pass must not undo rescueSecondBoutHRWake")
        XCTAssertGreaterThan(base / 60, 400, "sanity: the fixture really does stage two long bouts")
    }

    /// A night that sleeps flat then rises quietly at the very end — the shape the pass exists for.
    private func quietMorningRiseNight(epochs: Int = 160, riseAt: Int = 140,
                                       sleepHR: UInt8 = 54, wakeHR: UInt8 = 64) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 1_000_000
        for i in 0..<epochs {
            var b = [UInt8](repeating: 0, count: 23)
            b[0] = UInt8(c >> 24); b[1] = UInt8((c >> 16) & 0xFF)
            b[2] = UInt8((c >> 8) & 0xFF); b[3] = UInt8(c & 0xFF)
            b[4] = i >= riseAt ? wakeHR : sleepHR
            b[5] = 40; b[8] = 0x62
            for k in 0..<5 { b[10 + k] = 1 }
            recs.append(BulkRecord(b)!)
            c += UInt32(BulkRecord.epochSeconds)
        }
        return recs
    }

    /// The knob must be reachable from the public entry point, and the default must not move a night.
    func testClassifyIsUnchangedAtTheDefaultMargin() {
        let recs = quietMorningRiseNight()
        let base = SleepStaging.classify(from: recs)
        let same = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 0))
        XCTAssertEqual(base.map(\.start), same.map(\.start))
        XCTAssertEqual(base.map(\.stage), same.map(\.stage),
                       "explicit 0 must equal the default — the pass is opt-in")
    }

    /// PINS THE CALL SITE. Adversarial review mutation-tested the original suite by deleting the
    /// `markPointOfNoReturnOffset(...)` call from `classifyContiguous` — and the whole suite stayed
    /// green, because every test either drove the pass directly or asserted an equality that also
    /// holds when the pass is dead code. This test FAILS if the pass is not wired in.
    func testEnabledMarginActuallyMovesTheStagedWindowThroughClassify() {
        let recs = quietMorningRiseNight()
        let base = SleepStaging.classify(from: recs)
        let enabled = SleepStaging.classify(from: recs,
                                            tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: 4))
        guard let baseWake = SleepStaging.sleepWindow(base)?.wake,
              let enabledWake = SleepStaging.sleepWindow(enabled)?.wake else {
            return XCTFail("both configurations must still stage a night")
        }
        XCTAssertLessThan(enabledWake, baseWake,
                          "an enabled margin must pull the final wake EARLIER — if this fails the "
                          + "pass is not wired into classifyContiguous")
        XCTAssertLessThan(SleepStaging.totalAsleep(enabled), SleepStaging.totalAsleep(base))
        XCTAssertEqual(SleepStaging.sleepWindow(enabled)?.onset, SleepStaging.sleepWindow(base)?.onset,
                       "the offset pass must not disturb the onset")
    }

    /// The MAGNITUDE bound (BLOCKER from adversarial review). On a night with NO wake at all, whose
    /// HR merely drifts up across the later half, the unbounded pass destroyed 101.5 min at k=4 and
    /// 196.5 min at k=2 — `smHR` is a rolling MEDIAN, so the drift never dips back under the p12
    /// floor and the whole later night reads as "never returned".
    func testDriftingButSleepingNightIsNotAmputated() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 1_000_000
        for i in 0..<200 {
            var b = [UInt8](repeating: 0, count: 23)
            b[0] = UInt8(c >> 24); b[1] = UInt8((c >> 16) & 0xFF)
            b[2] = UInt8((c >> 8) & 0xFF); b[3] = UInt8(c & 0xFF)
            b[4] = i < 100 ? 50 : UInt8(52 + (i - 100) / 20)   // 50 → 52…56, no wake anywhere
            b[5] = 40; b[8] = 0x62
            for k in 0..<5 { b[10 + k] = 1 }
            recs.append(BulkRecord(b)!)
            c += UInt32(BulkRecord.epochSeconds)
        }
        let base = SleepStaging.totalAsleep(SleepStaging.classify(from: recs)) / 60
        for k in [2.0, 3.0, 4.0] {
            let got = SleepStaging.totalAsleep(
                SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(offsetNoReturnMarginBPM: k))) / 60
            // The bound is `onsetSearchEpochs` (48 epochs = 120 min) from the end, and the pass may
            // legitimately trim inside that. What it may NOT do is eat the drifting mid-night hours.
            XCTAssertGreaterThan(got, base - 121,
                                 "k=\(k): trimmed \(base - got) min — more than the search bound allows")
        }
    }
}
