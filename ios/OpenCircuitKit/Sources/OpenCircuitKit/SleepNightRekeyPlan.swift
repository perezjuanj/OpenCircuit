// The DECISION half of the one-shot "bedtime day → wake day" night-key migration
// (`LocalStore.rekeySleepNightsToWakeDay`), split out so it can be tested.
//
// WHY IT LIVES HERE. The migration rewrites the uniquely-indexed primary key of the user's only
// copy of their sleep history, behind a one-way latch, with no reverse mapping. It is the highest-
// risk code in the sleep path and it was originally written with no test coverage at all — the
// app-target XCTest suite crashes rather than fails, so a test placed there would not have run.
// Everything here is pure Foundation, so `swift test` exercises the ordering, the idempotence, the
// occupied-destination refusal and the degenerate-row refusal for real. The app side is left with
// nothing but "apply these moves".
//
// See SleepNightKey for the collision this migration repairs.

import Foundation

public enum SleepNightRekeyPlan {

    /// The only three fields the decision needs from a stored summary.
    public struct Row: Equatable, Sendable {
        public let night: Date
        public let inBedStart: Date
        public let inBedEnd: Date

        public init(night: Date, inBedStart: Date, inBedEnd: Date) {
            self.night = night
            self.inBedStart = inBedStart
            self.inBedEnd = inBedEnd
        }
    }

    /// One row's intended relocation, in normalized (start-of-day) keys.
    public struct Move: Equatable, Sendable {
        public let from: Date
        public let to: Date

        public init(from: Date, to: Date) {
            self.from = from
            self.to = to
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Moves to apply IN THIS ORDER. Applying them in order guarantees each destination is free
        /// when its move runs.
        public let moves: [Move]
        /// Rows that wanted to move but whose destination is occupied by a row that is not itself
        /// moving. Refused rather than forced — `night` is uniquely indexed, and leaving a row on a
        /// stale key is strictly better than deleting a night.
        public let refused: [Move]

        public init(moves: [Move], refused: [Move]) {
            self.moves = moves
            self.refused = refused
        }
    }

    /// Decide which rows move where.
    ///
    /// NEWEST FIRST. Every move is "+1 day" — a night's in-bed window ends either on the day it
    /// started or the next one — so descending order frees each destination before the row below it
    /// asks for the slot. Ascending order would report a cascade of false collisions and leave the
    /// table half-migrated on the first launch, permanently (the caller latches a done-flag).
    ///
    /// Rows whose window is unknown or inverted are left alone entirely (`SleepNightKey.rekeyed`
    /// returns nil), so a legacy row with `.distantPast` edges can never be relocated to year 0.
    public static func plan(rows: [Row], calendar: Calendar = .current) -> Plan {
        guard !rows.isEmpty else { return Plan(moves: [], refused: []) }
        var occupied = Set(rows.map { calendar.startOfDay(for: $0.night) })
        var moves: [Move] = []
        var refused: [Move] = []
        for row in rows.sorted(by: { $0.night > $1.night }) {
            guard let newKey = SleepNightKey.rekeyed(storedNight: row.night,
                                                     inBedStart: row.inBedStart,
                                                     inBedEnd: row.inBedEnd,
                                                     calendar: calendar) else { continue }
            let oldKey = calendar.startOfDay(for: row.night)
            let move = Move(from: oldKey, to: newKey)
            guard !occupied.contains(newKey) else { refused.append(move); continue }
            occupied.remove(oldKey)
            occupied.insert(newKey)
            moves.append(move)
        }
        return Plan(moves: moves, refused: refused)
    }
}
