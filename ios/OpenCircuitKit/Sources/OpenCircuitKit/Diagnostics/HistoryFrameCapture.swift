// Debug-only raw history-frame recorder (Gen 3 triage).
//
// OpenCircuit's BLE protocol was reverse-engineered against the Gen 2 (FW FR02.018). The
// `0x4c` sleep/activity record layout in BulkSleep.swift (23-byte records, [4]=HR / [5]=HRV /
// [8]=SpO2, 150 s epoch step) is pinned to THAT firmware. On a different generation the live /
// descriptor / step paths still work, but the overnight sleep-vitals records may not decode —
// which presents as HRV / Respiratory Rate / Sleep stuck on "after overnight sync" while
// everything else populates (discussion #111, a Gen 3 ring).
//
// To recover the Gen 3 record layout we need the RAW `0x4c`/`0x47` history bytes, but the live
// log only records page byte-COUNTS, and an iOS-only tester can't take an Android HCI snoop log.
// Worse, the overnight history is usually drained in the BACKGROUND, so a Mac-attached
// `log stream` capture would miss it. This type is the pure, persistable buffer the app records
// into during any drain (foreground OR background) so the tester can export it from a debug
// build and send it to us to decode.
//
// Pure value type (no BLE/Foundation-UI deps beyond Date) so it's unit-testable; the app owns
// persistence (UserDefaults, like the battery history) and the share-sheet export.

import Foundation

/// One raw frame received from the ring, kept for offline decoding.
public struct CapturedFrame: Codable, Equatable, Sendable {
    /// Wall-clock time the frame arrived.
    public let date: Date
    /// First byte (opcode), broken out so a capture can be summarised by opcode without re-parsing.
    public let opcode: UInt8
    /// Full frame as lowercase space-separated hex (e.g. "4c 00 12 …").
    public let hex: String
    /// Frame length in bytes (redundant with `hex` but cheap and handy in the summary).
    public let byteCount: Int

    public init(date: Date, bytes: [UInt8]) {
        self.date = date
        self.opcode = bytes.first ?? 0
        self.hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        self.byteCount = bytes.count
    }
}

/// Bounded ring buffer of captured frames + a human-readable report serializer.
public struct HistoryFrameCapture: Codable, Equatable, Sendable {
    /// Captured frames, oldest → newest.
    public private(set) var frames: [CapturedFrame]
    /// Keep at most this many (newest survive). A full overnight drain is only a few hundred
    /// history/descriptor frames, so this comfortably holds a whole night without unbounded growth.
    public static let cap = 1500

    public init(frames: [CapturedFrame] = []) {
        self.frames = frames
        trim()
    }

    public var count: Int { frames.count }

    /// Opcodes worth capturing for protocol triage: history pages (`0x47` PPG / `0x4c` sleep),
    /// the end-of-history cursor (`0x50`), the sync-open ACK (`0x82`), and the status descriptor
    /// (`0x10`/`0x87`). Deliberately EXCLUDES the high-rate live samples (`0x15`) and heartbeats
    /// (`0x11`) so the buffer stays focused on the sleep/history path that's failing on Gen 3.
    public static let capturedOpcodes: Set<UInt8> = [0x47, 0x4c, 0x50, 0x82, 0x10, 0x87]

    /// True when this opcode should be recorded (see `capturedOpcodes`).
    public static func shouldCapture(_ bytes: [UInt8]) -> Bool {
        guard let op = bytes.first else { return false }
        return capturedOpcodes.contains(op)
    }

    /// Record a frame if its opcode is one we triage on. No-op otherwise. Returns whether it was
    /// recorded, so the caller can skip a (costly) persist when nothing changed.
    @discardableResult
    public mutating func recordIfRelevant(_ bytes: [UInt8], at date: Date = Date()) -> Bool {
        guard Self.shouldCapture(bytes) else { return false }
        frames.append(CapturedFrame(date: date, bytes: bytes))
        trim()
        return true
    }

    public mutating func clear() { frames.removeAll() }

    private mutating func trim() {
        if frames.count > Self.cap { frames.removeFirst(frames.count - Self.cap) }
    }

    /// Count of captured frames per opcode (for the report header), sorted by opcode.
    public func countsByOpcode() -> [(opcode: UInt8, count: Int)] {
        var tally: [UInt8: Int] = [:]
        for f in frames { tally[f.opcode, default: 0] += 1 }
        return tally.sorted { $0.key < $1.key }.map { (opcode: $0.key, count: $0.value) }
    }

    /// A shareable plain-text report: a device/firmware header, an opcode summary, then every
    /// captured frame as `timestamp  opcode  Nb  hex`. `firmware` ties the bytes to a specific
    /// generation/build so we know which layout to compare against.
    public func report(firmware: FirmwareInfo, generatedAt: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("OpenCircuit — RingConn history-frame diagnostic capture")
        lines.append("Generated: \(iso.string(from: generatedAt))")
        lines.append("")
        lines.append("# Device")
        lines.append("Firmware:     \(firmware.version.isEmpty ? "(unread)" : firmware.version)")
        lines.append("Generation:   \(firmware.generation.rawValue)")
        lines.append("Pinned build: \(FirmwareInfo.pinnedVersion)")
        lines.append("Model:        \(firmware.modelName.isEmpty ? "(unread)" : firmware.modelName)")
        lines.append("Manufacturer: \(firmware.manufacturer.isEmpty ? "(unread)" : firmware.manufacturer)")
        lines.append("HW revision:  \(firmware.hardwareRevision ?? "(unread)")")
        lines.append("MAC:          \(firmware.mac ?? "(unread)")")
        lines.append("")
        lines.append("# Privacy")
        lines.append("These frames include the ring's overnight HR / HRV / SpO₂ history bytes and its")
        lines.append("MAC. They are not encrypted health records, but treat this file as personal data")
        lines.append("and only share it with someone you trust to decode it.")
        lines.append("")
        lines.append("# Summary")
        lines.append("Frames captured: \(frames.count) (cap \(Self.cap))")
        for entry in countsByOpcode() {
            lines.append(String(format: "  0x%02x: %d", entry.opcode, entry.count))
        }
        lines.append("")
        lines.append("# Frames (oldest → newest)")
        if frames.isEmpty {
            lines.append("(none — enable capture, then do an overnight wear + morning sync)")
        } else {
            for f in frames {
                lines.append("\(iso.string(from: f.date))  "
                             + String(format: "0x%02x  %3db  ", f.opcode, f.byteCount)
                             + f.hex)
            }
        }
        return lines.joined(separator: "\n")
    }
}
