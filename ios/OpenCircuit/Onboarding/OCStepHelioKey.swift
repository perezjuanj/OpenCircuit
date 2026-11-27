//
//  OCStepHelioKey.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  The strap's key sheet: the app's one Zepp sign-in design. Onboarding opens it when the guide ends
//  on the Helio Strap and the strap has no key yet (Set Up Strap on the last step), starting on the
//  choose step. The strap's setup screen opens it straight on the sign-in step (`Entry.setupScreen`):
//  that screen already shows what the choose step would, and Cancel closes the sheet. One way is
//  shown either way: the in-app Zepp sign-in. The computer route (guide, snippet, paste) lives only
//  in the setup screen's small Troubleshooting section (the setup-shows-one-way rule).
//
//  No logic of its own: sign-in and device pick are `ZeppSignInCopy.lookUp` and the save is
//  `HelioSetupView.saveKeyAndUseStrap`, the same two the setup screen uses.
//

import SwiftUI
import ZeppAccountKit

/// The sheet's own copy. Everything else is the setup screen's (`HelioSetupView`, `ZeppSignInCopy`).
enum HelioKeySheetCopy {
    static let intro = "Your strap needs its 16-byte key from your Zepp account. OpenCircuit reads it once; "
        + "syncing never signs in to Zepp."
    static let troubleshootingLink = "Troubleshooting"
    static let troubleshootingNote = "Sign-in didn't work, or your Zepp account uses Google or Apple?"
    static let signingIn = "Signing in…"
}

struct HelioKeySheet: View {

    enum Mode: Hashable {
        case choose, signIn
    }

    /// Where the sheet was opened from.
    enum Entry: Hashable {
        /// Onboarding's last strap step: starts on choose; Troubleshooting opens the setup screen.
        case onboarding
        /// The strap's setup screen: starts on sign-in; Cancel closes the sheet, and the account
        /// limit points at that screen's own Troubleshooting section.
        case setupScreen
    }

    /// Called once the key is saved and the strap is in use.
    let onSaved: () -> Void
    /// "Done" without a key: set it up later.
    let onDone: () -> Void
    var lookup = ZeppAccountKeyLookup()
    let entry: Entry

    @State private var mode: Mode

    init(onSaved: @escaping () -> Void, onDone: @escaping () -> Void, initialMode: Mode = .choose,
         entry: Entry = .onboarding) {
        self.onSaved = onSaved
        self.onDone = onDone
        self.entry = entry
        _mode = State(initialValue: Self.startMode(entry, requested: initialMode))
    }

    /// The setup screen always opens on sign-in; onboarding starts where it asks (choose by default).
    static func startMode(_ entry: Entry, requested: Mode) -> Mode {
        entry == .setupScreen ? .signIn : requested
    }

    /// The account-type limit for where the sheet sits: onboarding's Troubleshooting is at the bottom
    /// of this sheet; from the setup screen it's at the bottom of that screen.
    static func accountLimit(for entry: Entry) -> String {
        entry == .setupScreen ? ZeppSignInCopy.accountLimit : ZeppSignInCopy.accountLimitShort
    }

    /// Cancel on the sign-in step: back to choose in onboarding, closes the sheet from the setup screen.
    private func cancelSignIn() {
        clear()
        if entry == .setupScreen { onDone() } else { go(.choose) }
    }

    @State private var expanded: Set<String> = []
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorText: String?
    @State private var choices: [ZeppAccountDevice] = []
    @State private var showSetupScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.24) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                Group {
                    switch mode {
                    case .choose: chooseBody
                    case .signIn: signInBody
                    }
                }
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 20)), removal: .opacity))
            }
            .background(OCColor.sheet.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            // The full setup screen: Troubleshooting (guide, snippet, paste) sits at its bottom.
            .navigationDestination(isPresented: $showSetupScreen) {
                HelioSetupView()
                    .toolbar(.visible, for: .navigationBar)
                    .preferredColorScheme(.dark)
            }
            .onChange(of: showSetupScreen) { _, showing in
                // Back from the setup screen with a key saved there: done.
                if !showing, HelioKeyStore.shared.hasKey, ActiveDeviceChoiceStore.shared.isHelio { onSaved() }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSigningIn)
        .animation(motion, value: mode)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        switch mode {
        case .choose:
            HStack(spacing: 9) {
                OCAssetImage(name: ActiveDeviceChoice.helioStrap.onboardingAssetName)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text(ActiveDeviceChoice.helioStrap.displayName)
                    .font(.system(.callout, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                capsuleButton("Done", action: onDone)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            // Sheet chrome stops growing at xxxLarge; the body below scrolls at any size.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

        case .signIn:
            HStack(spacing: 12) {
                capsuleButton("Cancel", action: cancelSignIn)
                    .disabled(isSigningIn)
                Text(ZeppSignInCopy.title)
                    .font(.system(.callout, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                // Balances Cancel so the title stays centred.
                capsuleButton("Cancel") {}.hidden().accessibilityHidden(true)
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    private func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.14), in: Capsule(style: .continuous))
        }
        .buttonStyle(OCPressStyle())
    }

    // MARK: Choose

    private var chooseBody: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(HelioKeySheetCopy.intro)
                    .font(.subheadline)
                    .foregroundStyle(OCColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                PillButton(title: ZeppSignInCopy.buttonTitle) { go(.signIn) }
                    .padding(.top, 16)

                Text(ZeppSignInCopy.accountLimitShort)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                VStack(spacing: 8) {
                    disclosure("What you get", HelioSetupView.whatYouGet)
                    disclosure("Before you start", HelioSetupView.beforeYouStart)
                    disclosure("Good to know", HelioSetupView.goodToKnow)
                }
                .padding(.top, 16)

                Text(HelioSetupView.keyStorageNote)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                troubleshooting
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    /// Small print, last: the way to the computer route on the full setup screen.
    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HelioKeySheetCopy.troubleshootingNote)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
            Button(HelioKeySheetCopy.troubleshootingLink) { showSetupScreen = true }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OCColor.brandHi)
        }
    }

    private func disclosure(_ title: String, _ lines: [String]) -> some View {
        OCDisclosureRow(title: title, lines: lines, isExpanded: expanded.contains(title)) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
            }
        }
    }

    // MARK: Sign in

    private var signInBody: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.accountLimit(for: entry))
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 13)
                    Text(ZeppSignInCopy.pairFirst)
                }
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 0) {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.vertical, 16)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(.vertical, 16)
                        .onSubmit(submit)
                }
                .font(.callout)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(isSigningIn)

                PillButton(title: isSigningIn ? HelioKeySheetCopy.signingIn : ZeppSignInCopy.signInButton,
                           isEnabled: canSubmit, action: submit)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !choices.isEmpty { deviceChoices }

                Text(ZeppSignInCopy.privacy + " " + ZeppSignInCopy.mayStopWorking)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                troubleshooting
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// More than one candidate on the account: the user picks (never the first one silently).
    private var deviceChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ZeppSignInCopy.pickHeader(for: choices))
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Color.white)
            // By position, not address: Zepp can list two entries with the same (or an empty) address,
            // and a shared id lets SwiftUI hand a tap to the wrong row.
            ForEach(Array(choices.enumerated()), id: \.offset) { _, device in
                Button { save(device) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ZeppSignInCopy.deviceName(device))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Text(ZeppSignInCopy.deviceDetail(device))
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(OCPressStyle())
            }
            Text(ZeppSignInCopy.pickFooter(for: choices))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private var canSubmit: Bool {
        !isSigningIn && !password.isEmpty && !email.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let email = email.trimmingCharacters(in: .whitespaces)
        let password = password
        isSigningIn = true
        errorText = nil
        choices = []
        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                let pick = try await ZeppSignInCopy.lookUp(lookup, email: email, password: password)
                self.password = ""
                switch pick {
                case .use(let device): save(device)
                case .ask(let devices): choices = devices
                }
            } catch {
                errorText = ZeppSignInCopy.message(for: error)
            }
        }
    }

    private func save(_ device: ZeppAccountDevice) {
        let key = device.authKeyHex
        clear()
        if let error = HelioSetupView.saveKeyAndUseStrap(key) {
            errorText = error
        } else {
            onSaved()
        }
    }

    private func clear() {
        password = ""
        choices = []
    }

    private func go(_ next: Mode) {
        withAnimation(motion) { mode = next }
    }
}

// MARK: - Disclosure row

struct OCDisclosureRow: View {
    let title: String
    let lines: [String]
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .tracking(-0.1)
                        .foregroundStyle(Color.white)
                    Spacer(minLength: 0)
                    KeylineGlyph(.chevronRight, size: 12, relativeTo: .caption)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(OCPressStyle())
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(OCColor.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
