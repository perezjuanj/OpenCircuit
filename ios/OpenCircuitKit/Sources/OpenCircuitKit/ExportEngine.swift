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
        public let skinTempC: Double
        public let sleepScore: Int
        public let stressScore: Int
        public init(night: Date, asleepMin: Int, deepMin: Int, lightMin: Int,
                    remMin: Int, awakeMin: Int, efficiency: Double,
                    skinTempC: Double, sleepScore: Int, stressScore: Int) {
            self.night = night; self.asleepMin = asleepMin; self.deepMin = deepMin
            self.lightMin = lightMin; self.remMin = remMin; self.awakeMin = awakeMin
            self.efficiency = efficiency; self.skinTempC = skinTempC
            self.sleepScore = sleepScore; self.stressScore = stressScore
        }
    }

    public struct DailyRow: Equatable, Sendable {
        public let day: Date
        public let steps: Int
        public init(day: Date, steps: Int) { self.day = day; self.steps = steps }
    }

    // MARK: - Date formatters

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

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
        var lines = ["night,asleepMin,deepMin,lightMin,remMin,awakeMin,efficiency,skinTempC,sleepScore,stressScore"]
        for r in rows {
            lines.append([
                dateOnly.string(from: r.night),
                "\(r.asleepMin)", "\(r.deepMin)", "\(r.lightMin)",
                "\(r.remMin)", "\(r.awakeMin)",
                String(format: "%.4f", r.efficiency),
                String(format: "%.2f", r.skinTempC),
                "\(r.sleepScore)", "\(r.stressScore)"
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

    // MARK: - JSON bundle

    /// All three tables as a single JSON blob with an `exportedAt` timestamp.
    /// Returns nil only if JSON serialization fails (should never happen in practice).
    public static func toJSON(samples: [SampleRow], sleep: [SleepRow],
                              daily: [DailyRow], now: Date = Date()) -> String? {
        let root: [String: Any] = [
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
                "skinTempC": $0.skinTempC,
                "sleepScore": $0.sleepScore,
                "stressScore": $0.stressScore
            ] as [String: Any] },
            "daily": daily.map { [
                "day": dateOnly.string(from: $0.day),
                "steps": $0.steps
            ] as [String: Any] }
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}
