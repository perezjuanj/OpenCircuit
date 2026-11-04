import Foundation
import ZeppKit

/// Which wrist the strap is on for tennis and pickleball (decision 90b): the last choice, persisted in
/// `UserDefaults` (no schema change), `.left` until one is made. The recorder reads it at every start,
/// so the Start Workout shortcut uses it too (90d).
struct StrapWristStore {
    nonisolated static let key = "strapWorkoutWrist"
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Stored as the wire byte; anything else (unset, 0, a stale value) reads as `.left`.
    var wrist: StrapWrist {
        get { StrapWrist(rawValue: UInt8(clamping: defaults.integer(forKey: Self.key))) ?? .left }
        nonmutating set { defaults.set(Int(newValue.rawValue), forKey: Self.key) }
    }
}
