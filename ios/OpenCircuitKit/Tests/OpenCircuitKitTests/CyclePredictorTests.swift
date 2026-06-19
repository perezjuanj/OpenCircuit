// Tests/OpenCircuitKitTests/CyclePredictorTests.swift — SYNTHETIC-ONLY tests for
// cycle prediction (#78). No real health values; controlled inputs with
// known expected outputs.

import XCTest
@testable import OpenCircuitKit

final class CyclePredictorTests: XCTestCase {

    // MARK: Helpers

    private let cal = Calendar.current

    private func daysAgo(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: Date()))!
    }

    private func daysFromNow(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: Date()))!
    }

    private func period(startDaysAgo: Int,
                        endDaysAgo: Int? = nil) -> CyclePredictor.PeriodEntry {
        CyclePredictor.PeriodEntry(
            start: daysAgo(startDaysAgo),
            end: endDaysAgo.map { daysAgo($0) }
        )
    }

    // MARK: cycleStats — minimum history guard

    func testCycleStatsNilWhenEmpty() {
        XCTAssertNil(CyclePredictor.cycleStats(from: []))
    }

    func testCycleStatsNilWhenOnePeriod() {
        XCTAssertNil(CyclePredictor.cycleStats(from: [period(startDaysAgo: 30)]))
    }

    // MARK: cycleStats — interval math

    func testCycleStats_SingleInterval_28Days() {
        let periods = [period(startDaysAgo: 28), period(startDaysAgo: 0)]
        let stats = CyclePredictor.cycleStats(from: periods)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats!.avgCycleLengthDays, 28, accuracy: 0.01)
        XCTAssertEqual(stats!.sampleCount, 1)
    }

    func testCycleStats_MultipleIntervals_Average() {
        // 56 days ago, 28 days ago, today → two 28-day cycles
        let periods = [
            period(startDaysAgo: 56),
            period(startDaysAgo: 28),
            period(startDaysAgo: 0),
        ]
        let stats = CyclePredictor.cycleStats(from: periods)!
        XCTAssertEqual(stats.avgCycleLengthDays, 28, accuracy: 0.1)
        XCTAssertEqual(stats.sampleCount, 2)
    }

    func testCycleStats_UnequalIntervals_TrueAverage() {
        // 56 + 28 → intervals: 28, 28; but vary: 62 + 28 → intervals 34, 28 → avg 31
        let periods = [
            period(startDaysAgo: 62),
            period(startDaysAgo: 28),
            period(startDaysAgo: 0),
        ]
        let stats = CyclePredictor.cycleStats(from: periods)!
        XCTAssertEqual(stats.avgCycleLengthDays, 31, accuracy: 0.1)
    }

    // MARK: cycleStats — out-of-range interval exclusion

    func testCycleStats_TooShortInterval_Excluded() {
        // 15 days → below minCycleLengthDays (21) → no valid interval → nil
        let periods = [period(startDaysAgo: 15), period(startDaysAgo: 0)]
        XCTAssertNil(CyclePredictor.cycleStats(from: periods))
    }

    func testCycleStats_TooLongInterval_Excluded() {
        // 50 days → above maxCycleLengthDays (45) → excluded → nil
        let periods = [period(startDaysAgo: 50), period(startDaysAgo: 0)]
        XCTAssertNil(CyclePredictor.cycleStats(from: periods))
    }

    func testCycleStats_MixedValidity_OnlyValidIncluded() {
        // Three periods: interval 1 = 15 days (invalid), interval 2 = 28 days (valid)
        let periods = [
            period(startDaysAgo: 43),
            period(startDaysAgo: 28),  // 15 days after prev — invalid
            period(startDaysAgo: 0),   // 28 days after prev — valid
        ]
        let stats = CyclePredictor.cycleStats(from: periods)!
        XCTAssertEqual(stats.avgCycleLengthDays, 28, accuracy: 0.1)
        XCTAssertEqual(stats.sampleCount, 1)
    }

    // MARK: cycleStats — period duration

    func testCycleStats_AvgDurationFromCompletedPeriods() {
        // One completed period (5 days), one ongoing
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(30), end: daysAgo(25))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let stats = CyclePredictor.cycleStats(from: [p1, p2])!
        XCTAssertNotNil(stats.avgPeriodDurationDays)
        XCTAssertEqual(stats.avgPeriodDurationDays!, 5, accuracy: 0.1)
    }

    func testCycleStats_NilDurationWhenNoneCompleted() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let stats = CyclePredictor.cycleStats(from: [p1, p2])!
        XCTAssertNil(stats.avgPeriodDurationDays)
    }

    // MARK: predict — nil guard

    func testPredictNilBelowMinimum() {
        XCTAssertNil(CyclePredictor.predict(from: [period(startDaysAgo: 30)]))
        XCTAssertNil(CyclePredictor.predict(from: []))
    }

    // MARK: predict — date math

    func testPredict_28DayCycle_NextPeriodDate() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        // Next period ≈ 28 days from now (from start-of-today)
        let expected = daysFromNow(28)
        XCTAssertEqual(cal.startOfDay(for: pred.nextPeriodStart), expected)
        XCTAssertEqual(pred.avgCycleLengthDays, 28, accuracy: 0.01)
    }

    func testPredict_OvulationIs14DaysBeforeNextPeriod() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        let expectedOvulation = cal.startOfDay(for: pred.nextPeriodStart)
            .addingTimeInterval(-Double(CyclePredictor.lutealPhaseDays) * 86_400)
        XCTAssertEqual(cal.startOfDay(for: pred.ovulationEstimate), expectedOvulation)
        XCTAssertEqual(cal.startOfDay(for: pred.fertileWindowEnd), expectedOvulation,
                       "fertileWindowEnd == ovulation day")
    }

    func testPredict_FertileWindowStartIs5DaysBeforeOvulation() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        let expectedStart = cal.startOfDay(for: pred.ovulationEstimate)
            .addingTimeInterval(-Double(CyclePredictor.fertileWindowDaysBeforeOvulation) * 86_400)
        XCTAssertEqual(cal.startOfDay(for: pred.fertileWindowStart), expectedStart)
    }

    func testPredict_DefaultPeriodDuration_5Days() {
        // No completed periods → default 5-day duration
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        let durDays = pred.nextPeriodEnd.timeIntervalSince(pred.nextPeriodStart) / 86_400
        XCTAssertEqual(durDays, 5, accuracy: 0.01)
    }

    func testPredict_RollsForwardWhenLoggingWentStale() {
        // User logged two cycles long ago then stopped (last period 90 days ago, 28-day cycle).
        // The naive next-period (last + 28d) is in the PAST; predict() must roll it forward so
        // the "next" period and its ovulation/fertile window are all in the FUTURE.
        let now = cal.startOfDay(for: Date())
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(118))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(90))
        let pred = CyclePredictor.predict(from: [p1, p2], now: now)!

        XCTAssertGreaterThan(pred.nextPeriodStart, now, "next period must be in the future")
        XCTAssertGreaterThan(pred.ovulationEstimate, now, "ovulation must be in the future")
        XCTAssertGreaterThan(pred.fertileWindowStart, now, "fertile window must be in the future")
        // It must be the FIRST future occurrence: rolling back one whole cycle lands at/before now.
        let oneCycle = pred.avgCycleLengthDays * 86_400
        XCTAssertLessThan(pred.nextPeriodStart.addingTimeInterval(-oneCycle), now,
                          "must not over-roll past the first future cycle")
    }

    func testPredict_DoesNotRollForwardWhenAlreadyFuture() {
        // Last period today → naive next (today + 28d) is already future → no roll-forward.
        let now = cal.startOfDay(for: Date())
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2], now: now)!
        XCTAssertEqual(cal.startOfDay(for: pred.nextPeriodStart), daysFromNow(28))
    }

    func testPredict_UsesLoggedPeriodDuration() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28), end: daysAgo(24))  // 4 days
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        let durDays = pred.nextPeriodEnd.timeIntervalSince(pred.nextPeriodStart) / 86_400
        XCTAssertEqual(durDays, 4, accuracy: 0.1)
    }

    // MARK: predict — skin-temp corroboration

    func testTempCorroborated_WithSufficientRise() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred0 = CyclePredictor.predict(from: [p1, p2])!

        // Place two rising nights within ±3 days of the predicted ovulation
        let ov = pred0.ovulationEstimate
        let deviations: [(night: Date, offsetC: Double)] = [
            (night: ov.addingTimeInterval(-1 * 86_400), offsetC: 0.3),
            (night: ov.addingTimeInterval( 1 * 86_400), offsetC: 0.4),
        ]
        let pred = CyclePredictor.predict(from: [p1, p2], skinTempDeviations: deviations)!
        XCTAssertTrue(pred.tempCorroborated)
    }

    func testTempNotCorroborated_OnlyOneRisingNight() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred0 = CyclePredictor.predict(from: [p1, p2])!

        let ov = pred0.ovulationEstimate
        let deviations: [(night: Date, offsetC: Double)] = [
            (night: ov, offsetC: 0.5),           // only one night
        ]
        let pred = CyclePredictor.predict(from: [p1, p2], skinTempDeviations: deviations)!
        XCTAssertFalse(pred.tempCorroborated, "need ≥ 2 nights to corroborate")
    }

    func testTempNotCorroborated_RiseBelowThreshold() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred0 = CyclePredictor.predict(from: [p1, p2])!

        let ov = pred0.ovulationEstimate
        // Offsets present but below threshold (0.2 °C)
        let deviations: [(night: Date, offsetC: Double)] = [
            (night: ov.addingTimeInterval(-86_400), offsetC: 0.1),
            (night: ov, offsetC: 0.05),
        ]
        let pred = CyclePredictor.predict(from: [p1, p2], skinTempDeviations: deviations)!
        XCTAssertFalse(pred.tempCorroborated)
    }

    func testTempNotCorroborated_RiseOutsideWindow() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred0 = CyclePredictor.predict(from: [p1, p2])!

        let ov = pred0.ovulationEstimate
        // Rising nights are 7 days away — outside the ±3-day window
        let deviations: [(night: Date, offsetC: Double)] = [
            (night: ov.addingTimeInterval(-7 * 86_400), offsetC: 0.5),
            (night: ov.addingTimeInterval( 7 * 86_400), offsetC: 0.5),
        ]
        let pred = CyclePredictor.predict(from: [p1, p2], skinTempDeviations: deviations)!
        XCTAssertFalse(pred.tempCorroborated)
    }

    // MARK: day-classification helpers

    func testIsLoggedPeriodDay() {
        let p = CyclePredictor.PeriodEntry(start: daysAgo(5), end: daysAgo(2))
        XCTAssertTrue(CyclePredictor.isLoggedPeriodDay(daysAgo(5), entries: [p]))
        XCTAssertTrue(CyclePredictor.isLoggedPeriodDay(daysAgo(3), entries: [p]))
        XCTAssertTrue(CyclePredictor.isLoggedPeriodDay(daysAgo(2), entries: [p]))
        XCTAssertFalse(CyclePredictor.isLoggedPeriodDay(daysAgo(1), entries: [p]))
        XCTAssertFalse(CyclePredictor.isLoggedPeriodDay(daysAgo(6), entries: [p]))
    }

    func testIsLoggedPeriodDay_NoEnd_OnlyStartDay() {
        let p = CyclePredictor.PeriodEntry(start: daysAgo(3))
        XCTAssertTrue(CyclePredictor.isLoggedPeriodDay(daysAgo(3), entries: [p]))
        XCTAssertFalse(CyclePredictor.isLoggedPeriodDay(daysAgo(2), entries: [p]))
    }

    func testIsInPredictedPeriod() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        let duringPred = cal.startOfDay(for: pred.nextPeriodStart)
        XCTAssertTrue(CyclePredictor.isInPredictedPeriod(duringPred, prediction: pred))
        XCTAssertFalse(CyclePredictor.isInPredictedPeriod(daysAgo(100), prediction: pred))
    }

    func testIsInFertileWindow() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        let duringFertile = pred.fertileWindowStart.addingTimeInterval(86_400)
        XCTAssertTrue(CyclePredictor.isInFertileWindow(duringFertile, prediction: pred))
        XCTAssertFalse(CyclePredictor.isInFertileWindow(daysAgo(100), prediction: pred))
    }

    func testIsOvulationDay() {
        let p1 = CyclePredictor.PeriodEntry(start: daysAgo(28))
        let p2 = CyclePredictor.PeriodEntry(start: daysAgo(0))
        let pred = CyclePredictor.predict(from: [p1, p2])!

        XCTAssertTrue(CyclePredictor.isOvulationDay(pred.ovulationEstimate, prediction: pred))
        XCTAssertFalse(CyclePredictor.isOvulationDay(daysAgo(100), prediction: pred))
    }
}
