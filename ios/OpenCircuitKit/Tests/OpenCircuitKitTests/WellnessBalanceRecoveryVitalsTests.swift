// Recovery with the Vitals Status verdict as its third factor (#396, decision 95a): the sleep anchor
// and the shipped weights stay, a missing verdict is dropped (never a 0), and an anomaly can only
// lower the score.

import XCTest
@testable import OpenCircuitKit

final class WellnessBalanceRecoveryVitalsTests: XCTestCase {

    private func recovery(_ sleep: Int?, _ stress: Int?, _ vitals: VitalsBaseline.Status?) throws -> WellnessBalance.Result {
        try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: sleep, overnightStress: stress, vitalsStatus: vitals))
    }

    // MARK: Each verdict

    func testEachVerdictAgainstSleepAndHRV() throws {
        // Sleep 85, stress 33: the two-factor score is 82 (pinned in WellnessBalanceRecoveryTests).
        XCTAssertEqual(try recovery(85, 33, nil).score, 82)
        XCTAssertEqual(try recovery(85, 33, .normal).score, 86)
        XCTAssertEqual(try recovery(85, 33, .watch).score, 74)
        XCTAssertEqual(try recovery(85, 33, .anomaly).score, 62)
    }

    func testEachVerdictAgainstSleepAlone() throws {
        XCTAssertEqual(try recovery(80, nil, nil).score, 80)
        XCTAssertEqual(try recovery(80, nil, .normal).score, 87)
        XCTAssertEqual(try recovery(80, nil, .watch).score, 70)
        XCTAssertEqual(try recovery(80, nil, .anomaly).score, 53)
    }

    func testTheVerdictIsAFactorOfItsOwn() throws {
        XCTAssertEqual(try recovery(85, 33, .normal).factors, [.sleep: 0.85, .recovery: 0.76, .vitals: 1.0])
        XCTAssertEqual(try recovery(85, 33, .watch).factors[.vitals], 0.5)
        XCTAssertEqual(try recovery(85, 33, .anomaly).factors[.vitals], 0.0)
        XCTAssertEqual(try recovery(80, nil, .normal).factors.count, 2)
        XCTAssertNil(try recovery(85, 33, .normal).factors[.activity], "activity stays out")
    }

    /// Normal never lowers, anomaly never raises, and the verdicts are ordered, over a grid of nights.
    func testTheVerdictMovesTheScoreTheRightWay() throws {
        for sleep in stride(from: 1, through: 100, by: 9) {
            for stress: Int? in [nil, 15, 40, 90] {
                let base = try recovery(sleep, stress, nil).score
                let normal = try recovery(sleep, stress, .normal).score
                let watch = try recovery(sleep, stress, .watch).score
                let anomaly = try recovery(sleep, stress, .anomaly).score
                XCTAssertGreaterThanOrEqual(normal, base, "sleep \(sleep), stress \(String(describing: stress))")
                XCTAssertLessThanOrEqual(anomaly, base, "sleep \(sleep), stress \(String(describing: stress))")
                XCTAssertGreaterThanOrEqual(normal, watch)
                XCTAssertGreaterThanOrEqual(watch, anomaly)
            }
        }
        // A perfect night with an anomaly is pulled down, by exactly the vitals share.
        XCTAssertEqual(try recovery(100, 15, nil).score, 100)
        XCTAssertEqual(try recovery(100, 15, .anomaly).score, 76)
    }

    // MARK: A missing verdict

    func testNoVerdictIsExactlyTheTwoFactorScore() {
        for sleep in stride(from: 0, through: 100, by: 7) {
            for stress: Int? in [nil, 15, 33, 50, 75, 90] {
                XCTAssertEqual(WellnessBalance.recoveryScore(sleepScore: sleep, overnightStress: stress, vitalsStatus: nil),
                               WellnessBalance.recoveryScore(sleepScore: sleep, overnightStress: stress))
            }
        }
    }

    func testAVerdictWithoutASleepScoreIsNoRecovery() {
        for v: VitalsBaseline.Status in [.normal, .watch, .anomaly] {
            XCTAssertNil(WellnessBalance.recoveryScore(sleepScore: nil, overnightStress: 33, vitalsStatus: v))
            XCTAssertNil(WellnessBalance.recoveryScore(sleepScore: nil, overnightStress: nil, vitalsStatus: v))
        }
    }

    // MARK: Tier edges

    func testTheTierEdgesHoldWithTheVerdict() throws {
        let top = try recovery(77, nil, .normal), below = try recovery(76, nil, .normal)
        XCTAssertEqual(top.score, 85)
        XCTAssertEqual(top.tier, .excellent)
        XCTAssertEqual(below.score, 84)
        XCTAssertEqual(below.tier, .good)
        let floor = try recovery(65, nil, .watch), under = try recovery(64, nil, .watch)
        XCTAssertEqual(floor.score, 60)
        XCTAssertEqual(floor.tier, .good)
        XCTAssertEqual(under.score, 59)
        XCTAssertEqual(under.tier, .needsImprovement)
    }

    // MARK: Shares

    func testTheThreeSharesComeFromTheWeightsAndSumTo100() {
        let shares = WellnessBalance.recoveryVitalsShares
        XCTAssertEqual(shares.sleep + shares.hrv + shares.vitals, 100)
        let s = WellnessBalance.factorWeights[.sleep]!, r = WellnessBalance.factorWeights[.recovery]!
        let v = WellnessBalance.factorWeights[.vitals]!
        XCTAssertEqual(shares.sleep, Int((s / (s + r + v) * 100).rounded()))
        XCTAssertEqual(shares.hrv, Int((r / (s + r + v) * 100).rounded()))
        XCTAssertEqual(shares, .init(sleep: 47, hrv: 29, vitals: 24))
        // The two-factor shares are untouched.
        XCTAssertEqual(WellnessBalance.recoveryShares, .init(sleep: 62, hrv: 38))
    }

    /// The vitals share is what an anomaly costs a perfect night (to the nearest point).
    func testTheVitalsShareIsWhatAnAnomalyCosts() throws {
        XCTAssertEqual(100 - (try recovery(100, 15, .anomaly).score), WellnessBalance.recoveryVitalsShares.vitals)
    }
}
