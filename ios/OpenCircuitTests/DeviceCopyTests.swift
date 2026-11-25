import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

/// Decision 51e: device copy is data. The composed text for today's two devices is pinned word for
/// word, and two guards over `allCases` keep a new device's copy complete and its own.
@MainActor
final class DeviceCopyTests: XCTestCase {
    // MARK: the list composer

    func testTheListComposerJoinsLikeTheAppsCopy() {
        XCTAssertEqual(DeviceCopy.list([]), "")
        XCTAssertEqual(DeviceCopy.list(["A"]), "A")
        XCTAssertEqual(DeviceCopy.list(["A", "B"]), "A or B")
        XCTAssertEqual(DeviceCopy.list(["A", "B", "C"]), "A, B or C", "no serial comma")
        XCTAssertEqual(DeviceCopy.list(["A", "B", "C"], "and"), "A, B and C")
    }

    // MARK: composed text, pinned word for word

    func testTheWelcomeLineIsUnchanged() {
        XCTAssertEqual(DeviceCopy.worksWith,
                       "OpenCircuit works with a RingConn ring (Gen 2, Gen 2 Air or Gen 3) or the Amazfit Helio Strap.")
    }

    func testTheBluetoothLineIsUnchanged() {
        XCTAssertEqual(DeviceCopy.bluetoothPermission, "Bluetooth — to find and connect to your ring or strap.")
    }

    func testTheDisclaimerIsUnchanged() {
        XCTAssertEqual(DeviceCopy.disclaimer,
                       "OpenCircuit is an independent, local-first app compatible with RingConn Gen 2, Gen 2 Air and "
                       + "Gen 3 smart rings and the Amazfit Helio Strap. It is not affiliated with, authorized, or "
                       + "endorsed by RingConn, JZ_Tech, Amazfit or Zepp Health; \"RingConn\", \"Amazfit\", \"Helio\" "
                       + "and \"Zepp\" are trademarks of their respective owners. OpenCircuit is not a medical device. "
                       + "Its readings are estimates for personal insight, not diagnosis. Talk to a clinician about any "
                       + "health concern.")
    }

    func testTheAccountBulletStatesTheStrapsKeyStepHonestly() {
        XCTAssertEqual(DeviceCopy.accounts,
                       "No subscription. The ring needs no account. The strap needs a Zepp account once: pairing it "
                       + "in the Zepp app has Zepp's servers create its key, and OpenCircuit reads it when you sign in "
                       + "with your Zepp email and password. After that, OpenCircuit talks only to the strap and "
                       + "syncing never signs in to Zepp.")
        // HELIO_KEY_EXTRACTION.md: the account, once, Zepp's servers create the key, the in-app sign-in's
        // email-and-password requirement, and syncing never signs in.
        for fact in ["Zepp account", "once", "Zepp's servers", "email and password", "never signs in"] {
            XCTAssertTrue(ActiveDeviceChoice.helioStrap.accountSentence.contains(fact), fact)
            XCTAssertTrue(HelioStatus.keyOriginCopy.contains(fact), "the key bullet: \(fact)")
        }
        XCTAssertFalse(DeviceCopy.accounts.contains("no cloud"), "the key step goes through Zepp's servers")
        // The in-app lookup shipped: the old absolute claim must not come back.
        XCTAssertFalse(HelioStatus.keyOriginCopy.contains("OpenCircuit never signs in to Zepp"))
        XCTAssertFalse(ActiveDeviceChoice.helioStrap.accountSentence.contains("which you copy out on a computer"))
        // The automated way is the only one onboarding and Before you start show (computer route = Troubleshooting).
        for text in [ActiveDeviceChoice.helioStrap.accountSentence, HelioStatus.keyOriginCopy] {
            for word in ["computer", "watchface", "snippet", "console"] { XCTAssertFalse(text.contains(word), word) }
        }
    }

    func testTheOneAtATimeLine() {
        XCTAssertEqual(DeviceCopy.oneAtATime,
                       "OpenCircuit uses one device at a time. Switching keeps each device's history on this phone, "
                       + "and only the device in use is searched for and connected.")
        XCTAssertFalse(DeviceCopy.oneAtATime.contains("both"), "no count of devices")
    }

    func testTheCardDetails() {
        XCTAssertEqual(ActiveDeviceChoice.ringConn.cardDetail, "RingConn Gen 2, Gen 2 Air or Gen 3. No account needed.")
        XCTAssertEqual(ActiveDeviceChoice.helioStrap.cardDetail, "Needs a one-time key from your Zepp account (see setup).")
    }

    func testTheKeyBulletIsOneConstantSharedWithTheSetupScreen() {
        XCTAssertEqual(HelioStatus.keyOriginCopy,
                       "The strap talks only to an app that knows its 16-byte key. Zepp's servers create the key once, "
                       + "when you pair the strap in the Zepp app. OpenCircuit gets it for you when you sign in once to "
                       + "your Zepp account with its email and password. Syncing never signs in to Zepp.")
        XCTAssertEqual(ActiveDeviceChoice.helioStrap.firstSteps.first, HelioStatus.keyOriginCopy, "by reference")
    }

    // MARK: Profile, per device

    func testProfileHealthConnectedLine() {
        XCTAssertEqual(ProfileDeviceCopy.healthWriting(.ringConn), "OpenCircuit is writing your ring's metrics into Apple Health.")
        XCTAssertEqual(ProfileDeviceCopy.healthWriting(.helioStrap), "OpenCircuit is writing your strap's metrics into Apple Health.")
    }

    func testProfileHealthSummary() {
        XCTAssertEqual(ProfileDeviceCopy.healthSummary(.ringConn),
                       "Write your ring's heart rate, HRV, SpO₂, temperature, sleep and more into Apple Health.")
        XCTAssertEqual(ProfileDeviceCopy.healthSummary(.helioStrap),
                       HelioHealthPolicy.writesHRV
                           ? "Write your strap's heart rate, HRV, SpO₂, temperature, sleep and more into Apple Health."
                           : "Write your strap's heart rate, SpO₂, temperature, sleep and more into Apple Health.")
    }

    func testTheStrapsHealthSummaryNamesHRVOnlyWhenTheStrapWritesIt() {
        // The strap's mirrored kinds decide it (HEALTHKIT_MAPPING "What the app writes").
        let writesHRV = HelioHealthPolicy.healthMirroredKinds().contains(.hrvSDNN)
        XCTAssertEqual(ProfileDeviceCopy.healthSummary(.helioStrap).contains("HRV"), writesHRV)
    }

    func testProfileSleepFocusLine() {
        XCTAssertEqual(ProfileDeviceCopy.sleepFocusNote(.ringConn),
                       "Add OpenCircuit to your Sleep Focus once, and turning that Focus off will trigger a ring "
                       + "history sync alongside the existing automatic syncs.")
        XCTAssertEqual(ProfileDeviceCopy.sleepFocusNote(.helioStrap),
                       "Add OpenCircuit to your Sleep Focus once, and turning that Focus off will trigger a strap "
                       + "history sync alongside the existing automatic syncs.")
    }

    func testProfileRemindersFooter() {
        XCTAssertEqual(ProfileDeviceCopy.remindersFooter(.ringConn),
                       "Reminders pause while the ring is on the charger or off your finger — it counts no steps there, "
                       + "so that time isn't treated as sitting still. Quiet hours and backoff use the same settings as "
                       + "health alerts above.")
        XCTAssertEqual(ProfileDeviceCopy.remindersFooter(.helioStrap),
                       "Quiet hours and backoff use the same settings as health alerts above.")
    }

    func testProfileExportAndAlertLines() {
        XCTAssertEqual(ProfileDeviceCopy.exportNote,
                       "Export all stored wearable data (HR, SpO₂, sleep, steps) as CSV or JSON for your own analysis. "
                       + "Data stays on your device unless you share it.")
        XCTAssertEqual(ProfileDeviceCopy.alertsDisclaimer,
                       "Note: OpenCircuit is not a medical device. These reminders are based on your wearable's sensor data only "
                       + "and are not a diagnosis. If you feel unwell, consult a qualified medical professional.")
    }

    // MARK: shared screens (#257)

    func testGoalsFootnoteNamesNoDeviceAppAndKeepsTheRingsAccuracyLineForTheRingOnly() {
        for device in ActiveDeviceChoice.allCases {
            let text = SharedScreenCopy.goalsFootnote(device)
            XCTAssertTrue(text.hasPrefix("\u{B9} Activity Score is an on-device estimate"), "\(device)")
            XCTAssertTrue(text.contains("not your device app's own number"), "\(device)")
            XCTAssertFalse(text.contains("RingConn"), "\(device): \(text)")
        }
        XCTAssertTrue(SharedScreenCopy.goalsFootnote(.ringConn)
            .hasSuffix("Elevated HR is not detected workout duration. Full accuracy follows the ring activity-payload decode."))
        XCTAssertTrue(SharedScreenCopy.goalsFootnote(.helioStrap).hasSuffix("Elevated HR is not detected workout duration."))
    }

    func testBackgroundRefreshAndExportEmptyStatesNameTheDeviceInUse() {
        XCTAssertEqual(SharedScreenCopy.backgroundRefreshLimited(.ringConn),
                       "iOS is limiting background activity. Turn on Settings ▸ General ▸ Background App Refresh so the "
                       + "ring can sync while the app is closed.")
        XCTAssertEqual(SharedScreenCopy.backgroundRefreshLimited(.helioStrap),
                       "iOS is limiting background activity. Turn on Settings ▸ General ▸ Background App Refresh so the "
                       + "strap can sync while the app is closed.")
        XCTAssertEqual(SharedScreenCopy.exportNoNights(.ringConn), "No recorded nights yet — sync your ring first.")
        XCTAssertEqual(SharedScreenCopy.exportNoNights(.helioStrap), "No recorded nights yet — sync your strap first.")
        XCTAssertEqual(SharedScreenCopy.exportNoSessions(.ringConn), "No sleep sessions recorded yet — sync your ring first.")
        XCTAssertEqual(SharedScreenCopy.exportNoSessions(.helioStrap), "No sleep sessions recorded yet — sync your strap first.")
    }

    /// The export holds every device's nights, so its caveats cover every device: the ring's stages
    /// are estimated on the phone, the strap's are its own, and only the ring has apnea figures.
    func testExportCaveatsCoverEveryDevice() {
        let text = SharedScreenCopy.exportCaveats
        XCTAssertTrue(text.hasPrefix("Sleep stages: "))
        for device in ActiveDeviceChoice.allCases {
            XCTAssertTrue(text.contains(device.sleepStagingNote), "\(device)")
            if let spo2 = device.overnightSpO2Note { XCTAssertTrue(text.contains(spo2), "\(device)") }
        }
        XCTAssertTrue(ActiveDeviceChoice.ringConn.sleepStagingNote.contains("sends no hypnogram"))
        XCTAssertFalse(ActiveDeviceChoice.helioStrap.sleepStagingNote.contains("ESTIMATES"),
                       "the strap's nights are staged by the strap, not estimated on the phone")
        XCTAssertNil(ActiveDeviceChoice.helioStrap.overnightSpO2Note, "only the ring's burst fills the osa columns")
        XCTAssertFalse(text.contains("MAC address"))
        XCTAssertTrue(text.hasSuffix("your wearable's Bluetooth address and your phone's name are never included."))
    }

    func testExportContentsSaysWhichDeviceTheMetadataDescribes() {
        let text = SharedScreenCopy.exportContents
        XCTAssertTrue(text.contains("measurements your wearable delivered"))
        XCTAssertTrue(text.contains("the model and firmware of the last ring connected (if any)"),
                      "the metadata block is the ring's only (`ExportBuilder.metadata`)")
        XCTAssertNil(text.range(of: "\\bstrap\\b", options: .regularExpression))
    }

    func testANightsDeviceIsTheFamilyThatOwnsIt() {
        for device in ActiveDeviceChoice.allCases {
            XCTAssertEqual(SharedScreenCopy.device(owning: device.ownershipFamily), device)
        }
        for family in DeviceOwnershipLog.Family.allCases {
            XCTAssertEqual(SharedScreenCopy.device(owning: family).ownershipFamily, family, "every family has a device")
        }
    }

    // MARK: the ownership family (decision 51e follow-through)

    func testEachDeviceRecordsItsOwnFamily() {
        XCTAssertEqual(ActiveDeviceChoice.ringConn.ownershipFamily, .ringConn)
        XCTAssertEqual(ActiveDeviceChoice.helioStrap.ownershipFamily, .zeppOS)
    }

    // MARK: guards over every device

    /// Every string a device's descriptor supplies, including the Profile lines built from it.
    private func copy(of device: ActiveDeviceChoice) -> [String] {
        [device.noun, device.modelPhrase, device.compatibilityPhrase, device.cardDetail, device.accountSentence,
         device.healthSummary, ProfileDeviceCopy.healthWriting(device), ProfileDeviceCopy.sleepFocusNote(device),
         ProfileDeviceCopy.remindersFooter(device), device.sleepStagingNote,
         SharedScreenCopy.goalsFootnote(device), SharedScreenCopy.backgroundRefreshLimited(device),
         SharedScreenCopy.exportNoNights(device), SharedScreenCopy.exportNoSessions(device)]
            + device.makers + device.trademarks + device.firstSteps
            + [device.remindersPauseNote, device.activityScoreAccuracyNote,
               device.overnightSpO2Note].compactMap { $0 }
    }

    func testEveryDeviceFillsEveryField() {
        for device in ActiveDeviceChoice.allCases {
            XCTAssertFalse(device.makers.isEmpty, "\(device)")
            XCTAssertFalse(device.trademarks.isEmpty, "\(device)")
            XCTAssertFalse(device.firstSteps.isEmpty, "\(device)")
            for text in copy(of: device) {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(device) has an empty field")
            }
        }
    }

    func testNoDevicesCopyNamesAnotherDevicesBrand() {
        for device in ActiveDeviceChoice.allCases {
            for other in ActiveDeviceChoice.allCases where other != device {
                for brand in other.makers + other.trademarks {
                    for text in copy(of: device) {
                        XCTAssertFalse(text.contains(brand), "\(device)'s copy names \(other)'s \(brand): \(text)")
                    }
                }
            }
        }
    }

    func testNoDevicesCopyUsesAnotherDevicesNoun() {
        for device in ActiveDeviceChoice.allCases {
            for other in ActiveDeviceChoice.allCases where other != device {
                for text in copy(of: device) {
                    XCTAssertNil(text.range(of: "\\b\(other.noun)\\b", options: [.regularExpression, .caseInsensitive]),
                                 "\(device)'s copy says \(other.noun): \(text)")
                }
            }
        }
        for text in [ProfileDeviceCopy.exportNote, ProfileDeviceCopy.alertsDisclaimer] {
            for device in ActiveDeviceChoice.allCases {
                XCTAssertNil(text.range(of: "\\b\(device.noun)\\b", options: .regularExpression),
                             "a line about every device's data names one: \(text)")
            }
        }
    }
}
