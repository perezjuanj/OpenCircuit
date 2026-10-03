import SwiftUI

/// First-run onboarding (#103, revised for the ring and the strap in #255). A short, dismissible,
/// re-openable flow that orients a new (non-developer) user before they land on the dashboard:
///   1. what OpenCircuit does — a RingConn ring or the Amazfit Helio Strap, local-first, written to
///      Apple Health, nothing leaves the device;
///   2. your wearable — pick the ring or the strap (the device in use is preselected and marked);
///      picking switches nothing, the device is changed in Profile ▸ Device;
///   3. getting started — the picked device's first steps (both, when nothing is picked): the ring
///      needs no official app or account (#106); the strap needs its key, plus decision 6's warnings;
///   4. permission priming — why Bluetooth + Apple Health are requested (the system prompts come
///      later, when the user first connects / authorizes Health — onboarding only explains them);
///   5. the not-affiliated / not-a-medical-device disclaimer, shared with Profile ▸ About. With the
///      strap picked and not set up, it ends by pushing the strap's setup screen.
///
/// Honest copy, no medical claims (the `trust` convention). Shown once on first launch via the
/// `OnboardingView.completedKey` flag (see ContentView), and re-openable from the profile screen's
/// About section. Pure presentation — it triggers no permission prompts and creates no central
/// itself; the decisions live in `OnboardingFlow`.
struct OnboardingView: View {
    /// Persisted flag: set once the user finishes/skips so the flow doesn't show again on launch.
    /// Versioned so a revised onboarding re-shows by bumping the suffix: v2 (#255) shows the device
    /// choice once to everyone who finished v1. The v1 key is left in place, never cleared.
    static let completedKey = "onboarding.completed.v2"

    /// Called when the user taps Get Started, Skip, or Done on the strap's setup — the caller
    /// persists the flag / dismisses.
    var onDone: () -> Void

    @State private var flow: OnboardingFlow
    @State private var page: OnboardingFlow.Page
    /// Onboarding-local: picking a card switches nothing (decision 51b).
    @State private var pick: ActiveDeviceChoice?
    @State private var showStrapSetup = false
    /// The live read (UserDefaults + Keychain) has run. It runs once, on appear, not in `init`: the
    /// presenter re-renders often (a live device streams), and each render re-runs `init` (review-256 F5).
    @State private var readInstalled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        _flow = State(initialValue: OnboardingFlow(installed: .unread))
        _page = State(initialValue: .welcome)
        _pick = State(initialValue: nil)
    }

    /// The one live read: what's in use, and the preselection unless the user has already picked.
    private func readInstalledOnce() {
        guard !readInstalled else { return }
        readInstalled = true
        let live = OnboardingFlow(installed: .live())
        flow = live
#if DEBUG && targetEnvironment(simulator)
        if let id = UserDefaults.standard.string(forKey: OnboardingFlow.debugPageArgumentKey),
           let start = live.debugStart(id) {
            page = start.page
            pick = start.pick
            return
        }
#endif
        if pick == nil { pick = live.preselection }
    }

    private var motion: Animation? { reduceMotion ? nil : .default }

    private var isLastPage: Bool { page == .finish }
    private var finish: OnboardingFlow.Finish { flow.finish(for: pick) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(OnboardingFlow.Page.welcome)
                    chooseWearable.tag(OnboardingFlow.Page.choose)
                    gettingStarted.tag(OnboardingFlow.Page.gettingStarted)
                    permissions.tag(OnboardingFlow.Page.permissions)
                    disclaimer.tag(OnboardingFlow.Page.finish)
                }
                // The dots are drawn below the pages, not over them, so a page's scrolling text
                // never runs under them at the largest text sizes.
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: 4) {
                    pageDots
                        .padding(.vertical, 8)
                    Button(isLastPage ? finish.title : "Continue") {
                        if let next = OnboardingFlow.Page(rawValue: page.rawValue + 1) {
                            withAnimation(motion) { page = next }
                        } else if finish == .setUpStrap {
                            showStrapSetup = true
                        } else {
                            onDone()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    // Skip, or "Set up later" when the last page ends on the strap's setup. Both finish
                    // like Get Started. Hidden (its slot kept) when the primary button already finishes.
                    let secondary = flow.secondary(on: page, pick: pick)
                    Button(secondary?.title ?? OnboardingFlow.Secondary.skip.title, action: onDone)
                        .font(.footnote)
                        .opacity(secondary == nil ? 0 : 1)
                        .disabled(secondary == nil)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear(perform: readInstalledOnce)
            // The strap's existing setup screen, unchanged: its "Save key and use the Helio Strap"
            // is what switches. Done finishes onboarding from outside it.
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
                if !showing { flow = OnboardingFlow(installed: .live()) }
            }
        }
    }

    // MARK: Pages

    private var welcome: some View {
        page(title: "Welcome to OpenCircuit") {
            headerIcon(Image(systemName: "waveform.path.ecg"), tint: .blue)
        } content: {
            ForEach(OnboardingCopy.welcome, id: \.self) { bullet($0) }
        }
    }

    private var chooseWearable: some View {
        page(title: "Your Wearable") {
            headerIcon(Image(keyline: .bluetooth), tint: Theme.accent)
        } content: {
            Text("Which one do you wear? Pick one to see its first steps.")
                .font(.body)
            ForEach(ActiveDeviceChoice.allCases, id: \.self) { card($0) }
            Text(DeviceCopy.oneAtATime)
                .font(.subheadline).foregroundStyle(.secondary)
            Text(OnboardingCopy.changeLater)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var gettingStarted: some View {
        page(title: "Getting Started") {
            headerIcon(Image(systemName: "1.circle"), tint: .indigo)
        } content: {
            if let note = flow.switchNote(for: pick) {
                Text(note).font(.subheadline.weight(.semibold))
            }
            if let pick {
                steps(for: pick)
            } else {
                // Nothing picked: every device's steps, each under its own heading.
                ForEach(ActiveDeviceChoice.allCases, id: \.self) { device in
                    deviceHeading(device)
                        .padding(.top, device == ActiveDeviceChoice.allCases.first ? 0 : 8)
                    steps(for: device)
                }
            }
        }
    }

    private var permissions: some View {
        page(title: "Permissions") {
            headerIcon(Image(systemName: "lock.shield"), tint: .teal)
        } content: {
            bullet(DeviceCopy.bluetoothPermission, icon: "dot.radiowaves.left.and.right")
            bullet("Apple Health — to save your metrics. You choose exactly what to share.",
                   icon: "heart.text.square")
            Text("You'll be asked for these the first time you connect and authorize Health.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var disclaimer: some View {
        page(title: "Good to Know") {
            headerIcon(Image(systemName: "info.circle"), tint: .orange)
        } content: {
            // The same constant as the About-section disclaimer in UserProfileSettingsView.
            Text(DeviceCopy.disclaimer)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: Device steps

    /// A device's first steps, its guide link after the first one, and where it's set up.
    @ViewBuilder
    private func steps(for device: ActiveDeviceChoice) -> some View {
        let steps = device.firstSteps
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            bullet(step)
            if index == 0, let guide = device.setupGuide {
                Link(guide.title, destination: guide.url)
                    .font(.body)
                    .padding(.leading, 28)
            }
        }
        if let hint = flow.setupHint(for: device, pick: pick) {
            Text(hint).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func deviceHeading(_ device: ActiveDeviceChoice) -> some View {
        Text(device.displayName)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Wearable cards

    private func card(_ device: ActiveDeviceChoice) -> some View {
        let selected = pick == device
        return Button {
            withAnimation(motion) { pick = device }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                KeylineGlyph(selected ? .circleCheck : .circle, size: 22, relativeTo: .body)
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(device.displayName).font(.body.weight(.semibold))
                        Spacer(minLength: 8)
                        if flow.inUse == device {
                            Text("In use").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(device.cardDetail)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        // On the Button itself, so VoiceOver has one element per card: device, detail, "In use".
        .accessibilityLabel(flow.cardAccessibilityLabel(device))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Page scaffold

    /// The page dots, outside the pages. VoiceOver reads the page and swipes up/down to turn it,
    /// as it does the system's dots.
    private var pageDots: some View {
        let pages = OnboardingFlow.Page.allCases
        return HStack(spacing: 8) {
            ForEach(pages, id: \.self) { item in
                Circle()
                    .fill(item == page ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page.rawValue + 1) of \(pages.count)")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            if let next = OnboardingFlow.Page(rawValue: page.rawValue + step) { withAnimation(motion) { page = next } }
        }
    }

    /// One page: scrolls when the text outgrows the screen (the largest accessibility sizes), and
    /// stays vertically centred when it doesn't. The scroll indicator flashes when a page appears,
    /// so the page reads as scrollable.
    private func page(title: String, @ViewBuilder header: () -> some View,
                      @ViewBuilder content: () -> some View) -> some View {
        let header = header()
        let content = content()
        return GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 8)
                    header
                    Text(title).font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 12) { content }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicatorsFlash(onAppear: true)
        }
    }

    private func headerIcon(_ image: Image, tint: Color) -> some View {
        image
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 52, height: 52)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
    }

    private func bullet(_ text: String, icon: String = "checkmark.circle.fill") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).font(.body)
            Text(text).font(.body)
        }
    }
}
