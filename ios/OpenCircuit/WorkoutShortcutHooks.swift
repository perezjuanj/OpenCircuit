import SwiftUI
import OpenCircuitKit

// When `ContentView` decides a "Start Workout" shortcut request again (`WorkoutShortcutStart`), and
// when it drops one. A modifier, like `StrapWorkoutHooks`, so `ContentView`'s body stays one chain.
//
//   • a request arrives (or the app appears with one already waiting from a cold launch),
//   • the chosen device's readiness changes (connected, sync finished, a summary cleared),
//   • the first-run onboarding cover closes, or the "Interrupted workout" alert is answered (each
//     after it finishes dismissing: a sheet asked for in the same turn can be dropped, #258),
//   • the deadline passes.
//
// Dropped without starting when the person closes the workout sheet while it waits, or picks a
// different type in it: either way they have taken over from the shortcut.
struct WorkoutShortcutHooks: ViewModifier {
    let inbox: WorkoutShortcutInbox
    let onboardingCompleted: Bool
    /// The chosen device can start now (`ContentView.workoutShortcutDeviceReady`).
    let deviceReady: Bool
    let recoveryAlertShowing: Bool
    /// Either workout sheet is showing.
    let sheetOpen: Bool
    /// The type selected on the chosen device's recorder.
    let selectedSport: WorkoutSportType
    let apply: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: inbox.pending) {
                guard let request = inbox.pending else { return }
                apply()
                // Still waiting: decide once more at the deadline, so a device that never becomes
                // ready ends the wait instead of starting a workout an hour later.
                let wait = WorkoutShortcutStart.deadline(for: request).timeIntervalSinceNow
                guard inbox.pending == request, wait > 0 else { return }
                try? await Task.sleep(for: .seconds(wait + 0.5))
                guard !Task.isCancelled, inbox.pending == request else { return }
                apply()
            }
            .onChange(of: deviceReady) { _, _ in apply() }
            .onChange(of: onboardingCompleted) { _, done in
                if done { applyAfterDismissal() }
            }
            .onChange(of: recoveryAlertShowing) { _, showing in
                if !showing { applyAfterDismissal() }
            }
            .onChange(of: sheetOpen) { wasOpen, isOpen in
                if wasOpen, !isOpen { inbox.clear() }
            }
            .onChange(of: selectedSport) { _, sport in
                if sheetOpen, let pending = inbox.pending, pending.sport != sport { inbox.clear() }
            }
    }
}

extension WorkoutShortcutHooks {
    /// Let a closing cover or alert finish dismissing before a sheet is asked for (#258).
    @MainActor
    private func applyAfterDismissal() {
        guard inbox.pending != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            apply()
        }
    }
}

extension WorkoutShortcutStart.Device {
    /// The sheet that shows a workout on this device.
    var linkTarget: WorkoutLinkTarget {
        switch self {
        case .ring: return .ring
        case .strap: return .strap
        }
    }
}
