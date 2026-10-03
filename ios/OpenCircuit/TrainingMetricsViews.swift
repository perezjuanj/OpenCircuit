// TrainingMetricsViews.swift — the #232 training metrics on screen: a workout's training load and,
// for qualifying outdoor runs, its VO₂ max estimate (workout summary), plus the one-line weekly load
// trend where workouts are listed. The math is in OpenCircuitKit (`TrainingLoad`, `VO2MaxEstimate`);
// the methods, citations and skip rules are in docs/TRAINING_METRICS.md.
//
// Kept in its own file so each workout screen has one call site: the ring's `WorkoutView` and the
// strap's `StrapWorkoutView` show the same section.

import SwiftUI
import HealthKit
import OpenCircuitKit

// MARK: - Workout summary section

/// "TRAINING" on the workout summary: the workout's Edwards training load, and the VO₂ max estimate
/// (or the reason there is none) for an outdoor run.
struct WorkoutTrainingMetricsSection: View {
    let summary: WorkoutSummary
    /// nil for an outdoor run means it was saved without GPS (a detected or recovered workout).
    let vo2Outcome: VO2MaxEstimate.Outcome?
    let vo2HealthStatus: VO2MaxHealthWriter.Status?
    let distanceUnit: DistanceUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRAINING").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            loadRow
            if summary.sport == .runningOutdoor {
                Divider()
                vo2Row(vo2Outcome ?? .skipped(.noGPS))
            }
        }
    }

    @ViewBuilder
    private var loadRow: some View {
        let load = TrainingLoad.workoutLoad(zones: summary.zoneBreakdown,
                                            hrSampleCount: summary.hrSampleCount)
        metricRow(title: "Training load",
                  value: load.map { "\(Int($0.rounded()))" } ?? "--",
                  caption: load == nil
                      ? "No heart rate was recorded, so this workout has no training load."
                      : "Minutes in each heart-rate zone times the zone number (1 to 5). Minutes without a heart-rate reading add nothing.")
    }

    @ViewBuilder
    private func vo2Row(_ outcome: VO2MaxEstimate.Outcome) -> some View {
        switch outcome {
        case .estimate(let e):
            VStack(alignment: .leading, spacing: 4) {
                metricRow(title: "VO₂ max (estimate)",
                          value: "\(Int(e.vo2Max.rounded())) mL/kg/min",
                          caption: Self.estimateCaption(e, unit: distanceUnit))
                Text(healthLine)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .skipped(let reason):
            metricRow(title: "VO₂ max (estimate)", value: "--",
                      caption: "No VO₂ max estimate: " + reason.explanation)
        }
    }

    private var healthLine: String {
        switch vo2HealthStatus {
        case nil: return "Saving the estimate to Apple Health…"
        case .saved?: return "Saved to Apple Health as a submaximal estimate."
        case .sharingOff?: return "Not saved to Apple Health: VO₂ max sharing is off for OpenCircuit in the Health app."
        case .healthNotConnected?: return "Not saved to Apple Health: Apple Health isn't connected."
        case .failed?: return "Not saved to Apple Health."
        }
    }

    static func estimateCaption(_ e: VO2MaxEstimate.Estimate, unit: DistanceUnit) -> String {
        let maxSource = e.maxHRSource == .observed ? "the highest in this run" : "age formula"
        let grade = e.gradeFromElevation
            ? String(format: "%.0f%% grade from GPS elevation", e.grade * 100)
            : "assumed flat (GPS elevation not reliable)"
        return "Estimated from a steady 5-minute stretch at \(pace(e.speed, unit: unit)) and "
            + "\(Int(e.heartRate.rounded())) bpm, \(grade); resting heart rate "
            + "\(Int(e.restingHR.rounded())), maximum \(Int(e.maxHR.rounded())) (\(maxSource))."
    }

    /// m/min → "5:00 /km" (or "/mi").
    static func pace(_ metersPerMinute: Double, unit: DistanceUnit) -> String {
        guard metersPerMinute > 0 else { return "--" }
        let metersPerUnit = unit == .metric ? 1_000.0 : 1_609.344
        let seconds = Int((metersPerUnit / metersPerMinute * 60).rounded())
        return String(format: "%d:%02d /%@", seconds / 60, seconds % 60, unit.symbol)
    }

    @ViewBuilder
    private func metricRow(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Weekly load line

/// Reads back this app's own workouts from the last 5 weeks and scores each from the heart-rate
/// samples saved with it — the same samples, zones and max HR the summary used — so the weekly line
/// needs no local table (and no SwiftData change).
///
/// READ AUTHORIZATION: nothing new. Workouts come from our own source (share covers that, see
/// `WorkoutHistoryReader`), and heart rate is already in `HealthKitWriter.authorizationReadTypes`.
@MainActor
struct WorkoutLoadReader {
    private let store = HKHealthStore()

    func recentLoads(now: Date, age: Int) async -> [TrainingLoad.DatedLoad] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let since = now.addingTimeInterval(-35 * 86_400)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForSamples(withStart: since, end: now, options: []),
        ])
        let workouts: [HKWorkout] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        var loads: [TrainingLoad.DatedLoad] = []
        for workout in workouts {
            let hr = await heartRate(of: workout)
            loads.append(TrainingLoad.DatedLoad(
                end: workout.endDate,
                load: TrainingLoad.workoutLoad(hrSamples: hr, age: age, sessionEnd: workout.endDate)))
        }
        return loads
    }

    /// The heart-rate samples saved WITH this workout (added through its builder).
    private func heartRate(of workout: HKWorkout) async -> [HRSample] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        return samples.map {
            HRSample(bpm: Int($0.quantity.doubleValue(for: bpm).rounded()), start: $0.startDate, end: $0.endDate)
        }
    }
}

/// One line under "Recent Workouts": the last 7 days' training load against the weekly average of
/// the 4 weeks before. A trend, not advice — no injury-risk wording.
struct WeeklyTrainingLoadLine: View {
    var reloadToken: Int = 0
    @State private var trend: TrainingLoad.WeeklyTrend?

    var body: some View {
        content.task(id: reloadToken) {
            let now = Date()
            let age = HealthKitWriter.storedUserProfile().age
            let loads = await WorkoutLoadReader().recentLoads(now: now, age: age)
            // No workout in the last 35 days → no line, rather than "0 · no earlier workouts" above
            // a list of older workouts (review-237 N1). `content` still renders the clear
            // placeholder, so this task keeps a view to run on.
            trend = loads.isEmpty ? nil : TrainingLoad.weeklyTrend(loads, now: now)
        }
    }

    /// Always a real view, so `.task` has something to attach to while the first load runs (a
    /// conditional with no branch taken is not guaranteed to appear).
    @ViewBuilder
    private var content: some View {
        if let trend {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.symbol(trend.direction))
                    .font(.caption).foregroundStyle(.secondary)
                Text(Self.text(trend)).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    static func symbol(_ direction: TrainingLoad.Direction?) -> String {
        switch direction {
        case .higher?: return "arrow.up.right"
        case .lower?: return "arrow.down.right"
        case .similar?: return "arrow.right"
        case nil: return "chart.bar"
        }
    }

    static func text(_ trend: TrainingLoad.WeeklyTrend) -> String {
        var line = "Training load, last 7 days: \(Int(trend.thisWeek.rounded()))"
        if let average = trend.previousWeeklyAverage {
            line += " · 4-week average \(Int(average.rounded()))"
            if let change = trend.change {
                line += String(format: " (%+.0f%%)", change * 100)
            }
        } else {
            line += " · no earlier workouts to compare"
        }
        if trend.unscoredThisWeek > 0 {
            let n = trend.unscoredThisWeek
            line += " · \(n) workout\(n == 1 ? "" : "s") without heart rate not counted"
        }
        return line
    }
}
