import XCTest
@testable import OpenCircuitKit

/// #188 repair — recovering epochs from a diagnostics export's raw-frame capture.
///
/// The capture taps the inbound stream ABOVE the retention gate, so on a pre-fix build a page that
/// was acked-and-discarded is still in the exported text while its epoch never reached the archive.
/// The ring's resume pointer advanced on the ack, so that file is the only remaining copy.
final class DiagnosticsFrameImportTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// Real, XOR-valid 0x4c page (2026-06-13 overnight sync, FR02.018) — 6 × 23-byte records.
    private let realPage = "4c00260c22a16b55210a7d120a010101010100000402400400000c22a20155000300"
        + "120a010101010100003c00000d01200c22a297540001005f0a010101010100001101b00f"
        + "00440c22a32d6027077b120a010101010100402501c02235a00c22a3c351260577120b01"
        + "0101010108a01000000401300c22a459502d0378120a01010101010160200000040ff0cc"

    /// Render bytes the way `HistoryFrameCapture` writes a line into the export.
    private func captureLine(_ bytes: [UInt8], at stamp: String = "2026-08-04T12:56:16Z") -> String {
        let body = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "\(stamp)  0x\(String(format: "%02x", bytes[0]))  \(bytes.count)b  \(body)"
    }

    private func report(_ frameLines: [String]) -> String {
        ([
            "OpenCircuit — diagnostics bundle",
            "Generated: 2026-08-04 08:58 (America/New_York)",
            "",
            "# Epoch archive (drained 0x4c sleep/activity history)",
            "Epochs: 308   span: 08-03 02:53 → 08-04 08:53 (UTC-4)",
            "Gaps > 6 min (a hole = history NEVER drained — the key sleep-loss signal):",
            "  08-04 00:03 ──7.5h──> 08-04 07:30",
            "",
            "# Frames (oldest → newest)",
        ] + frameLines).joined(separator: "\n")
    }

    // MARK: - the recovery

    func testRecoversRecordsFromACaptureLine() {
        let r = DiagnosticsFrameImport.records(fromDiagnosticsText: report([captureLine(hex(realPage))]))
        XCTAssertEqual(r.pagesSeen, 1)
        XCTAssertEqual(r.pagesRejected, 0)
        XCTAssertEqual(r.records.count, 6, "a 142 B page carries 6 × 23-byte records")
        XCTAssertNotNil(r.coverage)
    }

    func testIgnoresEverythingThatIsNotA4cFrame() {
        // 0x47 PPG / 0x50 end-marker / descriptor lines carry no epoch records, and the surrounding
        // prose (which contains "0x4c" in a heading) must not parse as a frame.
        let noise = [
            "2026-08-04T12:56:04Z  0x47  239b  47 00 00 0c 65 86 3a 02 9f 00 30 3c",
            "2026-08-04T12:57:02Z  0x50  171b  50 00 00 17 04 b9 04 b8 00 15 31 0c",
            "2026-08-04T12:56:03Z  0x10  19b  10 4f 03 00 00 37 01 4e 01 49 00 00 00 00 10 1f 1b ff b5",
            "# Epoch archive (drained 0x4c sleep/activity history)",
        ]
        let r = DiagnosticsFrameImport.records(fromDiagnosticsText: report(noise))
        XCTAssertEqual(r.pagesSeen, 0)
        XCTAssertTrue(r.isEmpty)
    }

    func testRecordsAreDedupedByCounter() {
        // The ring re-sends a page whose ack it missed — both 2026-08-04 exports contain such a
        // duplicate terminal page. The same epoch must not be imported twice.
        let line = captureLine(hex(realPage))
        let r = DiagnosticsFrameImport.records(fromDiagnosticsText: report([line, line]))
        XCTAssertEqual(r.pagesSeen, 2)
        XCTAssertEqual(r.records.count, 6, "second copy adds nothing")
        XCTAssertEqual(r.duplicateRecords, 6)
    }

    /// Shift EVERY record's 4-byte BE counter in a page by `delta` and re-trailer it. Shifting only
    /// the page's first bytes would leave the other five records colliding with the original page.
    private func shiftingCounters(_ page: [UInt8], by delta: UInt32) -> [UInt8] {
        var out = page
        let count = (page.count - 4) / BulkRecord.length
        for i in 0 ..< count {
            let o = 3 + i * BulkRecord.length
            let c = UInt32(out[o]) << 24 | UInt32(out[o + 1]) << 16
                  | UInt32(out[o + 2]) << 8 | UInt32(out[o + 3])
            let n = c &+ delta
            out[o] = UInt8((n >> 24) & 0xFF); out[o + 1] = UInt8((n >> 16) & 0xFF)
            out[o + 2] = UInt8((n >> 8) & 0xFF); out[o + 3] = UInt8(n & 0xFF)
        }
        out[out.count - 1] = Frame.xorTrailer(out.dropLast())
        return out
    }

    func testRecordsComeBackAscendingByCounter() {
        let page = hex(realPage)
        let later = shiftingCounters(page, by: 86_400)          // a day forward — no counter collides
        // Deliberately fed NEWEST first: import order must not leak into the result.
        let r = DiagnosticsFrameImport.records(
            fromDiagnosticsText: report([captureLine(later), captureLine(page)]))
        XCTAssertEqual(r.records.count, 12, "two disjoint pages, nothing deduped")
        XCTAssertEqual(r.duplicateRecords, 0)
        XCTAssertEqual(r.records.map(\.counter), r.records.map(\.counter).sorted())
    }

    // MARK: - it must not import garbage

    func testCorruptPageIsRejectedNotImported() {
        var bytes = hex(realPage)
        bytes[10] ^= 0xFF                              // break the XOR trailer
        let r = DiagnosticsFrameImport.records(fromDiagnosticsText: report([captureLine(bytes)]))
        XCTAssertEqual(r.pagesSeen, 1)
        XCTAssertEqual(r.pagesRejected, 1)
        XCTAssertTrue(r.isEmpty, "decoding goes through the same XOR check as the live BLE path")
    }

    func testTruncatedLineIsRejectedByTheDeclaredLength() {
        // A copy-paste that lost trailing bytes would otherwise decode a short body as if whole.
        let bytes = hex(realPage)
        let full = captureLine(bytes)
        let truncated = full.split(separator: " ").dropLast(3).joined(separator: " ")
        let r = DiagnosticsFrameImport.records(fromDiagnosticsText: report([truncated]))
        XCTAssertEqual(r.pagesSeen, 0, "declared length no longer matches — not treated as a frame")
    }

    func testEmptyReportRecoversNothing() {
        let r = DiagnosticsFrameImport.records(fromDiagnosticsText: report([]))
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.pagesSeen, 0)
    }
}
