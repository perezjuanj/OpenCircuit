import XCTest
@testable import OpenCircuitKit

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

    // MARK: HR gate — awake-but-still rejection (the "sleep while I was out" bug, 2026-06-23)

    /// Still motion across `[startMin, endMin)` at 5-min cadence (reads as sleep, motion-only).
    private func stillMotion(_ startMin: Int, _ endMin: Int) -> [MotionSample] {
        stride(from: startMin, to: endMin, by: 5).map {
            MotionSample(time: base.addingTimeInterval(Double($0) * 60), movement: 1)
        }
    }
    private func hrSeries(_ startMin: Int, _ endMin: Int, bpm: Int) -> [HeartRateSample] {
        stride(from: startMin, to: endMin, by: 5).map {
            HeartRateSample(time: base.addingTimeInterval(Double($0) * 60), bpm: bpm)
        }
    }
    /// Is `minute` inside a detected `.sleep` period?
    private func sleepCovers(_ minute: Int, _ periods: [ActivityPeriod]) -> Bool {
        let t = base.addingTimeInterval(Double(minute) * 60)
        return periods.contains { $0.activity == .sleep && $0.start <= t && $0.end >= t }
    }

    /// The reported failure: a still-but-AWAKE evening (sitting out late, HR ~108) staged as sleep,
    /// then real low-HR sleep after a buffer gap. Motion-only stages the evening; the HR gate removes
    /// it and keeps the real block. Models the 2026-06-23 night: evening "sleep" 97–120 bpm, then the
    /// 00:09→06:29 HR hole (the overnight drain gap), then real sleep ~64 bpm — floor ~64.
    func testHeartRateGateRejectsAwakeStillEveningBlock() {
        // 60-min data gap (120→180) > gravityMaxGap → detect() breaks the run, so the two still
        // blocks are separate periods (no fragile reliance on the motion floor splitting them).
        let motion = stillMotion(0, 120) + stillMotion(180, 480)
        let hr = hrSeries(0, 120, bpm: 108) + hrSeries(180, 480, bpm: 64)

        let motionOnly = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [])
        XCTAssertTrue(sleepCovers(60, motionOnly), "motion-only stages the still evening as sleep")

        let gated = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: hr)
        XCTAssertFalse(sleepCovers(60, gated), "awake-but-still evening (HR 108 ≫ floor) must not be sleep")
        XCTAssertTrue(sleepCovers(300, gated), "real low-HR (64 bpm) sleep block survives the gate")
    }

    /// No regression: a genuinely still, low-HR night stays sleep (median near the floor).
    func testHeartRateGateKeepsRealLowHRSleep() {
        let gated = ActivityPeriod.detectFromMotion(stillMotion(0, 300), temperatureSamples: [],
                                                    heartRateSamples: hrSeries(0, 300, bpm: 60))
        XCTAssertEqual(gated.first?.activity, .sleep, "uniformly low-HR still night stays sleep")
    }

    /// No HR coverage → identical to motion-only (absence of HR is not evidence of wakefulness).
    func testHeartRateGateNoHRLeavesDetectionUnchanged() {
        let motion = stillMotion(0, 300)
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: []),
                       ActivityPeriod.detectFromMotion(motion),
                       "no HR coverage → identical to motion-only")
    }

    /// Too few HR readings → the gate stays out rather than acting on noise.
    func testHeartRateGateIgnoresSparseHR() {
        let motion = stillMotion(0, 300)
        let hr = [HeartRateSample(time: base, bpm: 120),
                  HeartRateSample(time: base.addingTimeInterval(60 * 60), bpm: 120)]   // < minHRSamplesForGate
        XCTAssertEqual(ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: hr).first?.activity,
                       .sleep, "too few HR readings → gate stays out, block remains sleep")
    }

    // MARK: Sleep-vitals rescue (moving-but-asleep morning) — the SYMMETRIC counterpart to the HR gate.

    /// A restless morning (motion spikes so the motion detector scores it `.active`) while the sleeper
    /// is still down — HR near the night's floor and the ring still emitting sleep-vitals (HRV). This is
    /// the 2026-07-04 Gen-2 night, where motion cut a real 7h32m night at the first stir (06:48).
    private func spikyMotion(_ startMin: Int, _ endMin: Int) -> [MotionSample] {
        // Alternate near-still and a big spike every 5 min so the rolling p10 floor stays low and the
        // burst reads as movement → the whole stretch classifies `.active` motion-only.
        stride(from: startMin, to: endMin, by: 5).enumerated().map { i, m in
            MotionSample(time: base.addingTimeInterval(Double(m) * 60), movement: i % 2 == 0 ? 2 : 260)
        }
    }
    private func hrvTimes(_ startMin: Int, _ endMin: Int) -> [Date] {
        stride(from: startMin, to: endMin, by: 5).map { base.addingTimeInterval(Double($0) * 60) }
    }
    private func lastSleepEnd(_ periods: [ActivityPeriod]) -> Date? {
        periods.filter { $0.activity == .sleep }.map(\.end).max()
    }

    /// The fix: a still low-HR night followed by a restless-but-asleep morning. Motion-only cuts the
    /// night at the first stir; with sleep-vitals coverage the tail extends through the morning.
    func testSleepVitalsRescueExtendsMovingButAsleepMorning() {
        let motion = stillMotion(0, 360) + spikyMotion(360, 480)
        let hr = hrSeries(0, 480, bpm: 55)                     // low all night incl. the restless morning
        let hrv = hrvTimes(0, 470)                             // ring still measuring sleep vitals to ~470

        let motionOnly = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: hr)
        let cutEnd = lastSleepEnd(motionOnly)!
        XCTAssertLessThan(cutEnd.timeIntervalSince(base) / 60, 380,
                          "motion-only cuts the night at the first morning stir (~360)")

        let rescued = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [],
                                                      heartRateSamples: hr, sleepVitalTimes: hrv)
        let rescuedEnd = lastSleepEnd(rescued)!
        XCTAssertGreaterThan(rescuedEnd.timeIntervalSince(base) / 60, 450,
                             "sleep-vitals rescue extends the night's tail through the restless morning")
    }

    /// Guard: a genuine morning WAKE (motion + HR climbs above the sleeping floor + margin) is NOT
    /// rescued — the HR gate on the rescue keeps it from swallowing real wakefulness.
    func testSleepVitalsRescueDoesNotRescueElevatedHRWake() {
        let motion = stillMotion(0, 360) + spikyMotion(360, 480)
        let hr = hrSeries(0, 360, bpm: 55) + hrSeries(360, 480, bpm: 95)   // awake HR after 360
        let hrv = hrvTimes(0, 470)

        let rescued = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [],
                                                      heartRateSamples: hr, sleepVitalTimes: hrv)
        let end = lastSleepEnd(rescued)!
        XCTAssertLessThan(end.timeIntervalSince(base) / 60, 380,
                          "elevated-HR morning is real wake, not rescued sleep")
    }

    /// Guard: no sleep-vitals coverage in the morning (ring stopped emitting HRV = awake) → no rescue,
    /// so a low-HR-but-awake lie-in isn't over-counted as sleep on motion+HR alone.
    func testSleepVitalsRescueRequiresSleepVitalsCoverage() {
        let motion = stillMotion(0, 360) + spikyMotion(360, 480)
        let hr = hrSeries(0, 480, bpm: 55)
        let hrv = hrvTimes(0, 360)     // sleep vitals STOP at the stir — nothing to extend through

        let rescued = ActivityPeriod.detectFromMotion(motion, temperatureSamples: [],
                                                      heartRateSamples: hr, sleepVitalTimes: hrv)
        let end = lastSleepEnd(rescued)!
        XCTAssertLessThan(end.timeIntervalSince(base) / 60, 380,
                          "without sleep-vitals coverage the morning stays active (no HR-only over-count)")
    }

    /// No regression: with no sleep-vitals times passed, detection is identical to before the rescue.
    func testSleepVitalsRescueNoOpWithoutCoverage() {
        let motion = stillMotion(0, 300)
        let hr = hrSeries(0, 300, bpm: 60)
        XCTAssertEqual(
            ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: hr, sleepVitalTimes: []),
            ActivityPeriod.detectFromMotion(motion, temperatureSamples: [], heartRateSamples: hr),
            "no sleep-vitals coverage → identical to the pre-rescue result")
    }
}
