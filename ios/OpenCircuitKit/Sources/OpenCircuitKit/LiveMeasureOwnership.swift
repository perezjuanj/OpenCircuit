// LiveMeasureOwnership — the pure state machine deciding who owns the single live-measure link
// when `RingSession.startMonitoring` is called, and when an in-flight auto-measure must stand
// down for a higher-priority owner (a user tap, a workout, calibration) (#125).
//
// Why this exists: the ring measures ONE metric at a time over ONE live link, so a Measure tap, a
// periodic auto/background refresh, and a workout all contend for it. The ownership rules used to
// live inline in `startMonitoring`/`autoMeasureOnce` as nested conditionals that were easy to get
// subtly wrong (e.g. a user tap wresting the link from an active workout, or a takeover firing
// while a measurement the user already started was mid-flight). Extracting the decision into a
// pure, injectable enum — mirroring `WorkoutHRGate`/`AutoMeasureGate` — lets the "don't fight the
// current owner" contract be locked by tests instead of re-verified by hand on every change.

import Foundation

public enum LiveMeasureOwnership {

    /// What `startMonitoring` should do for a given request, given the current link state.
    public enum Action: Equatable {
        /// Nothing is live → begin a fresh cycle. `clearStale` drops the prior value up front for a
        /// user read so an old lock can't masquerade as live while the new one warms up (#45 C/#125).
        case start(clearStale: Bool)
        /// An auto/background read is live and the user tapped Measure → promote it to an explicit
        /// user measurement (stop the foreign cycle, then start a fresh user-owned one).
        case takeover
        /// Already live in the SAME mode on a user-owned read and the user tapped again → re-poll.
        case rearm
        /// Already live in the same mode on an auto read → leave the converging read alone.
        case ignore
        /// Already live in a DIFFERENT mode → switch the mode in place. `armDeadline` when the switch
        /// was user-initiated (the user now owns the timeout UX for the new mode).
        case switchMode(armDeadline: Bool)
    }

    /// Decide the ownership action for one `startMonitoring(mode:userInitiated:)` call.
    ///
    /// - Parameters:
    ///   - monitoring: is a live cycle currently running?
    ///   - userInitiated: is this a real Measure tap (vs an auto/background refresh)?
    ///   - userMeasuring: is the CURRENT cycle already a user-owned measurement?
    ///   - workoutHolding: does an active workout hold the HR link? A user tap must NOT wrest it —
    ///     the workout owns HR for its whole duration (previously enforced only by hiding the button).
    ///   - sameMode: does the requested mode match the mode currently being measured?
    public static func decide(monitoring: Bool,
                              userInitiated: Bool,
                              userMeasuring: Bool,
                              workoutHolding: Bool,
                              sameMode: Bool) -> Action {
        guard monitoring else { return .start(clearStale: userInitiated) }
        // Promote an auto/background read into a user measurement — but never take the link from an
        // active workout, and never re-takeover a measurement the user already started.
        if userInitiated, !userMeasuring, !workoutHolding { return .takeover }
        if sameMode { return userInitiated ? .rearm : .ignore }
        return .switchMode(armDeadline: userInitiated)
    }

    /// Whether an in-flight `autoMeasureOnce` cycle should abandon its wait because a
    /// higher-priority owner took the link (a user takeover clears `autoMeasuring`; a mode switch or
    /// a stop clears the match/monitoring; calibration grabs the sensor). Mirrors the bail check in
    /// `autoMeasureOnce` so "don't fight the current owner" is test-locked, and an aborted cycle is
    /// never miscounted toward the not-worn inference (#56/#125).
    public static func autoShouldStandDown(autoMeasuring: Bool,
                                           monitoring: Bool,
                                           modeMatches: Bool,
                                           calibrationCapturing: Bool) -> Bool {
        !autoMeasuring || !monitoring || !modeMatches || calibrationCapturing
    }
}
