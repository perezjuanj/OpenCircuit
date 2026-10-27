import Foundation
import OpenCircuitKit

/// Which profile inputs the body-derived numbers (BMR, est. max HR) still rest on as placeholders.
///
/// The views read these through `@AppStorage` with a default (age 35, 70 kg, 170 cm, male). That
/// default is only a placeholder until the Profile screen writes the key, so "is this a default"
/// is the Profile age row's own predicate: `defaults.object(forKey:) == nil` (`ageRowValue` in
/// `UserProfileSettingsView`). Display-only: nothing here reads Health or writes a key.
struct ProfileDefaultsStatus: Equatable {
    var age: Bool
    var weight: Bool
    var height: Bool
    var sex: Bool

    static let ageKey = "userProfile.age"
    static let heightKey = "userProfile.heightCm"
    static let sexKey = "userProfile.sex"

    static func current(defaults: UserDefaults = .standard) -> ProfileDefaultsStatus {
        // Weight also counts as set when a newer Apple Health body mass feeds the math (#284).
        let weightFromHealth = WeightResolver.resolve(defaults: defaults).source == .appleHealth
        return ProfileDefaultsStatus(
            age: isUnset(Self.ageKey, defaults),
            weight: isUnset(WeightResolver.Keys.manualKg, defaults) && !weightFromHealth,
            height: isUnset(Self.heightKey, defaults),
            sex: isUnset(Self.sexKey, defaults))
    }

    /// The Profile screen's "Not set" predicate, in one place.
    static func isUnset(_ key: String, _ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil
    }

    var anyDefault: Bool { age || weight || height || sex }

    /// The BMR inputs that are defaults, in the order the Profile screen lists them.
    var defaultBMRInputs: [String] {
        [(age, "age"), (weight, "weight"), (height, "height"), (sex, "sex")].filter(\.0).map(\.1)
    }
}

/// The Calories card's reference line, as text. Same as before when the profile is set.
enum CaloriesReferenceLine {
    static func text(bmr: Int, maxHR: Int, age: Int, status: ProfileDefaultsStatus,
                     manualMaxHR: Int? = nil) -> String {
        var bmrPart = "BMR \(bmr) kcal/day"
        if status.anyDefault {
            bmrPart += " (default \(list(status.defaultBMRInputs)))"
        }
        if let manualMaxHR, MaxHeartRate.isValidManual(manualMaxHR) {
            return "\(bmrPart) · max HR \(manualMaxHR) bpm (set by you)"
        }
        let formula = status.age ? "220 − default age \(age)" : "220 − age"
        return "\(bmrPart) · est. max HR \(maxHR) bpm (\(formula))"
    }

    /// "age", "age and weight", "age, weight and sex".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
