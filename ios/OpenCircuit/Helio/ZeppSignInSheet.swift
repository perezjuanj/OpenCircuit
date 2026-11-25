import SwiftUI
import ZeppAccountKit

/// Copy for the optional Zepp account key lookup (`ZeppAccountKit`). The account-type limit is the
/// load-bearing line: Zepp accounts made with Google, Apple or another sign-in have no password the
/// lookup can use, so those people need the guide's computer method.
enum ZeppSignInCopy {
    static let buttonTitle = "Get the key from my Zepp account"
    static let title = "Zepp Account"
    static let signInButton = "Sign in and get the key"

    static let accountLimit = "Works only if you sign in to Zepp with an email and password. If your Zepp account "
        + "uses Google, Apple, Facebook or another sign-in, this can't sign in: use the computer method in "
        + "\u{201C}How to get the key\u{201D} instead."
    static let pairFirst = "Pair the strap in the Zepp app first. The key only exists after pairing."
    static let privacy = "Your email and password go straight from this phone to Zepp, once, to read the strap's key. "
        + "OpenCircuit doesn't save them and signs out of Zepp right after. Syncing never contacts Zepp."
    static let mayStopWorking = "This uses the same sign-in as the Zepp app. If Zepp changes it, it can stop "
        + "working; the computer method in the guide still works."
    static let pickHeader = "More than one device on this account"
    static let pickFooter = "Pick the Helio Strap. The address ending is shown so you can tell devices apart."

    static func message(for error: Error) -> String {
        switch error as? ZeppAccountError {
        case .credentialsRejected?:
            return "Zepp didn't accept that email and password. If you sign in to Zepp with Google, Apple or "
                + "another account, use the computer method in the guide."
        case .noKeyOnAccount?:
            return "Signed in, but no device on this Zepp account has a key. Pair the strap in the Zepp app, "
                + "then try again."
        case .network?:
            return "Couldn't reach Zepp. Check the connection and try again."
        case .unexpectedResponse?, nil:
            return "Zepp answered in a way OpenCircuit doesn't understand. Zepp may have changed its sign-in; "
                + "use the computer method in the guide."
        }
    }

    static func deviceName(_ device: ZeppAccountDevice) -> String {
        device.isHelioStrap ? "Amazfit Helio Strap" : "Other Amazfit device"
    }

    static func deviceDetail(_ device: ZeppAccountDevice) -> String {
        "Address ending \(device.macSuffix)" + (device.isActive ? " · in use in Zepp" : "")
    }
}

/// Email + password → the strap's key, handed to `onKey` (the setup screen saves it to the Keychain
/// and connects, exactly like a pasted key). Nothing here is persisted.
struct ZeppSignInSheet: View {
    let onKey: (String) -> Void
    var lookup = ZeppAccountKeyLookup()

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var choices: [ZeppAccountDevice] = []

    private var canSubmit: Bool {
        !working && !password.isEmpty && !email.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ZeppSignInCopy.accountLimit).font(.subheadline)
                    Text(ZeppSignInCopy.pairFirst).font(.subheadline)
                }

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Text(ZeppSignInCopy.signInButton)
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text(ZeppSignInCopy.privacy + " " + ZeppSignInCopy.mayStopWorking)
                }

                if !choices.isEmpty {
                    Section {
                        ForEach(choices, id: \.macAddress) { device in
                            Button {
                                finish(with: device)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ZeppSignInCopy.deviceName(device)).font(.body)
                                    Text(ZeppSignInCopy.deviceDetail(device)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(ZeppSignInCopy.pickHeader)
                    } footer: {
                        Text(ZeppSignInCopy.pickFooter)
                    }
                }
            }
            .navigationTitle(ZeppSignInCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { clear(); dismiss() }
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func submit() {
        let email = email
        let password = password
        working = true
        errorText = nil
        choices = []
        Task {
            defer { working = false }
            do {
                let devices = try await lookup.devicesWithKeys(email: email, password: password)
                self.password = ""
                // One device, or exactly one Helio Strap among several: no question to ask.
                let straps = devices.filter(\.isHelioStrap)
                if devices.count == 1 {
                    finish(with: devices[0])
                } else if straps.count == 1 {
                    finish(with: straps[0])
                } else {
                    choices = devices
                }
            } catch {
                errorText = ZeppSignInCopy.message(for: error)
            }
        }
    }

    private func finish(with device: ZeppAccountDevice) {
        let key = device.authKeyHex
        clear()
        onKey(key)
        dismiss()
    }

    private func clear() {
        password = ""
        choices = []
    }
}
