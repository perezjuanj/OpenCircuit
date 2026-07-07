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

    /// Active kcal estimate from a STEP count, via the decoded-step distance estimate
    /// (`DistanceEstimate`, RingConn's own fixed per-step constant — PROTOCOL.md §5.3.1).
    /// ESTIMATE — the same derived-not-decoded basis as distance (#81) and exercise
    /// minutes (#82). Zero for non-positive steps.
    public static func activeKcalFromSteps(steps: Int, profile: UserProfile) -> Double {
        activeKcalFromDistance(meters: DistanceEstimate.meters(steps: steps),
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

    /// Active-energy estimate for a WORKOUT via the Keytel et al. (2005) HR→energy regression — the
    /// standard heart-rate calorie model. Uses the AVERAGE HR over the workout's true duration:
    /// Keytel is linear in HR, so avg-HR-over-duration equals the per-sample integral for equal
    /// intervals, and it is immune to how sparsely the ring streams HR (the `0x4e` sport frame lands
    /// only ~every 10 s, so a 5-minute session yields ~30 readings).
    ///
    /// Chosen over Edwards-TRIMP for CALORIES because TRIMP assigns zero weight below 50% heart-rate
    /// reserve — an easy/moderate session (e.g. steady cycling at ~100 bpm) would read 0 kcal despite
    /// real energy spent. (Edwards-TRIMP is still the right model for training STRAIN; see `Strain`.)
    /// ESTIMATE — not a ring sensor reading; labeled as such at every display/write site.
    ///
    /// Keytel 2005 energy expenditure (kJ·min⁻¹), W = body mass kg, A = age years:
    ///   men:   −55.0969 + 0.6309·HR + 0.1988·W + 0.2017·A
    ///   women: −20.4022 + 0.4472·HR − 0.1263·W + 0.0740·A
    /// kcal = kJ / 4.184. The per-minute rate is clamped to ≥ 0 (a very low HR yields a negative raw
    /// rate). Returns 0 for a non-positive HR or duration.
    public static func workoutActiveKcal(avgHR: Int, durationSeconds: Double, profile: UserProfile) -> Double {
        guard avgHR > 0, durationSeconds > 0 else { return 0 }
        let hr = Double(avgHR)
        let w = profile.weightKg
        let a = Double(profile.age)
        let kJPerMin: Double
        switch profile.sex {
        case .male:   kJPerMin = -55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * a
        case .female: kJPerMin = -20.4022 + 0.4472 * hr - 0.1263 * w + 0.0740 * a
        }
        let kcalPerMin = max(0, kJPerMin / 4.184)
        return kcalPerMin * (durationSeconds / 60.0)
    }
}
