// Ring vibration motor (Gen 3) — command bytes, patterns, and the model gate.
//
// ══ PROVENANCE ══ (docs/PROTOCOL.md §5.9)
//
// The motor opcode is NOT in the RingConn APK — it was recovered from a live HCI snoop of a Gen 3
// ring (FR05.011, official app 4.3.1) and then confirmed by driving it ourselves. Do not go looking
// for it in a decompile; the capture is the source.
//
// 🟢 CONFIRMED — 12 buzzes for 12 attempts across four distinct frames, driven from our own client
// on a tester's Gen 3 ring, with the wearer reporting each result blind:
//
//     0b 03 01 64 00  → short-short-long   (3/3)
//     0b 03 01 32 00  → short-short-long   (3/3)
//     0b 03 01 0a 00  → short-short-long   (3/3)
//     0b 03 02 64 00  → one long buzz      (3/3)
//
// The ring answers every one of them `8b 00 8b` (0x0b + 0x80, the standard response convention).
// Like all commands it is NOT XOR-checksummed — it ends in a literal 0x00 (see `Command`).
//
// Byte-by-byte, and the two things this cost us to learn:
//
//   [0] 0x0b  opcode.
//   [1] 0x03  subcommand. Constant in every frame the official app sent; never varied.
//   [2] PATTERN selector 🟢. 0x01 = short-short-long, 0x02 = one long buzz. Established the hard
//       way: the tester described the app's own buzzes blind and they partitioned exactly along
//       this byte, then `0x02`'s single long buzz was PREDICTED IN ADVANCE and held 3/3.
//   [3] 🟢 MEASURED INERT — it is not intensity and it is not duration. Tested across a 10× range
//       (0x64 = 100, 0x32 = 50, 0x0a = 10); all three buzzed, and the wearer reported all three
//       identical in strength AND in pattern. 🔴 What it actually means is unknown — plausibly
//       reserved, or a firmware floor clamping everything to full power. We send 0x64, exactly
//       what the official app sends, and we do not vary it: varying it buys nothing measurable and
//       0x64 is the only value with field evidence behind it. 0x00 is untested — leave it that way.
//   [4] 0x00  terminator.
//
// ⚠️ There is no "stop" command and no acknowledgement that the motor actually ran. `8b 00 8b`
// means the frame was accepted, not that the wearer felt anything. Anything built on this must
// treat delivery as unverified — see `RingAlarmOutcome`.

import Foundation

// MARK: - Patterns

/// The two motor patterns the ring firmware implements. There is no third — every frame the
/// official app was seen to send used `[2]` ∈ {0x01, 0x02}, and nothing else has been probed.
public enum VibrationPattern: UInt8, CaseIterable, Codable, Sendable, Equatable {
    /// Three pulses: short, short, long. What the official app uses for every reminder and for the
    /// end of a heart-rate or blood-oxygen measurement. 🟢
    case notification = 0x01
    /// One sustained buzz. The official app uses it to mark the start of a workout. 🟢
    case long = 0x02

    /// Short user-facing name for the settings screen.
    public var displayName: String {
        switch self {
        case .notification: return "Triple pulse"
        case .long:         return "Single long buzz"
        }
    }

    /// How it actually feels, for a picker where the user can't preview without a ring on.
    public var displayDetail: String {
        switch self {
        case .notification: return "Short, short, long — the pattern RingConn uses for reminders."
        case .long:         return "One sustained buzz — RingConn's workout-start signal."
        }
    }
}

// MARK: - Model gate

public enum RingVibration {
    /// The inert third byte, sent verbatim. See the provenance note above before changing it.
    public static let intensityByte: UInt8 = 0x64

    /// Whether this ring has a motor we can drive.
    ///
    /// Gen 3 ONLY, and deliberately narrow. The evidence is a Gen 3 ring (FR05.011) and nothing
    /// else: no Gen 1, Gen 2, or Gen 2 Air has ever been sent `0x0b`, so we do not know whether
    /// they would ignore it, buzz, or fault. `.unknown` (the state before the DIS firmware read
    /// lands) is excluded too — this gate hides a feature rather than degrading one, so failing
    /// CLOSED costs a user nothing but a moment's wait, while failing open would put a dead
    /// button in front of every Gen 2 owner.
    public static func isSupported(_ generation: RingGeneration) -> Bool {
        generation == .gen3
    }
}
