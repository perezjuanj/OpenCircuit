// Live-sample decode — ported from desktop/opencircuit/framing.py.
//
// The `0x95` poll yields a `0x15` frame in one of two shapes (PROTOCOL.md §5.1):
//   • HR mode (`06 01 00`):   `15 00 <hr> 0a b0 <xor>`  → byte[2] = HR bpm 🟢
//   • SpO2 mode (`06 02 00`): `15 01 … <spo2> …`        → byte[14] = SpO2 % 🟡
// HR is verified (HR-only capture settled to 61 bpm resting); the first HR sample is
// a warm-up sentinel (byte[2] ≈ 8). SpO2 byte[14] matches the app's 96–97% live.

import Foundation

public enum LiveHR {
    /// Below this, the sensor hasn't locked on (warm-up); treat as not-yet-valid.
    public static let minValidBPM = 30
    /// Upper physiological ceiling for a single HR reading. Above this is a decode artifact,
    /// not a real beat rate (the zone/max-HR formula tops out at 220 = 220 − age 0).
    public static let maxValidBPM = 220
    /// The plausible band a decoded HR must fall in to be treated as a real reading. Shared by
    /// the live decoder AND the history/sleep-vitals decoder so a garbage epoch (e.g. byte[4]==4,
    /// the cause of the impossible "Resting HR 4 bpm") can never become a persisted sample.
    public static let validBPM = minValidBPM...maxValidBPM

    /// HR in bpm from a SHORT `15 00 <hr> …` frame, or nil (incl. long `15 01` frames,
    /// whose byte[2] is 0 — they carry SpO2, not HR).
    public static func decode(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 4, payload[0] == 0x15, payload[1] == 0x00 else { return nil }
        return Int(payload[2])
    }

    /// HR only once the sensor has locked on AND within the plausible band (filters the warm-up
    /// sentinel ≈ 8 and any over-ceiling decode artifact).
    public static func decodeLocked(_ payload: [UInt8]) -> Int? {
        guard let hr = decode(payload), validBPM.contains(hr) else { return nil }
        return hr
    }

    // MARK: - Settling a user-facing reading

    /// Locked frames required before a live HR is shown or persisted as a finished reading.
    ///
    /// 🟢 MEASURED, from the only real poll capture the repo holds (FR02.018, `RingKitVerify`'s
    /// `realHRFrames`): ONE user read yields the locked sequence 82, 84, 88, 90, 91, 66, 61 — a
    /// 30 bpm spread inside a single measurement, after the warm-up sentinel (8) is filtered. A
    /// display that renders whichever frame happened to arrive last is therefore a coin flip
    /// across that spread in BOTH directions, which is what a tester saw as an "abnormally low"
    /// manual reading. The problem is not a warm-up ramp — the first locked frame there is 82 —
    /// it is that one frame was ever treated as the answer.
    ///
    /// 5 is chosen from the poll cadence, not fitted: `startLiveMonitoring` polls every 2 s, so
    /// 5 frames is ~10 s of measurement — reachable inside a normal read (the real capture holds
    /// 7 locked frames) — and a 5-sample median has a 2-sample breakdown point, so a single
    /// sensor dropout cannot move it. `RingSession.liveHRTrend` retains 12, so the window always
    /// fits.
    ///
    /// ⚠️ This matters far more on Gen 2 Air (FR04) than on Gen 2. Measured over the committed
    /// corpus, the share of epochs whose HR byte falls outside `validBPM` is 0.0–0.5 % on three
    /// FR02.018 captures against 0.4–6.7 % on three FR04.009 captures — roughly a 10× higher
    /// PPG-failure rate — so an Air user is correspondingly likelier to catch a bad frame.
    public static let settleSampleCount = 5

    /// The settled HR for a user-facing read: the median of the last `settleSampleCount` locked
    /// frames, or nil while fewer than that have arrived (the caller should still say "measuring…").
    ///
    /// The median, not the mean: it discards a symmetric pair of outliers outright rather than
    /// averaging them in, so one dropout frame and one spike frame both fall out of the answer.
    /// Pass `RingSession.liveHRTrend`, which holds only values that already passed `decodeLocked`.
    public static func settled(_ trend: [Int]) -> Int? {
        guard trend.count >= settleSampleCount else { return nil }
        let window = trend.suffix(settleSampleCount).sorted()
        return window[window.count / 2]
    }

    /// SpO2 % from a long SpO2-mode frame `15 01 … <spo2> …` (byte[14]), or nil. 🟡
    /// Note: single-window measurement, not multi-sample ground-truthed — render with
    /// "est." caveat in UI to indicate lower confidence (#59).
    public static func decodeSpO2(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 15, payload[0] == 0x15, payload[1] == 0x01 else { return nil }
        let spo2 = Int(payload[14])
        return (70...100).contains(spo2) ? spo2 : nil
    }
}
