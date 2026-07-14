import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the Wellness Balance / readiness capstone (#97). Controlled inputs;
/// asserts tier cut-offs, stress inversion, the vitals-status mapping, factor renormalisation
/// when a sub-score is absent, nil when nothing is available, and the trend deadband. No real
/// health values.
final class WellnessBalanceTests: XCTestCase {

    func testTierCutoffs() {
        XCTAssertEqual(WellnessBalance.Tier.of(85), .excellent)
        XCTAssertEqual(WellnessBalance.Tier.of(84), .good)
        XCTAssertEqual(WellnessBalance.Tier.of(60), .good)
        XCTAssertEqual(WellnessBalance.Tier.of(59), .needsImprovement)
    }

    func testGoodDayScoresHigh() {
        let r = WellnessBalance.score(.init(sleepScore: 90, overnightStress: 20,
                                            vitalsStatus: .normal, activityScore: 85))
        XCTAssertNotNil(r)
        XCTAssertGreaterThanOrEqual(r!.score, 85)
        XCTAssertEqual(r!.tier, .excellent)
        XCTAssertEqual(r!.factors.count, 4)
    }

    func testPoorDayScoresLow() {
        let r = WellnessBalance.score(.init(sleepScore: 45, overnightStress: 85,
                                            vitalsStatus: .anomaly, activityScore: 30))
        XCTAssertNotNil(r)
        XCTAssertLessThan(r!.score, 60)
        XCTAssertEqual(r!.tier, .needsImprovement)
    }

    func testGoodDayOutScoresPoorDay() {
        let good = WellnessBalance.score(.init(sleepScore: 88, overnightStress: 25,
                                               vitalsStatus: .normal, activityScore: 80))!
        let poor = WellnessBalance.score(.init(sleepScore: 50, overnightStress: 80,
                                               vitalsStatus: .watch, activityScore: 35))!
        XCTAssertGreaterThan(good.score, poor.score)
    }

    func testStressIsInvertedIntoRecovery() {
        // overnightStress is a SleepStress score clamped to [15, 90]; map that REAL range to a full
        // 0…1 recovery factor (not a compressed [0.10, 0.85]). Sleep held constant to isolate it.
        let calm = WellnessBalance.score(.init(sleepScore: 80, overnightStress: 15))!
        let tense = WellnessBalance.score(.init(sleepScore: 80, overnightStress: 90))!
        XCTAssertGreaterThan(calm.score, tense.score)
        XCTAssertEqual(calm.factors[.recovery]!, 1.0, accuracy: 0.0001)   // most-relaxed → full recovery
        XCTAssertEqual(tense.factors[.recovery]!, 0.0, accuracy: 0.0001)  // most-stressed → zero recovery
        // A mid-range stress lands mid-recovery: (90 − 52) / 75 = 0.5067.
        let mid = WellnessBalance.score(.init(sleepScore: 80, overnightStress: 52))!
        XCTAssertEqual(mid.factors[.recovery]!, 0.5067, accuracy: 0.001)
    }

    func testAnchoredScoreRequiresSleep() {
        // Activity (or stress) alone must NOT synthesise a readiness — the anchor requires a sleep
        // sub-score, so we never fabricate readiness from a weak signal.
        XCTAssertNil(WellnessBalance.anchoredScore(.init(activityScore: 60)))
        XCTAssertNil(WellnessBalance.anchoredScore(.init(overnightStress: 20, activityScore: 60)))
        XCTAssertNotNil(WellnessBalance.anchoredScore(.init(sleepScore: 80, activityScore: 60)))
        // The unanchored blender intentionally DOES return an activity-only result — this pins that
        // documented contract so the anchor policy can't silently move into it.
        XCTAssertNotNil(WellnessBalance.score(.init(activityScore: 60)))
    }

    func testVitalsStatusMapping() {
        XCTAssertEqual(WellnessBalance.vitalsFactor(.normal), 1.0)
        XCTAssertEqual(WellnessBalance.vitalsFactor(.watch), 0.5)
        XCTAssertEqual(WellnessBalance.vitalsFactor(.anomaly), 0.0)
    }

    func testMissingFactorsAreRenormalised() {
        // Only sleep present → the score equals the sleep sub-score (renormalised to 1 factor).
        let r = WellnessBalance.score(.init(sleepScore: 80))
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.factors.count, 1)
        XCTAssertEqual(r!.score, 80)
        // Sleep + activity only → weighted mean over just those two.
        let r2 = WellnessBalance.score(.init(sleepScore: 90, activityScore: 60))!
        XCTAssertEqual(r2.factors.count, 2)
        // 0.40*0.9 + 0.15*0.6 = 0.45 over 0.55 → 0.8181… → 82
        XCTAssertEqual(r2.score, 82)
    }

    func testNilWhenNoSubScores() {
        XCTAssertNil(WellnessBalance.score(.init()))
    }

    func testScoreAlwaysInRange() {
        let worst = WellnessBalance.score(.init(sleepScore: 0, overnightStress: 100,
                                                vitalsStatus: .anomaly, activityScore: 0))!
        XCTAssertEqual(worst.score, 0)
        let best = WellnessBalance.score(.init(sleepScore: 100, overnightStress: 1,
                                               vitalsStatus: .normal, activityScore: 100))!
        XCTAssertLessThanOrEqual(best.score, 100)
        XCTAssertGreaterThanOrEqual(best.score, 95)
    }

    func testTrendDeadband() {
        XCTAssertEqual(WellnessBalance.trend(today: 80, prior: [70, 72, 74]), .up)
        XCTAssertEqual(WellnessBalance.trend(today: 60, prior: [70, 72, 74]), .down)
        XCTAssertEqual(WellnessBalance.trend(today: 73, prior: [70, 72, 74]), .steady)
        XCTAssertEqual(WellnessBalance.trend(today: 80, prior: []), .steady)
    }
}
