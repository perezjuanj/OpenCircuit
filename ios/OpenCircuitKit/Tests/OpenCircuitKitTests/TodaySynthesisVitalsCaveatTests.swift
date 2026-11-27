// Decision 95a: a Recovery counted from sleep and vitals without sleeping HRV keeps a caveat in the
// sentence, as sleep alone does; vitals never make it read as a full score.

import XCTest
@testable import OpenCircuitKit

final class TodaySynthesisVitalsCaveatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func lead(factorCount: Int, withoutHRV: Bool) -> String {
        TodaySynthesis.sentence(.init(readiness: .scored(score: 73, tier: .good, factorCount: factorCount),
                                      newestDataAt: now, now: now, withoutSleepingHRV: withoutHRV))
    }

    func testSleepAndVitalsWithoutHRVNamesBoth() {
        XCTAssertEqual(lead(factorCount: 2, withoutHRV: true), "Recovery is good at 73 based on last night's sleep and vitals alone.")
    }

    func testTheOtherCasesAreUnchanged() {
        XCTAssertEqual(lead(factorCount: 1, withoutHRV: false), "Recovery is good at 73 based on last night's sleep alone.")
        XCTAssertEqual(lead(factorCount: 2, withoutHRV: false), "Recovery is good at 73.")
        XCTAssertEqual(lead(factorCount: 3, withoutHRV: false), "Recovery is good at 73.")
        XCTAssertFalse(TodaySynthesis.Input(newestDataAt: now, now: now).withoutSleepingHRV, "defaults to false")
    }
}
