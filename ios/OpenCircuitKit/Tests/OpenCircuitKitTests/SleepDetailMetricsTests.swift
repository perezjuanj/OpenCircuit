import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for per-stage HR + the movement timeline (#70).
final class SleepDetailMetricsTests: XCTestCase {

    /// A sleep-vitals epoch with an explicit 5-sample motion array.
    private func rec(_ counter: UInt32, hr: UInt8, motionBytes: [UInt8]) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motionBytes[k] }
        return BulkRecord(b)!
    }

    /// A sleep-vitals epoch with a UNIFORM motion byte (a constant run = still at any level).
    private func rec(_ counter: UInt32, hr: UInt8, motion: UInt8 = 1) -> BulkRecord {
        rec(counter, hr: hr, motionBytes: [UInt8](repeating: motion, count: 5))
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

    /// Regression for the "all-orange" bug: a CONSTANT motion run is the ring's still/placeholder
    /// filler at ANY level — Gen-2 `01`, Gen-3 `0f`(=15), a drifted idle — and must read `.still`,
    /// never `.active`. The old `$1 == 1` baseline read `0f`×5 as 75 → `.active` on every sleep epoch.
    func testConstantRunsAreStillAtAnyLevel() {
        var c: UInt32 = 0
        var recs: [BulkRecord] = []
        for v: UInt8 in [1, 15, 20, 39] { recs.append(rec(c, hr: 55, motion: v)); c += step }
        let m = SleepDetailMetrics.movement(records: recs)
        XCTAssertEqual(m.map(\.level), [.still, .still, .still, .still])
        XCTAssertTrue(m.allSatisfy { $0.magnitude == 0 }, "a constant run has zero intra-epoch energy")
    }

    /// Movement = how far the 5 sub-samples rise above the epoch's OWN minimum (intra-epoch
    /// variation), not the raw sum. Explicit cut for determinism.
    func testMovementLevels() {
        var c: UInt32 = 0
        let still  = rec(c, hr: 55, motionBytes: [1, 1, 1, 1, 1]);      c += step  // no variation → still
        let light  = rec(c, hr: 55, motionBytes: [1, 1, 1, 4, 1]);      c += step  // energy 3
        let active = rec(c, hr: 55, motionBytes: [10, 40, 15, 50, 20])             // energy 85

        let m = SleepDetailMetrics.movement(records: [still, light, active], activeThreshold: 20)
        XCTAssertEqual(m.map(\.level), [.still, .light, .active])
        XCTAssertEqual(m[0].magnitude, 0)
        XCTAssertEqual(m[1].magnitude, 3)
        XCTAssertEqual(m[2].magnitude, 85)
    }

    /// With no explicit threshold the light/active split is the 80th percentile of the night's OWN
    /// moving energies — the most energetic epochs read `.active`, calmer movement `.light`.
    func testDerivedActiveCutUsesNightDistribution() {
        var c: UInt32 = 0
        var recs: [BulkRecord] = []
        // energies 2, 4, 6, 8, 80 ; idx = round(4×0.8) = 3 → cut = 8 ; ≥8 → active
        for a: [UInt8] in [[1,3,1,1,1], [1,5,1,1,1], [1,7,1,1,1], [1,9,1,1,1], [1,81,1,1,1]] {
            recs.append(rec(c, hr: 55, motionBytes: a)); c += step
        }
        let m = SleepDetailMetrics.movement(records: recs)
        XCTAssertEqual(m.map(\.level), [.light, .light, .light, .active, .active])
    }

    func testMovementSummaryCounts() {
        var c: UInt32 = 0
        var recs: [BulkRecord] = []
        for _ in 0..<6 { recs.append(rec(c, hr: 55, motion: 1)); c += step }                 // still (energy 0)
        for _ in 0..<3 { recs.append(rec(c, hr: 55, motionBytes: [1,1,1,4,1])); c += step }   // light (energy 3)
        recs.append(rec(c, hr: 55, motionBytes: [5,50,5,5,5]))                                // active (energy 45)

        let s = SleepDetailMetrics.movementSummary(records: recs, activeThreshold: 20)
        XCTAssertEqual(s.still, 6)
        XCTAssertEqual(s.light, 3)
        XCTAssertEqual(s.active, 1)
        XCTAssertEqual(s.total, 10)
        XCTAssertEqual(s.levels.count, 10)
        XCTAssertEqual(s.movementFraction, 0.4, accuracy: 1e-9)
    }
}
