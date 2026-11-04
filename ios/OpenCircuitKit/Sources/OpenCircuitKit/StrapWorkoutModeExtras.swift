// StrapWorkoutModeExtras.swift — what the strap's own workout mode adds to a strap workout (#359,
// decision 89e, 89h): whether the mode ran, the strap's swing count and its kcal estimate, and the
// `HKWorkout` metadata keys they are stored under (named here, once).
//
// Display and metadata only. Heart rate, zones, training load and the energy OpenCircuit writes to
// Apple Health keep coming from the standard `0x2A37` stream exactly as before (89d); the strap's kcal
// is shown as its own estimate, beside OpenCircuit's, and never replaces it.

import Foundation

public struct StrapWorkoutModeExtras: Codable, Equatable, Sendable {
    /// The strap's workout mode ran for this workout: its start was accepted and frames came (89h).
    public var ranWithWorkoutMode: Bool
    /// The strap's swing count from its last frame that carried one (racket sports); nil when no frame did.
    public var swings: Int?
    /// The strap's own running kcal total from its last frame; nil when no frame came.
    public var strapKilocalories: Int?

    public init(ranWithWorkoutMode: Bool = false, swings: Int? = nil, strapKilocalories: Int? = nil) {
        self.ranWithWorkoutMode = ranWithWorkoutMode
        self.swings = swings
        self.strapKilocalories = strapKilocalories
    }
}

/// The custom `HKWorkout` metadata keys (89e, 89h). Values are plain numbers, as HealthKit stores
/// custom metadata.
public enum StrapWorkoutMetadata {
    /// The strap's swing count (racket sports only).
    public static let swingCountKey = "OCStrapSwingCount"
    /// The strap's own active-energy estimate, kcal. NOT the energy sample OpenCircuit writes.
    public static let activeEnergyKey = "OCStrapActiveEnergyKcal"
    /// 1 = the strap's workout mode ran, 0 = phone-side. Missing (workouts before #359) = phone-side.
    public static let workoutModeKey = "OCStrapWorkoutMode"

    /// The metadata for a strap workout's `HKWorkout`: the mode flag always, the swings and the strap's
    /// kcal only when the strap reported them.
    public static func metadata(_ extras: StrapWorkoutModeExtras) -> [String: Int] {
        var out = [workoutModeKey: extras.ranWithWorkoutMode ? 1 : 0]
        if let swings = extras.swings { out[swingCountKey] = swings }
        if let kcal = extras.strapKilocalories { out[activeEnergyKey] = kcal }
        return out
    }

    /// Read back from a saved workout's metadata. A missing or unreadable flag is phone-side.
    public static func extras(from metadata: [String: Any]?) -> StrapWorkoutModeExtras {
        func int(_ key: String) -> Int? {
            switch metadata?[key] {
            case let value as Int: return value
            case let value as NSNumber: return value.intValue
            case let value as Double where value.isFinite: return Int(value)
            default: return nil
            }
        }
        return StrapWorkoutModeExtras(ranWithWorkoutMode: int(workoutModeKey) == 1,
                                      swings: int(swingCountKey).flatMap { $0 >= 0 ? $0 : nil },
                                      strapKilocalories: int(activeEnergyKey).flatMap { $0 >= 0 ? $0 : nil })
    }
}
