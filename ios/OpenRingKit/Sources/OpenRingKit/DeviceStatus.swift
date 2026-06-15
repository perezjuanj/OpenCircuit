// Device-status decode — the 0x10 / 0x87 fixed 19-byte descriptor (PROTOCOL.md §5.4).
//
// The ring emits this frame spontaneously (~30–60 s) and as the `0x07`/`0xd0` response.
// `[4:6]` is the ring's onboard **step count** (16-bit big-endian) 🟢 — confirmed by a
// from-scratch sync: the app showed 81 steps and `[4:6]` read exactly 81, `0` when idle.
// This is the ring's own count; the official app normally shows a cloud-aggregated daily
// total that can differ.

import Foundation

/// Skin temperature decoded from a 0x10/0x87 descriptor (PROTOCOL.md §5.4 🟢).
/// Two near-equal 16-bit channels (skin + reference); `celsius` is their mean.
public struct SkinTemperature: Equatable, Sendable {
    public let channelA: Double   // [6:8], °C
    public let channelB: Double   // [8:10], °C
    public var celsius: Double { (channelA + channelB) / 2 }
    public var fahrenheit: Double { celsius * 9 / 5 + 32 }
}

public enum DeviceStatus {
    /// The ring's onboard step count from a 0x10/0x87 descriptor frame, or nil if the
    /// frame isn't one. The value can legitimately be 0 (no steps yet).
    public static func steps(_ frame: [UInt8]) -> Int? {
        guard frame.count >= 19, frame[0] == 0x10 || frame[0] == 0x87 else { return nil }
        return (Int(frame[4]) << 8) | Int(frame[5])
    }

    /// Battery percentage from a 0x10/0x87 descriptor: **byte[1]** (§5.4 🟢, ground-truthed
    /// 2026-06-15: `0x4c`=76 matched the app's 76% exactly at capture time; the buffer showed
    /// a clean 92→76 discharge curve). Returns nil if not a descriptor or out of the 1…100 band.
    public static func battery(_ frame: [UInt8]) -> Int? {
        guard frame.count >= 19, frame[0] == 0x10 || frame[0] == 0x87 else { return nil }
        let pct = Int(frame[1])
        return (1...100).contains(pct) ? pct : nil
    }

    /// Skin temperature from a 0x10/0x87 descriptor: two 0.1 °C big-endian channels at
    /// `[6:8]`/`[8:10]` (§5.4 🟢, ground-truthed 2026-06-15). The descriptor streams live
    /// while connected — temperature is NOT in the 0x4c sleep sync. Returns nil if the
    /// frame isn't a descriptor or the reading is outside a plausible band (filters
    /// zero/garbage frames); a cold/just-donned ring still reads ~28 °C and is returned.
    public static func skinTemperature(_ frame: [UInt8]) -> SkinTemperature? {
        guard frame.count >= 19, frame[0] == 0x10 || frame[0] == 0x87 else { return nil }
        let a = (Int(frame[6]) << 8) | Int(frame[7])
        let b = (Int(frame[8]) << 8) | Int(frame[9])
        guard (150...500).contains(a), (150...500).contains(b) else { return nil }  // 15–50 °C
        return SkinTemperature(channelA: Double(a) / 10, channelB: Double(b) / 10)
    }
}
