import Foundation

/// The first run's decisions (#255, decision 51), kept out of the view so they're tested on their
/// own: which wearable is preselected and marked "In use", what the last page's button does, and
/// when to say the pick isn't the device in use.
///
/// Picking a card in onboarding switches nothing. Only the strap's setup screen ("Save key and use
/// the Helio Strap") and Profile ▸ Device switch, through `DeviceSwitcher` (decision 1). Building a
/// flow reads UserDefaults and the Keychain only: no driver, no `CBCentralManager` (#142), and never
/// `ActiveDeviceChoiceStore.shared`, whose init can write the ownership log.
struct OnboardingFlow: Equatable {
    /// What this phone already has, read with no side effects.
    struct Installed: Equatable {
        /// `ActiveDeviceChoiceStore.persisted()`: `.ringConn` when nothing was ever chosen.
        var persistedChoice: ActiveDeviceChoice
        /// `RingScanner.hasSavedRingToRestore`: a ring was connected on this phone before.
        var hasSavedRing: Bool
        /// The strap's key is in the Keychain.
        var hasStrapKey: Bool

        /// Before the live read: nothing in use, nothing picked. `OnboardingView` replaces it on appear.
        static let unread = Installed(persistedChoice: .ringConn, hasSavedRing: false, hasStrapKey: false)

        @MainActor
        static func live(defaults: UserDefaults = .standard, keyStore: (any HelioKeyStoring)? = nil) -> Installed {
            Installed(persistedChoice: ActiveDeviceChoiceStore.persisted(defaults),
                      hasSavedRing: RingScanner.hasSavedRingToRestore,
                      hasStrapKey: (keyStore ?? HelioKeyStore.shared).hasKey)
        }
    }

    enum Page: Int, CaseIterable {
        case welcome, choose, gettingStarted, permissions, finish
    }

    /// The last page's primary button.
    enum Finish: Equatable {
        case getStarted
        /// Pushes the strap's existing setup screen inside onboarding.
        case setUpStrap

        var title: String {
            switch self {
            case .getStarted: return "Get Started"
            case .setUpStrap: return "Set Up Strap"
            }
        }
    }

    /// The quiet button under the primary one. Both finish onboarding exactly as Get Started does:
    /// the flag is set, nothing switches and nothing is constructed.
    enum Secondary: Equatable {
        case skip
        /// On the last page when it ends on the strap's setup, so finishing doesn't require opening it.
        case setUpLater

        var title: String {
            switch self {
            case .skip: return "Skip"
            case .setUpLater: return "Set Up Later"
            }
        }
    }

    let installed: Installed

    /// The device in use, if it's been set up (51d). A fresh install's ring default is not a ring in
    /// use, and a saved key alone doesn't make the strap the device in use.
    var inUse: ActiveDeviceChoice? {
        switch installed.persistedChoice {
        case .helioStrap: return .helioStrap
        case .ringConn: return installed.hasSavedRing ? .ringConn : nil
        }
    }

    /// The card picked when onboarding opens: the device in use, else none.
    var preselection: ActiveDeviceChoice? { inUse }

    /// The strap is chosen and has its key, so there's nothing left to set up.
    var strapIsSetUp: Bool { installed.persistedChoice == .helioStrap && installed.hasStrapKey }

    /// Exhaustive over the devices (review-256b N3): a new device must say how the guide ends for it.
    func finish(for pick: ActiveDeviceChoice?) -> Finish {
        switch pick {
        case nil, .ringConn: return .getStarted
        case .helioStrap: return strapIsSetUp ? .getStarted : .setUpStrap
        }
    }

    /// Skip on every page but the last; on the last, "Set up later" only when it ends on the strap's
    /// setup, and nothing otherwise (its primary button already finishes).
    func secondary(on page: Page, pick: ActiveDeviceChoice?) -> Secondary? {
        guard page == .finish else { return .skip }
        return finish(for: pick) == .setUpStrap ? .setUpLater : nil
    }

    /// Shown on Getting started when the pick isn't the device in use.
    /// When the guide ends on the picked device's setup, that setup is what switches (review-256 F3):
    /// its save button activates the device through `DeviceSwitcher`.
    func switchNote(for pick: ActiveDeviceChoice?) -> String? {
        guard let pick, let inUse, pick != inUse else { return nil }
        let using = "You're using the \(inUse.displayName) now."
        switch finish(for: pick) {
        case .getStarted:
            return using + " To switch, go to Profile ▸ Device."
        case .setUpStrap:
            return using + " The \(pick.noun)'s setup at the end of this guide switches to the \(pick.noun); "
                + "you can switch back in Profile ▸ Device."
        }
    }

    /// Under a device's first steps: where it's set up, while it isn't yet. `pick` is nil when every
    /// device's steps are shown.
    func setupHint(for device: ActiveDeviceChoice, pick: ActiveDeviceChoice?) -> String? {
        switch device {
        case .ringConn:
            return nil   // the ring sets itself up on Today (Scan & connect)
        case .helioStrap:
            guard !strapIsSetUp else { return nil }
            return pick == .helioStrap ? "Set up the strap at the end of this guide, or later in Profile ▸ Device."
                                       : "Set it up in Profile ▸ Device."
        }
    }

    /// What VoiceOver reads for a card: the device, then its detail.
    func cardAccessibilityLabel(_ device: ActiveDeviceChoice) -> String {
        let base = "\(device.displayName). \(device.cardDetail)"
        return inUse == device ? base + " In use" : base
    }

#if DEBUG && targetEnvironment(simulator)
    /// Screenshot hook (#255): `-OCOnboardingPage <id>` opens on that page with that pick. Simulator
    /// Debug builds only, like `DemoData`; never in Release.
    static let debugPageArgumentKey = "OCOnboardingPage"

    func debugStart(_ id: String) -> (page: Page, pick: ActiveDeviceChoice?)? {
        switch id {
        case "welcome": return (.welcome, preselection)
        case "choose": return (.choose, preselection)
        case "choose-strap": return (.choose, .helioStrap)
        case "start-ring": return (.gettingStarted, .ringConn)
        case "start-strap": return (.gettingStarted, .helioStrap)
        case "permissions": return (.permissions, preselection)
        case "last-ring": return (.finish, .ringConn)
        case "last-strap": return (.finish, .helioStrap)
        default: return nil
        }
    }
#endif
}

/// Onboarding's own copy. Device copy is the device's (`ActiveDeviceChoice` fields, `DeviceCopy`),
/// so a new device needs no edit here.
enum OnboardingCopy {
    static var welcome: [String] {
        [
            DeviceCopy.worksWith,
            "It reads your wearable's metrics over Bluetooth — heart rate, HRV, SpO₂, sleep, skin "
                + "temperature and more.",
            "It's local-first: your data stays on your device and is written only to Apple Health. "
                + "Nothing is sent to any server.",
            DeviceCopy.accounts,
        ]
    }

    static let changeLater = "You can change it later in Profile ▸ Device."
}
