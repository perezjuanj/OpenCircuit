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

    /// Identity of the ring the export came FROM, read out of the report's `# Device` header. The
    /// MAC is redacted to its last octet by default (`··:··:··:··:··:AD`), which is still enough to
    /// tell two rings apart in practice; model + firmware corroborate it.
    public struct SourceRing: Equatable, Sendable {
        public var model: String?
        public var firmware: String?
        /// Last octet of the MAC, uppercased (e.g. "AD"), or nil when the header is absent.
        public var macSuffix: String?

        public init(model: String? = nil, firmware: String? = nil, macSuffix: String? = nil) {
            self.model = model
            self.firmware = firmware
            self.macSuffix = macSuffix
        }

        public var isEmpty: Bool { model == nil && firmware == nil && macSuffix == nil }

        /// Whether this export plausibly came from the SAME ring as `other`. Conservative: unknown
        /// on either side is NOT a match, so the caller must ask rather than silently merge.
        public func matches(_ other: SourceRing) -> Bool {
            // Any field known on BOTH sides that disagrees is an immediate mismatch.
            if let a = macSuffix, let b = other.macSuffix, a != b { return false }
            if let a = model, let b = other.model, a != b { return false }
            if let a = firmware, let b = other.firmware, a != b { return false }
            // …and we need at least one field actually corroborated on both sides. Unknown-vs-unknown
            // is NOT a match, so an export with no device header prompts instead of merging blind.
            let macAgrees = macSuffix != nil && macSuffix == other.macSuffix
            let modelAgrees = model != nil && model == other.model
            return macAgrees || modelAgrees
        }
    }

    // Not `Sendable`: `BulkRecord` isn't, and this is consumed on the main actor.
    public struct Result: Equatable {
        /// Decoded, de-duplicated records, ascending by counter.
        public let records: [BulkRecord]
        /// `0x4c` lines seen in the text.
        public let pagesSeen: Int
        /// Pages rejected by the real decoder (bad XOR, wrong length, malformed hex).
        public let pagesRejected: Int
        /// Records dropped as exact counter duplicates (the ring re-sends a page after a missed ack).
        public let duplicateRecords: Int
        /// Which ring the file says it came from — the caller MUST check this before merging, since
        /// the archive is per-ring and a foreign export would silently pollute it.
        public let sourceRing: SourceRing

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

        // Split on ANY newline, not the literal "\n": in Swift `\r\n` is a single grapheme cluster
        // that is NOT equal to `\n`, so a CRLF-converted export (mail client, Windows round-trip)
        // splits into ONE line and recovers zero frames — while the UI cheerfully tells the user
        // their only copy of the night contains nothing (#188 review).
        for rawLine in text.split(whereSeparator: \.isNewline) {
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
                      pagesRejected: rejected, duplicateRecords: duplicates,
                      sourceRing: sourceRing(fromDiagnosticsText: text))
    }

    /// Read the `# Device` header — `Firmware:` / `Model:` / `MAC:` — so the caller can refuse an
    /// export from a DIFFERENT ring before merging it into a per-ring archive.
    public static func sourceRing(fromDiagnosticsText text: String) -> SourceRing {
        var ring = SourceRing()
        for line in text.split(whereSeparator: \.isNewline) {
            let whole = line.trimmingCharacters(in: .whitespaces)
            // ⚠️ MAC IS READ FROM THE RAW LINE, BEFORE THE `·` SPLIT BELOW. The redacted MAC is
            // `··:··:··:··:··:AD` — its padding character IS the same `·` used as the field
            // separator, so splitting first shreds it and the identity check then silently degrades
            // to "always prompt".
            if ring.macSuffix == nil, whole.hasPrefix("MAC:") {
                let v = whole.dropFirst("MAC:".count).trimmingCharacters(in: .whitespaces)
                if let last = v.split(separator: ":").last,
                   last.count == 2, UInt8(last, radix: 16) != nil {
                    ring.macSuffix = last.uppercased()
                }
            }
            // The report writes the other fields BOTH ways: a single `·`-separated summary line near
            // the top ("Firmware: FR02.018 · Generation: Gen 2 · Model: RingConn Gen2-03AD") and one
            // field per line inside the raw-capture's `# Device` block. Split on `·` so a value can
            // never swallow the fields that follow it on the same line.
            for segment in line.split(separator: "·") {
                let t = segment.trimmingCharacters(in: .whitespaces)
                func value(_ prefix: String) -> String? {
                    guard t.hasPrefix(prefix) else { return nil }
                    let v = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    return v.isEmpty ? nil : v
                }
                if ring.firmware == nil, let v = value("Firmware:") { ring.firmware = v }
                if ring.model == nil, let v = value("Model:") { ring.model = v }
            }
            // The header sits above the frame dump; stop before scanning thousands of hex lines.
            if line.hasPrefix("# Frames") { break }
        }
        return ring
    }

    /// Extract the hex payload of a `0x4c` capture line, or nil for any other line.
    ///
    /// Deliberately tolerant of the surrounding report (headers, gap tables, sleep summaries) and
    /// strict about the frame itself: the opcode token must be exactly `0x4c`, and every remaining
    /// token must be a two-digit hex byte. A `0x4c` written into prose elsewhere in the report
    /// cannot match, because prose does not parse as whole hex bytes.
    static func pageBytes(fromLine line: String) -> [UInt8]? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
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
