import SwiftUI
import UIKit
import ZeppKit

/// Profile ▸ Device (#215, decision 1): which wearable the app drives. One at a time; switching
/// keeps both devices' stored history.
struct DeviceChoiceView: View {
    @State private var choice = ActiveDeviceChoiceStore.shared
    @State private var confirmRing = false

    var body: some View {
        List {
            Section {
                row(.ringConn, detail: ActiveDeviceChoice.ringConn.cardDetail) {
                    if !choice.isRing { confirmRing = true }
                }
                NavigationLink {
                    HelioSetupView()
                } label: {
                    rowLabel(.helioStrap, detail: ActiveDeviceChoice.helioStrap.cardDetail)
                }
            } footer: {
                Text(DeviceCopy.oneAtATime)
            }
        }
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Switch to the RingConn ring?", isPresented: $confirmRing, titleVisibility: .visible) {
            Button("Use the RingConn ring") { DeviceSwitcher.activate(.ringConn) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(choice.current.displayName) disconnects. Its history stays on this phone.")
        }
    }

    private func row(_ device: ActiveDeviceChoice, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(device, detail: detail) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ device: ActiveDeviceChoice, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if choice.current == device {
                Text("In use").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Amazfit Helio Strap setup (#215 decisions 4–7): what works, the Zepp coexistence warnings, the key
/// (read once from an email-and-password Zepp account through `ZeppSignInSheet`; the computer guide,
/// snippet and paste field sit in the small Troubleshooting section at the bottom; Keychain either
/// way), then connect and the first sync.
struct HelioSetupView: View {
    @State private var choice = ActiveDeviceChoiceStore.shared
    /// Read only while the strap is the chosen device: a ring user browsing this screen never
    /// constructs the strap's driver (decision 1).
    private var connection: HelioConnection { HelioConnection.shared }
    @State private var keyText = ""
    @State private var editingKey = false
    @State private var saveError: String?
    @State private var snippetCopied = false
    @State private var confirmForget = false
    @State private var showZeppSignIn = false
    /// Re-read after every key action: the Keychain isn't observable.
    @State private var hasKey = HelioKeyStore.shared.hasKey
    @State private var keyRejected = HelioKeyStore.shared.isRejected

    private var normalized: String? { HelioKeyText.normalized(keyText) }

    private var status: HelioStatus {
        HelioStatus.from(connection: connection.state, phase: connection.session?.phase, hasKey: hasKey,
                         keyRejected: keyRejected, hasSavedStrap: HelioConnection.hasSavedStrap,
                         endedBusy: connection.endedBusy)
    }

    var body: some View {
        List {
            Section("What you get") {
                bullet("Heart rate, HRV, steps, sleep stages, SpO₂, respiratory rate and skin temperature from the strap's own history, "
                       + "saved on this phone and written to Apple Health.")
                bullet("The strap's HRV is labelled RMSSD, like the ring's, based on Amazfit's statement that its devices "
                       + "measure HRV as RMSSD. Apple Health files it under its only HRV type (SDNN).")
                bullet("Stress and PAI are shown in the app only. Apple Health has no type for them.")
                bullet("Find My Strap, a short buzz, and the strap's alarms.")
                bullet(Self.noServerNote)
            }

            Section {
                bullet(HelioStatus.keyOriginCopy)
                bullet(HelioStatus.dontUnpairCopy)
                bullet(HelioStatus.zeppCoexistCopy)
            } header: {
                Text("Before you start")
            }

            Section {
                if hasKey && !editingKey {
                    LabeledContent("Key", value: keyRejected ? "Saved, rejected by the strap" : "Saved")
                    // Coming back from the ring: the saved key is used as is, never shown or re-pasted.
                    if !choice.isHelio && !keyRejected {
                        Button("Use the Helio Strap") {
                            DeviceSwitcher.activate(.helioStrap)
                            connection.connect()
                        }
                    }
                    Button("Replace Key") { editingKey = true; keyText = "" }
                    Button("Forget Key", role: .destructive) { confirmForget = true }
                } else {
                    Button(ZeppSignInCopy.buttonTitle) { showZeppSignIn = true }
                    Text(ZeppSignInCopy.accountLimit).font(.caption).foregroundStyle(.secondary)
                    if hasKey { Button("Cancel", role: .cancel) { editingKey = false; keyText = "" } }
                }
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Key")
            } footer: {
                Text(Self.keyStorageNote)
            }

            if choice.isHelio {
                Section("Status") {
                    HelioStatusRow(status: status)
                    if status.kind == .keyRejected || status.kind == .keyNeeded {
                        Button("Get the key again") { showZeppSignIn = true }
                    }
                    // Not offered for a rejected key: reconnecting would not retry it (decision 7).
                    if [.strapBusy, .notFound, .disconnected].contains(status.kind) {
                        Button("Try again") { connection.reconnectNow() }
                    }
                    if let session = connection.session, session.ready {
                        if let last = session.lastSyncAt {
                            LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let text = session.syncStatus { Text(text).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Section("Good to know") {
                bullet(Self.firstSyncNote)
                bullet(Self.reinstallNote)
                bullet(Self.firmwareNote)
                bullet(Self.iPhoneOnlyNote)
            }

            troubleshooting
        }
        .navigationTitle("Amazfit Helio Strap")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showZeppSignIn) {
            ZeppSignInSheet { key in
                keyText = key
                saveAndConnect()
            }
        }
        .confirmationDialog("Forget the key?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Key", role: .destructive) {
                HelioKeyStore.shared.forget()
                refreshKeyState()
                if choice.isHelio { connection.reconnectNow() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("History stops syncing until a key is saved again. Stored history stays.")
        }
    }

    static let firstSyncNote = "The first sync brings in only what the strap still holds, often about a week. "
        + "History then builds up day by day."
    static let reinstallNote = "OpenCircuit's own history lives on this phone and is removed if you delete the app. "
        + "What was already written to Apple Health stays there."
    static let firmwareNote = "Firmware updates for the strap are done in the Zepp app. OpenCircuit doesn't update firmware."
    static let iPhoneOnlyNote = "OpenCircuit is iPhone only."
    static let keyStorageNote = "Stored in this phone's Keychain only. It's never shown again, logged or exported."

    /// The computer route (`docs/HELIO_KEY_EXTRACTION.md` Methods 1–2), for accounts the sign-in can't
    /// use (Google/Apple/other sign-in) or when Zepp's sign-in breaks. Kept last and small: the button
    /// in the Key section is the way we show.
    static let troubleshootingIntro = "Zepp account uses Google, Apple or another sign-in, or the sign-in above "
        + "doesn't work? Copy the key from your Zepp account on a computer, then paste it here."
    static let snippetNote = "Paste the snippet in the browser console on watchface.zepp.com while signed in on a "
        + "computer. Universal Clipboard can carry it to a Mac."
    static let pasteNote = "Spaces, colons and a leading 0x are fine."
    /// Syncing never contacts a server; the only exception is the optional, one-time Zepp account lookup.
    static let noServerNote = "Syncing sends nothing to Zepp or any other server. The only time OpenCircuit contacts "
        + "Zepp is if you use \u{201C}\(ZeppSignInCopy.buttonTitle)\u{201D}, once."

    /// Small print, at the bottom: the guide, the console snippet and the paste field.
    private var troubleshooting: some View {
        Section {
            Text(Self.troubleshootingIntro).font(.footnote).foregroundStyle(.secondary)
            Link("How to get the key", destination: HelioStatus.keyGuideURL).font(.footnote)
            Button(snippetCopied ? "Copied" : "Copy key snippet") { copySnippet() }.font(.footnote)
            Text(Self.snippetNote).font(.caption).foregroundStyle(.secondary)
            SecureField("Paste the key: 32 characters, 0–9 and a–f", text: $keyText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first { keyText = first }
            }
            .controlSize(.small)
            Text(keyHint).font(.caption).foregroundStyle(normalized == nil ? Color.secondary : Theme.accent)
            Button(choice.isHelio ? "Save pasted key and reconnect" : "Save pasted key and use the Helio Strap") {
                saveAndConnect()
            }
            .font(.footnote)
            .disabled(normalized == nil)
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text(Self.pasteNote)
        }
    }

    private func copySnippet() {
        UIPasteboard.general.string = HelioKeySnippet.text
        snippetCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            snippetCopied = false
        }
    }

    private var keyHint: String {
        if normalized != nil { return "Looks like a key." }
        let digits = keyText.filter { $0.isHexDigit && $0.isASCII }.count
        return keyText.isEmpty ? "Paste the key from the guide." : "Not a key yet: \(digits) of 32 hex characters."
    }

    private func saveAndConnect() {
        do {
            guard try HelioKeyStore.shared.save(pasted: keyText) else {
                saveError = "That isn't a 32-character key."
                return
            }
        } catch {
            saveError = "Couldn't save the key in the Keychain."
            return
        }
        keyText = ""
        editingKey = false
        saveError = nil
        refreshKeyState()
        if choice.isHelio {
            connection.reconnectNow()
        } else {
            DeviceSwitcher.activate(.helioStrap)
            connection.connect()
        }
    }

    private func refreshKeyState() {
        hasKey = HelioKeyStore.shared.hasKey
        keyRejected = HelioKeyStore.shared.isRejected
    }

    private func bullet(_ text: String) -> some View {
        Text(text).font(.subheadline)
    }
}

/// One status line: a tone dot, the title and the detail.
struct HelioStatusRow: View {
    let status: HelioStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title).font(.subheadline.weight(.semibold))
                if let detail = status.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch status.tone {
        case .neutral: return .secondary
        case .working: return Theme.accent
        case .good: return Theme.steps
        case .attention: return .orange
        }
    }
}
