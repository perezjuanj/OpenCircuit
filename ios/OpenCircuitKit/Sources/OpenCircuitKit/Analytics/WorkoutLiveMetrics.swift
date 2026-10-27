// WorkoutLiveMetrics.swift — pure rules for what a workout shows LIVE beyond time and heart rate
// (#283): GPS pace, and what a phone call does to a running workout. Foundation-only; the ring's
// `WorkoutSessionManager` and the strap's `StrapWorkoutRecorder` both feed the same Live Activity
// from these, so the two devices cannot disagree.
//
// NO-FABRICATION: every function returns nil rather than a guess. Pace needs real GPS distance
// over real running time, and a pace measured from fixes that stopped arriving is not "current".

import Foundation

/// One accepted GPS fix reduced to what pace needs: when, and the cumulative distance then.
public struct WorkoutDistanceFix: Equatable, Sendable {
    public let at: Date
    public let cumulativeMeters: Double
    public init(at: Date, cumulativeMeters: Double) {
        self.at = at
        self.cumulativeMeters = cumulativeMeters
    }
}

public enum WorkoutPace {
    /// Least distance before an average pace is shown: below this the GPS noise is the number.
    public static let minimumAverageMeters: Double = 50
    /// Least running time before an average pace is shown.
    public static let minimumAverageSeconds: TimeInterval = 10
    /// The look-back for "current" pace.
    public static let currentWindowSeconds: TimeInterval = 30
    /// Least distance inside that window.
    public static let minimumWindowMeters: Double = 15
    /// A newest fix older than this means the person is not being tracked right now.
    public static let freshSeconds: TimeInterval = 15
    /// Slower than this (60 min/km) is standing still, not a pace.
    public static let slowestSecPerKm: Double = 3600

    /// Seconds per kilometre over the whole workout: running time (pauses excluded) / distance.
    public static func averageSecPerKm(distanceMeters: Double?, activeSeconds: TimeInterval) -> Double? {
        guard let distanceMeters, distanceMeters >= minimumAverageMeters,
              activeSeconds >= minimumAverageSeconds else { return nil }
        let pace = activeSeconds / (distanceMeters / 1000)
        return pace <= slowestSecPerKm ? pace : nil
    }

    /// Seconds per kilometre over the last `currentWindowSeconds` of fixes, or nil when the newest
    /// fix is not fresh or the window holds too little distance. `fixes` must be in time order and
    /// must not span a pause (the caller starts a new list on resume).
    public static func currentSecPerKm(fixes: [WorkoutDistanceFix], now: Date) -> Double? {
        guard let newest = fixes.last, now.timeIntervalSince(newest.at) <= freshSeconds else { return nil }
        let cutoff = newest.at.addingTimeInterval(-currentWindowSeconds)
        guard let oldest = fixes.first(where: { $0.at >= cutoff }), oldest.at < newest.at else { return nil }
        let meters = newest.cumulativeMeters - oldest.cumulativeMeters
        let seconds = newest.at.timeIntervalSince(oldest.at)
        guard meters >= minimumWindowMeters, seconds > 0 else { return nil }
        let pace = seconds / (meters / 1000)
        return pace <= slowestSecPerKm ? pace : nil
    }

    /// The live HR zone (1...5) for a reading, or nil when there is no fresh reading or it is below
    /// zone 1. Never a zone for a stale number.
    public static func liveZone(bpm: Int?, isStale: Bool, zones: HeartRateZones) -> Int? {
        guard let bpm, !isStale else { return nil }
        return zones.zone(bpm: bpm)?.rawValue
    }

    /// `liveZone` over the default zones for `maxHR`.
    public static func liveZone(bpm: Int?, isStale: Bool, maxHR: Int) -> Int? {
        liveZone(bpm: bpm, isStale: isStale, zones: HeartRateZones(percentOfMax: max(maxHR, 1)))
    }
}

/// What a phone call does to a workout: it pauses a running one, and when the call ends it asks —
/// it never resumes by itself, because the person may still be away from the activity.
public struct WorkoutCallPause: Equatable, Sendable {
    /// This call-pause owns the current pause (the workout was running when the call connected).
    public private(set) var pausedForCall = false
    /// The call ended and the person has not answered the "resume?" prompt yet.
    public private(set) var resumePromptPending = false

    public init() {}

    /// A call connected. True when the workout should be paused now. A workout the person had
    /// already paused is left alone and never offered a resume prompt.
    public mutating func callConnected(workoutRunning: Bool, workoutPaused: Bool) -> Bool {
        guard workoutRunning, !workoutPaused, !pausedForCall else { return false }
        pausedForCall = true
        resumePromptPending = false
        return true
    }

    /// The last call ended. True when the "paused for a call, resume?" prompt should show: only if
    /// this call paused the workout and the workout is still paused.
    public mutating func allCallsEnded(workoutRunning: Bool, workoutPaused: Bool) -> Bool {
        guard pausedForCall else { return false }
        guard workoutRunning, workoutPaused else { pausedForCall = false; return false }
        resumePromptPending = true
        return true
    }

    /// The person resumed (from the prompt or the Resume button) or the workout ended.
    public mutating func clear() {
        pausedForCall = false
        resumePromptPending = false
    }
}

/// Remembers when the cumulative GPS distance last MOVED, so "current pace" ages out when fixes stop
/// (a tracker fed on a timer would otherwise look fresh while the distance sat still).
public struct WorkoutPaceTracker: Equatable, Sendable {
    public private(set) var fixes: [WorkoutDistanceFix] = []
    private static let keepSeconds: TimeInterval = 120

    public init() {}

    /// Feed the cumulative distance as often as convenient; only a change is kept.
    public mutating func observe(distanceMeters: Double?, at date: Date) {
        guard let distanceMeters else { return }
        if let last = fixes.last, distanceMeters <= last.cumulativeMeters { return }
        fixes.append(WorkoutDistanceFix(at: date, cumulativeMeters: distanceMeters))
        let cutoff = date.addingTimeInterval(-Self.keepSeconds)
        fixes.removeAll { $0.at < cutoff }
    }

    /// Start a new leg (pause or resume): pace never spans a pause.
    public mutating func reset() { fixes = [] }

    public func currentSecPerKm(now: Date) -> Double? { WorkoutPace.currentSecPerKm(fixes: fixes, now: now) }
}
