import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the daily Activity Score (#95). Controlled inputs; asserts tier
/// cut-offs, per-goal attainment capping, factor renormalisation when a goal is disabled, and
/// that an active day out-scores a sedentary one. No real health values.
final class ActivityScoreTests: XCTestCase {

    private func input(steps: Int = 0, stepGoal: Int = 10_000,
                       activeMinutes: Double = 0, activeMinutesGoal: Double = 30,
                       activeKcal: Double = 0, activeKcalGoal: Double = 500) -> ActivityScore.Input {
        .init(steps: steps, stepGoal: stepGoal,
              activeMinutes: activeMinutes, activeMinutesGoal: activeMinutesGoal,
              activeKcal: activeKcal, activeKcalGoal: activeKcalGoal)
    }

    func testTierCutoffs() {
        XCTAssertEqual(ActivityScore.Tier.of(85), .excellent)
        XCTAssertEqual(ActivityScore.Tier.of(84), .good)
        XCTAssertEqual(ActivityScore.Tier.of(70), .good)
        XCTAssertEqual(ActivityScore.Tier.of(69), .needsImprovement)
    }

    func testAllGoalsMetScoresHundred() {
        // Every goal met exactly → all factors 1.0 → score 100.
        let r = ActivityScore.score(input(steps: 10_000, activeMinutes: 30, activeKcal: 500))
        XCTAssertEqual(r.score, 100)
        XCTAssertEqual(r.tier, .excellent)
        XCTAssertEqual(r.factors.count, 3)
    }

    func testExceedingGoalIsCappedNotOverCredited() {
        // 3× every goal must still cap each factor at 1.0 → 100, never > 100.
        let r = ActivityScore.score(input(steps: 30_000, activeMinutes: 90, activeKcal: 1500))
        XCTAssertEqual(r.score, 100)
        for (_, v) in r.factors { XCTAssertLessThanOrEqual(v, 1.0) }
    }

    func testSedentaryDayScoresLow() {
        let r = ActivityScore.score(input(steps: 800, activeMinutes: 0, activeKcal: 20))
        XCTAssertLessThan(r.score, 20)
        XCTAssertEqual(r.tier, .needsImprovement)
    }

    func testActiveDayOutScoresSedentary() {
        let active = ActivityScore.score(input(steps: 9_000, activeMinutes: 28, activeKcal: 460))
        let sedentary = ActivityScore.score(input(steps: 1_200, activeMinutes: 2, activeKcal: 40))
        XCTAssertGreaterThan(active.score, sedentary.score)
    }

    func testStepsOnlyReflectsWeighting() {
        // Only the step goal met (0.45 of the weight) → ~45, and steps is the sole full factor.
        let r = ActivityScore.score(input(steps: 10_000, activeMinutes: 0, activeKcal: 0))
        XCTAssertEqual(r.score, 45)
        XCTAssertEqual(r.factors[.steps], 1.0)
        XCTAssertEqual(r.factors[.activeMinutes], 0.0)
    }

    func testDisabledGoalIsDroppedAndRenormalised() {
        // Active-kcal goal disabled (0) → that factor is absent; the remaining two renormalise.
        let r = ActivityScore.score(input(steps: 10_000, activeMinutes: 30, activeKcal: 0, activeKcalGoal: 0))
        XCTAssertEqual(r.factors.count, 2)
        XCTAssertNil(r.factors[.activeKcal])
        // Both present goals fully met → 100 despite the dropped factor.
        XCTAssertEqual(r.score, 100)
    }

    func testScoreAlwaysInRange() {
        let zero = ActivityScore.score(input(steps: 0, activeMinutes: 0, activeKcal: 0))
        XCTAssertGreaterThanOrEqual(zero.score, 0)
        XCTAssertLessThanOrEqual(zero.score, 100)
        // All goals disabled → no factors → defined, in-range, low.
        let noGoals = ActivityScore.score(input(stepGoal: 0, activeMinutesGoal: 0, activeKcalGoal: 0))
        XCTAssertEqual(noGoals.factors.count, 0)
        XCTAssertGreaterThanOrEqual(noGoals.score, 0)
        XCTAssertLessThanOrEqual(noGoals.score, 100)
    }
}
