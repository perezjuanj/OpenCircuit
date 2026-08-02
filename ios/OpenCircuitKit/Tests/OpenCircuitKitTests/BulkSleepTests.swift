import XCTest
@testable import OpenCircuitKit

// Fixtures are REAL 0x4c frames/records pulled from the 2026-06-13 overnight sync
// (desktop/captures/sleep_sync_btsnoop.log, FR02.018), decoded and aligned to the
// RingConn app's readout for that night. They mirror desktop/decode_bulk.py so the
// Swift port is provably byte-identical.
final class BulkSleepTests: XCTestCase {

    func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // A real, XOR-valid 0x4c page: header 4c 00 26, then 6 × 23-byte records, then XOR.
    let realPage = "4c00260c22a16b55210a7d120a010101010100000402400400000c22a20155000300"
        + "120a010101010100003c00000d01200c22a297540001005f0a010101010100001101b00f"
        + "00440c22a32d6027077b120a010101010100402501c02235a00c22a3c351260577120b01"
        + "0101010108a01000000401300c22a459502d0378120a01010101010160200000040ff0cc"

    // A single hand-verified deep-sleep record (counter 0c22d5bf): HR 68, HRV 77, SpO2 98.
    let deepSleepRec = "0c22d5bf444d057a620a01010101012aa0000090000004"

    func testPageSplitsIntoSixRecords() {
        let recs = BulkSleep.records(fromPage: hex(realPage))
        XCTAssertEqual(recs.count, 6, "page body is 138 B = 6 × 23-byte records")
    }

    func testInvalidPageRejected() {
        var bad = hex(realPage); bad[bad.count - 1] ^= 0xFF   // break XOR trailer
        XCTAssertTrue(BulkSleep.records(fromPage: bad).isEmpty, "bad XOR -> no records")
        XCTAssertTrue(BulkSleep.records(fromPage: hex("8100b031")).isEmpty, "wrong opcode -> none")
    }

    func testSleepVitalsRecordDecode() {
        // Deep-sleep epoch confirmed against the app: HR 68 / HRV 77 / SpO2 98.
        let r = BulkRecord(hex(deepSleepRec))!
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertEqual(r.counter, 0x0c22d5bf)
        XCTAssertEqual(r.heartRate, 68)
        XCTAssertEqual(r.hrvRMSSD, 77)
        XCTAssertEqual(r.spo2Percent, 98)
        XCTAssertEqual(r.motion, [1, 1, 1, 1, 1])
    }

    func testConfidenceAndFullActivityCounts() {
        // deepSleepRec bytes: [6]=0x05 (confidence), [10:20]=01 01 01 01 01 2a a0 00 00 90.
        let r = BulkRecord(hex(deepSleepRec))!
        XCTAssertEqual(r.confidence, 5)
        XCTAssertEqual(r.activityCounts, [1, 1, 1, 1, 1, 0x2a, 0xa0, 0x00, 0x00, 0x90])
        // activityCounts' first 5 bytes always equal `motion` — same underlying bytes.
        XCTAssertEqual(Array(r.activityCounts.prefix(5)), r.motion)
    }

    func testConfidenceNilOnIdleEpoch() {
        // Idle/unworn template (§5.3): [4:8]=05 00 0c 00, [9]=0a, motion 01x5, [15:22]=00x7.
        let idleRec = "0c0000000500" + "0c0001" + "0a" + "0101010101" + "00000000000000" + "00"
        let r = BulkRecord(hex(idleRec))!
        XCTAssertEqual(r.layout, .idle)
        XCTAssertNil(r.confidence)
    }

    func testCounterToWallClock() {
        // counter = seconds since syncEpoch (PROTOCOL.md §5.6).
        let r = BulkRecord(hex(deepSleepRec))!
        XCTAssertEqual(r.date(),
                       Date(timeIntervalSince1970: TimeInterval(Int(0x0c22d5bf) + Command.syncEpoch)))
    }

    func testActivityVsSleepLayout() {
        let recs = BulkSleep.records(fromPage: hex(realPage))
        // Records [0],[1] are activity epochs ([8]=0x12); record [2] is sleep-vitals ([8]=0x5f).
        XCTAssertEqual(recs[0].layout, .activity)
        XCTAssertEqual(recs[2].layout, .sleepVitals)
        XCTAssertEqual(recs[2].spo2Percent, 0x5f)        // 95 %
        XCTAssertEqual(recs[2].heartRate, 0x54)          // 84 bpm (waking/active in-bed)
        XCTAssertNil(recs[2].hrvRMSSD, "HRV byte is 0 here -> no sample")
        // ALL-DAY HR: an activity epoch ALSO carries HR at byte[4] (0x55 = 85 bpm here — matches
        // the adjacent sleep epoch's 84). HRV/SpO2 stay sleep-vitals-only (motion corrupts them and
        // [8] is the activity tag, not SpO2), so only HR is surfaced for activity epochs.
        XCTAssertEqual(recs[0].heartRate, 85, "activity epoch exposes all-day HR at [4]")
        XCTAssertNil(recs[0].hrvRMSSD, "the STRICT accessor stays sleep-vitals-only (#185)")
        XCTAssertNil(recs[0].spo2Percent, "no SpO2 on an activity epoch ([8] is the activity tag)")
    }

    // MARK: - #185 — HRV/RR recovered from activity epochs, sample path ONLY

    func testSamplesFromMovingActivityEpochEmitsHRAndRRButNotHRV() {
        // #185: an activity/awake epoch emits HR (byte[4]) AND respiratory rate (byte[7]/8), but its
        // HRV (byte[5]=33) is suppressed because [15:20] is non-zero — the ring says this epoch
        // MOVED, and the moving pool is where the 146–200 ms artifact tail lives.
        let r = BulkRecord(hex("0c22a16b55210a7d120a01010101010000040240040000"))!
        XCTAssertEqual(r.layout, .activity)
        XCTAssertFalse(r.motionIntensityTailIsZero, "fixture is a MOVING activity epoch")
        let s = BulkSleep.samples(from: [r])
        XCTAssertEqual(Set(s.map(\.kind)), [.heartRate, .respiratoryRate])
        XCTAssertEqual(s.first(where: { $0.kind == .heartRate })?.value, 85)
        XCTAssertEqual(s.first(where: { $0.kind == .respiratoryRate })?.value, 15.625)
        XCTAssertNil(r.hrvRMSSD, "the strict accessor is unchanged")
        XCTAssertNil(r.measuredHRVRMSSD, "moving activity epoch -> HRV suppressed")
        XCTAssertNil(r.spo2Percent, "byte[8] is the activity tag — never SpO2")
    }

    /// Same epoch with a ZEROED [15:20] tail — the ring's own "nothing moved" verdict — so the
    /// recovered HRV is admitted.
    func testQuietActivityEpochRecoversHRVAndRR() {
        let r = BulkRecord(hex("0c22a16b55210a7d120a01010101010000000000040000"))!
        XCTAssertEqual(r.layout, .activity, "must NOT be the idle template ([4]=0x55, not 0x05)")
        XCTAssertTrue(r.motionIntensityTailIsZero)
        XCTAssertNil(r.hrvRMSSD, "strict accessor unchanged — detection/staging see nothing new")
        XCTAssertNil(r.respiratoryRate, "strict accessor unchanged")
        XCTAssertEqual(r.measuredHRVRMSSD, 33)
        XCTAssertEqual(r.measuredRespiratoryRate, 15.625)
        XCTAssertEqual(Set(BulkSleep.samples(from: [r]).map(\.kind)),
                       [.heartRate, .hrvSDNN, .respiratoryRate])
    }

    /// THE ISOLATION PIN (#185 constraint 1). A recovered epoch must be invisible to every
    /// sleep-pipeline entry point.
    func testRecoveredVitalsAreInvisibleToSleepPipeline() {
        let quiet = BulkRecord(hex("0c22a16b55210a7d120a01010101010000000000040000"))!
        XCTAssertTrue(BulkSleep.sleepVitalTimeline(from: [quiet]).isEmpty,
                      "recovered HRV must never seed sleepVitalsRescue")
        XCTAssertNil(SleepStress.overnightScore(records: [quiet]),
                     "recovered HRV must never enter the stress median")
        XCTAssertTrue(SleepStress.stateDurations(records: [quiet]).isEmpty)
    }

    /// Guard boundaries, both sides, both metrics. Constants justified in the accessor docs.
    func testMeasuredVitalGuardBoundaries() {
        func quiet(hrv: UInt8, rr: UInt8) -> BulkRecord {
            var b = hex("0c22a16b55210a7d120a01010101010000000000040000")
            b[5] = hrv; b[7] = rr
            return BulkRecord(b)!
        }
        XCTAssertEqual(quiet(hrv: 200, rr: 125).measuredHRVRMSSD, 200, "200 ms is the corpus max — kept")
        XCTAssertNil(quiet(hrv: 201, rr: 125).measuredHRVRMSSD, "201 ms is byte garbage — dropped")
        XCTAssertNil(quiet(hrv: 0, rr: 125).measuredHRVRMSSD, "HRV byte 0 = no measurement")
        XCTAssertEqual(quiet(hrv: 33, rr: 32).measuredRespiratoryRate, 4.0,   "4.0 brpm floor — kept")
        XCTAssertNil(quiet(hrv: 33, rr: 31).measuredRespiratoryRate,          "3.875 brpm — dropped")
        XCTAssertEqual(quiet(hrv: 33, rr: 240).measuredRespiratoryRate, 30.0, "30.0 brpm ceiling — kept")
        XCTAssertNil(quiet(hrv: 33, rr: 241).measuredRespiratoryRate,         "30.125 brpm — dropped")
        XCTAssertNil(quiet(hrv: 33, rr: 0).measuredRespiratoryRate,           "RR byte 0 = no measurement")
    }

    /// The idle/unworn template must stay silent on BOTH new accessors even if its payload bytes
    /// were non-zero — `layout != .idle` is the first guard on each.
    func testIdleTemplateYieldsNoMeasuredVitals() {
        let idleRec = "0c0000000500" + "0c0001" + "0a" + "0101010101" + "00000000000000" + "00"
        let r = BulkRecord(hex(idleRec))!
        XCTAssertEqual(r.layout, .idle)
        XCTAssertNil(r.measuredHRVRMSSD)
        XCTAssertNil(r.measuredRespiratoryRate)
        XCTAssertTrue(BulkSleep.samples(from: [r]).isEmpty, "idle epoch emits nothing (unchanged)")
    }

    /// The band's ONE deliberate divergence, stated out loud (measured 0 occurrences in 1109
    /// shipped sleep-vitals HRV samples and 1084 RR samples): a sleep-vitals epoch with byte[5]
    /// in 201…255 or byte[7] in 1…31 is counted by STAGING but dropped from the HealthKit sample.
    func testSleepVitalsBandDivergenceIsDeliberate() {
        var b = hex("0c22d5bf444d057a620a01010101012aa0000090000004"); b[5] = 255
        let r = BulkRecord(b)!
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertEqual(r.hrvRMSSD, 255, "staging still sees it — its input is provably unchanged")
        XCTAssertNil(r.measuredHRVRMSSD, "but 255 ms never becomes a HealthKit sample")
    }

    /// A MOVING sleep-vitals epoch keeps emitting HRV — the quiet gate is activity-only. Measured:
    /// a symmetric gate would drop 382 of the 1109 HRV samples we ship today (34.4 %).
    func testMovingSleepVitalsEpochStillEmitsHRV() {
        var b = hex("0c22d5bf444d057a620a01010101012aa0000090000004")
        b[15] = 0x40                                   // non-zero intensity tail on a SLEEP epoch
        let r = BulkRecord(b)!
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertFalse(r.motionIntensityTailIsZero)
        XCTAssertEqual(r.measuredHRVRMSSD, 77, "quiet gate must NOT apply to sleep-vitals epochs")
    }

    func testSamplesFromSleepVitals() {
        let r = BulkRecord(hex(deepSleepRec))!
        let s = BulkSleep.samples(from: [r])
        XCTAssertEqual(s.count, 4, "HR + HRV + SpO2 + respiratory rate")
        let byKind = Dictionary(grouping: s, by: { $0.kind })
        XCTAssertEqual(byKind[.heartRate]?.first?.value, 68)
        XCTAssertEqual(byKind[.hrvSDNN]?.first?.value, 77)
        XCTAssertEqual(byKind[.spo2]?.first?.value, 0.98, "SpO2 emitted as 0…1 fraction")
        XCTAssertEqual(byKind[.respiratoryRate]?.first?.value, 15.25, "RR = byte[7] 0x7a / 8 (🟢)")
        XCTAssertEqual(s.first?.start,
                       Date(timeIntervalSince1970: TimeInterval(Int(0x0c22d5bf) + Command.syncEpoch)))
    }

    /// Build a synthetic 23-byte record: counter, motion byte (×5), subtype [8].
    func rec(_ counter: UInt32, motion: UInt8, sub: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[8] = sub
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// Realistic "active" motion. A MOVING wrist produces a VARYING accelerometer signal; a
    /// *constant* reading — at ANY level — is an idle/off-wrist signature (Gen-3 idles at a high
    /// constant ~16–39, Gen-2 at 1). Detection is now device-agnostic (subtracts a local idle
    /// floor), so a constant stream correctly reads as still regardless of its level — off-wrist
    /// idle is rejected by the temp/HR gates, not by pretending a constant value means motion.
    /// These fixtures previously used a constant byte for "active"; that only worked because the
    /// old absolute threshold was hard-coded to Gen 2's `1`. Varying motion is the real signal.
    private func activeMotion(_ i: Int) -> UInt8 { [0x0a, 0x28, 0x50][i % 3] }

    func testMotionTimelineExpansion() {
        let r = BulkRecord(hex(deepSleepRec))!
        let tl = BulkSleep.motionTimeline(from: [r])
        XCTAssertEqual(tl.count, 5, "5 sub-samples per 150 s epoch")
        XCTAssertEqual(tl[1].time.timeIntervalSince(tl[0].time), 30, "30 s spacing")
        XCTAssertEqual(tl[0].movement, 1, "motion baseline 01 = still")
    }

    func testSleepDetectionFindsNight() throws {
        // 20 active epochs, then ~9 h still (216 epochs @150 s), then 20 active.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for i in 0..<20 { recs.append(rec(c, motion: activeMotion(i), sub: 0x12)); c += 150 }
        let onset = c
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }
        let wake = c
        for i in 0..<20 { recs.append(rec(c, motion: activeMotion(i), sub: 0x12)); c += 150 }

        let block = try XCTUnwrap(BulkSleep.mainSleep(from: recs))
        XCTAssertEqual(block.activity, .sleep)
        // ~9 h block, boundaries near onset/wake (within the 15-min merge window).
        XCTAssertEqual(block.duration, 216 * 150, accuracy: 30 * 60)
        let segs = BulkSleep.sleepSegments(from: recs)
        XCTAssertTrue(segs.contains { $0.stage == .asleepCore }, "emits asleep core")
        let inBed = try XCTUnwrap(segs.first { $0.stage == .inBed }, "emits an inBed span")
        XCTAssertEqual(inBed.start.timeIntervalSince1970,
                       Double(Int(onset) + Command.syncEpoch), accuracy: 20 * 60)
        XCTAssertEqual(inBed.end.timeIntervalSince1970,
                       Double(Int(wake) + Command.syncEpoch), accuracy: 20 * 60)
    }

    /// Synthetic record with explicit HR (sleep-vitals layout).
    func rec(_ counter: UInt32, motion: UInt8, sub: UInt8, hr: UInt8) -> BulkRecord {
        let r = rec(counter, motion: motion, sub: sub)
        var b = r.raw; b[4] = hr
        return BulkRecord(b)!
    }

    func testStagingSeparatesDeepRemLight() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }   // awake
        // still block: 60 elevated-HR (REM), 60 low-HR (Deep), 60 mid-HR (Light). Deep is FLAT;
        // REM/Light carry HR jitter — that variability is how the model keeps them out of Deep
        // (a perfectly flat mid-HR block would correctly read as Deep). REM stays below the wake
        // threshold (floor 50 + 18) so it isn't trimmed as wake.
        for k in 0..<60 { recs.append(rec(c, motion: 0x01, sub: 0x62, hr: k % 2 == 0 ? 62 : 70)); c += 150 }  // REM
        for _ in 0..<60 { recs.append(rec(c, motion: 0x01, sub: 0x62, hr: 50)); c += 150 }                     // Deep (flat)
        for k in 0..<60 { recs.append(rec(c, motion: 0x01, sub: 0x62, hr: k % 2 == 0 ? 56 : 62)); c += 150 }  // Light (jittery)
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }   // awake

        let segs = BulkSleep.stagedSegments(from: recs)
        let stages = Set(segs.map(\.stage))
        XCTAssertTrue(stages.contains(.inBed))
        XCTAssertTrue(stages.contains(.asleepDeep), "low-HR region -> deep")
        XCTAssertTrue(stages.contains(.asleepREM), "elevated-HR region -> REM")
        XCTAssertTrue(stages.contains(.asleepCore), "mid-HR region -> light/core")
        // Deep segment should fall in the low-HR (middle) third of the night.
        let deep = segs.filter { $0.stage == .asleepDeep }.max(by: { $0.duration < $1.duration })!
        let remSeg = segs.filter { $0.stage == .asleepREM }.max(by: { $0.duration < $1.duration })!
        XCTAssertLessThan(remSeg.start, deep.start, "REM region (HR ~66) precedes Deep region (HR 50) as constructed")
    }

    func testStagingEmptyWithoutSleep() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for i in 0..<50 { recs.append(rec(c, motion: activeMotion(i), sub: 0x12, hr: 70)); c += 150 }
        XCTAssertTrue(BulkSleep.stagedSegments(from: recs).isEmpty, "no sleep block -> no staging")
    }

    func testNoSleepWhenAllActive() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for i in 0..<100 { recs.append(rec(c, motion: activeMotion(i), sub: 0x12)); c += 150 }
        XCTAssertNil(BulkSleep.mainSleep(from: recs))
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs).isEmpty)
    }

    func testIdleAndStreamSplit() {
        // Idle template record: motion 01×5 + zero payload -> .idle, no samples.
        let idle = BulkRecord(hex("0c099dbf05000c00120a01010101010000000000000000"))!
        XCTAssertEqual(idle.layout, .idle)
        XCTAssertTrue(BulkSleep.samples(from: [idle]).isEmpty)
        // Stream split drops a trailing partial chunk.
        XCTAssertEqual(BulkSleep.records(fromStream: hex(deepSleepRec) + [0xff, 0xff]).count, 1)
    }

    // MARK: #39 — desaturations keep their vitals (layout no longer gated on the SpO2 value)

    /// A genuine desaturation epoch (deepSleepRec with SpO2 byte 0x62→0x50 = 80 %, below the
    /// old 87…99 gate). It must still decode as sleep-vitals so HR/HRV/SpO2 survive — the old
    /// gate dropped the WHOLE epoch. The HR/HRV bytes are unchanged from the proven fixture.
    func testLowSpO2EpochKeepsVitals() {
        let r = BulkRecord(hex("0c22d5bf444d057a500a01010101012aa0000090000004"))!
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertEqual(r.heartRate, 68)
        XCTAssertEqual(r.hrvRMSSD, 77)
        XCTAssertEqual(r.spo2Percent, 80, "80 % is a plausible desaturation (≥70) — emitted")
        let kinds = Set(BulkSleep.samples(from: [r]).map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.heartRate, .hrvSDNN, .spo2]), "all vitals emitted")
    }

    /// An implausible SpO2 (< 70) is range-guarded out of the emitted sample, but the epoch
    /// stays sleep-vitals so its HR/HRV are not lost with it (SpO2 byte 0x62→0x30 = 48 %).
    func testImplausibleSpO2GuardedButHRKept() {
        let r = BulkRecord(hex("0c22d5bf444d057a300a01010101012aa0000090000004"))!
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertNil(r.spo2Percent, "48 % is implausible → dropped")
        XCTAssertEqual(r.heartRate, 68, "but HR survives")
        XCTAssertEqual(r.hrvRMSSD, 77)
    }

    // MARK: HR physiological band (the "Resting HR 4 bpm" bug)
    //
    // The history/sleep decoder previously returned any raw[4] > 0 as HR, so a garbage epoch
    // (byte[4]==4) became a 4 bpm sample that surfaced as an impossible Resting HR and depressed
    // the sleep score / per-stage HR / Apple Health mirror. HR is now band-guarded (LiveHR.validBPM,
    // 30…220) at the single decode choke point; HRV/SpO2/RR of the same epoch are unaffected.

    func testHeartRateRejectsSubPhysiologicalValue() {
        var b = hex(deepSleepRec); b[4] = 4
        let r = BulkRecord(b)!
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertNil(r.heartRate, "4 bpm is below the 30 bpm physiological floor")
        let samples = BulkSleep.samples(from: [r])
        XCTAssertTrue(samples.filter { $0.kind == .heartRate }.isEmpty,
                      "sub-floor HR must not become a persisted sample")
        XCTAssertTrue(Set(samples.map(\.kind)).isSuperset(of: [.hrvSDNN, .spo2]),
                      "HRV/SpO2 of the same epoch still decode")
    }

    func testHeartRateBandBoundaries() {
        var hi = hex(deepSleepRec); hi[4] = 240          // > 220 ceiling → dropped
        XCTAssertNil(BulkRecord(hi)!.heartRate)
        var below = hex(deepSleepRec); below[4] = 29     // just below the 30 floor → dropped
        XCTAssertNil(BulkRecord(below)!.heartRate)
        var loEdge = hex(deepSleepRec); loEdge[4] = 30   // 30 floor inclusive
        XCTAssertEqual(BulkRecord(loEdge)!.heartRate, 30)
        var hiEdge = hex(deepSleepRec); hiEdge[4] = 220  // 220 ceiling inclusive
        XCTAssertEqual(BulkRecord(hiEdge)!.heartRate, 220)
    }

    // MARK: #41 — wear gate WIRED through BulkSleep.sleepSegments / mainSleep
    //
    // SleepDetection's temperature path is covered in SleepDetectionTests; these assert the
    // `temperatures:` overload that RingSession actually calls threads that gate end-to-end, so
    // a charging/off-wrist still night doesn't get committed (to the dashboard or Apple Health)
    // as a night of sleep.

    /// A synthetic night: 20 active epochs, ~9 h still (216 epochs), 20 active. One temperature
    /// sample per epoch at `celsius`, spanning the records' real time range.
    private func night() -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        return recs
    }
    private func temps(for recs: [BulkRecord], celsius: Double) -> [TemperatureSample] {
        recs.map { TemperatureSample(time: $0.date(), celsius: celsius) }
    }

    func testSleepSegmentsWearGateDropsColdNight() {
        let recs = night()
        // Motion-only (status quo): the still block reads as a night of sleep.
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs).contains { $0.stage == .inBed },
                      "motion-only: still block reads as sleep")
        // Worn (32 °C): still a night of sleep.
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs, temperatures: temps(for: recs, celsius: 32))
                        .contains { $0.stage == .inBed },
                      "worn temps keep the night")
        // Cold (22 °C, off-wrist / charging): no sleep night survives the gate.
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs, temperatures: temps(for: recs, celsius: 22)).isEmpty,
                      "cold (unworn) still block must not produce a sleep night")
    }

    func testMainSleepWearGateDropsColdNight() {
        let recs = night()
        XCTAssertNotNil(BulkSleep.mainSleep(from: recs, temperatures: temps(for: recs, celsius: 32)),
                        "worn night has a main sleep block")
        XCTAssertNil(BulkSleep.mainSleep(from: recs, temperatures: temps(for: recs, celsius: 22)),
                     "cold night yields no main sleep block")
    }

    func testSleepSegmentsEmptyTemperaturesUnchanged() {
        let recs = night()
        XCTAssertEqual(BulkSleep.sleepSegments(from: recs, temperatures: []).count,
                       BulkSleep.sleepSegments(from: recs).count,
                       "no temp coverage ⇒ identical to motion-only (absence ≠ unworn)")
    }
}
