// Daily goal settings — UserDefaults keys, defaults, and progress math (#77).
//
// Goals are APP-SIDE display only — no value is written to the ring. The ring's
// `TargetSyncModel` (type=0 step / 1 calorie / 2 sleep / 3 bedSchedule) and
// `watchStepTargetData` are out of scope (require the write-channel capture, #88).
//
// APK evidence: `workday_step_goal` / `weekend_step_goal` (pp.txt:111295);
// `calTarget`; `keySettingActivityDurationGoal`; `workdaySleepGoal` /
// `weekendSleepGoal`. WHO framing: 150–300 min/week activity.

import Foundation

// MARK: - Keys & defaults

public enum GoalDefaults {

    // Steps — weekday / weekend split
    public static let workdaySteps    = "goals.workdaySteps"
    public static let weekendSteps    = "goals.weekendSteps"

    // Active calories — single goal (no weekday/weekend in APK data)
    public static let activeKcal      = "goals.activeKcal"

    // Activity / exercise duration minutes — single goal
    public static let activityMinutes = "goals.activityMinutes"

    // Sleep duration — weekday / weekend split (minutes)
    public static let workdaySleepMin = "goals.workdaySleepMin"
    public static let weekendSleepMin = "goals.weekendSleepMin"

    // Defaults
    public static let defaultWorkdaySteps    = 8_000
    public static let defaultWeekendSteps    = 10_000
    public static let defaultActiveKcal      = 300.0
    public static let defaultActivityMinutes = 30.0          // WHO: 150 min/week ÷ 5
    public static let defaultWorkdaySleepMin = 7 * 60        // 7 h
    public static let defaultWeekendSleepMin = 8 * 60        // 8 h

    // MARK: Calendar helper

    /// Whether `date` is a weekend (Saturday or Sunday) in `calendar`.
    /// Sunday = weekday 1, Saturday = weekday 7 in Calendar.
    public static func isWeekend(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let wd = calendar.component(.weekday, from: date)
        return wd == 1 || wd == 7
    }

    // MARK: UserDefaults readers (shared between GoalsCardView + UserProfileSettingsView)

    public static func stepsGoal(for date: Date = Date(),
                                 calendar: Calendar = .current,
                                 defaults: UserDefaults = .standard) -> Int {
        let key = isWeekend(date, calendar: calendar) ? weekendSteps : workdaySteps
        return defaults.object(forKey: key) as? Int
            ?? (isWeekend(date, calendar: calendar) ? defaultWeekendSteps : defaultWorkdaySteps)
    }

    public static func sleepGoalMinutes(for date: Date = Date(),
                                        calendar: Calendar = .current,
                                        defaults: UserDefaults = .standard) -> Int {
        let key = isWeekend(date, calendar: calendar) ? weekendSleepMin : workdaySleepMin
        return defaults.object(forKey: key) as? Int
            ?? (isWeekend(date, calendar: calendar) ? defaultWeekendSleepMin : defaultWorkdaySleepMin)
    }
}

// MARK: - Progress

/// One metric's current value vs. its goal.
public struct GoalProgress: Equatable, Sendable {
    public let current: Double
    public let goal: Double

    public init(current: Double, goal: Double) {
        self.current = current
        self.goal = max(goal, 0)
    }

    /// Fraction towards the goal, clamped to [0, 1].
    public var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(current / goal, 1.0)
    }

    /// True when the goal is fully met (current ≥ goal).
    public var met: Bool { current >= goal && goal > 0 }
}

/// Today's progress across all four tracked goals.
public struct DailyGoalProgress: Equatable, Sendable {
    public let steps: GoalProgress
    public let activeKcal: GoalProgress
    public let activityMinutes: GoalProgress
    public let sleepMinutes: GoalProgress   // last night's sleep vs. tonight's goal

    public init(
        steps: GoalProgress,
        activeKcal: GoalProgress,
        activityMinutes: GoalProgress,
        sleepMinutes: GoalProgress
    ) {
        self.steps = steps
        self.activeKcal = activeKcal
        self.activityMinutes = activityMinutes
        self.sleepMinutes = sleepMinutes
    }
}
