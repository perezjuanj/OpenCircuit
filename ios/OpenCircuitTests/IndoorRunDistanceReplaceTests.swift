import HealthKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// The one-distance rule (decision 84e/84f, review-indoor-run SF2a/SF3): a typed treadmill distance is
// SAVED first, and only then are this app's estimated distance, speed and stride samples inside the
// workout deleted. Afterwards the workout has exactly one distance sample, the typed one. A failed
// save changes nothing; a failed delete says Health holds both. `IndoorRunHealthWriter.replaceEstimate`
// over a fake sample store; every value is synthetic and rounded, on a day that isn't today (so no
// daily distance credit moves).

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

@MainActor
private final class FakeSamples: IndoorRunSampleStoring {
    var healthConnected = true
    var sharing: Set<HKQuantityType> = [HKQuantityType(.runningSpeed), HKQuantityType(.runningStrideLength)]
    private(set) var stored: [HKQuantitySample] = []
    private(set) var log: [String] = []
    var failSave = false
    var failDelete = false
    var failQuery = false

    func add(_ sample: HKQuantitySample) { stored.append(sample) }

    func isSharing(_ type: HKQuantityType) -> Bool { sharing.contains(type) }

    /// What `HealthKitIndoorRunSamples.estimatePredicate` selects: inside the span, marked estimated.
    func estimatedSamples(of type: HKQuantityType, in span: DateInterval) async throws -> [HKSample] {
        log.append("query")
        if failQuery { throw NSError(domain: "fake", code: 1) }
        return stored.filter {
            $0.quantityType == type && $0.startDate >= span.start && $0.endDate <= span.end
                && ($0.metadata?[IndoorRunMetadata.estimatedKey] as? Bool) == true
        }
    }

    func saveForWorkout(_ sample: HKQuantitySample, workoutStart: Date) async throws {
        log.append("save")
        if failSave { throw NSError(domain: "fake", code: 2) }
        stored.append(sample)
    }

    func delete(_ samples: [HKSample]) async throws {
        log.append("delete")
        if failDelete { throw NSError(domain: "fake", code: 3) }
        let ids = Set(samples.map(\.uuid))
        stored.removeAll { ids.contains($0.uuid) }
    }

    func distances() -> [Double] {
        stored.filter { $0.quantityType == HKQuantityType(.distanceWalkingRunning) }
            .map { $0.quantity.doubleValue(for: .meter()) }
    }
}

@MainActor
final class IndoorRunDistanceReplaceTests: XCTestCase {
    private let span = DateInterval(start: t0, end: at(1_200))
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-REPLACE")

    private func quantity(_ type: HKQuantityTypeIdentifier, _ value: Double, unit: HKUnit, from: TimeInterval, to: TimeInterval,
                          estimated: Bool) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(type), quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: at(from), end: at(to),
                         metadata: estimated ? [IndoorRunMetadata.estimatedKey: true] : [:])
    }

    /// The workout as End left it: the estimate distance and two estimated minutes of speed and stride,
    /// plus an unrelated typed sample before the workout that must never be touched.
    private func endedWorkout() -> FakeSamples {
        let fake = FakeSamples()
        fake.add(quantity(.distanceWalkingRunning, 3_510, unit: .meter(), from: 0, to: 1_200, estimated: true))
        for m in [0.0, 60] {
            fake.add(quantity(.runningSpeed, 3.25, unit: HKUnit.meter().unitDivided(by: .second()), from: m, to: m + 60, estimated: true))
            fake.add(quantity(.runningStrideLength, 1.17, unit: .meter(), from: m, to: m + 60, estimated: true))
        }
        fake.add(quantity(.distanceWalkingRunning, 500, unit: .meter(), from: -3_600, to: -3_000, estimated: false))
        return fake
    }

    func testATypedDistanceIsSavedFirstAndThenTheEstimateIsDeletedLeavingOneDistanceForTheWorkout() async {
        let fake = endedWorkout()
        let status = await IndoorRunHealthWriter(samples: fake).replaceEstimate(workout: span, typedMeters: 3_900, timeline: timeline)
        XCTAssertEqual(status, .saved)
        XCTAssertEqual(Array(fake.log.suffix(2)), ["save", "delete"], "the estimate goes only after the typed distance is in")
        let inWorkout = fake.stored.filter { $0.startDate >= span.start && $0.endDate <= span.end }
        XCTAssertEqual(inWorkout.filter { $0.quantityType == HKQuantityType(.distanceWalkingRunning) }
            .map { $0.quantity.doubleValue(for: .meter()) }, [3_900], "exactly one distance for the workout: the typed one")
        XCTAssertEqual(inWorkout.filter { $0.quantityType != HKQuantityType(.distanceWalkingRunning) }.count, 0,
                       "the estimated speed and stride go with it")
        XCTAssertEqual(fake.distances().sorted(), [500, 3_900], "nothing outside the workout, and nothing typed, is touched")
        let typed = fake.stored.first { $0.quantity.doubleValue(for: .meter()) == 3_900 }
        XCTAssertEqual(typed?.metadata?[HKMetadataKeyWasUserEntered] as? Bool, true)
        XCTAssertNil(typed?.metadata?[IndoorRunMetadata.estimatedKey])
    }

    func testAFailedTypedSaveDeletesNothingSoTheEstimateStays() async {
        let fake = endedWorkout()
        fake.failSave = true
        let status = await IndoorRunHealthWriter(samples: fake).replaceEstimate(workout: span, typedMeters: 3_900, timeline: timeline)
        XCTAssertEqual(status, .failed)
        XCTAssertFalse(fake.log.contains("delete"))
        XCTAssertEqual(fake.distances().sorted(), [500, 3_510])
    }

    func testAFailedQueryChangesNothing() async {
        let fake = endedWorkout()
        fake.failQuery = true
        let status = await IndoorRunHealthWriter(samples: fake).replaceEstimate(workout: span, typedMeters: 3_900, timeline: timeline)
        XCTAssertEqual(status, .failed)
        XCTAssertEqual(fake.log, ["query"])
        XCTAssertEqual(fake.distances().sorted(), [500, 3_510])
    }

    func testAFailedDeleteKeepsBothAndSaysSo() async {
        let fake = endedWorkout()
        fake.failDelete = true
        let status = await IndoorRunHealthWriter(samples: fake).replaceEstimate(workout: span, typedMeters: 3_900, timeline: timeline)
        XCTAssertEqual(status, .savedEstimateKept)
        XCTAssertEqual(fake.distances().sorted(), [500, 3_510, 3_900])
    }

    func testHealthNotConnectedTouchesNothing() async {
        let fake = endedWorkout()
        fake.healthConnected = false
        let status = await IndoorRunHealthWriter(samples: fake).replaceEstimate(workout: span, typedMeters: 3_900, timeline: timeline)
        XCTAssertEqual(status, .notConnected)
        XCTAssertEqual(fake.log, [])
    }

    func testRunningTypesNotSharedAreNeitherQueriedNorDeleted() async {
        let fake = endedWorkout()
        fake.sharing = []
        let status = await IndoorRunHealthWriter(samples: fake).replaceEstimate(workout: span, typedMeters: 3_900, timeline: timeline)
        XCTAssertEqual(status, .saved)
        XCTAssertEqual(fake.log.filter { $0 == "query" }.count, 1, "the distance only")
        XCTAssertEqual(fake.distances().sorted(), [500, 3_900])
    }
}
