import XCTest
@testable import OpenCircuitKit

final class ExportEngineTests: XCTestCase {

    // Reference dates for deterministic output
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14T22:13:20Z
    private let t1 = Date(timeIntervalSince1970: 1_700_003_600)  // +1 h
    private let night = Date(timeIntervalSince1970: 1_699_920_000) // 2023-11-13 (approx)

    // MARK: - samplesCSV

    func testSamplesCSVHeader() {
        let csv = ExportEngine.samplesCSV([])
        XCTAssertTrue(csv.hasPrefix("kind,start,end,value"), "header missing — got: \(csv)")
    }

    func testSamplesCSVOneRow() {
        let row = ExportEngine.SampleRow(kind: "heartRate", start: t0, end: t1, value: 72)
        let csv = ExportEngine.samplesCSV([row])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "expected header + 1 data line")
        XCTAssertTrue(lines[1].hasPrefix("heartRate,"), "first field should be kind")
        XCTAssertTrue(lines[1].hasSuffix(",72"), "last field should be value 72")
    }

    func testSamplesCSVEmptyIsHeaderOnly() {
        let csv = ExportEngine.samplesCSV([])
        XCTAssertEqual(csv, "kind,start,end,value")
    }

    func testSamplesCSVMultipleRows() {
        let rows = [
            ExportEngine.SampleRow(kind: "heartRate", start: t0, end: t1, value: 72),
            ExportEngine.SampleRow(kind: "spo2", start: t1, end: t1, value: 0.98),
        ]
        let lines = ExportEngine.samplesCSV(rows).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
    }

    // MARK: - sleepCSV

    func testSleepCSVHeader() {
        let csv = ExportEngine.sleepCSV([])
        XCTAssertTrue(csv.hasPrefix("night,asleepMin,"), "header missing — got: \(csv)")
    }

    func testSleepCSVOneRow() {
        let row = ExportEngine.SleepRow(
            night: night, asleepMin: 450, deepMin: 90, lightMin: 180,
            remMin: 120, awakeMin: 30, efficiency: 0.9375,
            skinTempC: 36.5, sleepScore: 82, stressScore: 40)
        let csv = ExportEngine.sleepCSV([row])
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("450"), "asleepMin should appear")
        XCTAssertTrue(lines[1].contains("36.50"), "skinTempC should appear as 2 dp")
    }

    func testSleepCSVEmptyIsHeaderOnly() {
        let csv = ExportEngine.sleepCSV([])
        XCTAssertTrue(csv.hasPrefix("night,"))
        XCTAssertFalse(csv.contains("\n"), "no newline in header-only result")
    }

    // MARK: - dailyCSV

    func testDailyCSVHeader() {
        let csv = ExportEngine.dailyCSV([])
        XCTAssertEqual(csv, "day,steps")
    }

    func testDailyCSVOneRow() {
        let row = ExportEngine.DailyRow(day: night, steps: 8_000)
        let lines = ExportEngine.dailyCSV([row]).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix(",8000"), "steps should be last field")
    }

    func testStepSamplesCSVHeader() {
        XCTAssertEqual(ExportEngine.stepSamplesCSV([]), "start,end,delta")
    }

    func testNapsCSVHeader() {
        XCTAssertEqual(ExportEngine.napsCSV([]), "start,end,asleepMin,isLongNap")
    }

    func testDaytimeTemperatureCSVHeader() {
        XCTAssertEqual(ExportEngine.daytimeTemperatureCSV([]), "time,celsius")
    }

    func testHistorySyncEvidenceCSVHeader() {
        XCTAssertEqual(
            ExportEngine.historySyncEvidenceCSV([]),
            // `nightRowOutcome` (#204) is APPENDED — every pre-existing column keeps its index,
            // which is the compatibility property this header lock exists to protect.
            "capturedAt,ringID,trigger,sleepCommitted,stagedSleepSegments,mergedRecordCount,historySampleCount,channelSummary,rawRecordBlobBase64,nightRowOutcome"
        )
    }

    // MARK: - toJSON

    func testToJSONReturnsValidJSON() {
        let sRow = ExportEngine.SampleRow(kind: "heartRate", start: t0, end: t1, value: 72)
        let slRow = ExportEngine.SleepRow(
            night: night, asleepMin: 450, deepMin: 90, lightMin: 180,
            remMin: 120, awakeMin: 30, efficiency: 0.9375,
            inBedStart: t0, inBedEnd: t1, skinTempC: 36.5, sleepScore: 82, stressScore: 40,
            feelScore: 7, hrDeep: 55, hrLight: 60, hrRem: 64, hrAwake: 68, movementLevels: [0, 1, 2])
        let dRow = ExportEngine.DailyRow(day: night, steps: 8_000)
        let stepRow = ExportEngine.StepSampleRow(start: t0, end: t1, delta: 123)
        let napRow = ExportEngine.NapRow(start: t0, end: t1, asleepMin: 30, isLongNap: false)
        let tempRow = ExportEngine.DaytimeTemperatureRow(time: t0, celsius: 34.2)
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00, startedAt: t0)
        trace.finishedAt = t1
        trace.sawSyncAck = true
        trace.page4CCount = 1
        trace.endMarkerCount = 1
        trace.recordsAtStart = 2
        trace.recordsAtEnd = 8
        trace.exitReason = .endMarker
        let evidenceRow = ExportEngine.HistorySyncEvidenceRow(
            capturedAt: t0, ringID: "ring-1", trigger: "manual",
            sleepCommitted: true, stagedSleepSegments: 4,
            mergedRecordCount: 8, historySampleCount: 10,
            rawRecordBlobBase64: "AQID", channels: [trace])

        let json = ExportEngine.toJSON(samples: [sRow], sleep: [slRow], daily: [dRow], now: t0)
        XCTAssertNotNil(json, "toJSON should not return nil")

        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("produced string is not valid JSON")
        }
        XCTAssertNotNil(obj["exportedAt"], "exportedAt key required")
        // Bumped 2 → 3 with the rich export. v3 is a byte-SUPERSET of v2, so this is the only
        // value that changed; `ExportSchemaV3Tests` proves every other v2 key is untouched.
        XCTAssertEqual(obj["schemaVersion"] as? Int, 3)
        XCTAssertNotNil(obj["samples"] as? [[String: Any]])
        XCTAssertNotNil(obj["sleep"] as? [[String: Any]])
        XCTAssertNotNil(obj["daily"] as? [[String: Any]])
        let full = ExportEngine.toJSON(samples: [sRow], sleep: [slRow], daily: [dRow],
                                       stepSamples: [stepRow], naps: [napRow],
                                       daytimeTemperatures: [tempRow],
                                       historySyncEvidence: [evidenceRow], now: t0)
        XCTAssertNotNil(full)
        guard let full, let fullData = full.data(using: .utf8),
              let fullObj = try? JSONSerialization.jsonObject(with: fullData) as? [String: Any] else {
            return XCTFail("expanded JSON is not valid")
        }
        XCTAssertEqual((fullObj["stepSamples"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((fullObj["naps"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((fullObj["daytimeTemperatures"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((fullObj["historySyncEvidence"] as? [[String: Any]])?.count, 1)
    }

    func testToJSONEmptyInputsStillValid() {
        let json = ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0)
        XCTAssertNotNil(json)
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("empty-input JSON is invalid")
        }
        XCTAssertEqual((obj["samples"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((obj["sleep"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((obj["daily"] as? [[String: Any]])?.count, 0)
    }

    func testToJSONExportedAtPresent() {
        let json = ExportEngine.toJSON(samples: [], sleep: [], daily: [], now: t0)!
        XCTAssertTrue(json.contains("exportedAt"), "exportedAt timestamp must appear")
    }

    // MARK: - CSV byte identity (RFC-4180 escaper must be a no-op for clean values)

    // These expectations are hardcoded on purpose: they are what the writers emitted BEFORE the
    // escaper existed. If one of them fails, the escaper started quoting something it used to
    // leave alone and every downstream consumer's column offsets moved.

    func testSamplesCSVBytesUnchanged() {
        let rows = [
            ExportEngine.SampleRow(kind: "heartRate", start: t0, end: t1, value: 72),
            ExportEngine.SampleRow(kind: "spo2", start: t0, end: t0, value: 0.98),
        ]
        XCTAssertEqual(ExportEngine.samplesCSV(rows), """
        kind,start,end,value
        heartRate,2023-11-14T22:13:20.000Z,2023-11-14T23:13:20.000Z,72
        spo2,2023-11-14T22:13:20.000Z,2023-11-14T22:13:20.000Z,0.98
        """)
    }

    func testStepSamplesCSVBytesUnchanged() {
        let row = ExportEngine.StepSampleRow(start: t0, end: t1, delta: 123)
        XCTAssertEqual(ExportEngine.stepSamplesCSV([row]), """
        start,end,delta
        2023-11-14T22:13:20.000Z,2023-11-14T23:13:20.000Z,123
        """)
    }

    func testNapsCSVBytesUnchanged() {
        let row = ExportEngine.NapRow(start: t0, end: t1, asleepMin: 30, isLongNap: false)
        XCTAssertEqual(ExportEngine.napsCSV([row]), """
        start,end,asleepMin,isLongNap
        2023-11-14T22:13:20.000Z,2023-11-14T23:13:20.000Z,30,false
        """)
    }

    func testDaytimeTemperatureCSVBytesUnchanged() {
        let row = ExportEngine.DaytimeTemperatureRow(time: t0, celsius: 34.2)
        XCTAssertEqual(ExportEngine.daytimeTemperatureCSV([row]), """
        time,celsius
        2023-11-14T22:13:20.000Z,34.20
        """)
    }

    func testHistorySyncEvidenceCSVBytesUnchanged() {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00, startedAt: t0)
        trace.finishedAt = t1
        trace.sawSyncAck = true
        trace.page4CCount = 1
        trace.endMarkerCount = 1
        trace.recordsAtStart = 2
        trace.recordsAtEnd = 8
        trace.exitReason = .endMarker
        let row = ExportEngine.HistorySyncEvidenceRow(
            capturedAt: t0, ringID: "ring-1", trigger: "manual",
            sleepCommitted: true, stagedSleepSegments: 4,
            mergedRecordCount: 8, historySampleCount: 10,
            rawRecordBlobBase64: "AQID", channels: [trace],
            nightRowOutcome: SleepPersistOutcome.updated.rawValue)
        XCTAssertEqual(ExportEngine.historySyncEvidenceCSV([row]), """
        capturedAt,ringID,trigger,sleepCommitted,stagedSleepSegments,mergedRecordCount,historySampleCount,channelSummary,rawRecordBlobBase64,nightRowOutcome
        2023-11-14T22:13:20.000Z,ring-1,manual,true,4,8,10,sleep:complete:4c=1:47=0:50=1:added=6,AQID,updated
        """)
    }

    func testSleepCSVBytesUnchanged() {
        // `night` is formatted in the DEVICE's local calendar (that is the calendar it was
        // bucketed with), so the expected label is built independently here rather than pinned
        // to whatever timezone the test machine happens to be in.
        let row = ExportEngine.SleepRow(
            night: night, asleepMin: 450, deepMin: 90, lightMin: 180,
            remMin: 120, awakeMin: 30, efficiency: 0.9375,
            inBedStart: t0, inBedEnd: t1, skinTempC: 36.5, sleepScore: 82, stressScore: 40,
            feelScore: 7, hrDeep: 55, hrLight: 60, hrRem: 64, hrAwake: 68,
            movementLevels: [0, 1, 2])
        XCTAssertEqual(ExportEngine.sleepCSV([row]), """
        night,asleepMin,deepMin,lightMin,remMin,awakeMin,efficiency,inBedStart,inBedEnd,skinTempC,sleepScore,stressScore,feelScore,hrDeep,hrLight,hrRem,hrAwake,movementLevels
        \(localDayLabel(night)),450,90,180,120,30,0.9375,2023-11-14T22:13:20.000Z,2023-11-14T23:13:20.000Z,36.50,82,40,7,55,60,64,68,0|1|2
        """)
    }

    func testDailyCSVBytesUnchanged() {
        let row = ExportEngine.DailyRow(day: night, steps: 8_000)
        XCTAssertEqual(ExportEngine.dailyCSV([row]), """
        day,steps
        \(localDayLabel(night)),8000
        """)
    }

    // MARK: - RFC-4180 escaping

    func testCSVFieldIsNoOpForCleanValues() {
        for clean in ["", "heartRate", "2023-11-14T22:13:20.000Z", "0|1|2", "72", "ring-1",
                      "sleep:complete:4c=1:47=0:50=1:added=6", "a b c"] {
            XCTAssertEqual(ExportEngine.csvField(clean), clean,
                           "clean value \(clean) must not be quoted")
        }
    }

    func testCSVFieldQuotesComma() {
        XCTAssertEqual(ExportEngine.csvField("ring,1"), "\"ring,1\"")
    }

    func testCSVFieldDoublesEmbeddedQuotes() {
        XCTAssertEqual(ExportEngine.csvField("he said \"go\""), "\"he said \"\"go\"\"\"")
    }

    func testCSVFieldQuotesNewlines() {
        XCTAssertEqual(ExportEngine.csvField("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(ExportEngine.csvField("line1\r\nline2"), "\"line1\r\nline2\"")
    }

    func testCSVFieldQuotesLeadingAndTrailingSpace() {
        // Unquoted, most parsers strip these and the value silently changes.
        XCTAssertEqual(ExportEngine.csvField(" leading"), "\" leading\"")
        XCTAssertEqual(ExportEngine.csvField("trailing "), "\"trailing \"")
    }

    func testHostileValuesRoundTripThroughTheCSV() {
        // The real latent bug: a comma in a free-form column used to shift every later column.
        let hostile: [(String, String)] = [
            ("ring,with,commas", "manual"),
            ("ring\"quoted\"", "auto"),
            ("ring\nnewline", "background"),
            ("ring\r\nCRLF", "background"),   // one grapheme in Swift — see csvField's note
            (" padded ", "manual"),
        ]
        for (ringID, trigger) in hostile {
            let row = ExportEngine.HistorySyncEvidenceRow(
                capturedAt: t0, ringID: ringID, trigger: trigger,
                sleepCommitted: true, stagedSleepSegments: 4,
                mergedRecordCount: 8, historySampleCount: 10,
                rawRecordBlobBase64: "AQID", channels: [])
            let records = Self.parseCSV(ExportEngine.historySyncEvidenceCSV([row]))
            XCTAssertEqual(records.count, 2, "header + exactly one record for \(ringID)")
            XCTAssertEqual(records[1].count, 10, "column count must survive \(ringID)")
            XCTAssertEqual(records[1][1], ringID, "ringID must round-trip verbatim")
            XCTAssertEqual(records[1][2], trigger, "trigger must round-trip verbatim")
            XCTAssertEqual(records[1][8], "AQID",
                           "later columns must not shift — `nightRowOutcome` is appended, not inserted")
        }
    }

    // MARK: - Helpers

    /// yyyy-MM-dd in the device's local calendar — reimplemented here so the expectation is
    /// independent of `ExportEngine`'s own formatter.
    private func localDayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Minimal RFC-4180 reader (quoted fields, doubled quotes, embedded newlines) used to prove
    /// the writer's output is actually parseable rather than merely different.
    static func parseCSV(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let c = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(field); field = ""
            } else if c == "\n" {
                fields.append(field); field = ""
                records.append(fields); fields = []
            } else if c == "\r" {
                continue
            } else {
                field.append(c)
            }
        }
        fields.append(field)
        records.append(fields)
        return records
    }
}
