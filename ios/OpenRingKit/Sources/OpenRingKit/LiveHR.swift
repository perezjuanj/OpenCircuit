// Live-sample decode — ported from desktop/openringconn/framing.py.
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

    /// HR in bpm from a SHORT `15 00 <hr> …` frame, or nil (incl. long `15 01` frames,
    /// whose byte[2] is 0 — they carry SpO2, not HR).
    public static func decode(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 4, payload[0] == 0x15, payload[1] == 0x00 else { return nil }
        return Int(payload[2])
    }

    /// HR only once the sensor has locked on (filters the warm-up sentinel).
    public static func decodeLocked(_ payload: [UInt8]) -> Int? {
        guard let hr = decode(payload), hr >= minValidBPM else { return nil }
        return hr
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
