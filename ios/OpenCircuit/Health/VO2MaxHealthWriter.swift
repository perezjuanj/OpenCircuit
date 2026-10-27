// VO2MaxHealthWriter.swift — writes a run's VO₂ max ESTIMATE to Apple Health (#232), asking for the
// `vo2Max` share grant lazily: the first time an estimate is about to be written, never at launch.
//
// ⚠️ WHY THIS IS A SECOND AUTHORIZATION REQUEST, AND WHY IT CANNOT BE THE BUILD-50 DEFECT.
// `HealthKitWriter.requestAuthorization()` is otherwise the app's one request, and that rule is a scar
// (see `HealthKitWriter.authorizationReadTypes`): build 50 added a request naming a type the main
// request ALSO named, with a different share/read membership, and testers lost the workout write grant
// in a loop (#210 is the same family). The property that made that reachable is "two requests
// disagree about one type". This request names exactly one type, `vo2Max`, in `toShare`, with an
// empty read set, and `vo2Max` is in NEITHER of the main request's sets — so no type ever appears in
// two requests. Both halves are pinned by tests:
//   • `HealthKitAuthorizationSurfaceTests` (Kit, source audit) allows this file exactly one request,
//     requires it to share only `vo2MaxType` and read nothing, and forbids the vo2Max HealthKit
//     type anywhere else in the app;
//   • `HealthKitShareTypesTests` (app) asserts `vo2Max` is in neither `allTypes` nor
//     `authorizationReadTypes`.
// Keeping `vo2Max` out of `allTypes` is also what keeps it off the launch path: the #129 upgrade
// re-prompt (`authorizationPromptAvailable`) probes `allTypes`, so adding it there would put a sheet
// in front of every existing install on launch — which the brief for #232 rules out.
//
// What has NOT been observed: this request running on a device that already holds the main grant.
// The PR asks for that on-phone check (grant VO₂ max, then confirm Workouts and Heart Rate are still
// on in Health ▸ Sharing ▸ Apps ▸ OpenCircuit).

import Foundation
import HealthKit
import OpenCircuitKit

@MainActor
struct VO2MaxHealthWriter {
    /// The one type this writer shares. Named once so the source audit can pin the request to it.
    static let vo2MaxType = HKQuantityType(.vo2Max)

    /// mL·kg⁻¹·min⁻¹, HealthKit's VO₂ max unit.
    static let unit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    /// Our own marker naming the method, next to Apple's test-type key. The test type is
    /// `HKVO2MaxTestType.predictionSubMaxExercise` — Apple's "predicted from submaximal exercise"
    /// (there is no `.predictionSubMaximal` case in the SDK).
    static let methodMetadataKey = "OpenCircuitVO2MaxMethod"
    static let methodMetadataValue = "ACSM running equation + Swain %HRR (estimate)"

    enum Status: Equatable {
        case saved
        /// Health isn't connected at all (the main grant is missing), so no VO₂ max prompt is shown.
        case healthNotConnected
        /// The user declined or later turned off VO₂ max sharing.
        case sharingOff
        case failed
    }

    private let store = HKHealthStore()

    /// Save `estimate`, prompting for the `vo2Max` share grant only if it was never asked for.
    ///
    /// Never prompts someone who hasn't connected Apple Health (heart-rate share, the app's
    /// representative grant, is off): a VO₂-max-only sheet would be the first Health prompt they see,
    /// out of context, and their workout itself wasn't written either.
    ///
    /// `timeline` is the wearable whose heart rate the estimate came from: the ring for a ring workout,
    /// the strap for a strap workout (#232 on the strap).
    /// `method` is the metadata value naming how the estimate was made: the outdoor run's
    /// `methodMetadataValue`, or the indoor run's "treadmill distance + steps" (decision 84g).
    func save(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date,
              timeline: SyncDeviceID = .ringConn, method: String = Self.methodMetadataValue) async -> Status {
        guard HKHealthStore.isHealthDataAvailable() else { return .healthNotConnected }
        guard HealthKitWriter().isShareAuthorized else { return .healthNotConnected }

        switch store.authorizationStatus(for: Self.vo2MaxType) {
        case .sharingAuthorized:
            break
        case .sharingDenied:
            return .sharingOff
        case .notDetermined:
            do {
                try await store.requestAuthorization(toShare: [Self.vo2MaxType], read: [])
            } catch {
                return .failed
            }
            guard store.authorizationStatus(for: Self.vo2MaxType) == .sharingAuthorized else {
                return .sharingOff
            }
        @unknown default:
            return .sharingOff
        }

        let quantity = HKQuantity(unit: Self.unit, doubleValue: estimate.vo2Max)
        let metadata: [String: Any] = [
            HKMetadataKeyVO2MaxTestType: HKVO2MaxTestType.predictionSubMaxExercise.rawValue,
            HKMetadataKeyWasUserEntered: false,
            Self.methodMetadataKey: method,
        ]
        // The estimate names the wearable whose heart rate it came from (the ring's or the strap's
        // workout), like BP and the distance estimate (review-224b N-2): attribution follows the
        // data, never the current device choice (decision 28).
        let sample = HKQuantitySample(type: Self.vo2MaxType, quantity: quantity,
                                      start: workoutEnd, end: workoutEnd,
                                      device: HealthKitWriter.wearableDevice(forTimeline: timeline, wearable: .shared),
                                      metadata: metadata)
        do {
            try await store.save(sample)
            return .saved
        } catch {
            return .failed
        }
    }
}
