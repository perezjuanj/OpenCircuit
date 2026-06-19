import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the 6-factor composite Sleep Score (#70). Controlled inputs;
/// asserts tier cut-offs, factor renormalisation when optional inputs are absent, and that a
/// good night out-scores a poor one. No real health values.
final class SleepScoreCompositeTests: XCTestCase {

    private let h = 3600.0

    func testTierCutoffs() {
        XCTAssertEqual(SleepScore.Tier.of(85), .excellent)
        XCTAssertEqual(SleepScore.Tier.of(84), .good)
        XCTAssertEqual(SleepScore.Tier.of(70), .good)
        XCTAssertEqual(SleepScore.Tier.of(69), .needsImprovement)
    }

    func testDurationOnlyScoreStillGraded() {
        // The ported duration-only piece is preserved (graded, not a 0/100 step — #28).
        XCTAssertEqual(SleepScore.score(durationSeconds: 4 * 3600), 50, accuracy: 0.001)
        XCTAssertEqual(SleepScore.score(durationSeconds: 8 * 3600), 100, accuracy: 0.001)
    }

    func testGoodNightScoresHigh() {
        // 8 h asleep, little awake, healthy deep+rem, high efficiency, low HR, on baseline.
        let input = SleepScore.CompositeInput(
            totalAsleep: 8 * h, timeAwake: 10 * 60, efficiency: 0.94,
            deep: 1.5 * h, light: 4.5 * h, rem: 2 * h,
            restingHR: 48, tempOffsetC: 0.1)
        let c = SleepScore.composite(input)
        XCTAssertGreaterThanOrEqual(c.score, 85)
        XCTAssertEqual(c.tier, .excellent)
        XCTAssertEqual(c.factors.count, 6, "all six factors present")
    }

    func testPoorNightScoresLow() {
        // 4 h asleep, lots awake, scant deep/rem, poor efficiency, high HR, big temp deviation.
        let input = SleepScore.CompositeInput(
            totalAsleep: 4 * h, timeAwake: 90 * 60, efficiency: 0.55,
            deep: 0.2 * h, light: 3.7 * h, rem: 0.1 * h,
            restingHR: 78, tempOffsetC: 1.5)
        let c = SleepScore.composite(input)
        XCTAssertLessThan(c.score, 60)
        XCTAssertEqual(c.tier, .needsImprovement)
    }

    func testGoodNightOutScoresPoorNight() {
        let good = SleepScore.composite(.init(totalAsleep: 8 * h, timeAwake: 10 * 60,
            efficiency: 0.93, deep: 1.5 * h, light: 4.5 * h, rem: 2 * h))
        let poor = SleepScore.composite(.init(totalAsleep: 4 * h, timeAwake: 80 * 60,
            efficiency: 0.6, deep: 0.2 * h, light: 3.7 * h, rem: 0.1 * h))
        XCTAssertGreaterThan(good.score, poor.score)
    }

    func testMissingOptionalFactorsAreRenormalised() {
        // Without HR + temp, only 4 factors are present and the score still spans 0…100.
        let input = SleepScore.CompositeInput(
            totalAsleep: 8 * h, timeAwake: 10 * 60, efficiency: 0.93,
            deep: 1.5 * h, light: 4.5 * h, rem: 2 * h)   // no restingHR / tempOffsetC
        let c = SleepScore.composite(input)
        XCTAssertEqual(c.factors.count, 4)
        XCTAssertNil(c.factors[.heartRate])
        XCTAssertNil(c.factors[.temperature])
        XCTAssertGreaterThanOrEqual(c.score, 0)
        XCTAssertLessThanOrEqual(c.score, 100)
        XCTAssertGreaterThanOrEqual(c.score, 85, "a strong night still scores high without HR/temp")
    }

    func testScoreAlwaysInRange() {
        let zero = SleepScore.composite(.init(totalAsleep: 0, timeAwake: 8 * h, efficiency: 0,
            deep: 0, light: 0, rem: 0))
        XCTAssertGreaterThanOrEqual(zero.score, 0)
        XCTAssertLessThanOrEqual(zero.score, 100)
    }
}
