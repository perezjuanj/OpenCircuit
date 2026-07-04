import HealthKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

@MainActor
final class HealthKitShareTypesTests: XCTestCase {
    /// Correlation types (blood pressure) are NOT authorizable: putting one in the `toShare`
    /// set of `requestAuthorization`/`statusForAuthorizationRequest` raises the same
    /// uncatchable NSInvalidArgumentException as #110 — it crashed the app whenever the auth
    /// path ran after PR #121 added it (e.g. right after the user revoked Health access in the
    /// Health app, when the auth-recovery path re-requests). BP auth rides on the two
    /// constituent quantity types instead; guard against the correlation type creeping back.
    func testAuthTypeSetContainsNoCorrelationTypes() {
        let types = HealthKitWriter().allTypes
        XCTAssertFalse(types.contains { $0 is HKCorrelationType },
                       "correlation types must never enter the HealthKit auth set")
        XCTAssertTrue(types.contains(HKQuantityType(.bloodPressureSystolic)))
        XCTAssertTrue(types.contains(HKQuantityType(.bloodPressureDiastolic)))
    }

    /// Apple Exercise Time is an Apple-COMPUTED Activity-ring metric and is NOT third-party
    /// shareable. Listing it in HealthKit's auth `toShare` set raises an Obj-C
    /// NSInvalidArgumentException (-[HKHealthStore _throwIfAuthorizationDisallowedForSharing:])
    /// that crashed the app on first Health authorization (TestFlight #110). It must therefore
    /// have no writable quantity type, which excludes it from both the auth request and the
    /// write path. Guard against it silently creeping back in.
    func testExerciseMinutesHasNoWritableHealthKitType() {
        XCTAssertNil(HealthKitWriter.quantityType(for: .exerciseMinutes))
    }

    /// Sanity: the genuinely writable ring metrics still map to a quantity type, so the fix
    /// above didn't over-broadly drop real Health writes.
    func testWritableMetricsStillMapToAType() {
        for kind in [MetricKind.heartRate, .restingHeartRate, .hrvSDNN, .spo2, .temperature,
                     .respiratoryRate, .steps, .activeEnergy, .distance] {
            XCTAssertNotNil(HealthKitWriter.quantityType(for: kind), "\(kind) should be writable")
        }
    }

    func testEnergyWritesCountAsFlushOutput() {
        var basal = HealthKitWriter.FlushResult()
        basal.passiveHours = 1
        XCTAssertTrue(basal.wroteAnything)

        var active = HealthKitWriter.FlushResult()
        active.activeKcal = 12.5
        XCTAssertTrue(active.wroteAnything)
    }

    func testWorkoutActiveKcalLedgerIsDayScopedAndAccumulates() {
        let suite = "HealthKitShareTypesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let day = Date(timeIntervalSince1970: 10_000)
        HealthKitWriter.recordWorkoutActiveKcal(80, day: day, defaults)
        HealthKitWriter.recordWorkoutActiveKcal(20, day: day.addingTimeInterval(60), defaults)

        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 100)

        HealthKitWriter.recordWorkoutActiveKcal(30, day: day.addingTimeInterval(86_400), defaults)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 30)
    }

    func testDailyActiveEnergyNetsWorkoutCaloriesOnlyFromHRSide() {
        XCTAssertEqual(
            HealthKitWriter.netDailyActiveKcalEstimate(hrKcal: 300, stepKcal: 80, workoutActiveKcal: 125),
            175,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HealthKitWriter.netDailyActiveKcalEstimate(hrKcal: 100, stepKcal: 80, workoutActiveKcal: 125),
            80,
            accuracy: 0.001
        )
    }
}
