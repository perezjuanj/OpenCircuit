// StrapWorkoutLowHeartRateNote.swift — when a strap workout gets the "heart rate stayed below Zone 1"
// note (#355, decision 88).
//
// A phone-side strap workout reads the strap's everyday heart rate stream (ZEPP_PROTOCOL.md §18.1,
// route 1), not Zepp's workout mode. A tester's tennis session read avg 83 bpm where his Zepp-recorded
// tennis reads about 165: fast, repeated arm movement is the worst case for optical heart rate. Until
// the hardware test (#356) says more, the summary and the history detail say so, and that is all.
//
// Display only (88d): nothing here changes stored data, Apple Health writes, zones, training load or
// calories. The readings are the set the summary counts (`StrapWorkoutSummaryBuilder.activeSamples`)
// and the zones are the ones the summary used.

import Foundation

public enum StrapWorkoutLowHeartRateNote {

    /// The note, verbatim (88b).
    public static let text = "Heart rate stayed below Zone 1 for most of this workout. If you worked harder than that, the strap may not have held a good reading: fast, repeated arm movement (racket sports, boxing) can make its live heart rate read low. OpenCircuit reads the strap's everyday heart rate, not Zepp's workout mode. A snug fit helps."

    // MARK: Constants (88a, the one place they are named)

    /// Sports where a heart rate below Zone 1 is expected, so the note would be noise.
    public static let excludedSports: Set<WorkoutSportType> = [.walkingOutdoor, .walkingIndoor, .hiking, .yoga]
    /// The shortest active time (pauses excluded) the note can apply to.
    public static let minimumActiveSeconds: TimeInterval = 20 * 60
    /// The readings must cover at least this share of the active seconds (one reading a second).
    public static let minimumCoverage = 0.5
    /// At least this share of the readings must be below Zone 1's lower bound.
    public static let minimumShareBelowZoneOne = 0.75

    // MARK: Predicate

    /// Whether the note shows. `activeReadings` are the readings the summary counts (deduplicated,
    /// inside the running stretches); `zones` are the zones it used. A bpm equal to Zone 1's lower
    /// bound is IN Zone 1.
    public static func applies(isStrapWorkout: Bool,
                               sport: WorkoutSportType,
                               activeSeconds: TimeInterval,
                               activeReadings: [HRSample],
                               zones: HeartRateZones) -> Bool {
        guard isStrapWorkout,
              !excludedSports.contains(sport),
              activeSeconds >= minimumActiveSeconds,
              Double(activeReadings.count) >= minimumCoverage * activeSeconds else { return false }
        let floor = zones.lowerBound(of: .warmUp)
        let below = activeReadings.filter { $0.bpm < floor }.count
        return Double(below) >= minimumShareBelowZoneOne * Double(activeReadings.count)
    }

    /// The same over a recording's time line: the active seconds and the counted readings exactly as
    /// `StrapWorkoutSummaryBuilder.summarize` takes them, so paused time never counts.
    public static func applies(isStrapWorkout: Bool,
                               sport: WorkoutSportType,
                               ledger: WorkoutActivityLedger,
                               samples: [HRSample],
                               end: Date,
                               zones: HeartRateZones) -> Bool {
        let end = max(end, ledger.start)
        return applies(isStrapWorkout: isStrapWorkout, sport: sport,
                       activeSeconds: ledger.activeSeconds(until: end),
                       activeReadings: StrapWorkoutSummaryBuilder.activeSamples(samples, ledger: ledger, end: end),
                       zones: zones)
    }
}
