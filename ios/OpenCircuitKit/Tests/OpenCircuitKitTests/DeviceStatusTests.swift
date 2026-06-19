import XCTest
@testable import OpenCircuitKit

// Tests for DeviceStatus.isWorn / isCharging — the proxy wear/charging API (#41, #60).
//
// These proxies wrap the current best-available signal (skin temp for wear; rising
// battery % for charging) behind the stable call signature that will be replaced by the
// decoded hardware byte (#61) without touching call sites.
//
// Key design rule: isWorn/isCharging are CONSERVATIVE.
//   • isWorn miss (ring cold, actually worn) → at most one unfiltered charger block in
//     sleep detection.  Never adds spurious sleep.
//   • isCharging false-positive (slow flat discharge that looks rising) → at most a
//     "likely charging" hint in the UI.  Never drops a real night.
final class DeviceStatusTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal 19-byte 0x10 descriptor frame with specified temperature bytes.
    /// Channels are two 16-bit big-endian values at [6:8] and [8:10] in units of 0.1 °C.
    private func descriptorFrame(tempA: Int, tempB: Int, opcode: UInt8 = 0x10) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 19)
        frame[0] = opcode
        frame[6] = UInt8(tempA >> 8); frame[7] = UInt8(tempA & 0xFF)
        frame[8] = UInt8(tempB >> 8); frame[9] = UInt8(tempB & 0xFF)
        return frame
    }

    /// Temperature integer for a given Celsius value (0.1 °C units).
    private func tempInt(_ celsius: Double) -> Int { Int(celsius * 10) }

    // MARK: - isWorn: non-descriptor frames

    func testIsWornNonDescriptorFrameReturnsNil() {
        // A frame that isn't 0x10 or 0x87 → no temperature → nil
        var frame = descriptorFrame(tempA: tempInt(32), tempB: tempInt(32))
        frame[0] = 0x4C   // sleep-page opcode, not a descriptor
        XCTAssertNil(DeviceStatus.isWorn(frame))
    }

    func testIsWornTooShortFrameReturnsNil() {
        XCTAssertNil(DeviceStatus.isWorn([0x10, 0x50]))   // too short
    }

    func testIsWornGarbageTempReturnsNil() {
        // Both channels out of the 15–50 °C plausible band → skinTemperature returns nil
        let frame = descriptorFrame(tempA: 0, tempB: 0)
        XCTAssertNil(DeviceStatus.isWorn(frame))
    }

    // MARK: - isWorn: warm (worn) readings

    func testIsWornReturnsTrueAt32C() {
        // Typical worn-ring temp: both channels at 32.0 °C
        let frame = descriptorFrame(tempA: tempInt(32), tempB: tempInt(32))
        XCTAssertEqual(DeviceStatus.isWorn(frame), true)
    }

    func testIsWornReturnsTrueAtThresholdExactly() {
        // Exactly at the default threshold (28 °C) → worn
        let t = tempInt(ActivityPeriod.wornMinTemperatureC)
        let frame = descriptorFrame(tempA: t, tempB: t)
        XCTAssertEqual(DeviceStatus.isWorn(frame), true)
    }

    func testIsWornReturnsTrueWithMixedChannels() {
        // Mean of 30 + 32 = 31 °C → worn
        let frame = descriptorFrame(tempA: tempInt(30), tempB: tempInt(32))
        XCTAssertEqual(DeviceStatus.isWorn(frame), true)
    }

    // MARK: - isWorn: cold (unworn/charging) readings

    func testIsWornReturnsFalseAt22C() {
        // Typical room-ambient off-wrist temp
        let frame = descriptorFrame(tempA: tempInt(22), tempB: tempInt(22))
        XCTAssertEqual(DeviceStatus.isWorn(frame), false)
    }

    func testIsWornReturnsFalseJustBelowThreshold() {
        // Just below threshold: threshold - 0.1 °C
        let tInt = tempInt(ActivityPeriod.wornMinTemperatureC) - 1
        let frame = descriptorFrame(tempA: tInt, tempB: tInt)
        XCTAssertEqual(DeviceStatus.isWorn(frame), false)
    }

    func testIsWornWorksFor0x87Opcode() {
        // 0x87 is the response variant of the same descriptor
        let frame = descriptorFrame(tempA: tempInt(33), tempB: tempInt(33), opcode: 0x87)
        XCTAssertEqual(DeviceStatus.isWorn(frame), true)
    }

    func testIsWornCustomThreshold() {
        // Override default threshold to 30 °C: a 29 °C reading is unworn under this stricter gate
        let frame = descriptorFrame(tempA: tempInt(29), tempB: tempInt(29))
        XCTAssertEqual(DeviceStatus.isWorn(frame, wornMinC: 30.0), false)
        // … but worn under the default 28 °C threshold
        XCTAssertEqual(DeviceStatus.isWorn(frame), true)
    }

    // MARK: - isCharging: delegates to ChargingInference

    func testIsChargingReturnsFalseForEmptyTrend() {
        XCTAssertFalse(DeviceStatus.isCharging(batteryTrend: []))
    }

    func testIsChargingReturnsFalseForSingleReading() {
        XCTAssertFalse(DeviceStatus.isCharging(batteryTrend: [75]))
    }

    func testIsChargingReturnsTrueForRisingTrend() {
        XCTAssertTrue(DeviceStatus.isCharging(batteryTrend: [74, 76, 78]))
    }

    func testIsChargingReturnsFalseForFlatTrend() {
        XCTAssertFalse(DeviceStatus.isCharging(batteryTrend: [75, 75]))
    }

    func testIsChargingReturnsFalseForFallingTrend() {
        XCTAssertFalse(DeviceStatus.isCharging(batteryTrend: [80, 78]))
    }

    func testIsChargingReturnsFalseForMixedTrend() {
        XCTAssertFalse(DeviceStatus.isCharging(batteryTrend: [74, 76, 75]))
    }

    // MARK: - Combined: still + ambient temp + battery-rising → NOT sleep (#41 core case)
    //
    // This is the key regression guard: a ring on the charger produces a still motion
    // timeline AND cold skin temps AND a rising battery %. All three proxies fire.
    // The sleep wear-gate must drop the block — it must NOT be committed to HealthKit.

    private func rec(_ counter: UInt32, motion: UInt8, sub: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[8] = sub
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    func testChargingNightNotCommittedAsSleep() {
        // 9 h of still, sleep-vitals epochs (ring on charger: motion=01, sub=0x62)
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }   // active
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }   // still
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }   // active

        // Motion-only: the still block looks like sleep.
        XCTAssertNotNil(BulkSleep.mainSleep(from: recs),
                        "motion-only: still block reads as sleep (expected baseline)")

        // Confirm isWorn returns false for an ambient-temp descriptor frame.
        let coldFrame = descriptorFrame(tempA: tempInt(22), tempB: tempInt(22))
        XCTAssertEqual(DeviceStatus.isWorn(coldFrame), false, "22 °C frame reads as unworn")

        // Confirm isCharging returns true for a rising battery trend.
        XCTAssertTrue(DeviceStatus.isCharging(batteryTrend: [70, 72, 74, 76]),
                      "rising trend reads as charging")

        // With cold (off-wrist / charging) temperature samples covering the entire night,
        // the sleep wear-gate must reclassify the still block as active → no sleep block.
        let coldTemps = recs.map { TemperatureSample(time: $0.date(), celsius: 22.0) }
        XCTAssertNil(BulkSleep.mainSleep(from: recs, temperatures: coldTemps),
                     "ambient-temp still block must NOT be committed as a night of sleep (#41)")
        XCTAssertTrue(BulkSleep.sleepSegments(from: recs, temperatures: coldTemps).isEmpty,
                      "no sleep segments for a cold-temp still night (#41)")
    }

    /// A warm (worn) ring with the same still motion must STILL be detected as sleep —
    /// the gate must not over-fire and drop real nights.
    func testWornNightWithStillMotionIsKeptAsSleep() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        let warmTemps = recs.map { TemperatureSample(time: $0.date(), celsius: 32.0) }
        XCTAssertNotNil(BulkSleep.mainSleep(from: recs, temperatures: warmTemps),
                        "worn (32 °C) still night must survive the wear gate")
    }

    /// No temperature data → detection falls back to motion alone (absence ≠ unworn).
    func testNoTemperatureSamplesLeavesDetectionUnchanged() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        for _ in 0..<216 { recs.append(rec(c, motion: 0x01, sub: 0x62)); c += 150 }
        for _ in 0..<20 { recs.append(rec(c, motion: 0x14, sub: 0x12)); c += 150 }
        XCTAssertEqual(BulkSleep.mainSleep(from: recs, temperatures: []) != nil,
                       BulkSleep.mainSleep(from: recs) != nil,
                       "empty temperatures → same result as motion-only (absence ≠ unworn)")
    }
}
