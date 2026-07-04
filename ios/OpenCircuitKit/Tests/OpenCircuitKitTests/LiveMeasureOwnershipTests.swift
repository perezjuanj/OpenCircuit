import XCTest
@testable import OpenCircuitKit

// Ownership/takeover state machine for the single live-measure link (#125). Locks the
// "don't fight the current owner" contract: a user tap promotes an auto read but never wrests an
// active workout, an auto refresh never disturbs a user's converging read, and an in-flight
// auto-measure stands down the moment a higher-priority owner takes over.
final class LiveMeasureOwnershipTests: XCTestCase {

    typealias Action = LiveMeasureOwnership.Action

    // MARK: nothing live → fresh start

    func testIdleUserTapStartsWithStaleCleared() {
        // A user read clears the stale value up front so an old lock can't look live while warming.
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: false, userInitiated: true,
                                        userMeasuring: false, workoutHolding: false, sameMode: true),
            .start(clearStale: true))
    }

    func testIdleAutoStartKeepsLastValue() {
        // Auto/background refresh leaves the prior value on screen until the new one locks.
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: false, userInitiated: false,
                                        userMeasuring: false, workoutHolding: false, sameMode: true),
            .start(clearStale: false))
    }

    func testIdleWorkoutStartKeepsLastValue() {
        // beginWorkoutHR starts a fresh cycle (userInitiated:false) — no stale clear.
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: false, userInitiated: false,
                                        userMeasuring: false, workoutHolding: true, sameMode: true),
            .start(clearStale: false))
    }

    // MARK: takeover

    func testUserTapTakesOverAnAutoRead() {
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                        userMeasuring: false, workoutHolding: false, sameMode: true),
            .takeover)
    }

    func testUserTapTakesOverAnAutoReadEvenInADifferentMode() {
        // Takeover is checked before the same/different-mode split — a tap in the other mode still
        // promotes to a fresh user-owned cycle rather than an in-place switch.
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                        userMeasuring: false, workoutHolding: false, sameMode: false),
            .takeover)
    }

    // MARK: workout hold is inviolable

    func testUserTapDoesNotWrestAnActiveWorkout() {
        // The blocker's MINOR fix: a workout owns HR; a Measure tap must NOT take over in the state
        // machine (previously relied only on the view hiding the button).
        let action = LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                                 userMeasuring: false, workoutHolding: true,
                                                 sameMode: true)
        XCTAssertNotEqual(action, .takeover)
        XCTAssertEqual(action, .rearm, "same-mode user tap during a workout re-polls, never takes over")
    }

    func testUserTapDuringWorkoutInOtherModeSwitchesRatherThanTakesOver() {
        let action = LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                                 userMeasuring: false, workoutHolding: true,
                                                 sameMode: false)
        XCTAssertNotEqual(action, .takeover)
        XCTAssertEqual(action, .switchMode(armDeadline: true))
    }

    // MARK: same-mode re-tap vs auto no-op

    func testSameModeUserRetapRearms() {
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                        userMeasuring: true, workoutHolding: false, sameMode: true),
            .rearm)
    }

    func testSameModeAutoRefreshIsIgnored() {
        // A periodic auto-measure must never disturb a user's converging read.
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: false,
                                        userMeasuring: true, workoutHolding: false, sameMode: true),
            .ignore)
    }

    // MARK: mode switch

    func testUserModeSwitchArmsDeadline() {
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                        userMeasuring: true, workoutHolding: false, sameMode: false),
            .switchMode(armDeadline: true))
    }

    func testAutoModeSwitchDoesNotArmDeadline() {
        // armDeadline:false also means "keep the prior value on screen" — setLiveMode does NOT clear
        // the target mode's latch on an auto switch, mirroring startLiveMonitoring's contract.
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: false,
                                        userMeasuring: false, workoutHolding: false, sameMode: false),
            .switchMode(armDeadline: false))
    }

    func testUserModeToggleSignalsStaleClearAtEveryStep() {
        // #125 blocker repro: a user SpO2 read, then toggling HR and back to SpO2, must never let the
        // prior liveSpO2 masquerade as live or count as a deadline lock. Every user-owned entry into
        // a mode signals a stale-clear — the initial start clears it, and each cross-mode switch
        // reports armDeadline:true, which setLiveMode uses to drop the TARGET mode's stale latch.
        // (Before the fix, the switchMode path left liveSpO2 set, so an off-finger read after the
        // toggle timed out with no failure banner.)
        // 1. idle → user taps SpO2
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: false, userInitiated: true,
                                        userMeasuring: false, workoutHolding: false, sameMode: true),
            .start(clearStale: true))
        // 2. live SpO2 (user-owned) → user taps HR
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                        userMeasuring: true, workoutHolding: false, sameMode: false),
            .switchMode(armDeadline: true))
        // 3. live HR (user-owned) → user taps SpO2 again — the toggle that regressed
        XCTAssertEqual(
            LiveMeasureOwnership.decide(monitoring: true, userInitiated: true,
                                        userMeasuring: true, workoutHolding: false, sameMode: false),
            .switchMode(armDeadline: true))
    }

    // MARK: stop-ownership — auto-measure stands down for a higher-priority owner

    func testAutoHoldsWhileItStillOwnsTheLink() {
        XCTAssertFalse(LiveMeasureOwnership.autoShouldStandDown(
            autoMeasuring: true, monitoring: true, modeMatches: true, calibrationCapturing: false))
    }

    func testAutoStandsDownWhenUserTookOwnership() {
        // A user takeover clears `autoMeasuring`.
        XCTAssertTrue(LiveMeasureOwnership.autoShouldStandDown(
            autoMeasuring: false, monitoring: true, modeMatches: true, calibrationCapturing: false))
    }

    func testAutoStandsDownWhenMonitoringStopped() {
        XCTAssertTrue(LiveMeasureOwnership.autoShouldStandDown(
            autoMeasuring: true, monitoring: false, modeMatches: true, calibrationCapturing: false))
    }

    func testAutoStandsDownWhenModeSwitchedOutFromUnderIt() {
        XCTAssertTrue(LiveMeasureOwnership.autoShouldStandDown(
            autoMeasuring: true, monitoring: true, modeMatches: false, calibrationCapturing: false))
    }

    func testAutoStandsDownWhenCalibrationGrabsTheSensor() {
        XCTAssertTrue(LiveMeasureOwnership.autoShouldStandDown(
            autoMeasuring: true, monitoring: true, modeMatches: true, calibrationCapturing: true))
    }
}
