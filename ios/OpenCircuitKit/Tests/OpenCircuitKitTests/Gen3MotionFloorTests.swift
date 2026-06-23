import XCTest
@testable import OpenCircuitKit

/// Regression coverage for the Gen-3 sleep-detection bug (discussion #111, FR05.008 capture
/// 2026-06-23). The 0x4c motion channel idles at a device-dependent — and intra-night DRIFTING —
/// level: still Gen-2 reads ~1, still Gen-3 reads ~15–16 and steps to ~24, ~39 as sleeping posture
/// changes. The old ABSOLUTE still threshold (calibrated to Gen 2's `1`) classified every Gen-3
/// epoch as movement → no sleep block → blank Sleep/HRV/Respiratory cards even though the vitals
/// decoded perfectly. The fix measures stillness above a LOCAL rolling idle floor and bridges
/// drift-step gaps via `maxSleepPause`.
///
/// All data here is SYNTHETIC — it reproduces the failure SHAPE (elevated/drifting still floor with
/// sane vitals), not a real person's night. No captured health data is committed (see CLAUDE.md).
final class Gen3MotionFloorTests: XCTestCase {

    /// A worn sleep-vitals epoch: HR/HRV/SpO2/RR present, all five motion bytes = `motion`.
    private func sleepEpoch(_ counter: UInt32, hr: UInt8, motion: UInt8,
                            hrv: UInt8 = 40, spo2: UInt8 = 0x5e, rr: UInt8 = 120) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[7] = rr; b[8] = spo2     // sleep-vitals layout ([8] is an SpO2 %)
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// An awake/active epoch with VARYING motion (a moving wrist; not a constant reading).
    private func activeEpoch(_ counter: UInt32, i: Int) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = 90; b[8] = 0x12                            // activity tag, awake HR
        let m = UInt8([0x0a, 0x30, 0x58][i % 3])
        for k in 0..<5 { b[10 + k] = m }
        return BulkRecord(b)!
    }

    private let step: UInt32 = UInt32(BulkRecord.epochSeconds)   // 150 s

    /// Build a night: `onset` active epochs, then still sleep plateaus at each `floors` level for
    /// `plateauEpochs` epochs each (the posture-drift), then `wake` active epochs.
    private func driftingNight(floors: [UInt8], plateauEpochs: Int,
                               onset: Int = 8, wake: Int = 8) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for i in 0..<onset { recs.append(activeEpoch(c, i: i)); c += step }
        var hr: UInt8 = 76
        for floor in floors {
            for _ in 0..<plateauEpochs { recs.append(sleepEpoch(c, hr: hr, motion: floor)); c += step }
            hr = hr > 2 ? hr - 2 : hr      // HR drifts down deeper into the night
        }
        for i in 0..<wake { recs.append(activeEpoch(c, i: i)); c += step }
        return recs
    }

    // MARK: - The regression itself

    func testGen3ElevatedConstantFloorDetectsSleep() {
        // A flat Gen-3 night at a CONSTANT elevated floor (16) — what previously detected as zero sleep.
        let recs = driftingNight(floors: [16], plateauEpochs: 120, onset: 6, wake: 6)   // ~5 h still
        let block = BulkSleep.mainSleep(from: recs)
        XCTAssertNotNil(block, "an elevated but still Gen-3 floor must detect as sleep (was nil → blank cards)")
        XCTAssertGreaterThan(block!.duration, 4 * 3600, "≈5 h still block recovered")
    }

    func testGen3DriftingFloorStaysOneNight() {
        // Floor steps 16 → 24 → 39 across the night (posture drift). Must read as ONE block, not three.
        let recs = driftingNight(floors: [16, 24, 39], plateauEpochs: 40)   // 3 × ~1.7 h = ~5 h
        let block = BulkSleep.mainSleep(from: recs)
        XCTAssertNotNil(block)
        XCTAssertGreaterThan(block!.duration, 4 * 3600,
                             "drift-stepped plateaus bridge into one ~5 h night, not three short fragments")
        // And the staged night is populated (HRV/Respiratory/Sleep cards have data to show).
        let segs = BulkSleep.sleepSegments(from: recs)
        let asleep = segs.filter { $0.stage == .asleepCore }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        XCTAssertGreaterThan(asleep, 3 * 3600, "most of the drifting night is staged as asleep")
        // The motion-floor STEPS must not masquerade as awakenings (the calibration lesson from the
        // FR05.008 night: a tester slept ~7 h with near-zero true wake, but the long detection floor
        // lag was marking ~55 min "awake" at the steps; the shorter staging floor cut that to ~20).
        let summary = SleepStaging.summary(SleepStaging.classify(from: recs)).minutes
        XCTAssertGreaterThan(Double(summary.asleep) / Double(max(summary.inBed, 1)), 0.85,
                             "drift steps stay asleep — most of the in-bed window is sleep, not false wake")
        // Vitals samples flow regardless of staging (the HealthKit path).
        XCTAssertFalse(BulkSleep.samples(from: recs).filter { $0.kind == .hrvSDNN }.isEmpty,
                       "HRV samples present")
    }

    func testGen2ConstantFloorUnchanged() {
        // Parity: Gen 2's flat `1` floor still detects sleep (the local floor maps it to 0, as the
        // old absolute threshold did).
        let recs = driftingNight(floors: [1], plateauEpochs: 120, onset: 6, wake: 6)
        XCTAssertNotNil(BulkSleep.mainSleep(from: recs), "Gen-2 still floor detection preserved")
    }

    func testVaryingActivityIsNotSleep() {
        // Safety invariant: a stretch of genuinely VARYING (moving) motion is never staged as sleep,
        // at any device's idle level — only a flat/still floor is.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for i in 0..<160 { recs.append(activeEpoch(c, i: i)); c += step }
        XCTAssertNil(BulkSleep.mainSleep(from: recs))
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs).isEmpty)
    }

    // MARK: - The de-flooring primitive

    func testRollingFloorTracksDriftToZero() {
        // A drifting-but-flat signal (16…24…39) de-floors to ~0 in each plateau's interior (still),
        // once the rolling window sits fully inside it. Plateaus here are 120 × 30 s = 60 min, longer
        // than the 30-min floor window (as a real night's plateaus are). A constant signal at ANY
        // level is still; a varying signal keeps its excursions (active).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let plateau = 120
        let levels: [Float] = Array(repeating: 16, count: plateau)
            + Array(repeating: 24, count: plateau) + Array(repeating: 39, count: plateau)
        let times = levels.indices.map { base.addingTimeInterval(Double($0) * 30) }
        let floored = ActivityPeriod.motionAboveLocalFloor(
            zip(times, levels).map { MotionSample(time: $0.0, movement: $0.1) })
        // Deep interior of each plateau (well clear of the step boundaries) reads still.
        for mid in [plateau / 2, plateau + plateau / 2, 2 * plateau + plateau / 2] {
            XCTAssertLessThanOrEqual(floored[mid], ActivityPeriod.motionStillThreshold,
                                     "flat plateau at level \(levels[mid]) de-floors to still")
        }

        // A genuinely varying signal keeps excursions above the floor (active).
        let varying: [Float] = (0..<120).map { Float([10, 48, 88][$0 % 3]) }
        let vTimes = varying.indices.map { base.addingTimeInterval(Double($0) * 30) }
        let vFloored = ActivityPeriod.motionAboveLocalFloor(
            zip(vTimes, varying).map { MotionSample(time: $0.0, movement: $0.1) })
        XCTAssertGreaterThan(vFloored.max() ?? 0, ActivityPeriod.motionStillThreshold,
                             "varying motion keeps active excursions above the local floor")
    }
}
