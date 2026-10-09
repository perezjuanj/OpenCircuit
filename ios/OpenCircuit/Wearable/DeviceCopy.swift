import Foundation
import OpenCircuitKit
import ZeppKit

/// Every piece of user-facing copy that names a device or depends on one (decision 51e). Each field
/// is an exhaustive `switch` with no `default:`, so a new `ActiveDeviceChoice` case doesn't compile
/// until its copy is written. Shared surfaces compose over `allCases` (`DeviceCopy`); device-specific
/// ones read the active device's field.
extension ActiveDeviceChoice {
    /// The short noun: "your ring", "the strap".
    var noun: String {
        switch self {
        case .ringConn: return "ring"
        case .helioStrap: return "strap"
        }
    }

    /// The models, as onboarding's welcome names them ("works with … or …").
    var modelPhrase: String {
        switch self {
        case .ringConn: return "a RingConn ring (Gen 2, Gen 2 Air or Gen 3)"
        case .helioStrap: return "the Amazfit Helio Strap"
        }
    }

    /// The models, as the not-affiliated disclaimer names them ("compatible with … and …").
    var compatibilityPhrase: String {
        switch self {
        case .ringConn: return "RingConn Gen 2, Gen 2 Air and Gen 3 smart rings"
        case .helioStrap: return "the Amazfit Helio Strap"
        }
    }

    /// One line under the device's name, on the onboarding card and in Profile ▸ Device.
    var cardDetail: String {
        switch self {
        case .ringConn: return "RingConn Gen 2, Gen 2 Air or Gen 3. No account needed."
        case .helioStrap: return "Needs a one-time key from your Zepp account (see setup)."
        }
    }

    /// What the device needs besides OpenCircuit, for onboarding's welcome. The strap's facts are
    /// `docs/HELIO_KEY_EXTRACTION.md`'s: the key comes from the Zepp account the strap is paired to,
    /// once, and every method needs a computer; OpenCircuit never signs in to Zepp.
    var accountSentence: String {
        switch self {
        case .ringConn: return "The ring needs no account."
        case .helioStrap:
            return "The strap needs a Zepp account once: pairing it in the Zepp app has Zepp's servers create its key, "
                + "which you copy out on a computer. After that, OpenCircuit talks only to the strap and never signs "
                + "in to Zepp."
        }
    }

    /// The companies OpenCircuit isn't affiliated with, for this device.
    var makers: [String] {
        switch self {
        case .ringConn: return ["RingConn", "JZ_Tech"]
        case .helioStrap: return ["Amazfit", "Zepp Health"]
        }
    }

    /// The device's trademarks, unquoted.
    var trademarks: [String] {
        switch self {
        case .ringConn: return ["RingConn"]
        case .helioStrap: return ["Amazfit", "Helio", "Zepp"]
        }
    }

    /// The first steps onboarding shows for this device, in order.
    var firstSteps: [String] {
        switch self {
        case .ringConn:
            return [
                "No RingConn account and no official app needed — OpenCircuit connects to your ring on its own, "
                    + "even a brand-new ring straight out of the box.",
                "If the official RingConn app is installed, fully close it (swipe it away) before using "
                    + "OpenCircuit — only one app can talk to the ring at a time.",
                "Keep your phone nearby — especially overnight — so OpenCircuit can capture your full night of "
                    + "sleep and skin-temperature data.",
                "Charge the ring as usual; OpenCircuit picks up where it left off.",
            ]
        case .helioStrap:
            // `HelioSetupView`'s "Before you start", all three by reference.
            return [
                HelioStatus.keyOriginCopy,
                HelioStatus.dontUnpairCopy,
                HelioStatus.zeppBluetoothCopy,
            ]
        }
    }

    /// A guide link shown after the first step, if the device has one.
    var setupGuide: (title: String, url: URL)? {
        switch self {
        case .ringConn: return nil
        case .helioStrap: return ("How to get the key", HelioStatus.keyGuideURL)
        }
    }

    /// Profile ▸ Apple Health, before Health is connected: what this device writes. Matches the code:
    /// the strap's mirrored kinds are `HelioHealthPolicy.healthMirroredKinds()`, so its HRV is named
    /// only while `HelioHealthPolicy.writesHRV` is on.
    var healthSummary: String {
        switch self {
        case .ringConn:
            return "Write your ring's heart rate, HRV, SpO₂, temperature, sleep and more into Apple Health."
        case .helioStrap:
            let hrv = HelioHealthPolicy.writesHRV ? ", HRV" : ""
            return "Write your strap's heart rate\(hrv), SpO₂, temperature, sleep and more into Apple Health."
        }
    }

    /// Profile ▸ Reminders: why reminders pause, for a device whose signals pause them. Nil when none do.
    var remindersPauseNote: String? {
        switch self {
        case .ringConn:
            return "Reminders pause while the ring is on the charger or off your finger — it counts no steps "
                + "there, so that time isn't treated as sitting still."
        case .helioStrap: return nil
        }
    }

    /// The Goals footnote's last line: what the Activity Score still waits on for this device. Nil
    /// when nothing is pending: the ring's activity payload is only partly decoded, while the strap's
    /// steps come from its own activity records.
    var activityScoreAccuracyNote: String? {
        switch self {
        case .ringConn: return "Full accuracy follows the ring activity-payload decode."
        case .helioStrap: return nil
        }
    }

    /// Data Export: where this device's nights' sleep stages come from. The ring sends no hypnogram,
    /// so its nights are staged on the phone (`SleepStaging`); the strap stages its own nights, and a
    /// night it did not stage is not stored (`HelioSleepSelection`, decision 13).
    var sleepStagingNote: String {
        switch self {
        case .ringConn:
            return "A RingConn ring sends no hypnogram, so OpenCircuit ESTIMATES its nights' stages on this "
                + "phone: stage totals approximate the RingConn app's, but the placement of individual cycles "
                + "is not validated."
        case .helioStrap:
            return "The Helio Strap stages its own nights, and the export carries the stages it sent."
        }
    }

    /// Data Export: the caveat on this device's overnight SpO₂ (apnea) figures, if it has any. Only
    /// the ring's `0x48` assessment burst fills the `osa*` columns (`LocalStore.applyOSASummary`,
    /// called from `RingSession`), so a strap night has no such figures and no caveat.
    var overnightSpO2Note: String? {
        switch self {
        case .ringConn:
            return "On ring nights, the overnight lowest SpO₂, time below 90 % and ODI are EXPERIMENTAL "
                + "estimates; only the average SpO₂ is validated (±1 %) against the RingConn app."
        case .helioStrap: return nil
        }
    }
}

/// Copy on screens every device's data reaches (#257): Today, Activity, Sleep, Data Export and
/// Background Activity. A line about what the ACTIVE device does takes it; a line about stored data,
/// which can hold every device's, takes nothing and composes over `allCases`.
enum SharedScreenCopy {
    /// Today and Activity ▸ Goals footnote. "Not your device app's own" matches the readiness card
    /// (`WellnessBalanceCardView`).
    static func goalsFootnote(_ device: ActiveDeviceChoice) -> String {
        let base = "\u{B9} Activity Score is an on-device estimate — the weighted attainment of your step, "
            + "active-calorie & elevated-HR goals, not your device app's own number. Elevated HR counts time "
            + "at or above half your age-estimated maximum heart rate while you are moving (steps around it, "
            + "or a recorded workout), so a raised pulse while sitting still doesn't count. Active calories "
            + "use those same periods and count only energy above resting, which goes to Health as Resting "
            + "Energy; steps remain the calorie fallback. Elevated HR is not detected workout duration."
        return device.activityScoreAccuracyNote.map { base + " " + $0 } ?? base
    }

    /// Background Activity, when iOS limits Background App Refresh. Both devices sync on the app's
    /// background wakes, each only while chosen (docs/BACKGROUND_SYNC.md; B.5 is the strap).
    static func backgroundRefreshLimited(_ device: ActiveDeviceChoice) -> String {
        "iOS is limiting background activity. Turn on Settings ▸ General ▸ Background App Refresh so the "
            + "\(device.noun) can sync while the app is closed."
    }

    /// Data Export, "One night", with no night stored yet: syncing the device in use fills it.
    static func exportNoNights(_ device: ActiveDeviceChoice) -> String {
        "No recorded nights yet — sync your \(device.noun) first."
    }

    /// Data Export, "New only", with no night stored yet.
    static func exportNoSessions(_ device: ActiveDeviceChoice) -> String {
        "No sleep sessions recorded yet — sync your \(device.noun) first."
    }

    /// Data Export: what a file holds. The rows are every device's (see `ProfileDeviceCopy.exportNote`),
    /// but the device metadata is the ring's only: `ExportBuilder.metadata` fills `ringModel`/`ringFirmware`
    /// from `RingMetadataStore`, which is blank when no ring was ever connected.
    static let exportContents = "Each export carries the raw timestamped measurements your wearable delivered "
        + "— heart rate, HRV, SpO₂, respiratory rate, skin temperature, step deltas — plus one row per sleep "
        + "session: bedtime and wake times, the per-epoch sleep stages, the overnight SpO₂ (apnea) figures, and "
        + "a coverage measurement showing how much of the night this app currently holds. Every section is "
        + "labelled measured, derived or diagnostic, and the file records the app build, the model and "
        + "firmware of the last ring connected (if any), and which timezone its timestamps are in."

    /// Data Export: the caveats, over every device, because one file can hold every device's nights.
    /// No device's Bluetooth address is exported: `RingMetadataStore` caches no MAC-derived bytes
    /// (`ExportBuilder.metadata`), and nothing of the strap's identity is read into the export.
    static var exportCaveats: String {
        let all = ActiveDeviceChoice.allCases
        return (["Sleep stages:"] + all.map(\.sleepStagingNote) + all.compactMap(\.overnightSpO2Note)
            + ["Nothing leaves this device unless you share or save the file yourself, and your wearable's "
                + "Bluetooth address and your phone's name are never included."])
            .joined(separator: " ")
    }

    /// The device that recorded a night of the given family. The sleep card's caveats name it, which
    /// after a switch need not be the device in use (decision 28a: the device you went to bed with
    /// keeps the night).
    static func device(owning family: DeviceOwnershipLog.Family) -> ActiveDeviceChoice {
        ActiveDeviceChoice.allCases.first { $0.ownershipFamily == family } ?? .ringConn
    }
}

/// Copy composed over every device, so a new case joins it with no edit here.
enum DeviceCopy {
    /// "A", "A or B", "A, B or C" (no serial comma, like the rest of the app's copy).
    static func list(_ items: [String], _ conjunction: String = "or") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " \(conjunction) " + items[items.count - 1]
        }
    }

    static let all = ActiveDeviceChoice.allCases

    /// Onboarding's welcome: which devices OpenCircuit works with.
    static var worksWith: String { "OpenCircuit works with \(list(all.map(\.modelPhrase)))." }

    /// Onboarding's welcome: the subscription and account bullet.
    /// "No cloud" isn't here: the local-first bullet says nothing is sent to any server, and next to the
    /// strap's account step it would read as covering the key too.
    static var accounts: String { (["No subscription."] + all.map(\.accountSentence)).joined(separator: " ") }

    /// Onboarding's permissions page.
    static var bluetoothPermission: String { "Bluetooth — to find and connect to your \(list(all.map(\.noun)))." }

    /// `DeviceChoiceView`'s footer, also on onboarding's "Your wearable" page.
    static let oneAtATime = "OpenCircuit uses one device at a time. Switching keeps each device's history on this "
        + "phone, and only the device in use is searched for and connected."

    /// The not-affiliated and not-a-medical-device text, shared by onboarding's last page and
    /// Profile ▸ About so they can't drift apart. Names match the README's (#225).
    static var disclaimer: String {
        let marks = all.flatMap(\.trademarks).map { "\"\($0)\"" }
        let markVerb = marks.count == 1 ? "is a trademark of its respective owner"
                                        : "are trademarks of their respective owners"
        return "OpenCircuit is an independent, local-first app compatible with \(list(all.map(\.compatibilityPhrase), "and")). "
            + "It is not affiliated with, authorized, or endorsed by \(list(all.flatMap(\.makers))); "
            + "\(list(marks, "and")) \(markVerb). OpenCircuit is not a medical device. Its readings are estimates "
            + "for personal insight, not diagnosis. Talk to a clinician about any health concern."
    }
}

/// Profile's device lines (decision 51e), each a pure function of the device or of nothing, so both
/// devices' text is pinned by tests. A line about what the ACTIVE device does takes it; a line about
/// stored history, which can hold every device's, takes nothing.
enum ProfileDeviceCopy {
    /// Apple Health, connected.
    static func healthWriting(_ device: ActiveDeviceChoice) -> String {
        "OpenCircuit is writing your \(device.noun)'s metrics into Apple Health."
    }

    /// Apple Health, not connected yet.
    static func healthSummary(_ device: ActiveDeviceChoice) -> String { device.healthSummary }

    /// Sleep Focus: the Focus-off run syncs the chosen device (`SleepFocusSyncFilter`).
    static func sleepFocusNote(_ device: ActiveDeviceChoice) -> String {
        "Add OpenCircuit to your Sleep Focus once, and turning that Focus off will trigger a \(device.noun) "
            + "history sync alongside the existing automatic syncs."
    }

    /// Reminders' footer.
    static func remindersFooter(_ device: ActiveDeviceChoice) -> String {
        let shared = "Quiet hours and backoff use the same settings as health alerts above."
        return device.remindersPauseNote.map { $0 + " " + shared } ?? shared
    }

    /// Data export: the export reads every device's stored rows (no device predicate in
    /// `LocalStore.samplesDescriptor`, `stepSamplesDescriptor` or `sleepSummaries`).
    static let exportNote = "Export all stored wearable data (HR, SpO₂, sleep, steps) as CSV or JSON "
        + "for your own analysis. Data stays on your device unless you share it."

    /// The medical disclaimer under Health alerts (`UserProfileSettingsView.medicalDisclaimer`). Both
    /// devices' syncs run the alert pass (decision 37).
    static let alertsDisclaimer = "Note: OpenCircuit is not a medical device. These reminders are based on your "
        + "wearable's sensor data only and are not a diagnosis. If you feel unwell, consult a "
        + "qualified medical professional."
}
