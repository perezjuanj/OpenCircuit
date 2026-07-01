import XCTest
@testable import OpenCircuitKit

final class DecodeAnomalyTests: XCTestCase {

    func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Real sleep-vitals record (BulkSleepTests.deepSleepRec): HR 68, decodes fine.
    let goodRec = "0c22d5bf444d057a620a01010101012aa0000090000004"

    /// A worn (non-idle) record whose HR byte is below LiveHR.validBPM's floor (30), so
    /// `heartRate` decodes nil. [4]=0x04 (4 bpm, invalid), [8]=0x62 (sleep-vitals SpO2 so the
    /// layout isn't idle), [9]=0x0a, motion 01x5 — only [4] differs from the idle template.
    let noHRRec = "0c22d5bf044d057a620a01010101012aa0000090000004"

    func testNoAnomalyOnNormalRecords() {
        let records = Array(repeating: BulkRecord(hex(goodRec))!, count: 10)
        XCTAssertTrue(DecodeAnomaly.detect(records: records).isEmpty)
    }

    func testFlagsAllZeroHRWhileWorn() {
        let records = Array(repeating: BulkRecord(hex(noHRRec))!, count: 10)
        XCTAssertEqual(DecodeAnomaly.detect(records: records), [.allZeroHRWhileWorn])
    }

    func testDoesNotFlagSparseSyncBelowMinWornEpochs() {
        // Same "all nil HR" records, but fewer than minWornEpochs — a near-empty/contended
        // sync, not a decode-format anomaly.
        let records = Array(repeating: BulkRecord(hex(noHRRec))!, count: 3)
        XCTAssertTrue(DecodeAnomaly.detect(records: records, minWornEpochs: 5).isEmpty)
    }

    func testMixedRecordsDoNotFlag() {
        // Most epochs decode HR fine; one bad epoch is not a pattern.
        var records = Array(repeating: BulkRecord(hex(goodRec))!, count: 9)
        records.append(BulkRecord(hex(noHRRec))!)
        XCTAssertTrue(DecodeAnomaly.detect(records: records).isEmpty)
    }

    // MARK: Temperature

    func testNoTemperatureAnomalyForNormalReadings() {
        let readings = [30.0, 31.0, 32.5, 33.0, 34.5, 30.2]
        XCTAssertFalse(DecodeAnomaly.hasSustainedTemperatureAnomaly(readings))
    }

    func testSingleSpikeDoesNotFlag() {
        // One bad reading among good ones (e.g. a transient donning artifact) resets the run.
        let readings = [30.0, 31.0, 99.0, 32.0, 33.0, 99.0, 31.0]
        XCTAssertFalse(DecodeAnomaly.hasSustainedTemperatureAnomaly(readings))
    }

    func testSustainedOutOfRangeRunFlags() {
        let readings = [30.0, 31.0, 99.0, 99.0, 99.0, 99.0, 99.0]
        XCTAssertTrue(DecodeAnomaly.hasSustainedTemperatureAnomaly(readings))
    }

    func testSustainedRunBelowMinimumFlags() {
        let readings = [5.0, 4.0, 3.0, 2.0, 1.0]
        XCTAssertTrue(DecodeAnomaly.hasSustainedTemperatureAnomaly(readings))
    }

    func testRunShorterThanThresholdDoesNotFlag() {
        let readings = [30.0, 99.0, 99.0, 99.0, 30.0]
        XCTAssertFalse(DecodeAnomaly.hasSustainedTemperatureAnomaly(readings, sustainedRun: 5))
    }
}
