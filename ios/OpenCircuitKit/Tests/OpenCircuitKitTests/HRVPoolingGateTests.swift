import XCTest
@testable import OpenCircuitKit

/// #185 REGRESSION — the run-level HRV pooling gate.
///
/// #185 pools the HRV that `0x12`/`0x13` ACTIVITY epochs carry into `BulkSleep.samples`. On every
/// Gen-2 / Gen-3 archive the two record templates measure the same thing, so pooling is correct and
/// must be preserved. On one device family they do not: the activity template runs ~13–20 ms LOW,
/// and because ~44 % of that archive's night HRV samples are recovered ones, the deficit propagates
/// into Apple Health, `VitalsBaseline.overnightHRV` and the headache HRV z-score.
///
/// `BulkSleep.hrvPooling` decides from the RUN'S OWN DATA — no ring generation, no firmware string
/// — exactly as `motionSource` (#184) decides which motion channel a run can use. This suite pins
/// the three verdicts, the two calibrated constants, the deliberate default-closed choice, and the
/// fact that ONLY the recovered activity-epoch HRV is gated: HR / SpO2 / RR and every strict sleep
/// accessor are bit-identical across all verdicts.
///
/// Synthetic records only: real captures are health data and are never committed.
final class HRVPoolingGateTests: XCTestCase {

    // MARK: - Synthetic run
    //
    // ⚠️ FIXTURE TRAP: the canonical sleep-vitals hex used elsewhere in the suite
    // (`0c22d5bf444d057a620a01010101012aa0000090000004`) has `[15:20] = 2a a0 00 00 90` — it is a
    // MOVING sleep-vitals epoch and is excluded from the reference pool by design. Every
    // sleep-vitals epoch below therefore zeroes `[15:20]` unless a test is deliberately probing the
    // symmetric quiet gate.

    private func rec(counter: UInt32,
                     hr: UInt8,
                     hrv: UInt8,
                     rr: UInt8,
                     tag: UInt8,
                     motion: [UInt8],
                     tail: [UInt8]) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(truncatingIfNeeded: counter >> 24)
        b[1] = UInt8(truncatingIfNeeded: counter >> 16)
        b[2] = UInt8(truncatingIfNeeded: counter >> 8)
        b[3] = UInt8(truncatingIfNeeded: counter)
        b[4] = hr
        b[5] = hrv
        b[6] = 0x05                 // confidence — NOT 0x0c, so the idle template never matches
        b[7] = rr
        b[8] = tag
        b[9] = 0x0a
        b.replaceSubrange(10..<15, with: motion)
        b.replaceSubrange(15..<20, with: tail)
        return BulkRecord(b)!
    }

    /// A QUIET activity epoch: `[8] == 0x12` and a zero `[15:20]` tail, so #185 recovers its HRV and
    /// the gate admits it to the activity pool. Its `[10:15]` still varies — quiet is the ring's own
    /// tail verdict, not stillness on the primary channel.
    private func quietActivity(_ counter: UInt32, hr: UInt8, hrv: Int, m: UInt8) -> BulkRecord {
        rec(counter: counter, hr: hr, hrv: UInt8(clamping: hrv), rr: 121, tag: 0x12,
            motion: [m, m &+ 9, m &+ 3, m &+ 14, m &+ 6], tail: [0, 0, 0, 0, 0])
    }

    private func sleepVitals(_ counter: UInt32, hr: UInt8, hrv: Int, spo2: UInt8,
                             moving: Bool = false) -> BulkRecord {
        rec(counter: counter, hr: hr, hrv: UInt8(clamping: hrv), rr: 121, tag: spo2,
            motion: [1, 1, 1, 1, 1],
            tail: moving ? [0x2a, 0xa0, 0, 0, 0x90] : [0, 0, 0, 0, 0])
    }

    /// A synthetic night with `activityCount` quiet activity epochs and `sleepCount` sleep-vitals
    /// epochs drawn from OVERLAPPING HRV distributions, offset by `activityHRVDelta` ms on the
    /// activity side. `delta == 0` is the Gen-2/Gen-3 shape; `delta == -15` is the disagreeing shape
    /// measured on the FR04.009 archive.
    private func night(activityHRVDelta: Int = 0,
                     activityCount: Int = 54,
                     sleepCount: Int = 100,
                     movingSleepVitals: Bool = false) -> [BulkRecord] {
        var out: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        func step() -> UInt32 { defer { c &+= 150 }; return c }

        // Evening lead-in, then the night, then a mid-night stretch, then the morning tail — the
        // three places a leaked scope or a mis-scoped pool would move a boundary.
        let eveningAct = activityCount / 2
        let morningAct = activityCount - eveningAct
        for i in 0 ..< eveningAct {
            out.append(quietActivity(step(), hr: 68,
                                     hrv: 60 + (i * 7) % 25 + activityHRVDelta,
                                     m: UInt8(20 + (i * 7) % 40)))
        }
        for i in 0 ..< sleepCount {
            out.append(sleepVitals(step(), hr: UInt8(52 + i % 5),
                                   hrv: 60 + (i * 3) % 25, spo2: UInt8(96 + i % 3),
                                   moving: movingSleepVitals))
        }
        for i in 0 ..< morningAct {
            out.append(quietActivity(step(), hr: 72,
                                     hrv: 60 + ((i + eveningAct) * 7) % 25 + activityHRVDelta,
                                     m: UInt8(25 + (i * 11) % 45)))
        }
        return out
    }

    /// The SAME records with `[5]` zeroed on every ACTIVITY epoch — the pre-#185 world.
    private func zeroedOnActivity(_ records: [BulkRecord]) -> [BulkRecord] {
        records.map { r in
            guard r.layout == .activity else { return r }
            var b = r.raw
            b[5] = 0
            return BulkRecord(b)!
        }
    }

    private func hrvCount(_ s: [QuantitySample]) -> Int { s.filter { $0.kind == .hrvSDNN }.count }
    private func values(_ s: [QuantitySample], _ k: MetricKind) -> [Double] {
        s.filter { $0.kind == k }.map(\.value)
    }

    // MARK: - Anti-vacuity

    /// Every pin below is meaningless if the fixture does not actually exercise the recovery.
    func testFixtureActuallyExercisesTheRecovery() {
        let r = night()
        let sv = r.filter { $0.layout == .sleepVitals && $0.hrvRMSSD != nil }.count
        let act = r.filter { $0.layout == .activity && $0.measuredHRVRMSSD != nil }.count
        XCTAssertEqual(sv, 100, "100 sleep-vitals HRV epochs")
        XCTAssertEqual(act, 54, "54 quiet activity epochs carry recoverable HRV")
        XCTAssertGreaterThanOrEqual(act, BulkSleep.hrvPoolingMinEpochs, "activity pool must be judgeable")
        XCTAssertGreaterThanOrEqual(sv, BulkSleep.hrvPoolingMinEpochs, "sleep-vitals pool must be judgeable")
        XCTAssertEqual(hrvCount(BulkSleep.samples(from: r)), sv + act, "ungated = pooled (#185)")
    }

    // MARK: - The three verdicts

    func testAgreeingRunPoolsRecoveredHRV() {
        let r = night(activityHRVDelta: 0)
        XCTAssertEqual(BulkSleep.hrvPooling(r), .agree)
        XCTAssertLessThanOrEqual(abs(BulkSleep.hrvShift(r.filter { $0.layout == .activity }
                                                         .compactMap(\.measuredHRVRMSSD),
                                                       r.compactMap(\.hrvRMSSD))),
                                 BulkSleep.hrvPoolingNoiseFloorMs)
        // Gen-2 / Gen-3 keep the FULL #185 recovery — a gate that suppresses everyone is a failure.
        XCTAssertEqual(BulkSleep.samples(from: r, calibratedBy: r),
                       BulkSleep.samples(from: r),
                       "an agreeing run must be byte-identical to the ungated #185 output")
    }

    func testDisagreeingRunSuppressesOnlyActivityHRV() {
        let r = night(activityHRVDelta: -15)
        XCTAssertEqual(BulkSleep.hrvPooling(r), .disagree)

        let ungated = BulkSleep.samples(from: r)
        let gated = BulkSleep.samples(from: r, calibratedBy: r)
        let strict = r.compactMap(\.hrvRMSSD).map(Double.init)

        XCTAssertEqual(hrvCount(ungated), 154)
        XCTAssertEqual(hrvCount(gated), 100, "only the sleep-vitals half survives")
        XCTAssertEqual(values(gated, .hrvSDNN), strict,
                       "the suppressed run emits EXACTLY the strict sleep-vitals HRV population")

        // CONSTRAINT 1 + the untouched metrics: RR shifts ≤ 0.06 brpm between the templates on every
        // archive and is deliberately NOT gated. HR and SpO2 are likewise untouched.
        XCTAssertEqual(values(gated, .respiratoryRate), values(ungated, .respiratoryRate),
                       "respiratory rate must stay exactly as #185 merged it")
        XCTAssertEqual(values(gated, .heartRate), values(ungated, .heartRate))
        XCTAssertEqual(values(gated, .spo2), values(ungated, .spo2))
    }

    /// The scoping crux (#185 constraint 4). A short drain slice cannot measure the shift at all —
    /// 🟢 MEASURED on the real corpus, a 1-h slice is undecidable on 100 % of windows of all 10
    /// archives. Undecided ⇒ SUPPRESS: default-open would ship the disagreeing device's deficit on
    /// essentially every short drain, and its first day is the day that becomes its baseline. The
    /// drain path therefore calibrates on the 30-h archive union, not on the slice.
    func testThinCalibrationYieldsNoEvidenceAndSuppresses() {
        let thin = night(activityCount: 19 * 2, sleepCount: 19)
        XCTAssertEqual(thin.filter { $0.layout == .sleepVitals && $0.hrvRMSSD != nil }.count, 19)
        XCTAssertEqual(BulkSleep.hrvPooling(thin), .noEvidence, "19 < hrvPoolingMinEpochs")
        let gated = BulkSleep.samples(from: thin, calibratedBy: thin)
        XCTAssertEqual(hrvCount(gated), 19, "no evidence ⇒ sleep-vitals only")
        XCTAssertLessThan(hrvCount(gated), hrvCount(BulkSleep.samples(from: thin)))
    }

    /// One MORE epoch on each side flips the same shape from `.noEvidence` to a real verdict —
    /// proves the previous test is bounded by `hrvPoolingMinEpochs` and not by the fixture.
    func testMinEpochsBoundaryIsExact() {
        XCTAssertEqual(BulkSleep.hrvPooling(night(activityCount: 19 * 2, sleepCount: 19)), .noEvidence)
        XCTAssertEqual(BulkSleep.hrvPooling(night(activityCount: 20 * 2, sleepCount: 20)), .agree)
        XCTAssertEqual(BulkSleep.hrvPooling(night(activityHRVDelta: -15,
                                                activityCount: 20 * 2, sleepCount: 20)), .disagree)
    }

    /// `calibration == nil` leaves the gate INERT. This is a DOCUMENTED CONTRACT, not an accident:
    /// it is what keeps every fixture/RE caller that passes a single record asserting the #185
    /// recovery itself. Every path that reaches Apple Health must pass a calibration set.
    func testNilCalibrationLeavesGateInert() {
        let r = night(activityHRVDelta: -15)
        XCTAssertEqual(BulkSleep.hrvPooling(r), .disagree)
        XCTAssertEqual(BulkSleep.samples(from: r, calibratedBy: nil), BulkSleep.samples(from: r))
        XCTAssertEqual(hrvCount(BulkSleep.samples(from: r, calibratedBy: nil)), 154,
                       "nil ⇒ pre-gate behaviour, INCLUDING on a disagreeing run")
    }

    // MARK: - The symmetric quiet gate

    /// BOTH pools are conditioned on the ring's own `[15:20]` "nothing moved" verdict. 🟢 MEASURED:
    /// quieting the sleep-vitals side too lifts corpus separation from 6.5 ms (1.76×) to 8.0 ms
    /// (2.60×). If someone "simplifies" it back to comparing against ALL sleep-vitals epochs, this
    /// run's reference pool stops being empty and the test fails.
    func testMovingSleepVitalsAreNotInTheReferencePool() {
        let r = night(movingSleepVitals: true)
        XCTAssertEqual(r.filter { $0.layout == .sleepVitals && $0.motionIntensityTailIsZero }.count, 0)
        XCTAssertGreaterThan(r.compactMap(\.hrvRMSSD).count, BulkSleep.hrvPoolingMinEpochs,
                             "the strict accessor still sees them — only the REFERENCE POOL excludes them")
        XCTAssertEqual(BulkSleep.hrvPooling(r), .noEvidence)
    }

    // MARK: - The statistic

    /// Known-answer test for the Hodges–Lehmann two-sample shift (median of all pairwise a−b).
    func testHodgesLehmannKnownAnswers() {
        XCTAssertEqual(BulkSleep.hrvShift([1, 2, 3], [1, 2, 3]), 0.0, accuracy: 1e-9,
                       "identical pools ⇒ zero shift")
        // a=[10,20] b=[1,2] ⇒ diffs 9,8,19,18 ⇒ sorted 8,9,18,19 ⇒ median (9+18)/2.
        XCTAssertEqual(BulkSleep.hrvShift([10, 20], [1, 2]), 13.5, accuracy: 1e-9)
        XCTAssertEqual(BulkSleep.hrvShift([5], [12]), -7.0, accuracy: 1e-9)
        XCTAssertEqual(BulkSleep.hrvShift([], [1, 2]), 0.0, "empty side ⇒ 0, never a crash")
        XCTAssertEqual(BulkSleep.hrvShift([1, 2], []), 0.0)
    }

    /// 50 % breakdown: replacing 10 % of the activity pool with the 200 ms band ceiling must not
    /// move the verdict. A mean would.
    func testShiftIsRobustToOutliers() {
        var r = night(activityHRVDelta: 0)
        var replaced = 0
        for i in r.indices where r[i].layout == .activity {
            if replaced * 10 >= 54 { break }
            if i % 5 == 0 {
                var b = r[i].raw; b[5] = 200; r[i] = BulkRecord(b)!
                replaced += 1
            }
        }
        XCTAssertGreaterThanOrEqual(replaced, 5, "at least 10 % of the activity pool was poisoned")
        XCTAssertEqual(BulkSleep.hrvPooling(r), .agree, "HL absorbs a 10 % outlier mass")
        // The same poisoning on the disagreeing shape must not rescue it either.
        var d = night(activityHRVDelta: -15)
        replaced = 0
        for i in d.indices where d[i].layout == .activity {
            if replaced * 10 >= 54 { break }
            if i % 5 == 0 { var b = d[i].raw; b[5] = 200; d[i] = BulkRecord(b)!; replaced += 1 }
        }
        XCTAssertEqual(BulkSleep.hrvPooling(d), .disagree)
    }

    /// The stride cap bounds an O(|a|·|b|) statistic without an RNG, so it is deterministic and
    /// verdict-neutral. 🟢 MEASURED: caps of 32…512 change 0 of 3092 real union-window verdicts.
    func testStrideCapIsVerdictNeutral() {
        let big = night(activityCount: 1600, sleepCount: 2400)
        XCTAssertGreaterThan(big.filter { $0.layout == .activity }.count, BulkSleep.hrvPoolingSampleCap,
                             "the activity pool must exceed the cap or this test is vacuous")
        let strided = stride(from: 0, to: big.count, by: 10).map { big[$0] }
        XCTAssertEqual(BulkSleep.hrvPooling(big), .agree)
        XCTAssertEqual(BulkSleep.hrvPooling(big), BulkSleep.hrvPooling(strided))

        let bigD = night(activityHRVDelta: -15, activityCount: 1600, sleepCount: 2400)
        let stridedD = stride(from: 0, to: bigD.count, by: 10).map { bigD[$0] }
        XCTAssertEqual(BulkSleep.hrvPooling(bigD), .disagree)
        XCTAssertEqual(BulkSleep.hrvPooling(bigD), BulkSleep.hrvPooling(stridedD))

        // Deterministic: no RNG anywhere on the path.
        let a = big.filter { $0.layout == .activity }.compactMap(\.measuredHRVRMSSD)
        let b = big.compactMap(\.hrvRMSSD)
        XCTAssertEqual(BulkSleep.hrvShift(a, b), BulkSleep.hrvShift(a, b))
        XCTAssertEqual(BulkSleep.hrvShift(a, a), 0.0, accuracy: 1e-9, "self-shift is 0 even when capped")
    }

    // MARK: - Constraint 2: the gate must be invisible to the sleep pipeline

    /// `hrvPooling` reads records; it never mutates them, and NOTHING outside `BulkSleep.samples`
    /// consumes its verdict. Pin every sleep consumer across all three verdicts AND against the
    /// pre-#185 (activity-HRV-zeroed) input, which is the only input the strict accessors can tell
    /// apart from this one.
    func testGateNeverTouchesStrictAccessors() {
        for delta in [0, -15] {
            let r = night(activityHRVDelta: delta)
            let pre = zeroedOnActivity(r)

            // Compute the sleep pipeline BEFORE any gate call…
            let timelineBefore = BulkSleep.sleepVitalTimeline(from: r)
            let coarseBefore = BulkSleep.sleepSegments(from: r)
            let stagedBefore = BulkSleep.stagedSegments(from: r)
            let mainSleep = BulkSleep.mainSleep(from: r)
            let napsBefore = NapDetection.naps(from: r, mainSleep: mainSleep)
            let stressBefore = SleepStress.overnightScore(records: r)
            let strictHRVBefore = r.compactMap(\.hrvRMSSD)
            let strictRRBefore = r.compactMap(\.respiratoryRate)

            // …exercise every verdict…
            _ = BulkSleep.hrvPooling(r)
            _ = BulkSleep.samples(from: r, calibratedBy: r)
            _ = BulkSleep.samples(from: r, calibratedBy: nil)
            _ = BulkSleep.samples(from: r, calibratedBy: night(activityHRVDelta: -15))

            // …and assert nothing moved, in either direction.
            XCTAssertEqual(BulkSleep.sleepVitalTimeline(from: r), timelineBefore)
            XCTAssertEqual(BulkSleep.sleepSegments(from: r), coarseBefore)
            XCTAssertEqual(BulkSleep.stagedSegments(from: r), stagedBefore)
            XCTAssertEqual(NapDetection.naps(from: r, mainSleep: mainSleep), napsBefore)
            XCTAssertEqual(SleepStress.overnightScore(records: r), stressBefore)
            XCTAssertEqual(r.compactMap(\.hrvRMSSD), strictHRVBefore)
            XCTAssertEqual(r.compactMap(\.respiratoryRate), strictRRBefore)

            // The strict accessors cannot even see #185's recovery, gated or not.
            XCTAssertEqual(BulkSleep.sleepVitalTimeline(from: pre), timelineBefore)
            XCTAssertEqual(BulkSleep.sleepSegments(from: pre), coarseBefore)
            XCTAssertEqual(BulkSleep.stagedSegments(from: pre), stagedBefore)
            XCTAssertEqual(NapDetection.naps(from: pre, mainSleep: BulkSleep.mainSleep(from: pre)), napsBefore)
            XCTAssertEqual(SleepStress.overnightScore(records: pre), stressBefore)
            XCTAssertEqual(pre.compactMap(\.hrvRMSSD), strictHRVBefore)

            // Anti-vacuity: the pinned pipeline is not empty.
            XCTAssertFalse(timelineBefore.isEmpty, "sleepVitalTimeline must be non-empty to pin anything")
        }
    }

    // MARK: - The calibrated constants

    /// Both constants are jointly calibrated on 3092 real 30-h union windows and a permutation null.
    /// Changing either must be a deliberate act with the new measurement in the diff.
    func testThresholdAndMinEpochsAreTheMeasuredValues() {
        XCTAssertEqual(BulkSleep.hrvPoolingNoiseFloorMs, 9.0,
                       "midpoint of the measured [5.0, 13.0) separation, above the null's p99 of 8.0")
        XCTAssertEqual(BulkSleep.hrvPoolingMinEpochs, 20,
                       "the separation gap saturates at 8.0 ms here; at 12 an agreeing archive reaches 8.0")
        XCTAssertEqual(BulkSleep.hrvPoolingSampleCap, 512)
    }
}
