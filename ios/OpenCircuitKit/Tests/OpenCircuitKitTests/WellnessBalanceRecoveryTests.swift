import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for Recovery (#391, decision 93a): last night's sleep score plus overnight
/// recovery (sleeping HRV), with no activity and no vitals. Every value here is made up.
final class WellnessBalanceRecoveryTests: XCTestCase {

    /// Overnight stress 33 maps to an overnight-recovery factor of exactly 0.76 ((90 − 33) / 75).
    private let stressFor76 = 33

    func testAScoredNightWithSleepingHRVIsGoodAt82() throws {
        let r = try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: 85, overnightStress: stressFor76))
        XCTAssertEqual(r.factors[.recovery] ?? -1, 0.76, accuracy: 1e-9)
        // (0.40 · 0.85 + 0.25 · 0.76) / 0.65 = 0.8154 → 82
        XCTAssertEqual(r.score, 82)
        XCTAssertEqual(r.tier, .good)
        XCTAssertEqual(r.factors.count, 2)
    }

    func testSleepAloneScoresTheSleepScoreAtLowConfidence() throws {
        let r = try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: 52, overnightStress: nil))
        XCTAssertEqual(r.score, 52)
        XCTAssertEqual(r.tier, .needsImprovement)
        XCTAssertLessThanOrEqual(r.factors.count, 1, "rests on sleep alone, so the ring is dashed")
    }

    func testNoSleepScoreMeansNoRecovery() {
        XCTAssertNil(WellnessBalance.recoveryScore(sleepScore: nil, overnightStress: nil))
        XCTAssertNil(WellnessBalance.recoveryScore(sleepScore: nil, overnightStress: stressFor76),
                     "sleeping HRV alone never makes a Recovery score")
    }

    /// The activity term that made the old morning score dip is gone: whatever today's activity was,
    /// Recovery is the same number, and only sleep and overnight recovery ever enter it.
    func testRecoveryNeverCountsActivityOrVitals() throws {
        let recovery = try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: 85, overnightStress: stressFor76))
        for activity in [0, 19, 60, 100] {
            let withActivity = try XCTUnwrap(WellnessBalance.anchoredScore(.init(
                sleepScore: 85, overnightStress: stressFor76, activityScore: activity)))
            XCTAssertNotEqual(withActivity.score, recovery.score, "the old blend moved with activity \(activity)")
        }
        XCTAssertEqual(recovery.score, 82)
        XCTAssertEqual(Set(recovery.factors.keys), [.sleep, .recovery])
        XCTAssertNil(recovery.factors[.activity])
        XCTAssertNil(recovery.factors[.vitals])
    }

    /// Recovery is exactly the anchored blend over sleep and overnight stress, across the range.
    func testRecoveryIsTheAnchoredBlendOfSleepAndOvernightStress() {
        for sleep in stride(from: 0, through: 100, by: 7) {
            for stress: Int? in [nil, 15, 33, 50, 75, 90] {
                XCTAssertEqual(WellnessBalance.recoveryScore(sleepScore: sleep, overnightStress: stress),
                               WellnessBalance.anchoredScore(.init(sleepScore: sleep, overnightStress: stress)))
            }
        }
    }

    func testTheSharesComeFromTheWeightsAndSumTo100() {
        let shares = WellnessBalance.recoveryShares
        XCTAssertEqual(shares.sleep + shares.hrv, 100)
        let s = WellnessBalance.factorWeights[.sleep]!, r = WellnessBalance.factorWeights[.recovery]!
        XCTAssertEqual(shares.sleep, Int((s / (s + r) * 100).rounded()))
        XCTAssertEqual(shares, .init(sleep: 62, hrv: 38))
    }

    func testTiersAreTheShipped85And60() throws {
        XCTAssertEqual(try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: 85, overnightStress: nil)).tier, .excellent)
        XCTAssertEqual(try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: 84, overnightStress: nil)).tier, .good)
        XCTAssertEqual(try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: 60, overnightStress: nil)).tier, .good)
        XCTAssertEqual(try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: 59, overnightStress: nil)).tier, .needsImprovement)
    }
}
