import XCTest
@testable import OpenRingKit

// Fixtures are REAL 0x4c frames/records pulled from the 2026-06-13 overnight sync
// (desktop/captures/sleep_sync_btsnoop.log, FR02.018), decoded and aligned to the
// RingConn app's readout for that night. They mirror desktop/decode_bulk.py so the
// Swift port is provably byte-identical.
//
// #39 regression guard: additional helpers and tests verify that the idle-template
// check (not the SpO2 range) gates layout, so desaturation epochs are never dropped.
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

    func testCounterToWallClock() {
        // counter = seconds since syncEpoch (PROTOCOL.md §5.6).
        let r = BulkRecord(hex(deepSleepRec))!
        XCTAssertEqual(r.date(),
                       Date(timeIntervalSince1970: TimeInterval(Int(0x0c22d5bf) + Command.syncEpoch)))
    }

    func testLayoutAfterFix() {
        // After #39 fix: the layout discriminator is the idle template (🟢), NOT the
        // SpO2 range in raw[8]. Records with raw[8]=0x12 (which is not in SpO2 range
        // 87–99) are now `.sleepVitals` — previously they returned `.activity`.
        let recs = BulkSleep.records(fromPage: hex(realPage))
        // Record [0]: raw[8]=0x12 (not in old SpO2 range 87–99) — now .sleepVitals.
        // Not idle because raw[4:8] = 55 21 0a 7d ≠ 05 00 0c 00.
        XCTAssertEqual(recs[0].layout, .sleepVitals,
            "#39 fix: non-idle records are sleepVitals regardless of raw[8] value")
        // Record [2]: raw[8]=0x5f (95%) — was sleepVitals before, still sleepVitals.
        XCTAssertEqual(recs[2].layout, .sleepVitals)
        XCTAssertEqual(recs[2].spo2Percent, 0x5f)        // 95 %
        XCTAssertEqual(recs[2].heartRate, 0x54)          // 84 bpm (waking/active in-bed)
        XCTAssertNil(recs[2].hrvRMSSD, "HRV byte is 0 here -> no sample")
        // Record [0] now exposes HR (raw[4]=0x55=85): previously returned nil as .activity.
        XCTAssertEqual(recs[0].heartRate, 0x55,
            "non-idle records now expose HR at raw[4] (sleepVitals path)")
        // SpO2 at raw[8]=0x12=18 is outside 70–100 guard -> nil (sensor artefact).
        XCTAssertNil(recs[0].spo2Percent, "raw[8]=0x12 is not a plausible SpO2 -> guarded nil")
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

    func testMotionTimelineExpansion() {
        let r = BulkRecord(hex(deepSleepRec))!
        let tl = BulkSleep.motionTimeline(from: [r])
        XCTAssertEqual(tl.count, 5, "5 sub-samples per 150 s epoch")
        XCTAssertEqual(tl[1].time.timeIntervalSince(tl[0].time), 30, "30 s spacing")
        XCTAssertEqual(tl[0].movement, 1, "motion baseline 01 = still")
    }

    func testSleepDetectionFindsNight() {
        // 20 active epochs, then ~9 h still (216 epochs @150 s), then 20 active.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        let onset = c
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }
        let wake = c
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }

        let block = BulkSleep.mainSleep(from: recs)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.activity, .sleep)
        // ~9 h block, boundaries near onset/wake (within the 15-min merge window).
        XCTAssertEqual(block!.duration, 216 * 150, accuracy: 30 * 60)
        let segs = BulkSleep.sleepSegments(from: recs)
        XCTAssertTrue(segs.contains { $0.stage == .inBed }, "emits an inBed span")
        XCTAssertTrue(segs.contains { $0.stage == .asleepCore }, "emits asleep core")
        let inBed = segs.first { $0.stage == .inBed }!
        XCTAssertEqual(inBed.start.timeIntervalSince1970,
                       Double(Int(onset) + Command.syncEpoch), accuracy: 20 * 60)
        XCTAssertEqual(inBed.end.timeIntervalSince1970,
                       Double(Int(wake) + Command.syncEpoch), accuracy: 20 * 60)
    }

    /// Synthetic record with explicit HR (sleep-vitals layout — raw[4]=hr).
    func rec(_ counter: UInt32, motion: UInt8, sub: UInt8, hr: UInt8) -> BulkRecord {
        let r = rec(counter, motion: motion, sub: sub)
        var b = r.raw; b[4] = hr
        return BulkRecord(b)!
    }

    func testStagingSeparatesDeepRemLight() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }   // awake
        // still block: 60 high-HR (REM), 60 low-HR (Deep), 60 mid-HR (Light)
        for _ in 0..<60 { recs.append(rec(c, motion: 0x01, sub: 0x62, hr: 72)); c += 150 }
        for _ in 0..<60 { recs.append(rec(c, motion: 0x01, sub: 0x62, hr: 50)); c += 150 }
        for _ in 0..<60 { recs.append(rec(c, motion: 0x01, sub: 0x62, hr: 60)); c += 150 }
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }   // awake

        let segs = BulkSleep.stagedSegments(from: recs)
        let stages = Set(segs.map(\.stage))
        XCTAssertTrue(stages.contains(.inBed))
        XCTAssertTrue(stages.contains(.asleepDeep), "low-HR region -> deep")
        XCTAssertTrue(stages.contains(.asleepREM), "high-HR region -> REM")
        XCTAssertTrue(stages.contains(.asleepCore), "mid-HR region -> light/core")
        // Deep segment should fall in the low-HR (middle) third of the night.
        let deep = segs.filter { $0.stage == .asleepDeep }.max(by: { $0.duration < $1.duration })!
        let remSeg = segs.filter { $0.stage == .asleepREM }.max(by: { $0.duration < $1.duration })!
        XCTAssertLessThan(remSeg.start, deep.start, "REM region (HR 72) precedes Deep region (HR 50) as constructed")
    }

    func testStagingEmptyWithoutSleep() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<50 { recs.append(rec(c, motion: 0x18, sub: 0x12, hr: 70)); c += 150 }
        XCTAssertTrue(BulkSleep.stagedSegments(from: recs).isEmpty, "no sleep block -> no staging")
    }

    func testNoSleepWhenAllActive() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<100 { recs.append(rec(c, motion: 0x18, sub: 0x12)); c += 150 }
        XCTAssertNil(BulkSleep.mainSleep(from: recs))
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs).isEmpty)
    }

    func testIdleAndStreamSplit() {
        // Idle template record confirmed 🟢: raw[4:8]=05 00 0c 00, raw[9]=0x0a,
        // raw[10:15]=01×5, raw[15:22]=00×7 -> .idle, no samples.
        let idle = BulkRecord(hex("0c099dbf05000c00120a01010101010000000000000000"))!
        XCTAssertEqual(idle.layout, .idle)
        XCTAssertTrue(BulkSleep.samples(from: [idle]).isEmpty)
        // Stream split drops a trailing partial chunk.
        XCTAssertEqual(BulkSleep.records(fromStream: hex(deepSleepRec) + [0xff, 0xff]).count, 1)
    }

    // MARK: - #39 Regression tests: desaturation epochs must not be dropped

    // Build a synthetic non-idle (sleepVitals) 23-byte record using confirmed byte
    // positions (🟢 PROTOCOL.md §5.3): raw[4]=HR, raw[5]=HRV, raw[8]=SpO2.
    // The record deliberately does NOT match the idle template (raw[4]=hr ≠ 0x05
    // unless hr happens to be 5 and the rest also match, which we avoid with SpO2
    // being set at raw[8] which breaks the 0x0c needed at raw[6]).
    private func makeSleepRecord(spo2: UInt8, hr: UInt8 = 60, hrv: UInt8 = 30) -> BulkRecord {
        var b = [UInt8](repeating: 0x00, count: 23)
        b[0] = 0x0c; b[1] = 0x0a; b[2] = 0x01; b[3] = 0x2c  // counter
        b[4] = hr     // HR at raw[4] (🟢)
        b[5] = hrv    // HRV at raw[5] (🟢)
        b[8] = spo2   // SpO2 at raw[8] (🟢)
        // raw[10] = 0x00 (not 0x01) — breaks the 01×5 baseline, so not idle regardless
        return BulkRecord(b)!
    }

    func testDesaturationEpochIsSleepVitals() {
        // SpO2 = 82 % (0x52): below 87, would be classified as .activity under the
        // pre-#39 code because 0x52 is not in range 0x57–0x63.
        // After #39 fix: .sleepVitals (idle template governs, not SpO2 range).
        let r = makeSleepRecord(spo2: 82, hr: 70, hrv: 20)
        XCTAssertEqual(r.layout, .sleepVitals,
            "SpO2 < 87 % must not affect layout — #39 regression guard")
        XCTAssertEqual(r.spo2Percent, 82)
        XCTAssertEqual(r.heartRate, 70)
        XCTAssertEqual(r.hrvRMSSD, 20)
    }

    func testSevereDesaturationEpochIsSleepVitals() {
        // SpO2 = 70 % (lower bound of the 70–100 guard): still .sleepVitals.
        let r = makeSleepRecord(spo2: 70)
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertEqual(r.spo2Percent, 70, "70 % is the lower bound of the physiological guard")
    }

    func testSpO2BelowGuardIsNil() {
        // SpO2 = 69 %: outside the 70–100 guard -> nil.
        // The epoch is still .sleepVitals (guard only affects the spo2Percent value,
        // NOT layout — the epoch's HR/HRV data are kept).
        let r = makeSleepRecord(spo2: 69, hr: 72, hrv: 30)
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertNil(r.spo2Percent, "SpO2 = 69 is below the 70 lower-bound guard")
        XCTAssertNotNil(r.heartRate, "HR is still surfaced even when SpO2 is guarded out")
    }

    func testSpO2AboveCeilingIsNil() {
        let r = makeSleepRecord(spo2: 101)
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertNil(r.spo2Percent, "SpO2 = 101 is above ceiling")
    }

    func testSpO2At100IsValid() {
        let r = makeSleepRecord(spo2: 100)
        XCTAssertEqual(r.layout, .sleepVitals)
        XCTAssertEqual(r.spo2Percent, 100)
    }

    func testIdleTemplateCheckBothSubtags() {
        // Idle alternates between subtype raw[8]=0x12 and 0x13 (PROTOCOL.md §5.3 🟢).
        // The new idle check does NOT include raw[8] as a gate — it uses raw[4:8] and
        // the payload pattern, making it robust to future subtype variants.
        let makeIdle = { (sub: UInt8) -> BulkRecord in
            var b = [UInt8](repeating: 0x00, count: 23)
            b[0] = 0x0c; b[1] = 0x09; b[2] = 0x9d; b[3] = 0xbf
            b[4] = 0x05; b[5] = 0x00; b[6] = 0x0c; b[7] = 0x00
            b[8] = sub
            b[9] = 0x0a
            for k in 0..<5 { b[10 + k] = 0x01 }
            return BulkRecord(b)!
        }
        XCTAssertEqual(makeIdle(0x12).layout, .idle, "subtype 0x12 idle")
        XCTAssertEqual(makeIdle(0x13).layout, .idle, "subtype 0x13 idle")
        XCTAssertNil(makeIdle(0x12).heartRate, "idle -> no HR")
        XCTAssertNil(makeIdle(0x12).spo2Percent, "idle -> no SpO2")
    }

    // MARK: - #41 wear gating through BulkSleep

    func testMainSleepGatedByColdTemperature() {
        // 20 active + 216 still + 20 active, but temperature = 18 °C (off-wrist/charger).
        // With temperature gating, the still block is not classified as sleep.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        let base = Date(timeIntervalSince1970: TimeInterval(Int(c) + Command.syncEpoch))
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        let duration = Double(256 * 150)
        let temps = stride(from: 0.0, through: duration, by: 150.0).map { offset in
            TemperatureSample(time: base.addingTimeInterval(offset), tempCelsius: 18.0)
        }
        XCTAssertNil(BulkSleep.mainSleep(from: recs, temperatureSamples: temps),
            "#41: still but cold (charger) -> no sleep block detected")
    }

    func testMainSleepPassesWithWarmTemperature() {
        // Same motion profile but ring is warm (32 °C = worn) -> sleep detected.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        let base = Date(timeIntervalSince1970: TimeInterval(Int(c) + Command.syncEpoch))
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        let duration = Double(256 * 150)
        let temps = stride(from: 0.0, through: duration, by: 150.0).map { offset in
            TemperatureSample(time: base.addingTimeInterval(offset), tempCelsius: 32.0)
        }
        XCTAssertNotNil(BulkSleep.mainSleep(from: recs, temperatureSamples: temps),
            "#41: still and warm (worn) -> sleep block detected")
    }
}
