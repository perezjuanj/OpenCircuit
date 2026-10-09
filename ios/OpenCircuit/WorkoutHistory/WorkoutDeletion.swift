// WorkoutDeletion.swift: deleting one of OpenCircuit's own workouts from the history screen (#293).
//
// Order, and why:
//   1. the samples OpenCircuit saved WITH the workout that only describe it: its active energy (an
//      estimate), its GPS distance and its route, in ONE `delete` call so they go together or not at
//      all. Heart rate and steps are measurements and stay. They go first because
//      `predicateForObjects(from:)` needs the workout to still exist.
//   2. the `HKWorkout`. HealthKit doesn't document whether deleting a workout also removes the
//      samples its builder associated with it. So the heart-rate and step samples saved with it are
//      read first, and any that are missing afterwards (looked up by UUID, so nothing still present is
//      ever written twice) are saved again as standalone copies.
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
    /// Delete workout `id`. Succeeds when it is already gone. Returns how many of the heart-rate and
    /// step samples saved with it HealthKit removed and could NOT be saved back (0 when all are kept).
    func deleteWorkout(_ id: UUID) async throws -> Int
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
        /// The workout is gone, but HealthKit removed this many heart-rate or step readings with it and
        /// they could not be saved back.
        case deletedLosingReadings(Int)
        /// Apple Health removed none of the workout's own samples (they are deleted in one call).
        case samplesNotDeleted
        /// The samples are gone but the workout itself is still in Apple Health.
        case workoutNotDeleted

        /// Whether the workout is gone from Apple Health (the screens drop the row).
        var removedWorkout: Bool {
            switch self {
            case .deleted, .deletedLosingReadings: return true
            case .samplesNotDeleted, .workoutNotDeleted: return false
            }
        }

        /// The alert title that goes with `failureMessage`.
        var failureTitle: String { removedWorkout ? "Workout deleted" : "Workout not fully deleted" }

        /// What the screen says when a delete did not finish cleanly. nil when it did.
        var failureMessage: String? {
            switch self {
            case .deleted:
                return nil
            case .deletedLosingReadings(let n):
                return "The workout was deleted, but Apple Health also removed \(n) heart-rate or step \(n == 1 ? "reading" : "readings") saved with it, and they couldn't be saved back. They are still in OpenCircuit."
            case .samplesNotDeleted:
                return "Apple Health did not remove this workout's calories, distance or route, so the workout was kept. Check that OpenCircuit can still write workouts in the Health app, then try again."
            case .workoutNotDeleted:
                return "Apple Health removed this workout's calories, distance and route but kept the workout itself. Try deleting it again to finish."
            }
        }
    }

    static let confirmationTitle = "Delete this workout?"
    /// Names what goes and what stays. Heart rate and steps are measurements, not part of the
    /// workout's estimate, so they are kept: in the app, and in Apple Health (put back by
    /// `HealthKitWorkoutStore.deleteWorkout` if deleting the workout took them).
    static let confirmationMessage = "This removes the workout from OpenCircuit and Apple Health, together with the calorie estimate, distance and route saved with it. Heart-rate readings and steps are kept. This can't be undone."

    let health: any WorkoutHealthDeleting
    var tombstones = WorkoutTombstones()
    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init

    func delete(_ target: Target) async -> Outcome {
        do { try await health.deleteOwnedSamples(ofWorkout: target.id) } catch { return .samplesNotDeleted }
        let lostReadings: Int
        do { lostReadings = try await health.deleteWorkout(target.id) } catch { return .workoutNotDeleted }

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
        return lostReadings > 0 ? .deletedLosingReadings(lostReadings) : .deleted
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
    /// Measurements saved with a workout. Never deleted, and put back if deleting the workout took them.
    static let keptSampleTypes: [HKQuantityType] = [
        HKQuantityType(.heartRate),
        HKQuantityType(.stepCount),
    ]

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
        var owned: [HKSample] = []
        for type in Self.ownedSampleTypes {
            owned += try await samples(of: type, predicate: Self.savedWith(workout))
        }
        // One call, so a failure leaves all of them in place rather than some. Skipped when empty:
        // deleting nothing (no route share grant, say) would fail for nothing.
        if !owned.isEmpty { try await store.delete(owned) }
    }

    func deleteWorkout(_ id: UUID) async throws -> Int {
        guard let workout = try await workout(id) else { return 0 }
        var kept: [HKQuantitySample] = []
        for type in Self.keptSampleTypes {
            kept += try await samples(of: type, predicate: Self.savedWith(workout))
                .compactMap { $0 as? HKQuantitySample }
        }
        try await store.delete(workout)
        guard !kept.isEmpty else { return 0 }
        // Look the kept samples up again by UUID. A lookup that fails counts as "still there": a
        // copy saved over an original that still exists would double the steps.
        var present = Set<UUID>()
        for type in Self.keptSampleTypes {
            let ids = kept.filter { $0.quantityType == type }.map(\.uuid)
            guard !ids.isEmpty else { continue }
            guard let found = try? await samples(of: type, predicate: HKQuery.predicateForObjects(with: Set(ids))) else {
                present.formUnion(ids)
                continue
            }
            present.formUnion(found.map(\.uuid))
        }
        let missing = Self.removedWithWorkout(kept: kept.map(\.uuid), stillPresent: present)
        guard !missing.isEmpty else { return 0 }
        let copies = kept.filter { missing.contains($0.uuid) }.map {
            HKQuantitySample(type: $0.quantityType, quantity: $0.quantity, start: $0.startDate, end: $0.endDate,
                             device: $0.device, metadata: $0.metadata)
        }
        do {
            try await store.save(copies)
            return 0
        } catch {
            return copies.count
        }
    }

    /// The kept samples HealthKit removed along with the workout: those not found again by UUID.
    nonisolated static func removedWithWorkout(kept: [UUID], stillPresent: Set<UUID>) -> Set<UUID> {
        Set(kept).subtracting(stillPresent)
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

    /// Samples saved with `workout` by this app. Association AND source, never a time window: a
    /// window would also catch the daily energy flush and any other workout's samples.
    /// `ourSource` is injectable only because `HKSource.default()` can't be built in an unsigned test host.
    static func savedWith(_ workout: HKWorkout,
                          ourSource: @autoclosure () -> NSPredicate = HKQuery.predicateForObjects(from: .default()))
        -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            ourSource(),
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
