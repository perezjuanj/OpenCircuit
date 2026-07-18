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
    @AppStorage("userProfile.heightCm") private var heightCm = 170.0
    @AppStorage("userProfile.sex") private var sexRaw = BiologicalSex.male.rawValue

    @Query private var todayDaily: [StoredDaily]
    @Query private var todayHR: [StoredSample]
    @Query private var latestSleep: [StoredSleepSummary]

    init() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let hrKind = MetricKind.heartRate.rawValue
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
        UserProfile(age: age, weightKg: max(weightKg, 1), heightCm: max(heightCm, 1),
                    sex: BiologicalSex(rawValue: sexRaw) ?? .male)
    }

    /// Only credit last night's stored scores when the night actually ended today — the same recency
    /// test the Sleep card and Goals ring use, so a days-old night isn't read as "last night" (#147).
    private var sleepCredited: Bool {
        guard let s = latestSleep.first else { return false }
        let inBedEnd = s.inBedEnd > s.inBedStart ? s.inBedEnd : nil
        return MissedNight.endedToday(inBedEnd: inBedEnd, nightKey: s.night)
    }

    /// Recompute identity — changes only when an input to readiness changes.
    private var inputsKey: String {
        "\(todayHR.count)|\(currentSteps)|\(age)|\(weightKg)|\(heightCm)|\(sexRaw)|"
        + "\(latestSleep.first?.night.timeIntervalSince1970 ?? 0)|\(latestSleep.first?.sleepScore ?? 0)|"
        + "\(latestSleep.first?.stressScore ?? 0)|\(sleepCredited ? 1 : 0)|"
        + "\(stepsGoal)|\(Int(actMinGoal))|\(Int(activeKcalGoal))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "heart.circle.fill").foregroundStyle(.pink)
                Text("READINESS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let r = result {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(r.score)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                        .foregroundStyle(tierColor(r.tier))
                    Text(tierLabel(r.tier)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(breakdown(r)).font(.caption).foregroundStyle(.secondary)
                Text("Estimate — a blend of last night's sleep, overnight recovery & today's activity. Not the RingConn app's readiness score, and not medical advice.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Sync last night's sleep to see today's readiness.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.map { "Readiness, estimate, \($0.score) out of 100, \(tierLabel($0.tier))" }
                            ?? "Readiness unavailable — sync last night's sleep")
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

            let activity = await Task.detached { () -> ActivityScore.Result in
                let estimate = Calories.dailyEstimate(
                    hrSamples: samples,
                    steps: steps,
                    profile: profile,
                    sleepWindow: sleepWindow
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

    private func tierColor(_ t: WellnessBalance.Tier) -> Color {
        switch t {
        case .excellent:        return .green
        case .good:             return .teal   // dashboard mid/secondary accent (matches SleepCardView)
        case .needsImprovement: return .orange
        }
    }
}
