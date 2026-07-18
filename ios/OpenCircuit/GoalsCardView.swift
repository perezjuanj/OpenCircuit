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
import OpenCircuitKit

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
    /// Today's naps (#nap-parity) — folded into the daily sleep total, matching RingConn's
    /// sleepNapAvgTimeLength. Detected OUTSIDE the main night, so no double-count.
    @Query private var todayNaps: [StoredNap]

    init() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let hrKind = MetricKind.heartRate.rawValue

        _todayNaps = Query(FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.start >= dayStart },
            sortBy: [SortDescriptor(\.start, order: .forward)]))

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

    // Active-kcal + exercise-minutes are HELD AS STATE and recomputed OFF the render path in
    // `.task(id:)` below — NOT read in `body`. They were computed vars that `body` evaluated ~10× per
    // pass (`progress` alone is read 4×, each rebuilding both), running the O(n) analytics over the
    // unbounded `todayHR` SYNCHRONOUSLY inside the background scene-update layout when a workout's
    // `stop()` batch-ingest invalidated the @Query — that blew the 10 s scene-update watchdog
    // (0x8BADF00D). As @State the body renders instantly and the analysis runs once per data change.
    // (Same fix as VitalsStatusCardView.)
    @State private var cachedActiveKcal: Double = 0
    @State private var cachedActivityMin: Double = 0
    /// Daily Activity Score (#95) — the weighted goal-attainment of the three activity rings
    /// below (steps, active kcal, exercise minutes). Held as @State and computed in the SAME
    /// off-main `.task` as the two estimates it consumes, so the score never runs analytics on
    /// the render / scene-update path. nil until the first compute lands.
    @State private var cachedActivityScore: ActivityScore.Result?

    /// Identity for the recompute `.task` — changes only when an input to the two estimates changes,
    /// so they re-run on new data (HR count grows, steps, profile, or last night) and never on an
    /// unrelated re-render.
    private var goalsInputsKey: String {
        "\(todayHR.count)|\(currentSteps)|\(age)|\(weightKg)|\(heightCm)|\(sexRaw)|"
        + "\(latestSleep.first?.night.timeIntervalSince1970 ?? 0)"
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

    /// True when the newest stored night actually ended TODAY, so its minutes may be credited to
    /// today's Sleep ring. A days-old night (no overnight sync landed) is NOT credited — the ring
    /// stays empty rather than silently reading a stale night as last night (#147). Uses the SAME
    /// recency test as the Sleep card's missed-night banner (`MissedNight.endedToday`), so the two
    /// surfaces can never disagree about what counts as last night.
    private var sleepCredited: Bool {
        guard let s = latestSleep.first else { return false }
        let inBedEnd = s.inBedEnd > s.inBedStart ? s.inBedEnd : nil
        return MissedNight.endedToday(inBedEnd: inBedEnd, nightKey: s.night)
    }

    /// Asleep minutes credited to today's ring — the stored night's `asleepMin` only when it ended
    /// today, else 0 (empty ring). Don't gate on `asleepMin > 0`: a stale night has positive
    /// minutes too, so recency (not magnitude) is what decides.
    /// The credited night's in-bed window, when a night ended today. Naps overlapping it are excluded
    /// from the fold-in so they can never double-count against the night (a MANUAL nap has no
    /// auto-detection night guard, so this exclusion is required, not just belt-and-suspenders).
    private var creditedNightInterval: DateInterval? {
        guard sleepCredited, let s = latestSleep.first, s.inBedEnd > s.inBedStart else { return nil }
        return DateInterval(start: s.inBedStart, end: s.inBedEnd)
    }
    /// Today's nap sleep (#nap-parity), folded into the daily sleep total per RingConn — excluding any
    /// nap overlapping the credited night.
    private var napAsleepMin: Int {
        todayNaps.reduce(0) { sum, nap in
            if let n = creditedNightInterval, nap.effectiveStart < n.end && nap.effectiveEnd > n.start { return sum }
            return sum + nap.asleepMin
        }
    }
    /// Credited daily sleep = last night (if it ended today) + today's non-overlapping naps.
    private var creditedLastNightMin: Int {
        (sleepCredited ? (latestSleep.first?.asleepMin ?? 0) : 0) + napAsleepMin
    }
    /// True when there's any sleep to credit today (a night ended today, or a nap was logged).
    private var hasSleepCredit: Bool { sleepCredited || napAsleepMin > 0 }

    private var sleepGoalMin: Int {
        GoalDefaults.isWeekend() ? weekendSleepMin : workdaySleepMin
    }

    private var progress: DailyGoalProgress {
        DailyGoalProgress(
            steps:           GoalProgress(current: Double(currentSteps),     goal: Double(stepsGoal)),
            activeKcal:      GoalProgress(current: cachedActiveKcal,         goal: activeKcalGoal),
            activityMinutes: GoalProgress(current: cachedActivityMin,        goal: actMinGoal),
            sleepMinutes:    GoalProgress(current: Double(creditedLastNightMin), goal: Double(sleepGoalMin))
        )
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "target").foregroundStyle(.green)
                Text("DAILY GOALS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let s = cachedActivityScore {
                HStack(alignment: .center, spacing: 8) {
                    Text("\(s.score)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(activityTierColor(s.tier))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Activity Score\u{B9}").font(.caption.weight(.semibold))
                        Text(activityTierLabel(s.tier)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Activity Score, estimate, \(s.score) out of 100, \(activityTierLabel(s.tier))")
            }
            HStack(spacing: 16) {
                goalRing(progress: progress.steps,
                         label: "Steps",
                         current: "\(currentSteps.formatted())",
                         goal: "\(stepsGoal.formatted())",
                         color: .green)
                goalRing(progress: progress.activeKcal,
                         label: "Active kcal est.",
                         current: "\(Int(cachedActiveKcal))",
                         goal: "\(Int(activeKcalGoal))",
                         color: .orange)
                goalRing(progress: progress.activityMinutes,
                         label: "Elevated HR\u{B9}",
                         current: "\(Int(cachedActivityMin))",
                         goal: "\(Int(actMinGoal))",
                         color: .blue)
                goalRing(progress: progress.sleepMinutes,
                         label: "Sleep",
                         // "—" (not "0m") when no night ended today, so an empty ring reads as
                         // "no data yet", never "0 minutes slept" (#147).
                         current: hasSleepCredit ? formatDuration(creditedLastNightMin) : "—",
                         goal: formatDuration(sleepGoalMin),
                         color: .purple)
            }
            Text("\u{B9} Activity Score is an on-device estimate — the weighted attainment of your step, active-calorie & elevated-HR goals, not the RingConn app's number. Active calories and elevated-HR minutes now use the same qualifying heart-rate periods; steps remain the calorie fallback. Elevated HR is not detected workout duration. Full accuracy follows the ring activity-payload decode.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Recompute the two HR-derived estimates OFF the main actor (0x8BADF00D fix). d338484 moved
        // this to `.task`, but a View's `.task` still runs on the MAIN actor — so a workout `stop()`
        // ingest that invalidated the @Query still ran this O(n) map+analytics on the main thread
        // during the background scene-update snapshot, and the crash recurred. Snapshot the
        // SwiftData rows to Sendable value types HERE (main actor), then run the pure Kit math on
        // `Task.detached` and publish back. (Also maps `todayHR` ONCE instead of twice.)
        .task(id: goalsInputsKey) {
            let samples = todayHR.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
            let steps = currentSteps
            let profile = profile
            let sleepWindow: DateInterval? = latestSleep.first.flatMap { s in
                guard s.inBedStart > Date.distantPast, s.inBedEnd > s.inBedStart else { return nil }
                return DateInterval(start: s.inBedStart, end: s.inBedEnd)
            }
            let result = await Task.detached { () -> Calories.DailyEstimate in
                Calories.dailyEstimate(
                    hrSamples: samples,
                    steps: steps,
                    profile: profile,
                    sleepWindow: sleepWindow
                )
            }.value
            cachedActiveKcal = result.activeKcal
            cachedActivityMin = result.elevatedMinutes
            // Score is pure + O(1) — fine on the main actor once the O(n) estimates it reads
            // have been published. Reuses the same goals the rings use so the two never disagree.
            cachedActivityScore = ActivityScore.score(.init(
                steps: steps, stepGoal: stepsGoal,
                activeMinutes: result.elevatedMinutes, activeMinutesGoal: actMinGoal,
                activeKcal: result.activeKcal, activeKcalGoal: activeKcalGoal))
        }
    }

    private func activityTierLabel(_ t: ActivityScore.Tier) -> String {
        switch t {
        case .excellent:        return "Excellent"
        case .good:             return "Good"
        case .needsImprovement: return "Keep moving"
        }
    }

    private func activityTierColor(_ t: ActivityScore.Tier) -> Color {
        switch t {
        case .excellent:        return .green
        case .good:             return .teal   // dashboard mid/secondary accent (matches SleepCardView)
        case .needsImprovement: return .orange
        }
    }

    @ViewBuilder
    private func goalRing(progress p: GoalProgress, label: String,
                          current: String, goal: String, color: Color) -> some View {
        // Percent computed independently of the `p.met` branch below, so a met goal (which swaps the
        // percent Text for a checkmark) still exposes an accessible progress value instead of silence.
        // Truncate (not round) to match the visible ring percent (Int(p.fraction * 100)) exactly.
        let pct = Int(p.fraction * 100)
        let percentText = p.met ? "goal met" : "\(pct) percent"
        // Spoken metric name without the estimate superscript (¹), which VoiceOver reads awkwardly.
        let spokenLabel = label.replacingOccurrences(of: "\u{B9}", with: "")
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
        // One VoiceOver stop per ring: "Steps, 4,321 of 10,000, 47 percent" (was ~4 orphaned tokens).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue("\(current) of \(goal), \(percentText)")
    }

    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h\(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
