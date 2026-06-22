// RingConn command/response opcodes — ported from desktop/opencircuit/ble.py.
// All 🟢 confirmed from the FR02.018 capture (docs/PROTOCOL.md §4) unless noted.

import Foundation

public enum Opcode {
    /// Live-sample poll / keepalive → response 0x15. The app's `95 00 95`.
    public static let poll: UInt8 = 0x95
    /// Fetch next history record header → response 0x87.
    public static let fetchRecord: UInt8 = 0x07
    /// Bulk-transfer page ACK / continue → responses 0x47 and 0x4C.
    public static let page47: UInt8 = 0xC7
    public static let page4C: UInt8 = 0xCC

    // Session setup / metadata (roles partly 🟡 — see PROTOCOL.md §4).
    public static let sessionSetup: UInt8 = 0x01
    public static let syncOpen: UInt8 = 0x02
    public static let liveHRMode: UInt8 = 0x06
    public static let statusQuery: UInt8 = 0xD0
}

/// Exact command byte sequences, sent VERBATIM (🟢 verified live, PROTOCOL.md §3).
/// Commands are NOT XOR-checksummed — they end in a literal 0x00. Do not build
/// them with Frame.xorTrailer; that produces invalid frames the ring ignores
/// (e.g. the GB #4506 `95 00 95` is wrong — the real poll is `95 00 00`).
public enum Command {
    public static let status0: [UInt8] = [0x01, 0x00, 0x00]
    public static let status1: [UInt8] = [0x01, 0x01, 0x31, 0x82, 0x67, 0x00]
    /// Open the data session at cursor 0xFFFFFFFF — a far-FUTURE cursor. Believed to return an
    /// EMPTY history (the LIVE path's "skip the backlog, fast HR" open) — ⚠️ 🟡 NOT ground-truthed
    /// (§3): the official app never sends it, and whether it ADVANCES the ring's resume pointer is
    /// untested (if it does, the every-10-min auto-measure would shred the backlog). For history
    /// use `syncUpToNow` (cursor ≈ now → ring drains its backlog up to now). See §3 "Load-bearing".
    public static let syncAll: [UInt8] = [0x02, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x00]
    public static let statusQuery: [UInt8] = [0xD0, 0x00, 0x00]   // → 0x50; precedes live mode
    public static let liveHRMode: [UInt8] = [0x06, 0x01, 0x00]    // 06 01 = HR; 06 02 = SpO2
    public static let liveSpO2Mode: [UInt8] = [0x06, 0x02, 0x00]
    public static let fetch: [UInt8] = [0x07, 0x00, 0x00]
    public static let poll: [UInt8] = [0x95, 0x00, 0x00]
    public static let pageAck47: [UInt8] = [0xC7, 0x00, 0x00]
    public static let pageAck4C: [UInt8] = [0xCC, 0x00, 0x00]
    /// Reply to the ring's unsolicited `0x11` heartbeat (ring→host `11 00 <ctr> <tok> <xor>`).
    /// The official app answers every heartbeat with a constant `91 00 00` (0x11+0x80, same
    /// +0x80 response convention as 0x47→0xC7) — it does NOT echo the counter/token. 🟢 confirmed
    /// `ppg_align_20260616` (§5.8). The ring's `0x10` telemetry streams on its own timer
    /// regardless, but we ACK promptly so an activated ring has no reason to throttle us.
    public static let heartbeatAck: [UInt8] = [0x91, 0x00, 0x00]

    /// Steps to enter live-HR mode, in the order the official app sends them (verified
    /// in the FR02.018 capture: open+drain history, then `d0 00 00` → `06 01 00` → fetch,
    /// then poll `95 00 00` for `15 00 <hr>` frames). The `d0 00 00` is REQUIRED — without
    /// it the ring never switches to HR mode. Pages from the drain are acked in the BLE
    /// layer; poll after this sequence.
    public static let liveHRStart: [[UInt8]] = [status0, status1, syncAll, fetch,
                                                statusQuery, liveHRMode, fetch]

    /// Sync-cursor epoch: seconds since 2019-12-31 12:00:00 UTC (🟢 confirmed,
    /// PROTOCOL.md §5.6 — derived from 3 capture (time,cursor) pairs to <0.34 s).
    public static let syncEpoch = 1_577_793_600

    /// History-channel selector — `byte[6]` of the `0x02` sync-open. The ring keeps TWO history
    /// channels, each with its own resume cursor; the official app drains BOTH every sync (🟢 mined
    /// from every capture — the app only ever sends these two values):
    ///   • `0x00` — sleep/overnight log (+ idle epochs). What we historically pulled.
    ///   • `0x03` — awake/all-day log: activity HR + a periodic (~10 min) daytime SpO₂ reading.
    /// Pulling only `0x00` left daytime SpO₂ stale (the #99 gap). Same 23-byte record schema on both.
    public static let syncChannelSleep: UInt8 = 0x00
    public static let syncChannelAllDay: UInt8 = 0x03

    /// Build `02 00 <cursor BE4> <channel> 01 00` with `cursor = unixSeconds − syncEpoch` (big-endian).
    /// A plausible-recent cursor acts as a "drain up to ≈now" trigger (§3) — NOT a hard bound
    /// (records can overshoot it): the ring streams everything it hasn't handed off on `channel`,
    /// from its own internal resume point up to its current time, then self-advances that point.
    public static func syncSince(unixSeconds: Int, channel: UInt8 = syncChannelSleep) -> [UInt8] {
        // `clamping` (not `truncatingIfNeeded`): a pre-2020 clock clamps to 0, and a far-future
        // clock clamps to 0xFFFFFFFF (fails safe to the empty/skip-backlog open) instead of
        // silently WRAPPING to a small value that would look like a valid recent cursor.
        let c = UInt32(clamping: unixSeconds - syncEpoch)
        return [0x02, 0x00,
                UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF),
                channel, 0x01, 0x00]
    }

    /// Open a HISTORY sync "up to NOW" on `channel` — cursor ≈ current wall-clock (🟢 the official
    /// app's history behaviour, PROTOCOL.md §3: it opens at ≈now every sync). This triggers a drain
    /// up to the ring's current time and advances its OWN resume pointer, so there is nothing to
    /// persist on our side. Use this — NOT `syncAll` (0xFFFFFFFF, far-future, which does NOT pull
    /// history) — for sleep/vitals history. `now` is injectable for tests.
    public static func syncUpToNow(now: Date = Date(), channel: UInt8 = syncChannelSleep) -> [UInt8] {
        syncSince(unixSeconds: Int(now.timeIntervalSince1970), channel: channel)
    }

    /// Per-connection auth response: the ring challenges with `byte[2]` of its `81 00` reply, and
    /// the official app answers `01 01 <f(challenge)> 00` where `f` is a deterministic 256-entry
    /// keyed table (🟡 §5.7: e.g. `b0→31 82 67`, `86→db 2b 80`, `80→a9 a3 ef`, `52→27 7d 7f`).
    /// The ring does NOT appear to strictly enforce it (our fixed `status1` = `f(0xb0)` has worked),
    /// so this is informational until `f` is recovered from the APK. Returns the known nonce for a
    /// challenge, else nil (caller falls back to `status1`). Bytes confirmed via challenge-response
    /// correlation across 22 capture pairs; the full table needs the APK (issue #54).
    public static func authNonce(forChallenge c: UInt8) -> [UInt8]? {
        knownAuthNonces[c]
    }
    static let knownAuthNonces: [UInt8: [UInt8]] = [
        0x0f: [0x4b, 0xcc, 0xe6], 0x1f: [0x9b, 0xc9, 0x31], 0x3b: [0x4b, 0xee, 0x0c],
        0x3f: [0x67, 0x97, 0xa8], 0x49: [0x0b, 0x20, 0x6f], 0x52: [0x27, 0x7d, 0x7f],
        0x78: [0xda, 0x5d, 0x57], 0x80: [0xa9, 0xa3, 0xef], 0x81: [0x4c, 0xc4, 0xae],
        0x86: [0xdb, 0x2b, 0x80], 0x94: [0x71, 0xe9, 0x59], 0x96: [0x08, 0x60, 0xce],
        0x9d: [0x6b, 0x6e, 0x2c], 0xa3: [0x5e, 0xb6, 0x1e], 0xb0: [0x31, 0x82, 0x67],
        0xbc: [0x12, 0x52, 0xf2], 0xc2: [0x05, 0x33, 0x17], 0xc4: [0xa2, 0xf8, 0x27],
        0xcb: [0x09, 0x88, 0x9c], 0xd8: [0x9c, 0x61, 0x91], 0xda: [0xf0, 0x1e, 0x88],
        0xe3: [0x1b, 0xe9, 0x85], 0xe5: [0x52, 0x0b, 0xe1], 0xf9: [0x36, 0x09, 0xb2],
    ]   // 24/256 entries from captures (incl. 2026-06-16 login e5→52 0b e1). Full f() needs the APK.

    /// 🔴 UNKNOWN — the one-time login/activation command (if any) the official app sends so the
    /// ring starts streaming to a fresh client. NOT present in any steady-state capture; reverse-
    /// engineer from a first-time-provisioning / login btsnoop (issue #54), then fill + wire at the
    /// discovery handler. Current evidence (§0/§5.8) points to the LE-SC bond itself being the gate
    /// (local LTK, no cloud key) — in which case there is no app-layer command to send, only the
    /// CoreBluetooth auto-bond. Placeholder so the call site can land before the bytes are known:
    // public static func activate(/* token from login */) -> [UInt8] { … }
}

/// BLE transport handles (🟢). The ring is driven through this pair, not discrete
/// per-metric characteristics. iOS addresses by UUID, not handle — bind these via
/// `opencircuit scan` and fill the UUIDs in PROTOCOL.md before the BLE layer.
public enum Transport {
    public static let notifyHandle: UInt16 = 0x0804   // all responses + data
    public static let writeHandle: UInt16 = 0x0802    // all commands
    public static let notifyCCCD: UInt16 = 0x0805     // enable with [0x01, 0x00]

    /// Primary data service + characteristic UUIDs (🟢 confirmed by scan, FR02.018).
    /// Value handle 0x0804 (notify) / 0x0802 (write); service handle 0x0800.
    public static let dataServiceUUID = "8327ad99-2d87-4a22-a8ce-6dd7971c0437"
    public static let notifyCharUUID = "8327ad97-2d87-4a22-a8ce-6dd7971c0437"
    public static let writeCharUUID = "8327ad98-2d87-4a22-a8ce-6dd7971c0437"

    /// Advertised-name prefixes to match while scanning. Observed name is
    /// "RingConn Gen2-<MAC suffix>" (🟢); kept broad for older variants.
    public static let namePrefixes = ["RingConn", "Ring"]

    public static func matchesRingName(_ name: String) -> Bool {
        namePrefixes.contains { name.hasPrefix($0) }
    }
}
