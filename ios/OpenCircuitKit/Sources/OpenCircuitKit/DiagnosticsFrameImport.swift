// Recover epoch records from a diagnostics export's raw-frame capture (#188 repair).
//
// WHY THIS CAN WORK AT ALL. The diagnostics raw-frame capture (`HistoryFrameCapture`) taps the
// inbound stream in the CoreBluetooth delegate, ~240 lines ABOVE the retention gate that #188
// fixed. So on any build where a page was acked-and-discarded, the page's bytes are still in the
// user's own diagnostics export even though the epoch never reached the EpochArchive. That asymmetry
// is what makes an after-the-fact repair possible — the ring's resume pointer has long since moved
// past those epochs and will never re-offer them.
//
// 🟢 PROVEN against both 2026-08-04 exports: 208 records (Gen 2, 00:15→08:53) and 189 records
// (Gen 2 Air, 22:38→06:28) decode cleanly out of the text, contiguous at exactly one 150 s epoch.
//
// The capture format (`DiagnosticsReport` / `HistoryFrameCapture.render`) is one frame per line:
//     2026-08-04T12:56:16Z  0x4c  142b  4c 00 ca 0c 66 2f 3a 37 …
// Only `0x4c` carries epoch records; `0x47` (PPG), `0x50`, `0x10`/`0x87` do not.

import Foundation

public enum DiagnosticsFrameImport {

    public struct Result: Equatable, Sendable {
        /// Decoded, de-duplicated records, ascending by counter.
        public let records: [BulkRecord]
        /// `0x4c` lines seen in the text.
        public let pagesSeen: Int
        /// Pages rejected by the real decoder (bad XOR, wrong length, malformed hex).
        public let pagesRejected: Int
        /// Records dropped as exact counter duplicates (the ring re-sends a page after a missed ack).
        public let duplicateRecords: Int

        public var isEmpty: Bool { records.isEmpty }
        /// Wall-clock span the recovered records cover.
        public var coverage: ClosedRange<Date>? {
            guard let f = records.first?.date(), let l = records.last?.date(), f <= l else { return nil }
            return f...l
        }
    }

    /// Parse every `0x4c` page out of a diagnostics export and decode its epoch records.
    ///
    /// Decoding goes through the SAME `BulkSleep.records(fromPage:)` the live BLE path uses, so a
    /// page with a bad XOR trailer or a non-multiple-of-23 body is rejected here exactly as it would
    /// be on the wire — this can import corrupt data only if the live path would have too.
    public static func records(fromDiagnosticsText text: String) -> Result {
        var decoded: [UInt32: BulkRecord] = [:]
        var seen = 0, rejected = 0, duplicates = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let bytes = pageBytes(fromLine: String(rawLine)) else { continue }
            seen += 1
            let recs = BulkSleep.records(fromPage: bytes)
            if recs.isEmpty { rejected += 1; continue }
            for r in recs {
                if decoded[r.counter] != nil { duplicates += 1 } else { decoded[r.counter] = r }
            }
        }
        let sorted = decoded.values.sorted { $0.counter < $1.counter }
        return Result(records: sorted, pagesSeen: seen,
                      pagesRejected: rejected, duplicateRecords: duplicates)
    }

    /// Extract the hex payload of a `0x4c` capture line, or nil for any other line.
    ///
    /// Deliberately tolerant of the surrounding report (headers, gap tables, sleep summaries) and
    /// strict about the frame itself: the opcode token must be exactly `0x4c`, and every remaining
    /// token must be a two-digit hex byte. A `0x4c` written into prose elsewhere in the report
    /// cannot match, because prose does not parse as whole hex bytes.
    static func pageBytes(fromLine line: String) -> [UInt8]? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // timestamp, opcode, length, then ≥1 hex byte
        guard fields.count >= 4 else { return nil }
        guard fields[1].lowercased() == "0x4c" else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(fields.count - 3)
        for token in fields.dropFirst(3) {
            guard token.count == 2, let b = UInt8(token, radix: 16) else { return nil }
            bytes.append(b)
        }
        guard bytes.count >= 4, bytes.first == 0x4C else { return nil }
        // Cross-check the declared length (e.g. "142b") when present — a truncated copy-paste
        // would otherwise decode a short body as if it were whole.
        let declared = fields[2].hasSuffix("b") ? Int(fields[2].dropLast()) : nil
        if let declared, declared != bytes.count { return nil }
        return bytes
    }
}
