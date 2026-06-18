// Daily goal progress card (#77) — steps, active calories, activity minutes, sleep.
//
// Goals are APP-SIDE ONLY. No values are written to the ring. Activity-minute goal
// sharpens once the activity-epoch payload is decoded (#93); the current estimate
// is the basic elevated-HR threshold from ExerciseMinutes.swift (#82).
//
// APK evidence: `TargetSyncModel` type 0=step / 1=calorie / 2=sleep / 3=bedSchedule;
// `workday_step_goal` / `weekend_step_goal` (pp.txt:111295); `calTarget`;
// `keySettingActivityDurationGoal`; `workdaySleepGoal` / `weekendSleepGoal`.

import SwiftUI
import SwiftData
import OpenRingKit

struct GoalsCardView: View {

    // MARK: Goal settings (shared with UserProfileSettingsView / GoalDefaults)
    @AppStorage(GoalDefaults.workdaySteps)    private var workdaySteps    = GoalDefaults.defaultWorkdaySteps
    @AppStorage(GoalDefaults.weekendSteps)    private var weekendSteps    = GoalDefaults.defaultWeekendSteps
    @AppStorage(GoalDefaults.activeKcal)      private var activeKcalGoal  = GoalDefaults.defaultActiveKcal
    @AppStorage(GoalDefaults.activityMinutes) private var actMinGoal      = GoalDefaults.defaultActivityMinutes
    @AppStorage(GoalDefaults.workdaySleepMin) private var workdaySleepMin = GoalDefaults.defaultWorkdaySleepMin
    @AppStorage(GoalDefaults.weekendSleepMin) private var weekendSleepMin = GoalDefaults.defaultWeekendSleepMin

    // Profile (for maxHR → exercise threshold, and the step/distance active-calorie estimate)
    @AppStorage("userProfile.age") private var age = 35
    @AppStorage("userProfile.weightKg") private var weightKg = 70.0
    @AppStorage("userProfile.heightCm") private var heightCm = 170.0
    @AppStorage("userProfile.sex") private var sexRaw = BiologicalSex.male.rawValue

    // MARK: Data queries (bounded — no unbounded fetches)
    /// Today's step rollup.
    @Query private var todayDaily: [StoredDaily]
    /// Today's HR samples for active-kcal + exercise-minutes estimates.
    @Query private var todayHR: [StoredSample]
    /// Most recent sleep summary for last-night's sleep duration + sleep window exclusion.
    @Query private var latestSleep: [StoredSleepSummary]

    init() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let hrKind = MetricKind.heartRate.rawValue

        _todayDaily = Query(
            filter: #Predicate<StoredDaily> { $0.day == dayStart },
            sort: \.day)

        // Count ALL of today's HR (no upper-hour cap) so this card matches CaloriesCardView and
        // doesn't lag up to 59 min behind it — e.g. right after an on-demand measurement. The
        // stable `dayStart` lower bound already keeps the @Query descriptor stable.
        _todayHR = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hrKind && $0.start >= dayStart && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)]))

        var sleepDesc = FetchDescriptor<StoredSleepSummary>(
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        sleepDesc.fetchLimit = 1
        _latestSleep = Query(sleepDesc)
    }

    // MARK: Computed values

    private var stepsGoal: Int {
        GoalDefaults.isWeekend() ? weekendSteps : workdaySteps
    }

    private var currentSteps: Int { todayDaily.first?.steps ?? 0 }

    private var profile: UserProfile {
        UserProfile(age: age, weightKg: max(weightKg, 1), heightCm: max(heightCm, 1),
                    sex: BiologicalSex(rawValue: sexRaw) ?? .male)
    }

    /// Active kcal today — the larger of the HR-TRIMP estimate (sparse; ~0 without dense HR) and a
    /// step/distance estimate, so a day with walking still shows nonzero active calories. Estimate.
    private var currentActiveKcal: Double {
        let samples = todayHR.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let hrKcal = Calories.activeKcal(hrSamples: samples, maxHR: max(220 - age, 1))
        let stepKcal = Calories.activeKcalFromSteps(steps: currentSteps, profile: profile)
        return max(hrKcal, stepKcal)
    }

    private var currentActivityMin: Double {
        let samples = todayHR.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let maxHR = max(220 - age, 1)
        let sleepWindow: DateInterval? = latestSleep.first.flatMap { s in
            guard s.inBedStart > Date.distantPast else { return nil }
            return DateInterval(start: s.inBedStart, end: s.inBedEnd)
        }
        return ExerciseMinutes.estimate(hrSamples: samples, maxHR: maxHR, sleepWindow: sleepWindow)
    }

    private var lastNightSleepMin: Int { latestSleep.first?.asleepMin ?? 0 }

    private var sleepGoalMin: Int {
        GoalDefaults.isWeekend() ? weekendSleepMin : workdaySleepMin
    }

    private var progress: DailyGoalProgress {
        DailyGoalProgress(
            steps:           GoalProgress(current: Double(currentSteps),     goal: Double(stepsGoal)),
            activeKcal:      GoalProgress(current: currentActiveKcal,        goal: activeKcalGoal),
            activityMinutes: GoalProgress(current: currentActivityMin,       goal: actMinGoal),
            sleepMinutes:    GoalProgress(current: Double(lastNightSleepMin), goal: Double(sleepGoalMin))
        )
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "target").foregroundStyle(.green)
                Text("DAILY GOALS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                goalRing(progress: progress.steps,
                         label: "Steps",
                         current: "\(currentSteps.formatted())",
                         goal: "\(stepsGoal.formatted())",
                         color: .green)
                goalRing(progress: progress.activeKcal,
                         label: "Active kcal\u{B9}",
                         current: "\(Int(currentActiveKcal))",
                         goal: "\(Int(activeKcalGoal))",
                         color: .orange)
                goalRing(progress: progress.activityMinutes,
                         label: "Move min\u{B9}",
                         current: "\(Int(currentActivityMin))",
                         goal: "\(Int(actMinGoal))",
                         color: .blue)
                goalRing(progress: progress.sleepMinutes,
                         label: "Sleep",
                         current: formatDuration(lastNightSleepMin),
                         goal: formatDuration(sleepGoalMin),
                         color: .purple)
            }
            Text("\u{B9} Active calories & activity minutes are estimates (active kcal from heart rate where available, else steps × distance; minutes from an elevated-HR threshold). Full accuracy follows the ring activity-payload decode.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func goalRing(progress p: GoalProgress, label: String,
                          current: String, goal: String, color: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: p.fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: p.fraction)
                if p.met {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color)
                } else {
                    Text("\(Int(p.fraction * 100))%")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
            Text(current)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(p.met ? color : .primary)
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("/ \(goal)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h\(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
