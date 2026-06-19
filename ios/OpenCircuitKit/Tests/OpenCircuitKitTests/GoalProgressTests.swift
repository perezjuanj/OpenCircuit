import XCTest
@testable import OpenCircuitKit

final class GoalProgressTests: XCTestCase {

    // MARK: GoalProgress math

    func testFractionAtZeroIsZero() {
        let p = GoalProgress(current: 0, goal: 8000)
        XCTAssertEqual(p.fraction, 0, accuracy: 0.0001)
        XCTAssertFalse(p.met)
    }

    func testFractionAtHalf() {
        let p = GoalProgress(current: 4000, goal: 8000)
        XCTAssertEqual(p.fraction, 0.5, accuracy: 0.0001)
        XCTAssertFalse(p.met)
    }

    func testFractionCappedAt1() {
        let p = GoalProgress(current: 12000, goal: 8000)
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.0001)
        XCTAssertTrue(p.met)
    }

    func testFractionExactlyMet() {
        let p = GoalProgress(current: 8000, goal: 8000)
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.0001)
        XCTAssertTrue(p.met)
    }

    func testZeroGoalIsZeroFraction() {
        let p = GoalProgress(current: 100, goal: 0)
        XCTAssertEqual(p.fraction, 0, accuracy: 0.0001)
        XCTAssertFalse(p.met)
    }

    // MARK: Weekday / weekend selection

    /// Build a Date that falls on a given weekday (1=Sun…7=Sat) in a Gregorian calendar,
    /// guaranteed to be local-midnight regardless of timezone.
    private func dateOnWeekday(_ weekday: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        comps.weekday = weekday
        return cal.date(from: comps) ?? Date()
    }

    func testWeekendDetection() {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        let saturday = dateOnWeekday(7)  // 7 = Saturday in Gregorian
        XCTAssertTrue(GoalDefaults.isWeekend(saturday, calendar: cal))
    }

    func testWeekdayDetection() {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        let monday = dateOnWeekday(2)  // 2 = Monday in Gregorian
        XCTAssertFalse(GoalDefaults.isWeekend(monday, calendar: cal))
    }

    // MARK: Steps goal selection

    func testStepsGoalFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "GoalProgressTestsSuite")!
        defaults.removePersistentDomain(forName: "GoalProgressTestsSuite")
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        let monday = dateOnWeekday(2)   // Monday = weekday
        let goal = GoalDefaults.stepsGoal(for: monday, calendar: cal, defaults: defaults)
        XCTAssertEqual(goal, GoalDefaults.defaultWorkdaySteps)
    }

    func testWeekendStepsGoalDefault() {
        let defaults = UserDefaults(suiteName: "GoalProgressTestsSuiteW")!
        defaults.removePersistentDomain(forName: "GoalProgressTestsSuiteW")
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        let saturday = dateOnWeekday(7)   // Saturday = weekend
        let goal = GoalDefaults.stepsGoal(for: saturday, calendar: cal, defaults: defaults)
        XCTAssertEqual(goal, GoalDefaults.defaultWeekendSteps)
    }

    // MARK: DailyGoalProgress

    func testDailyProgressSummary() {
        let p = DailyGoalProgress(
            steps: GoalProgress(current: 6000, goal: 8000),
            activeKcal: GoalProgress(current: 150, goal: 300),
            activityMinutes: GoalProgress(current: 20, goal: 30),
            sleepMinutes: GoalProgress(current: 420, goal: 480)
        )
        XCTAssertEqual(p.steps.fraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(p.activeKcal.fraction, 0.5, accuracy: 0.0001)
        XCTAssertFalse(p.activityMinutes.met)
        XCTAssertFalse(p.sleepMinutes.met)
    }
}
