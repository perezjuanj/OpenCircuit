// Wellness Balance / readiness home headline (#97).
//
// Weight-combines last night's Sleep Score and overnight recovery (the inverse of overnight
// stress) — both already stored on the latest StoredSleepSummary — with today's Activity Score
// (#95, computed here OFF the render path from steps + HR, exactly as GoalsCardView does, so the
// two surfaces never disagree). The Vitals-Status factor is supported by the Kit
// (`WellnessBalance.Input.vitalsStatus`) and will be wired once the Vitals-Status report is shared
// (see VitalsStatusCardView); until then it renormalises out cleanly.
//
// On-device ESTIMATE, labeled as such — NOT the RingConn app's proprietary readiness number, and
// not medical advice. Heavy analytics run OFF the main actor in `.task` (snapshot → Task.detached
// → publish), matching the 0x8BADF00D-safe pattern of GoalsCardView / CaloriesCardView /
// VitalsStatusCardView.

import SwiftUI
import SwiftData
import OpenCircuitKit

struct WellnessBalanceCardView: View {

    // Goal + profile settings (shared with GoalsCardView / GoalDefaults) for the Activity Score.
    @AppStorage(GoalDefaults.workdaySteps)    private var workdaySteps   = GoalDefaults.defaultWorkdaySteps
    @AppStorage(GoalDefaults.weekendSteps)    private var weekendSteps   = GoalDefaults.defaultWeekendSteps
    @AppStorage(GoalDefaults.activeKcal)      private var activeKcalGoal = GoalDefaults.defaultActiveKcal
    @AppStorage(GoalDefaults.activityMinutes) private var actMinGoal     = GoalDefaults.defaultActivityMinutes
    @AppStorage("userProfile.age") private var age = 35
    @AppStorage("userProfile.weightKg") private var weightKg = 70.0
    // #284: manual-entry date + cached latest Apple Health body mass; the newer one feeds the math.
    @AppStorage(WeightResolver.Keys.manualSetAt) private var weightSetAtEpoch = 0.0
    @AppStorage(WeightResolver.Keys.healthKg) private var healthWeightKg = 0.0
    @AppStorage(WeightResolver.Keys.healthAt) private var healthWeightAtEpoch = 0.0
    private var effectiveWeightKg: Double {
        WeightResolver.resolve(manualKg: weightKg, manualSetAtEpoch: weightSetAtEpoch,
                               healthKg: healthWeightKg, healthAtEpoch: healthWeightAtEpoch).kg
    }
    @AppStorage("userProfile.heightCm") private var heightCm = 170.0
    @AppStorage("userProfile.sex") private var sexRaw = BiologicalSex.male.rawValue

    @Query private var todayDaily: [StoredDaily]
    @Query private var todayHR: [StoredSample]
    @Query private var latestSleep: [StoredSleepSummary]
    /// Per-snapshot step deltas — see the same query in `GoalsCardView`. Readiness scores active
    /// kcal, so it must price the day exactly as the Goals rings and Apple Health do.
    @Query private var recentStepSamples: [StoredStepSample]

    /// Reports what the card ended up showing, so the Today synthesis line (#216) speaks about the
    /// SAME readiness instead of recomputing its own. Called after every recompute.
    var onReport: ((ReadinessReport) -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 132
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(onReport: ((ReadinessReport) -> Void)? = nil) {
        self.onReport = onReport
        let dayStart = Calendar.current.startOfDay(for: Date())
        let stepsFrom = dayStart.addingTimeInterval(-86_400)
        let hrKind = MetricKind.heartRate.rawValue
        _recentStepSamples = Query(FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.start >= stepsFrom },
            sortBy: [SortDescriptor(\.start, order: .forward)]))
        _todayDaily = Query(filter: #Predicate<StoredDaily> { $0.day == dayStart }, sort: \.day)
        _todayHR = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hrKind && $0.start >= dayStart && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)]))
        var sleepDesc = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        sleepDesc.fetchLimit = 1
        _latestSleep = Query(sleepDesc)
    }

    /// Readiness held as STATE, recomputed off the render path (see `.task` below). nil until the
    /// first compute lands, or when there's no credited last night to anchor readiness.
    @State private var result: WellnessBalance.Result?

    private var stepsGoal: Int { GoalDefaults.isWeekend() ? weekendSteps : workdaySteps }
    private var currentSteps: Int { todayDaily.first?.steps ?? 0 }
    private var profile: UserProfile {
        UserProfile(age: age, weightKg: max(effectiveWeightKg, 1), heightCm: max(heightCm, 1),
                    sex: BiologicalSex(rawValue: sexRaw) ?? .male)
    }

    /// Only credit last night's stored scores when the night actually ended today — the same recency
    /// test the Sleep card and Goals ring use, so a days-old night isn't read as "last night" (#147).
    private var sleepCredited: Bool {
        guard let s = latestSleep.first else { return false }
        let inBedEnd = s.inBedEnd > s.inBedStart ? s.inBedEnd : nil
        return MissedNight.endedToday(inBedEnd: inBedEnd, nightKey: s.night)
    }

    /// WHY THE CARD IS EMPTY, AND WHETHER SYNCING WOULD ACTUALLY HELP.
    ///
    /// ⚠️ NEVER TELL THE USER TO SYNC WHEN A SYNC CANNOT CHANGE THE ANSWER. Until b49 this card had
    /// one empty state — "Sync last night's sleep to see today's readiness." — and the commonest way
    /// to reach it was editing your own sleep times, which zeroed the stored score
    /// (`LocalStore.applySleepEdit`, now fixed). The wearer was then told to perform the one action
    /// that provably cannot restore it: nothing in the app re-scores a night that is already stored,
    /// so she re-synced, saw nothing change, and reported the score as deleted.
    ///
    /// So the cases are separated by the ONE thing that decides whether a sync is the fix: whether
    /// we already hold last night, and whether it carries a score. Both are read from the STORED
    /// row rather than from `result`, because `result` is also nil for the moment before the first
    /// `.task` lands — and telling a wearer whose night IS scored that it isn't would be the same
    /// class of lie in the other direction.
    private enum ReadinessGap { case noNight, noScore, computing }

    private var readinessGap: ReadinessGap {
        // `sleepCredited` is the same recency rule the Sleep card and the Goals ring use (#147):
        // a days-old night is not "last night", and for it a sync IS the right advice.
        guard sleepCredited else { return .noNight }
        // 0 is the app-wide "never computed" sentinel for this column (`SleepCardView`'s badge,
        // `TrendsEngine`'s filter, `App`'s backup restore). The night is here either way, so no
        // amount of syncing changes the answer.
        return (latestSleep.first?.sleepScore ?? 0) > 0 ? .computing : .noScore
    }

    private var emptyStateText: String {
        switch readinessGap {
        case .noNight:   return "Sync last night's sleep to see today's readiness."
        case .noScore:   return "Last night doesn't have a sleep score, so there's no readiness to show today."
        case .computing: return "Working out today's readiness…"
        }
    }

    private var emptyStateAccessibilityLabel: String {
        switch readinessGap {
        case .noNight:   return "Readiness unavailable — sync last night's sleep"
        case .noScore:   return "Readiness unavailable — last night has no sleep score"
        case .computing: return "Readiness, working it out"
        }
    }

    /// Recompute identity — changes only when an input to readiness changes.
    private var inputsKey: String {
        "\(todayHR.count)|\(currentSteps)|\(recentStepSamples.count)|\(age)|\(effectiveWeightKg)|\(heightCm)|\(sexRaw)|"
        + "\(latestSleep.first?.night.timeIntervalSince1970 ?? 0)|\(latestSleep.first?.sleepScore ?? 0)|"
        + "\(latestSleep.first?.stressScore ?? 0)|\(sleepCredited ? 1 : 0)|"
        + "\(stepsGoal)|\(Int(actMinGoal))|\(Int(activeKcalGoal))|\(workoutCreditsRevision)"
    }
    /// Bumped when a deleted workout's credited span is undone (#293), so readiness recomputes.
    @AppStorage(HealthKitWriter.workoutCreditsRevisionKey) private var workoutCreditsRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.circle.fill").foregroundStyle(.pink)
                Text("READINESS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            // Ring beside the details; stacked at accessibility text sizes so nothing truncates.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
            if let r = result {
                layout {
                    ReadinessRing(progress: Double(r.score) / 100, tint: r.tier.ringColor,
                                  lowConfidence: isLowConfidence(r)) {
                        VStack(spacing: 0) {
                            Text("\(r.score)")
                                .font(.system(size: ringSize * 0.32, weight: .bold, design: .rounded))
                                .monospacedDigit().contentTransition(.numericText())
                                .minimumScaleFactor(0.5).lineLimit(1)
                            Text("of 100").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: ringSize, height: ringSize)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tierLabel(r.tier))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        ForEach(WellnessBalance.Result.Factor.allCases, id: \.self) { factor in
                            if let v = r.factors[factor] {
                                ReadinessFactorBar(label: factorLabel(factor), value: v,
                                                   tint: r.tier.ringColor)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isLowConfidence(r) {
                    Text("Based on last night's sleep alone — overnight recovery and today's activity aren't in yet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Estimate — a blend of last night's sleep, overnight recovery & today's activity. Not your device app's own score, and not medical advice.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                layout {
                    ReadinessRing(progress: nil) {
                        Text("—").font(.system(size: ringSize * 0.26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: ringSize * 0.7, height: ringSize * 0.7)
                    Text(emptyStateText)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.map {
            "Readiness, estimate, \($0.score) out of 100, \(tierLabel($0.tier)). \(breakdown($0))"
            + (isLowConfidence($0) ? ". Based on last night's sleep alone" : "")
        } ?? emptyStateAccessibilityLabel)
        .task(id: inputsKey) {
            // Snapshot SwiftData rows to Sendable value types on the main actor, run the O(n) activity
            // math off-main, then compose the readiness on the way back.
            let samples = todayHR.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
            let steps = currentSteps
            let profile = profile
            let sleepWindow: DateInterval? = latestSleep.first.flatMap { s in
                // Guard BOTH ends: DateInterval(start:end:) traps when end < start, and a legacy /
                // partial row can carry a real inBedStart with inBedEnd == .distantPast.
                guard s.inBedStart > Date.distantPast, s.inBedEnd > s.inBedStart else { return nil }
                return DateInterval(start: s.inBedStart, end: s.inBedEnd)
            }
            let stepGoal = stepsGoal
            let minGoal = actMinGoal
            let kcalGoal = activeKcalGoal

            let stepWindows = recentStepSamples.map {
                StepWindow(start: $0.start, end: $0.end, delta: $0.delta)
            }
            let dayStart = Calendar.current.startOfDay(for: Date())
            // #281 motion gate (off by default): the ring's own activity sessions.
            let activityIntervals = RingActivityEventLedger.load().corroboratingIntervals(now: Date())
            let creditedWorkoutIntervals = HealthKitWriter.workoutCreditedSpans(day: dayStart)

            let activity = await Task.detached { () -> ActivityScore.Result in
                let estimate = Calories.dailyEstimate(
                    hrSamples: samples,
                    steps: steps,
                    profile: profile,
                    sleepWindow: sleepWindow,
                    stepWindows: stepWindows,
                    dayStart: dayStart,
                    activityIntervals: activityIntervals,
                    creditedWorkoutIntervals: creditedWorkoutIntervals
                )
                return ActivityScore.score(.init(
                    steps: steps, stepGoal: stepGoal,
                    activeMinutes: estimate.elevatedMinutes, activeMinutesGoal: minGoal,
                    activeKcal: estimate.activeKcal, activeKcalGoal: kcalGoal))
            }.value

            // Sleep + overnight recovery only count when last night actually ended today.
            let sleepScore: Int? = {
                guard sleepCredited, let s = latestSleep.first, s.sleepScore > 0 else { return nil }
                return s.sleepScore
            }()
            let stress: Int? = {
                guard sleepCredited, let s = latestSleep.first, s.stressScore > 0 else { return nil }
                return s.stressScore
            }()
            // Activity contributes only once the day has some signal — a fresh 0-step morning
            // shouldn't drag readiness down before the user has moved.
            let activityScore: Int? = activity.score > 0 ? activity.score : nil

            // Readiness is anchored on last night: anchoredScore returns nil without a sleep score,
            // so activity alone never synthesises a readiness — the card shows the empty state.
            result = WellnessBalance.anchoredScore(.init(
                sleepScore: sleepScore, overnightStress: stress,
                vitalsStatus: nil, activityScore: activityScore))
            onReport?(report)
        }
    }

    /// What this card is showing, for the synthesis line. Mirrors `readinessGap` for the empty states.
    private var report: ReadinessReport {
        let asleep = sleepCredited ? latestSleep.first.flatMap { $0.asleepMin > 0 ? $0.asleepMin : nil } : nil
        if let r = result {
            return ReadinessReport(readiness: .scored(score: r.score, tier: r.tier, factorCount: r.factors.count),
                                   lastNightAsleepMin: asleep)
        }
        switch readinessGap {
        case .noNight:   return ReadinessReport(readiness: .noNight, lastNightAsleepMin: nil)
        case .noScore:   return ReadinessReport(readiness: .noScore, lastNightAsleepMin: asleep)
        case .computing: return ReadinessReport(readiness: .pending, lastNightAsleepMin: asleep)
        }
    }

    /// A score resting on last night's sleep alone (no overnight recovery, no activity yet).
    private func isLowConfidence(_ r: WellnessBalance.Result) -> Bool { r.factors.count <= 1 }

    private func factorLabel(_ f: WellnessBalance.Result.Factor) -> String {
        switch f {
        case .sleep:    return "Sleep"
        case .recovery: return "Overnight recovery"
        case .vitals:   return "Vitals"
        case .activity: return "Activity"
        }
    }

    private func breakdown(_ r: WellnessBalance.Result) -> String {
        var parts: [String] = []
        if let s = r.factors[.sleep]    { parts.append("sleep \(Int((s * 100).rounded()))") }
        if let rec = r.factors[.recovery] { parts.append("recovery \(Int((rec * 100).rounded()))") }
        if let a = r.factors[.activity] { parts.append("activity \(Int((a * 100).rounded()))") }
        return parts.joined(separator: " · ")
    }

    private func tierLabel(_ t: WellnessBalance.Tier) -> String {
        switch t {
        case .excellent:        return "Excellent"
        case .good:             return "Good"
        case .needsImprovement: return "Needs improvement"
        }
    }
}
