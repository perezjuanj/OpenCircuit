// The realtime step stream on endpoint `0x0016` (ZEPP_PROTOCOL.md §7.2, §16.2 row 5, §16.5),
// plaintext. Pure: the commands, and the two messages the strap sends back.
//
//   phone → strap   `05 01` on, `05 00` off. The setting PERSISTS across connections (§16.2 row 5).
//   strap → phone   `06 <status> <enabled>`, the ack of `05 xx`.
//                   `07` + 13 bytes while the stream is on; steps = u16 LE at offset 1 of the 13.
//
// 🔴 on the Helio: no strap has been seen to send these frames yet (decision 84a). Who may send `05 01`,
// and when the owed `05 00` goes out, is the app's rule (decision 84b, `HelioSession`).

import Foundation

public enum ZeppRealtimeSteps {
    /// `05 01`: turn the stream on.
    public static let enable: [UInt8] = [0x05, 0x01]
    /// `05 00`: turn the stream off.
    public static let disable: [UInt8] = [0x05, 0x00]

    /// The bytes after the `07` opcode in a step frame (§16.2 row 5).
    public static let frameBodyLength = 13

    public enum Message: Equatable, Sendable {
        /// The strap's step counter, as it reported it. A running counter, not a per-frame count:
        /// use `StepCounterDeltas` (OpenCircuitKit) for the steps between two frames.
        case steps(UInt16)
        /// The ack of `05 xx`: its status byte, and the enabled byte when the ack carries one.
        // SPEC-GAP: §7.2 gives the layout `06 <status> <enabled>` but not which status means success,
        // so the status is reported as received (the breadcrumb), never interpreted.
        case ack(status: UInt8, enabled: UInt8?)
    }

    /// One message on `0x0016`, or nil for anything else (a short frame, another opcode).
    public static func parse(_ payload: [UInt8]) -> Message? {
        switch payload.first {
        case 0x07?:
            // SPEC-GAP: §16.2 says "`07` + 13 bytes"; a longer frame is read by the same layout, a
            // shorter one is refused rather than guessed at.
            guard payload.count >= 1 + frameBodyLength else { return nil }
            // Offset 1 of the 13-byte body = payload offset 2.
            return .steps(UInt16(payload[2]) | UInt16(payload[3]) << 8)
        case 0x06?:
            guard payload.count >= 2 else { return nil }
            return .ack(status: payload[1], enabled: payload.count >= 3 ? payload[2] : nil)
        default:
            return nil
        }
    }
}
