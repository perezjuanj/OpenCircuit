// Bulk activity/sleep decode — the `0x4c` history stream (docs/PROTOCOL.md §5.3).
//
// Confirmed on FW FR02.018 by aligning captures/sleep_sync_btsnoop.log
// (2026-06-13 overnight sync) to the RingConn app's own readout for that night
// (avg HR 68 / HRV 65 ms / SpO2 98 %, low 93 % ~02:30–03:00). The decisive anchor:
// the decoded SpO2 low-cluster lands at 02:32–03:07, matching the app exactly.
//
// A 0x4c page is `[0x4c][0x00][countdown][N × 23-byte record][xor]`. The counter
// is seconds since `Command.syncEpoch`; records step +0x96 = 150 s, so each record
// is one 2.5-min epoch. Records align to page boundaries (each page body is a whole
// number of records — they do not span pages).
//
// Two record layouts, keyed on byte [8]:
//   • Sleep-vitals epoch ([8] in 0x57…0x63): [4]=HR bpm 🟢, [5]=HRV/RMSSD ms 🟢,
//     [8]=SpO2 % 🟢, [10:15]=motion. [6]/[7] unresolved 🟡.
//   • Activity/awake epoch ([8]=0x12/0x13): activity payload in [15:22] 🟡.
// Respiratory rate + skin temp are NOT per-epoch (derived/summary). Sleep stages are
// not on the wire — compute them in Swift (Analytics/SleepDetection), per Phase 5.
//
// Do not add behavior that isn't in PROTOCOL.md. New facts go into the spec (and
// desktop/decode_bulk.py) first, then get ported here.

import Foundation

/// One 23-byte record from a `0x4c` bulk activity/sleep page (PROTOCOL.md §5.3).
public struct BulkRecord: Equatable {
    /// Bytes per record (🟢).
    public static let length = 23
    /// Counter step between consecutive records: 0x96 = 150 s (🟢).
    public static let epochSeconds = 150

    /// The raw 23 bytes.
    public let raw: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.length else { return nil }
        self.raw = bytes
    }

    /// `[0:4]` big-endian counter — seconds since `Command.syncEpoch`.
    public var counter: UInt32 {
        (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
    }

    /// Wall-clock time of this epoch (counter + epoch offset).
    public func date(epoch: Int = Command.syncEpoch) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int(counter) + epoch))
    }

    public enum Layout: Equatable {
        case idle          // unworn / no measurement: motion 01×5 and zero payload
        case sleepVitals   // [8] is an SpO2 %; HR/HRV/SpO2 live in [4:9]
        case activity      // awake/active epoch; payload in [15:22]
    }

    public var layout: Layout {
        // A sleep-vitals epoch carries SpO2 in [8] even when motion is at baseline and
        // the [15:22] payload is zero (common in deep sleep) — so check [8] FIRST, else
        // those real epochs would be mistaken for the idle/unworn template and their
        // HR/SpO2 dropped.
        if (0x57...0x63).contains(raw[8]) { return .sleepVitals }
        if raw[10..<15] == [1, 1, 1, 1, 1] && raw[15..<22] == [0, 0, 0, 0, 0, 0, 0] {
            return .idle
        }
        return .activity
    }

    /// Heart rate in bpm — `[4]` on a sleep-vitals epoch (🟢). nil otherwise / when 0.
    public var heartRate: Int? {
        guard layout == .sleepVitals, raw[4] > 0 else { return nil }
        return Int(raw[4])
    }

    /// HRV in ms — `[5]` on a sleep-vitals epoch (🟢). The ring reports RMSSD; HealthKit
    /// only has SDNN (different statistic, same unit) — see HEALTHKIT_MAPPING.md.
    public var hrvRMSSD: Int? {
        guard layout == .sleepVitals, raw[5] > 0 else { return nil }
        return Int(raw[5])
    }

    /// SpO2 percent — `[8]` on a sleep-vitals epoch (🟢, range 87…99 observed). nil otherwise.
    public var spo2Percent: Int? {
        guard layout == .sleepVitals else { return nil }
        return Int(raw[8])
    }

    /// Respiratory rate in breaths/min — `[7]` on a sleep-vitals epoch, scaled ÷8 (🟢,
    /// ground-truthed 2026-06-15): per-epoch `[7]/8` matches the RingConn app's nightly
    /// average 15.1 and its low/high 14.5–16.1 at the p5–p95 of the asleep epochs. (The
    /// raw field is RR×8; exact divisor ≈8.07, but 8 is the natural 1/8-brpm fixed point.)
    public var respiratoryRate: Double? {
        guard layout == .sleepVitals, raw[7] > 0 else { return nil }
        return Double(raw[7]) / 8.0
    }

    /// `[10:15]` — 5 per-30 s motion/activity counts (🟢 role). `01` baseline = still.
    public var motion: [UInt8] { Array(raw[10..<15]) }
}

/// Reassembles `0x4c` pages into records and maps sleep-vitals epochs to samples.
public enum BulkSleep {

    /// Records carried by ONE 0x4c page frame (full notification incl. opcode + XOR).
    /// Returns [] if the XOR trailer is invalid or the opcode isn't 0x4c.
    public static func records(fromPage frame: [UInt8]) -> [BulkRecord] {
        guard let p = Frame.parse(frame), p.opcode == Frame.responseID(Opcode.page4C) else { return [] }
        // body = [00][countdown][records…]; records begin at body index 2.
        return records(fromStream: Array(p.body.dropFirst(2)))
    }

    /// Split a raw record stream (no page header/trailer) into whole 23-byte records.
    /// A trailing partial chunk is dropped.
    public static func records(fromStream bytes: [UInt8]) -> [BulkRecord] {
        guard bytes.count >= BulkRecord.length else { return [] }
        return stride(from: 0, through: bytes.count - BulkRecord.length, by: BulkRecord.length)
            .compactMap { BulkRecord(Array(bytes[$0 ..< $0 + BulkRecord.length])) }
    }

    /// Reassemble a multi-page bulk transfer into one ordered record list.
    public static func records(fromPages frames: [[UInt8]]) -> [BulkRecord] {
        frames.flatMap { records(fromPage: $0) }
    }

    /// Expand 0x4c records into a per-30 s motion timeline (5 sub-samples per
    /// 150 s epoch from the [10:15] channel) for `SleepDetection.detectFromMotion`.
    /// Motion counts are passed through directly (baseline `01` = still); callers
    /// should scope `records` to a worn period (charging data reads as still too).
    public static func motionTimeline(from records: [BulkRecord],
                                      epoch: Int = Command.syncEpoch) -> [MotionSample] {
        var out: [MotionSample] = []
        out.reserveCapacity(records.count * 5)
        for r in records {
            let base = r.date(epoch: epoch)
            for k in 0 ..< 5 {
                out.append(MotionSample(time: base.addingTimeInterval(Double(k) * 30),
                                        movement: Float(r.raw[10 + k])))
            }
        }
        return out
    }

    /// Restrict `records` to those whose epoch falls within `hint`, or return them
    /// unchanged when no hint is given. Extension point for the sleep-schedule abstraction:
    /// the app can pass the user's bedtime→wake window (see ios/OpenRingConn/SleepSchedule)
    /// so detection ignores stray daytime/charging motion outside the expected night.
    public static func records(_ records: [BulkRecord],
                               within hint: DateInterval?,
                               epoch: Int = Command.syncEpoch) -> [BulkRecord] {
        guard let hint else { return records }
        return records.filter { hint.contains($0.date(epoch: epoch)) }
    }

    /// The main sleep block (in-bed window) detected from the motion channel, or nil.
    /// Pass `within:` to bound detection to the user's scheduled sleep window (optional).
    public static func mainSleep(from records: [BulkRecord],
                                 within hint: DateInterval? = nil,
                                 epoch: Int = Command.syncEpoch) -> ActivityPeriod? {
        let scoped = Self.records(records, within: hint, epoch: epoch)
        var periods = ActivityPeriod.detectFromMotion(motionTimeline(from: scoped, epoch: epoch))
        return ActivityPeriod.findSleep(&periods)
    }

    /// HealthKit sleep segments for the detected night: an `inBed` span plus
    /// `asleepCore`/`awake` sub-segments from the stillness detection. Finer
    /// Light/Deep/REM staging needs an HR-based model (TODO) — the ring doesn't
    /// send a hypnogram (PROTOCOL.md §5.3), so all "asleep" is reported as core.
    public static func sleepSegments(from records: [BulkRecord],
                                     within hint: DateInterval? = nil,
                                     epoch: Int = Command.syncEpoch) -> [SleepSegment] {
        let scoped = Self.records(records, within: hint, epoch: epoch)
        let periods = ActivityPeriod.detectFromMotion(motionTimeline(from: scoped, epoch: epoch))
        // Main in-bed block = longest sleep period over the minimum duration (1 h).
        guard let block = periods
            .filter({ $0.activity == .sleep })
            .max(by: { $0.duration < $1.duration }),
            block.duration > 60 * 60 else { return [] }

        var segs = [SleepSegment(start: block.start, end: block.end, stage: .inBed)]
        for p in periods where p.start < block.end && p.end > block.start {
            let s = max(p.start, block.start), e = min(p.end, block.end)
            if e <= s { continue }
            segs.append(SleepSegment(start: s, end: e,
                                     stage: p.activity == .sleep ? .asleepCore : .awake))
        }
        return segs
    }

    // MARK: - Light/Deep/REM staging
    //
    // ⚠️ APPROXIMATION, NOT VALIDATED PER-EPOCH. The ring sends no hypnogram (§5.3), so
    // stages are estimated from the per-epoch HR/HRV/motion signals. The model now lives
    // in `SleepStaging` (Analytics/SleepStaging.swift): HR bands are drawn from the
    // night's OWN asleep HR distribution, and REM is separated from Light by HR/HRV
    // variability (not just absolute HR). Validated only against the app's night TOTALS,
    // never per-segment timing — treat output as approximate stage proportions.
    // `sleepSegments` (coarse asleep/awake) remains the non-experimental default.

    /// Light/Deep/REM/Awake staging of the detected sleep block. Thin wrapper over
    /// `SleepStaging.classify` (kept for source compatibility with existing callers).
    public static func stagedSegments(from records: [BulkRecord],
                                      within hint: DateInterval? = nil,
                                      epoch: Int = Command.syncEpoch) -> [SleepSegment] {
        SleepStaging.classify(from: Self.records(records, within: hint, epoch: epoch), epoch: epoch)
    }

    /// HR / HRV / SpO2 samples from sleep-vitals epochs, with device timestamps.
    /// SpO2 is emitted as a 0…1 fraction (HealthKit oxygenSaturation). HRV is the
    /// ring's RMSSD value written to the SDNN type (unit-compatible; see mapping).
    public static func samples(from records: [BulkRecord],
                               epoch: Int = Command.syncEpoch) -> [QuantitySample] {
        var out: [QuantitySample] = []
        for r in records where r.layout == .sleepVitals {
            let t = r.date(epoch: epoch)
            if let hr = r.heartRate {
                out.append(QuantitySample(kind: .heartRate, start: t, value: Double(hr)))
            }
            if let hrv = r.hrvRMSSD {
                out.append(QuantitySample(kind: .hrvSDNN, start: t, value: Double(hrv)))
            }
            if let spo2 = r.spo2Percent {
                out.append(QuantitySample(kind: .spo2, start: t, value: Double(spo2) / 100.0))
            }
            if let rr = r.respiratoryRate {
                out.append(QuantitySample(kind: .respiratoryRate, start: t, value: rr))
            }
        }
        return out
    }
}
