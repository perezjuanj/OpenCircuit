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

    // MARK: #41 — wear / charging gate

    /// A 4 h still motion block (would detect as sleep) sampled every 5 min.
    private func stillNight() -> [MotionSample] {
        (0..<48).map { MotionSample(time: base.addingTimeInterval(Double($0) * 5 * 60), movement: 1) }
    }
    private func temps(_ celsius: Double) -> [TemperatureSample] {
        (0..<48).map { TemperatureSample(time: base.addingTimeInterval(Double($0) * 5 * 60), celsius: celsius) }
    }

    func testWearGateReclassifiesColdStillBlockAsActive() {
        let motion = stillNight()
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion).first?.activity, .sleep,
                       "motion-only: a still block reads as sleep")
        // Same motion, but skin temp ~22 °C (off-wrist / charging) -> no sleep survives.
        let gated = ActivityPeriod.detectFromMotion(motion, temperatureSamples: temps(22))
        XCTAssertFalse(gated.contains { $0.activity == .sleep },
                       "cold (unworn) still block must not count as sleep")
    }

    func testWearGateKeepsWarmStillBlockAsSleep() {
        let gated = ActivityPeriod.detectFromMotion(stillNight(), temperatureSamples: temps(32))
        XCTAssertEqual(gated.first?.activity, .sleep, "worn (32 °C) still block stays sleep")
    }

    func testWearGateNoTemperatureLeavesDetectionUnchanged() {
        let motion = stillNight()
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion, temperatureSamples: []),
                       ActivityPeriod.detectFromMotion(motion),
                       "no temperature coverage -> identical to motion-only (absence ≠ unworn)")
    }
}
