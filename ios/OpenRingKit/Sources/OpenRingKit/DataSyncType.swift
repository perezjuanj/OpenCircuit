// #99 — all-day HR / SpO₂ via the `0x02` sync-open `byte[6]` (DataSyncType) selector.
//
// The official RingConn app pulls all-day HR & SpO₂ as dedicated `HrSync` / `Spo2Sync`
// streams. The decompiled app (v3.2.1, blutter) classifies every metric with a 32-member
// `DataSyncType` enum; `hr/spo2/step/stand` are `ringData` (pulled from the ring) while
// `activity/stress/temperature` are `serverData` (cloud-computed). Our `0x02` sync-open
// carries a flag at `byte[6]` (PROTOCOL.md §5.3/§5.6) that is the prime suspect for that
// per-stream selector — we have only ever sent `0x00` (default sleep/activity), so we never
// pull the all-day HR/SpO₂ series.
//
// ⚠️ The selector ENCODING and the HR/SpO₂ record byte-layout are NOT statically recoverable
// (blutter dropped the BLE transport/parser from this build). They must come from a CAPTURE.
// This file is the on-device PROBE harness: it builds the sync-open for each candidate
// selector and classifies the raw responses — it deliberately does NOT decode HR/SpO₂ record
// fields (that would be fabrication until ground-truthed against the official app).
//
// Why the bonded iPhone, and why now: an earlier desktop sweep of flags 00/01/02/04/05/08 was
// inconclusive because it (a) used the far-future cursor 0xFFFFFFFF, which returns NO `0x82`
// ACK for ANY flag, and (b) predated the auth crack (#54), so it was auth-gated. Both blockers
// are resolved — this probe uses a real ≈now cursor and runs after the SM3 handshake, and adds
// the `off_2c` ring-data group (0x0a/0x0b/0x0c/0x0d) the old sweep never tried.

import Foundation

/// One candidate `byte[6]` selector to test, annotated with what it WOULD select under each
/// hypothesis (enum-index vs. the `off_2c` ring-data group). 🔴 all candidates are guesses until
/// the probe ground-truths which one returns an all-day HR/SpO₂ series.
public struct DataSyncSelector: Equatable {
    /// The raw `byte[6]` value written in the sync-open.
    public let byte: UInt8
    /// Human-readable note: which metric/stream this maps to under which hypothesis.
    public let label: String
    public init(byte: UInt8, label: String) {
        self.byte = byte
        self.label = label
    }
}

/// How a raw response frame is bucketed during a probe — by OPCODE only, with NO semantic field
/// decode. A brand-new opcode appearing for an HR/SpO₂ selector (`.unknown`) is the smoking gun
/// for a dedicated `HrSync`/`Spo2Sync` response stream.
public enum ProbeFrameClass: String, Equatable {
    case syncOpenAck      // 0x82 — the sync-open was accepted (cursor in range, stream opening)
    case historyPage      // 0x47 / 0x4c — the known activity/sleep/PPG drain
    case endOfHistory     // 0x50 — end-of-history cursor report
    case descriptor       // 0x10 / 0x87 — steps/temp/battery status descriptor
    case liveSample       // 0x15 — live HR/SpO₂ stream
    case authChallenge    // 0x81 — auth handshake
    case heartbeat        // 0x11 — ring keepalive
    case unknown          // anything else — a candidate NEW stream opcode (most interesting)

    public init(opcode: UInt8) {
        switch opcode {
        case 0x82: self = .syncOpenAck
        case 0x47, 0x4c: self = .historyPage
        case 0x50: self = .endOfHistory
        case 0x10, 0x87: self = .descriptor
        case 0x15: self = .liveSample
        case 0x81: self = .authChallenge
        case 0x11: self = .heartbeat
        default: self = .unknown
        }
    }
}

/// Accumulated evidence for ONE selector during a probe sweep. Mutated frame-by-frame by the BLE
/// layer; pure data (no BLE types) so it's testable and surfaceable in the UI / unified log.
public struct SelectorProbeResult: Equatable, Identifiable {
    public var id: UInt8 { selector }
    public let selector: UInt8
    public let label: String
    /// True once a `0x82` sync-open ACK arrived — the open was ACCEPTED for this selector.
    public var sawAck: Bool = false
    /// Distinct response opcodes seen, in first-seen order.
    public var opcodes: [UInt8] = []
    public var frameCount: Int = 0
    /// A few raw frames (hex) for the user/decoder to inspect; capped to keep the log small.
    public var sampleFrames: [String] = []

    public init(selector: UInt8, label: String) {
        self.selector = selector
        self.label = label
    }

    public static let sampleCap = 8

    /// Fold one raw response frame into this result. No-op on an empty frame.
    public mutating func record(_ bytes: [UInt8]) {
        guard let op = bytes.first else { return }
        frameCount += 1
        if !opcodes.contains(op) { opcodes.append(op) }
        if op == 0x82 { sawAck = true }
        if sampleFrames.count < Self.sampleCap {
            sampleFrames.append(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
    }

    /// Opcodes seen for this selector that the control selector (`0x00`, default sleep/activity)
    /// did NOT produce — i.e. evidence this selector opened a DIFFERENT stream.
    public func novelOpcodes(vsControl control: [UInt8]) -> [UInt8] {
        opcodes.filter { !control.contains($0) }
    }
}

public enum DataSyncProbe {

    /// Build a sync-open for an arbitrary `byte[6]` selector: `02 00 <cursor BE4> <selector> 01 00`
    /// (PROTOCOL.md §5.6). `cursor = unixSeconds − Command.syncEpoch`. Selector `0x00` reproduces
    /// the normal history open (`Command.syncSince`) exactly — the probe's control.
    public static func syncOpen(unixSeconds: Int, selector: UInt8) -> [UInt8] {
        let c = UInt32(clamping: unixSeconds - Command.syncEpoch)
        return [0x02, 0x00,
                UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF),
                selector, 0x01, 0x00]
    }

    /// Convenience: a sync-open at ≈now for `selector`. `now` injectable for tests.
    public static func syncOpenNow(selector: UInt8, now: Date = Date()) -> [UInt8] {
        syncOpen(unixSeconds: Int(now.timeIntervalSince1970), selector: selector)
    }

    /// The full candidate sweep. Covers both hypotheses plus the two observed controls:
    ///   • enum INDEX:  hr=0x00, spo2=0x01, step=0x02, temperature=0x03, stand=0x04, activity=0x06
    ///   • off_2c GROUP (ring-data): sleep=0x05, hr=0x0a, spo2=0x0b, step=0x0c, stand=0x0d
    /// `0x00` (current default → sleep/activity) and `0x03` (also observed → activity/sleep) are the
    /// CONTROLS; `0x08` was in the old (inconclusive) sweep. The prime new candidates are `0x0a`
    /// (off_2c hr) and `0x0b` (off_2c spo2). 🔴 all guesses until the probe ground-truths them.
    public static let candidates: [DataSyncSelector] = [
        DataSyncSelector(byte: 0x00, label: "control — current default (sleep/activity); enum-idx hr"),
        DataSyncSelector(byte: 0x01, label: "enum-idx: spo2"),
        DataSyncSelector(byte: 0x02, label: "enum-idx: step"),
        DataSyncSelector(byte: 0x03, label: "control — observed (activity/sleep); enum-idx temperature"),
        DataSyncSelector(byte: 0x04, label: "enum-idx: stand"),
        DataSyncSelector(byte: 0x05, label: "off_2c: sleep"),
        DataSyncSelector(byte: 0x06, label: "enum-idx: activity (serverData — may be empty)"),
        DataSyncSelector(byte: 0x08, label: "prior-sweep value (unknown)"),
        DataSyncSelector(byte: 0x0a, label: "★ off_2c: hr — prime all-day HR candidate"),
        DataSyncSelector(byte: 0x0b, label: "★ off_2c: spo2 — prime all-day SpO₂ candidate"),
        DataSyncSelector(byte: 0x0c, label: "off_2c: step / enum-idx stress"),
        DataSyncSelector(byte: 0x0d, label: "off_2c: stand / enum-idx sleep"),
    ]

    /// Build a human-readable report from a completed sweep. Flags each selector that ACKed and
    /// produced an opcode the `0x00` control did not — the candidates worth decoding. Pure +
    /// testable; the BLE layer logs this and the UI shows it.
    public static func summarize(_ results: [SelectorProbeResult]) -> String {
        guard !results.isEmpty else { return "No probe results." }
        var control: [UInt8] = []
        for r in results where r.selector == 0x00 { control = r.opcodes }
        let hot = results.filter { $0.sawAck && !$0.novelOpcodes(vsControl: control).isEmpty }

        var lines: [String] = []
        lines.append("Sync-open byte[6] (DataSyncType) sweep — \(results.count) selectors, real ≈now cursor, post-auth (#99).")
        if hot.isEmpty {
            lines.append("No selector produced an opcode the control (0x00) didn't — byte[6] may NOT be the HR/SpO₂ stream selector, or HR/SpO₂ rides a different command. Inspect the per-selector frames below.")
        } else {
            let names = hot.map { String(format: "0x%02x", $0.selector) }.joined(separator: ", ")
            lines.append("⭑ Novel-stream candidates (ACK + opcode not in control): \(names). Decode these against the official app's all-day HR/SpO₂.")
        }
        lines.append("")
        for r in results {
            let ack = r.sawAck ? "ACK✓" : "no-ACK"
            let ops = r.opcodes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let novel = r.novelOpcodes(vsControl: control)
            // Classify each novel opcode (ProbeFrameClass): an `.unknown` one is the prize — a
            // dedicated HrSync/Spo2Sync response the known opcodes don't cover.
            let novelStr = novel.isEmpty ? "" : "  NOVEL[" + novel.map(describeOpcode).joined(separator: " ") + "]"
            lines.append(String(format: "0x%02x", r.selector) + " \(ack) frames=\(r.frameCount) op=[\(ops)]\(novelStr) — \(r.label)")
        }
        return lines.joined(separator: "\n")
    }

    /// Format an opcode with its `ProbeFrameClass` for the report, e.g. `4d(unknown→candidate-stream)`
    /// or `4c(historyPage)` — so a novel HR/SpO₂ opcode is called out as the decode target.
    static func describeOpcode(_ op: UInt8) -> String {
        let cls = ProbeFrameClass(opcode: op)
        let tag = cls == .unknown ? "unknown→candidate-stream" : cls.rawValue
        return String(format: "%02x", op) + "(" + tag + ")"
    }
}
