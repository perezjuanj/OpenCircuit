// IndoorRunHealthWriter.swift — an indoor run's Apple Health writes beyond the workout itself (#339,
// decision 84f, 84g): per-minute running speed and stride length, the typed treadmill distance replacing
// the step estimate, and the indoor VO₂ max.
//
// ⚠️ TWO LAZY ONE-TYPE REQUESTS, THE VO₂ MAX PATTERN (read `VO2MaxHealthWriter.swift` first). Running speed
// and running stride length are asked for the first time a sample of each is about to be written, each
// in its own request that names that one type in `toShare` and reads nothing. Neither type is in
// `HealthKitWriter.allTypes` or `authorizationReadTypes`, so no type is ever named by two requests (the
// build-50 defect) and the launch's re-prompt probe never sees them. Pinned by
// `HealthKitAuthorizationSurfaceTests` (the file's two requests) and `IndoorRunHealthTypesTests` (each
// request names only its type, neither type is spelled elsewhere, and neither is in the main sets).
//
// The distance type needs no new grant: `distanceWalkingRunning` is already shared (the daily estimate).

import Foundation
import HealthKit
import OpenCircuitKit

@MainActor
final class IndoorRunHealthWriter: IndoorRunHealthWriting {
    /// The two lazily asked types. Named once each so the source audit can pin the requests to them.
    static let runningSpeedType = HKQuantityType(.runningSpeed)
    static let runningStrideLengthType = HKQuantityType(.runningStrideLength)

    /// Method metadata of the indoor VO₂ max (decision 84g).
    static let indoorVO2MaxMethod = "ACSM running equation + Swain %HRR (estimate), treadmill distance + steps"

    private let store = HKHealthStore()
    private let samples: any IndoorRunSampleStoring

    init(samples: (any IndoorRunSampleStoring)? = nil) { self.samples = samples ?? HealthKitIndoorRunSamples() }

    // MARK: Per-minute speed and stride (84f)

    func saveRunningMetrics(_ minutes: [IndoorRunMinuteSample], estimated: Bool,
                            timeline: SyncDeviceID) async -> IndoorRunHealthStatus {
        guard HKHealthStore.isHealthDataAvailable(), HealthKitWriter().isShareAuthorized else { return .notConnected }
        guard !minutes.isEmpty else { return .saved }
        let speedAllowed = await askSpeed()
        let strideAllowed = await askStride()
        guard speedAllowed || strideAllowed else { return .sharingOff }
        let device = HealthKitWriter.wearableDevice(forTimeline: timeline, wearable: .shared)
        var metadata: [String: Any] = [HKMetadataKeyWasUserEntered: false]
        if estimated { metadata[IndoorRunMetadata.estimatedKey] = true }
        var samples: [HKQuantitySample] = []
        for minute in minutes {
            if speedAllowed {
                samples.append(HKQuantitySample(
                    type: Self.runningSpeedType,
                    quantity: HKQuantity(unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: minute.speed),
                    start: minute.start, end: minute.end, device: device, metadata: metadata))
            }
            if strideAllowed {
                samples.append(HKQuantitySample(
                    type: Self.runningStrideLengthType,
                    quantity: HKQuantity(unit: .meter(), doubleValue: minute.strideLength),
                    start: minute.start, end: minute.end, device: device, metadata: metadata))
            }
        }
        do {
            try await store.save(samples)
            return .saved
        } catch {
            helioLog.error("indoor run: running speed / stride not saved to Health")
            return .failed
        }
    }

    private func askSpeed() async -> Bool {
        switch store.authorizationStatus(for: Self.runningSpeedType) {
        case .sharingAuthorized: return true
        case .notDetermined:
            do { try await store.requestAuthorization(toShare: [Self.runningSpeedType], read: []) } catch { return false }
            return store.authorizationStatus(for: Self.runningSpeedType) == .sharingAuthorized
        default: return false
        }
    }

    private func askStride() async -> Bool {
        switch store.authorizationStatus(for: Self.runningStrideLengthType) {
        case .sharingAuthorized: return true
        case .notDetermined:
            do { try await store.requestAuthorization(toShare: [Self.runningStrideLengthType], read: []) } catch { return false }
            return store.authorizationStatus(for: Self.runningStrideLengthType) == .sharingAuthorized
        default: return false
        }
    }

    // MARK: The typed distance replaces the estimate (84e, 84f; review-indoor-run SF2a)

    /// The typed distance is SAVED FIRST and the estimate deleted only after that save succeeded, so a
    /// failure never leaves the workout with no distance in Health:
    ///   • the query or the typed save fails → `.failed`, nothing changed (the estimate stays);
    ///   • the typed save succeeds but the delete fails → `.savedEstimateKept` (Health holds both);
    ///   • both succeed → `.saved`: exactly one distance sample for the workout, the typed one.
    func replaceEstimate(workout span: DateInterval, typedMeters: Double, timeline: SyncDeviceID) async -> IndoorRunHealthStatus {
        guard samples.healthConnected else { return .notConnected }
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        var types: [HKQuantityType] = [distanceType]
        for type in [Self.runningSpeedType, Self.runningStrideLengthType] where samples.isSharing(type) { types.append(type) }
        var estimated: [HKSample] = []
        do {
            for type in types { estimated += try await samples.estimatedSamples(of: type, in: span) }
        } catch {
            helioLog.error("indoor run: the step estimate could not be read from Health; the typed distance is not written")
            return .failed
        }
        // The treadmill measured it and the person typed it: no wearable is named.
        let typed = HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: typedMeters),
                                     start: span.start, end: span.end, metadata: [HKMetadataKeyWasUserEntered: true])
        do {
            try await samples.saveForWorkout(typed, workoutStart: span.start)
        } catch {
            helioLog.error("indoor run: the typed distance was not saved to Health; the estimate stays")
            return .failed
        }
        let estimatedMeters = estimated.compactMap { $0 as? HKQuantitySample }
            .filter { $0.quantityType == distanceType }
            .reduce(0.0) { $0 + $1.quantity.doubleValue(for: .meter()) }
        var deleted = true
        if !estimated.isEmpty {
            do { try await samples.delete(estimated) } catch {
                deleted = false
                helioLog.error("indoor run: the typed distance is saved but the estimate could not be removed")
            }
        }
        // The daily steps × stride distance nets out workout distance (`recordWorkoutWalkRunDistance`):
        // credit the typed distance, and undo the estimate's credit only when the estimate is gone from
        // Health. Today only (the rule's own).
        if Calendar.current.isDateInToday(span.end) {
            if deleted, estimatedMeters > 0 { HealthKitWriter.undoWorkoutWalkRunDistance(estimatedMeters) }
            HealthKitWriter.recordWorkoutWalkRunDistance(typedMeters)
            let key = HealthKitWriter.workoutCreditsRevisionKey
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        }
        return deleted ? .saved : .savedEstimateKept
    }

    // MARK: Indoor VO₂ max (84g)

    func saveVO2Max(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date, timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status {
        await VO2MaxHealthWriter().save(estimate, workoutEnd: workoutEnd, timeline: timeline, method: Self.indoorVO2MaxMethod)
    }

}

/// What `replaceEstimate` needs from HealthKit, apart from it so the one-distance rule (save the typed
/// distance, then delete the estimate) is testable without HealthKit (review-indoor-run SF3).
@MainActor
protocol IndoorRunSampleStoring: AnyObject {
    /// Apple Health is available and the app's main share grant is in place.
    var healthConnected: Bool { get }
    func isSharing(_ type: HKQuantityType) -> Bool
    /// This app's own samples of `type` inside `span` that carry `OpenCircuitEstimated = true`.
    func estimatedSamples(of type: HKQuantityType, in span: DateInterval) async throws -> [HKSample]
    /// Save `sample`, associated with this app's workout that started at `workoutStart` when it exists.
    func saveForWorkout(_ sample: HKQuantitySample, workoutStart: Date) async throws
    func delete(_ samples: [HKSample]) async throws
}

@MainActor
final class HealthKitIndoorRunSamples: IndoorRunSampleStoring {
    private let store = HKHealthStore()

    var healthConnected: Bool { HKHealthStore.isHealthDataAvailable() && HealthKitWriter().isShareAuthorized }

    func isSharing(_ type: HKQuantityType) -> Bool { store.authorizationStatus(for: type) == .sharingAuthorized }

    /// The predicate: this app as the source, wholly inside the workout's span, marked estimated.
    static func estimatePredicate(_ span: DateInterval) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: [.strictStartDate, .strictEndDate]),
            HKQuery.predicateForObjects(withMetadataKey: IndoorRunMetadata.estimatedKey, allowedValues: [true]),
        ])
    }

    func estimatedSamples(of type: HKQuantityType, in span: DateInterval) async throws -> [HKSample] {
        try await samples(of: type, predicate: Self.estimatePredicate(span))
    }

    func saveForWorkout(_ sample: HKQuantitySample, workoutStart: Date) async throws {
        if let workout = try await ownWorkout(startingAt: workoutStart) {
            // Associated with the workout, so deleting the workout from the history deletes it too
            // (`HealthKitWorkoutStore.deleteOwnedSamples`). HealthKit keeps a finished workout's own
            // totals as written; decision 84j saves an indoor run's workout only once the prompt is
            // answered or skipped, so this path is only for a distance typed after that save.
            try await store.addSamples([sample], to: workout)
        } else {
            try await store.save(sample)
        }
    }

    func delete(_ samples: [HKSample]) async throws { try await store.delete(samples) }

    private func ownWorkout(startingAt start: Date) async throws -> HKWorkout? {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1),
                                        options: [.strictStartDate]),
        ])
        return try await samples(of: HKWorkoutType.workoutType(), predicate: predicate)
            .compactMap { $0 as? HKWorkout }
            .first { abs($0.startDate.timeIntervalSince(start)) < 1 }
    }

    private func samples(of type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }
}
