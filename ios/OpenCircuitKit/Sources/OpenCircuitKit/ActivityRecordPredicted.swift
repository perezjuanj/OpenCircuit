// Predicted decoder for the still-uncaptured 历史活动响应 ("history ACTIVITY response")
// record — PROTOCOL.md §5.3.1, issue #93. This is a DIFFERENT record from the `0x4c`
// MEASUREMENT record `BulkRecord` decodes; it has never been observed on the wire. Channel
// `0x02` is now ruled out: the 2026-07-11 workout capture proves it returns `0x4d` 10-second
// SPORT records (#179), decoded by `HistoricalSportFrame`. The remaining unknown selectors
// can still be swept with `RingSession.probeActivityChannels`.
//
// Layout below is PREDICTED via the `wire_index = APK_loc - 3` convention already validated
// against the MEASUREMENT record (PROTOCOL.md §5.3: 5 independent fields landed byte-for-byte
// using the same convention) — ported 1:1 from `desktop/decode_activity.py`'s
// `decode_activity_record_PREDICTED()`. Keep the two in sync. Every field here is 🔴
// unconfirmed until a real `byte[6]=0x02` capture proves it.
//
// Do NOT wire this into BulkSleep, HealthKitWriter, or any UI before that capture validates
// it — running it on today's MEASUREMENT records returns implausible values BY DESIGN (see
// `isPlausible`); that's the whole point of the sanity check.
//
// Distance is deliberately NOT a field here: PROTOCOL.md §5.3.1 confirms the app computes
// distance client-side (`steps × 0.248m`, see `DistanceEstimate`), it is never on the wire.

import Foundation

/// Predicted decode of a 23-byte 历史活动响应 record (🔴 unconfirmed — see file header).
public struct ActivityRecordPredicted: Equatable {
    public let date: Date
    /// 🔴 per-epoch step count (LE, per the decompiled field type).
    public let steps: Int
    /// 🔴 wear/charge state enum.
    public let deviceState: UInt8
    /// 🔴 per-epoch battery % (0...100 if the prediction is right).
    public let powerLevel: UInt8
    /// 🔴 four per-epoch skin-temp samples — distinct from the live `0x10`/`0x87`
    /// descriptor temperature (§5.4); units/scale unconfirmed.
    public let temp1: Int
    public let temp2: Int
    public let temp3: Int
    public let temp4: Int
    /// 🔴 three unidentified small integers (`item5p0_1/2/3` in the decompiled field names).
    public let item5p0: [UInt8]
    /// 🔴 active seconds this epoch — predicted bound 0...150 (the epoch length).
    public let activeSeconds: Int
    /// 🔴 stand/active flag for this epoch.
    public let dailyActiveFlag: UInt8

    /// Decode a raw 23-byte record via the PREDICTED 历史活动响应 layout
    /// (`wire_index = APK_loc - 3`). Returns nil if `bytes` isn't a whole record.
    /// Mirrors `desktop/decode_activity.py:decode_activity_record_PREDICTED()` exactly —
    /// keep the two in sync if either changes.
    public static func decode(_ bytes: [UInt8], epoch: Int = Command.syncEpoch) -> ActivityRecordPredicted? {
        guard bytes.count == BulkRecord.length else { return nil }
        func le16(_ i: Int) -> Int { Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
        let counter = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return ActivityRecordPredicted(
            date: Date(timeIntervalSince1970: TimeInterval(Int(counter) + epoch)),
            steps: le16(4),
            deviceState: bytes[6],
            powerLevel: bytes[7],
            temp1: le16(8), temp2: le16(10), temp3: le16(12), temp4: le16(14),
            item5p0: [bytes[16], bytes[17], bytes[18]],
            activeSeconds: le16(19),
            dailyActiveFlag: bytes[21]
        )
    }

    /// Sanity bounds a genuine activity record should satisfy — mirrors the Python script's
    /// self-verify (`power_level<=100`, `active_seconds<=150`, `steps<=5000`). Run this
    /// against a real `byte[6]=0x02` capture: if most worn epochs FAIL it, either the
    /// predicted layout or the capture is wrong. Today's MEASUREMENT records fail it by
    /// design — they aren't this record at all (PROTOCOL.md §5.3.1's own demonstration).
    public var isPlausible: Bool {
        powerLevel <= 100 && activeSeconds <= 150 && steps <= 5000
    }
}
