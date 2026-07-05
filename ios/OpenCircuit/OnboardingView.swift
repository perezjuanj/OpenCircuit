import SwiftUI

/// First-run onboarding (#103). A short, dismissible, re-openable flow that orients a new
/// (non-developer) user before they land on the dashboard:
///   1. what OpenCircuit does — local-first, writes to Apple Health, nothing leaves the device;
///   2. the one-time prerequisite — activate the ring once in the official RingConn app;
///   3. permission priming — why Bluetooth + Apple Health are requested (the system prompts come
///      later, when the user first connects / authorizes Health — onboarding only explains them);
///   4. the not-affiliated / not-a-medical-device disclaimer.
///
/// Honest copy, no medical claims (the `trust` convention). Shown once on first launch via the
/// `OnboardingView.completedKey` flag (see ContentView), and re-openable from the profile screen's
/// About section. Pure presentation — it triggers no permission prompts itself.
struct OnboardingView: View {
    /// Persisted flag: set once the user finishes/skips so the flow doesn't show again on launch.
    /// Versioned so a future revised onboarding can re-show by bumping the suffix.
    static let completedKey = "onboarding.completed.v1"

    /// Called when the user taps Get Started or Skip — the caller persists the flag / dismisses.
    var onDone: () -> Void

    @State private var page = 0
    private static let lastPage = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                prerequisite.tag(1)
                permissions.tag(2)
                disclaimer.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 4) {
                Button(page < Self.lastPage ? "Continue" : "Get Started") {
                    if page < Self.lastPage { withAnimation { page += 1 } } else { onDone() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                // Skip is redundant on the final page (Get Started is the same action there).
                Button("Skip", action: onDone)
                    .font(.footnote)
                    .opacity(page < Self.lastPage ? 1 : 0)
                    .disabled(page == Self.lastPage)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    // MARK: Pages

    private var welcome: some View {
        page(icon: "waveform.path.ecg", tint: .blue, title: "Welcome to OpenCircuit") {
            bullet("OpenCircuit reads your RingConn Gen 2's metrics over Bluetooth — heart rate, "
                 + "HRV, SpO₂, sleep, skin temperature and more.")
            bullet("It's local-first: your data stays on your device and is written only to Apple "
                 + "Health. Nothing is sent to any server.")
            bullet("No account, no subscription, no cloud.")
        }
    }

    private var prerequisite: some View {
        page(icon: "1.circle", tint: .indigo, title: "One-time setup") {
            bullet("If your ring is new, set it up once in the official RingConn app to activate it — "
                 + "then fully close that app (swipe it away). Only one app can talk to the ring at a "
                 + "time. After that, OpenCircuit connects on its own.")
            bullet("Keep your phone nearby — especially overnight — so OpenCircuit can capture your "
                 + "full night of sleep and skin-temperature data.")
            bullet("Charge the ring as usual; OpenCircuit picks up where it left off.")
        }
    }

    private var permissions: some View {
        page(icon: "lock.shield", tint: .teal, title: "Permissions") {
            bullet("Bluetooth — to find and connect to your ring.", icon: "dot.radiowaves.left.and.right")
            bullet("Apple Health — to save your metrics. You choose exactly what to share.",
                   icon: "heart.text.square")
            Text("You'll be asked for these the first time you connect and authorize Health.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var disclaimer: some View {
        page(icon: "info.circle", tint: .orange, title: "Good to know") {
            // Mirrors the About-section disclaimer in UserProfileSettingsView (single source of copy).
            Text("OpenCircuit is an independent, local-first app compatible with the RingConn Gen 2 "
                 + "smart ring. It is not affiliated with, authorized, or endorsed by RingConn or "
                 + "JZ_Tech; \"RingConn\" is a trademark of its respective owner.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("OpenCircuit is not a medical device. Its readings are estimates for personal "
                 + "insight, not diagnosis. Talk to a clinician about any health concern.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: Page scaffold

    @ViewBuilder
    private func page(icon: String, tint: Color, title: String,
                      @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 8)
            Image(systemName: icon)
                .font(.system(size: 52)).foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(title).font(.title.bold())
            VStack(alignment: .leading, spacing: 12) { content() }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 36)   // clear the page dots
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String, icon: String = "checkmark.circle.fill") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).font(.body)
            Text(text).font(.body)
        }
    }
}
