// Pure export serialization — no SwiftData dependency (#80). Callers fetch from the
// store and pass plain structs here, so these functions are unit-testable on the CLI.
//
// Three formats:
//   • samplesCSV   — one row per QuantitySample-equivalent (HR / SpO2 / temp / HRV / RR)
//   • sleepCSV     — one row per persisted nightly sleep summary
//   • dailyCSV     — one row per day's step rollup
//   • toJSON       — all three tables as a single JSON bundle with an exportedAt timestamp
//
// Timestamps: ISO 8601 with millisecond precision for sample start/end; yyyy-MM-dd for
// date-only fields (sleep night, daily rollup day) to keep the file readable.

import Foundation

public enum ExportEngine {

    // MARK: - Row types

    public struct SampleRow: Equatable, Sendable {
        public let kind: String
        public let start: Date
        public let end: Date
        public let value: Double
        public init(kind: String, start: Date, end: Date, value: Double) {
            self.kind = kind; self.start = start; self.end = end; self.value = value
        }
    }

    public struct SleepRow: Equatable, Sendable {
        public let night: Date
        public let asleepMin: Int
        public let deepMin: Int
        public let lightMin: Int
        public let remMin: Int
        public let awakeMin: Int
        public let efficiency: Double
        public let inBedStart: Date?
        public let inBedEnd: Date?
        public let skinTempC: Double
        public let sleepScore: Int
        public let stressScore: Int
        public let feelScore: Int
        public let hrDeep: Int
        public let hrLight: Int
        public let hrRem: Int
        public let hrAwake: Int
        public let movementLevels: [Int]
        public init(night: Date, asleepMin: Int, deepMin: Int, lightMin: Int,
                    remMin: Int, awakeMin: Int, efficiency: Double,
                    inBedStart: Date? = nil, inBedEnd: Date? = nil,
                    skinTempC: Double, sleepScore: Int, stressScore: Int,
                    feelScore: Int = 0, hrDeep: Int = 0, hrLight: Int = 0,
                    hrRem: Int = 0, hrAwake: Int = 0, movementLevels: [Int] = []) {
            self.night = night; self.asleepMin = asleepMin; self.deepMin = deepMin
            self.lightMin = lightMin; self.remMin = remMin; self.awakeMin = awakeMin
            self.efficiency = efficiency; self.inBedStart = inBedStart; self.inBedEnd = inBedEnd
            self.skinTempC = skinTempC
            self.sleepScore = sleepScore; self.stressScore = stressScore
            self.feelScore = feelScore; self.hrDeep = hrDeep; self.hrLight = hrLight
            self.hrRem = hrRem; self.hrAwake = hrAwake; self.movementLevels = movementLevels
        }
    }

    public struct DailyRow: Equatable, Sendable {
        public let day: Date
        public let steps: Int
        public init(day: Date, steps: Int) { self.day = day; self.steps = steps }
    }

    public struct StepSampleRow: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let delta: Int
        public init(start: Date, end: Date, delta: Int) {
            self.start = start; self.end = end; self.delta = delta
        }
    }

    public struct NapRow: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let asleepMin: Int
        public let isLongNap: Bool
        public init(start: Date, end: Date, asleepMin: Int, isLongNap: Bool) {
            self.start = start; self.end = end; self.asleepMin = asleepMin; self.isLongNap = isLongNap
        }
    }

    public struct DaytimeTemperatureRow: Equatable, Sendable {
        public let time: Date
        public let celsius: Double
        public init(time: Date, celsius: Double) {
            self.time = time; self.celsius = celsius
        }
    }

    public struct HistorySyncEvidenceRow: Equatable, Sendable {
        public let capturedAt: Date
        public let ringID: String
        public let trigger: String
        public let sleepCommitted: Bool
        public let stagedSleepSegments: Int
        public let mergedRecordCount: Int
        public let historySampleCount: Int
        public let rawRecordBlobBase64: String
        public let channels: [HistoryChannelTrace]
        public init(capturedAt: Date, ringID: String, trigger: String,
                    sleepCommitted: Bool, stagedSleepSegments: Int,
                    mergedRecordCount: Int, historySampleCount: Int,
                    rawRecordBlobBase64: String, channels: [HistoryChannelTrace]) {
            self.capturedAt = capturedAt
            self.ringID = ringID
            self.trigger = trigger
            self.sleepCommitted = sleepCommitted
            self.stagedSleepSegments = stagedSleepSegments
            self.mergedRecordCount = mergedRecordCount
            self.historySampleCount = historySampleCount
            self.rawRecordBlobBase64 = rawRecordBlobBase64
            self.channels = channels
        }
    }

    // MARK: - Date formatters

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // `night`/`day` are bucketed with `Calendar.current.startOfDay` (the DEVICE's local
    // timezone) at write time — e.g. a `StoredDaily.day` value IS local midnight. Formatting
    // that Date back out in UTC (the old behavior here) silently shifts the printed label a day
    // earlier for any positive UTC offset (and a day later for negative), e.g. local midnight
    // 2026-06-24 00:00 +02:00 prints as "2026-06-23" — exactly the mismatch that showed up
    // between this CSV's `day` column and the same steps' date in Apple Health. Match the
    // bucketing timezone instead of hardcoding UTC.
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static func jsonOrNull(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func jsonOrNull<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    // MARK: - CSV

    /// CSV for QuantitySample-equivalent rows. Header: `kind,start,end,value`
    public static func samplesCSV(_ rows: [SampleRow]) -> String {
        var lines = ["kind,start,end,value"]
        for r in rows {
            let v = r.value.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", r.value)
                : String(r.value)
            lines.append("\(r.kind),\(iso8601.string(from: r.start)),\(iso8601.string(from: r.end)),\(v)")
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for nightly sleep summaries. Header includes all stored columns.
    public static func sleepCSV(_ rows: [SleepRow]) -> String {
        var lines = ["night,asleepMin,deepMin,lightMin,remMin,awakeMin,efficiency,inBedStart,inBedEnd,skinTempC,sleepScore,stressScore,feelScore,hrDeep,hrLight,hrRem,hrAwake,movementLevels"]
        for r in rows {
            lines.append([
                dateOnly.string(from: r.night),
                "\(r.asleepMin)", "\(r.deepMin)", "\(r.lightMin)",
                "\(r.remMin)", "\(r.awakeMin)",
                String(format: "%.4f", r.efficiency),
                r.inBedStart.map { iso8601.string(from: $0) } ?? "",
                r.inBedEnd.map { iso8601.string(from: $0) } ?? "",
                String(format: "%.2f", r.skinTempC),
                "\(r.sleepScore)", "\(r.stressScore)",
                "\(r.feelScore)",
                "\(r.hrDeep)", "\(r.hrLight)", "\(r.hrRem)", "\(r.hrAwake)",
                r.movementLevels.map(String.init).joined(separator: "|")
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for daily step rollups. Header: `day,steps`
    public static func dailyCSV(_ rows: [DailyRow]) -> String {
        var lines = ["day,steps"]
        for r in rows {
            lines.append("\(dateOnly.string(from: r.day)),\(r.steps)")
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for intraday step deltas. Header: `start,end,delta`
    public static func stepSamplesCSV(_ rows: [StepSampleRow]) -> String {
        var lines = ["start,end,delta"]
        for r in rows {
            lines.append("\(iso8601.string(from: r.start)),\(iso8601.string(from: r.end)),\(r.delta)")
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for daytime naps. Header: `start,end,asleepMin,isLongNap`
    public static func napsCSV(_ rows: [NapRow]) -> String {
        var lines = ["start,end,asleepMin,isLongNap"]
        for r in rows {
            lines.append("\(iso8601.string(from: r.start)),\(iso8601.string(from: r.end)),\(r.asleepMin),\(r.isLongNap)")
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for daytime temperature samples. Header: `time,celsius`
    public static func daytimeTemperatureCSV(_ rows: [DaytimeTemperatureRow]) -> String {
        var lines = ["time,celsius"]
        for r in rows {
            lines.append("\(iso8601.string(from: r.time)),\(String(format: "%.2f", r.celsius))")
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for history-sync evidence. Channel traces are flattened to a compact summary string.
    public static func historySyncEvidenceCSV(_ rows: [HistorySyncEvidenceRow]) -> String {
        var lines = ["capturedAt,ringID,trigger,sleepCommitted,stagedSleepSegments,mergedRecordCount,historySampleCount,channelSummary,rawRecordBlobBase64"]
        for r in rows {
            let channelSummary = r.channels.map {
                "\($0.label):\($0.outcome.rawValue):4c=\($0.page4CCount):47=\($0.page47Count):50=\($0.endMarkerCount):added=\($0.recordsAdded)"
            }.joined(separator: "|")
            lines.append([
                iso8601.string(from: r.capturedAt),
                r.ringID,
                r.trigger,
                String(r.sleepCommitted),
                "\(r.stagedSleepSegments)",
                "\(r.mergedRecordCount)",
                "\(r.historySampleCount)",
                channelSummary,
                r.rawRecordBlobBase64
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON bundle

    /// All three tables as a single JSON blob with an `exportedAt` timestamp.
    /// Returns nil only if JSON serialization fails (should never happen in practice).
    public static func toJSON(samples: [SampleRow], sleep: [SleepRow],
                              daily: [DailyRow], stepSamples: [StepSampleRow] = [],
                              naps: [NapRow] = [],
                              daytimeTemperatures: [DaytimeTemperatureRow] = [],
                              historySyncEvidence: [HistorySyncEvidenceRow] = [],
                              now: Date = Date()) -> String? {
        let root: [String: Any] = [
            "schemaVersion": 2,
            "exportedAt": iso8601.string(from: now),
            "samples": samples.map { [
                "kind": $0.kind,
                "start": iso8601.string(from: $0.start),
                "end": iso8601.string(from: $0.end),
                "value": $0.value
            ] as [String: Any] },
            "sleep": sleep.map { [
                "night": dateOnly.string(from: $0.night),
                "asleepMin": $0.asleepMin,
                "deepMin": $0.deepMin,
                "lightMin": $0.lightMin,
                "remMin": $0.remMin,
                "awakeMin": $0.awakeMin,
                "efficiency": $0.efficiency,
                "inBedStart": jsonOrNull($0.inBedStart.map { iso8601.string(from: $0) }),
                "inBedEnd": jsonOrNull($0.inBedEnd.map { iso8601.string(from: $0) }),
                "skinTempC": $0.skinTempC,
                "sleepScore": $0.sleepScore,
                "stressScore": $0.stressScore,
                "feelScore": $0.feelScore,
                "hrDeep": $0.hrDeep,
                "hrLight": $0.hrLight,
                "hrRem": $0.hrRem,
                "hrAwake": $0.hrAwake,
                "movementLevels": $0.movementLevels
            ] as [String: Any] },
            "daily": daily.map { [
                "day": dateOnly.string(from: $0.day),
                "steps": $0.steps
            ] as [String: Any] },
            "stepSamples": stepSamples.map { [
                "start": iso8601.string(from: $0.start),
                "end": iso8601.string(from: $0.end),
                "delta": $0.delta
            ] as [String: Any] },
            "naps": naps.map { [
                "start": iso8601.string(from: $0.start),
                "end": iso8601.string(from: $0.end),
                "asleepMin": $0.asleepMin,
                "isLongNap": $0.isLongNap
            ] as [String: Any] },
            "daytimeTemperatures": daytimeTemperatures.map { [
                "time": iso8601.string(from: $0.time),
                "celsius": $0.celsius
            ] as [String: Any] },
            "historySyncEvidence": historySyncEvidence.map { [
                "capturedAt": iso8601.string(from: $0.capturedAt),
                "ringID": $0.ringID,
                "trigger": $0.trigger,
                "sleepCommitted": $0.sleepCommitted,
                "stagedSleepSegments": $0.stagedSleepSegments,
                "mergedRecordCount": $0.mergedRecordCount,
                "historySampleCount": $0.historySampleCount,
                "rawRecordBlobBase64": $0.rawRecordBlobBase64,
                "channels": $0.channels.map { channel in [
                    "label": channel.label,
                    "channel": channel.channel,
                    "startedAt": iso8601.string(from: channel.startedAt),
                    "finishedAt": jsonOrNull(channel.finishedAt.map { iso8601.string(from: $0) }),
                    "outcome": channel.outcome.rawValue,
                    "sawSyncAck": channel.sawSyncAck,
                    "syncAckFlag": jsonOrNull(channel.syncAckFlag),
                    "page4CCount": channel.page4CCount,
                    "page47Count": channel.page47Count,
                    "endMarkerCount": channel.endMarkerCount,
                    "recordsAtStart": channel.recordsAtStart,
                    "recordsAtEnd": channel.recordsAtEnd,
                    "recordsAdded": channel.recordsAdded,
                    "firstOpcode": jsonOrNull(channel.firstOpcode),
                    "lastOpcode": jsonOrNull(channel.lastOpcode),
                    "exitReason": jsonOrNull(channel.exitReason?.rawValue)
                ] as [String: Any] }
            ] as [String: Any] }
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}
