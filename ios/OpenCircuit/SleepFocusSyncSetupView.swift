import SwiftUI
import UIKit

/// In-app guidance for the one system-owned step required to enable `SleepFocusSyncFilter`.
/// Apple provides a public URL for the app's own Settings page, but no public URL that deep-links
/// directly to Settings > Focus. Keep the handoff App-Store-safe and explain the remaining taps.
struct SleepFocusSyncSetupView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Automatic sync when you wake up")
                        .font(.headline)
                } icon: {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(.indigo)
                }
                Text("After this one-time setup, turning off Sleep Focus starts a short ring "
                     + "history sync and Apple Health flush. Your other automatic syncs continue "
                     + "to work as before.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Set up once") {
                setupStep(
                    number: 1,
                    title: "Open iOS Settings",
                    detail: "Use the button below, then return to the main Settings screen."
                )
                setupStep(
                    number: 2,
                    title: "Open your Sleep Focus",
                    detail: "Tap Focus, then Sleep, then Add Filter."
                )
                setupStep(
                    number: 3,
                    title: "Add OpenCircuit",
                    detail: "Choose OpenCircuit, leave “Sync when this Focus ends” on, then tap Add."
                )
            }

            Section {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label("Open iOS Settings", systemImage: "arrow.up.forward.app")
                }
                .accessibilityHint("Opens OpenCircuit's page in the iOS Settings app")

                Text("iOS does not allow apps to open the Focus page directly. Settings opens to "
                     + "OpenCircuit; go back to the main Settings screen, then follow steps 2 and 3.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sleep Focus Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setupStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.indigo, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)")
    }
}
