import SwiftUI
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

/// Amazfit Helio Strap setup (#215 decisions 4–7): what works, the key (paste-only, Keychain), the
/// Zepp coexistence warnings, then connect and the first sync.
struct HelioSetupView: View {
    @State private var choice = ActiveDeviceChoiceStore.shared
    /// Read only while the strap is the chosen device: a ring user browsing this screen never
    /// constructs the strap's driver (decision 1).
    private var connection: HelioConnection { HelioConnection.shared }
    @State private var keyText = ""
    @State private var editingKey = false
    @State private var saveError: String?
    @State private var confirmForget = false
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
                bullet("Nothing is sent to Zepp or any other server.")
            }

            Section {
                bullet(HelioStatus.keyOriginCopy)
                Link("How to get the key", destination: HelioStatus.keyGuideURL)
                bullet(HelioStatus.dontUnpairCopy)
                bullet(HelioStatus.zeppBluetoothCopy)
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
                    SecureField("32 characters, 0–9 and a–f", text: $keyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { keyText = first }
                    }
                    Text(keyHint).font(.caption).foregroundStyle(normalized == nil ? Color.secondary : Theme.accent)
                    Button(choice.isHelio ? "Save key and reconnect" : "Save key and use the Helio Strap") { saveAndConnect() }
                        .disabled(normalized == nil)
                    if hasKey { Button("Cancel", role: .cancel) { editingKey = false; keyText = "" } }
                }
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Key")
            } footer: {
                Text("Stored in this phone's Keychain only. It's never shown again, logged or exported. "
                     + "Spaces, colons and a leading 0x are fine.")
            }

            if choice.isHelio {
                Section("Status") {
                    HelioStatusRow(status: status)
                    if status.kind == .keyRejected || status.kind == .keyNeeded {
                        Link("Get the key again", destination: HelioStatus.keyGuideURL)
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
        }
        .navigationTitle("Amazfit Helio Strap")
        .navigationBarTitleDisplayMode(.inline)
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
