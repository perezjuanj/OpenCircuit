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

    /// Fewest PRIOR days before the trimmed mean actually trims. The trim floors at one value off
    /// each end (`max(1, count/10)`), so on a thin window it discards a disproportionate slice: at
    /// n=3 it would keep only the median day, at n=4 only the middle two — the baseline collapses
    /// toward a single day instead of averaging the window. At n=5 the same 1-in/1-out trim still
    /// keeps the middle three (60% of the window), enough to resist one outlier while staying
    /// representative. So below 5 prior days we skip the trim and take the plain mean of every day
    /// (the ±`maxRestingEnergyAdjustment` clamp still bounds any single bad day); at/above 5 the
    /// trim earns its outlier resistance.
    public static let minTrimmedBaselineDays = 5

    /// Personal resting-HR baseline (mean bpm) from a person's PRIOR daily resting-HR values.
    /// `prior` is chronological (oldest→newest); returns nil below `minRestingBaselineDays` so the
    /// caller degrades to the static BMR rather than adjust off a baseline we can't yet trust.
    ///
    /// With `< minTrimmedBaselineDays` prior days the window is too thin to trim without collapsing
    /// toward a single day (see `minTrimmedBaselineDays`), so we take the plain mean of all values.
    /// At/above that threshold we use a 10% trimmed mean (drops the top and bottom 10%, at least one
    /// value off each end) to resist a single outlier day from skewing the window — the ±20% clamp
    /// limits per-hour damage, but a robust baseline prevents systematic drift from one sick or
    /// mis-measured day.
    public static func restingBaselineBpm(
        prior: [Double],
        minDays: Int = minRestingBaselineDays
    ) -> Double? {
        guard prior.count >= minDays, minDays > 0 else { return nil }
        let sorted = prior.sorted()
        // Thin window: plain mean of every prior day — trimming here would collapse the baseline
        // toward a single median day rather than average the window.
        guard sorted.count >= minTrimmedBaselineDays else {
            return sorted.reduce(0, +) / Double(sorted.count)
        }
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

    /// One internally-consistent daily activity estimate for the dashboard rings, readiness,
    /// trends, and Health mirroring. The previous implementation used two incompatible HR rules:
    /// exercise minutes started at 50% of max HR while active calories started at 50% of HEART-RATE
    /// RESERVE. A moderate session could therefore earn hours of exercise time but zero HR calories,
    /// leaving the calorie ring on its steps-only fallback.
    ///
    /// This estimate deliberately reuses `ExerciseMinutes` as the qualifying-duration source and
    /// applies the same Keytel HR model used by a recorded workout to that duration. Until the
    /// calibrated activity-seconds payload is decoded, `elevatedMinutes` is explicitly labeled as
    /// an elevated-HR estimate in the UI rather than presented as detected workout duration.
    public struct DailyEstimate: Equatable, Sendable {
        public let activeKcal: Double
        public let elevatedMinutes: Double
        /// Chronological, non-overlapping time attribution of `activeKcal`. Invariant:
        /// `buckets.map(\.activeKcal).reduce(0,+) == activeKcal` whenever attribution ran.
        /// EMPTY when the inputs could not support it — see `dailyEstimate`'s degrade rule.
        public let buckets: [EnergyBucket]

        public init(activeKcal: Double, elevatedMinutes: Double, buckets: [EnergyBucket] = []) {
            self.activeKcal = activeKcal
            self.elevatedMinutes = elevatedMinutes
            self.buckets = buckets
        }
    }

    /// Width of one attribution bucket. This is PLACEMENT metadata only: the day total is
    /// bucket-width-invariant because overlap between the HR and step channels is netted on the
    /// real overlap, not on a grid cell. Changing this changes which Apple Health hour bar a
    /// sample lands in, never how many kcal the day holds. 15 min divides an hour exactly, so a
    /// bucket never straddles two bars.
    public static let energyBucketSeconds: TimeInterval = 15 * 60

    /// Defensive upper bound on how far past `dayStart` attribution will place energy. Wider than
    /// any real calendar day (25 h at a DST fall-back) so it never truncates legitimate data;
    /// steps beyond it are recovered by the residual reconciliation in `attributedDailyEstimate`.
    static let maxAttributionSeconds: TimeInterval = 26 * 3600

    /// One slice of the day with the active energy attributed to it, split by source.
    public struct EnergyBucket: Equatable, Sendable {
        public let start: Date
        public let end: Date
        /// Keytel energy of the elevated-HR time inside this bucket.
        public let hrKcal: Double
        /// Walking energy credited here — already netted against `hrKcal` where the two overlap,
        /// so a walk that raised heart rate is paid once, by whichever channel valued it higher.
        public let stepKcal: Double
        public let elevatedMinutes: Double

        public init(start: Date, end: Date, hrKcal: Double, stepKcal: Double,
                    elevatedMinutes: Double) {
            self.start = start
            self.end = end
            self.hrKcal = hrKcal
            self.stepKcal = stepKcal
            self.elevatedMinutes = elevatedMinutes
        }

        public var activeKcal: Double { hrKcal + stepKcal }
    }

    /// One internally-consistent daily activity estimate (see the type docs above).
    ///
    /// Pass `stepWindows` + `dayStart` to get TIME-ATTRIBUTED energy; omit them and the result is
    /// byte-identical to the pre-attribution behaviour. The degrade is deliberate and load-bearing:
    /// a call site that has not been updated, or a day whose step rows predate per-snapshot step
    /// history, produces exactly the old number with no buckets rather than a silently different
    /// one. (Trends DOES pass both for every day in its lookback, so historical days there are
    /// re-priced and read higher than the samples already sitting in Apple Health for those days —
    /// deliberate, and documented at that call site. Only days with no step rows stay put.)
    ///
    /// WHY attribution exists: the legacy estimate is `max(hrKcal, stepKcal)` over two WHOLE-DAY
    /// snapshots. Once the last bout above the elevated-HR threshold ends, `elevatedMinutes` stops
    /// growing, so `hrKcal` is exactly constant — and the step channel is worth only
    /// `0.000124 x weightKg` kcal/step, so it needs ~27-40k steps to overtake a 300 kcal `hrKcal`
    /// and the `max()` never switches. A tester's whole afternoon (a 25-minute, 2,100-step walk
    /// home at ~90 bpm) was therefore worth 0.000 kcal, `HealthKitWriter.flushActiveCalories`
    /// computed a zero delta on every flush for 5.5 hours, and Apple Health showed a hard stop at
    /// 2pm (2026-07-28). Attribution pays each channel where it actually earned, so a sedentary-HR
    /// afternoon of walking still accrues.
    public static func dailyEstimate(
        hrSamples: [HRSample],
        steps: Int,
        profile: UserProfile,
        sleepWindow: DateInterval? = nil,
        stepWindows: [StepWindow] = [],
        dayStart: Date? = nil,
        bucketSeconds: TimeInterval = energyBucketSeconds
    ) -> DailyEstimate {
        if let dayStart, bucketSeconds > 0, steps == 0 || !stepWindows.isEmpty,
           let attributed = attributedDailyEstimate(hrSamples: hrSamples,
                                                    steps: steps,
                                                    profile: profile,
                                                    sleepWindow: sleepWindow,
                                                    stepWindows: stepWindows,
                                                    dayStart: dayStart,
                                                    bucketSeconds: bucketSeconds) {
            return attributed
        }
        return legacyDailyEstimate(hrSamples: hrSamples, steps: steps,
                                   profile: profile, sleepWindow: sleepWindow)
    }

    /// The pre-attribution estimate, kept verbatim as the degrade path (and as the thing the
    /// attribution tests assert they still reproduce for steps-only / HR-only days).
    public static func legacyDailyEstimate(
        hrSamples: [HRSample],
        steps: Int,
        profile: UserProfile,
        sleepWindow: DateInterval? = nil
    ) -> DailyEstimate {
        let maxHR = max(220 - profile.age, 1)
        let elevatedMinutes = ExerciseMinutes.estimate(
            hrSamples: hrSamples,
            maxHR: maxHR,
            sleepWindow: sleepWindow
        )

        // MUST be the same threshold `elevatedPieces` just used inside `estimate` above — it is
        // derived from these same samples, so re-deriving it here reproduces it exactly. Calling
        // the bare `threshold(maxHR:)` would price a DIFFERENT qualifying set than the minutes it
        // divides by, silently mixing two models in one kcal number.
        let threshold = ExerciseMinutes.threshold(
            maxHR: maxHR, restingHR: ExerciseMinutes.restingBaseline(hrSamples))
        let qualifyingBPM = hrSamples.compactMap { sample -> Int? in
            guard sample.bpm >= threshold,
                  sleepWindow.map({ !$0.contains(sample.start) }) ?? true else { return nil }
            return sample.bpm
        }
        let hrKcal: Double
        if elevatedMinutes > 0, !qualifyingBPM.isEmpty {
            let average = Int((Double(qualifyingBPM.reduce(0, +))
                               / Double(qualifyingBPM.count)).rounded())
            hrKcal = workoutActiveKcal(
                avgHR: average,
                durationSeconds: elevatedMinutes * 60,
                profile: profile
            )
        } else {
            hrKcal = 0
        }

        let stepKcal = activeKcalFromSteps(steps: steps, profile: profile)
        return DailyEstimate(
            activeKcal: max(hrKcal, stepKcal),
            elevatedMinutes: elevatedMinutes
        )
    }

    /// Time-attributed estimate. Returns nil when the inputs cannot be attributed at all, so the
    /// caller falls back to `legacyDailyEstimate` rather than reporting a partial day.
    ///
    /// Composition, per bucket:
    ///   hrKcal   = Keytel priced on EACH elevated piece's own bpm (never a whole-day average, so
    ///              a later bout cannot re-price an earlier one and an isolated spot read cannot
    ///              dilute either).
    ///   stepKcal = walking energy where the wearer was NOT in elevated HR, plus, where they
    ///              overlap, `max(0, stepKcal - hrKcal)` — the excess the HR channel did not
    ///              already price. That is what keeps a walk from being paid twice while still
    ///              crediting a walk the 50%-of-max-HR gate ignores.
    ///
    /// Everything here is linear in duration (Keytel at fixed bpm, and metres→kcal), so splitting
    /// a span across bucket edges is exactly additive: the grid cannot change the day total.
    static func attributedDailyEstimate(
        hrSamples: [HRSample],
        steps: Int,
        profile: UserProfile,
        sleepWindow: DateInterval?,
        stepWindows: [StepWindow],
        dayStart: Date,
        bucketSeconds: TimeInterval
    ) -> DailyEstimate? {
        let maxHR = max(220 - profile.age, 1)
        let pieces = ExerciseMinutes.elevatedPieces(hrSamples: hrSamples,
                                                    maxHR: maxHR,
                                                    sleepWindow: sleepWindow)
        let elevatedMinutes = pieces.reduce(0.0) { $0 + $1.seconds } / 60.0
        let dayEnd = dayStart.addingTimeInterval(maxAttributionSeconds)

        func ordinal(_ t: Date) -> Int {
            Int((t.timeIntervalSince(dayStart) / bucketSeconds).rounded(.down))
        }
        func bucketStart(_ o: Int) -> Date {
            dayStart.addingTimeInterval(Double(o) * bucketSeconds)
        }

        /// Spread `total` across the buckets `[from, to)` covers, in proportion to the time spent
        /// in each. A zero-length span lands wholly in the bucket containing it.
        func spread(from: Date, to: Date, total: Double, into dict: inout [Int: Double]) {
            guard total != 0 else { return }
            let lo = Swift.max(from, dayStart)
            let hi = Swift.min(to, dayEnd)
            guard hi > lo else {
                if from >= dayStart, from < dayEnd { dict[ordinal(from), default: 0] += total }
                return
            }
            let span = hi.timeIntervalSince(lo)
            var cursor = lo
            var o = ordinal(lo)
            while cursor < hi {
                let edge = Swift.min(bucketStart(o + 1), hi)
                dict[o, default: 0] += total * (edge.timeIntervalSince(cursor) / span)
                cursor = edge
                o += 1
            }
        }

        var hrByOrdinal: [Int: Double] = [:]
        var minutesByOrdinal: [Int: Double] = [:]
        var stepByOrdinal: [Int: Double] = [:]

        for piece in pieces {
            let kcal = workoutActiveKcal(avgHR: piece.bpm,
                                         durationSeconds: piece.seconds,
                                         profile: profile)
            spread(from: piece.start, to: piece.end, total: kcal, into: &hrByOrdinal)
            spread(from: piece.start, to: piece.end, total: piece.seconds / 60.0,
                   into: &minutesByOrdinal)
        }

        // Steps, netted against the elevated time they overlap. Prorated on METRES, never on the
        // Int step count — splitting an Int at a boundary truncates and quietly loses steps.
        var creditedSteps = 0
        for window in stepWindows where window.delta > 0 {
            let lo = Swift.max(window.start, dayStart)
            let hi = Swift.min(window.end, dayEnd)
            guard window.start < dayEnd, window.end >= dayStart else { continue }
            let metres = Double(window.delta) * DistanceEstimate.metersPerStep

            guard hi > lo else {  // point snapshot: nothing to net against, credit it whole
                creditedSteps += window.delta
                spread(from: lo, to: lo,
                       total: activeKcalFromDistance(meters: metres, profile: profile),
                       into: &stepByOrdinal)
                continue
            }

            // Prorate against the window's FULL span, not the clipped one: a snapshot that opened
            // before midnight earned only the share of its steps that fell inside the day, and
            // measuring the fraction against the clipped span would credit all of them to today.
            let fullSpan = window.end.timeIntervalSince(window.start)
            let duration = fullSpan > 0 ? fullSpan : hi.timeIntervalSince(lo)
            creditedSteps += Int((Double(window.delta)
                                  * (hi.timeIntervalSince(lo) / duration)).rounded())
            var cursor = lo
            var idx = 0
            while cursor < hi {
                while idx < pieces.count, pieces[idx].end <= cursor { idx += 1 }
                let piece = idx < pieces.count ? pieces[idx] : nil
                let segmentEnd: Date
                let overlapped: ExerciseMinutes.ElevatedPiece?
                if let piece, piece.start <= cursor {
                    segmentEnd = Swift.min(piece.end, hi)
                    overlapped = piece
                } else if let piece, piece.start < hi {
                    segmentEnd = piece.start
                    overlapped = nil
                } else {
                    segmentEnd = hi
                    overlapped = nil
                }
                guard segmentEnd > cursor else { break }

                let seconds = segmentEnd.timeIntervalSince(cursor)
                let segmentKcal = activeKcalFromDistance(meters: metres * (seconds / duration),
                                                         profile: profile)
                let credit: Double
                if let overlapped {
                    let alreadyPriced = workoutActiveKcal(avgHR: overlapped.bpm,
                                                          durationSeconds: seconds,
                                                          profile: profile)
                    credit = Swift.max(0, segmentKcal - alreadyPriced)
                } else {
                    credit = segmentKcal
                }
                spread(from: cursor, to: segmentEnd, total: credit, into: &stepByOrdinal)
                cursor = segmentEnd
            }
        }

        // Steps the daily counter knows about but no snapshot placed in time (a snapshot whose
        // window opened before midnight, or a row written before per-snapshot step history). Credit
        // them at the earliest bucket that already holds activity rather than at midnight — putting
        // them at 00:00 is the very mis-placement this attribution exists to end.
        let residual = steps - creditedSteps
        if residual > 0 {
            let kcal = activeKcalFromDistance(
                meters: Double(residual) * DistanceEstimate.metersPerStep, profile: profile)
            guard let earliest = [stepByOrdinal.keys.min(), hrByOrdinal.keys.min()]
                .compactMap({ $0 }).min() else { return nil }
            stepByOrdinal[earliest, default: 0] += kcal
        }

        let ordinals = Set(hrByOrdinal.keys).union(stepByOrdinal.keys).sorted()
        guard !ordinals.isEmpty else { return nil }
        let buckets = ordinals.map { o in
            EnergyBucket(start: bucketStart(o),
                         end: bucketStart(o + 1),
                         hrKcal: hrByOrdinal[o] ?? 0,
                         stepKcal: stepByOrdinal[o] ?? 0,
                         elevatedMinutes: minutesByOrdinal[o] ?? 0)
        }
        return DailyEstimate(activeKcal: buckets.reduce(0) { $0 + $1.activeKcal },
                             elevatedMinutes: elevatedMinutes,
                             buckets: buckets)
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
