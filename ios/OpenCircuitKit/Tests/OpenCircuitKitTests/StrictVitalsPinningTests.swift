import XCTest
@testable import OpenCircuitKit

/// #185 CONSTRAINT 1 — the byte-identity net.
///
/// `measuredHRVRMSSD` / `measuredRespiratoryRate` recover HRV and RR from `0x12`/`0x13` ACTIVITY
/// epochs so they can reach Apple Health. The strict `hrvRMSSD` / `respiratoryRate` accessors stay
/// sleep-vitals-scoped because sleep DETECTION, STAGING, NAPS and `SleepStress` consume that scope
/// as the ring's "I am measuring sleep" MODE flag — widening it would MOVE the detected night.
///
/// Access control already makes that a compile-time guarantee for the app target (both new
/// accessors are `internal`, and `RingSession` lives in another module). This suite closes the
/// remaining hole: a future edit INSIDE OpenCircuitKit re-pointing a sleep consumer at a
/// `measured*` accessor. Every test builds the same synthetic night TWICE — once with plausible
/// HRV/RR bytes on the quiet activity epochs, once with those two bytes ZEROED — and asserts the
/// sleep pipeline cannot tell them apart. If anyone widens the scope, these fail BY NAME.
///
/// Synthetic records only: real captures are health data and are never committed.
final class StrictVitalsPinningTests: XCTestCase {

    // MARK: - Synthetic night

    /// One 23-byte 0x4c record. `[8] == 0x12` makes it an ACTIVITY epoch, anything else in the
    /// SpO2 band makes it sleep-vitals (`BulkRecord.layout`).
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

    /// An evening/morning epoch: the ring tags it `0x12` and its `[15:20]` intensity tail is ZERO,
    /// so `motionIntensityTailIsZero` calls it quiet and #185 recovers its HRV. Its `[10:15]`
    /// motion channel still VARIES — this is exactly the awake-but-quiet epoch that would extend
    /// the night if the strict sleep-vitals scope ever leaked.
    private func quietActivity(_ counter: UInt32, hr: UInt8, m: UInt8) -> BulkRecord {
        rec(counter: counter, hr: hr, hrv: 58, rr: 121, tag: 0x12,
            motion: [m, m &+ 9, m &+ 3, m &+ 14, m &+ 6], tail: [0, 0, 0, 0, 0])
    }

    private func sleepVitals(_ counter: UInt32, hr: UInt8, hrv: UInt8, spo2: UInt8) -> BulkRecord {
        rec(counter: counter, hr: hr, hrv: hrv, rr: 121, tag: spo2,
            motion: [1, 1, 1, 1, 1], tail: [0, 0, 0, 0, 0])
    }

    /// Sleep-vitals epochs for the core of the night, bracketed and interrupted by QUIET activity
    /// epochs (evening lead-in, a mid-night stretch, a morning tail) — the three places a leaked
    /// scope would move a boundary.
    private func night() -> [BulkRecord] {
        var out: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        func step() -> UInt32 { defer { c &+= 150 }; return c }

        for i in 0..<16 {                                   // awake evening, quiet but moving
            out.append(quietActivity(step(), hr: 68, m: UInt8(20 + (i * 7) % 40)))
        }
        for i in 0..<40 {                                   // first half of the night
            out.append(sleepVitals(step(), hr: UInt8(52 + i % 5),
                                   hrv: UInt8(60 + (i * 3) % 25), spo2: UInt8(96 + i % 3)))
        }
        for i in 0..<4 {                                    // mid-night quiet activity stretch
            out.append(quietActivity(step(), hr: 56, m: UInt8(12 + i * 5)))
        }
        for i in 0..<60 {                                   // second half of the night
            out.append(sleepVitals(step(), hr: UInt8(50 + i % 6),
                                   hrv: UInt8(64 + (i * 5) % 30), spo2: UInt8(95 + i % 4)))
        }
        for i in 0..<16 {                                   // awake morning, quiet but moving
            out.append(quietActivity(step(), hr: 72, m: UInt8(25 + (i * 11) % 45)))
        }
        return out
    }

    /// The SAME records with `[5]` and `[7]` zeroed on every ACTIVITY epoch — i.e. a ring that never
    /// populated them. Sleep-vitals epochs are untouched, so anything reading the strict accessors
    /// sees an identical input.
    private func zeroedOnActivity(_ records: [BulkRecord]) -> [BulkRecord] {
        records.map { r in
            guard r.layout == .activity else { return r }
            var b = r.raw
            b[5] = 0; b[7] = 0
            return BulkRecord(b)!
        }
    }

    // MARK: - Anti-vacuity

    /// If the two inputs did not actually differ in what #185 recovers, every pin below would pass
    /// trivially. Assert the difference is real and large before asserting it is invisible.
    func testFixtureActuallyExercisesTheRecovery() {
        let a = night(), b = zeroedOnActivity(night())
        XCTAssertEqual(a.count, b.count)
        let recovered = a.filter { $0.layout == .activity && $0.measuredHRVRMSSD != nil }.count
        XCTAssertEqual(recovered, 36, "36 quiet activity epochs carry recoverable HRV")
        XCTAssertEqual(b.filter { $0.layout == .activity && $0.measuredHRVRMSSD != nil }.count, 0)
        // …and the sample path DOES see the difference (that is the whole point of #185).
        let ha = BulkSleep.samples(from: a).filter { $0.kind == .hrvSDNN }.count
        let hb = BulkSleep.samples(from: b).filter { $0.kind == .hrvSDNN }.count
        XCTAssertEqual(ha - hb, 36, "recovered HRV reaches the HealthKit sample path")
        let ra = BulkSleep.samples(from: a).filter { $0.kind == .respiratoryRate }.count
        let rb = BulkSleep.samples(from: b).filter { $0.kind == .respiratoryRate }.count
        XCTAssertEqual(ra - rb, 36, "recovered RR reaches the HealthKit sample path")
        // The STRICT accessors, by contrast, see nothing at all.
        XCTAssertEqual(a.compactMap(\.hrvRMSSD), b.compactMap(\.hrvRMSSD))
        XCTAssertEqual(a.compactMap(\.respiratoryRate), b.compactMap(\.respiratoryRate))
    }

    // MARK: - The pins

    func testSleepVitalTimelineUnchanged() {
        XCTAssertEqual(BulkSleep.sleepVitalTimeline(from: night()),
                       BulkSleep.sleepVitalTimeline(from: zeroedOnActivity(night())),
                       "sleepVitalTimeline feeds ActivityPeriod.sleepVitalsRescue — it must never "
                       + "see a recovered activity-epoch HRV (#185 constraint 1)")
    }

    func testMainSleepDetectionUnchanged() {
        XCTAssertEqual(BulkSleep.mainSleep(from: night()),
                       BulkSleep.mainSleep(from: zeroedOnActivity(night())),
                       "the detected in-bed window must not move")
    }

    func testCoarseSleepSegmentsUnchanged() {
        XCTAssertEqual(BulkSleep.sleepSegments(from: night()),
                       BulkSleep.sleepSegments(from: zeroedOnActivity(night())))
    }

    func testStagingUnchangedAtDefaultTuning() {
        XCTAssertEqual(SleepStaging.classify(from: night()),
                       SleepStaging.classify(from: zeroedOnActivity(night())))
    }

    /// The default Tuning has `rrVarWeight == 0`, so a default-only test could pass because the RR
    /// term is switched off rather than because the input is pinned. The supervised fitter
    /// (`desktop/ringconn_sleep_fit.py`) runs non-default tunings, so pin one with BOTH variability
    /// weights live.
    func testStagingUnchangedWithHRVAndRRVariabilityWeightsLive() {
        let t = SleepStaging.Tuning(hrvVarWeight: 1.0, rrVarWeight: 1.0)
        XCTAssertGreaterThan(t.rrVarWeight, 0, "guard against a future default change hiding this")
        XCTAssertEqual(SleepStaging.classify(from: night(), tuning: t),
                       SleepStaging.classify(from: zeroedOnActivity(night()), tuning: t))
    }

    func testNapDetectionUnchanged() {
        let a = night(), b = zeroedOnActivity(night())
        XCTAssertEqual(NapDetection.naps(from: a, mainSleep: BulkSleep.mainSleep(from: a)),
                       NapDetection.naps(from: b, mainSleep: BulkSleep.mainSleep(from: b)))
    }

    func testSleepStressUnchanged() {
        XCTAssertEqual(SleepStress.overnightScore(records: night()),
                       SleepStress.overnightScore(records: zeroedOnActivity(night())),
                       "the stress median is built from the STRICT hrvRMSSD")
        XCTAssertEqual(SleepStress.stateDurations(records: night()),
                       SleepStress.stateDurations(records: zeroedOnActivity(night())))
    }

    /// `SleepDetailMetrics.averageHRByStage` filters on `layout == .sleepVitals` directly, so it is
    /// pinned by constraint 3 (layout untouched) rather than by the accessors — assert it anyway,
    /// since it consumes the staged segments the pins above protect.
    func testSleepDetailMetricsUnchanged() {
        let a = night(), b = zeroedOnActivity(night())
        XCTAssertEqual(SleepDetailMetrics.averageHRByStage(records: a,
                                                           segments: SleepStaging.classify(from: a)),
                       SleepDetailMetrics.averageHRByStage(records: b,
                                                           segments: SleepStaging.classify(from: b)))
    }

    // MARK: - Constraint 3: the false-nap gate still bites

    /// `NapDetection` gates false naps on the SLEEP-VITALS SHARE of a still block, read straight off
    /// `layout` — which #185 does not touch. A sedentary daytime still block of quiet `0x12` epochs
    /// now carries plausible HRV and RR, and must STILL produce zero naps. This is the exact failure
    /// mode that loosening `layout` (rather than adding a separate accessor) would have caused.
    func testSedentaryQuietActivityBlockIsStillNotANap() {
        var out: [BulkRecord] = []
        var c: UInt32 = 0x0c230000
        for _ in 0..<60 {                       // 2.5 h of still, quiet, awake-at-a-desk epochs
            out.append(rec(counter: c, hr: 66, hrv: 58, rr: 121, tag: 0x12,
                           motion: [1, 1, 1, 1, 1], tail: [0, 0, 0, 0, 0]))
            c &+= 150
        }
        XCTAssertTrue(out.allSatisfy { $0.layout == .activity })
        XCTAssertTrue(out.allSatisfy { $0.measuredHRVRMSSD == 58 }, "HRV IS recoverable here")
        XCTAssertTrue(out.allSatisfy { $0.hrvRMSSD == nil }, "…but the sleep-vitals share stays 0")
        XCTAssertTrue(NapDetection.naps(from: out, mainSleep: nil).isEmpty,
                      "a sedentary daytime block must never become a nap (#185 constraint 3)")
    }
}
