import XCTest
@testable import OpenCircuitKit

final class WorkoutShortcutStartTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_700_000)
    private var request: WorkoutShortcutStart.Request { .init(sport: .cyclingIndoor, requestedAt: t0) }

    private func context(device: WorkoutShortcutStart.Device = .ring, onboarding: Bool = true,
                         recovery: Bool = false, ring: Bool = false, strap: Bool = false,
                         ready: Bool = true) -> WorkoutShortcutStart.Context {
        .init(device: device, onboardingCompleted: onboarding, recoveryAlertShowing: recovery,
              ringRecording: ring, strapRecording: strap, deviceReady: ready)
    }

    private func decide(_ c: WorkoutShortcutStart.Context, after seconds: TimeInterval = 1) -> WorkoutShortcutStart.Action {
        WorkoutShortcutStart.decide(request, context: c, now: t0.addingTimeInterval(seconds))
    }

    func testAReadyDeviceStartsTheChosenType() {
        XCTAssertEqual(decide(context(device: .ring)), .start(.ring, .cyclingIndoor))
        XCTAssertEqual(decide(context(device: .strap)), .start(.strap, .cyclingIndoor))
    }

    /// #258: nothing presents under the onboarding cover or over a recovery alert.
    func testOnboardingAndTheRecoveryAlertHoldTheRequest() {
        XCTAssertEqual(decide(context(onboarding: false)), .hold)
        XCTAssertEqual(decide(context(recovery: true)), .hold)
        XCTAssertEqual(decide(context(onboarding: false, ring: true)), .hold, "held before anything else")
        // Held well past the deadline is still held: the clock only runs once something can be shown.
        XCTAssertEqual(decide(context(recovery: true), after: 3600), .hold)
    }

    /// A recording workout is never doubled or replaced.
    func testARecordingWorkoutIsShownNotReplaced() {
        XCTAssertEqual(decide(context(device: .ring, ring: true)), .showRunning(.ring))
        XCTAssertEqual(decide(context(device: .strap, strap: true)), .showRunning(.strap))
        XCTAssertEqual(decide(context(device: .ring, strap: true)), .showRunning(.strap),
                       "a strap workout still running after a switch to the ring is the one shown")
        XCTAssertEqual(decide(context(ring: true, ready: false), after: 3600), .showRunning(.ring))
    }

    func testANotReadyDeviceWaitsWithTheTypeSelected() {
        XCTAssertEqual(decide(context(device: .ring, ready: false)), .waitForDevice(.ring, .cyclingIndoor))
        XCTAssertEqual(decide(context(device: .strap, ready: false), after: WorkoutShortcutStart.readyTimeout - 1),
                       .waitForDevice(.strap, .cyclingIndoor))
    }

    func testTheWaitEndsAtTheDeadline() {
        let timeout = WorkoutShortcutStart.readyTimeout
        XCTAssertEqual(decide(context(ready: false), after: timeout), .giveUp(.ring, .cyclingIndoor))
        XCTAssertEqual(WorkoutShortcutStart.deadline(for: request), t0.addingTimeInterval(timeout))
        // Ready just before the deadline still starts; ready after it is still a start (the device
        // came back while the person was looking at the sheet), which `decide` cannot tell apart,
        // so the caller drops the request at `giveUp` and never decides it again.
        XCTAssertEqual(decide(context(ready: true), after: timeout - 1), .start(.ring, .cyclingIndoor))
    }

    func testEveryWorkoutTypeCanBeStarted() {
        for sport in WorkoutSportType.allCases {
            let r = WorkoutShortcutStart.Request(sport: sport, requestedAt: t0)
            XCTAssertEqual(WorkoutShortcutStart.decide(r, context: context(), now: t0), .start(.ring, sport))
        }
    }
}
