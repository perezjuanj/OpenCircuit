import Foundation

public struct HRSample: Equatable, Codable, Sendable {
    public let bpm: Int
    public let start: Date
    public let end: Date

    public init(bpm: Int, start: Date, end: Date? = nil) {
        self.bpm = bpm
        self.start = start
        self.end = end ?? start
    }
}

public enum Calories {
    public static let trimpKcalFactor = 5.0
    public static let defaultRestingHR = 60

    /// Net (above-resting) walking economy: ≈ 0.5 kcal per kg of body mass per km walked
    /// (gross ≈ 1.0 kcal·kg⁻¹·km⁻¹ minus the resting component, the standard pedometer constant).
    /// Used for the step/distance-derived active-energy ESTIMATE that lets a day with walking —
    /// or a workout with no locked HR — still report honest, clearly-labeled active calories
    /// instead of 0. NOT a sensor reading; labeled as an estimate at every write/display site.
    public static let walkKcalPerKgPerKm = 0.5

    /// Active kcal estimate from a walked/ran DISTANCE (meters) and body mass. ESTIMATE.
    /// Zero for non-positive distance. Pure math — unit-testable on macOS.
    public static func activeKcalFromDistance(meters: Double, profile: UserProfile) -> Double {
        guard meters > 0 else { return 0 }
        return (meters / 1000.0) * profile.weightKg * walkKcalPerKgPerKm
    }

    /// Active kcal estimate from a STEP count, via the height-based stride distance estimate
    /// (`DistanceEstimate`). ESTIMATE — the same derived-not-decoded basis as distance (#81) and
    /// exercise minutes (#82). Zero for non-positive steps.
    public static func activeKcalFromSteps(steps: Int, profile: UserProfile) -> Double {
        activeKcalFromDistance(meters: DistanceEstimate.meters(steps: steps, profile: profile),
                               profile: profile)
    }

    public static func bmrKcalPerDay(profile: UserProfile) -> Double {
        let base = (10.0 * profile.weightKg)
            + (6.25 * profile.heightCm)
            - (5.0 * Double(profile.age))
        switch profile.sex {
        case .male: return base + 5.0
        case .female: return base - 161.0
        }
    }

    public static func bmrKcalPerHour(profile: UserProfile) -> Double {
        bmrKcalPerDay(profile: profile) / 24.0
    }

    public static func activeKcal(hrSamples: [HRSample], maxHR: Int) -> Double {
        guard let trimp = Strain.edwardsTRIMP(
            hrSamples: hrSamples,
            maxHR: maxHR,
            restingHR: defaultRestingHR
        ) else {
            return 0.0
        }
        return trimp * trimpKcalFactor
    }
}
