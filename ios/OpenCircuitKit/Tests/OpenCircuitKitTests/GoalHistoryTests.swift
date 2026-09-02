import XCTest
@testable import OpenCircuitKit

/// Historical goal-ring completion (`GoalHistory`) — the derivation behind the ring history strip.
/// Every case here pins a decision that would otherwise be a silent lie on screen: an absent metric
/// must not read as a failed ring, a still-running today must not read as a broken streak, and the
/// weekday/weekend goal split must follow the HISTORICAL date, not today's.
final class GoalHistoryTests: XCTestCase {

    // A fixed UTC calendar so weekday arithmetic is deterministic wherever this runs.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    private let goals = GoalHistory.Goals(
        workdaySteps: 8_000, weekendSteps: 10_000,
        activeKcal: 300, activityMinutes: 30,
        workdaySleepMin: 420, weekendSleepMin: 480)

    /// A day where every ring is comfortably over its goal.
    private func fullDay(_ iso: String) -> GoalHistory.DayInput {
        GoalHistory.DayInput(date: day(iso), steps: 20_000, activeKcal: 600,
                             activityMinutes: 60, sleepMinutes: 600)
    }

    // MARK: - Goal selection

    func testWeekendGoalAppliesToTheHistoricalDateNotToday() {
        // 2026-08-15 is a Saturday, 2026-08-17 a Monday.
        XCTAssertEqual(goals.stepGoal(on: day("2026-08-15"), calendar: cal), 10_000)
        XCTAssertEqual(goals.stepGoal(on: day("2026-08-17"), calendar: cal), 8_000)
        XCTAssertEqual(goals.sleepGoalMinutes(on: day("2026-08-15"), calendar: cal), 480)
        XCTAssertEqual(goals.sleepGoalMinutes(on: day("2026-08-17"), calendar: cal), 420)
    }

    func testSameStepsCanCloseOnAWeekdayAndMissOnTheWeekend() {
        let steps = 9_000
        let days = GoalHistory.build(
            days: [GoalHistory.DayInput(date: day("2026-08-14"), steps: steps),   // Friday, goal 8000
                   GoalHistory.DayInput(date: day("2026-08-15"), steps: steps)],  // Saturday, goal 10000
            goals: goals, now: day("2026-08-20"), calendar: cal)
        XCTAssertTrue(days[0].met.contains(.steps))
        XCTAssertFalse(days[1].met.contains(.steps))
    }

    // MARK: - Absence is not failure

    func testAbsentMetricIsNotPresentNotMetAndDrawnEmpty() {
        let d = GoalHistory.build(
            days: [GoalHistory.DayInput(date: day("2026-08-17"), steps: 9_000)],
            goals: goals, now: day("2026-08-20"), calendar: cal)[0]
        XCTAssertEqual(d.present, [.steps])
        XCTAssertEqual(d.met, [.steps])
        XCTAssertEqual(d.ringsMet, 1)
        XCTAssertFalse(d.closedAll)
        // The three unmeasured rings read as empty, not as 0 % of a goal the user failed.
        XCTAssertEqual(d.fraction(for: .activeKcal), 0)
        XCTAssertEqual(d.fraction(for: .sleepMinutes), 0)
        XCTAssertTrue(d.hasData)
    }

    func testDayWithNoDataAtAllHasNoRingsAndCannotClose() {
        let d = GoalHistory.build(days: [GoalHistory.DayInput(date: day("2026-08-17"))],
                                  goals: goals, now: day("2026-08-20"), calendar: cal)[0]
        XCTAssertFalse(d.hasData)
        XCTAssertFalse(d.closedAll)
        XCTAssertNil(d.attainment)
    }

    func testAttainmentAveragesOnlyThePresentRings() {
        // Steps at half goal, sleep at goal; the other two never measured.
        let d = GoalHistory.build(
            days: [GoalHistory.DayInput(date: day("2026-08-17"), steps: 4_000, sleepMinutes: 420)],
            goals: goals, now: day("2026-08-20"), calendar: cal)[0]
        XCTAssertEqual(d.attainment ?? 0, 0.75, accuracy: 1e-9)   // (0.5 + 1.0) / 2, not / 4
    }

    func testExceedingAGoalIsCappedAtFullRing() {
        let d = GoalHistory.build(days: [fullDay("2026-08-17")], goals: goals,
                                  now: day("2026-08-20"), calendar: cal)[0]
        XCTAssertEqual(d.fraction(for: .steps), 1.0)
        XCTAssertEqual(d.attainment ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertTrue(d.closedAll)
    }

    // MARK: - Partial day

    func testTodayIsPartialAndAFutureDayToo() {
        let days = GoalHistory.build(
            days: [GoalHistory.DayInput(date: day("2026-08-17"), steps: 20_000),
                   GoalHistory.DayInput(date: day("2026-08-18"), steps: 100),
                   GoalHistory.DayInput(date: day("2026-08-19"), steps: 0)],
            goals: goals, now: day("2026-08-18").addingTimeInterval(3_600 * 10), calendar: cal)
        XCTAssertFalse(days[0].isPartial)
        XCTAssertTrue(days[1].isPartial)
        XCTAssertTrue(days[2].isPartial)
    }

    func testPartialDayIsNotCountedAsAClosedDay() {
        let s = GoalHistory.summarize(GoalHistory.build(
            days: [fullDay("2026-08-17"), fullDay("2026-08-18")],
            goals: goals, now: day("2026-08-18"), calendar: cal), calendar: cal)
        // Both closed, but the 18th is today → only the finished 17th counts in daysAllClosed.
        XCTAssertEqual(s.daysAllClosed, 1)
    }

    // MARK: - Summary + streaks

    func testStreakCountsConsecutiveAllClosedDays() {
        let s = GoalHistory.summarize(GoalHistory.build(
            days: [fullDay("2026-08-15"), fullDay("2026-08-16"), fullDay("2026-08-17")],
            goals: goals, now: day("2026-08-20"), calendar: cal), calendar: cal)
        XCTAssertEqual(s.currentStreak, 3)
        XCTAssertEqual(s.longestStreak, 3)
        XCTAssertEqual(s.daysAllClosed, 3)
        XCTAssertEqual(s.daysWithData, 3)
    }

    func testAMissedDayBreaksTheStreak() {
        let days = GoalHistory.build(
            days: [fullDay("2026-08-15"), fullDay("2026-08-16"),
                   GoalHistory.DayInput(date: day("2026-08-17"), steps: 10),   // missed
                   fullDay("2026-08-18")],
            goals: goals, now: day("2026-08-20"), calendar: cal)
        let s = GoalHistory.summarize(days, calendar: cal)
        XCTAssertEqual(s.currentStreak, 1)
        XCTAssertEqual(s.longestStreak, 2)
    }

    func testACalendarGapBreaksTheStreakEvenThoughTheRowsAreAdjacent() {
        // 08-16 is absent from the window entirely — consecutive means consecutive DAYS.
        let s = GoalHistory.summarize(GoalHistory.build(
            days: [fullDay("2026-08-15"), fullDay("2026-08-17")],
            goals: goals, now: day("2026-08-20"), calendar: cal), calendar: cal)
        XCTAssertEqual(s.currentStreak, 1)
        XCTAssertEqual(s.longestStreak, 1)
    }

    func testAnIncompleteTodayDoesNotResetYesterdaysStreak() {
        // Today has barely started; yesterday and the day before both closed.
        let s = GoalHistory.summarize(GoalHistory.build(
            days: [fullDay("2026-08-16"), fullDay("2026-08-17"),
                   GoalHistory.DayInput(date: day("2026-08-18"), steps: 200)],
            goals: goals, now: day("2026-08-18").addingTimeInterval(3_600 * 9), calendar: cal),
            calendar: cal)
        XCTAssertEqual(s.currentStreak, 2)
    }

    func testAnAlreadyClosedTodayExtendsTheStreak() {
        let s = GoalHistory.summarize(GoalHistory.build(
            days: [fullDay("2026-08-16"), fullDay("2026-08-17"), fullDay("2026-08-18")],
            goals: goals, now: day("2026-08-18").addingTimeInterval(3_600 * 20), calendar: cal),
            calendar: cal)
        XCTAssertEqual(s.currentStreak, 3)
    }

    func testAMissingDayDoesNotSilentlyCountAsClosed() {
        // A sync gap (no data) must break the streak rather than be papered over.
        let s = GoalHistory.summarize(GoalHistory.build(
            days: [fullDay("2026-08-15"),
                   GoalHistory.DayInput(date: day("2026-08-16")),   // nothing retained
                   fullDay("2026-08-17")],
            goals: goals, now: day("2026-08-20"), calendar: cal), calendar: cal)
        XCTAssertEqual(s.currentStreak, 1)
        XCTAssertEqual(s.daysWithData, 2)
    }

    func testPerRingCountsSeparateMetFromMeasured() {
        let days = GoalHistory.build(
            days: [GoalHistory.DayInput(date: day("2026-08-17"), steps: 20_000, sleepMinutes: 100),
                   GoalHistory.DayInput(date: day("2026-08-18"), steps: 100)],
            goals: goals, now: day("2026-08-20"), calendar: cal)
        let s = GoalHistory.summarize(days, calendar: cal)
        XCTAssertEqual(s.dataCounts[.steps], 2)
        XCTAssertEqual(s.metCounts[.steps], 1)
        XCTAssertEqual(s.dataCounts[.sleepMinutes], 1)   // measured once
        XCTAssertNil(s.metCounts[.sleepMinutes])         // never met
        XCTAssertNil(s.dataCounts[.activeKcal])          // never measured
    }

    // MARK: - Ordering / shape

    func testBuildSortsOldestToNewestAndNormalisesToStartOfDay() {
        let noon = day("2026-08-17").addingTimeInterval(3_600 * 12)
        let days = GoalHistory.build(
            days: [GoalHistory.DayInput(date: day("2026-08-18"), steps: 1),
                   GoalHistory.DayInput(date: noon, steps: 1)],
            goals: goals, now: day("2026-08-20"), calendar: cal)
        XCTAssertEqual(days.map(\.date), [day("2026-08-17"), day("2026-08-18")])
    }

    func testEmptyWindowSummarisesToZeroes() {
        let s = GoalHistory.summarize([], calendar: cal)
        XCTAssertEqual(s.daysWithData, 0)
        XCTAssertEqual(s.currentStreak, 0)
        XCTAssertEqual(s.longestStreak, 0)
    }

    // MARK: - Sleep credit (wake-day attribution + naps)

    private func at(_ iso: String, _ h: Int, _ m: Int = 0) -> Date {
        day(iso).addingTimeInterval(TimeInterval(h * 3_600 + m * 60))
    }

    func testNightIsCreditedToTheDayItEndedNotTheDayItStarted() {
        // In bed 23:40 on the 16th, awake 07:20 on the 17th → the 17th's Sleep ring.
        let credit = GoalHistory.sleepCreditByDay(
            nights: [.init(nightKey: day("2026-08-16"),
                           inBedStart: at("2026-08-16", 23, 40),
                           inBedEnd: at("2026-08-17", 7, 20),
                           asleepMinutes: 430)],
            naps: [], calendar: cal)
        XCTAssertEqual(credit[day("2026-08-17")], 430)
        XCTAssertNil(credit[day("2026-08-16")])
    }

    func testNightWhollyInsideOneDayStaysOnThatDay() {
        let credit = GoalHistory.sleepCreditByDay(
            nights: [.init(nightKey: day("2026-08-17"),
                           inBedStart: at("2026-08-17", 1, 0),
                           inBedEnd: at("2026-08-17", 8, 0),
                           asleepMinutes: 400)],
            naps: [], calendar: cal)
        XCTAssertEqual(credit[day("2026-08-17")], 400)
    }

    func testLegacyNightWithNoClockTimeFallsBackToItsNightKey() {
        // No in-bed window stored → credited to the night key, never drifted onto a later day.
        let credit = GoalHistory.sleepCreditByDay(
            nights: [.init(nightKey: day("2026-08-16"), inBedStart: nil, inBedEnd: nil,
                           asleepMinutes: 400)],
            naps: [], calendar: cal)
        XCTAssertEqual(credit[day("2026-08-16")], 400)
        XCTAssertNil(credit[day("2026-08-17")])
    }

    func testZeroMinuteNightContributesNoCreditKey() {
        let credit = GoalHistory.sleepCreditByDay(
            nights: [.init(nightKey: day("2026-08-16"),
                           inBedStart: at("2026-08-16", 23, 0),
                           inBedEnd: at("2026-08-17", 7, 0), asleepMinutes: 0)],
            naps: [], calendar: cal)
        XCTAssertTrue(credit.isEmpty)
    }

    func testNapAddsToTheDayItStartedOn() {
        let credit = GoalHistory.sleepCreditByDay(
            nights: [.init(nightKey: day("2026-08-16"),
                           inBedStart: at("2026-08-16", 23, 0),
                           inBedEnd: at("2026-08-17", 7, 0), asleepMinutes: 400)],
            naps: [.init(start: at("2026-08-17", 14, 0), end: at("2026-08-17", 14, 45),
                         asleepMinutes: 40)],
            calendar: cal)
        XCTAssertEqual(credit[day("2026-08-17")], 440)
    }

    func testNapOverlappingTheCreditedNightIsExcluded() {
        // A manually-added "nap" sitting inside the night must not double-count (no auto-detection
        // night guard exists for a manual nap).
        let credit = GoalHistory.sleepCreditByDay(
            nights: [.init(nightKey: day("2026-08-17"),
                           inBedStart: at("2026-08-17", 1, 0),
                           inBedEnd: at("2026-08-17", 8, 0), asleepMinutes: 400)],
            naps: [.init(start: at("2026-08-17", 3, 0), end: at("2026-08-17", 4, 0),
                         asleepMinutes: 55)],
            calendar: cal)
        XCTAssertEqual(credit[day("2026-08-17")], 400)
    }

    func testNapOnADayWithNoNightStillCounts() {
        let credit = GoalHistory.sleepCreditByDay(
            nights: [],
            naps: [.init(start: at("2026-08-17", 13, 0), end: at("2026-08-17", 14, 0),
                         asleepMinutes: 50)],
            calendar: cal)
        XCTAssertEqual(credit[day("2026-08-17")], 50)
    }

    func testCreditFeedsTheSleepRing() {
        // End-to-end: the wake-day credit is what the Sleep ring is scored on.
        let credit = GoalHistory.sleepCreditByDay(
            nights: [.init(nightKey: day("2026-08-16"),
                           inBedStart: at("2026-08-16", 23, 0),
                           inBedEnd: at("2026-08-17", 7, 30), asleepMinutes: 425)],
            naps: [], calendar: cal)
        let d = GoalHistory.build(
            days: [GoalHistory.DayInput(date: day("2026-08-17"),
                                        sleepMinutes: credit[day("2026-08-17")])],
            goals: goals, now: day("2026-08-20"), calendar: cal)[0]
        XCTAssertTrue(d.present.contains(.sleepMinutes))
        XCTAssertTrue(d.met.contains(.sleepMinutes))   // 425 ≥ the 420-minute weekday goal
    }

    // MARK: - Parity with the Today card

    /// The history builder must produce exactly the `DailyGoalProgress` the Goals card builds for
    /// the same numbers, or "today" and "today, in the strip" could disagree on screen.
    func testProgressMatchesTheGoalsCardConstruction() {
        let input = GoalHistory.DayInput(date: day("2026-08-17"), steps: 6_000, activeKcal: 150,
                                         activityMinutes: 20, sleepMinutes: 210)
        let built = GoalHistory.build(days: [input], goals: goals,
                                      now: day("2026-08-20"), calendar: cal)[0]
        let expected = DailyGoalProgress(
            steps:           GoalProgress(current: 6_000, goal: 8_000),
            activeKcal:      GoalProgress(current: 150, goal: 300),
            activityMinutes: GoalProgress(current: 20, goal: 30),
            sleepMinutes:    GoalProgress(current: 210, goal: 420))
        XCTAssertEqual(built.progress, expected)
    }
}
