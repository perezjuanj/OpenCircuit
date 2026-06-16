import XCTest
@testable import OpenRingKit

final class SyncCursorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 2000)
    let t2 = Date(timeIntervalSince1970: 3000)

    func testFreshCursorTreatsEverythingAsNew() {
        let c = SyncCursor()
        XCTAssertNil(c.last(.heartRate))
        XCTAssertTrue(c.isNew(.heartRate, t0))
    }

    func testSelectNewSortsAndAdvancesPerKind() {
        var c = SyncCursor()
        let fresh = c.selectNew([
            QuantitySample(kind: .heartRate, start: t1, value: 60),
            QuantitySample(kind: .heartRate, start: t0, value: 58),
            QuantitySample(kind: .spo2, start: t1, value: 0.97),
        ])
        XCTAssertEqual(fresh.count, 3)
        XCTAssertEqual(fresh.first?.start, t0)            // sorted
        XCTAssertEqual(c.last(.heartRate), t1)
        XCTAssertEqual(c.last(.spo2), t1)                 // independent
    }

    func testResyncDropsSeenKeepsNewerAndNeverGoesBackward() {
        var c = SyncCursor()
        _ = c.selectNew([QuantitySample(kind: .heartRate, start: t1, value: 60)])
        let again = c.selectNew([
            QuantitySample(kind: .heartRate, start: t1, value: 61),  // == cursor
            QuantitySample(kind: .heartRate, start: t2, value: 62),  // newer
        ])
        XCTAssertEqual(again.map(\.start), [t2])
        c.advance(.heartRate, to: t0)
        XCTAssertEqual(c.last(.heartRate), t2)
    }

    func testSelectNewStagedDoesNotMutateUntilApplied() {
        let c = SyncCursor()
        let (fresh, advanced) = c.selectNewStaged([
            QuantitySample(kind: .heartRate, start: t1, value: 60),
            QuantitySample(kind: .heartRate, start: t0, value: 58),
        ])
        XCTAssertEqual(fresh.map(\.start), [t0, t1])     // sorted, both fresh
        XCTAssertNil(c.last(.heartRate))                 // original cursor untouched
        XCTAssertEqual(advanced.last(.heartRate), t1)    // advance only on the returned copy
    }

    func testStagedAdvanceIgnoredLeavesSamplesRetriable() {
        // Simulate a failed commit: stage the advance but DON'T adopt `advanced`. The original
        // cursor must still treat the same samples as new so they're retried (#22).
        let c = SyncCursor()
        _ = c.selectNewStaged([QuantitySample(kind: .heartRate, start: t1, value: 60)])
        XCTAssertTrue(c.isNew(.heartRate, t1))
    }

    func testAdvancedKindsReportsOnlyMovedCursors() {
        let base = SyncCursor()
        var moved = base
        _ = moved.selectNew([
            QuantitySample(kind: .heartRate, start: t1, value: 60),
            QuantitySample(kind: .spo2, start: t1, value: 0.97),
        ])
        XCTAssertEqual(Set(moved.advancedKinds(since: base)), [.heartRate, .spo2])
        XCTAssertTrue(moved.advancedKinds(since: moved).isEmpty)   // no diff with self
    }

    func testUnitsMatchHealthKitMapping() {
        XCTAssertEqual(MetricKind.spo2.unit, "fraction")
        XCTAssertEqual(MetricKind.hrvSDNN.unit, "ms")
        XCTAssertEqual(MetricKind.temperature.unit, "degC")
    }

    func testCursorRoundTripsThroughCodable() throws {
        var c = SyncCursor()
        c.advance(.steps, to: t1)
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(SyncCursor.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.last(.steps), t1)
    }
}
