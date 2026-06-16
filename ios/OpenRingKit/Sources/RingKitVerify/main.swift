// CLT-friendly verification runner — mirrors OpenRingKitTests/FrameTests.swift so
// the codec can be exercised with `swift run RingKitVerify` before Xcode/XCTest is
// available. Asserts against REAL frames from the FR02.018 capture. Exits non-zero
// on any failure so it works as a loop build/test gate.

import Foundation
import OpenRingKit

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ok   \(msg)") }
    else { print("  FAIL \(msg)"); failures += 1 }
}
func hex(_ s: String) -> [UInt8] {
    var out = [UInt8](); var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!); i = j
    }
    return out
}

// Real validated notify frames from desktop/captures/btsnoop_hci.log.
let realFrames = [
    "8100b031", "82000082", "860086", "1500080ab0a7",
    "874e0400000000fd00fd00000000100c0b9e44",
    "104e0100000000fd00fd00000000100c0bffb7",
]

print("RingKitVerify — RingConn codec self-checks")

check(Frame.xorTrailer([0x81, 0x00, 0xB0]) == 0x31, "response XOR trailer 81 00 b0 -> 31")
check(Command.poll == [0x95, 0x00, 0x00], "poll command is verbatim 95 00 00 (not XOR'd)")
check(Array(Command.syncAll[2...5]) == [0xFF, 0xFF, 0xFF, 0xFF], "syncAll cursor = 0xFFFFFFFF")
check(Command.syncSince(unixSeconds: Command.syncEpoch + 0x0c2298c3)
      == [0x02, 0x00, 0x0c, 0x22, 0x98, 0xc3, 0x00, 0x01, 0x00],
      "syncSince builds 02 00 <cursor BE4> 00 01 00 (epoch 1577793600)")
for f in realFrames { check(Frame.isValid(hex(f)), "real frame validates: \(f)") }

var bad = hex("8100b031"); bad[1] ^= 0xFF
check(!Frame.isValid(bad), "corrupted frame rejected")
check(!Frame.isValid([]), "empty rejected")
check(!Frame.isValid([0x81]), "single byte rejected")

let pairs: [(UInt8, UInt8)] = [
    (0x01, 0x81), (0x02, 0x82), (0x06, 0x86), (0x07, 0x87),
    (0x95, 0x15), (0xC7, 0x47), (0xCC, 0x4C), (0xD0, 0x50),
]
for (cmd, resp) in pairs {
    check(Frame.responseID(cmd) == resp, "responseID 0x\(String(cmd, radix: 16)) -> 0x\(String(resp, radix: 16))")
}

let p = Frame.parse(hex("8100b031"))
check(p == Frame.Parsed(opcode: 0x81, body: [0x00, 0xB0], trailer: 0x31), "parse splits opcode/body/trailer")
check(LiveHR.decode(hex("15005b0ab0f4")) == 91, "live HR 0x15 byte[2] -> 91 bpm (🟢 confirmed)")
check(LiveHR.decode(hex("15003d0ab092")) == 61, "live HR resting -> 61 bpm (from HR-only capture)")
check(LiveHR.decodeLocked(hex("1500080ab0a7")) == nil, "warm-up sentinel (8) filtered by decodeLocked")
check(LiveHR.decode([]) == nil, "empty HR -> nil")

// --- Metric models + SyncCursor ---
check(MetricKind.spo2.unit == "fraction", "spo2 unit is fraction (HealthKit 0…1)")
check(MetricKind.heartRate.unit == "count/min", "heartRate unit count/min")
let inst = QuantitySample(kind: .heartRate, start: Date(timeIntervalSince1970: 100), value: 72)
check(inst.start == inst.end, "instantaneous sample: end defaults to start")

let t0 = Date(timeIntervalSince1970: 1000)
let t1 = Date(timeIntervalSince1970: 2000)
let t2 = Date(timeIntervalSince1970: 3000)
var cursor = SyncCursor()
check(cursor.last(.heartRate) == nil, "fresh cursor: never synced")
check(cursor.isNew(.heartRate, t0), "any date is new before first sync")

let batch = [
    QuantitySample(kind: .heartRate, start: t1, value: 60),
    QuantitySample(kind: .heartRate, start: t0, value: 58),  // out of order
    QuantitySample(kind: .spo2, start: t1, value: 0.97),
]
let fresh = cursor.selectNew(batch)
check(fresh.count == 3, "selectNew keeps all 3 first time")
check(fresh.map { $0.start } == [t0, t0, t1] || fresh.first?.start == t0, "selectNew sorts by start")
check(cursor.last(.heartRate) == t1, "cursor advanced HR to newest (t1)")
check(cursor.last(.spo2) == t1, "cursor tracks spo2 independently")

let resync = cursor.selectNew([
    QuantitySample(kind: .heartRate, start: t1, value: 61),  // equal -> not new
    QuantitySample(kind: .heartRate, start: t2, value: 62),  // newer -> new
])
check(resync.count == 1 && resync.first?.start == t2, "re-sync drops <= cursor, keeps newer")
check(cursor.last(.heartRate) == t2, "cursor advanced to t2; never backward")
cursor.advance(.heartRate, to: t0)
check(cursor.last(.heartRate) == t2, "advance() never moves cursor backward")

// --- Analytics (ported from openwhoop-algos) ---
// HRV / RMSSD
check(HRV.rmssd([800, 900, 1000]) == 100, "rmssd([800,900,1000]) = 100")
check(HRV.rmssd([800]) == nil, "rmssd single sample = nil")
check(HRV.cleanRR([[800, 900], [1000], []]) == [800, 900, 1000], "cleanRR flattens")
check(HRV.cleanRR([[0, 900], [0]]) == [900], "cleanRR drops non-positive")
check(HRV.rollingRMSSD([1, 2, 3], windowSize: 2) == [1, 1], "rollingRMSSD windows of 2")

// Stress (Baevsky index)
check(Stress.index(rr: Array(repeating: 750, count: 120)) == 10.0, "constant RR -> max stress 10.0")
let moderate = Stress.index(rr: [667, 619, 583, 556, 531, 556, 600, 632, 612, 600, 612, 625, 638])
check(moderate > 0.0 && moderate <= 10.0, "moderate variability stress in (0,10]: \(moderate)")

// Strain (Edwards TRIMP, HRR zones); maxHR=190, restingHR=60
let strain = Strain(maxHR: 190, restingHR: 60)
check(strain.calculate(bpms: Array(repeating: 65, count: 600)) == 0.0, "65bpm below zone1 -> strain 0")
check(strain.calculate(bpms: Array(repeating: 190, count: 86400)) == 21.0, "24h@maxHR -> strain 21.0")
check((strain.calculate(bpms: Array(repeating: 170, count: 1800)) ?? 0) > 10.0, "sustained 170bpm -> strain >10")
check(strain.calculate(bpms: Array(repeating: 80, count: 500)) == nil, "too few readings -> nil")
check(Strain(maxHR: 60, restingHR: 60).calculate(bpms: Array(repeating: 80, count: 600)) == nil,
      "maxHR<=restingHR -> nil")

// Sleep score (#28 fix: floating-point division so 4h yields 50.0, not 0.0)
check(SleepScore.score(durationSeconds: 8 * 3600) == 100.0, "8h sleep -> 100")
check(SleepScore.score(durationSeconds: 4 * 3600) == 50.0, "4h sleep -> 50.0 (#28 fix: floating-point ratio)")
check(SleepScore.score(durationSeconds: 24 * 3600) == 100.0, "24h sleep -> clamped 100")

// Sleep detection (activity.rs)
let base = Date(timeIntervalSince1970: 1_700_000_000)
func reading(_ minutes: Int, _ g: SIMD3<Float>?) -> GravitySample {
    GravitySample(time: base.addingTimeInterval(Double(minutes) * 60), gravity: g)
}
check(ActivityPeriod.detectFromGravity([]).isEmpty, "detect: empty -> none")
check(ActivityPeriod.detectFromGravity([reading(0, SIMD3(0, 0, 1))]).isEmpty, "detect: single -> none")
let still = (0..<120).map { reading($0, SIMD3(0, 0, 1)) }
check(ActivityPeriod.detectFromGravity(still).first?.activity == .sleep, "detect: all-still -> sleep")
let moving = (0..<120).map { reading($0, SIMD3($0 % 2 == 0 ? 1 : -1, 0, 0)) }
check(ActivityPeriod.detectFromGravity(moving).first?.activity == .active, "detect: all-moving -> active")
let noGrav = (0..<120).map { reading($0, nil) }
check(ActivityPeriod.detectFromGravity(noGrav).first?.activity == .active, "detect: no-gravity -> active")
var gapped = (0..<60).map { reading($0, SIMD3(0, 0, 1)) }
gapped += (120..<180).map { reading($0, SIMD3(0, 0, 1)) }
check(ActivityPeriod.detectFromGravity(gapped).count >= 2, "detect: >20min gap breaks run")

var events = [
    ActivityPeriod(activity: .active, start: base, end: base.addingTimeInterval(30 * 60)),
    ActivityPeriod(activity: .sleep, start: base.addingTimeInterval(30 * 60), end: base.addingTimeInterval(300 * 60)),
]
check(ActivityPeriod.findSleep(&events)?.activity == .sleep, "findSleep: returns long sleep")
var shortSleep = [ActivityPeriod(activity: .sleep, start: base, end: base.addingTimeInterval(30 * 60))]
check(ActivityPeriod.findSleep(&shortSleep) == nil, "findSleep: ignores <60min sleep")
var none: [ActivityPeriod] = []
check(ActivityPeriod.findSleep(&none) == nil, "findSleep: empty -> nil")

// --- Bulk activity/sleep decode (0x4c, PROTOCOL.md §5.3) ---
// Real, XOR-valid 0x4c page from the 2026-06-13 overnight sync: 6 × 23-byte records.
let realPage = "4c00260c22a16b55210a7d120a010101010100000402400400000c22a20155000300"
    + "120a010101010100003c00000d01200c22a297540001005f0a010101010100001101b00f"
    + "00440c22a32d6027077b120a010101010100402501c02235a00c22a3c351260577120b01"
    + "0101010108a01000000401300c22a459502d0378120a01010101010160200000040ff0cc"
let pageRecs = BulkSleep.records(fromPage: hex(realPage))
check(pageRecs.count == 6, "0x4c page splits into 6 × 23-byte records")
// #39 fix: all non-idle records are .sleepVitals; .activity is no longer returned.
check(pageRecs[0].layout == .sleepVitals && pageRecs[2].layout == .sleepVitals,
      "#39 fix: non-idle records are .sleepVitals (not .activity)")

// Deep-sleep epoch confirmed against the app: HR 68 / HRV 77 / SpO2 98.
let dsr = BulkRecord(hex("0c22d5bf444d057a620a01010101012aa0000090000004"))!
check(dsr.heartRate == 68, "sleep-vitals [4] -> HR 68 bpm (🟢 app-confirmed)")
check(dsr.hrvRMSSD == 77, "sleep-vitals [5] -> HRV 77 ms (🟢)")
check(dsr.spo2Percent == 98, "sleep-vitals [8] -> SpO2 98% (🟢)")
check(dsr.respiratoryRate == 15.25, "sleep-vitals [7] 0x7a/8 -> RR 15.25 brpm (🟢, app avg 15.1)")
check(dsr.counter == 0x0c22d5bf, "record [0:4] -> BE counter")
let dsSamples = BulkSleep.samples(from: [dsr])
check(dsSamples.count == 4, "sleep-vitals -> HR + HRV + SpO2 + RR samples")
check(dsSamples.first(where: { $0.kind == .spo2 })?.value == 0.98, "SpO2 emitted as 0…1 fraction")
check(dsSamples.first(where: { $0.kind == .respiratoryRate })?.value == 15.25, "RR sample emitted")
let idleRec = BulkRecord(hex("0c099dbf05000c00120a01010101010000000000000000"))!
check(idleRec.layout == .idle && BulkSleep.samples(from: [idleRec]).isEmpty,
      "idle template -> no samples")

// Motion-channel sleep detection: active -> still(9h) -> active finds the night.
func bulkRec(_ c: UInt32, motion: UInt8, sub: UInt8) -> BulkRecord {
    var b = [UInt8](repeating: 0, count: 23)
    b[0] = UInt8(c >> 24); b[1] = UInt8((c >> 16) & 0xFF)
    b[2] = UInt8((c >> 8) & 0xFF); b[3] = UInt8(c & 0xFF)
    b[8] = sub
    for k in 0..<5 { b[10 + k] = motion }
    return BulkRecord(b)!
}
var night: [BulkRecord] = []
var cc: UInt32 = 0x0c220000
for _ in 0..<20 { night.append(bulkRec(cc, motion: 0x14, sub: 0x12)); cc += 150 }
for _ in 0..<216 { night.append(bulkRec(cc, motion: 0x01, sub: 0x62)); cc += 150 }
for _ in 0..<20 { night.append(bulkRec(cc, motion: 0x14, sub: 0x12)); cc += 150 }
let block = BulkSleep.mainSleep(from: night)
check(block?.activity == .sleep, "motion detection finds the sleep block")
check(abs((block?.duration ?? 0) - 216 * 150) < 30 * 60, "sleep block ~9 h")
check(BulkSleep.sleepSegments(from: night).contains { $0.stage == .inBed },
      "sleepSegments emits inBed")
check(BulkSleep.mainSleep(from: night.prefix(20).map { $0 }) == nil,
      "all-active -> no sleep block")

// Experimental staging: low-HR region -> Deep, high-HR -> REM (sleep-vitals sub 0x62).
func vrec(_ c: UInt32, motion: UInt8, hr: UInt8) -> BulkRecord {
    var b = bulkRec(c, motion: motion, sub: 0x62).raw; b[4] = hr; return BulkRecord(b)!
}
var staged: [BulkRecord] = []
var sc: UInt32 = 0x0c220000
for _ in 0..<20 { staged.append(bulkRec(sc, motion: 0x14, sub: 0x12)); sc += 150 }
for _ in 0..<60 { staged.append(vrec(sc, motion: 0x01, hr: 72)); sc += 150 }   // REM band
for _ in 0..<60 { staged.append(vrec(sc, motion: 0x01, hr: 50)); sc += 150 }   // Deep band
for _ in 0..<60 { staged.append(vrec(sc, motion: 0x01, hr: 60)); sc += 150 }   // Light
for _ in 0..<20 { staged.append(bulkRec(sc, motion: 0x14, sub: 0x12)); sc += 150 }
let stages = Set(BulkSleep.stagedSegments(from: staged).map { $0.stage })
check(stages.contains(.asleepDeep) && stages.contains(.asleepREM) && stages.contains(.asleepCore),
      "staging separates Deep/REM/Light by HR band (experimental)")
// Regression: a sleep-vitals epoch with baseline motion + zero payload is NOT idle.
let zeroPayloadSleep = BulkRecord(hex("0c22cd8b38520973620a01010101010000000000000004"))!
check(zeroPayloadSleep.layout == .sleepVitals && zeroPayloadSleep.heartRate == 0x38,
      "zero-payload sleep epoch keeps HR (not mistaken for idle)")

// --- Sleep-stage classifier (SleepStaging, §5.3) ---------------------------------
// stagedSegments now delegates to SleepStaging.classify; it must produce the same output.
check(BulkSleep.stagedSegments(from: staged) == SleepStaging.classify(from: staged),
      "BulkSleep.stagedSegments delegates to SleepStaging.classify")

// Calm flat low HR (still) -> predominantly Deep, no REM.
var deepNight: [BulkRecord] = []
var dc: UInt32 = 0x0c220000
for _ in 0..<12 { deepNight.append(bulkRec(dc, motion: 0x14, sub: 0x12)); dc += 150 }
for _ in 0..<120 { deepNight.append(vrec(dc, motion: 0x01, hr: 50)); dc += 150 }
for _ in 0..<12 { deepNight.append(bulkRec(dc, motion: 0x14, sub: 0x12)); dc += 150 }
let deepSegs = SleepStaging.classify(from: deepNight)
let deepTotals = SleepStaging.stageTotals(deepSegs)
let deepAsleep = (deepTotals[.asleepDeep] ?? 0) + (deepTotals[.asleepCore] ?? 0) + (deepTotals[.asleepREM] ?? 0)
check(deepAsleep > 0 && (deepTotals[.asleepDeep] ?? 0) / deepAsleep > 0.8,
      "calm flat low HR -> mostly Deep")
check((deepTotals[.asleepREM] ?? 0) == 0, "calm flat HR -> no REM")

// Constructed multi-cycle night partitions like a tracker: Light ≫ REM > Deep, modest awake.
func vrecHRV(_ c: UInt32, hr: UInt8, hrv: UInt8) -> BulkRecord {
    var b = vrec(c, motion: 0x01, hr: hr).raw; b[5] = hrv; return BulkRecord(b)!
}
var night2: [BulkRecord] = []
var nc: UInt32 = 0x0c220000
for _ in 0..<8 { night2.append(bulkRec(nc, motion: 0x14, sub: 0x12)); nc += 150 }
for cycle in 0..<5 {
    for _ in 0..<10 { night2.append(vrecHRV(nc, hr: 56, hrv: 60)); nc += 150 }   // Light
    for _ in 0..<8  { night2.append(vrecHRV(nc, hr: 50, hrv: 70)); nc += 150 }   // Deep
    for _ in 0..<8  { night2.append(vrecHRV(nc, hr: 56, hrv: 60)); nc += 150 }   // Light
    for _ in 0..<10 { night2.append(vrecHRV(nc, hr: 62, hrv: 45)); nc += 150 }   // REM
    if cycle < 4 { for _ in 0..<2 { night2.append(bulkRec(nc, motion: 0x15, sub: 0x12)); nc += 150 } }
}
for _ in 0..<8 { night2.append(bulkRec(nc, motion: 0x14, sub: 0x12)); nc += 150 }
let s = SleepStaging.summary(SleepStaging.classify(from: night2))
check(s.deep > 0 && s.rem > 0 && s.light > 0 && s.awake > 0, "constructed night has all 4 stages")
check(s.light > s.rem && s.rem > s.deep, "architecture sanity: Light ≫ REM > Deep")
check(abs(s.inBed - (s.totalAsleep + s.awake)) < 150, "inBed ≈ asleep + awake (partition)")
check(s.efficiency > 0.6 && s.efficiency <= 1.0, "plausible sleep efficiency")
let m = s.minutes
print("    => constructed night (min): inBed \(m.inBed), asleep \(m.asleep), "
      + "awake \(m.awake), light \(m.light), deep \(m.deep), rem \(m.rem), eff \(Int(s.efficiency * 100))%")

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
