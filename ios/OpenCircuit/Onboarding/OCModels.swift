//
//  OCModels.swift
//  OpenCircuit — Onboarding (gradient direction)
//
//  The redesigned flow's step state. Devices are `ActiveDeviceChoice` and their copy is the
//  device descriptor's (`DeviceCopy.swift`, decision 51e); the decisions (preselection, "In use",
//  how the guide ends) are `OnboardingFlow`'s, so a new wearable needs no edit here.
//

import SwiftUI

// MARK: - Device art

extension ActiveDeviceChoice {
    /// The product image on the device panel. Exhaustive: a new device needs its art.
    var onboardingAssetName: String {
        switch self {
        case .ringConn: return "RingConnRing"
        case .helioStrap: return "HelioStrap"
        }
    }

    /// Product photos are unreadable at pill size, so the pill and the "Using the …?" row use a glyph.
    var onboardingGlyph: KeylineIcon {
        switch self {
        case .ringConn: return .circle
        case .helioStrap: return .activity
        }
    }

    /// The device's first steps as (title, detail) pairs, from the descriptor.
    var onboardingSteps: [(title: String, detail: String)] {
        zip(firstStepTitles, firstSteps).map { (title: $0.0, detail: $0.1) }
    }
}

// MARK: - Flow state

@MainActor
final class OnboardingViewModel: ObservableObject {

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, device, setup, permissions, legal

        var id: Int { rawValue }

        /// 1-based position, for the dash indicator.
        var position: Int { rawValue + 1 }

        /// `OnboardingFlow`'s page for this step (the screenshot hook and the tests speak in pages).
        init(_ page: OnboardingFlow.Page) {
            switch page {
            case .welcome: self = .welcome
            case .choose: self = .device
            case .gettingStarted: self = .setup
            case .permissions: self = .permissions
            case .finish: self = .legal
            }
        }
    }

    @Published private(set) var step: Step
    /// What's in use, read once on appear (`OnboardingView`), and re-read after the strap's setup.
    @Published var flow: OnboardingFlow
    /// `nil` = nothing picked yet: Continue stays disabled on the device step until a panel is tapped.
    /// A fresh install starts here (51d): a default ring is not a ring in use.
    @Published private(set) var device: ActiveDeviceChoice?

    init(initialStep: Step = .welcome, flow: OnboardingFlow = OnboardingFlow(installed: .unread),
         device: ActiveDeviceChoice? = nil) {
        self.step = initialStep
        self.flow = flow
        self.device = device
    }

    var totalSteps: Int { Step.allCases.count }
    var isLastStep: Bool { step == .legal }

    /// How the last step ends for the pick: Get Started, or Set Up Strap when the strap isn't set up.
    var finish: OnboardingFlow.Finish { flow.finish(for: device) }

    var primaryCTATitle: String { isLastStep ? finish.title : "Continue" }

    var footnote: String {
        switch step {
        case .welcome: return "No subscription · No OpenCircuit account"
        case .device: return OnboardingCopy.changeLater
        case .setup, .permissions: return "Step \(step.position) of \(totalSteps)"
        case .legal: return "Open this guide again any time in Profile ▸ About."
        }
    }

    /// The device whose steps the setup step shows: the pick, else the first device.
    var shownSetupDevice: ActiveDeviceChoice { device ?? ActiveDeviceChoice.allCases[0] }

    /// Every device but the one whose steps are showing, as "Using the …?" rows.
    var otherSetupDevices: [ActiveDeviceChoice] { ActiveDeviceChoice.allCases.filter { $0 != shownSetupDevice } }

    var canAdvance: Bool {
        if step == .device { return device != nil }
        return true
    }

    // MARK: Actions

    /// Picking a panel (or a "Using the …?" row) switches nothing (decision 51b); it only chooses
    /// which steps show and how the guide ends.
    func select(_ choice: ActiveDeviceChoice) { device = choice }

    func changeDevice() { step = .device }

    func advance() {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func start(at step: Step, device: ActiveDeviceChoice?) {
        self.step = step
        self.device = device
    }
}
