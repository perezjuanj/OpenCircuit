import XCTest
@testable import OpenCircuitKit

// #203 — a "35-minute data hole billed as Light sleep" that was a hole in the DIAGNOSTIC, not in
// the data.
//
// 🟢 MEASURED on a Gen-3 tester's export (FR05.010, build 39, Europe/Paris, 2026-08-10→11). The
// union of `historySyncEvidence[].rawRecordBlobBase64` held 367 records with a 35-minute gap at
// 05:44:46 → 06:19:48, and replaying it gave in-bed 470 / asleep 460 / wake 05:46:46 while the card
// showed 522 / 511 / 06:38. The export's own `samples` table carries HR + HRV + RR + SpO2 for 13
// epochs INSIDE that gap, on the exact 150 s cadence — so the app had decoded, persisted and staged
// them. Rebuilding those 13 epochs from those samples and replaying reproduces the card exactly:
// in-bed 522, asleep 511, deep 75, light 280, REM 156, awake 11, wake 06:38:18. Seven of seven.
//
// The check the issue relied on — blob record count vs `mergedRecordCount` — cannot see this: both
// are built from the same `bulkRecords` array in the same call, so they can never disagree. And the
// evidence list is a bounded ring buffer (`historySyncEvidenceLimit`, 24; that export carried
// exactly 24 rows), so a drain whose row is gone leaves its epochs in no blob at all.
final class ArchiveEvidenceCoverageTests: XCTestCase {

    private let step: UInt32 = 150
    private let base: UInt32 = 0x0c220000

    private func rec(_ counter: UInt32) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = 55; b[5] = 40; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = 1 }
        return BulkRecord(b)!
    }

    private func run(_ n: Int, from: UInt32) -> [BulkRecord] {
        (0..<n).map { rec(from + UInt32($0) * step) }
    }

    func testCompleteCoverageReportsNoGap() {
        let archive = run(20, from: base)
        let report = ArchiveEvidenceCoverage.report(archive: archive, evidence: archive)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.archiveRecordCount, 20)
        XCTAssertEqual(report.evidenceRecordCount, 20)
        XCTAssertEqual(report.longestMissingRunSeconds, 0)
    }

    /// The tester's shape: a contiguous archive whose middle stretch is in no blob.
    func testMissingMiddleStretchIsReportedWithItsSpan() {
        let archive = run(30, from: base)
        let evidence = Array(archive.prefix(10)) + Array(archive.suffix(7))
        let report = ArchiveEvidenceCoverage.report(archive: archive, evidence: evidence)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.missingFromEvidence.count, 13, "13 epochs, exactly the measured case")
        XCTAssertEqual(report.longestMissingRunSeconds, 13 * 150,
                       "a blob-only replay would see a hole this wide")
        XCTAssertEqual(report.archiveRecordCount, 30)
        XCTAssertEqual(report.evidenceRecordCount, 17)
    }

    /// Overlapping blobs are the norm — a drain that re-hydrates banked records ships them twice —
    /// so both sides must be deduped by epoch counter or the counts are nonsense.
    func testDuplicateRecordsAreDedupedOnBothSides() {
        let archive = run(10, from: base)
        let evidence = archive + archive + archive
        let report = ArchiveEvidenceCoverage.report(archive: archive + archive, evidence: evidence)
        XCTAssertEqual(report.archiveRecordCount, 10)
        XCTAssertEqual(report.evidenceRecordCount, 10)
        XCTAssertTrue(report.isComplete)
    }

    /// The ring's cadence drifts a second or two between epochs (152 s intervals are common on
    /// Gen 3), so a run must not be split by that jitter and under-report the hole.
    func testCadenceJitterDoesNotSplitAMissingRun() {
        var counters: [UInt32] = [base]
        for i in 1..<12 { counters.append(base + UInt32(i) * step + UInt32(i % 3)) }
        let archive = counters.map(rec)
        let report = ArchiveEvidenceCoverage.report(archive: archive, evidence: [])
        XCTAssertEqual(report.missingFromEvidence.count, 12)
        XCTAssertGreaterThanOrEqual(report.longestMissingRunSeconds, 11 * 150)
    }

    /// Two genuinely separate holes must report the LONGER one, not their sum.
    func testSeparateHolesReportTheLongestRun() {
        let archive = run(40, from: base)
        var evidence = archive
        evidence.removeSubrange(30..<34)        // 4 epochs
        evidence.removeSubrange(5..<7)          // 2 epochs
        let report = ArchiveEvidenceCoverage.report(archive: archive, evidence: evidence)
        XCTAssertEqual(report.missingFromEvidence.count, 6)
        XCTAssertEqual(report.longestMissingRunSeconds, 4 * 150)
    }

    /// An archive the blobs OVERSHOOT (a blob older than the archive's 30 h retention) is still
    /// complete — coverage asks "does the export contain what the app holds", not the reverse.
    func testEvidenceBeyondTheArchiveIsNotAGap() {
        let archive = run(10, from: base + 10 * step)
        let evidence = run(30, from: base)
        let report = ArchiveEvidenceCoverage.report(archive: archive, evidence: evidence)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.evidenceRecordCount, 30)
    }

    func testEmptyArchiveIsVacuouslyComplete() {
        let report = ArchiveEvidenceCoverage.report(archive: [], evidence: run(4, from: base))
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.archiveRecordCount, 0)
        XCTAssertEqual(report.longestMissingRunSeconds, 0)
    }
}
