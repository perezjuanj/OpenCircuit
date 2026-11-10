// The strap's own workout records (ZEPP_PROTOCOL.md §22, #226): the `0x05` summary (a protocol-buffers
// message, §22.2) and the `0x06` detail (a TLV heart-rate track, §22.3), decoded into plain values.
//
// Both parsers are total, like `ZeppRecordParser`: any input (truncated, oversized, garbage) yields a
// value or a thrown `ZeppWorkoutRecordError`, never a trap. They take ONE record, as one round of the
// walk delivers it (§22.1); the walk itself is `ZeppWorkoutWalk`.

import Foundation

/// The two fetch types of a workout record (§22.1). Not cases of `ZeppFetchType`: those rounds are
/// keyed by a cursor of their own and walked one record at a time, so `ZeppWorkoutWalk` fetches them,
/// never `ZeppHistoryFetch`.
public enum ZeppWorkoutFetchType: UInt8, CaseIterable, Equatable, Sendable {
    case summary = 0x05
    case detail = 0x06

    public var displayName: String {
        switch self {
        case .summary: return "workout summary"
        case .detail: return "workout detail"
        }
    }

    /// The largest round accepted, in bytes. The real summaries are a few hundred bytes. A detail
    /// is about 5.4 bytes a second (a 5-byte sample each second, a 14-byte block header every ~33 s,
    /// §22.3), so 2 MiB is about four days of track.
    public var maxRoundBytes: Int {
        switch self {
        case .summary: return 64 << 10
        case .detail: return 2 << 20
        }
    }
}

public enum ZeppWorkoutRecordError: Error, Equatable, Sendable {
    case empty
    case oversized(length: Int, limit: Int)
    /// The summary did not start with the two bytes `00 80` (§22.2).
    case badHeader
    /// A field, a varint or a TLV entry runs past the end of the record (§22.3: the record is truncated).
    case truncated
    /// A varint longer than 10 bytes, or one that doesn't fit 64 bits.
    case malformedVarint
    /// Field number 0, or a wire type protocol buffers doesn't define for this reader (3, 4, 6, 7).
    case malformedField
    /// A summary without a start (`2.1`) or a duration (`7.1`).
    case missingField(String)
    /// A value outside what a workout can be: a start before 2015 or after 2100, a duration of zero or
    /// over two days, a block header of the wrong length, a heart-rate sample before any block header.
    case outOfRange(String)
}

// MARK: - Summary (§22.2)

public struct ZeppWorkoutSummary: Equatable, Sendable {
    /// `2.1`, Unix seconds.
    public let start: Date
    /// `7.1`, seconds. The record has no end field: end = start + duration.
    public let durationSeconds: Int
    /// `16.1`, active energy in kcal. nil when absent.
    public let kilocalories: Int?
    /// `19.1` / `19.2` / `19.3`, bpm. nil when absent or zero.
    public let averageHeartRate: Int?
    public let maximumHeartRate: Int?
    public let minimumHeartRate: Int?
    /// `3.1`: the §18.2 sport code space; `df` is the strap's generic auto-detected activity.
    public let sportCode: UInt64?
    /// `2.13`, kept raw: `257` on every auto-detected record seen, `1` on phone-started ones (🟡).
    public let raw2_13: UInt64?

    public init(start: Date, durationSeconds: Int, kilocalories: Int?, averageHeartRate: Int?,
                maximumHeartRate: Int?, minimumHeartRate: Int?, sportCode: UInt64?, raw2_13: UInt64?) {
        self.start = start
        self.durationSeconds = durationSeconds
        self.kilocalories = kilocalories
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.minimumHeartRate = minimumHeartRate
        self.sportCode = sportCode
        self.raw2_13 = raw2_13
    }

    public var end: Date { start.addingTimeInterval(TimeInterval(durationSeconds)) }
    public var window: DateInterval { DateInterval(start: start, end: end) }

    /// The strap's generic auto-detected activity (§22.2 `3.1` = `df`, 🟡).
    public static let autoDetectedSportCode: UInt64 = 0xdf

    /// The two bytes before the message (🔴 meaning; the same in all 33 records seen).
    public static let header: [UInt8] = [0x00, 0x80]

    /// Starts outside this range are not a workout's (a strap clock never set, or garbage).
    public static let plausibleStarts = Date(timeIntervalSince1970: 1_420_070_400)..<Date(timeIntervalSince1970: 4_102_444_800)
    /// A workout longer than this is not one (the strap's longest record seen was under 2 h).
    public static let maxDurationSeconds = 2 * 86_400

    public static func parse(_ data: [UInt8]) throws -> ZeppWorkoutSummary {
        guard !data.isEmpty else { throw ZeppWorkoutRecordError.empty }
        let limit = ZeppWorkoutFetchType.summary.maxRoundBytes
        guard data.count <= limit else { throw ZeppWorkoutRecordError.oversized(length: data.count, limit: limit) }
        // SPEC-GAP: the header's meaning is 🔴; it was `00 80` on every record seen, so anything else is
        // treated as not a summary (the round fails and is retried, never stored).
        guard data.count >= 2, Array(data[0..<2]) == header else { throw ZeppWorkoutRecordError.badHeader }

        var start: UInt64?, raw2_13: UInt64?, sport: UInt64?, duration: UInt64?, kcal: UInt64?
        var average: UInt64?, maximum: UInt64?, minimum: UInt64?
        try ZeppProtobuf.walk(data[2...]) { field, value in
            guard case .bytes(let body) = value else { return }
            switch field {
            case 2:
                try ZeppProtobuf.walk(body) { inner, v in
                    guard case .varint(let n) = v else { return }
                    if inner == 1 { start = n }
                    if inner == 13 { raw2_13 = n }
                }
            case 3:
                try ZeppProtobuf.walk(body) { inner, v in
                    if inner == 1, case .varint(let n) = v { sport = n }
                }
            case 7:
                try ZeppProtobuf.walk(body) { inner, v in
                    if inner == 1, case .varint(let n) = v { duration = n }
                }
            case 16:
                try ZeppProtobuf.walk(body) { inner, v in
                    if inner == 1, case .varint(let n) = v { kcal = n }
                }
            case 19:
                try ZeppProtobuf.walk(body) { inner, v in
                    guard case .varint(let n) = v else { return }
                    switch inner {
                    case 1: average = n
                    case 2: maximum = n
                    case 3: minimum = n
                    default: break
                    }
                }
            default:
                break   // `1` (the "2.1" version string) and every unknown field (§22.2)
            }
        }
        guard let start else { throw ZeppWorkoutRecordError.missingField("2.1 start") }
        guard let duration else { throw ZeppWorkoutRecordError.missingField("7.1 duration") }
        let startDate = Date(timeIntervalSince1970: TimeInterval(start))
        guard start <= UInt64(UInt32.max), plausibleStarts.contains(startDate) else {
            throw ZeppWorkoutRecordError.outOfRange("start")
        }
        guard duration > 0, duration <= UInt64(maxDurationSeconds) else { throw ZeppWorkoutRecordError.outOfRange("duration") }
        // Heart rate 0 is "no reading", as everywhere in this document; a value past 255 is not a bpm.
        func bpm(_ n: UInt64?) -> Int? { n.flatMap { $0 > 0 && $0 < 255 ? Int($0) : nil } }
        return ZeppWorkoutSummary(start: startDate, durationSeconds: Int(duration),
                                  kilocalories: kcal.flatMap { $0 <= 100_000 ? Int($0) : nil },
                                  averageHeartRate: bpm(average), maximumHeartRate: bpm(maximum),
                                  minimumHeartRate: bpm(minimum), sportCode: sport, raw2_13: raw2_13)
    }
}

// MARK: - Detail (§22.3)

/// One 1 Hz heart-rate reading of a workout's detail track.
public struct ZeppWorkoutHeartRate: Equatable, Codable, Sendable {
    public let time: Date
    public let bpm: Int

    public init(time: Date, bpm: Int) {
        self.time = time
        self.bpm = bpm
    }
}

public struct ZeppWorkoutDetail: Equatable, Sendable {
    /// The readings inside the workout's window, in record order, `00`/`ff` dropped.
    public let heartRate: [ZeppWorkoutHeartRate]
    /// Every `08` entry the record held, before trimming and dropping.
    public let rawSampleCount: Int

    public static let blockHeaderType: UInt8 = 0x01
    public static let blockHeaderLength = 12
    public static let heartRateType: UInt8 = 0x08
    public static let heartRateLength = 3

    /// Walks the whole record and keeps the readings in `[window.start, window.end)` (§22.3: the detail
    /// runs past the workout). Unknown types are skipped by their length.
    public static func parse(_ data: [UInt8], window: DateInterval) throws -> ZeppWorkoutDetail {
        guard !data.isEmpty else { throw ZeppWorkoutRecordError.empty }
        let limit = ZeppWorkoutFetchType.detail.maxRoundBytes
        guard data.count <= limit else { throw ZeppWorkoutRecordError.oversized(length: data.count, limit: limit) }
        var offset = 0
        var blockStartMs: UInt64?
        var raw = 0
        var out: [ZeppWorkoutHeartRate] = []
        var sawBlock = false
        while offset < data.count {
            // SPEC-GAP: §22.3 keeps the samples before an entry that runs past the end (🟡); the brief's
            // rule for this record is stricter: a truncated record fails and is fetched again later.
            guard offset + 2 <= data.count else { throw ZeppWorkoutRecordError.truncated }
            let type = data[offset]
            let length = Int(data[offset + 1])
            let valueStart = offset + 2
            guard valueStart + length <= data.count else { throw ZeppWorkoutRecordError.truncated }
            let value = data[valueStart..<(valueStart + length)]
            switch type {
            case blockHeaderType:
                guard length == blockHeaderLength else { throw ZeppWorkoutRecordError.outOfRange("block header length") }
                // Bytes 4-9: the block's start, Unix epoch milliseconds, u48 LE. Bytes 0-3 and 10-11 are 🔴.
                var ms: UInt64 = 0
                for i in 0..<6 { ms |= UInt64(value[value.startIndex + 4 + i]) << UInt64(8 * i) }
                let blockStart = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                guard ZeppWorkoutSummary.plausibleStarts.contains(blockStart) else {
                    throw ZeppWorkoutRecordError.outOfRange("block start")
                }
                blockStartMs = ms
                sawBlock = true
            case heartRateType:
                guard length == heartRateLength else { throw ZeppWorkoutRecordError.outOfRange("heart-rate entry length") }
                guard let base = blockStartMs else { throw ZeppWorkoutRecordError.outOfRange("heart rate before a block header") }
                raw += 1
                let i = value.startIndex
                let offsetMs = UInt64(value[i]) | UInt64(value[i + 1]) << 8
                let time = Date(timeIntervalSince1970: TimeInterval(base + offsetMs) / 1000)
                if let bpm = ZeppHeartRateReading.bpm(value[i + 2]), time >= window.start, time < window.end {
                    out.append(ZeppWorkoutHeartRate(time: time, bpm: bpm))
                }
            default:
                break   // `04`, `05`, `0f`, `1f`, `fa`, `00` and anything else: skipped by length (🔴)
            }
            offset = valueStart + length
        }
        // A track with no block header has no time for anything in it.
        guard sawBlock else { throw ZeppWorkoutRecordError.outOfRange("no block header") }
        return ZeppWorkoutDetail(heartRate: out, rawSampleCount: raw)
    }
}

/// One workout as the walk delivers it: the summary and its trimmed heart-rate track.
public struct ZeppWorkoutRecord: Equatable, Sendable {
    public let summary: ZeppWorkoutSummary
    public let heartRate: [ZeppWorkoutHeartRate]

    public init(summary: ZeppWorkoutSummary, heartRate: [ZeppWorkoutHeartRate]) {
        self.summary = summary
        self.heartRate = heartRate
    }

    /// The record's identity (91c): its start time.
    public var start: Date { summary.start }
}

// MARK: - A minimal protocol-buffers reader

/// Varint, fixed64, length-delimited and fixed32 fields; groups (wire types 3 and 4) are not read.
enum ZeppProtobuf {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    /// Calls `visit` with each top-level field of `data`, in order. Throws on anything malformed.
    static func walk(_ data: ArraySlice<UInt8>, _ visit: (UInt64, Value) throws -> Void) throws {
        var i = data.startIndex
        while i < data.endIndex {
            let tag = try varint(data, &i)
            let field = tag >> 3
            guard field > 0, field <= 536_870_911 else { throw ZeppWorkoutRecordError.malformedField }
            switch tag & 0x07 {
            case 0:
                try visit(field, .varint(try varint(data, &i)))
            case 1:
                guard data.endIndex - i >= 8 else { throw ZeppWorkoutRecordError.truncated }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(data[i + k]) << UInt64(8 * k) }
                i += 8
                try visit(field, .fixed64(v))
            case 2:
                let length = try varint(data, &i)
                guard length <= UInt64(data.endIndex - i) else { throw ZeppWorkoutRecordError.truncated }
                let end = i + Int(length)
                try visit(field, .bytes(data[i..<end]))
                i = end
            case 5:
                guard data.endIndex - i >= 4 else { throw ZeppWorkoutRecordError.truncated }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(data[i + k]) << UInt32(8 * k) }
                i += 4
                try visit(field, .fixed32(v))
            default:
                throw ZeppWorkoutRecordError.malformedField
            }
        }
    }

    static func varint(_ data: ArraySlice<UInt8>, _ i: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < data.endIndex else { throw ZeppWorkoutRecordError.truncated }
            let byte = data[i]
            i += 1
            // The 10th byte may only carry the top bit of a 64-bit value.
            guard shift < 63 || (shift == 63 && byte & 0x7E == 0) else { throw ZeppWorkoutRecordError.malformedVarint }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }
}
