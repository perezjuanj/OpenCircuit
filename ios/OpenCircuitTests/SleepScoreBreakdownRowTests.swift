import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// The Sleep card offers "How this score is made" only for a stored row whose score can be rebuilt
// from the row itself. Every value here is synthetic.

final class SleepScoreBreakdownRowTests: XCTestCase {

    private func row(edited: Bool, scoreOffset: Int = 0) -> StoredSleepSummary {
        let composite = SleepScore.composite(.init(
            totalAsleep: 412 * 60, timeAwake: 14 * 60, efficiency: 0.91,
            deep: 80 * 60, light: 254 * 60, rem: 78 * 60))
        let r = StoredSleepSummary(night: Date(timeIntervalSince1970: 1_789_862_400),
                                   asleepMin: 412, deepMin: 80, lightMin: 254, remMin: 78,
                                   awakeMin: 14, efficiency: 0.91,
                                   sleepScore: composite.score + scoreOffset)
        r.isManuallyEdited = edited
        return r
    }

    func testAnEditedRowWhoseScoreAddsUpHasABreakdown() throws {
        let breakdown = try XCTUnwrap(row(edited: true).scoreBreakdown)
        XCTAssertEqual(breakdown.score, row(edited: true).sleepScore)
        XCTAssertEqual(breakdown.rows.count, 4, "an edited night has no HR or temperature factor")
    }

    func testARowWhoseScoreDoesNotAddUpHasNone() {
        XCTAssertNil(row(edited: true, scoreOffset: 1).scoreBreakdown)
    }

    func testAnUneditedRowHasNoneBecauseItsHRAndTemperatureAreNotStored() {
        XCTAssertNil(row(edited: false).scoreBreakdown)
    }

    func testARowWithNoScoreHasNone() {
        let r = row(edited: true)
        r.sleepScore = 0
        XCTAssertNil(r.scoreBreakdown)
    }
}
