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

    // MARK: Resting-HR–adjusted basal energy (#dynamic-resting-calories)
    //
    // Mifflin-St Jeor gives one number for a fixed profile — the same basal (passive) energy
    // every hour of every day, regardless of how the person actually is. Resting energy
    // expenditure tracks autonomic tone, and so does resting heart rate: an acutely elevated
    // RHR (illness, poor recovery, stress, dehydration, stimulants) rides with a raised RMR.
    // So we NUDGE the formula BMR by how far the day's MEASURED resting HR sits from the
    // person's own recent baseline, instead of shipping an identical value daily. Still an
    // ESTIMATE — labeled as such at every write site — but one that moves with real data.

    /// Fractional change in resting energy per bpm of resting-HR deviation from baseline.
    /// Order-of-magnitude anchor: the fever relationship (~10–13% RMR rise per +1 °C, and
    /// ~8–10 bpm HR rise per +1 °C) ⇒ ≈1% RMR per bpm. We use that as a defensible, deliberately
    /// conservative slope for autonomic-driven RMR shifts generally (stress, fitness, dehydration,
    /// stimulants — not only fever), NOT a claim of clinical precision (hence the ESTIMATE label
    /// and the cap below).
    public static let restingEnergyFractionPerBpm = 0.01

    /// Hard cap on how far measured RHR may move basal energy off the formula value, either way.
    /// Bounds a garbage/outlier RHR (and honest but extreme physiology) to ±20% so a bad reading
    /// can never produce an absurd basal-energy sample in Apple Health.
    public static let maxRestingEnergyAdjustment = 0.20

    /// Fewest PRIOR daily RHR readings needed before we trust a personal baseline. Below this we
    /// don't adjust at all (new user / too little history) and callers fall back to static BMR —
    /// never to zero. A plain baseline mean needs less history than SD-based anomaly detection,
    /// so this sits below `VitalsBaseline`'s 7-day minimum on purpose.
    public static let minRestingBaselineDays = 3

    /// Personal resting-HR baseline (trimmed mean bpm) from a person's PRIOR daily resting-HR
    /// values. `prior` is chronological (oldest→newest); returns nil below `minRestingBaselineDays`
    /// so the caller degrades to the static BMR rather than adjust off a baseline we can't yet
    /// trust. Uses a 10% trimmed mean (drops the top and bottom 10% of values) to resist single
    /// outlier days from skewing the window — the ±20% clamp limits per-hour damage, but a robust
    /// baseline prevents systematic drift from a single sick or mis-measured day.
    public static func restingBaselineBpm(
        prior: [Double],
        minDays: Int = minRestingBaselineDays
    ) -> Double? {
        guard prior.count >= minDays, minDays > 0 else { return nil }
        let sorted = prior.sorted()
        let trimCount = max(1, sorted.count / 10)
        let trimmed = sorted.count > 2 * trimCount
            ? Array(sorted[trimCount ..< (sorted.count - trimCount)])
            : sorted
        return trimmed.reduce(0, +) / Double(trimmed.count)
    }

    /// Multiplier on the static Mifflin-St Jeor BMR from the day's MEASURED resting HR vs the
    /// personal baseline. 1.0 == no change. Returns 1.0 when either input is missing (so the
    /// caller degrades to static BMR), and is clamped to ±`maxRestingEnergyAdjustment`. ESTIMATE.
    public static func restingEnergyScale(restingHR: Double?, baselineRestingHR: Double?) -> Double {
        guard let rhr = restingHR, let base = baselineRestingHR, base > 0 else { return 1.0 }
        let raw = 1.0 + restingEnergyFractionPerBpm * (rhr - base)
        let lo = 1.0 - maxRestingEnergyAdjustment
        let hi = 1.0 + maxRestingEnergyAdjustment
        return Swift.min(hi, Swift.max(lo, raw))
    }

    /// Dynamic basal (passive) energy for ONE hour: the per-hour Mifflin-St Jeor BMR scaled by the
    /// resting-HR deviation from the personal baseline. Falls back to the exact static per-hour BMR
    /// when RHR or baseline are unavailable (new user, no nights of data yet). ESTIMATE — labeled at
    /// the HealthKit write site. Pure math — unit-testable on macOS.
    public static func basalKcalPerHour(
        profile: UserProfile,
        restingHR: Double? = nil,
        baselineRestingHR: Double? = nil
    ) -> Double {
        bmrKcalPerHour(profile: profile)
            * restingEnergyScale(restingHR: restingHR, baselineRestingHR: baselineRestingHR)
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
