import XCTest
@testable import OpenCircuitKit

// Tests for the SpO2-CADENCE trailing-edge wake locator (#190) — `cadenceSteps` and
// `markCadenceWakeOffset`.
//
// The defect: when the primary motion channel is a flat placeholder and the morning HR rise is small,
// every sleeper-side pass misses the wake, the staged night runs to the last record, and the reported
// wake becomes `lastRecord + 120 s` — a function of when the user SYNCED. 🟢 Truncating one real
// capture in 49 five-minute steps moved reported sleep 367 → 625 min with no byte of physiology
// changed.
//
// The unit cases drive the pass DIRECTLY, for the same reason `SleepStagingOffsetTests` does: a
// synthetic record sequence carries a constant motion byte that de-floors to "still" everywhere, so a
// fixture built to look "awake" silently stages as sleep and the assertion goes vacuous. The
// `classify` cases at the bottom cover the WIRING, and are written to go red under mutation — the
// adversarial review of round 1 caught a suite that stayed green when the call site was deleted.
final class SleepStagingCadenceOffsetTests: XCTestCase {

    private let floor: Double = 50
    private func asleepMask(_ n: Int) -> [Bool] { [Bool](repeating: false, count: n) }

    /// Flat sleeping HR with a sustained rise over the last `tail` epochs — a rise that never returns.
    private func hrRisingAtEnd(n: Int, tail: Int, sleepHR: Double = 52, wakeHR: Double = 62) -> [Double] {
        (0..<n).map { $0 >= n - tail ? wakeHR : sleepHR }
    }

    /// `alternating` for `[0, quietEnd]`, then `terminator` at `quietEnd + 1`, then `.violation` after.
    private func cadence(n: Int, quietEnd: Int,
                         terminator: SleepStaging.CadenceStep = .violation) -> [SleepStaging.CadenceStep] {
        var out = [SleepStaging.CadenceStep](repeating: .violation, count: n)
        out[0] = .unknown
        for i in 1 ... quietEnd where i < n { out[i] = .alternating }
        if quietEnd + 1 < n { out[quietEnd + 1] = terminator }
        return out
    }

    // MARK: - `cadenceSteps`: reading the ring's SpO2 duty cycle off the wire

    private func times(_ n: Int, step: Int = BulkRecord.epochSeconds) -> [Date] {
        (0..<n).map { Date(timeIntervalSince1970: TimeInterval(1_000_000 + $0 * step)) }
    }
    private func alternatingLayouts(_ n: Int) -> [BulkRecord.Layout] {
        (0..<n).map { $0.isMultiple(of: 2) ? .sleepVitals : .activity }
    }

    func testPerfectAlternationIsAllAlternating() {
        let steps = SleepStaging.cadenceSteps(times: times(10), layouts: alternatingLayouts(10))
        XCTAssertEqual(steps[0], .unknown, "there is no step INTO the first row")
        XCTAssertTrue(steps.dropFirst().allSatisfy { $0 == .alternating })
    }

    func testSameTemplateTwiceIsAViolation() {
        let layouts: [BulkRecord.Layout] = [.sleepVitals, .activity, .activity, .sleepVitals]
        let steps = SleepStaging.cadenceSteps(times: times(4), layouts: layouts)
        XCTAssertEqual(steps, [.unknown, .alternating, .violation, .alternating])
    }

    /// ONE missing epoch is bridged by PARITY: after an even number of steps the template returns to
    /// itself, so `S … S` across 300 s is the alternation intact, not a break. Dropping one interior
    /// epoch makes its neighbours same-template in 90.5 % of positions BY CONSTRUCTION — a gap-blind
    /// rule reads that as a violation storm.
    func testOneMissingEpochIsBridgedByParity() {
        let t = [0, 150, 450].map { Date(timeIntervalSince1970: TimeInterval(1_000_000 + $0)) }
        let steps = SleepStaging.cadenceSteps(times: t, layouts: [.activity, .sleepVitals, .sleepVitals])
        XCTAssertEqual(steps[2], .alternating, "S→(A dropped)→S is the cadence holding, not breaking")
    }

    func testOneMissingEpochWithTheWrongParityIsStillAViolation() {
        let t = [0, 150, 450].map { Date(timeIntervalSince1970: TimeInterval(1_000_000 + $0)) }
        let steps = SleepStaging.cadenceSteps(times: t, layouts: [.activity, .sleepVitals, .activity])
        XCTAssertEqual(steps[2], .violation, "two steps must return to the SAME template")
    }

    /// More than one missing epoch carries NO information. 🟢 A blind-bridging rule was measured
    /// joining 70 missing epochs into a 25-epoch phantom *daytime* quiet run.
    func testTwoMissingEpochsCarryNoInformation() {
        let t = [0, 150, 600].map { Date(timeIntervalSince1970: TimeInterval(1_000_000 + $0)) }
        let steps = SleepStaging.cadenceSteps(times: t, layouts: [.activity, .sleepVitals, .sleepVitals])
        XCTAssertEqual(steps[2], .unknown)
    }

    /// JITTER, not a hole: 91 of 3432 steps on the primary ring are 151–221 s with no record missing.
    /// An exact `dt == 150` test silently suppresses 57 genuine violations.
    func testJitteredStepUnderOneAndAHalfEpochsIsStillOneEpoch() {
        let t = [0, 221].map { Date(timeIntervalSince1970: TimeInterval(1_000_000 + $0)) }
        XCTAssertEqual(SleepStaging.cadenceSteps(times: t, layouts: [.sleepVitals, .sleepVitals])[1],
                       .violation, "a 221 s step is ONE epoch — the violation must survive the jitter")
        XCTAssertEqual(SleepStaging.cadenceSteps(times: t, layouts: [.sleepVitals, .activity])[1],
                       .alternating)
    }

    /// An unworn epoch is outside the measurement program altogether — absence of evidence.
    func testIdleEpochCarriesNoInformation() {
        let steps = SleepStaging.cadenceSteps(times: times(3), layouts: [.sleepVitals, .idle, .sleepVitals])
        XCTAssertEqual(steps, [.unknown, .unknown, .unknown])
    }

    func testMismatchedInputsProduceNothing() {
        XCTAssertTrue(SleepStaging.cadenceSteps(times: times(3), layouts: alternatingLayouts(2)).isEmpty)
        XCTAssertTrue(SleepStaging.cadenceSteps(times: [], layouts: []).isEmpty)
    }

    // MARK: - `markCadenceWakeOffset`: what the locator does

    func testCutsAtTheEndOfTheLastQuietRun() {
        var awake = asleepMask(120)
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 120, quietEnd: 99),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake.firstIndex(of: true), 100,
                       "wake is the epoch AFTER the last epoch of the trusted quiet run")
        XCTAssertTrue(awake[100...].allSatisfy { $0 })
    }

    /// Suffix-only by construction — the pass may never punch a hole in the middle of a night.
    func testMarkedRegionIsAlwaysASuffix() {
        var awake = asleepMask(120)
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 120, quietEnd: 99),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        guard let first = awake.firstIndex(of: true) else { return XCTFail("expected a cut") }
        XCTAssertTrue(awake[first...].allSatisfy { $0 })
        XCTAssertFalse(awake[..<first].contains(true))
    }

    /// THE KILL SWITCH. 0 must be a total no-op, so a regression can always be turned off in one line.
    func testZeroQuietEpochsIsANoOp() {
        var awake = asleepMask(120)
        let before = awake
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 120, quietEnd: 99),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20), floor: floor, margin: 4,
                                           tuning: SleepStaging.Tuning(cadenceWakeQuietEpochs: 0))
        XCTAssertEqual(awake, before)
    }

    func testNonPositiveMarginIsANoOp() {
        var awake = asleepMask(120)
        let before = awake
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 120, quietEnd: 99),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 0, tuning: .default)
        XCTAssertEqual(awake, before)
    }

    /// THE GUARD THAT STOPS THE PASS RE-MANUFACTURING THE VERY ARTEFACT IT EXISTS TO REMOVE. A quiet
    /// run that is still going when the capture stops has not been observed to END — cutting there
    /// would put the wake back at the data edge.
    func testDeclinesWhenTheQuietRunReachesTheDataEdge() {
        var awake = asleepMask(120)
        let before = awake
        var cad = [SleepStaging.CadenceStep](repeating: .alternating, count: 120)
        cad[0] = .unknown
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cad,
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before, "an unterminated quiet run is not evidence of a wake")
    }

    /// A hole is absence of evidence, not evidence of a wake. This is what keeps a dropped page from
    /// being read as "the ring left its sleep program here".
    func testDeclinesWhenTheRunEndsAtAHoleRatherThanAViolation() {
        var awake = asleepMask(120)
        let before = awake
        SleepStaging.markCadenceWakeOffset(&awake,
                                           cadence: cadence(n: 120, quietEnd: 99, terminator: .unknown),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before)
    }

    func testDeclinesWhenNoRunReachesTheQuietBar() {
        var awake = asleepMask(120)
        let before = awake
        // Alternation that never holds for more than 5 epochs anywhere.
        var cad = [SleepStaging.CadenceStep](repeating: .alternating, count: 120)
        for i in stride(from: 0, to: 120, by: 6) { cad[i] = .violation }
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cad,
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before, "the cadence never held for a plausible night")
    }

    /// LAST, not LONGEST. 🟢 "End of the longest violation-free run" was measured catastrophic:
    /// 06-29 → −4 h 28 m, 08-04 → −1 h 29 m.
    func testTakesTheLastQualifyingRunNotTheLongest() {
        var awake = asleepMask(120)
        var cad = [SleepStaging.CadenceStep](repeating: .alternating, count: 120)
        cad[0] = .unknown
        cad[80] = .violation                              // long run  [0, 79]  (80 epochs)
        for i in 100..<120 { cad[i] = .violation }        // short run [80, 99] (20) — the LAST at/above K,
                                                          // and nothing qualifies after it
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cad,
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake.firstIndex(of: true), 100,
                       "the LONGEST run ends at 79; taking it would delete two more hours of sleep")
    }

    /// The independent second witness. The cadence says where the ring stopped measuring sleep; this
    /// says the body never settled back. 🟢 It is what declines the cut on 06-29, which would
    /// otherwise remove 75 min from an UNLABELLED night.
    func testDeclinesWhenHRSettlesBackToTheFloorAfterTheCut() {
        var awake = asleepMask(120)
        let before = awake
        var hr = hrRisingAtEnd(n: 120, tail: 20)
        hr[110] = 51                                    // one dip back to the floor after the cut
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 120, quietEnd: 99),
                                           smHR: hr, floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before, "a suffix that returns to the sleeping floor is not final wake")
    }

    /// A pass that REMOVES sleep must not be able to commit a night down to a token fragment. The
    /// fixture is a heavily fragmented night: every asleep run is 10 epochs — long enough for
    /// `onsetSustainEpochs` (6) to find a span, too short for `minConsolidatedSleepEpochs` (16) — so
    /// cutting the tail would leave no consolidated sleep at all.
    func testDeclinesWhenNoConsolidatedSleepWouldSurvive() {
        var awake = asleepMask(120)
        for i in 0..<120 where (i % 12) >= 10 { awake[i] = true }   // 10 asleep, 2 awake, repeating
        let seeded = awake
        XCTAssertNotNil(SleepStaging.sleepSpanForTesting(seeded, sustain: 6),
                        "fixture sanity: the pass must get past its own onset-span guard")
        XCTAssertNil(SleepStaging.sleepSpanForTesting(seeded, sustain: 16),
                     "fixture sanity: no consolidated run exists to survive with")
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 120, quietEnd: 99),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, seeded, "the cut must be reverted, not committed to a fragment")
    }

    /// `notBefore` — a rescued second bout must not be overturned by this pass.
    func testCannotCutAtOrBeforeNotBefore() {
        var awake = asleepMask(120)
        let before = awake
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 120, quietEnd: 99),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, notBefore: 105, tuning: .default)
        XCTAssertEqual(awake, before)
    }

    /// The magnitude bound: the scan may not reach further back from the tail than the onset passes
    /// may from theirs (`onsetSearchEpochs`, 48 ≈ 2 h). This is what caps the damage this pass can do.
    func testCannotReachFurtherBackThanTheOnsetSearchBound() {
        var awake = asleepMask(200)
        let before = awake
        // The quiet run ends at 99 — 100 epochs from the end, well outside the 48-epoch reach.
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 200, quietEnd: 99),
                                           smHR: hrRisingAtEnd(n: 200, tail: 100),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before)
    }

    /// REGIME PLAUSIBILITY. 🔴 Does not fire anywhere in the local corpus (longest trusted run 191
    /// epochs ≈ 7.96 h) — it exists because ring `u4` was measured holding the 300 s cadence for a
    /// continuous 11.96 h, which no timezone makes a night.
    func testDeclinesWhenTheQuietRunIsTooLongToBeANight() {
        var awake = asleepMask(300)
        let before = awake
        let cad = cadence(n: 300, quietEnd: 259)          // 260 epochs ≈ 10.8 h
        let hr = hrRisingAtEnd(n: 300, tail: 40)
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cad, smHR: hr,
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before, "10.8 h of unbroken cadence is a ring in continuous SpO2 mode")

        var relaxed = asleepMask(300)
        SleepStaging.markCadenceWakeOffset(&relaxed, cadence: cad, smHR: hr, floor: floor, margin: 4,
                                           tuning: SleepStaging.Tuning(cadenceWakeMaxQuietEpochs: 300))
        XCTAssertEqual(relaxed.firstIndex(of: true), 260,
                       "sanity: only the plausibility bound was stopping it")
    }

    func testMismatchedArrayLengthsAreANoOp() {
        var awake = asleepMask(120)
        let before = awake
        SleepStaging.markCadenceWakeOffset(&awake, cadence: cadence(n: 100, quietEnd: 80),
                                           smHR: hrRisingAtEnd(n: 120, tail: 20),
                                           floor: floor, margin: 4, tuning: .default)
        XCTAssertEqual(awake, before)
    }

    // MARK: - Fixtures

    /// A still, sleep-vitals-bearing epoch (`.sleepVitals`).
    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 55) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = 1 }
        return BulkRecord(b)!
    }
    /// A STILL epoch on the `.activity` template — the other half of the ring's SpO2 duty cycle.
    /// ⚠️ Motion is the baseline `1`, NOT the `0x14` the offset suite's `arec` uses: this record means
    /// "no SpO2 reading in this epoch", not "the wearer moved". Expressing sleep-vs-wake through motion
    /// in a fixture is the flat-motion trap — a constant motion value de-floors to STILL and the
    /// assertions go vacuous. Here wake is expressed as ELEVATED HR only.
    private func qrec(_ counter: UInt32, hr: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x12
        for k in 0..<5 { b[10 + k] = 1 }
        return BulkRecord(b)!
    }

    /// THE 2026-08-09 SHAPE, in miniature. The ring alternates its SpO2 duty cycle 1:1 through the
    /// night, then the duty cycle EXITS and the morning is same-template throughout. The wearer is
    /// still (placeholder motion all night), the morning HR rise is far too small to clear
    /// `wakeHRMarginBPM` (+18), and the ring keeps emitting sleep-vitals ACROSS the wake — so the
    /// terminal-REM vitals guard on `markPointOfNoReturnOffset` declines and the cadence is the only
    /// witness left. Without this pass the night runs to the last record.
    private func cadenceExitNight(epochs: Int = 160, riseAt: Int = 120,
                                  sleepHR: UInt8 = 54, wakeHR: UInt8 = 64) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 1_000_000
        for i in 0..<epochs {
            if i >= riseAt {
                recs.append(vrec(c, hr: wakeHR, hrv: 55))          // same template, every epoch
            } else {
                recs.append(i.isMultiple(of: 2) ? vrec(c, hr: sleepHR, hrv: 55) : qrec(c, hr: sleepHR))
            }
            c += UInt32(BulkRecord.epochSeconds)
        }
        return recs
    }

    // MARK: - Integration through `classify` (these go red if the call site is deleted)

    /// PINS THE CALL SITE. The default is ENABLED, so this compares default against `0`.
    func testEnabledByDefaultMovesTheStagedWakeVersusDisabled() {
        let recs = cadenceExitNight()
        let off = SleepStaging.classify(from: recs,
                                        tuning: SleepStaging.Tuning(cadenceWakeQuietEpochs: 0))
        let on = SleepStaging.classify(from: recs)          // default = enabled
        guard let offWake = SleepStaging.sleepWindow(off)?.wake,
              let onWake = SleepStaging.sleepWindow(on)?.wake else {
            return XCTFail("both configurations must still stage a night")
        }
        XCTAssertLessThan(onWake, offWake,
                          "the DEFAULT must pull final wake earlier than the disabled config — if this "
                          + "fails the pass is not wired in, or the default was reverted to off")
        XCTAssertGreaterThan(offWake.timeIntervalSince(onWake), 60 * 60,
                            "the whole same-template morning must come off, not a token epoch")
        XCTAssertEqual(SleepStaging.sleepWindow(on)?.onset, SleepStaging.sleepWindow(off)?.onset,
                       "a trailing-edge pass must not disturb the onset")
    }

    /// The defect in one assertion: with the pass off, the reported wake IS the data edge, wherever the
    /// data happens to end. `BulkSleep` expands each 150 s epoch into five 30 s sub-samples, so the
    /// block — and the wake with it — lands on `lastRecord + 120 s`.
    func testWithThePassDisabledTheWakeIsMerelyTheLastRecord() {
        let recs = cadenceExitNight()
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(cadenceWakeQuietEpochs: 0))
        guard let wake = SleepStaging.sleepWindow(off)?.wake, let last = recs.last?.date() else {
            return XCTFail("expected a staged night")
        }
        XCTAssertEqual(wake.timeIntervalSince(last), 120, accuracy: 1)
    }

    /// SYNC-TIME INVARIANCE — the property the whole issue is about. Staging the SAME night after
    /// truncating the capture at successively later points must not keep pushing the wake later once
    /// the wake itself is in the data. 🟢 On the real 2026-08-09 capture master moved +5 min per
    /// 5-minute step across all 49 steps (367 → 625 min); with this pass the located wake is identical
    /// on every cut from the true wake onward.
    func testWakeStopsMovingOnceItIsInTheData() {
        let recs = cadenceExitNight()
        var wakes: [Date] = []
        for extra in stride(from: 4, through: 40, by: 4) {
            let truncated = Array(recs.prefix(120 + extra))
            guard let w = SleepStaging.sleepWindow(SleepStaging.classify(from: truncated))?.wake else {
                return XCTFail("every truncation must still stage a night (cut at +\(extra))")
            }
            wakes.append(w)
        }
        XCTAssertEqual(Set(wakes).count, 1,
                       "the wake moved with the truncation point: \(wakes.map(\.timeIntervalSince1970))")
    }

    func testDefaultIsEnabled() {
        XCTAssertGreaterThan(SleepStaging.Tuning.default.cadenceWakeQuietEpochs, 0,
                             "the cadence locator ships ON; disabling it is a deliberate act")
    }

    /// The measured admissible band for K over the local corpus is [12, 27] — bounded below by
    /// 08-09's 11-epoch post-wake quiet run and above by 08-04's 27-epoch final run. A default outside
    /// it changes a real night's answer by tens of minutes.
    func testDefaultQuietBarSitsInsideTheMeasuredAdmissibleBand() {
        let k = SleepStaging.Tuning.default.cadenceWakeQuietEpochs
        XCTAssertGreaterThanOrEqual(k, 12, "below 12 the 11-epoch post-wake run on 08-09 wins (+43 min)")
        XCTAssertLessThanOrEqual(k, 27, "above 27 the 08-04 night jumps back an extra 70 min")
    }

    /// A night the ring alternated through to the very last record must be left ALONE — this is the
    /// end-to-end form of the data-edge guard, and the case that would otherwise re-create the bug.
    func testNightStillInCadenceAtTheDataEdgeIsUntouched() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 1_000_000
        for i in 0..<160 {
            recs.append(i.isMultiple(of: 2) ? vrec(c, hr: 54) : qrec(c, hr: 54))
            c += UInt32(BulkRecord.epochSeconds)
        }
        let off = SleepStaging.totalAsleep(
            SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(cadenceWakeQuietEpochs: 0)))
        let on = SleepStaging.totalAsleep(SleepStaging.classify(from: recs))
        XCTAssertEqual(on, off, accuracy: 1)
        XCTAssertGreaterThan(off, 0, "fixture sanity: the night really does stage")
    }
}
