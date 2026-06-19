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

    // MARK: - toJSON

    func testToJSONReturnsValidJSON() {
        let sRow = ExportEngine.SampleRow(kind: "heartRate", start: t0, end: t1, value: 72)
        let slRow = ExportEngine.SleepRow(
            night: night, asleepMin: 450, deepMin: 90, lightMin: 180,
            remMin: 120, awakeMin: 30, efficiency: 0.9375,
            skinTempC: 36.5, sleepScore: 82, stressScore: 40)
        let dRow = ExportEngine.DailyRow(day: night, steps: 8_000)

        let json = ExportEngine.toJSON(samples: [sRow], sleep: [slRow], daily: [dRow], now: t0)
        XCTAssertNotNil(json, "toJSON should not return nil")

        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("produced string is not valid JSON")
        }
        XCTAssertNotNil(obj["exportedAt"], "exportedAt key required")
        XCTAssertNotNil(obj["samples"] as? [[String: Any]])
        XCTAssertNotNil(obj["sleep"] as? [[String: Any]])
        XCTAssertNotNil(obj["daily"] as? [[String: Any]])
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
}
