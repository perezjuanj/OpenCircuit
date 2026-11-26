import SwiftUI

/// First-run onboarding (#103, revised for the ring and the strap in #255, redesigned as a
/// five-step gradient flow): welcome, your wearable, getting started, permissions, before you start.
///
/// The decisions are `OnboardingFlow`'s (preselection, "In use", how the guide ends) and the copy is
/// the device descriptor's (`DeviceCopy.swift`), so a new wearable needs no edit here. The permissions
/// step asks iOS for Bluetooth and Apple Health when the user taps Continue there
/// (`OnboardingPermissions`). With the strap picked and no key, the last step opens `HelioKeySheet`,
/// whose saved key switches to the strap like the setup screen's; nothing else here prompts, connects
/// or switches the device in use.
/// Shown once on first launch via `completedKey` (see ContentView), and re-openable from Profile ▸ About.
struct OnboardingView: View {
    /// Persisted flag: set once the user finishes/skips so the flow doesn't show again on launch.
    /// Versioned so a revised onboarding re-shows by bumping the suffix: v2 (#255) shows the device
    /// choice once to everyone who finished v1. The v1 key is left in place, never cleared.
    static let completedKey = "onboarding.completed.v2"

    /// Called when the user taps Get Started, Skip, or Done on the strap's setup — the caller
    /// persists the flag / dismisses.
    var onDone: () -> Void

    @StateObject private var model = OnboardingViewModel()
    @State private var showKeySheet = false
    /// Set by the key sheet's Done or a saved key: onboarding finishes once the sheet is gone, never
    /// while it's still on screen over the cover.
    @State private var finishAfterSheet = false
    @State private var debugSheetMode = HelioKeySheet.Mode.choose
    /// The live read (UserDefaults + Keychain) has run. It runs once, on appear, not in `init`: the
    /// presenter re-renders often (a live device streams), and each render re-runs `init` (review-256 F5).
    @State private var readInstalled = false

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    /// The one live read: what's in use, and the preselection.
    private func readInstalledOnce() {
        guard !readInstalled else { return }
        readInstalled = true
        let live = OnboardingFlow(installed: .live())
        model.flow = live
#if DEBUG && targetEnvironment(simulator)
        // `strap-sheet` / `strap-signin`: the last step with the strap's key sheet open (screenshots).
        if let id = UserDefaults.standard.string(forKey: OnboardingFlow.debugPageArgumentKey),
           let mode = ["strap-sheet": HelioKeySheet.Mode.choose, "strap-signin": .signIn][id] {
            model.start(at: .legal, device: .helioStrap)
            debugSheetMode = mode
            showKeySheet = true
            return
        }
        if let id = UserDefaults.standard.string(forKey: OnboardingFlow.debugPageArgumentKey),
           let start = live.debugStart(id) {
            model.start(at: .init(start.page), device: start.pick)
            return
        }
#endif
        model.start(at: .welcome, device: live.preselection)
    }

    var body: some View {
        NavigationStack {
            OnboardingFlowView(
                model: model,
                onFinish: {
                    if model.finish == .setUpStrap {
                        showKeySheet = true
                    } else {
                        onDone()
                    }
                },
                onSkip: onDone
            )
            .toolbar(.hidden, for: .navigationBar)
            .onAppear(perform: readInstalledOnce)
            // The strap's key sheet: the in-app Zepp sign-in, saved and switched exactly as the setup
            // screen does (`HelioSetupView.saveKeyAndUseStrap`). Done or a saved key finishes onboarding;
            // swiping it away goes back to the last step.
            .sheet(isPresented: $showKeySheet, onDismiss: {
                // A saved key or a switch changes what's in use.
                model.flow = OnboardingFlow(installed: .live())
                if finishAfterSheet { onDone() }
            }) {
                HelioKeySheet(
                    onSaved: { finishAfterSheet = true; showKeySheet = false },
                    onDone: { finishAfterSheet = true; showKeySheet = false },
                    initialMode: debugSheetMode
                )
            }
        }
    }
}
