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

    // MARK: The typed distance replaces the estimate (84e, 84f)

    func replaceEstimate(workout span: DateInterval, typedMeters: Double, timeline: SyncDeviceID) async -> IndoorRunHealthStatus {
        guard HKHealthStore.isHealthDataAvailable(), HealthKitWriter().isShareAuthorized else { return .notConnected }
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        // This app's own estimated samples inside the workout (never anything else's, never a typed one).
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForSamples(withStart: span.start, end: span.end, options: [.strictStartDate, .strictEndDate]),
            HKQuery.predicateForObjects(withMetadataKey: IndoorRunMetadata.estimatedKey, allowedValues: [true]),
        ])
        var estimated: [HKSample] = []
        var types: [HKQuantityType] = [distanceType]
        for type in [Self.runningSpeedType, Self.runningStrideLengthType]
        where store.authorizationStatus(for: type) == .sharingAuthorized { types.append(type) }
        do {
            for type in types { estimated += try await samples(of: type, predicate: predicate) }
            if !estimated.isEmpty { try await store.delete(estimated) }
        } catch {
            helioLog.error("indoor run: the step estimate could not be removed from Health; the typed distance is not written")
            return .failed
        }
        let estimatedMeters = estimated.compactMap { $0 as? HKQuantitySample }
            .filter { $0.quantityType == distanceType }
            .reduce(0.0) { $0 + $1.quantity.doubleValue(for: .meter()) }
        // The treadmill measured it and the person typed it: no wearable is named.
        let sample = HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: typedMeters),
                                      start: span.start, end: span.end, metadata: [HKMetadataKeyWasUserEntered: true])
        do {
            if let workout = try await ownWorkout(startingAt: span.start) {
                // Associated with the workout, so deleting the workout from the history deletes it too
                // (`HealthKitWorkoutStore.deleteOwnedSamples`). HealthKit keeps a finished workout's own
                // totals as written, so its summary may still show the estimate (see the PR body).
                try await store.addSamples([sample], to: workout)
            } else {
                try await store.save(sample)
            }
        } catch {
            helioLog.error("indoor run: the typed distance was not saved to Health")
            return .failed
        }
        // The daily steps × stride distance nets out workout distance (`recordWorkoutWalkRunDistance`):
        // swap the estimate it was credited with for the typed distance, today only (the rule's own).
        if Calendar.current.isDateInToday(span.end) {
            if estimatedMeters > 0 { HealthKitWriter.undoWorkoutWalkRunDistance(estimatedMeters) }
            HealthKitWriter.recordWorkoutWalkRunDistance(typedMeters)
            let key = HealthKitWriter.workoutCreditsRevisionKey
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        }
        return .saved
    }

    // MARK: Indoor VO₂ max (84g)

    func saveVO2Max(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date, timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status {
        await VO2MaxHealthWriter().save(estimate, workoutEnd: workoutEnd, timeline: timeline, method: Self.indoorVO2MaxMethod)
    }

    // MARK: Queries

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
