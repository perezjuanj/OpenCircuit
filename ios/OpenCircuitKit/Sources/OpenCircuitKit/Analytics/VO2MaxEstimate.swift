// VO2MaxEstimate.swift — a submaximal VO₂ max ESTIMATE from one outdoor run (#232).
//
// METHOD (docs/TRAINING_METRICS.md §2 has the citations and every threshold's origin):
//   1. Oxygen cost of running at the run's steady speed, from the ACSM metabolic equation:
//          VO₂ = 0.2 × S + 0.9 × S × G + 3.5        (mL·kg⁻¹·min⁻¹; S in m/min, G as a fraction)
//      American College of Sports Medicine, ACSM's Guidelines for Exercise Testing and
//      Prescription (metabolic equations, running). Grade only when the GPS elevation is reliable;
//      otherwise the segment is treated as flat.
//   2. Extrapolation to the maximum through %HRR ≈ %VO₂R (Swain DP, Leutholtz BC. "Heart rate
//      reserve is equivalent to %VO₂ reserve, not to %VO₂max." Med Sci Sports Exerc 1997;
//      29(3):410–414):
//          (HR − HRrest) / (HRmax − HRrest) = (VO₂ − 3.5) / (VO₂max − 3.5)
//      ⇒  VO₂max = 3.5 + (VO₂ − 3.5) × (HRmax − HRrest) / (HR − HRrest)
//   3. HRmax = the higher of Tanaka's age formula (208 − 0.7 × age; Tanaka H, Monahan KD, Seals DR.
//      "Age-predicted maximal heart rate revisited." J Am Coll Cardiol 2001;37(1):153–156) and the
//      highest 1-minute mean heart rate seen in this run. HRrest = the app's daily resting HR.
//
// Every refusal is a `SkipReason` the UI states in words. No input is ever defaulted: an unset age
// or a missing resting HR skips the estimate instead of borrowing a placeholder.
//
// Device-agnostic and pure: heart-rate samples, cumulative GPS distance and the profile in, a
// number or a reason out. No CoreLocation, no HealthKit.

import Foundation

public enum VO2MaxEstimate {

    // MARK: Published formulas

    /// Resting oxygen uptake, 1 MET (mL·kg⁻¹·min⁻¹). The 3.5 in both the ACSM and Swain equations.
    public static let restingVO2 = 3.5

    /// ACSM running equation. `speed` in m/min, `grade` as a fraction (0.05 = 5 %).
    public static func acsmRunningVO2(speedMetersPerMinute speed: Double, grade: Double) -> Double {
        let horizontal = 0.2 * speed
        let vertical = 0.9 * speed * grade
        return horizontal + vertical + restingVO2
    }

    /// Tanaka 2001 age-predicted maximal heart rate.
    public static func tanakaMaxHR(age: Int) -> Double {
        208 - 0.7 * Double(age)
    }

    /// Swain & Leutholtz 1997 %HRR ≈ %VO₂R, solved for VO₂max. nil when the heart rate isn't above
    /// resting or max isn't above resting (the ratio is undefined).
    public static func extrapolate(vo2: Double, heartRate: Double,
                                   restingHR: Double, maxHR: Double) -> Double? {
        let reserve = maxHR - restingHR
        let working = heartRate - restingHR
        guard reserve > 0, working > 0 else { return nil }
        return restingVO2 + (vo2 - restingVO2) * reserve / working
    }

    // MARK: Inputs

    /// One GPS fix reduced to what the estimate needs. `distance` is CUMULATIVE metres from the
    /// run's first accepted fix (the same running sum the workout shows as its distance).
    public struct RoutePoint: Equatable, Sendable {
        public let time: Date
        public let distance: Double
        /// Altitude in metres, nil when the fix had none.
        public let altitude: Double?
        /// CoreLocation's vertical accuracy in metres; ≤ 0 or nil means "no valid altitude".
        public let verticalAccuracy: Double?

        public init(time: Date, distance: Double, altitude: Double? = nil,
                    verticalAccuracy: Double? = nil) {
            self.time = time
            self.distance = distance
            self.altitude = altitude
            self.verticalAccuracy = verticalAccuracy
        }
    }

    public struct Input: Sendable {
        public let sport: WorkoutSportType
        public let start: Date
        public let end: Date
        public let heartRate: [HRSample]
        public let route: [RoutePoint]
        /// The user's age, nil when they never set it (the app's 35 placeholder is NOT an input).
        public let age: Int?
        /// The daily resting HR (bpm), nil when there isn't enough history.
        public let restingHR: Double?

        public init(sport: WorkoutSportType, start: Date, end: Date, heartRate: [HRSample],
                    route: [RoutePoint], age: Int?, restingHR: Double?) {
            self.sport = sport
            self.start = start
            self.end = end
            self.heartRate = heartRate
            self.route = route
            self.age = age
            self.restingHR = restingHR
        }
    }

    // MARK: Rules (each one's origin is in docs/TRAINING_METRICS.md §2.3)

    /// Only runs of at least this long qualify (the issue's 10-minute rule).
    public static let minimumDuration: TimeInterval = 10 * 60
    /// Minutes skipped at the start, while heart rate is still climbing to steady state.
    public static let warmUpExcluded: TimeInterval = 4 * 60
    /// Length of the steady segment, in 1-minute bins.
    public static let segmentMinutes = 5
    /// A 1-minute bin needs at least this many heart-rate readings to count.
    public static let minReadingsPerMinute = 2
    /// A bin's speed needs a GPS fix within this many seconds of each of its edges.
    public static let maxFixGap: TimeInterval = 15
    /// Steady = speed varies by at most this (coefficient of variation across the bins) …
    public static let maxSpeedVariation = 0.10
    /// … and heart rate (1-minute means) spans at most this many bpm.
    public static let maxHeartRateSpread = 10.0
    /// ACSM running equation's speed range: from 80 m/min ("truly jogging") upward; 400 m/min
    /// (24 km/h) is the GPS-plausibility ceiling.
    public static let speedRange: ClosedRange<Double> = 80 ... 400
    /// Elevation is trusted only when every fix in the segment has a vertical accuracy this good.
    public static let maxVerticalAccuracy = 10.0
    /// Grades the ACSM running equation is used for. Below −1 % is downhill (the equation is for
    /// level and uphill running); between −1 % and 0 is read as level (GPS altitude noise).
    public static let gradeRange: ClosedRange<Double> = -0.01 ... 0.15
    /// Below 50 % of heart-rate reserve the extrapolation multiplies GPS and heart-rate error by
    /// more than 2×, so the run is too easy to extrapolate from.
    public static let minimumReserveFraction = 0.50
    /// Results outside this range are not physiology, they are a bad input.
    public static let plausibleRange: ClosedRange<Double> = 15 ... 90

    // MARK: Output

    public enum SkipReason: Equatable, Sendable {
        case notAnOutdoorRun
        case tooShort
        case noGPS
        case noHeartRate
        case noAge
        case noRestingHR
        case noSteadySegment
        case intensityTooLow
        case implausible
        /// Indoor (decision 84g): the treadmill's distance wasn't entered, so steps can't be a speed.
        case noTypedDistance
        /// Indoor (decision 84g): no steps were counted during the run.
        case noStepData
        /// Indoor (decision 84g): the indoor estimate is only for an indoor run.
        case notAnIndoorRun

        /// What the workout screen says, after "No VO₂ max estimate: ".
        public var explanation: String {
            switch self {
            case .notAnOutdoorRun: return "it is only estimated for outdoor runs."
            case .tooShort: return "the run was shorter than 10 minutes."
            case .noGPS: return "there was no GPS route for this run."
            case .noHeartRate: return "too few heart-rate readings during the run."
            case .noAge: return "set your age in Profile so a maximum heart rate can be estimated."
            case .noRestingHR: return "there isn't enough heart-rate history yet for a resting heart rate (3 days needed)."
            case .noSteadySegment: return "the run had no steady 5-minute stretch (even pace, heart rate and GPS, level or uphill)."
            case .intensityTooLow: return "the steady stretch was too easy (under half your heart-rate reserve) to extrapolate from."
            case .implausible: return "the result fell outside a plausible range, so it was discarded."
            case .noTypedDistance: return "enter the treadmill's distance above, so your steps can be turned into a speed."
            case .noStepData: return "no steps were counted during this run."
            case .notAnIndoorRun: return "it is only estimated for indoor runs."
            }
        }
    }

    public enum MaxHRSource: Equatable, Sendable {
        case ageFormula
        case observed
    }

    public struct Estimate: Equatable, Sendable {
        /// mL·kg⁻¹·min⁻¹.
        public let vo2Max: Double
        public let segmentStart: Date
        public let segmentEnd: Date
        /// Mean speed over the segment, m/min.
        public let speed: Double
        /// Grade used in the ACSM equation (0 when elevation wasn't reliable).
        public let grade: Double
        /// True when `grade` came from GPS elevation, false when the segment was assumed flat.
        public let gradeFromElevation: Bool
        /// Oxygen cost of the segment from the ACSM equation.
        public let segmentVO2: Double
        /// Mean heart rate over the segment.
        public let heartRate: Double
        public let restingHR: Double
        public let maxHR: Double
        public let maxHRSource: MaxHRSource
        /// Where `speed` came from: the GPS route (#232), or treadmill distance + steps (decision 84g).
        public var speedSource: SpeedSource = .gpsRoute
    }

    public enum SpeedSource: Equatable, Sendable {
        case gpsRoute
        case treadmillSteps
    }

    public enum Outcome: Equatable, Sendable {
        case estimate(Estimate)
        case skipped(SkipReason)
    }

    // MARK: Estimate

    public static func estimate(_ input: Input) -> Outcome {
        guard input.sport == .runningOutdoor else { return .skipped(.notAnOutdoorRun) }
        guard input.end.timeIntervalSince(input.start) >= minimumDuration else {
            return .skipped(.tooShort)
        }
        let route = input.route.sorted { $0.time < $1.time }
        guard route.count >= 2, let lastDistance = route.last?.distance, lastDistance > 0 else {
            return .skipped(.noGPS)
        }
        guard input.heartRate.count >= minReadingsPerMinute * segmentMinutes else {
            return .skipped(.noHeartRate)
        }
        guard let age = input.age else { return .skipped(.noAge) }
        guard let restingHR = input.restingHR, restingHR > 0 else { return .skipped(.noRestingHR) }

        let bins = minuteBins(input, route: route)
        guard let segment = steadiestSegment(bins: bins, route: route) else {
            return .skipped(.noSteadySegment)
        }

        let observedMax = bins.compactMap(\.heartRate).max()
        let tanaka = tanakaMaxHR(age: age)
        let maxHR: Double
        let source: MaxHRSource
        if let observedMax, observedMax > tanaka {
            maxHR = observedMax
            source = .observed
        } else {
            maxHR = tanaka
            source = .ageFormula
        }

        let reserve = maxHR - restingHR
        guard reserve > 0, (segment.heartRate - restingHR) / reserve >= minimumReserveFraction else {
            return .skipped(.intensityTooLow)
        }
        let cost = acsmRunningVO2(speedMetersPerMinute: segment.speed, grade: segment.grade)
        guard let vo2Max = extrapolate(vo2: cost, heartRate: segment.heartRate,
                                       restingHR: restingHR, maxHR: maxHR),
              plausibleRange.contains(vo2Max) else {
            return .skipped(.implausible)
        }
        return .estimate(Estimate(
            vo2Max: vo2Max, segmentStart: segment.start, segmentEnd: segment.end,
            speed: segment.speed, grade: segment.grade, gradeFromElevation: segment.gradeFromElevation,
            segmentVO2: cost, heartRate: segment.heartRate, restingHR: restingHR,
            maxHR: maxHR, maxHRSource: source))
    }

    /// A workout that can be paused (the strap's, #227): the 10-minute rule counts RUNNING time, so
    /// a run of 8 minutes with a 5-minute pause in it is too short, as it is for an unpaused run. The
    /// rest is `estimate(_:)` over the whole span: no heart rate and no GPS fix is recorded while
    /// paused, so a minute that overlaps a pause cannot be part of a steady segment, and the warm-up
    /// is counted from the workout's start. With `activeSeconds` = end − start this is exactly
    /// `estimate(_:)`.
    public static func estimate(_ input: Input, activeSeconds: TimeInterval) -> Outcome {
        guard input.sport == .runningOutdoor else { return .skipped(.notAnOutdoorRun) }
        guard activeSeconds >= minimumDuration else { return .skipped(.tooShort) }
        return estimate(input)
    }

    // MARK: Resting HR input

    /// Days of resting HR needed before the estimate trusts a resting value.
    public static let minRestingDays = 3

    /// The resting HR input: the median of the most recent 7 daily resting-HR values on or before
    /// the run's day (`RestingHR.dailyValues` without the display coverage floor of #298, so on a
    /// thin day it can hold a value the app's own tile does not show). nil below
    /// `minRestingDays` values. The median keeps one short or disturbed day from moving it.
    public static func restingHR(daily: [RestingHR.DailyValue], runStart: Date,
                                 calendar: Calendar = .current) -> Double? {
        let runDay = calendar.startOfDay(for: runStart)
        let recent = daily.filter { $0.day <= runDay }
            .sorted { $0.day > $1.day }
            .prefix(7)
            .map(\.bpm)
            .sorted()
        guard recent.count >= minRestingDays else { return nil }
        let mid = recent.count / 2
        if recent.count % 2 == 1 { return recent[mid] }
        return (recent[mid - 1] + recent[mid]) / 2
    }

    // MARK: Segment search

    struct MinuteBin: Equatable {
        let start: Date
        /// m/min, nil when GPS didn't cover both edges of the minute.
        let speed: Double?
        /// Mean bpm, nil below `minReadingsPerMinute` readings.
        let heartRate: Double?
        /// Number of HR readings in the bin.
        let readings: Int
    }

    struct Segment: Equatable {
        let start: Date
        let end: Date
        let speed: Double
        let heartRate: Double
        let grade: Double
        let gradeFromElevation: Bool
        let speedVariation: Double
    }

    /// 1-minute bins over the whole run (warm-up included: the observed-max search uses them all).
    static func minuteBins(_ input: Input, route: [RoutePoint]) -> [MinuteBin] {
        var bins: [MinuteBin] = []
        var binStart = input.start
        while binStart.addingTimeInterval(60) <= input.end {
            let binEnd = binStart.addingTimeInterval(60)
            let readings = input.heartRate.filter { $0.start >= binStart && $0.start < binEnd }
            var hr: Double?
            if readings.count >= minReadingsPerMinute {
                let sum = readings.reduce(0.0) { $0 + Double($1.bpm) }
                hr = sum / Double(readings.count)
            }
            var speed: Double?
            if let d0 = distance(at: binStart, route: route),
               let d1 = distance(at: binEnd, route: route) {
                speed = d1 - d0   // metres in one minute = m/min
            }
            bins.append(MinuteBin(start: binStart, speed: speed, heartRate: hr,
                                  readings: readings.count))
            binStart = binEnd
        }
        return bins
    }

    /// Cumulative distance at `time`, linearly interpolated between the two fixes around it, or nil
    /// when no fix lies within `maxFixGap` of `time` on BOTH sides (a GPS gap is never bridged).
    static func distance(at time: Date, route: [RoutePoint]) -> Double? {
        guard let afterIndex = route.firstIndex(where: { $0.time >= time }) else { return nil }
        let after = route[afterIndex]
        if after.time == time { return after.distance }
        guard afterIndex > 0 else { return nil }
        let before = route[afterIndex - 1]
        guard time.timeIntervalSince(before.time) <= maxFixGap,
              after.time.timeIntervalSince(time) <= maxFixGap else { return nil }
        let span = after.time.timeIntervalSince(before.time)
        let fraction = time.timeIntervalSince(before.time) / span
        return before.distance + (after.distance - before.distance) * fraction
    }

    /// The steady segment with the most even pace, after the warm-up. Every bin in it must have
    /// speed and heart rate; speed must be steady (CV ≤ `maxSpeedVariation`) and in the ACSM
    /// range, heart rate within `maxHeartRateSpread`, and the grade (when elevation is reliable)
    /// inside `gradeRange`. Ties keep the earlier segment.
    static func steadiestSegment(bins: [MinuteBin], route: [RoutePoint]) -> Segment? {
        guard let first = bins.first else { return nil }
        let earliest = first.start.addingTimeInterval(warmUpExcluded)
        var best: Segment?
        let n = segmentMinutes
        guard bins.count >= n else { return nil }
        for i in 0 ... (bins.count - n) where bins[i].start >= earliest {
            let window = Array(bins[i ..< i + n])
            let speeds = window.compactMap(\.speed)
            let rates = window.compactMap(\.heartRate)
            guard speeds.count == n, rates.count == n else { continue }

            let meanSpeed = speeds.reduce(0, +) / Double(n)
            guard speedRange.contains(meanSpeed) else { continue }
            let variance = speeds.reduce(0.0) { $0 + ($1 - meanSpeed) * ($1 - meanSpeed) } / Double(n)
            let cv = variance.squareRoot() / meanSpeed
            guard cv <= maxSpeedVariation else { continue }
            guard let low = rates.min(), let high = rates.max(),
                  high - low <= maxHeartRateSpread else { continue }

            let start = window[0].start
            let end = start.addingTimeInterval(Double(n) * 60)
            var grade = 0.0
            var fromElevation = false
            if let measured = reliableGrade(route: route, from: start, to: end) {
                guard gradeRange.contains(measured) else { continue }
                grade = max(measured, 0)
                fromElevation = true
            }
            // Mean of the 1-minute means: each minute weighs the same however many readings it had.
            let meanHR = rates.reduce(0, +) / Double(n)
            let candidate = Segment(start: start, end: end, speed: meanSpeed, heartRate: meanHR,
                                    grade: grade, gradeFromElevation: fromElevation,
                                    speedVariation: cv)
            // The epsilon keeps floating-point noise in the CV from counting as "more even", so
            // equally even segments resolve to the earliest one deterministically.
            if best == nil || cv < best!.speedVariation - 1e-9 { best = candidate }
        }
        return best
    }

    /// Least-squares slope of altitude against cumulative distance over the fixes in [from, to] —
    /// the segment's grade. nil (⇒ assume flat) unless there are ≥ 3 fixes, every one with an
    /// altitude and a vertical accuracy in (0, `maxVerticalAccuracy`], and the fixes cover at least
    /// 100 m of ground.
    static func reliableGrade(route: [RoutePoint], from: Date, to: Date) -> Double? {
        let fixes = route.filter { $0.time >= from && $0.time <= to }
        guard fixes.count >= 3 else { return nil }
        var xs: [Double] = []
        var ys: [Double] = []
        for fix in fixes {
            guard let altitude = fix.altitude, let accuracy = fix.verticalAccuracy,
                  accuracy > 0, accuracy <= maxVerticalAccuracy else { return nil }
            xs.append(fix.distance)
            ys.append(altitude)
        }
        guard let minX = xs.min(), let maxX = xs.max(), maxX - minX >= 100 else { return nil }
        let count = Double(xs.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        var sxy = 0.0
        var sxx = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - meanX) * (y - meanY)
            sxx += (x - meanX) * (x - meanX)
        }
        guard sxx > 0 else { return nil }
        return sxy / sxx
    }
}
