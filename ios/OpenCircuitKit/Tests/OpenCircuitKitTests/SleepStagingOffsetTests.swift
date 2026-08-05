import XCTest
@testable import OpenCircuitKit

// Tests for the point-of-no-return OFFSET pass (`markPointOfNoReturnOffset`) and its derived margin.
//
// The unit cases drive the pass DIRECTLY rather than through a synthetic night, deliberately: a
// synthetic record sequence carries a CONSTANT motion byte, which de-floors to "still" everywhere
// (see `ActivityPeriod.motionAboveLocalFloor`), so a fixture built to look "awake" silently produces
// sleep and the assertion goes vacuous. Feeding the smoothed-HR array straight in keeps every case
// honest about which signal is under test. The `classify` cases at the bottom cover the wiring —
// including one that FAILS if the call site is removed (adversarial review mutation-tested the
// original suite by deleting the call and the whole thing stayed green).
final class SleepStagingOffsetTests: XCTestCase {

    private let floor: Double = 50

    private func asleepMask(_ n: Int) -> [Bool] { [Bool](repeating: false, count: n) }

    /// Flat sleeping HR with a sustained rise over the last `tail` epochs.
    private func hrRisingAtEnd(n: Int, tail: Int, sleepHR: Double = 52, wakeHR: Double = 62) -> [Double] {
        (0..<n).map { $0 >= n - tail ? wakeHR : sleepHR }
    }

    // MARK: - The derived margin

    func testMarginIsDerivedFromTheNightsOwnSpread() {
        // floor 50, median 60 -> spread 10 -> 0.5 x 10 = 5 bpm.
        let hr = (0..<100).map { Double(50 + ($0 / 10)) }        // 50…59, median 60 after sort? assert below
        let m = SleepStaging.resolvedOffsetMargin(hr: hr, floor: 50, tuning: .default)
        XCTAssertEqual(m, max(2, 0.5 * (SleepStaging.percentileForTesting(hr, 0.50) - 50)), accuracy: 0.001)
        XCTAssertGreaterThan(m, 0)
    }

    /// A person with a WIDER sleeping-HR spread must get a wider margin — the whole point of
    /// deriving it instead of fixing it in bpm.
    func testWiderSpreadYieldsWiderMargin() {
        let tight = [Double](repeating: 52, count: 50) + [Double](repeating: 54, count: 50)
        let wide  = [Double](repeating: 52, count: 50) + [Double](repeating: 78, count: 50)
        let mTight = SleepStaging.resolvedOffsetMargin(hr: tight, floor: 50, tuning: .default)
        let mWide  = SleepStaging.resolvedOffsetMargin(hr: wide, floor: 50, tuning: .default)
        XCTAssertGreaterThan(mWide, mTight)
    }

    /// A near-flat night must not derive a hair-trigger threshold.
    func testFlatNightIsFlooredAtTheQuantisationMargin() {
        let flat = [Double](repeating: 50, count: 100)
        let m = SleepStaging.resolvedOffsetMargin(hr: flat, floor: 50, tuning: .default)
        XCTAssertEqual(m, SleepStaging.Tuning.default.offsetNoReturnMinMarginBPM)
        XCTAssertGreaterThan(m, 0, "the floor must keep the pass safe, not disable it")
    }

    func testFractionZeroDisablesTheDerivation() {
        let t = SleepStaging.Tuning(offsetNoReturnSpreadFraction: 0)
        XCTAssertEqual(SleepStaging.resolvedOffsetMargin(hr: [50, 60, 70], floor: 50, tuning: t), 0)
    }

    func testEmptyHRDisablesTheDerivation() {
        XCTAssertEqual(SleepStaging.resolvedOffsetMargin(hr: [], floor: 50, tuning: .default), 0)
    }

    // MARK: - What the pass does

    func testMarksTrailingRunThatNeverReturnsToFloor() {
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hrRisingAtEnd(n: 60, tail: 20),
                                               floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake.firstIndex(of: true), 40, "wake should start where the rise begins")
        XCTAssertTrue(awake[40...].allSatisfy { $0 })
        XCTAssertFalse(awake[..<40].contains(true))
    }

    func testNonPositiveMarginIsANoOp() {
        var awake = asleepMask(60)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hrRisingAtEnd(n: 60, tail: 20),
                                               floor: floor, margin: 0, tuning: .default)
        XCTAssertEqual(awake, before)
    }

    /// The whole point of the pass: a bump that SETTLES BACK is not final wake, however high.
    func testIgnoresInteriorBumpThatSettlesBack() {
        var hr = [Double](repeating: 52, count: 60)
        for i in 20..<26 { hr[i] = 75 }
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor, margin: 4, tuning: .default)
        XCTAssertFalse(awake.contains(true),
                       "a bump that returns to the floor is not final wake")
    }

    func testMarkedRegionIsAlwaysASuffix() {
        var hr = [Double](repeating: 52, count: 60)
        for i in 20..<26 { hr[i] = 75 }          // interior bump
        for i in 45..<60 { hr[i] = 62 }          // real final wake
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake.firstIndex(of: true), 45)
        XCTAssertFalse(awake[..<45].contains(true), "the interior bump must stay asleep")
    }

    // MARK: - Safety properties

    func testCannotReachTheHeadOnAUniformlyElevatedNight() {
        var awake = asleepMask(60)
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: [Double](repeating: 62, count: 60),
                                               floor: floor, margin: 4, tuning: .default)
        XCTAssertFalse(awake.contains(true))
    }

    /// PRECEDENCE: must not overturn a rescued second bout / vitals-softened morning.
    func testRefusesToStartBeforeARescuedRegion() {
        var awake = asleepMask(60)
        var hr = [Double](repeating: 52, count: 60)
        for i in 30..<60 { hr[i] = 62 }
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor, margin: 4,
                                               notBefore: 44, tuning: .default)
        XCTAssertFalse(awake[..<45].contains(true),
                       "must not reclaim epochs an earlier pass already judged asleep")
    }

    /// SURVIVAL: never trim a night down to a token fragment.
    func testRevertsWhenNoConsolidatedSleepWouldSurvive() {
        let t = SleepStaging.Tuning.default
        var hr = [Double](repeating: 62, count: 60)
        for i in 0..<(t.minConsolidatedSleepEpochs - 1) { hr[i] = 52 }
        var awake = asleepMask(60)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hr, floor: floor, margin: 4, tuning: t)
        XCTAssertEqual(awake, before, "must revert rather than leave a token sleep fragment")
    }

    func testNoOpOnEmptyOrMismatchedInput() {
        var empty: [Bool] = []
        SleepStaging.markPointOfNoReturnOffset(&empty, smHR: [], floor: floor, margin: 4, tuning: .default)
        XCTAssertTrue(empty.isEmpty)
        var awake = asleepMask(10)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: [52, 52], floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before, "length mismatch must be a no-op, not a crash")
    }

    func testWideMarginDegradesToNoOp() {
        var awake = asleepMask(60)
        let before = awake
        SleepStaging.markPointOfNoReturnOffset(&awake, smHR: hrRisingAtEnd(n: 60, tail: 20),
                                               floor: floor, margin: 40, tuning: .default)
        XCTAssertEqual(awake, before)
    }

    // MARK: - Fixtures

    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 55) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = 1 }
        return BulkRecord(b)!
    }
    private func arec(_ counter: UInt32) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[8] = 0x12
        for k in 0..<5 { b[10 + k] = 0x14 }
        return BulkRecord(b)!
    }
    /// A night that sleeps flat then rises quietly at the very end — the shape the pass exists for.
    /// A night that sleeps flat then rises quietly at the end AND stops emitting sleep vitals there
    /// — a real wake, not a terminal REM period. The vitals thinning matters: the pass deliberately
    /// refuses to cut without it (see the terminal-REM guard).
    private func quietMorningRiseNight(epochs: Int = 160, riseAt: Int = 140,
                                       sleepHR: UInt8 = 54, wakeHR: UInt8 = 64) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 1_000_000
        for i in 0..<epochs {
            let awakeTail = i >= riseAt
            // Sleeping epochs carry HRV on ~half the epochs (the real sleepV/activity interleave);
            // the awake tail carries none, which is what true wake looks like on the wire.
            let hrv: UInt8 = awakeTail ? 0 : (i % 2 == 0 ? 55 : 0)
            recs.append(vrec(c, hr: awakeTail ? wakeHR : sleepHR, hrv: hrv))
            c += UInt32(BulkRecord.epochSeconds)
        }
        return recs
    }

    // MARK: - Integration through `classify`

    /// PINS THE CALL SITE — fails if `markPointOfNoReturnOffset` is not wired into
    /// `classifyContiguous`. The default is ENABLED, so this compares default against fraction 0.
    func testEnabledByDefaultMovesTheStagedWindowVersusDisabled() {
        let recs = quietMorningRiseNight()
        let off = SleepStaging.classify(from: recs,
                                        tuning: SleepStaging.Tuning(offsetNoReturnSpreadFraction: 0))
        let on = SleepStaging.classify(from: recs)          // default = enabled
        guard let offWake = SleepStaging.sleepWindow(off)?.wake,
              let onWake = SleepStaging.sleepWindow(on)?.wake else {
            return XCTFail("both configurations must still stage a night")
        }
        XCTAssertLessThan(onWake, offWake,
                          "the DEFAULT must pull final wake earlier than the disabled config — "
                          + "if this fails the pass is not wired in, or the default was reverted to off")
        XCTAssertEqual(SleepStaging.sleepWindow(on)?.onset, SleepStaging.sleepWindow(off)?.onset,
                       "the offset pass must not disturb the onset")
    }

    func testDefaultIsEnabled() {
        XCTAssertGreaterThan(SleepStaging.Tuning.default.offsetNoReturnSpreadFraction, 0,
                             "the offset pass ships ON; disabling it is a deliberate act")
    }

    /// A mid-night wake followed by a SECOND BOUT at a HIGHER level than the night's floor never
    /// "returns to the floor". Before the precedence guard the offset scan deleted the whole bout:
    /// 🟢 MEASURED 240 min of sleep lost, night total 485 → 245.
    func testSecondBoutAtHigherHRSurvivesTheOffsetPass() {
        let step = UInt32(BulkRecord.epochSeconds)
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c22_0000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<96 { recs.append(vrec(c, hr: 50)); c += step }
        for _ in 0..<4  { recs.append(arec(c)); c += step }
        for _ in 0..<96 { recs.append(vrec(c, hr: 71)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let off = SleepStaging.totalAsleep(
            SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(offsetNoReturnSpreadFraction: 0)))
        let on = SleepStaging.totalAsleep(SleepStaging.classify(from: recs))
        XCTAssertEqual(on, off, accuracy: 1, "the offset pass must not undo rescueSecondBoutHRWake")
        XCTAssertGreaterThan(off / 60, 400, "sanity: the fixture really does stage two long bouts")
    }

    /// The MAGNITUDE bound. On a night with NO wake at all, whose HR merely drifts up across the
    /// later half, the unbounded pass destroyed 101.5 min at k=4 / 196.5 min at k=2 — `smHR` is a
    /// rolling MEDIAN, so the drift never dips back under the p12 floor.
    func testDriftingButSleepingNightIsNotAmputated() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 1_000_000
        for i in 0..<200 {
            recs.append(vrec(c, hr: i < 100 ? 50 : UInt8(52 + (i - 100) / 20)))
            c += UInt32(BulkRecord.epochSeconds)
        }
        let off = SleepStaging.totalAsleep(
            SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(offsetNoReturnSpreadFraction: 0))) / 60
        let on = SleepStaging.totalAsleep(SleepStaging.classify(from: recs)) / 60
        // The scan is bounded to `onsetSearchEpochs` (48 epochs = 120 min) from the end.
        XCTAssertGreaterThan(on, off - 121, "trimmed \(off - on) min — more than the search bound allows")
    }
}
