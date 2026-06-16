import XCTest
@testable import OpenRingKit

// Parity with openwhoop-algos/src/activity.rs unit tests.
final class SleepDetectionTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func reading(_ minutes: Int, _ g: SIMD3<Float>?) -> GravitySample {
        GravitySample(time: base.addingTimeInterval(Double(minutes) * 60), gravity: g)
    }

    func testEmptyAndSingle() {
        XCTAssertTrue(ActivityPeriod.detectFromGravity([]).isEmpty)
        XCTAssertTrue(ActivityPeriod.detectFromGravity([reading(0, SIMD3(0, 0, 1))]).isEmpty)
    }

    func testAllStillIsSleep() {
        let h = (0..<120).map { reading($0, SIMD3(0, 0, 1)) }
        let p = ActivityPeriod.detectFromGravity(h)
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.first?.activity, .sleep)
    }

    func testAllMovingIsActive() {
        let h = (0..<120).map { reading($0, SIMD3($0 % 2 == 0 ? 1 : -1, 0, 0)) }
        XCTAssertEqual(ActivityPeriod.detectFromGravity(h).first?.activity, .active)
    }

    func testNoGravityIsActive() {
        let h = (0..<120).map { reading($0, nil) }
        XCTAssertEqual(ActivityPeriod.detectFromGravity(h).first?.activity, .active)
    }

    func testGapBreaksRun() {
        var h = (0..<60).map { reading($0, SIMD3(0, 0, 1)) }
        h += (120..<180).map { reading($0, SIMD3(0, 0, 1)) }
        XCTAssertGreaterThanOrEqual(ActivityPeriod.detectFromGravity(h).count, 2)
    }

    func testFindSleepReturnsLong() {
        var events = [
            ActivityPeriod(activity: .active, start: base, end: base.addingTimeInterval(30 * 60)),
            ActivityPeriod(activity: .sleep, start: base.addingTimeInterval(30 * 60), end: base.addingTimeInterval(300 * 60)),
        ]
        XCTAssertEqual(ActivityPeriod.findSleep(&events)?.activity, .sleep)
    }

    func testFindSleepIgnoresShort() {
        var events = [ActivityPeriod(activity: .sleep, start: base, end: base.addingTimeInterval(30 * 60))]
        XCTAssertNil(ActivityPeriod.findSleep(&events))
    }

    func testFindSleepEmpty() {
        var events: [ActivityPeriod] = []
        XCTAssertNil(ActivityPeriod.findSleep(&events))
    }

    func testIsActive() {
        XCTAssertTrue(ActivityPeriod(activity: .active, start: base, end: base.addingTimeInterval(3600)).isActive)
        XCTAssertFalse(ActivityPeriod(activity: .sleep, start: base, end: base.addingTimeInterval(3600)).isActive)
    }

    // MARK: #41 — wear detection (analytics layer)

    private func tempSample(_ minutes: Int, _ degC: Double) -> TemperatureSample {
        TemperatureSample(time: base.addingTimeInterval(Double(minutes) * 60), tempCelsius: degC)
    }

    func testStillColdEpochNotClassifiedAsSleep() {
        // 2h of perfectly still gravity → would be "sleep" with detectFromGravity.
        // Ring temperature = 18 °C (off-wrist / charger) → must NOT classify as sleep.
        let h = (0..<120).map { reading($0, SIMD3(0, 0, 1)) }
        let temps = (0..<120).map { tempSample($0, 18.0) }

        let periods = ActivityPeriod.detectFromMotion(h, temperatureSamples: temps)
        XCTAssertFalse(
            periods.contains { $0.activity == .sleep },
            "A still but cold (off-wrist / charging) block must not be classified as sleep — #41 regression guard"
        )
    }

    func testStillWarmEpochClassifiedAsSleep() {
        // Same motion profile but ring is warm (31 °C = worn) → should still detect sleep.
        let h = (0..<120).map { reading($0, SIMD3(0, 0, 1)) }
        let temps = (0..<120).map { tempSample($0, 31.0) }

        let periods = ActivityPeriod.detectFromMotion(h, temperatureSamples: temps)
        XCTAssertTrue(
            periods.contains { $0.activity == .sleep },
            "A still worn (warm) block should be classified as sleep"
        )
    }

    func testNoTemperatureDataPassesThrough() {
        // Without temperature samples, detectFromMotion == detectFromGravity (still = sleep).
        let h = (0..<120).map { reading($0, SIMD3(0, 0, 1)) }
        let viaMotion = ActivityPeriod.detectFromMotion(h, temperatureSamples: [])
        let viaGravity = ActivityPeriod.detectFromGravity(h)
        XCTAssertEqual(viaMotion, viaGravity)
    }

    func testWearDetectionMinWornThreshold() {
        // Exactly at the threshold (30 °C) → worn.
        XCTAssertEqual(WearDetection.state(tempCelsius: 30.0), .worn)
        // Just below → notWorn.
        XCTAssertEqual(WearDetection.state(tempCelsius: 29.9), .notWorn)
    }

    func testWearDetectionNoSamplesDefaultsToWorn() {
        // No temperature samples in window → fail-open (assume worn, keep data).
        let period = ActivityPeriod(activity: .sleep, start: base, end: base.addingTimeInterval(3600))
        XCTAssertEqual(WearDetection.wornState(during: period, from: []), .worn)
    }

    func testWearDetectionAverageBelowThreshold() {
        // Mix of samples: average = (28 + 29) / 2 = 28.5 < 30 → notWorn.
        let period = ActivityPeriod(activity: .sleep,
                                    start: base,
                                    end: base.addingTimeInterval(120 * 60))
        let temps = [tempSample(0, 28.0), tempSample(60, 29.0)]
        XCTAssertEqual(WearDetection.wornState(during: period, from: temps), .notWorn)
    }
}
