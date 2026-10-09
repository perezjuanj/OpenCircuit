// WorkoutDeletion.swift: deleting one of OpenCircuit's own workouts from the history screen (#293).
//
// Order, and why:
//   1. the samples OpenCircuit saved WITH the workout that only describe it: its active energy (an
//      estimate), its GPS distance and its route. Heart rate and steps are measurements and stay.
//      They go first because `predicateForObjects(from:)` needs the workout to still exist.
//   2. the `HKWorkout`.
//   3. only once both deletes succeeded: the tombstone (`WorkoutTombstones`) and, for a workout that
//      ended today, the app-local credits that net it out of today's estimates.
// If any HealthKit delete fails, step 3 never runs and the screen says what is left. Nothing local
// claims a deletion Health didn't make. A retry is safe: the samples already gone match nothing,
// and the credit amounts come from the workout's own totals (`Target`), not from those samples.

import CoreLocation
import Foundation
import HealthKit
import OpenCircuitKit

/// The HealthKit side of a deletion. `HealthKitWorkoutStore` in the app, a fake in tests.
@MainActor
protocol WorkoutHealthDeleting: AnyObject {
    /// Delete the active-energy, distance and route samples saved with workout `id` (our source only).
    func deleteOwnedSamples(ofWorkout id: UUID) async throws
    /// Delete workout `id`. Succeeds when it is already gone.
    func deleteWorkout(_ id: UUID) async throws
}

@MainActor
struct WorkoutDeleter {
    /// What a deletion needs to know about the workout, read before anything is deleted.
    struct Target: Equatable {
        let id: UUID
        let start: Date
        let end: Date
        /// The workout's banked active-energy total: the amount `recordWorkoutActiveKcal` credited.
        let activeKcal: Double?
        /// Its walk/run GPS distance: the amount `recordWorkoutWalkRunDistance` credited (cycling
        /// distance is never netted, so it has nothing to undo).
        let walkRunMeters: Double?
    }

    enum Outcome: Equatable {
        case deleted
        /// Nothing was removed from Apple Health (or only some of the samples were).
        case samplesNotDeleted
        /// The samples are gone but the workout itself is still in Apple Health.
        case workoutNotDeleted

        /// What the screen says when a delete did not finish. nil when it did.
        var failureMessage: String? {
            switch self {
            case .deleted:
                return nil
            case .samplesNotDeleted:
                return "Apple Health did not remove this workout's calories, distance or route, so the workout was kept. Check that OpenCircuit can still write workouts in the Health app, then try again."
            case .workoutNotDeleted:
                return "Apple Health removed this workout's calories, distance and route but kept the workout itself. Try deleting it again to finish."
            }
        }
    }

    static let confirmationTitle = "Delete this workout?"
    /// Names what goes and what stays. Heart rate is a measurement, not part of the workout's
    /// estimate, so it is kept (in the app and, see the #293 report, in Apple Health).
    static let confirmationMessage = "This removes the workout from OpenCircuit and Apple Health, together with the calorie estimate, distance and route saved with it. Heart-rate readings are kept. This can't be undone."

    let health: any WorkoutHealthDeleting
    var tombstones = WorkoutTombstones()
    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init

    func delete(_ target: Target) async -> Outcome {
        do { try await health.deleteOwnedSamples(ofWorkout: target.id) } catch { return .samplesNotDeleted }
        do { try await health.deleteWorkout(target.id) } catch { return .workoutNotDeleted }

        let now = now()
        tombstones.record(start: target.start, end: target.end, deletedAt: now)
        // The credits only ever exist for a workout that ended today (the write paths' own rule),
        // and each helper also refuses a slot that isn't today's.
        if Calendar.current.isDate(target.end, inSameDayAs: now) {
            var changed = false
            if let kcal = target.activeKcal {
                changed = HealthKitWriter.undoWorkoutActiveKcal(kcal, day: target.end, now: now, defaults) || changed
            }
            changed = HealthKitWriter.removeWorkoutCreditedSpan(start: target.start, end: target.end,
                                                                now: now, defaults) || changed
            if let meters = target.walkRunMeters {
                changed = HealthKitWriter.undoWorkoutWalkRunDistance(meters, now: now, defaults) || changed
            }
            if changed {
                let key = HealthKitWriter.workoutCreditsRevisionKey
                defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
            }
        }
        return .deleted
    }
}

// MARK: - HealthKit

/// Our own workouts in Apple Health: the detail screen's reads and the deletion's deletes. Every
/// query is limited to this app's source, which the workout SHARE grant already covers (see the
/// READ AUTHORIZATION note on `WorkoutHistoryReader`; no read request is added here).
@MainActor
final class HealthKitWorkoutStore: WorkoutHealthDeleting {
    private let store = HKHealthStore()

    /// The samples saved with a workout that only describe it, and are deleted with it.
    static let ownedSampleTypes: [HKSampleType] = [
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
        HKSeriesType.workoutRoute(),
    ]

    /// Workout `id`, if it is ours and still exists. Throws when the query itself failed, so a
    /// failed lookup is never mistaken for "already deleted".
    func workout(_ id: UUID) async throws -> HKWorkout? {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObject(with: id),
            HKQuery.predicateForObjects(from: .default()),
        ])
        return try await samples(of: HKWorkoutType.workoutType(), predicate: predicate).first as? HKWorkout
    }

    func deleteOwnedSamples(ofWorkout id: UUID) async throws {
        guard let workout = try await workout(id) else { return }
        for type in Self.ownedSampleTypes {
            let owned = try await samples(of: type, predicate: Self.savedWith(workout))
            // Only types that hold something: deleting a type the app never wrote (no route share
            // grant, say) would fail for nothing.
            if !owned.isEmpty { try await store.delete(owned) }
        }
    }

    func deleteWorkout(_ id: UUID) async throws {
        guard let workout = try await workout(id) else { return }
        try await store.delete(workout)
    }

    /// The heart rate saved with the workout (through its builder): our source, inside its window.
    /// The same samples the weekly training-load line scores (`WorkoutLoadReader`).
    func heartRate(of workout: HKWorkout) async -> [HRSample] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let found = (try? await samples(of: HKQuantityType(.heartRate), predicate: Self.savedWith(workout),
                                        ascending: true)) ?? []
        return found.compactMap { $0 as? HKQuantitySample }.map {
            HRSample(bpm: Int($0.quantity.doubleValue(for: bpm).rounded()), start: $0.startDate, end: $0.endDate)
        }
    }

    /// The workout's GPS route, or [] when it has none.
    func route(of workout: HKWorkout) async -> [CLLocationCoordinate2D] {
        guard let routes = try? await samples(of: HKSeriesType.workoutRoute(), predicate: Self.savedWith(workout))
            .compactMap({ $0 as? HKWorkoutRoute }), !routes.isEmpty else { return [] }
        var coordinates: [CLLocationCoordinate2D] = []
        for route in routes {
            let points: [CLLocationCoordinate2D] = await withCheckedContinuation { cont in
                var collected: [CLLocationCoordinate2D] = []
                var resumed = false
                let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    collected += (locations ?? []).map(\.coordinate)
                    guard !resumed, done || error != nil else { return }
                    resumed = true
                    cont.resume(returning: collected)
                }
                store.execute(query)
            }
            coordinates += points
        }
        return coordinates
    }

    private static func savedWith(_ workout: HKWorkout) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            HKQuery.predicateForObjects(from: .default()),
        ])
    }

    private func samples(of type: HKSampleType, predicate: NSPredicate,
                         ascending: Bool? = nil) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let sort = ascending.map { [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: $0)] }
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: sort) { _, samples, error in
                // "No data" is an answer (nothing matched), not a failure.
                if let error, samples == nil, (error as? HKError)?.code != .errorNoData {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}
