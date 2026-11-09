// History record layouts (ZEPP_PROTOCOL.md §6.5–§6.6) decoded into plain value types.
//
// Parsers are total: any input — truncated, oversized, garbage — yields either records or a
// thrown `ZeppRecordParser.Error`, never a trap, and every read is bounds-checked through
// `ZeppByteReader`. Raw values are kept next to the interpreted ones wherever the spec marks the
// interpretation 🔴, so later captures can re-derive them without a re-fetch.

import Foundation

/// The history types `ZeppHistoryFetch` fetches and this parser decodes. Statistics (`0x2c`) and debug
/// logs (`0x07`) are out of scope for v1 (§6.5). The workout records (`0x05`/`0x06`, §22) are walked one
/// record at a time by `ZeppWorkoutWalk` (`ZeppWorkoutFetchType`, `ZeppWorkoutRecords.swift`).
public enum ZeppFetchType: UInt8, CaseIterable, Equatable {
    case activity = 0x01
    case manualHeartRate = 0x02
    case pai = 0x0d
    case manualStress = 0x12
    case autoStress = 0x13
    case spo2 = 0x25
    case sleepSpO2 = 0x26
    case temperature = 0x2e
    case sleepRespiratoryRate = 0x38
    case restingHeartRate = 0x3a
    case maxHeartRate = 0x3d
    case sleepSession = 0x48
    case hrv = 0x49

    /// Per-minute types carry no timestamps: record i is at start + i minutes (§6.4).
    public var isPerMinute: Bool {
        switch self {
        case .activity, .autoStress, .temperature: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .activity: return "activity"
        case .manualHeartRate: return "manual HR"
        case .pai: return "PAI"
        case .manualStress: return "stress (manual)"
        case .autoStress: return "stress (auto)"
        case .spo2: return "SpO2"
        case .sleepSpO2: return "sleep SpO2"
        case .temperature: return "temperature"
        case .sleepRespiratoryRate: return "sleep respiratory rate"
        case .restingHeartRate: return "resting HR"
        case .maxHeartRate: return "max HR"
        case .sleepSession: return "sleep session"
        case .hrv: return "HRV"
        }
    }

    /// Data bytes per unit of the start reply's length field (§6.2). Activity announces its 8-byte
    /// records (minutes), seen on a real strap; every other type announces bytes.
    /// SPEC-GAP: bytes is confirmed on hardware only for the types that delivered data there
    /// (§10.1). Manual HR (0x02), manual stress (0x12) and max HR (0x3d) have only ever answered
    /// "empty", so they stay bytes 🟡; if that is wrong, the length checks fail the round and the
    /// data stays on the strap.
    public var startReplyLengthUnit: Int {
        switch self {
        case .activity: return 8
        default: return 1
        }
    }

    /// Bytes per record on the wire (§6.5), after `headerLength`. The per-minute types hold one
    /// record per minute; the others hold one per reading.
    public var wireRecordLength: Int {
        switch self {
        case .activity, .temperature, .sleepRespiratoryRate: return 8
        case .autoStress: return 1
        case .manualHeartRate, .restingHeartRate, .maxHeartRate, .hrv: return 6
        case .manualStress: return 5
        case .spo2: return ZeppSpO2Reading.recordLength
        case .sleepSpO2: return ZeppSleepSpO2Reading.recordLength
        case .sleepSession: return ZeppSleepSession.recordLength
        case .pai: return ZeppPAIRecord.recordLength
        }
    }

    /// Bytes before the first record: the version byte of the SpO₂ types (§6.5).
    public var headerLength: Int {
        switch self {
        case .spo2, .sleepSpO2: return 1
        default: return 0
        }
    }

    /// Records a round of `bytes` holds, counting a trailing partial record as one (the length rule
    /// rejects it later anyway).
    public func recordCount(bytes: Int) -> Int {
        let body = max(0, bytes - headerLength)
        return (body + wireRecordLength - 1) / wireRecordLength
    }

    /// The length rule enforced before parsing (§6.5); a violation rejects the round.
    public func isValidLength(_ length: Int) -> Bool {
        switch self {
        case .activity, .temperature, .sleepRespiratoryRate: return length % 8 == 0
        case .autoStress: return true
        case .manualHeartRate, .restingHeartRate, .maxHeartRate, .hrv: return length % 6 == 0
        case .spo2: return length >= 1 && (length - 1) % ZeppSpO2Reading.recordLength == 0
        case .sleepSpO2: return length >= 1 && (length - 1) % ZeppSleepSpO2Reading.recordLength == 0
        case .sleepSession: return length % ZeppSleepSession.recordLength == 0
        case .pai: return length % ZeppPAIRecord.recordLength == 0
        case .manualStress: return length % 5 == 0
        }
    }
}

// MARK: - Record types

/// One minute of `0x01` activity (8 bytes, §6.5).
public struct ZeppActivityMinute: Equatable {
    public let time: Date
    /// Activity kind: `0x73` not worn, `0x76` charging, `0x78` sleep, `0x40` outdoor running;
    /// the full table is 🔴.
    public let kind: UInt8
    /// 0–255.
    public let intensity: UInt8
    /// Steps in this minute.
    public let steps: UInt8
    /// Raw HR byte; see `heartRate`.
    public let rawHeartRate: UInt8
    public let unknown4: UInt8
    /// Low 7 bits of bytes 5, 6, 7.
    public let sleep: UInt8
    public let deepSleep: UInt8
    public let rem: UInt8

    /// bpm, or nil for `00`/`ff` (no reading, §9 #5).
    public var heartRate: Int? { ZeppHeartRateReading.bpm(rawHeartRate) }

    public static let kindNotWorn: UInt8 = 0x73
    public static let kindCharging: UInt8 = 0x76
    public static let kindSleep: UInt8 = 0x78
    public static let kindOutdoorRunning: UInt8 = 0x40
}

/// The 6-byte `u32 ts, i8 tz, u8 bpm` layout shared by manual (`0x02`), resting (`0x3a`) and
/// max (`0x3d`) heart rate.
public struct ZeppHeartRateReading: Equatable {
    public let time: Date
    /// UTC offset in quarter-hours, for local display only.
    public let utcOffsetQuarterHours: Int8
    public let rawBeatsPerMinute: UInt8

    public var beatsPerMinute: Int? { Self.bpm(rawBeatsPerMinute) }

    static func bpm(_ raw: UInt8) -> Int? {
        raw == 0x00 || raw == 0xFF ? nil : Int(raw)
    }
}

/// `0x49` HRV (6 bytes): u32 ts, u8 unknown, u8 HRV.
public struct ZeppHRVReading: Equatable {
    public let time: Date
    /// 🔴 probably the tz byte, as in the 6-byte HR records.
    public let unknown: UInt8
    /// Milliseconds. RMSSD 🟡: Amazfit's product-line documentation, which doesn't name the strap; not
    /// compared with Zepp's display (ZEPP_PROTOCOL.md §6.5).
    public let milliseconds: UInt8
}

/// `0x12` manual stress (5 bytes): u32 ts, u8 stress.
public struct ZeppStressReading: Equatable {
    public let time: Date
    public let rawLevel: UInt8
    /// 0–100, nil otherwise.
    public var level: Int? { rawLevel <= 100 ? Int(rawLevel) : nil }
}

/// One minute of `0x13` automatic stress (1 byte, `ff` = none).
public struct ZeppStressMinute: Equatable {
    public let time: Date
    public let rawLevel: UInt8
    /// 0–100, nil for `ff` or any other out-of-range value.
    public var level: Int? { rawLevel <= 100 ? Int(rawLevel) : nil }
}

/// `0x25` SpO₂ (65-byte records after a version byte): u32 ts, u8 value, 60 unknown bytes.
public struct ZeppSpO2Reading: Equatable {
    public static let recordLength = 65
    public static let supportedVersion: UInt8 = 0x02

    public let time: Date
    /// Bit 7 of the value byte.
    public let isAutomatic: Bool
    /// Low 7 bits of the value byte.
    public let rawPercent: UInt8
    /// 1–100, nil otherwise.
    public var percent: Int? { (1...100).contains(rawPercent) ? Int(rawPercent) : nil }
}

/// `0x26` sleep SpO₂ (30-byte records after a version byte).
public struct ZeppSleepSpO2Reading: Equatable {
    public static let recordLength = 30
    public static let supportedVersion: UInt8 = 0x02

    public let time: Date
    public let rawPercent: UInt8
    public let duration: UInt8
    public let high: [UInt8]
    public let low: [UInt8]
    public let signalQuality: [UInt8]
    public let extended: [UInt8]
    public var percent: Int? { (1...100).contains(rawPercent) ? Int(rawPercent) : nil }
}

/// One minute of `0x2e` temperature (8 bytes): i16 unknown, i16 temperature (centi-°C), i16, i16.
public struct ZeppTemperatureMinute: Equatable {
    public let time: Date
    public let unknown0: Int16
    public let rawCentiCelsius: Int16
    public let unknown2: Int16
    public let unknown3: Int16

    /// °C, or nil for the `0x7fff`/`0x8000` sentinels and anything outside 20–45 °C (§9: treat as
    /// missing; whether the field has its own "no reading" value is 🔴).
    public var celsius: Double? {
        guard rawCentiCelsius != Int16.max, rawCentiCelsius != Int16.min else { return nil }
        let value = Double(rawCentiCelsius) / 100
        return (20...45).contains(value) ? value : nil
    }
}

/// `0x38` sleep respiratory rate (8 bytes): u32 ts, i8 tz, u8 rate, u8 unknown, u8 unknown.
public struct ZeppRespiratoryRateReading: Equatable {
    public let time: Date
    public let utcOffsetQuarterHours: Int8
    public let breathsPerMinute: UInt8
    public let unknown6: UInt8
    public let unknown7: UInt8
}

/// `0x0d` PAI (102 bytes). Only type-`05` records are kept.
public struct ZeppPAIRecord: Equatable {
    public static let recordLength = 102
    public static let validType: UInt8 = 0x05

    public let time: Date
    public let utcOffsetQuarterHours: Int8
    public let lowZonePAI: Float
    public let moderateZonePAI: Float
    public let highZonePAI: Float
    public let lowZoneMinutes: UInt16
    public let moderateZoneMinutes: UInt16
    public let highZoneMinutes: UInt16
    public let todayPAI: Float
    public let totalPAI: Float
}

/// `0x48` sleep session (594 bytes, §6.6).
public struct ZeppSleepSession: Equatable {
    public static let recordLength = 594
    /// The stage table (5 bytes/stage from 0x056) fits at most 100 entries before 0x24A (🔴).
    public static let maxStages = 100

    public enum StageKind: Equatable {
        case light
        case deep
        case awake
        case rem
        /// Any other stage byte: generic sleep.
        case other(UInt8)

        init(raw: UInt8) {
            switch raw {
            case 0x04: self = .light
            case 0x05: self = .deep
            case 0x07: self = .awake
            case 0x08: self = .rem
            default: self = .other(raw)
            }
        }
    }

    public struct Stage: Equatable {
        public let start: Date
        /// The end minute as the record states it (`rawEndMinute`). It is INCLUSIVE (§6.6 🟡): the
        /// stage covers that minute too, so the time it covers ends at `segmentEnd`.
        public let end: Date
        public let kind: StageKind
        public let rawStartMinute: UInt16
        public let rawEndMinute: UInt16

        /// Where the stage's time ends: one minute after its inclusive end minute (§6.6 🟡, decision
        /// 70e, #312). The one place ZeppKit turns a stage end into a span end; every reader of a
        /// stage's span (`stageGaps`, `HelioSleepSelection.night(from:now:)`) uses this, never `end`.
        public var segmentEnd: Date { end.addingTimeInterval(ZeppSleepSession.stageEndMinute) }
    }

    /// The inclusive end minute's own length (§6.6 🟡, decision 70e).
    public static let stageEndMinute: TimeInterval = 60

    public let time: Date
    /// Local midnight (as Unix seconds) of the day the session belongs to.
    public let midnightReference: Date
    public let flag8: UInt8
    public let flag9: UInt8
    public let sleepStart: Date
    public let sleepEnd: Date
    public let rawSleepStartMinute: UInt16
    public let rawSleepEndMinute: UInt16
    public let averageHeartRate: UInt8
    public let score: UInt8
    public let stages: [Stage]
    public let totalREMMinutes: UInt16
    public let totalLightMinutes: UInt16
    public let totalDeepMinutes: UInt16
    public let totalAwakeMinutes: UInt16

    /// Spans between consecutive stages that no stage covers (§6.6: use stage ends, flag gaps). A
    /// stage covers its inclusive end minute (`Stage.segmentEnd`), so a next stage starting the minute
    /// after a stage's end minute leaves no gap.
    public var stageGaps: [ClosedRange<Date>] {
        var out = [ClosedRange<Date>]()
        for (previous, next) in zip(stages, stages.dropFirst()) where next.start > previous.segmentEnd {
            out.append(previous.segmentEnd...next.start)
        }
        return out
    }

    /// Minute fields count from the previous local midnight: `midnight − 86400 + minutes × 60`.
    /// SPEC-GAP: the source comments call the base "noon of the previous day" while the arithmetic
    /// uses midnight − 24 h (🔴 until a capture decides). ZeppKit follows the arithmetic.
    static func absolute(minute: UInt16, midnight: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(midnight) - 86_400 + TimeInterval(minute) * 60)
    }
}

// MARK: - Parsed round

public enum ZeppRecordBatch: Equatable {
    case activity([ZeppActivityMinute])
    case manualHeartRate([ZeppHeartRateReading])
    case pai([ZeppPAIRecord])
    case manualStress([ZeppStressReading])
    case autoStress([ZeppStressMinute])
    case spo2([ZeppSpO2Reading])
    case sleepSpO2([ZeppSleepSpO2Reading])
    case temperature([ZeppTemperatureMinute])
    case sleepRespiratoryRate([ZeppRespiratoryRateReading])
    case restingHeartRate([ZeppHeartRateReading])
    case maxHeartRate([ZeppHeartRateReading])
    case sleepSession([ZeppSleepSession])
    case hrv([ZeppHRVReading])

    public var count: Int {
        switch self {
        case .activity(let r): return r.count
        case .manualHeartRate(let r), .restingHeartRate(let r), .maxHeartRate(let r): return r.count
        case .pai(let r): return r.count
        case .manualStress(let r): return r.count
        case .autoStress(let r): return r.count
        case .spo2(let r): return r.count
        case .sleepSpO2(let r): return r.count
        case .temperature(let r): return r.count
        case .sleepRespiratoryRate(let r): return r.count
        case .sleepSession(let r): return r.count
        case .hrv(let r): return r.count
        }
    }
}

public struct ZeppParsedRecords: Equatable {
    public let type: ZeppFetchType
    public let records: ZeppRecordBatch
    /// Records present on the wire but not kept (PAI type ≠ 05, a sleep session with no or too
    /// many stages).
    public let skippedRecords: Int
    /// Time of the last record on the wire, kept or skipped; for per-minute types, the last minute.
    /// The next round's *since* is this + 1 minute (§6.4). nil when the round held no records.
    public let lastRecordTime: Date?
}

public enum ZeppRecordParser {

    public enum Error: Swift.Error, Equatable {
        /// The data length breaks the type's length rule (§6.5).
        case lengthViolation(type: ZeppFetchType, length: Int)
        /// A versioned type (SpO₂) carried a version other than `02`.
        case unsupportedVersion(type: ZeppFetchType, version: UInt8)
    }

    /// Decodes one round's concatenated data. `start` is the start reply's first-record time; the
    /// per-minute types are laid out from it.
    public static func parse(_ type: ZeppFetchType, data: [UInt8], start: Date) throws -> ZeppParsedRecords {
        guard type.isValidLength(data.count) else {
            throw Error.lengthViolation(type: type, length: data.count)
        }
        var skipped = 0
        var times = [Date]()
        let batch: ZeppRecordBatch
        switch type {
        case .activity:
            let minutes = records(data, size: 8).enumerated().map { i, r -> ZeppActivityMinute in
                ZeppActivityMinute(time: minute(start, i), kind: r[0], intensity: r[1], steps: r[2],
                                   rawHeartRate: r[3], unknown4: r[4], sleep: r[5] & 0x7F,
                                   deepSleep: r[6] & 0x7F, rem: r[7] & 0x7F)
            }
            times = minutes.map(\.time)
            batch = .activity(minutes)
        case .autoStress:
            let minutes = data.enumerated().map { i, b in ZeppStressMinute(time: minute(start, i), rawLevel: b) }
            times = minutes.map(\.time)
            batch = .autoStress(minutes)
        case .temperature:
            let minutes = records(data, size: 8).enumerated().map { i, r -> ZeppTemperatureMinute in
                var reader = ZeppByteReader(r)
                return ZeppTemperatureMinute(time: minute(start, i), unknown0: reader.i16() ?? 0,
                                             rawCentiCelsius: reader.i16() ?? 0,
                                             unknown2: reader.i16() ?? 0, unknown3: reader.i16() ?? 0)
            }
            times = minutes.map(\.time)
            batch = .temperature(minutes)
        case .manualHeartRate, .restingHeartRate, .maxHeartRate:
            let readings = records(data, size: 6).map { r -> ZeppHeartRateReading in
                var reader = ZeppByteReader(r)
                return ZeppHeartRateReading(time: unix(reader.u32()), utcOffsetQuarterHours: reader.i8() ?? 0,
                                            rawBeatsPerMinute: reader.u8() ?? 0)
            }
            times = readings.map(\.time)
            switch type {
            case .manualHeartRate: batch = .manualHeartRate(readings)
            case .restingHeartRate: batch = .restingHeartRate(readings)
            default: batch = .maxHeartRate(readings)
            }
        case .hrv:
            let readings = records(data, size: 6).map { r -> ZeppHRVReading in
                var reader = ZeppByteReader(r)
                return ZeppHRVReading(time: unix(reader.u32()), unknown: reader.u8() ?? 0,
                                      milliseconds: reader.u8() ?? 0)
            }
            times = readings.map(\.time)
            batch = .hrv(readings)
        case .manualStress:
            let readings = records(data, size: 5).map { r -> ZeppStressReading in
                var reader = ZeppByteReader(r)
                return ZeppStressReading(time: unix(reader.u32()), rawLevel: reader.u8() ?? 0)
            }
            times = readings.map(\.time)
            batch = .manualStress(readings)
        case .sleepRespiratoryRate:
            let readings = records(data, size: 8).map { r -> ZeppRespiratoryRateReading in
                var reader = ZeppByteReader(r)
                return ZeppRespiratoryRateReading(time: unix(reader.u32()), utcOffsetQuarterHours: reader.i8() ?? 0,
                                                  breathsPerMinute: reader.u8() ?? 0,
                                                  unknown6: reader.u8() ?? 0, unknown7: reader.u8() ?? 0)
            }
            times = readings.map(\.time)
            batch = .sleepRespiratoryRate(readings)
        case .spo2:
            guard data[0] == ZeppSpO2Reading.supportedVersion else {
                throw Error.unsupportedVersion(type: type, version: data[0])
            }
            let readings = records(Array(data.dropFirst()), size: ZeppSpO2Reading.recordLength).map { r -> ZeppSpO2Reading in
                var reader = ZeppByteReader(r)
                let time = unix(reader.u32())
                let value = reader.u8() ?? 0
                return ZeppSpO2Reading(time: time, isAutomatic: value & 0x80 != 0, rawPercent: value & 0x7F)
            }
            times = readings.map(\.time)
            batch = .spo2(readings)
        case .sleepSpO2:
            guard data[0] == ZeppSleepSpO2Reading.supportedVersion else {
                throw Error.unsupportedVersion(type: type, version: data[0])
            }
            let readings = records(Array(data.dropFirst()), size: ZeppSleepSpO2Reading.recordLength).map { r -> ZeppSleepSpO2Reading in
                var reader = ZeppByteReader(r)
                return ZeppSleepSpO2Reading(time: unix(reader.u32()), rawPercent: reader.u8() ?? 0,
                                            duration: reader.u8() ?? 0, high: reader.take(6) ?? [],
                                            low: reader.take(6) ?? [], signalQuality: reader.take(8) ?? [],
                                            extended: reader.take(4) ?? [])
            }
            times = readings.map(\.time)
            batch = .sleepSpO2(readings)
        case .pai:
            var kept = [ZeppPAIRecord]()
            for r in records(data, size: ZeppPAIRecord.recordLength) {
                var reader = ZeppByteReader(r)
                let kind = reader.u8() ?? 0
                let time = unix(reader.u32())
                times.append(time)
                // SPEC-GAP: only `05` (valid) and `00` (pre-reset, skip) are described; every
                // other type byte is skipped too.
                guard kind == ZeppPAIRecord.validType else {
                    skipped += 1
                    continue
                }
                let offset = reader.i8() ?? 0
                _ = reader.skip(31)
                let low = reader.f32() ?? 0
                let moderate = reader.f32() ?? 0
                let high = reader.f32() ?? 0
                let minutesLow = reader.u16() ?? 0
                let minutesModerate = reader.u16() ?? 0
                let minutesHigh = reader.u16() ?? 0
                let today = reader.f32() ?? 0
                let total = reader.f32() ?? 0
                kept.append(ZeppPAIRecord(time: time, utcOffsetQuarterHours: offset, lowZonePAI: low,
                                          moderateZonePAI: moderate, highZonePAI: high,
                                          lowZoneMinutes: minutesLow, moderateZoneMinutes: minutesModerate,
                                          highZoneMinutes: minutesHigh, todayPAI: today, totalPAI: total))
            }
            batch = .pai(kept)
        case .sleepSession:
            var kept = [ZeppSleepSession]()
            for r in records(data, size: ZeppSleepSession.recordLength) {
                var reader = ZeppByteReader(r)
                times.append(unix(reader.u32()))
                if let session = sleepSession(r) {
                    kept.append(session)
                } else {
                    skipped += 1
                }
            }
            batch = .sleepSession(kept)
        }
        return ZeppParsedRecords(type: type, records: batch, skippedRecords: skipped, lastRecordTime: times.last)
    }

    /// nil for a record with no staging (n = 0: skip, §6.6) or a stage count that would overrun
    /// the totals at 0x24A.
    /// SPEC-GAP: the 100-stage cap is a 🔴 inference from the layout; a larger count is treated as a
    /// malformed record and skipped rather than read into the totals.
    static func sleepSession(_ r: [UInt8]) -> ZeppSleepSession? {
        guard r.count == ZeppSleepSession.recordLength else { return nil }
        func u8(_ offset: Int) -> UInt8 { r[offset] }
        func u16(_ offset: Int) -> UInt16 { UInt16(r[offset]) | UInt16(r[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            var reader = ZeppByteReader(r, offset: offset)
            return reader.u32() ?? 0
        }
        let stageCount = Int(u8(0x054))
        guard stageCount > 0, stageCount <= ZeppSleepSession.maxStages else { return nil }
        let midnight = u32(0x004)
        var stages = [ZeppSleepSession.Stage]()
        for i in 0..<stageCount {
            let base = 0x056 + 5 * i
            let startMinute = u16(base)
            let endMinute = u16(base + 2)
            stages.append(ZeppSleepSession.Stage(
                start: ZeppSleepSession.absolute(minute: startMinute, midnight: midnight),
                end: ZeppSleepSession.absolute(minute: endMinute, midnight: midnight),
                kind: ZeppSleepSession.StageKind(raw: u8(base + 4)),
                rawStartMinute: startMinute, rawEndMinute: endMinute))
        }
        let startMinute = u16(0x00A)
        let endMinute = u16(0x00C)
        return ZeppSleepSession(
            time: Date(timeIntervalSince1970: TimeInterval(u32(0x000))),
            midnightReference: Date(timeIntervalSince1970: TimeInterval(midnight)),
            flag8: u8(0x008), flag9: u8(0x009),
            sleepStart: ZeppSleepSession.absolute(minute: startMinute, midnight: midnight),
            sleepEnd: ZeppSleepSession.absolute(minute: endMinute, midnight: midnight),
            rawSleepStartMinute: startMinute, rawSleepEndMinute: endMinute,
            averageHeartRate: u8(0x015), score: u8(0x016), stages: stages,
            totalREMMinutes: u16(0x24A), totalLightMinutes: u16(0x24C),
            totalDeepMinutes: u16(0x24E), totalAwakeMinutes: u16(0x250))
    }

    /// Whole `size`-byte records; the length rule has already been checked, so nothing is dropped.
    private static func records(_ data: [UInt8], size: Int) -> [[UInt8]] {
        stride(from: 0, to: data.count - data.count % size, by: size).map { Array(data[$0..<($0 + size)]) }
    }

    private static func minute(_ start: Date, _ index: Int) -> Date {
        start.addingTimeInterval(TimeInterval(index) * 60)
    }

    private static func unix(_ seconds: UInt32?) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds ?? 0))
    }
}
