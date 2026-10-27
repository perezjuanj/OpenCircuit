// WorkoutSteps.swift — steps during an INDOOR run or walk (#339, decision 84): the counter-delta rule,
// cadence, and the step-based distance estimate. Device-agnostic and pure: the strap's realtime step
// counter (`ZeppRealtimeSteps`, decision 84a) and the ring's running `0x4e` sport total
// (`RingSession.sportSteps`) both arrive here as a running counter read at a time.
//
// Rules (decision 84c, 84d):
//   • A counter is turned into steps by DELTAS. The first reading is a base, never steps. A reading
//     below the last one (the counter was reset, or a u16 wrapped) is a NEW BASE: never a negative
//     step count, and never a guessed wrap-around.
//   • Steps count only while the workout runs: a reading taken while paused moves the base and counts
//     nothing, and the recorder rebases at every resume and reconnect, so the steps taken in a pause or
//     a link gap are never credited to the next running minute.
//   • Distance estimate = active steps × stride, stride = height × a named per-sport factor (walking
//     0.415, running 0.65). Both factors are ROUGH ESTIMATES (docs/TRAINING_METRICS.md §3), so the
//     distance is labelled "est." until the person types the treadmill's distance; that distance then
//     calibrates the stride for the next indoor run of that sport on that device.

import Foundation

/// Which workouts use steps (decision 84a): an indoor run or walk.
public enum IndoorStepWorkout {
    public static func applies(to sport: WorkoutSportType) -> Bool {
        switch sport {
        case .runningIndoor, .walkingIndoor: return true
        case .walkingOutdoor, .runningOutdoor, .cyclingOutdoor, .cyclingIndoor, .rowing, .hiking,
             .strengthTraining, .yoga, .other: return false
        }
    }

    /// Per-minute running speed and stride length go to Apple Health for indoor RUNS only (84f).
    public static func writesRunningMetrics(_ sport: WorkoutSportType) -> Bool { sport == .runningIndoor }
}

/// Steps counted at one moment: the delta between two counter readings, dated at the later one.
public struct WorkoutStepDelta: Codable, Equatable, Sendable {
    public let at: Date
    public let steps: Int

    public init(at: Date, steps: Int) {
        self.at = at
        self.steps = steps
    }
}

/// A running step counter turned into counted steps (decision 84c).
public struct StepCounterDeltas: Equatable, Sendable {
    /// The last reading, nil before the first one and after `rebase()`.
    public private(set) var base: Int?
    /// Readings that were taken as a new base because they went backwards (a reset or a wrap).
    public private(set) var resets = 0

    public init() {}

    /// The next reading is a base again (the stream was turned on again, or the link came back).
    public mutating func rebase() { base = nil }

    /// One reading. Returns the steps it adds: 0 for a base, a reset, an unchanged counter, or a reading
    /// taken while not `counting` (paused); otherwise the positive delta.
    public mutating func observe(_ counter: Int, counting: Bool) -> Int {
        defer { base = counter }
        guard let previous = base else { return 0 }
        guard counter >= previous else {
            resets += 1
            return 0
        }
        return counting ? counter - previous : 0
    }
}

/// The steps a workout counted, in time order.
public struct WorkoutStepLog: Equatable, Sendable {
    public private(set) var deltas: [WorkoutStepDelta] = []

    public init(deltas: [WorkoutStepDelta] = []) { self.deltas = deltas }

    public var total: Int { deltas.reduce(0) { $0 + $1.steps } }
    public var isEmpty: Bool { total == 0 }

    public mutating func add(_ steps: Int, at date: Date) {
        guard steps > 0 else { return }
        deltas.append(WorkoutStepDelta(at: date, steps: steps))
    }

    /// Cadence live (decision 84d): steps per minute over the last 60 s, or over the time since the
    /// steps started counting when that is shorter. nil before 10 s of counting time (too short to say).
    public func liveCadence(now: Date, countingSince: Date) -> Double? {
        let window = min(60, now.timeIntervalSince(countingSince))
        guard window >= 10 else { return nil }
        let from = now.addingTimeInterval(-window)
        let steps = deltas.filter { $0.at > from && $0.at <= now }.reduce(0) { $0 + $1.steps }
        return Double(steps) / window * 60
    }

    /// The summary's average cadence: total steps over the running minutes. nil with no steps.
    public func averageCadence(activeSeconds: TimeInterval) -> Double? {
        guard total > 0, activeSeconds >= 60 else { return nil }
        return Double(total) / activeSeconds * 60
    }

    /// One whole minute of a workout and the steps counted in it.
    public struct Minute: Equatable, Sendable {
        public let start: Date
        public let steps: Int
        /// The minute lies wholly inside a running stretch (no pause and no link gap in it).
        public let wholeInActiveTime: Bool

        public var end: Date { start.addingTimeInterval(60) }
    }

    /// Whole minutes from `start` (the same bins as the VO₂ max estimate), with each one's steps
    /// (a delta counts in the minute it was dated in). The trailing part-minute is left out.
    public func minutes(start: Date, end: Date, active: [DateInterval]) -> [Minute] {
        var out: [Minute] = []
        var binStart = start
        while binStart.addingTimeInterval(60) <= end {
            let binEnd = binStart.addingTimeInterval(60)
            let steps = deltas.filter { $0.at >= binStart && $0.at < binEnd }.reduce(0) { $0 + $1.steps }
            let whole = active.contains { $0.start <= binStart && $0.end >= binEnd }
            out.append(Minute(start: binStart, steps: steps, wholeInActiveTime: whole))
            binStart = binEnd
        }
        return out
    }
}

/// The stride a step-based distance uses, and where it came from.
public struct IndoorStride: Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        /// Height × the sport's factor (a rough estimate).
        case height
        /// Typed treadmill distance ÷ active steps, from an earlier indoor run of this sport on this
        /// device.
        case calibrated
        /// This workout's own typed distance ÷ its active steps.
        case typed
    }

    /// Metres per step.
    public let meters: Double
    public let source: Source

    public init(meters: Double, source: Source) {
        self.meters = meters
        self.source = source
    }

    /// Decision 84d's factors: stride ≈ height × 0.415 walking, × 0.65 running. Rough estimates,
    /// documented in docs/TRAINING_METRICS.md §3.
    public static let walkingHeightFactor = 0.415
    public static let runningHeightFactor = 0.65

    public static func heightFactor(for sport: WorkoutSportType) -> Double? {
        switch sport {
        case .walkingIndoor: return walkingHeightFactor
        case .runningIndoor: return runningHeightFactor
        case .walkingOutdoor, .runningOutdoor, .cyclingOutdoor, .cyclingIndoor, .rowing, .hiking,
             .strengthTraining, .yoga, .other: return nil
        }
    }

    /// A stored calibration when there is one, else height × the sport's factor. nil when neither
    /// exists (no height set, or a sport without steps).
    public static func forWorkout(sport: WorkoutSportType, heightCm: Double?, calibrated: Double?) -> IndoorStride? {
        if let calibrated, plausible.contains(calibrated) { return IndoorStride(meters: calibrated, source: .calibrated) }
        guard let factor = heightFactor(for: sport), let heightCm, heightCm > 0 else { return nil }
        return IndoorStride(meters: heightCm / 100 * factor, source: .height)
    }

    /// The stride a typed distance gives: typed ÷ active steps. nil when there are no steps, or when the
    /// result isn't a human stride (a typo, or steps the device missed), so it is never stored.
    public static func calibrate(typedMeters: Double, activeSteps: Int) -> IndoorStride? {
        guard typedMeters > 0, activeSteps > 0 else { return nil }
        let meters = typedMeters / Double(activeSteps)
        guard plausible.contains(meters) else { return nil }
        return IndoorStride(meters: meters, source: .typed)
    }

    /// A stride outside this range is a bad input, not a person (metres per step).
    public static let plausible: ClosedRange<Double> = 0.2 ... 2.5

    /// Active steps × this stride, in metres.
    public func distance(steps: Int) -> Double { Double(max(steps, 0)) * meters }
}

/// What the summary's "Treadmill distance?" and "Incline %" fields accept (decision 84e).
public enum IndoorRunEntry {
    /// Incline, in percent.
    public static let inclineRange: ClosedRange<Double> = 0 ... 15

    /// A typed distance in the person's unit, as metres; nil for an empty, zero, negative or
    /// unreadable entry. Accepts "," as the decimal separator too.
    public static func distanceMeters(_ text: String, metersPerUnit: Double) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value > 0, value < 1_000 else { return nil }
        return value * metersPerUnit
    }

    /// A typed incline in percent; nil for an empty entry or one outside 0–15.
    public static func incline(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), inclineRange.contains(value) else { return nil }
        return value
    }
}
