// WorkoutHistoryView.swift — "Recent workouts": the app reading its OWN workouts back out of
// Apple Health, and the Activity-tab card that renders them.
//
// WHY (tester report 2026-08-29, build 49): "it still ended up in my Apple Health and Bevel as an
// activity but I didn't see it in Open Circuit." OpenCircuit had NO workout history of any kind —
// a finished workout was visible exactly once, on the summary screen, and then only until the sheet
// closed. So even a correctly-saved workout looked lost.
//
// WHY HEALTHKIT AND NOT A LOCAL TABLE: HealthKit is already the durable, authoritative store for
// every workout this app writes (`WorkoutSessionManager.writeWorkout`). Reading it back is the
// cheapest correct fix and, decisively, it adds NO SwiftData model and therefore NO schema version
// — a migration is a launch-crash surface whose recovery path wipes un-resyncable raw history
// (build 44 deleted every raw history row on upgrade; see the notes in `App.swift`). A second local
// copy would also be able to disagree with Health, which is the bug class this card exists to end.
//
// SCOPE OF THE QUERY: `HKQuery.predicateForObjects(from: .default())` — OUR OWN workouts only. This
// is deliberately not a general workout browser: showing Apple Watch / Strava / Bevel workouts here
// would imply OpenCircuit recorded them.

import SwiftUI
import HealthKit
import OpenCircuitKit

// MARK: - Reader

/// Reads back the workouts this app wrote to Apple Health.
@MainActor
struct WorkoutHistoryReader {
    private let store = HKHealthStore()

    /// One row of history. Every field is optional-where-absent on purpose: a workout saved without
    /// HR (the ring never locked) reports nil rather than a zero that would read as a measurement.
    struct Item: Identifiable, Equatable {
        let id: UUID
        let activityType: HKWorkoutActivityType
        let start: Date
        let end: Date
        let activeKcal: Double?
        let distanceMeters: Double?
        let avgHR: Int?

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    // READ AUTHORIZATION — deliberately NOT requested here.
    //
    // Build 50 asked for it here, in its own `requestAuthorization(toShare: [], read:
    // [HKObjectType.workoutType()])`, while `HealthKitWriter`'s request kept naming that same
    // workout type in `toShare` only. On device that left the user in a permission loop with no
    // settled state: grant Workouts + Workout Routes WRITE at launch → open this tab → the read
    // prompt appears → the write grant is gone → next launch asks for write again. The full
    // evidence, and what is and is not established about the HealthKit mechanism, is on
    // `HealthKitWriter.authorizationReadTypes`.
    //
    // `HKObjectType.workoutType()` now rides the app's SINGLE authorization request: it is in
    // `HealthKitWriter.allTypes` (share) and in `HealthKitWriter.authorizationReadTypes` (read), so
    // one sheet settles both halves. Already-authorized users pick the read half up through
    // `ContentView.reconcileNewlyAuthorizableShareTypes()` (#129), which re-runs the one request
    // while `statusForAuthorizationRequest` still reports it as needed.
    //
    // ⚠️ DO NOT ADD A REQUEST HERE. A HealthKit read without authorization does not error — it
    // returns an empty result — so if this card is ever empty on a device that has workouts, the
    // fix is in that single request, never a second one.

    /// The most recent workouts OpenCircuit itself wrote, newest first. Returns `[]` on any failure
    /// (unavailable / denied / query error) — an empty list is honest here, and the card says
    /// "nothing yet" rather than inventing a placeholder row.
    func recentWorkouts(limit: Int) async -> [Item] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let workouts: [HKWorkout] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: HKQuery.predicateForObjects(from: .default()),
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                   ascending: false)]
            ) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        return workouts.map { w in
            // `statistics(for:)` reads the totals the HKWorkoutBuilder banked when the workout was
            // saved; nil when that quantity was never added (e.g. no HR locked, indoor → no route).
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            let footDistance = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                .sumQuantity()?.doubleValue(for: .meter())
            let cycleDistance = w.statistics(for: HKQuantityType(.distanceCycling))?
                .sumQuantity()?.doubleValue(for: .meter())
            let bpm = w.statistics(for: HKQuantityType(.heartRate))?
                .averageQuantity()?
                .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            return Item(id: w.uuid,
                        activityType: w.workoutActivityType,
                        start: w.startDate,
                        end: w.endDate,
                        activeKcal: kcal,
                        distanceMeters: footDistance ?? cycleDistance,
                        avgHR: bpm.map { Int($0.rounded()) })
        }
    }
}

// MARK: - Presentation helpers

/// Display name + glyph for the activity types this app writes. Anything else falls back to a
/// neutral "Workout" rather than guessing — the list only ever holds our own workouts, so an
/// unrecognised type means a build wrote something this switch has not learned about yet.
enum WorkoutActivityDisplay {
    static func name(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking:                      return "Walking"
        case .running:                      return "Running"
        case .cycling:                      return "Cycling"
        case .rowing:                       return "Rowing"
        case .hiking:                       return "Hiking"
        case .traditionalStrengthTraining:  return "Strength"
        case .yoga:                         return "Yoga"
        default:                            return "Workout"
        }
    }

    static func symbol(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking:                      return "figure.walk"
        case .running:                      return "figure.run"
        case .cycling:                      return "bicycle"
        case .rowing:                       return "figure.rower"
        case .hiking:                       return "mountain.2"
        case .traditionalStrengthTraining:  return "dumbbell"
        case .yoga:                         return "figure.yoga"
        default:                            return "heart.circle"
        }
    }
}

// MARK: - Card

/// "Recent workouts" on the Activity tab. Loads on appear and whenever `reloadToken` changes (the
/// workout sheet closing bumps it), so a workout the user just finished shows up without a relaunch.
struct RecentWorkoutsCard: View {
    /// Bumped by the owner after a workout ends, to re-query Health.
    var reloadToken: Int = 0
    /// How many rows to show. Small on purpose: this is a "did my workout save?" reassurance
    /// surface, not a history browser.
    var limit: Int = 5

    @AppStorage("units.distance") private var distUnitRaw = DistanceUnit.localeDefault.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distUnitRaw) ?? .metric }

    @State private var items: [WorkoutHistoryReader.Item] = []
    @State private var loaded = false

    var body: some View {
        OCCard {
            OCSectionHeader("Recent Workouts", systemImage: "figure.run.square.stack",
                            tint: Theme.steps)
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if items.isEmpty {
                Text("No workouts recorded yet. Ones you record here are saved to Apple Health and listed back here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        row(item)
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
        }
        .task(id: reloadToken) { await load() }
    }

    @ViewBuilder
    private func row(_ item: WorkoutHistoryReader.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: WorkoutActivityDisplay.symbol(item.activityType))
                .font(.title3).foregroundStyle(Theme.steps).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutActivityDisplay.name(item.activityType))
                    .font(.subheadline.weight(.semibold))
                Text(subtitle(item)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(durationText(item.duration))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                // Only ever renders what Health actually holds — a workout with no HR and no energy
                // shows its duration alone rather than a fabricated "0".
                if let kcal = item.activeKcal {
                    Text("\(Int(kcal.rounded())) cal").font(.caption2).foregroundStyle(.secondary)
                } else if let bpm = item.avgHR {
                    Text("\(bpm) bpm").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func subtitle(_ item: WorkoutHistoryReader.Item) -> String {
        let df = DateFormatter()
        df.dateStyle = Calendar.current.isDateInToday(item.start) ? .none : .medium
        df.timeStyle = .short
        var parts = [df.string(from: item.start)]
        if let d = item.distanceMeters, d > 0 {
            parts.append(UnitsFormatter.distance(d, unit: distanceUnit, fractionDigits: 2))
        }
        return parts.joined(separator: " · ")
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }

    private func load() async {
        let reader = WorkoutHistoryReader()
        items = await reader.recentWorkouts(limit: limit)
        loaded = true
    }
}
