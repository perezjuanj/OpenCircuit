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

    // MARK: - Wear / charging proxy (#41, #60)
    //
    // ⚠️  PROXY ONLY. The hardware charging/wear byte at 0x10/0x87 [2] is not yet decoded
    // (#61 — needs a charged-vs-uncharged capture pair). These functions wrap the best
    // 🟡/🟢 proxies available today behind the same call signature that a future
    // hardware-byte decoder will fill in — callers stay identical when #61 lands.
    //
    // Use `isWorn` to gate sleep detection, temperature averaging, and HealthKit writes.
    // Use `isCharging` to surface a "ring on charger" hint in the UI. Both are labelled
    // "inferred" / "likely" everywhere they appear — never "confirmed".

    /// 🟡 Inferred wear state from the skin-temperature field of a 0x10/0x87 descriptor.
    ///
    /// A worn Gen-2 ring reads ~30–34 °C; off-wrist / on the charger it falls toward room
    /// ambient (~20–24 °C). Returns `true` when the mean of the two temperature channels
    /// is at or above the conservative `wornMinC` threshold, `false` when below, and `nil`
    /// when the frame isn't a descriptor or has no plausible temperature reading.
    ///
    /// The default threshold (`ActivityPeriod.wornMinTemperatureC` = 28 °C) is used by
    /// the sleep wear-gate (#41) — pass an explicit value to override in tests.
    ///
    /// - Note: A miss here (ring cold from just being put on) costs at most one unfiltered
    ///   charger block; it never *adds* spurious sleep. Will be superseded by the decoded
    ///   hardware byte (#61).
    public static func isWorn(_ frame: [UInt8],
                              wornMinC: Double = ActivityPeriod.wornMinTemperatureC) -> Bool? {
        guard let temp = skinTemperature(frame) else { return nil }
        return temp.celsius >= wornMinC
    }

    /// 🟢 Inferred charging state from a rolling window of battery % readings.
    ///
    /// True when `batteryTrend` is a strictly rising sequence (every consecutive pair
    /// increases) — the confirmed indirect signal that the ring is charging. Delegates to
    /// `ChargingInference.inferred(from:)`; see that type for edge-case semantics
    /// (requires ≥ 2 readings; flat or falling returns `false`).
    ///
    /// - Note: Never certainty — label this "inferred" / "likely" in all UI copy.
    ///   Will be superseded by the decoded hardware byte (#61).
    public static func isCharging(batteryTrend: [Int]) -> Bool {
        ChargingInference.inferred(from: batteryTrend)
    }
}
