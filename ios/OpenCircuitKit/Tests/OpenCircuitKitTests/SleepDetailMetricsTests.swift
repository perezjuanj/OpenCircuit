import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for per-stage HR + the movement timeline (#70).
final class SleepDetailMetricsTests: XCTestCase {

    /// A sleep-vitals epoch with explicit HR + uniform motion byte.
    private func rec(_ counter: UInt32, hr: UInt8, motion: UInt8 = 1) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    private let step: UInt32 = 150

    func testAverageHRByStage() {
        let epoch = Command.syncEpoch
        func t(_ c: UInt32) -> Date { Date(timeIntervalSince1970: TimeInterval(Int(c) + epoch)) }

        // Two deep epochs @ 50/52, two REM epochs @ 64/66.
        var c: UInt32 = 1000
        let deepStart = c
        let r0 = rec(c, hr: 50); c += step
        let r1 = rec(c, hr: 52); c += step
        let deepEnd = c
        let remStart = c
        let r2 = rec(c, hr: 64); c += step
        let r3 = rec(c, hr: 66); c += step
        let remEnd = c + step

        let segs = [
            SleepSegment(start: t(deepStart), end: t(remEnd), stage: .inBed),
            SleepSegment(start: t(deepStart), end: t(deepEnd), stage: .asleepDeep),
            SleepSegment(start: t(remStart), end: t(remEnd), stage: .asleepREM),
        ]
        let byStage = SleepDetailMetrics.averageHRByStage(records: [r0, r1, r2, r3], segments: segs)
        XCTAssertEqual(byStage[.asleepDeep], 51)
        XCTAssertEqual(byStage[.asleepREM], 65)
        XCTAssertNil(byStage[.asleepCore], "no light epochs → omitted")
        XCTAssertNil(byStage[.inBed], "inBed excluded so stages don't double-count")
    }

    func testMovementLevels() {
        var c: UInt32 = 0
        let still = rec(c, hr: 55, motion: 1); c += step      // baseline → still
        let light = rec(c, hr: 55, motion: 3); c += step      // 5×(3) = 15, not > 15 → light
        let active = rec(c, hr: 55, motion: 20)               // 5×20 = 100 → active

        let m = SleepDetailMetrics.movement(records: [still, light, active])
        XCTAssertEqual(m.map(\.level), [.still, .light, .active])
        XCTAssertEqual(m[0].magnitude, 0)
        XCTAssertEqual(m[2].magnitude, 100)
    }

    func testMovementSummaryCounts() {
        var c: UInt32 = 0
        var recs: [BulkRecord] = []
        for _ in 0..<6 { recs.append(rec(c, hr: 55, motion: 1)); c += step }   // still
        for _ in 0..<3 { recs.append(rec(c, hr: 55, motion: 3)); c += step }   // light
        for _ in 0..<1 { recs.append(rec(c, hr: 55, motion: 30)); c += step }  // active

        let s = SleepDetailMetrics.movementSummary(records: recs)
        XCTAssertEqual(s.still, 6)
        XCTAssertEqual(s.light, 3)
        XCTAssertEqual(s.active, 1)
        XCTAssertEqual(s.total, 10)
        XCTAssertEqual(s.levels.count, 10)
        XCTAssertEqual(s.movementFraction, 0.4, accuracy: 1e-9)
    }
}
