import XCTest
@testable import OpenCircuitKit

final class EpochArchiveDiagnosticsTests: XCTestCase {

    /// One sleep-vitals 0x4c record at `counter` (HR/HRV/SpO2 present → decodes as sleepVitals).
    private func rec(_ counter: UInt32, hr: UInt8 = 60) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff); b[3] = UInt8(counter & 0xff)
        b[4] = hr; b[5] = 50; b[7] = 120; b[8] = 97   // HR, HRV, RR*8, SpO2
        return BulkRecord(b)!
    }

    func testEmptyArchive() {
        XCTAssertTrue(EpochArchiveDiagnostics.report([]).contains("empty"))
    }

    func testContiguousHasNoGap() {
        let recs = (0 ..< 6).map { rec(UInt32($0 * 150)) }   // 150 s steps
        let report = EpochArchiveDiagnostics.report(recs)
        XCTAssertTrue(report.contains("Epochs: 6"))
        XCTAssertTrue(report.contains("(none — contiguous coverage)"))
        XCTAssertTrue(report.contains("HR 6"))   // all six carry HR
    }

    func testFlagsOvernightHole() {
        // Three contiguous epochs, a 6.3 h hole, then two more — the bug-B signature.
        let base: UInt32 = 0
        let recs = [rec(base), rec(base + 150), rec(base + 300),
                    rec(base + 300 + UInt32(6.3 * 3600)),
                    rec(base + 300 + UInt32(6.3 * 3600) + 150)]
        let report = EpochArchiveDiagnostics.report(recs)
        XCTAssertTrue(report.contains("6.3h"), "the 6.3 h hole must be reported")
        XCTAssertFalse(report.contains("(none — contiguous coverage)"))
    }

    func testGapThresholdRespected() {
        // A 5-min gap is under the default 6-min threshold → not flagged.
        let recs = [rec(0), rec(300)]   // 5 min
        XCTAssertTrue(EpochArchiveDiagnostics.report(recs).contains("(none — contiguous coverage)"))
    }
}
