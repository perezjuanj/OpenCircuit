import XCTest
@testable import OpenRingKit

// Tests for BulkSleep.swift — verify the #39 fix: layout is determined by the
// idle-template check, NOT by the SpO2 range. A desaturation epoch (SpO2 < 87%)
// must still be recognised as .sleepVitals so HR/HRV/SpO2 are not silently dropped.
final class BulkSleepTests: XCTestCase {

    // MARK: Idle template detection

    /// Build a 23-byte idle record from the confirmed 🟢 template.
    private func makeIdleRecord(subtypeTag: UInt8 = 0x12) -> [UInt8] {
        var r = [UInt8](repeating: 0x00, count: 23)
        r[0] = 0x0c            // delimiter
        r[1] = 0x0a; r[2] = 0x00; r[3] = 0x96  // BE counter (arbitrary)
        r[4] = 0x05; r[5] = 0x00; r[6] = 0x0c; r[7] = 0x00  // idle template bytes[4:8]
        r[8] = subtypeTag      // 0x12 or 0x13 (alternates in idle)
        r[9] = 0x0a            // bytes[9] = 0x0a in idle
        r[10] = 0x01; r[11] = 0x01; r[12] = 0x01; r[13] = 0x01; r[14] = 0x01  // baseline
        // bytes[15:22] = 0x00×7 (already zero-filled)
        // r[22] = flags = 0x00 or 0x04 (idle variants)
        return r
    }

    /// Build a minimal non-idle (sleepVitals) record with a specific SpO2 byte.
    /// bytes[9] is the 🟡 probable SpO2 position; HR at bytes[15], HRV at bytes[16].
    private func makeSleepRecord(spo2: UInt8, hr: UInt8 = 60, hrv: UInt8 = 30) -> [UInt8] {
        var r = [UInt8](repeating: 0x00, count: 23)
        r[0] = 0x0c
        r[1] = 0x0a; r[2] = 0x01; r[3] = 0x2c  // counter
        // Deliberately do NOT set the idle-template bytes (they stay 0x00, not 0x05/0x0a/0x01)
        r[9] = spo2             // SpO2 (bytes[9], 🟡)
        r[10] = 0x00            // break the 01×5 baseline pattern
        r[15] = hr              // HR (bytes[15], 🔴)
        r[16] = hrv             // HRV (bytes[16], 🔴)
        return r
    }

    func testIdleRecordDetectedAsIdle() {
        let rec = BulkRecord(makeIdleRecord())
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.layout, .idle)
    }

    func testIdleAlternateTag13() {
        // Idle alternates between subtype 0x12 and 0x13 (PROTOCOL.md §5.3 🟢).
        XCTAssertEqual(BulkRecord(makeIdleRecord(subtypeTag: 0x13))?.layout, .idle)
    }

    func testIdleReturnsNilMetrics() {
        let rec = BulkRecord(makeIdleRecord())!
        XCTAssertNil(rec.heartRateBPM)
        XCTAssertNil(rec.hrvRMSSD)
        XCTAssertNil(rec.spo2Percent)
    }

    // MARK: #39 fix — desaturation epoch must not be dropped

    func testHealthySpO2EpochIsSleepVitals() {
        // Normal night: SpO2 = 95% (0x5f), in the old buggy range 87–99.
        let rec = BulkRecord(makeSleepRecord(spo2: 95, hr: 62, hrv: 28))!
        XCTAssertEqual(rec.layout, .sleepVitals)
        XCTAssertEqual(rec.spo2Percent, 95)
    }

    func testDesaturationEpochIsSleepVitals() {
        // Desaturation: SpO2 = 82% — below 87, would be DROPPED by the old buggy layout gate.
        // After #39 fix: layout must still be .sleepVitals.
        let rec = BulkRecord(makeSleepRecord(spo2: 82, hr: 70, hrv: 20))!
        XCTAssertEqual(rec.layout, .sleepVitals,
            "SpO2 < 87% must not affect layout detection — #39 regression guard")
        XCTAssertEqual(rec.spo2Percent, 82)
        XCTAssertNotNil(rec.heartRateBPM)
        XCTAssertNotNil(rec.hrvRMSSD)
    }

    func testSevereDesaturationEpochIsSleepVitals() {
        // Severe desaturation (70%): layout must be .sleepVitals, SpO2 still returned.
        let rec = BulkRecord(makeSleepRecord(spo2: 70))!
        XCTAssertEqual(rec.layout, .sleepVitals)
        XCTAssertEqual(rec.spo2Percent, 70)
    }

    // MARK: SpO2 guard (70–100)

    func testSpO2BelowFloorIsNil() {
        // bytes[9] = 10 (0x0a) as it is in idle template — not a real SpO2 reading.
        // When layout is sleepVitals and value is outside 70–100, spo2Percent is nil.
        let r = makeSleepRecord(spo2: 10)   // 10 is not a plausible SpO2
        // Force it to be non-idle (already the case from makeSleepRecord)
        let rec = BulkRecord(r)!
        XCTAssertEqual(rec.layout, .sleepVitals)
        XCTAssertNil(rec.spo2Percent, "SpO2 = 10 should be rejected as implausible (below 70)")
    }

    func testSpO2AboveCeilingIsNil() {
        let rec = BulkRecord(makeSleepRecord(spo2: 101))!
        XCTAssertNil(rec.spo2Percent)
    }

    func testSpO2At100IsValid() {
        let rec = BulkRecord(makeSleepRecord(spo2: 100))!
        XCTAssertEqual(rec.spo2Percent, 100)
    }

    // MARK: Validity / length

    func testTooShortReturnsNil() {
        XCTAssertNil(BulkRecord([UInt8](repeating: 0x0c, count: 22)))
    }

    func testWrongDelimiterReturnsNil() {
        var r = makeIdleRecord()
        r[0] = 0x00
        XCTAssertNil(BulkRecord(r))
    }

    // MARK: parseBulkSleepPage

    func testPageParserExtractsRecords() {
        let idle = makeIdleRecord()
        let sleep = makeSleepRecord(spo2: 95)
        let page = idle + sleep   // two consecutive records
        let records = parseBulkSleepPage(page)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].layout, .idle)
        XCTAssertEqual(records[1].layout, .sleepVitals)
    }

    func testPageParserIgnoresIncompleteTrailer() {
        let idle = makeIdleRecord()
        let page = idle + [0x0c, 0x00]  // 2 extra bytes — not a full record
        XCTAssertEqual(parseBulkSleepPage(page).count, 1)
    }
}
