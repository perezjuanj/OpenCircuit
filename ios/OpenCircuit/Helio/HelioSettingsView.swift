import SwiftUI
import ZeppKit

// The strap's own settings (#228 measurement, #229 workout detection, #230 alerts): read from the
// strap and changed on the strap, one setting per user action, through `ZeppSettingsEditor`
// (ZEPP_PROTOCOL.md §17.8: read the setting and its parent, validate, write ONE entry echoing the
// version read, wait for `06`, re-read). The strap is the truth: the screens show what the strap
// reports, and the only thing kept on the phone is the last read, for display while the strap
// can't be reached.
//
// Left out on purpose:
// - Heart Rate Push: the spec can't say which arg it is (HEALTH `05` is 🔴 "probably", §5.5).
// - Inactivity and goal alerts: whether they buzz on the Helio is 🔴 (§13.4, §20).
// - A workout-detection on/off switch: no arg is known (§19.2); WORKOUT `40` (categories) is never
//   written (§19.3).
// - "Your strap probably alerted you" (§20.2): a follow-up, not this screen.

/// The strap's last read settings, per strap, in memory only: shown (read-only) while the strap
/// can't be reached. Never written back and never treated as the setting.
@MainActor
enum HelioSettingsDisplayCache {
    struct Entry: Equatable {
        let snapshot: ZeppSettingsSnapshot
        let readAt: Date
    }

    private static var entries: [String: Entry] = [:]

    static func store(_ snapshot: ZeppSettingsSnapshot, strap: String, at date: Date = Date()) {
        entries[strap] = Entry(snapshot: snapshot, readAt: date)
    }

    static func entry(strap: String) -> Entry? { entries[strap] }
}

/// The outcome of the last settings action, keyed to the setting it is about (review-240 N2), or to
/// the groups a read was for. A screen shows only the notices about its own settings.
struct HelioSettingsNotice: Equatable {
    let setting: ZeppSetting?
    let groups: [UInt8]
    let text: String

    init(setting: ZeppSetting, text: String) {
        self.setting = setting
        groups = [setting.group]
        self.text = text
    }

    init(groups: [UInt8], text: String) {
        setting = nil
        self.groups = groups
        self.text = text
    }

    /// Shown on a screen listing `settings`.
    func belongs(to settings: [ZeppSetting]) -> Bool {
        if let setting { return settings.contains(setting) }
        return settings.contains { groups.contains($0.group) }
    }
}

/// The plain-language side of the settings screens: labels, values, what each setting does, its
/// battery cost (in words: no figures are known), and why the controls are unavailable.
enum HelioSettingsCopy {

    static func label(_ setting: ZeppSetting) -> String {
        switch setting {
        case .heartRateMonitoring: return "All-day heart rate"
        case .activeHeartRateMonitoring: return "Active heart-rate monitoring"
        case .highAccuracySleep: return "High-accuracy sleep"
        case .sleepBreathingQuality: return "Sleep breathing quality"
        case .stressMonitoring: return "Stress monitoring"
        case .allDaySpO2: return "All-day SpO₂"
        case .highHeartRateAlert: return "High heart rate"
        case .lowHeartRateAlert: return "Low heart rate"
        case .relaxReminder: return "Relax reminder"
        case .lowSpO2Alert: return "Low SpO₂"
        case .workoutDetectionAlert: return "Alert when a workout is detected"
        case .workoutDetectionSensitivity: return "Detection sensitivity"
        }
    }

    /// What the setting does, then what it costs in battery. The alert rules are Amazfit's (§20).
    static func explanation(_ setting: ZeppSetting) -> String {
        switch setting {
        case .heartRateMonitoring:
            return "How often the strap measures your heart rate. Heart rate, resting heart rate and HRV history come from these readings. "
                + "More frequent readings use more battery; Smart lets the strap decide."
        case .activeHeartRateMonitoring:
            return "Measures heart rate more often while you're active. It doesn't decide whether heart rate is recorded: "
                + "the strap records it either way. Uses more battery during activity."
        case .highAccuracySleep:
            return "Uses heart rate to track your sleep in more detail. Uses more battery overnight."
        case .sleepBreathingQuality:
            return "Measures blood oxygen while you sleep. Running the sensor overnight uses more battery."
        case .stressMonitoring:
            return "Estimates stress through the day from extra heart-rate readings, which use more battery. The relax reminder needs it on."
        case .allDaySpO2:
            return "Measures blood oxygen through the day. Running the sensor uses more battery. The low SpO₂ alert needs it on."
        case .highHeartRateAlert:
            return "Buzzes when your heart rate stays above this for 10 minutes in a row while you're at rest. Never during sleep."
        case .lowHeartRateAlert:
            return "Buzzes when your heart rate stays below this for 10 minutes in a row while you're at rest. Never during sleep."
        case .relaxReminder:
            return "Buzzes when your stress stays high for 10 minutes in a row while you're at rest. Never during sleep."
        case .lowSpO2Alert:
            return "Buzzes when your blood oxygen stays below this for 10 minutes in a row. Never during sleep."
        case .workoutDetectionAlert:
            return "Lets you know when the strap detects a workout. On the strap this is probably a buzz; that isn't confirmed yet."
        case .workoutDetectionSensitivity:
            return "Higher notices a workout sooner; lower waits longer."
        }
    }

    /// What goes missing while a recording switch is off; nil when either value is fine.
    static func offConsequence(_ setting: ZeppSetting, _ value: ZeppConfigValue) -> String? {
        let off = value == .bool(false) || value == .byte(0)
        guard off else { return nil }
        switch setting {
        case .heartRateMonitoring: return "Off: heart rate, resting heart rate and HRV history may be missing."
        case .highAccuracySleep: return "Off: sleep stages may be missing."
        case .sleepBreathingQuality: return "Off: sleep SpO₂ and sleep respiratory rate may be missing."
        case .stressMonitoring: return "Off: stress will be empty."
        case .allDaySpO2: return "Off: automatic SpO₂ readings will be empty."
        default: return nil
        }
    }

    /// One value as the strap means it.
    static func value(_ value: ZeppConfigValue, for setting: ZeppSetting) -> String {
        switch (setting, value) {
        case (_, .bool(let on)): return on ? "On" : "Off"
        case (.workoutDetectionSensitivity, .byte(0)): return "High"
        case (.workoutDetectionSensitivity, .byte(1)): return "Standard"
        case (.workoutDetectionSensitivity, .byte(2)): return "Low"
        case (.workoutDetectionSensitivity, .byte(let n)): return "Level \(n)"
        case (_, .byte(0)): return "Off"
        // §17.9: ff smart, fe continuous, 01–78 every N minutes.
        case (.heartRateMonitoring, .byte(0xff)): return "Smart"
        case (.heartRateMonitoring, .byte(0xfe)): return "Continuous"
        case (.heartRateMonitoring, .byte(1)): return "Every minute"
        case (.heartRateMonitoring, .byte(let n)) where n <= 0x78: return "Every \(n) min"
        // Outside §17.9's defined set: don't guess a meaning (review-240 N4).
        case (.heartRateMonitoring, .byte(let n)): return String(format: "Unknown (0x%02x)", n)
        case (.highHeartRateAlert, .byte(let n)): return "Above \(n) bpm"
        case (.lowHeartRateAlert, .byte(let n)): return "Below \(n) bpm"
        case (.lowSpO2Alert, .byte(let n)): return "Below \(n) %"
        default: return "Not reported"
        }
    }

    /// A setting that can't be changed now, shown as text: "On (inactive: needs stress monitoring
    /// on)" for a child whose parent is off (§17.7), "On (read-only)" for an undescribed version.
    static func inactiveValue(_ value: ZeppConfigValue, for setting: ZeppSetting,
                              availability: ZeppSettingsSnapshot.Availability) -> String {
        let shown = Self.value(value, for: setting)
        switch availability {
        case .needs(.heartRateMonitoring): return shown + " (inactive: needs all-day heart rate on)"
        case .needs(let parent): return shown + " (inactive: needs \(label(parent).lowercasedFirst) on)"
        case .readOnly: return shown + " (read-only)"
        default: return shown
        }
    }

    /// The dependent control's one-line reason (§17.7).
    static func needs(_ parent: ZeppSetting) -> String {
        switch parent {
        case .heartRateMonitoring: return "Needs all-day heart rate set to anything but Off, in Measurement."
        default: return "Needs \(label(parent).lowercasedFirst) on. Turn it on in Measurement."
        }
    }

    static let readOnly = "Read-only: the strap's version of these settings isn't one OpenCircuit knows."

    /// Why the settings can't be changed right now; nil when they can.
    static func blockedReason(status: HelioStatus, canChange: Bool, offered: Bool?) -> String? {
        switch status.kind {
        case .ready, .syncing:
            if canChange { return nil }
            if offered == false { return "The strap didn't offer these settings on this connection." }
            return status.kind == .syncing
                ? "Syncing history. Settings can be changed when the sync finishes."
                : "The strap isn't ready for changes yet."
        case .notSetUp, .keyNeeded:
            return "Add the strap's key to change its settings."
        case .keyRejected:
            return "The strap refused the saved key, so its settings can't be changed. Replace the key first."
        case .strapBusy:
            return "Another phone or app seems to hold the strap, so its settings can't be changed. " + HelioStatus.zeppBluetoothCopy
        case .bluetoothOff, .bluetoothDenied:
            return status.title + ". " + (status.detail ?? "")
        case .unsupported:
            return "This strap doesn't offer its settings over Bluetooth."
        case .authenticating, .settingUp:
            return "Getting ready. Settings can be changed once the strap is connected."
        case .searching, .notFound, .connecting, .disconnected:
            return "Connect the strap to change its settings."
        }
    }

    /// §20.1: no message tells the phone when the strap buzzes.
    static let alertsHeader = "Your strap buzzes on its own when one of these triggers, even when your phone isn't nearby. "
        + "OpenCircuit isn't notified when it buzzes, and these are separate from OpenCircuit's own notifications."
    /// §19, decision 34.
    static let workoutHeader = "The strap can notice a workout from your heart rate and record it by itself. "
        + "Amazfit says workout detection greatly reduces battery life. "
        + "OpenCircuit doesn't import the strap's workout records, so these settings only change what the strap and the Zepp app record."
    static let workoutSwitchNote = "Turning detection itself on or off isn't here yet: which strap setting does that hasn't been identified."
    static let savedOnStrap = "Saved on the strap itself. OpenCircuit changes a setting only when you do."
    static let heartRatePushNote = "Heart Rate Push isn't here yet: which strap setting it is hasn't been confirmed. "
        + "OpenCircuit doesn't need it once the key is saved."
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// The state every settings screen shares: the strap's values (live, or last read for display), and
/// whether they can be changed.
@MainActor
private struct HelioSettingsModel {
    let connection: HelioConnection
    let status: HelioStatus
    let group: UInt8

    var session: HelioSession? { connection.session }
    var editor: ZeppSettingsEditor? { session?.settingsEditor }
    var canRead: Bool { session?.canReadStrapSettings == true }
    var canChange: Bool { session?.canChangeStrapSettings == true && editor?.isOffered(group: group) == true }
    var blockedReason: String? {
        HelioSettingsCopy.blockedReason(status: status, canChange: canChange,
                                        offered: canRead ? editor?.isOffered(group: group) : nil)
    }
    var isBusy: Bool { editor?.isBusy == true }
    var hasLiveRead: Bool { canRead && editor?.hasRead(group: group) == true }

    /// This connection's read when there is one; otherwise the last read, for display only.
    var snapshot: ZeppSettingsSnapshot? {
        if hasLiveRead, let live = editor?.snapshot { return live }
        return cached?.snapshot
    }

    var cached: HelioSettingsDisplayCache.Entry? {
        (session?.identityID ?? HelioConnection.savedPeripheralID).flatMap { HelioSettingsDisplayCache.entry(strap: $0) }
    }

    /// Showing the last read rather than a read from this connection.
    var showingCache: Bool { !hasLiveRead && cached != nil }
}

/// One setting: a toggle or a picker of the strap's allowed values, its explanation, and why it is
/// disabled when it is.
private struct HelioSettingRow: View {
    let setting: ZeppSetting
    let snapshot: ZeppSettingsSnapshot
    let enabled: Bool
    let onChange: (ZeppConfigValue, ZeppConfigValue) -> Void

    var body: some View {
        if let current = snapshot.value(setting) {
            let availability = snapshot.availability(setting)
            let usable = enabled && availability == .available && !snapshot.options(setting).isEmpty
            VStack(alignment: .leading, spacing: 6) {
                switch availability {
                case .needs, .readOnly:
                    // Not a greyed switch that reads as "on" (review-240 N1): the stored value as text.
                    LabeledContent(HelioSettingsCopy.label(setting),
                                   value: HelioSettingsCopy.inactiveValue(current, for: setting, availability: availability))
                default:
                    control(current: current).disabled(!usable)
                }
                Text(HelioSettingsCopy.explanation(setting)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch availability {
                case .needs(let parent):
                    // §17.7: shown inactive, with its stored value visible.
                    Text(HelioSettingsCopy.needs(parent)).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                case .readOnly:
                    Text(HelioSettingsCopy.readOnly).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                default:
                    if let consequence = HelioSettingsCopy.offConsequence(setting, current) {
                        Text(consequence).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func control(current: ZeppConfigValue) -> some View {
        if setting.isSwitch {
            Toggle(HelioSettingsCopy.label(setting), isOn: Binding(
                get: { current == .bool(true) },
                set: { on in onChange(current, .bool(on)) }))
        } else {
            // The strap's allowed values, in its order; the current value too if the strap reports
            // one outside its own list (shown, never offered as a change).
            let allowed = snapshot.options(setting)
            let options = allowed + (allowed.contains(current) ? [] : [current])
            Picker(HelioSettingsCopy.label(setting), selection: Binding(
                get: { current },
                set: { new in onChange(current, new) })) {
                ForEach(options, id: \.self) { option in
                    Text(HelioSettingsCopy.value(option, for: setting)).tag(option)
                }
            }
        }
    }
}

/// Shared shell: the reason the controls are unavailable, the rows, the outcome of the last change.
private struct HelioSettingsList: View {
    let connection: HelioConnection
    let group: UInt8
    let settings: [ZeppSetting]
    let header: String?
    let footer: String
    @State private var hasKey = HelioKeyStore.shared.hasKey
    @State private var keyRejected = HelioKeyStore.shared.isRejected

    private var status: HelioStatus {
        HelioStatus.from(connection: connection.state, phase: connection.session?.phase,
                         hasKey: hasKey, keyRejected: keyRejected,
                         hasSavedStrap: HelioConnection.hasSavedStrap, endedBusy: connection.endedBusy)
    }

    var body: some View {
        let model = HelioSettingsModel(connection: connection, status: status, group: group)
        List {
            if let reason = model.blockedReason {
                Section { Text(reason).font(.subheadline) }
            }
            if let header {
                Section { Text(header).font(.subheadline) }
            }
            if let snapshot = model.snapshot, settings.contains(where: { snapshot.value($0) != nil }) {
                Section {
                    ForEach(settings.filter { snapshot.value($0) != nil }, id: \.self) { setting in
                        HelioSettingRow(setting: setting, snapshot: snapshot, enabled: model.canChange && !model.isBusy) { from, to in
                            model.session?.changeStrapSetting(setting, from: from, to: to)
                        }
                    }
                } footer: {
                    if model.showingCache, let cached = model.cached {
                        Text("Last read from the strap \(cached.readAt.formatted(date: .abbreviated, time: .shortened)). " + footer)
                    } else {
                        Text(footer)
                    }
                }
            } else if model.hasLiveRead {
                Section { Text("The strap didn't report these settings.").foregroundStyle(.secondary) }
            } else if model.canRead, model.editor?.isOffered(group: group) == true {
                Section {
                    if model.editor?.readFailures[group] != nil {
                        Text("Couldn't read the strap's settings.").foregroundStyle(.secondary)
                        Button("Read again") { model.session?.readStrapSettings(groups: [group]) }.disabled(model.isBusy)
                    } else {
                        Text("Reading the strap's settings…").foregroundStyle(.secondary)
                    }
                }
            }
            if model.isBusy, model.editor?.changeInFlight != nil {
                Section { Text("Saving to the strap…").font(.caption) }
            } else if model.canRead, let notice = model.session?.settingsNotice, notice.belongs(to: settings) {
                Section { Text(notice.text).font(.caption) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") { model.session?.readStrapSettings(groups: [group]) }.disabled(!model.canRead || model.isBusy)
            }
        }
        .onAppear {
            hasKey = HelioKeyStore.shared.hasKey
            keyRejected = HelioKeyStore.shared.isRejected
            model.session?.readStrapSettings(groups: [group])
        }
        .onChange(of: connection.session?.phase) { _, phase in
            // A connection made while the screen is open: read once it is set up.
            if phase == .ready, connection.session?.settingsEditor?.hasRead(group: group) == false {
                connection.session?.readStrapSettings(groups: [group])
            }
        }
    }
}

/// #228: what the strap measures, and how often.
struct HelioMeasurementSettingsView: View {
    let connection: HelioConnection

    var body: some View {
        HelioSettingsList(connection: connection, group: ZeppConfig.healthGroup, settings: ZeppSetting.measurement, header: nil,
                          footer: HelioSettingsCopy.savedOnStrap + " " + HelioSettingsCopy.heartRatePushNote)
            .navigationTitle("Measurement")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// #230: the strap's own haptic alerts.
struct HelioAlertsView: View {
    let connection: HelioConnection

    var body: some View {
        HelioSettingsList(connection: connection, group: ZeppConfig.healthGroup, settings: ZeppSetting.alerts,
                          header: HelioSettingsCopy.alertsHeader, footer: HelioSettingsCopy.savedOnStrap)
            .navigationTitle("Health Alerts")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// #229: workout detection's alert and sensitivity (decision 34: detection settings only).
struct HelioWorkoutDetectionView: View {
    let connection: HelioConnection

    var body: some View {
        HelioSettingsList(connection: connection, group: ZeppConfig.workoutGroup, settings: ZeppSetting.workoutDetection,
                          header: HelioSettingsCopy.workoutHeader,
                          footer: HelioSettingsCopy.savedOnStrap + " " + HelioSettingsCopy.workoutSwitchNote)
            .navigationTitle("Workout Detection")
            .navigationBarTitleDisplayMode(.inline)
    }
}
