// Device-status decode — the 0x10 / 0x87 fixed 19-byte descriptor (PROTOCOL.md §5.4).
//
// The ring emits this frame spontaneously (~30–60 s) and as the `0x07`/`0xd0` response.
// `[4:6]` is the ring's onboard **step count** (16-bit big-endian) 🟢 — confirmed by a
// from-scratch sync: the app showed 81 steps and `[4:6]` read exactly 81, `0` when idle.
// This is the ring's own count; the official app normally shows a cloud-aggregated daily
// total that can differ.
//
// ⚠️ It is a **QUARTER-HOUR BUCKET, not a running day total** 🟢 (#192, re-derived 2026-08-09
// over 10,327 descriptor frames from two rings: 268 drops, every one at a wall-clock
// `:00`/`:15`/`:30`/`:45`, max value ever observed 746 against 2,611–4,566-step days). See
// `StepAccumulator` for the derivation, the ~108 s clear lag, and why the fold is what it is.

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
    /// frame isn't one.
    ///
    /// 🟢 **Steps so far in the ring's CURRENT WALL-CLOCK QUARTER-HOUR**, cleared to 0 at every
    /// `:00`/`:15`/`:30`/`:45` (#192). It is not cumulative over the day, so it must never be
    /// read as "today's steps" and cannot back-fill a quarter nobody observed. `0` is both
    /// legitimate and common — it means "no steps counted yet in this quarter", which is what
    /// most of a night looks like. Fold it with `StepAccumulator`.
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

    // MARK: - Charging state + voltage + case battery (DECODED, #61 / #89)
    //
    // Resolved 2026-06-19 by clean labelled A/B captures. Charger A/B (finger → charger → off →
    // finger): over a 6-min charge the battery rose 66→74 % and skin temp fell 31→27 °C, and `[2]`
    // read **0x04 for 100 % of charging frames and never** in the worn/off-wrist phases (~30×
    // enriched for a rising-battery window vs 0x02/0x03). In-case A/B (case 70→90 %, ring 93→99 %):
    // `[17]` tracked the case battery exactly. Map of the 0x10/0x87 status model (matches the app's
    // device-status fields: power, state, step, volt, …, chargingCasePower, chargingCaseCharging):
    //   `[1]`  = ring battery %                                                          🟢
    //   `[2]`  = state: 0x02/0x03 worn-stream toggle · 0x01 startup/settle · **0x04 ON CHARGER** 🟢
    //   `[4:6]`= step · `[6:10]` = skin temp (2 ch)                                       🟢
    //   `[14:16]` = ring voltage mV, 16-bit BE (4001→4384 across the charge)              🟢
    //   `[17]` = **CASE byte**: low 7 bits = case battery % · bit 0x80 = case charging ·
    //            0xff = ring NOT in case  (#89; was mis-read as a charging witness pre-fix) 🟢

    /// 🟢 True when a 0x10/0x87 descriptor reports the ring is **on the charger** (`[2] == 0x04`,
    /// PROTOCOL.md §5.4). Returns nil if the frame isn't a descriptor.
    ///
    /// This is the real hardware signal that supersedes the `isCharging(batteryTrend:)` proxy:
    /// it is per-frame, instant (flips on contact before temperature or battery % move), and does
    /// not depend on a rising-% window. Prefer it whenever a live descriptor frame is available;
    /// fall back to the battery-trend proxy only when no fresh frame exists.
    public static func isOnCharger(_ frame: [UInt8]) -> Bool? {
        guard frame.count >= 19, frame[0] == 0x10 || frame[0] == 0x87 else { return nil }
        return frame[2] == 0x04
    }

    /// 🟢 Ring battery voltage in millivolts from a 0x10/0x87 descriptor: `[14:16]`, 16-bit BE
    /// (PROTOCOL.md §5.4 / #89). Ground-truthed 2026-06-19: 4001 mV worn → 4384 mV peak charge →
    /// 4196 mV relaxed — a textbook single-cell Li-ion curve. Returns nil if the frame isn't a
    /// descriptor or the value is outside a plausible single-cell band (2.5–4.6 V), filtering
    /// zero/garbage frames.
    public static func batteryVoltageMillivolts(_ frame: [UInt8]) -> Int? {
        guard frame.count >= 19, frame[0] == 0x10 || frame[0] == 0x87 else { return nil }
        let mv = (Int(frame[14]) << 8) | Int(frame[15])
        return (2500...4600).contains(mv) ? mv : nil
    }

    /// Charging-case state decoded from a 0x10/0x87 descriptor `[17]` (#89 🟢).
    public struct CaseBattery: Equatable, Sendable {
        /// Case battery percentage (0…100).
        public let percent: Int
        /// True when the case itself is plugged in and charging (bit 0x80).
        public let isCharging: Bool
    }

    /// 🟢 Charging-case battery from a 0x10/0x87 descriptor: byte `[17]` packs both app fields —
    /// **low 7 bits = case battery %** (`chargingCasePower`), **bit 0x80 = case charging**
    /// (`chargingCaseCharging`). `0xff` is the sentinel for **ring not in the case** → nil.
    ///
    /// Ground-truthed 2026-06-19 (`captures/case89`): in-case readings 0x46→70 %, 0xc6→70 %+charging,
    /// 0xda→90 %+charging matched the official app's case % exactly; 0xff whenever the ring was out
    /// of the case. Returns nil if the frame isn't a descriptor, the ring isn't docked (0xff), or
    /// the percentage is implausible (> 100).
    public static func caseBattery(_ frame: [UInt8]) -> CaseBattery? {
        guard frame.count >= 19, frame[0] == 0x10 || frame[0] == 0x87 else { return nil }
        let b = frame[17]
        guard b != 0xff else { return nil }                 // not docked in the case
        let pct = Int(b & 0x7f)
        guard pct <= 100 else { return nil }                // garbage guard
        return CaseBattery(percent: pct, isCharging: (b & 0x80) != 0)
    }

    // MARK: - Wear proxy (#41, #56) + battery-trend charging fallback (#60)
    //
    // `isWorn` is still a temperature PROXY (no confirmed skin-contact byte — distinct from the
    // now-decoded charging byte above). `isCharging(batteryTrend:)` is the pre-#61 fallback for
    // when no live descriptor frame is in hand; with a frame, use `isOnCharger` instead.
    //
    // Use `isWorn` to gate sleep detection, temperature averaging, and HealthKit writes.
    // `isWorn` is labelled "inferred" / "likely" everywhere it appears — never "confirmed".

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

    /// 🟢 Inferred charging state from a rolling window of battery % readings — the **fallback**
    /// for when no live descriptor frame is available (use `isOnCharger(_:)`, the decoded
    /// `[2]==0x04` byte, whenever a frame is in hand).
    ///
    /// True when `batteryTrend` is a strictly rising sequence (every consecutive pair
    /// increases) — the indirect signal that the ring is charging. Delegates to
    /// `ChargingInference.inferred(from:)`; see that type for edge-case semantics
    /// (requires ≥ 2 readings; flat or falling returns `false`).
    ///
    /// - Note: Inferred, not instant — it needs the % to actually tick up. The decoded
    ///   `isOnCharger(_:)` byte (#61) is per-frame and supersedes it where a frame exists.
    public static func isCharging(batteryTrend: [Int]) -> Bool {
        ChargingInference.inferred(from: batteryTrend)
    }
}
