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

    // MARK: Partial-grant share state (#132)

    /// A PARTIAL grant (heart rate on, other types off) must resolve to `.partial` with exactly the
    /// denied set — not the blanket "authorized" that silently drops those metrics.
    func testShareStatePartialListsDeniedTypes() {
        let types = HealthKitWriter().allTypes
        let spo2 = HKQuantityType(.oxygenSaturation)
        let temp = HKQuantityType(.bodyTemperature)
        let state = HealthKitWriter.resolveShareState(authorizableTypes: types) { type in
            (type.isEqual(spo2) || type.isEqual(temp)) ? .sharingDenied : .sharingAuthorized
        }
        guard case .partial(let denied) = state else {
            return XCTFail("expected .partial, got \(state)")
        }
        XCTAssertEqual(Set(denied), [spo2, temp])
    }

    func testShareStateAuthorizedWhenAllGranted() {
        let types = HealthKitWriter().allTypes
        let state = HealthKitWriter.resolveShareState(authorizableTypes: types) { _ in .sharingAuthorized }
        XCTAssertEqual(state, .authorized)
    }

    /// Heart rate itself not granted ⇒ unauthorized regardless of the rest (mirrors isShareAuthorized).
    func testShareStateUnauthorizedWhenHeartRateNotGranted() {
        let types = HealthKitWriter().allTypes
        let state = HealthKitWriter.resolveShareState(authorizableTypes: types) { type in
            type.isEqual(HKQuantityType(.heartRate)) ? .notDetermined : .sharingAuthorized
        }
        XCTAssertEqual(state, .unauthorized)
    }

    /// Friendly names map through MetricKind, collapse both BP constituents to one label, and sort.
    func testFriendlyNamesMapAndDedupe() {
        let names = HealthKitWriter.friendlyNames(for: [
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.bodyTemperature),
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic),   // collapses with systolic → one "Blood Pressure"
            HKCategoryType(.sleepAnalysis),
        ])
        XCTAssertEqual(names, ["Blood Pressure", "Skin Temp", "Sleep", "SpO₂"])
    }

    // MARK: Persisted per-metric write-failure map (#135)

    /// The failure map stamps failed metrics, clears a metric on its next successful write, and
    /// keeps "nothing pending" (empty map) distinct from "writes failing".
    func testWriteFailureMapPersistsAndClearsPerMetric() {
        let suite = "HealthKitShareTypesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(HealthKitWriter.healthWriteFailures(defaults).isEmpty)

        // SpO₂ + Sleep fail this pass; HR wrote fine.
        HealthKitWriter.recordFlushOutcome(written: [.heartRate], failed: [.spo2, .sleep],
                                           now: Date(timeIntervalSince1970: 1000), defaults)
        XCTAssertEqual(Set(HealthKitWriter.healthWriteFailures(defaults).keys), [.spo2, .sleep])

        // Next pass: SpO₂ recovers (a later success wins), Sleep still failing → only Sleep remains.
        HealthKitWriter.recordFlushOutcome(written: [.spo2], failed: [.sleep],
                                           now: Date(timeIntervalSince1970: 2000), defaults)
        XCTAssertEqual(Set(HealthKitWriter.healthWriteFailures(defaults).keys), [.sleep])

        // Sleep recovers → map empties (back to a clean "nothing failing" state).
        HealthKitWriter.recordFlushOutcome(written: [.sleep], failed: [],
                                           now: Date(timeIntervalSince1970: 3000), defaults)
        XCTAssertTrue(HealthKitWriter.healthWriteFailures(defaults).isEmpty)
    }

    /// A FlushResult with a failure but no writes is still NOT "wrote anything" — the UI must be able
    /// to tell an idle store (no failures) from a failing one.
    func testFlushResultFailuresDefaultEmptyAndDoNotCountAsWrite() {
        var r = HealthKitWriter.FlushResult()
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertFalse(r.wroteAnything)
        r.failures = [.sleep]
        XCTAssertFalse(r.wroteAnything)
    }

    /// Distance is DERIVED from step rows and rides their single watermark, so it must only write
    /// when steps saved — else a granted distance re-derives + re-writes every flush while the rows
    /// stay pending and HealthKit sums the duplicate (~N× inflation). Guards that regression.
    func testDistanceOnlyWritesWhenStepsSucceeded() {
        // Steps failed → distance must NOT write/commit, regardless of distance's own status.
        XCTAssertFalse(HealthKitWriter.distanceMayWrite(stepsFailed: true, distanceFailed: false))
        XCTAssertFalse(HealthKitWriter.distanceMayWrite(stepsFailed: true, distanceFailed: true))
        // Steps ok + distance denied → skip distance (deferred with the rows).
        XCTAssertFalse(HealthKitWriter.distanceMayWrite(stepsFailed: false, distanceFailed: true))
        // Both ok → distance writes.
        XCTAssertTrue(HealthKitWriter.distanceMayWrite(stepsFailed: false, distanceFailed: false))
    }

    func testDailyActiveEnergyNetsWorkoutCaloriesFromChosenDailyEstimate() {
        // HR channel dominates → credit nets the HR-derived daily estimate.
        XCTAssertEqual(
            HealthKitWriter.netDailyActiveKcalEstimate(hrKcal: 300, stepKcal: 80, workoutActiveKcal: 125),
            175,
            accuracy: 0.001
        )
        // HR channel dominates but the workout kcal exceeds it → clamp at 0 (never negative).
        XCTAssertEqual(
            HealthKitWriter.netDailyActiveKcalEstimate(hrKcal: 100, stepKcal: 80, workoutActiveKcal: 125),
            0,
            accuracy: 0.001
        )
        // Step channel dominates (indoor/treadmill: steps counted, HR sparse) → credit STILL nets
        // the step-derived estimate. The old "HR side only" netting left this double-counted.
        XCTAssertEqual(
            HealthKitWriter.netDailyActiveKcalEstimate(hrKcal: 50, stepKcal: 200, workoutActiveKcal: 120),
            80,
            accuracy: 0.001
        )
        // No workout → the plain daily estimate (larger of the two channels) passes through.
        XCTAssertEqual(
            HealthKitWriter.netDailyActiveKcalEstimate(hrKcal: 90, stepKcal: 140, workoutActiveKcal: 0),
            140,
            accuracy: 0.001
        )
    }
}
