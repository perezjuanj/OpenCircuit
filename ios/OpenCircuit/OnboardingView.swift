import SwiftUI

/// First-run onboarding (#103, revised for the ring and the strap in #255, redesigned as a
/// five-step gradient flow): welcome, your wearable, getting started, permissions, before you start.
///
/// The decisions are `OnboardingFlow`'s (preselection, "In use", how the guide ends) and the copy is
/// the device descriptor's (`DeviceCopy.swift`), so a new wearable needs no edit here. The permissions
/// step asks iOS for Bluetooth and Apple Health when the user taps Continue there
/// (`OnboardingPermissions`); nothing else here prompts, connects or switches the device in use.
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
    @State private var showStrapSetup = false
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
                        showStrapSetup = true
                    } else {
                        onDone()
                    }
                },
                onSkip: onDone
            )
            .toolbar(.hidden, for: .navigationBar)
            .onAppear(perform: readInstalledOnce)
            // The strap's existing setup screen, unchanged: its in-app Zepp sign-in gets the key, and
            // its "Save key and use the Helio Strap" is what switches. Done finishes onboarding.
            .navigationDestination(isPresented: $showStrapSetup) {
                HelioSetupView()
                    .toolbar(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone)
                        }
                    }
            }
            .onChange(of: showStrapSetup) { _, showing in
                // Back from setup: a saved key or a switch changes what's in use.
                if !showing { model.flow = OnboardingFlow(installed: .live()) }
            }
        }
    }
}
