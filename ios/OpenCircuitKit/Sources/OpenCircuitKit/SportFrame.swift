// SportFrame.swift — RingConn native SPORT-mode protocol (#90).
//
// The ring has a dedicated workout mode entered with `06 03 <type> 04 00` (SportStart),
// which streams a `0x4e` frame roughly every ~10 s carrying HR + steps for the interval,
// each acked with `ce 00 00` (0x4e = 0xce ^ 0x80), and ended with `06 00 00` (SportStop).
//
// Ground truth (🟢 FR02.018, captured 2026-07-06, HR+steps validated on 2 workouts):
//   yoga     `06 03 07 04 00` → avg 75 / max 81, ~0 steps (matched app exactly)
//   walk     `06 03 02 04 00` → avg 80 / max 90, 178 steps ≈ app's ~170
//
//   0x4e frame: `4e <cursor:4 BE> <hr> <steps> <misc…> <xor>`
//     [0]      = 0x4e opcode
//     [1..<5]  = cursor (sync-epoch seconds, big-endian) — the interval's end time
//     [5]      = HR bpm
//     [6]      = steps taken in this interval
//     [7..<12] = perfusion/quality (undecoded, not needed)
//     [last]   = XOR trailer
//
// Calories, the 5 HR zones, and distance are NOT on the wire — the app/cloud computes them
// (we do too: Edwards-TRIMP kcal, HRZoneClassifier, phone GPS). See docs/PROTOCOL.md §4.

import Foundation

/// The 7 workout types the RingConn app drives via `06 03 <type>` (🟢 all captured; these are
/// the only workouts the app offers). The type byte tunes the ring's own HR sampling for the
/// activity; on our side the user-facing HealthKit type is chosen independently (WorkoutSportType).
public enum SportType: UInt8, CaseIterable, Sendable {
    case outdoorRunning = 0x01
    case outdoorWalking = 0x02
    case indoorRunning  = 0x03
    case outdoorCycling = 0x04
    case indoorCycling  = 0x05
    case indoorRowing   = 0x06
    case yoga           = 0x07

    public var displayName: String {
        switch self {
        case .outdoorRunning: return "Outdoor Running"
        case .outdoorWalking: return "Outdoor Walking"
        case .indoorRunning:  return "Indoor Running"
        case .outdoorCycling: return "Outdoor Cycling"
        case .indoorCycling:  return "Indoor Cycling"
        case .indoorRowing:   return "Indoor Rowing"
        case .yoga:           return "Yoga"
        }
    }
}

public enum SportFrame {

    /// One decoded sample from a ring→host `0x4e` sport-stream frame.
    public struct Sample: Equatable, Sendable {
        /// HR in bpm, or nil if outside the plausible band (warm-up sentinel / decode artifact).
        public let hr: Int?
        /// Steps taken in this ~10 s interval (byte[6]).
        public let steps: Int
        /// Interval-end cursor: seconds since the sync epoch (2019-12-31 12:00 UTC), big-endian.
        public let cursor: UInt32

        public init(hr: Int?, steps: Int, cursor: UInt32) {
            self.hr = hr
            self.steps = steps
            self.cursor = cursor
        }
    }

    /// Decode a `0x4e` sport-stream frame. Validates the XOR trailer first, then extracts
    /// HR (byte[5], gated to the plausible band) and steps (byte[6]). Returns nil for any
    /// non-`0x4e` / too-short / bad-checksum frame.
    public static func decode(_ payload: [UInt8]) -> Sample? {
        guard payload.count >= 8, payload[0] == 0x4e, Frame.isValid(payload) else { return nil }
        let cursor = (UInt32(payload[1]) << 24) | (UInt32(payload[2]) << 16)
                   | (UInt32(payload[3]) << 8)  |  UInt32(payload[4])
        let hrByte = Int(payload[5])
        let hr = LiveHR.validBPM.contains(hrByte) ? hrByte : nil
        return Sample(hr: hr, steps: Int(payload[6]), cursor: cursor)
    }
}
