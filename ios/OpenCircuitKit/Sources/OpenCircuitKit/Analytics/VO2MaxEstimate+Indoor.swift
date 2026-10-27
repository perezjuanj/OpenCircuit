// VO2MaxEstimate+Indoor.swift — the VO₂ max ESTIMATE for an indoor (treadmill) run (#339, decision 84g).
//
// The outdoor method (`VO2MaxEstimate.estimate`, docs/TRAINING_METRICS.md §2) with one input changed:
// the speed. Outdoors it is the GPS route; indoors there is no route, so each minute's speed is
//     that minute's steps × the calibrated stride,   stride = typed treadmill distance ÷ total active steps
// and the grade is the typed incline ÷ 100 (0 when none was typed). Everything else is the outdoor
// rule, unchanged: the 10-minute minimum on running time, the 4-minute warm-up, the steady 5-minute
// segment (speed CV ≤ 10 %, heart-rate spread ≤ 10 bpm, 80–400 m/min), the 50 % heart-rate-reserve
// floor, Tanaka/observed maximum, Swain's extrapolation and the plausible range.
//
// Only with a typed distance AND step data: without the treadmill's distance a stride from height is
// a guess, and a guess of speed is exactly what the estimate's error budget can't absorb. Each
// refusal is a `SkipReason` in words. The outdoor path is not touched by this file.

import Foundation

extension VO2MaxEstimate {

    public struct IndoorInput: Sendable {
        public let sport: WorkoutSportType
        public let start: Date
        public let end: Date
        /// Running time (pauses left out), for the 10-minute rule.
        public let activeSeconds: TimeInterval
        public let heartRate: [HRSample]
        /// The steps counted while running, each dated when it was counted.
        public let steps: [WorkoutStepDelta]
        /// The treadmill's distance the person typed (metres), nil when they didn't.
        public let typedDistance: Double?
        /// The typed incline in percent (0–15), nil when none was typed.
        public let inclinePercent: Double?
        public let age: Int?
        public let restingHR: Double?

        public init(sport: WorkoutSportType, start: Date, end: Date, activeSeconds: TimeInterval,
                    heartRate: [HRSample], steps: [WorkoutStepDelta], typedDistance: Double?,
                    inclinePercent: Double?, age: Int?, restingHR: Double?) {
            self.sport = sport
            self.start = start
            self.end = end
            self.activeSeconds = activeSeconds
            self.heartRate = heartRate
            self.steps = steps
            self.typedDistance = typedDistance
            self.inclinePercent = inclinePercent
            self.age = age
            self.restingHR = restingHR
        }

        /// The steps the stride divides the typed distance by.
        public var activeSteps: Int { steps.reduce(0) { $0 + max($1.steps, 0) } }
    }

    public static func estimateIndoor(_ input: IndoorInput) -> Outcome {
        guard input.sport == .runningIndoor else { return .skipped(.notAnIndoorRun) }
        guard input.activeSeconds >= minimumDuration,
              input.end.timeIntervalSince(input.start) >= minimumDuration else { return .skipped(.tooShort) }
        guard let typed = input.typedDistance, typed > 0 else { return .skipped(.noTypedDistance) }
        let totalSteps = input.activeSteps
        guard totalSteps > 0 else { return .skipped(.noStepData) }
        guard input.heartRate.count >= minReadingsPerMinute * segmentMinutes else {
            return .skipped(.noHeartRate)
        }
        guard let age = input.age else { return .skipped(.noAge) }
        guard let restingHR = input.restingHR, restingHR > 0 else { return .skipped(.noRestingHR) }
        // The typed incline is the grade (decision 84g). The entry field only accepts 0–15 %; anything
        // else is a bad input, not a slope to clamp.
        let grade = (input.inclinePercent ?? 0) / 100
        guard grade >= 0, grade <= gradeRange.upperBound else { return .skipped(.implausible) }

        let stride = typed / Double(totalSteps)
        let bins = indoorMinuteBins(input, stride: stride)
        // No route: `steadiestSegment` finds no elevation to judge, so it applies the speed and
        // heart-rate rules only, and the typed grade is used below.
        guard let segment = steadiestSegment(bins: bins, route: []) else { return .skipped(.noSteadySegment) }

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
        let cost = acsmRunningVO2(speedMetersPerMinute: segment.speed, grade: grade)
        guard let vo2Max = extrapolate(vo2: cost, heartRate: segment.heartRate,
                                       restingHR: restingHR, maxHR: maxHR),
              plausibleRange.contains(vo2Max) else {
            return .skipped(.implausible)
        }
        return .estimate(Estimate(
            vo2Max: vo2Max, segmentStart: segment.start, segmentEnd: segment.end,
            speed: segment.speed, grade: grade, gradeFromElevation: false,
            segmentVO2: cost, heartRate: segment.heartRate, restingHR: restingHR,
            maxHR: maxHR, maxHRSource: source, speedSource: .treadmillSteps))
    }

    /// The outdoor bins (`minuteBins`) with each minute's speed = its steps × `stride` (m/min). A
    /// minute with no steps has speed 0, which the ACSM range then refuses: a pause or a gap in the
    /// step stream can never be part of the steady segment.
    static func indoorMinuteBins(_ input: IndoorInput, stride: Double) -> [MinuteBin] {
        let log = WorkoutStepLog(deltas: input.steps)
        let minutes = log.minutes(start: input.start, end: input.end, active: [DateInterval(start: input.start, end: input.end)])
        return minutes.map { minute in
            let readings = input.heartRate.filter { $0.start >= minute.start && $0.start < minute.end }
            var hr: Double?
            if readings.count >= minReadingsPerMinute {
                hr = readings.reduce(0.0) { $0 + Double($1.bpm) } / Double(readings.count)
            }
            return MinuteBin(start: minute.start, speed: Double(minute.steps) * stride, heartRate: hr,
                             readings: readings.count)
        }
    }
}
