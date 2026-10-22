// Starting a workout from a Shortcut ("Start Workout", Siri, the Action button, an automation).
//
// The shortcut carries ONE choice, the workout type, picked when the person sets the shortcut up. It
// opens the app, because a workout is something you watch start (the Live Activity, the location
// prompt for an outdoor route, the device link), and then this file decides what happens. Every rule
// here exists because the obvious "just call start()" would be wrong somewhere:
//
//   • Under the first-run onboarding cover, or while an "Interrupted workout" alert waits for an
//     answer, nothing may present (#258: a sheet asked for under the cover was never shown and left
//     the workout card dead). The request is HELD and decided again once they close.
//   • A workout already recording (ring or strap) is never replaced or doubled: the shortcut opens
//     the one that is running and the request is dropped. Ending a workout is always a deliberate
//     hold-to-end on screen, never a side effect of a shortcut.
//   • The device must be able to start (the ring connected, not mid-sync and not holding the link;
//     the strap authenticated and streaming). Starting during a ring sync is exactly what the Start
//     button is disabled for (T1). So the request WAITS with the workout sheet open and the type
//     already selected, and starts the moment the device is ready.
//   • A wait has an end. After `readyTimeout` the request is dropped and the sheet stays open with the
//     type selected; the person taps Start when the device is back. A workout that begins by itself
//     long after the shortcut ran, with the phone in a pocket, would be a surprise and a wrong record.
//   • Closing the workout sheet while waiting cancels the request (the caller does that): the person
//     backed out.
//
// Pure value logic so the rules are unit-tested (`WorkoutShortcutStartTests`); `ContentView` only
// applies the actions.

import Foundation

public enum WorkoutShortcutStart {

    /// Which recorder a workout runs on: the ring's (`WorkoutSessionManager`) or the strap's.
    public enum Device: Equatable, Sendable {
        case ring, strap
    }

    /// One shortcut run waiting to be applied.
    public struct Request: Equatable, Sendable {
        public let sport: WorkoutSportType
        public let requestedAt: Date
        public init(sport: WorkoutSportType, requestedAt: Date) {
            self.sport = sport
            self.requestedAt = requestedAt
        }
    }

    /// The app's state, read fresh every time the request is decided.
    public struct Context: Equatable, Sendable {
        /// The device chosen in Profile ▸ Device.
        public var device: Device
        public var onboardingCompleted: Bool
        /// Either "Interrupted workout" alert (ring or strap) is waiting for an answer.
        public var recoveryAlertShowing: Bool
        /// A ring workout is starting or active.
        public var ringRecording: Bool
        /// A strap workout is recording (active, paused included).
        public var strapRecording: Bool
        /// The chosen device can start a workout right now (the Start button's own rule).
        public var deviceReady: Bool

        public init(device: Device, onboardingCompleted: Bool, recoveryAlertShowing: Bool,
                    ringRecording: Bool, strapRecording: Bool, deviceReady: Bool) {
            self.device = device
            self.onboardingCompleted = onboardingCompleted
            self.recoveryAlertShowing = recoveryAlertShowing
            self.ringRecording = ringRecording
            self.strapRecording = strapRecording
            self.deviceReady = deviceReady
        }
    }

    public enum Action: Equatable, Sendable {
        /// Keep the request and decide again later (onboarding cover or recovery alert in the way).
        case hold
        /// A workout is already recording: open its sheet, drop the request.
        case showRunning(Device)
        /// Select the type, start, open the sheet; drop the request.
        case start(Device, WorkoutSportType)
        /// Open the sheet with the type selected, keep the request, decide again when the device's
        /// readiness changes (or at the deadline).
        case waitForDevice(Device, WorkoutSportType)
        /// The deadline passed: leave the sheet open with the type selected, drop the request.
        case giveUp(Device, WorkoutSportType)
    }

    /// How long a request waits for its device. A cold launch has to reconnect, and the ring may run
    /// a short sync on the way; past this, starting by itself would no longer match the moment the
    /// person ran the shortcut.
    public static let readyTimeout: TimeInterval = 5 * 60

    public static func decide(_ request: Request, context c: Context, now: Date) -> Action {
        guard c.onboardingCompleted, !c.recoveryAlertShowing else { return .hold }
        // A strap workout still recording after a switch to the ring is the one that is running,
        // whichever device is chosen now (the Activity tab keeps its card for the same reason).
        if c.strapRecording { return .showRunning(.strap) }
        if c.ringRecording { return .showRunning(.ring) }
        if c.deviceReady { return .start(c.device, request.sport) }
        if now.timeIntervalSince(request.requestedAt) >= readyTimeout { return .giveUp(c.device, request.sport) }
        return .waitForDevice(c.device, request.sport)
    }

    /// When a waiting request must be decided again even if nothing else changes.
    public static func deadline(for request: Request) -> Date {
        request.requestedAt.addingTimeInterval(readyTimeout)
    }
}
