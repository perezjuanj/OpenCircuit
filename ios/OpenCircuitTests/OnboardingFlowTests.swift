import XCTest
import ZeppKit
@testable import OpenCircuit

/// #255 (decision 51): the first run's decisions, which device is preselected and marked "In use",
/// what the last button does, and the "You're using X now" line, plus the copy that must not fork
/// from its sources. All values are synthetic.
@MainActor
final class OnboardingFlowTests: XCTestCase {
    private typealias Installed = OnboardingFlow.Installed

    private func flow(_ choice: ActiveDeviceChoice = .ringConn, ring: Bool = false, key: Bool = false) -> OnboardingFlow {
        OnboardingFlow(installed: Installed(persistedChoice: choice, hasSavedRing: ring, hasStrapKey: key))
    }

    // MARK: preselection (51d)

    func testAFreshInstallPreselectsNothing() {
        XCTAssertNil(flow().preselection, "the ring default on a fresh install is not a ring in use")
        XCTAssertNil(flow().inUse)
    }

    func testASavedRingWithTheRingChosenIsPreselected() {
        XCTAssertEqual(flow(.ringConn, ring: true).preselection, .ringConn)
        XCTAssertEqual(flow(.ringConn, ring: true).inUse, .ringConn)
    }

    func testTheStrapChosenIsPreselectedWithOrWithoutASavedRing() {
        XCTAssertEqual(flow(.helioStrap).preselection, .helioStrap)
        XCTAssertEqual(flow(.helioStrap, ring: true).preselection, .helioStrap)
        XCTAssertEqual(flow(.helioStrap, ring: true, key: true).preselection, .helioStrap)
        XCTAssertEqual(flow(.helioStrap, ring: true).inUse, .helioStrap)
    }

    func testASavedKeyWithTheRingChosenAndASavedRingPreselectsTheRing() {
        XCTAssertEqual(flow(.ringConn, ring: true, key: true).preselection, .ringConn)
    }

    func testTheViewsPlaceholderBeforeTheLiveReadClaimsNothing() {
        // OnboardingView starts on this and reads the phone once, on appear (review-256 F5).
        let unread = OnboardingFlow(installed: .unread)
        XCTAssertNil(unread.preselection)
        XCTAssertNil(unread.inUse)
        XCTAssertNil(unread.switchNote(for: .helioStrap))
    }

    func testASavedKeyAndNothingElsePreselectsNothing() {
        XCTAssertNil(flow(.ringConn, key: true).preselection, "a key alone doesn't make the strap the device in use")
        XCTAssertNil(flow(.ringConn, key: true).inUse)
    }

    // MARK: the last button (51b)

    func testTheStrapPickedAndNotSetUpEndsOnTheStrapsSetup() {
        XCTAssertEqual(flow().finish(for: .helioStrap), .setUpStrap, "no key, ring default")
        XCTAssertEqual(flow(.ringConn, ring: true, key: true).finish(for: .helioStrap), .setUpStrap,
                       "a key but the ring chosen: the switch is still to make")
        XCTAssertEqual(flow(.helioStrap).finish(for: .helioStrap), .setUpStrap, "the strap chosen but its key forgotten")
        XCTAssertEqual(OnboardingFlow.Finish.setUpStrap.title, "Set Up Strap")
    }

    func testTheStrapPickedAndSetUpGetsStarted() {
        XCTAssertEqual(flow(.helioStrap, key: true).finish(for: .helioStrap), .getStarted)
        XCTAssertEqual(flow(.helioStrap, ring: true, key: true).finish(for: .helioStrap), .getStarted)
    }

    func testTheRingOrNoPickGetsStarted() {
        for installed in [flow(), flow(.ringConn, ring: true), flow(.helioStrap), flow(.helioStrap, key: true)] {
            XCTAssertEqual(installed.finish(for: .ringConn), .getStarted)
            XCTAssertEqual(installed.finish(for: nil), .getStarted)
        }
        XCTAssertEqual(OnboardingFlow.Finish.getStarted.title, "Get Started")
    }

    // MARK: the secondary button (steer 1 item 5)

    func testSetUpLaterAppearsOnlyWhereTheLastPageEndsOnTheStrapsSetup() {
        let fresh = flow()
        XCTAssertEqual(fresh.secondary(on: .finish, pick: .helioStrap), .setUpLater)
        XCTAssertEqual(OnboardingFlow.Secondary.setUpLater.title, "Set Up Later")
        XCTAssertEqual(flow(.ringConn, ring: true, key: true).secondary(on: .finish, pick: .helioStrap), .setUpLater)
        XCTAssertNil(fresh.secondary(on: .finish, pick: .ringConn), "Get Started already finishes")
        XCTAssertNil(fresh.secondary(on: .finish, pick: nil))
        XCTAssertNil(flow(.helioStrap, key: true).secondary(on: .finish, pick: .helioStrap), "the strap is set up")
        for page in OnboardingFlow.Page.allCases where page != .finish {
            for pick in [nil, ActiveDeviceChoice.ringConn, .helioStrap] {
                XCTAssertEqual(fresh.secondary(on: page, pick: pick), .skip, "Skip as today on \(page)")
            }
        }
        XCTAssertEqual(OnboardingFlow.Secondary.skip.title, "Skip")
    }

    // MARK: "You're using X now"

    func testTheSwitchLineAppearsOnlyWhenThePickDiffersFromTheDeviceInUse() {
        // The guide ends on the strap's setup, whose save button switches (review-256 F3).
        let strapSetupSwitches = "You're using the RingConn ring now. The strap's setup at the end of this guide "
            + "switches to the strap; you can switch back in Profile ▸ Device."
        XCTAssertEqual(flow(.ringConn, ring: true).finish(for: .helioStrap), .setUpStrap)
        XCTAssertEqual(flow(.ringConn, ring: true).switchNote(for: .helioStrap), strapSetupSwitches)
        XCTAssertEqual(flow(.ringConn, ring: true, key: true).switchNote(for: .helioStrap), strapSetupSwitches,
                       "a saved key: the setup screen's one-tap \"Use the Helio Strap\" switches too")
        // The guide ends with Get Started: switching is Profile ▸ Device's.
        XCTAssertEqual(flow(.helioStrap, key: true).finish(for: .ringConn), .getStarted)
        XCTAssertEqual(flow(.helioStrap, key: true).switchNote(for: .ringConn),
                       "You're using the Amazfit Helio Strap now. To switch, go to Profile ▸ Device.")
        XCTAssertEqual(flow(.helioStrap).switchNote(for: .ringConn),
                       "You're using the Amazfit Helio Strap now. To switch, go to Profile ▸ Device.")
        XCTAssertNil(flow(.ringConn, ring: true).switchNote(for: .ringConn), "the pick is the device in use")
        XCTAssertNil(flow(.helioStrap).switchNote(for: .helioStrap))
        XCTAssertNil(flow(.ringConn, ring: true).switchNote(for: nil), "nothing picked")
        XCTAssertNil(flow().switchNote(for: .helioStrap), "a fresh install has no device in use")
        XCTAssertNil(flow().switchNote(for: .ringConn))
        XCTAssertNil(flow(.ringConn, key: true).switchNote(for: .ringConn), "a key alone is no device in use")
    }

    func testTheStrapSetupHintSaysWhereTheStrapIsSetUp() {
        XCTAssertEqual(flow().setupHint(for: .helioStrap, pick: .helioStrap),
                       "Set up the strap at the end of this guide, or later in Profile ▸ Device.")
        XCTAssertEqual(flow().setupHint(for: .helioStrap, pick: nil), "Set it up in Profile ▸ Device.")
        XCTAssertNil(flow(.helioStrap, key: true).setupHint(for: .helioStrap, pick: .helioStrap), "already set up")
        XCTAssertNil(flow(.helioStrap, key: true).setupHint(for: .helioStrap, pick: nil))
        for pick in [nil, ActiveDeviceChoice.ringConn] {
            XCTAssertNil(flow().setupHint(for: .ringConn, pick: pick), "the ring is set up on Today")
        }
    }

    // MARK: copy and constants

    func testTheCompletionFlagIsVersionTwo() {
        XCTAssertEqual(OnboardingView.completedKey, "onboarding.completed.v2")
    }

    func testTheSharedDisclaimerNamesEveryCompanyAndTrademark() {
        let text = DeviceCopy.disclaimer
        for name in ["RingConn", "JZ_Tech", "Amazfit", "Zepp Health", "not a medical device",
                     "\"RingConn\"", "\"Amazfit\"", "\"Helio\"", "\"Zepp\"", "Gen 2 Air", "Gen 3", "Helio Strap"] {
            XCTAssertTrue(text.contains(name), "missing \(name)")
        }
        XCTAssertFalse(text.contains("compatible with the RingConn Gen 2 smart ring"), "the old ring-only wording")
    }

    func testTheStrapBulletsAreHelioStatussOwnCopy() {
        let steps = ActiveDeviceChoice.helioStrap.firstSteps
        XCTAssertEqual(Array(steps.suffix(2)), [HelioStatus.dontUnpairCopy, HelioStatus.zeppCoexistCopy])
        XCTAssertEqual(steps.first, HelioStatus.keyOriginCopy)
        for step in steps {
            XCTAssertFalse(step.contains("computer") || step.contains("watchface"), "onboarding shows only the in-app sign-in")
        }
    }

    func testTheRingStepsAreTodaysFour() {
        let steps = ActiveDeviceChoice.ringConn.firstSteps
        XCTAssertEqual(steps.count, 4)
        XCTAssertTrue(steps[0].hasPrefix("No RingConn account and no official app needed"))
        XCTAssertTrue(steps[3].hasPrefix("Charge the ring as usual"))
    }

    func testEachCardReadsAsTheDeviceAndItsDetail() {
        let ring = flow(.ringConn, ring: true)
        XCTAssertEqual(ring.cardAccessibilityLabel(.ringConn),
                       "RingConn ring. RingConn Gen 2, Gen 2 Air or Gen 3. No account needed. In use")
        XCTAssertEqual(ring.cardAccessibilityLabel(.helioStrap),
                       "Amazfit Helio Strap. Needs a one-time key from your Zepp account (see setup).")
    }

    func testTheSharedPagesHaveNoRingOnlyWording() {
        for text in [DeviceCopy.welcomeLead, DeviceCopy.bluetoothPurpose, DeviceCopy.bluetoothPermission] {
            XCTAssertNil(text.range(of: "your ring\\b(?! or)", options: .regularExpression), text)
            XCTAssertFalse(text.contains("RingConn Gen 2's"), text)
        }
        XCTAssertTrue(DeviceCopy.welcomeLead.contains("your ring or strap"))
        XCTAssertTrue(DeviceCopy.bluetoothPurpose.contains("your ring or strap"))
    }

    // MARK: the redesigned flow's copy

    func testEveryDeviceHasATitleForEachFirstStep() {
        for device in ActiveDeviceChoice.allCases {
            XCTAssertEqual(device.firstStepTitles.count, device.firstSteps.count, "\(device)")
            XCTAssertEqual(device.onboardingSteps.map(\.detail), device.firstSteps, "\(device)")
        }
    }

    /// The strap's key comes from a Zepp sign-in and Health can sync to iCloud, so onboarding makes
    /// no absolute "nothing leaves the phone" or "no account" claim (#387's sweep).
    func testOnboardingMakesNoAbsoluteLocalOrAccountClaim() {
        let model = OnboardingViewModel()
        let footnotes = OnboardingViewModel.Step.allCases.map { step -> String in
            model.start(at: step, device: nil)
            return model.footnote
        }
        let texts = [OnboardingCopy.welcomeHeadline, DeviceCopy.welcomeLead, OnboardingCopy.permissionsLead,
                     OnboardingCopy.permissionsNote] + OnboardingCopy.ticks + footnotes
        for text in texts {
            for banned in ["Nowhere else", "Nothing is sent", "No account needed", "keeps every reading"] {
                XCTAssertFalse(text.contains(banned), "\(banned) in: \(text)")
            }
        }
        XCTAssertFalse(OnboardingCopy.ticks.contains("No account"))
        XCTAssertEqual(DeviceCopy.disclaimer, DeviceCopy.notAffiliated + " " + DeviceCopy.notMedical,
                       "onboarding's two panels are exactly Profile ▸ About's disclaimer")
    }

    /// The permissions step prompts on Continue, so its copy must say so, not "when you connect".
    func testThePermissionsCopyMatchesWhenTheStepPrompts() {
        XCTAssertTrue(OnboardingCopy.permissionsLead.contains("Continue"))
        XCTAssertFalse(OnboardingCopy.permissionsLead.contains("first time you connect"))
    }

    // MARK: the redesigned flow's state

    func testAFreshInstallPicksNothingAndTheDeviceStepWaitsForAPick() {
        let model = OnboardingViewModel(initialStep: .device, flow: flow())
        XCTAssertNil(model.device)
        XCTAssertFalse(model.canAdvance)
        model.select(.helioStrap)
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(model.shownSetupDevice, .helioStrap)
        XCTAssertEqual(model.otherSetupDevices, ActiveDeviceChoice.allCases.filter { $0 != .helioStrap })
    }

    func testTheLastStepEndsOnTheStrapsSetupOnlyWhenTheStrapIsntSetUp() {
        let model = OnboardingViewModel(initialStep: .legal, flow: flow(), device: .helioStrap)
        XCTAssertEqual(model.primaryCTATitle, "Set Up Strap")
        model.flow = flow(.helioStrap, key: true)
        XCTAssertEqual(model.primaryCTATitle, "Get Started")
        model.select(.ringConn)
        XCTAssertEqual(model.primaryCTATitle, "Get Started")
        model.start(at: .permissions, device: .helioStrap)
        XCTAssertEqual(model.primaryCTATitle, "Continue")
    }

    func testEveryStepMapsToItsFlowPage() {
        for page in OnboardingFlow.Page.allCases {
            XCTAssertEqual(OnboardingViewModel.Step(page).rawValue, page.rawValue, "\(page)")
        }
    }

#if DEBUG && targetEnvironment(simulator)
    func testTheScreenshotHookMapsEveryId() {
        let fresh = flow()
        let cases: [(String, OnboardingFlow.Page, ActiveDeviceChoice?)] = [
            ("welcome", .welcome, nil), ("choose", .choose, nil), ("choose-strap", .choose, .helioStrap),
            ("start-ring", .gettingStarted, .ringConn), ("start-strap", .gettingStarted, .helioStrap),
            ("permissions", .permissions, nil), ("last-ring", .finish, .ringConn), ("last-strap", .finish, .helioStrap),
        ]
        for (id, page, pick) in cases {
            let start = fresh.debugStart(id)
            XCTAssertEqual(start?.page, page, id)
            XCTAssertEqual(start?.pick, pick, id)
        }
        XCTAssertNil(fresh.debugStart("nope"))
        XCTAssertEqual(flow(.ringConn, ring: true).debugStart("choose")?.pick, .ringConn, "plain ids keep the preselection")
    }
#endif

    // MARK: no side effects (#142, decision 1)

    func testReadingThePreselectionCreatesNoCentralAndSwitchesNothing() throws {
        let standard = UserDefaults.standard
        let choiceBefore = standard.object(forKey: ActiveDeviceChoiceStore.key) as? String
        let logBefore = standard.data(forKey: DeviceOwnershipStore.key)
        let persistedBefore = ActiveDeviceChoiceStore.persisted()
        let centralBefore = HelioConnection.shared.hasCentral
        XCTAssertFalse(centralBefore, "the test host has the ring chosen, so the strap has no central")

        // A stub, never the real keychain: the orchestrator's unsigned runs fail every SecItem call.
        let live = OnboardingFlow(installed: .live(keyStore: StubKeyStore(hasKey: true)))
        XCTAssertTrue(live.installed.hasStrapKey)
        _ = live.preselection
        for pick in [nil, ActiveDeviceChoice.ringConn, .helioStrap] {
            _ = live.finish(for: pick)
            _ = live.switchNote(for: pick)
            for device in ActiveDeviceChoice.allCases { _ = live.setupHint(for: device, pick: pick) }
            for page in OnboardingFlow.Page.allCases { _ = live.secondary(on: page, pick: pick) }
        }
        _ = OnboardingFlow(installed: .live(keyStore: StubKeyStore(hasKey: false)))

        XCTAssertEqual(HelioConnection.shared.hasCentral, centralBefore, "no central was created")
        XCTAssertFalse(HelioConnection.shared.hasCentral)
        XCTAssertEqual(ActiveDeviceChoiceStore.persisted(), persistedBefore, "nothing was switched")
        XCTAssertEqual(standard.object(forKey: ActiveDeviceChoiceStore.key) as? String, choiceBefore)
        XCTAssertEqual(standard.data(forKey: DeviceOwnershipStore.key), logBefore, "the ownership log is untouched")
    }

    func testTheLiveReadAsksTheKeyStoreAndNothingElse() {
        XCTAssertTrue(Installed.live(keyStore: StubKeyStore(hasKey: true)).hasStrapKey)
        XCTAssertFalse(Installed.live(keyStore: StubKeyStore(hasKey: false)).hasStrapKey)
    }

    func testTheLiveReadUsesThePersistedChoiceFromItsDefaults() throws {
        let suite = "test.OnboardingFlowTests.choice"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let keys = StubKeyStore(hasKey: false)

        XCTAssertEqual(Installed.live(defaults: defaults, keyStore: keys).persistedChoice, .ringConn)
        defaults.set(ActiveDeviceChoice.helioStrap.rawValue, forKey: ActiveDeviceChoiceStore.key)
        let strap = Installed.live(defaults: defaults, keyStore: keys)
        XCTAssertEqual(strap.persistedChoice, .helioStrap)
        XCTAssertFalse(strap.hasStrapKey)
        XCTAssertNil(defaults.data(forKey: DeviceOwnershipStore.key), "a read records no ownership entry")
    }
}

/// A key store with no keychain behind it (shared rules: no test may need the real keychain to reach
/// its assertions). `hasKey` comes from `load()` through the protocol extension.
@MainActor
private final class StubKeyStore: HelioKeyStoring {
    private let key: ZeppAuthKey?
    init(hasKey: Bool) {
        key = hasKey ? HelioKeyText.parse("00112233445566778899aabbccddeeff") : nil
    }
    func load() -> ZeppAuthKey? { key }
    func save(pasted text: String) throws -> Bool { false }
    func forget() {}
    var isRejected: Bool { false }
    func markRejected() {}
}
