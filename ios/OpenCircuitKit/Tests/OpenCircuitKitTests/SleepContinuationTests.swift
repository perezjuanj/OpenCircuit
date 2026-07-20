import XCTest
@testable import OpenCircuitKit

// Regression tests for the "sleep never continues after a mid-night wake" bug (tester report,
// build 26, 2026-07-19): "woke up at 3am to pee then it just said I was awake with low heart rate
// till 7. Didn't continue to log sleep." The ring recorded and the app ingested the whole night
// (that is why the user could SEE his low HR for 03:00–07:00) — the four hours were MIS-LABELLED
// awake, not missing. Root cause: `classifyContiguous` condemns an epoch on ONE night-wide sleeping
// floor + `wakeHRMarginBPM`; the deep-rich first bout sets that floor, and the legitimately-lighter
// second bout after the wake sits a few bpm above it, so every epoch of the back half flags awake at
// an objectively low HR — and no downstream pass could put it back. The fix is `rescueSecondBoutHRWake`:
// an ADD-only pass that relabels a long, motion-free, sleep-vitals-backed, only-mildly-elevated
// HR-awake second bout back to asleep when consolidated sleep already lies behind it. Its
// `hrWakeRescueCeilingBPM == 0` kill-switch is byte-identical to the pre-rescue staging.
//
// SYNTHETIC-ONLY (the ring sends no hypnogram, §5.3): these build a controlled bimodal night and
// assert the classifier recovers the second bout with the rescue on and loses it with the rescue off.
final class SleepContinuationTests: XCTestCase {

    private let step: UInt32 = 150
    private let base: UInt32 = 0x0c220000

    /// A sleep-vitals epoch (sub 0x62) carrying HR + HRV (so `vitals` is true) and a uniform still
    /// motion byte (baseline `01` → de-floors to 0 → not motion-awake). Mirrors `SleepStagingTests.vrec`.
    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 55, motion: UInt8 = 1) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// A motion/activity epoch (sub 0x12, high motion, no vitals): the bathroom trip / onset / offset.
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

    /// Minutes of ASLEEP (Core/Deep/REM) time whose segments overlap `[lo, hi)`.
    private func asleepMinutes(_ segs: [SleepSegment], from lo: Date, to hi: Date) -> Double {
        let asleep: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]
        return segs.filter { asleep.contains($0.stage) }.reduce(0.0) { acc, s in
            acc + max(0, min(s.end, hi).timeIntervalSince(max(s.start, lo))) / 60
        }
    }

    /// The tester's night: an awake onset, a FIRST bout at a low resting HR, a ~10-min bathroom trip
    /// (motion), then a SECOND bout at `secondHR` (still, sleep-vitals present), then an awake offset.
    /// Both bouts are FLAT so the p12 sleeping floor is deterministically `firstHR` (it is the minimum
    /// HR and dominates the low tail) — the wake threshold is then exactly `firstHR + wakeHRMarginBPM`
    /// (68 at default) and the rescue ceiling `firstHR + hrWakeRescueCeilingBPM` (75), so the tests can
    /// place `secondHR` relative to those edges without depending on an incidental ±1 jitter.
    /// Returns the records and the `[start, end)` of the second bout for measurement.
    private func midNightWakeNight(firstHR: UInt8, secondHR: UInt8,
                                   firstEpochs: Int = 96, tripEpochs: Int = 4,
                                   secondEpochs: Int = 96)
        -> (records: [BulkRecord], secondStart: Date, secondEnd: Date) {
        var recs: [BulkRecord] = []
        var c = base
        for _ in 0..<12 { recs.append(arec(c)); c += step }                    // awake onset
        for _ in 0..<firstEpochs { recs.append(vrec(c, hr: firstHR)); c += step }
        for _ in 0..<tripEpochs { recs.append(arec(c)); c += step }            // bathroom trip (motion)
        let secondStart = date(c)
        for _ in 0..<secondEpochs { recs.append(vrec(c, hr: secondHR)); c += step }
        let secondEnd = date(c)
        for _ in 0..<12 { recs.append(arec(c)); c += step }                    // awake offset
        return (recs, secondStart, secondEnd)
    }

    // MARK: - The bug, and the fix

    /// Swept across the rescue band, with the rescue ON (default) the second bout is recovered as
    /// sleep, and with it OFF (kill-switch) the second bout is lost — proving both the bug and that
    /// the new knob controls it. floor≈`firstHR` (p12 of a night dominated by the two bouts), so the
    /// wake threshold is floor+18 and the rescue ceiling floor+25.
    func testSecondBoutRecoveredAcrossRescueBand() {
        let floor: UInt8 = 50
        let off = SleepStaging.Tuning(hrWakeRescueCeilingBPM: 0)       // kill-switch = pre-fix behaviour
        // Second-bout HR from below the wake threshold (asleep either way) up past the rescue ceiling
        // (genuine wake, never rescued). With flat bouts the floor is exactly 50, so threshold = 68
        // (50+18) and ceiling = 75 (50+25); values are kept off the exact 75 boundary deliberately.
        for hr2: UInt8 in [60, 64, 68, 71, 74, 76, 80] {
            let night = midNightWakeNight(firstHR: floor, secondHR: hr2)
            let onSegs = SleepStaging.classify(from: night.records)                       // rescue ON
            let offSegs = SleepStaging.classify(from: night.records, tuning: off)         // rescue OFF
            let on = asleepMinutes(onSegs, from: night.secondStart, to: night.secondEnd)
            let offM = asleepMinutes(offSegs, from: night.secondStart, to: night.secondEnd)
            let full = night.secondEnd.timeIntervalSince(night.secondStart) / 60          // ~240 min

            if hr2 < 68 {
                // Below the wake threshold the second bout was never awake — rescue is a no-op.
                XCTAssertEqual(on, offM, accuracy: 1,
                    "hr2=\(hr2): below threshold, rescue must not change anything")
                XCTAssertGreaterThan(on, full * 0.9, "hr2=\(hr2): sub-threshold bout stays asleep")
            } else if hr2 < 75 {
                // In-band: OFF loses (almost) the whole bout (the bug); ON recovers (almost) all of it.
                XCTAssertLessThan(offM, full * 0.2,
                    "hr2=\(hr2): BUG — with the rescue off the second bout is lost as awake")
                XCTAssertGreaterThan(on, full * 0.8,
                    "hr2=\(hr2): FIX — the rescue recovers the second bout as sleep")
                XCTAssertGreaterThan(on, offM + full * 0.5,
                    "hr2=\(hr2): the rescue must add back most of the lost bout")
            } else {
                // At/above the ceiling the elevated bout is genuine wake — the rescue must NOT fire.
                XCTAssertEqual(on, offM, accuracy: 1,
                    "hr2=\(hr2): above the ceiling, genuine wake must stay awake with the rescue on")
                XCTAssertLessThan(on, full * 0.2, "hr2=\(hr2): genuine wake is not rescued")
            }
        }
    }

    /// The exact tester scenario, asserted end-to-end: ~4 h asleep before a 3 a.m. trip and ~4 h after
    /// it. Before the fix the app reported roughly the first half only; after it, roughly the whole night.
    func testTesterNightContinuesAfterBathroomTrip() {
        let night = midNightWakeNight(firstHR: 50, secondHR: 71)   // 71 = floor+21, squarely in-band
        let fixed = SleepStaging.classify(from: night.records)
        let buggy = SleepStaging.classify(from: night.records,
                                          tuning: SleepStaging.Tuning(hrWakeRescueCeilingBPM: 0))

        let lostBefore = asleepMinutes(buggy, from: night.secondStart, to: night.secondEnd)
        let keptAfter = asleepMinutes(fixed, from: night.secondStart, to: night.secondEnd)
        XCTAssertLessThan(lostBefore, 40, "pre-fix: the ~4 h second bout is dropped")
        XCTAssertGreaterThan(keptAfter, 200, "post-fix: the ~4 h second bout is logged as sleep")

        // Whole-night total roughly doubles.
        let totalFixed = SleepStaging.totalAsleep(fixed)
        let totalBuggy = SleepStaging.totalAsleep(buggy)
        XCTAssertGreaterThan(totalFixed, totalBuggy + 200 * 60,
            "the fix restores several hours to the night's total asleep time")
    }

    /// Guard (b), isolated: with the existing morning-tail motion softening DISABLED
    /// (`motionAwakeVitalsHalfWindow = 0`), the bathroom trip (motion) and the second bout (HR-only)
    /// are ONE contiguous awake run. The rescue must relabel only the motion-free tail (the second
    /// bout) and leave the getting-up itself scored as a brief awakening. This proves the recovery
    /// does not depend on the softening and never papers over real movement.
    func testBathroomTripStaysAwakeWithSofteningOff() {
        let night = midNightWakeNight(firstHR: 50, secondHR: 71)
        let tuning = SleepStaging.Tuning(motionAwakeVitalsHalfWindow: 0)   // softening off; rescue on
        let segs = SleepStaging.classify(from: night.records, tuning: tuning)

        // The second bout is still recovered…
        XCTAssertGreaterThan(asleepMinutes(segs, from: night.secondStart, to: night.secondEnd), 200,
            "with softening off the motion-free second bout is still rescued")
        // …while the trip immediately before it stays awake.
        let tripStart = night.secondStart.addingTimeInterval(-Double(4 * step))   // 4 trip epochs
        let tripAwake = segs.contains { $0.stage == .awake
            && $0.start < night.secondStart && $0.end > tripStart }
        XCTAssertTrue(tripAwake, "the getting-up itself stays scored as a brief awakening")
    }

    // MARK: - Safety: the rescue only ever ADDS sleep, and never on the wrong night

    /// The adversarial night the fix must NOT break: a person lying STILL and AWAKE for hours at the
    /// START (elevated HR, no movement, ring still emitting vitals), THEN falling asleep — the
    /// 2026-06-26 "lay still awake for hours" case. The awake block has NO consolidated sleep behind
    /// it, so guard (d) blocks the rescue and the leading wake is preserved.
    func testLieAwakeFirstNightIsNotRescued() {
        var recs: [BulkRecord] = []
        var c = base
        for _ in 0..<6 { recs.append(arec(c)); c += step }                     // brief settle
        let awakeStart = date(c)
        // 60 epochs (~2.5 h) STILL but AWAKE at floor+20, sleep-vitals present — the trap for a
        // vitals-only rescue. motion 1 = still, so this is a motion-free awake run at the leading edge.
        for k in 0..<60 { recs.append(vrec(c, hr: k % 2 == 0 ? 70 : 69)); c += step }
        let awakeEnd = date(c)
        for k in 0..<120 { recs.append(vrec(c, hr: k % 2 == 0 ? 50 : 49)); c += step }  // real sleep
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let fixed = SleepStaging.classify(from: recs)
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(hrWakeRescueCeilingBPM: 0))
        // The rescue must not convert the pre-sleep wakefulness to sleep: output is unchanged vs OFF.
        XCTAssertEqual(fixed, off,
            "a lie-awake-FIRST night has no sleep behind the wake block — the rescue must be a no-op")
        // And that leading stretch is (mostly) awake, not logged as sleep.
        let asleepInLeadIn = asleepMinutes(fixed, from: awakeStart, to: awakeEnd)
        XCTAssertLessThan(asleepInLeadIn, 40, "the pre-sleep wake is not logged as sleep")
    }

    /// Guard (e), isolated: a still, sleep-vitals-bearing second bout whose HR sits well ABOVE the
    /// rescue ceiling (floor + 25) is a genuine awakening, not lighter sleep — the rescue must leave
    /// it awake. floor≈50, so a second bout at 90 bpm (floor+40) is unambiguously wake.
    func testElevatedSecondBoutIsNotRescued() {
        let night = midNightWakeNight(firstHR: 50, secondHR: 90)
        let fixed = SleepStaging.classify(from: night.records)
        let off = SleepStaging.classify(from: night.records,
                                        tuning: SleepStaging.Tuning(hrWakeRescueCeilingBPM: 0))
        XCTAssertEqual(fixed, off,
            "a clearly-elevated second bout is above the ceiling — the rescue is a no-op")
        XCTAssertLessThan(asleepMinutes(fixed, from: night.secondStart, to: night.secondEnd), 40,
            "genuine elevated wake stays awake")
    }

    /// A brief HR AROUSAL (above the ceiling) inside an otherwise-still second bout must remain awake:
    /// the per-epoch ceiling splits the sub-run at the spike rather than averaging it away, so a genuine
    /// mid-bout awakening is preserved while the calm stretches on either side are rescued.
    func testAboveCeilingArousalWithinBoutStaysAwake() {
        var recs: [BulkRecord] = []
        var c = base
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<96 { recs.append(vrec(c, hr: 50)); c += step }            // first bout (floor 50)
        for _ in 0..<4 { recs.append(arec(c)); c += step }                     // get up briefly
        for _ in 0..<20 { recs.append(vrec(c, hr: 70)); c += step }            // calm, in-band
        let spikeStart = date(c)
        for _ in 0..<8 { recs.append(vrec(c, hr: 92)); c += step }             // STILL but HR arousal (>ceiling)
        let spikeEnd = date(c)
        for _ in 0..<20 { recs.append(vrec(c, hr: 70)); c += step }            // calm, in-band again
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        // The arousal stays awake…
        let arousalAwake = segs.contains { $0.stage == .awake
            && $0.start < spikeEnd && $0.end > spikeStart }
        XCTAssertTrue(arousalAwake, "an above-ceiling arousal inside the bout is preserved as awake")
        // …but the still, in-band stretches around it are rescued (net asleep well over the spike alone).
        XCTAssertGreaterThan(asleepMinutes(segs, from: spikeEnd, to: date(c)), 30,
            "the calm in-band stretch after the arousal is still rescued")
    }

    /// Two successive mid-night wakes: BOTH the second and third bouts must be recovered. Verifies the
    /// "correct by construction" claim — the second rescued bout legitimately backs the third, but the
    /// third also qualifies on the genuine first bout independently.
    func testTwoSuccessiveMidNightWakesBothRecovered() {
        var recs: [BulkRecord] = []
        var c = base
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<96 { recs.append(vrec(c, hr: 50)); c += step }            // first bout
        for _ in 0..<4 { recs.append(arec(c)); c += step }                     // wake 1
        let secondStart = date(c)
        for _ in 0..<40 { recs.append(vrec(c, hr: 71)); c += step }            // second bout (in-band)
        let secondEnd = date(c)
        for _ in 0..<4 { recs.append(arec(c)); c += step }                     // wake 2
        let thirdStart = date(c)
        for _ in 0..<40 { recs.append(vrec(c, hr: 71)); c += step }            // third bout (in-band)
        let thirdEnd = date(c)
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        XCTAssertGreaterThan(asleepMinutes(segs, from: secondStart, to: secondEnd), 80,
            "second bout recovered")
        XCTAssertGreaterThan(asleepMinutes(segs, from: thirdStart, to: thirdEnd), 80,
            "third bout recovered (backed by the genuine first bout, not only the rescued second)")
    }

    // MARK: - Kill-switch is byte-identical

    /// Default staging with the rescue at ceiling 0 is byte-identical to an explicit disabled tuning,
    /// on a night that WOULD be rescued at the default — proving 0 is a true escape hatch, not 0 == 0.
    func testKillSwitchByteIdentical() {
        let night = midNightWakeNight(firstHR: 50, secondHR: 71)
        let a = SleepStaging.classify(from: night.records,
                                      tuning: SleepStaging.Tuning(hrWakeRescueCeilingBPM: 0))
        let b = SleepStaging.classify(from: night.records,
                                      tuning: SleepStaging.Tuning(hrWakeRescueCeilingBPM: 0))
        XCTAssertEqual(a, b)
        // And it genuinely differs from the rescued default (so the knob is load-bearing).
        let def = SleepStaging.classify(from: night.records)
        XCTAssertNotEqual(a, def, "ceiling 0 must actually disable the rescue")
    }

    /// The default tuning ships the rescue ON at 25 bpm and 0.5 vitals fraction (locks the calibration).
    func testDefaultRescueCalibration() {
        XCTAssertEqual(SleepStaging.Tuning.default.hrWakeRescueCeilingBPM, 25)
        XCTAssertEqual(SleepStaging.Tuning.default.hrWakeRescueVitalsFraction, 0.5)
    }
}
