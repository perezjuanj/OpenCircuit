import XCTest
@testable import OpenCircuitKit

// Synthetic fixtures only — PROTOCOL.md §5.3.1: this record (历史活动响应) has never been
// captured on the wire (needs sync-open byte[6]=0x02, see RingSession.probeActivityChannels).
// These tests pin the byte-layout math against hand-built vectors so it's ready to validate
// the instant a real capture lands — they do NOT prove the layout itself is correct.
final class ActivityRecordPredictedTests: XCTestCase {

    func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Hand-built 23-byte record: counter 0c22d999, steps=1234 (LE d2 04), deviceState=01,
    // powerLevel=75 (4b), temp1..4 = 358/360/359/357 (LE), item5p0=(2,3,4),
    // activeSeconds=90 (LE 5a 00), dailyActiveFlag=01, trailer=00.
    let syntheticActivityRecord =
        "0c22d999d204014b66016801670165010203045a000100"

    func testDecodePredictedLayout() {
        let r = ActivityRecordPredicted.decode(hex(syntheticActivityRecord))!
        XCTAssertEqual(r.steps, 1234)
        XCTAssertEqual(r.deviceState, 0x01)
        XCTAssertEqual(r.powerLevel, 75)
        XCTAssertEqual(r.temp1, 358)
        XCTAssertEqual(r.temp2, 360)
        XCTAssertEqual(r.temp3, 359)
        XCTAssertEqual(r.temp4, 357)
        XCTAssertEqual(r.item5p0, [2, 3, 4])
        XCTAssertEqual(r.activeSeconds, 90)
        XCTAssertEqual(r.dailyActiveFlag, 0x01)
    }

    func testCounterToWallClock() {
        let r = ActivityRecordPredicted.decode(hex(syntheticActivityRecord))!
        XCTAssertEqual(r.date,
                       Date(timeIntervalSince1970: TimeInterval(Int(0x0c22d999) + Command.syncEpoch)))
    }

    func testWrongLengthReturnsNil() {
        XCTAssertNil(ActivityRecordPredicted.decode(hex("0c22d999")))
    }

    func testSyntheticActivityRecordIsPlausible() {
        let r = ActivityRecordPredicted.decode(hex(syntheticActivityRecord))!
        XCTAssertTrue(r.isPlausible)
    }

    // PROTOCOL.md §5.3.1's own demonstration: decoding a REAL MEASUREMENT record (from
    // BulkSleepTests' deep-sleep fixture) via the predicted ACTIVITY layout produces an
    // implausible result — proof these are different record classes, not a layout bug.
    func testMeasurementRecordFailsActivityPlausibilityCheck() {
        let measurementRecord = "0c22d5bf444d057a620a01010101012aa0000090000004"
        let r = ActivityRecordPredicted.decode(hex(measurementRecord))!
        XCTAssertFalse(r.isPlausible,
                        "a MEASUREMENT record decoded as ACTIVITY should violate the sanity bounds")
    }
}
