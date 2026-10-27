import Foundation
import Observation
import OpenCircuitKit
import SwiftData

/// Which wearable the app drives (#215, decision 1): ONE at a time. The inactive device is not
/// scanned for, connected or synced. Switching keeps both devices' stored history, because every
/// device writes its own timeline (`SyncDeviceID`, SchemaV8).
enum ActiveDeviceChoice: String, CaseIterable, Sendable {
    case ringConn
    case helioStrap

    var displayName: String {
        switch self {
        case .ringConn: return "RingConn ring"
        case .helioStrap: return "Amazfit Helio Strap"
        }
    }

    /// The device's family in decision 28's ownership log. Exhaustive (decision 51e): a new device
    /// doesn't compile until it says which family owns its time.
    var ownershipFamily: DeviceOwnershipLog.Family {
        switch self {
        case .ringConn: return .ringConn
        case .helioStrap: return .zeppOS
        }
    }

    /// Whether the device buzzes when asked: Shortcuts' Vibrate Wearable (decision 52a). Exhaustive
    /// (decision 51e). The ring's motor is driven on the Gen 3 only (`RingVibration.isSupported`), so
    /// the connected ring's session decides; the strap buzzes through find device (§13.2).
    var onDemandVibration: OnDemandVibration {
        switch self {
        case .ringConn: return .someModels(only: "the RingConn Gen 3")
        case .helioStrap: return .supported
        }
    }

    /// How the device's wake alarm works: Shortcuts' Set and Clear Wake Alarm (decision 52b, 52c, 52g).
    /// Exhaustive (decision 51e). The strap keeps up to 10 alarms and fires them itself (§12); the ring
    /// stores none, and its wake-up alarm is the app's own buzz on a Gen 3 (`RingAlarmController`).
    var wakeAlarm: DeviceWakeAlarm {
        switch self {
        case .ringConn: return .appDriven(models: "the RingConn Gen 3")
        case .helioStrap: return .storedOnDevice
        }
    }

    /// Whether the device can start its Measure by itself when the app opens, and the setting's default
    /// (decision 81e). Exhaustive (decision 51e). The strap streams cheaply and defaults on; the ring's
    /// live measure costs battery, so it is offered but defaults off.
    var autoLiveHeartRateOnOpen: AutoLiveHeartRateOnOpenSupport {
        switch self {
        case .ringConn: return .supported(defaultOn: false)
        case .helioStrap: return .supported(defaultOn: true)
        }
    }
}

/// `ActiveDeviceChoice.autoLiveHeartRateOnOpen`.
enum AutoLiveHeartRateOnOpenSupport: Equatable {
    /// The device can't start a live heart rate by itself.
    case unsupported
    /// It can; `defaultOn` is the setting's value until the person changes it.
    case supported(defaultOn: Bool)
}

/// `ActiveDeviceChoice.onDemandVibration`.
enum OnDemandVibration: Equatable {
    /// Every model buzzes when asked.
    case supported
    /// Only some models have a motor OpenCircuit can drive (`only` names them); the connected
    /// device's session says whether this one does.
    case someModels(only: String)
    case unsupported
}

/// `ActiveDeviceChoice.wakeAlarm`.
enum DeviceWakeAlarm: Equatable {
    /// The device stores alarms and fires them itself, with no phone needed at the time.
    case storedOnDevice
    /// It doesn't. `alternative` says where OpenCircuit offers a wake-up alarm for it instead, if anywhere.
    case notStored(alternative: String?)
    /// Nothing is stored on the device: OpenCircuit buzzes it at the time, best-effort, on the models
    /// named (`RingAlarmController`, decision 52g).
    case appDriven(models: String)

    var isStoredOnDevice: Bool { self == .storedOnDevice }
}

/// The persisted choice (UserDefaults). `.ringConn` when nothing was ever chosen, so an existing
/// ring user's app is exactly what it was before the strap existed.
@Observable
@MainActor
final class ActiveDeviceChoiceStore {
    static let shared = ActiveDeviceChoiceStore()
    nonisolated static let key = "device.activeChoice.v1"

    /// The choice read straight from UserDefaults, for launch paths that must decide before any
    /// observable holder exists (AppDelegate, a BGTask, a CoreBluetooth-restoration relaunch).
    nonisolated static func persisted(_ defaults: UserDefaults = .standard) -> ActiveDeviceChoice {
        defaults.string(forKey: key).flatMap(ActiveDeviceChoice.init(rawValue:)) ?? .ringConn
    }

    private(set) var current: ActiveDeviceChoice
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ownership: DeviceOwnershipStore
    @ObservationIgnored private let neverHadRing: @MainActor () -> Bool

    init(defaults: UserDefaults = .standard, ownership: DeviceOwnershipStore? = nil,
         neverHadRing: (@MainActor () -> Bool)? = nil, now: Date = Date()) {
        self.defaults = defaults
        // A store over its own defaults (a test's suite) records its switches there too.
        self.ownership = ownership ?? (defaults === UserDefaults.standard ? .shared : DeviceOwnershipStore(defaults: defaults))
        self.neverHadRing = neverHadRing ?? { DeviceOwnershipStore.installNeverHadRing() }
        current = Self.persisted(defaults)
        // Review-224b S-A: the choice and the log are two keys. A strap chosen while the log says the
        // ring owns the present (a choice persisted before the log existed) would own no time and
        // store nothing, and choosing it again records nothing (`set` records only a change). Put
        // the invariant back here, with `set`'s first-entry rule. No-op with the ring chosen.
        if current == .helioStrap, self.ownership.log.currentFamily != .zeppOS {
            let strapOnly = self.ownership.log.isEmpty && self.neverHadRing()
            self.ownership.record(.zeppOS, since: strapOnly ? .distantPast : now)
        }
    }

    /// The ownership log, read through the choice store so the reconciliation above has run first.
    var ownershipLog: DeviceOwnershipLog { ownership.log }

    var isRing: Bool { current == .ringConn }
    var isHelio: Bool { current == .helioStrap }

    /// Persist a choice. Only `DeviceSwitcher` calls this: switching also stops the other device.
    ///
    /// The ONE place a switch is recorded in the ownership log (decision 28), and only when the
    /// choice actually changes. The strap's first entry on an install that never had a ring owns
    /// all past time (`.distantPast`), so a strap-only user gets the normal first sync; every other
    /// switch owns time from `now`.
    func set(_ choice: ActiveDeviceChoice, now: Date = Date()) {
        defaults.set(choice.rawValue, forKey: Self.key)
        if choice != current {
            let family = choice.ownershipFamily
            let strapOnly = family == .zeppOS && ownership.log.isEmpty && neverHadRing()
            ownership.record(family, since: strapOnly ? .distantPast : now)
        }
        current = choice
    }
}

/// Decision 28's ownership log, persisted in UserDefaults under a versioned key (no SwiftData
/// schema change). Written only through `ActiveDeviceChoiceStore.set`; read by the store, the
/// strap's fetch and the Health writer.
@MainActor
final class DeviceOwnershipStore {
    static let shared = DeviceOwnershipStore()
    nonisolated static let key = "device.ownershipLog.v1"

    private let defaults: UserDefaults
    /// The persisted log; empty (the ring owns all time) when nothing was ever switched.
    private(set) var log: DeviceOwnershipLog

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        log = Self.persisted(defaults)
    }

    nonisolated static func persisted(_ defaults: UserDefaults = .standard) -> DeviceOwnershipLog {
        guard let data = defaults.data(forKey: key),
              let log = try? JSONDecoder().decode(DeviceOwnershipLog.self, from: data) else { return DeviceOwnershipLog() }
        return log
    }

    func record(_ family: DeviceOwnershipLog.Family, since: Date) {
        var next = log
        guard next.record(family, since: since), let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.key)
        log = next
    }

    /// "Never had a ring" (decision 28's first-entry rule): no saved ring peripheral, no cached ring
    /// identity (`RingMetadataStore`), and no sample row on the ring's timeline. Without a readable
    /// store the answer is "had a ring", the conservative side: the strap then owns time only from
    /// the switch.
    static func installNeverHadRing(defaults: UserDefaults = .standard) -> Bool {
        guard !RingScanner.hasSavedRingToRestore, RingMetadataStore(defaults).load().identifier.isEmpty,
              let container = OpenCircuitApp.sharedContainer else { return false }
        let ring = SyncDeviceID.ringConn.rawValue
        var descriptor = FetchDescriptor<StoredSample>(predicate: #Predicate { $0.deviceID == ring })
        descriptor.fetchLimit = 1
        guard let rows = try? container.mainContext.fetch(descriptor) else { return false }
        return rows.isEmpty
    }
}

/// The one place the active device changes (decision 1).
@MainActor
enum DeviceSwitcher {
    /// Stop the device being left (no scan, no link, no pending connect), persist the choice, then
    /// wake the device being chosen. The device being left keeps its saved peripheral, so switching
    /// back reconnects without a new pairing.
    static func activate(_ choice: ActiveDeviceChoice, store: ActiveDeviceChoiceStore? = nil) {
        let store = store ?? .shared
        guard choice != store.current else { return }
        switch choice {
        case .helioStrap:
            // Constructs the scanner if this launch never touched it; that creates no central
            // (RingScanner #142) and happens before the strap becomes active.
            RingScanner.shared.disconnect()
            store.set(.helioStrap)
            HelioConnection.shared.reconnectKnown()
            if HelioHealthWake.wasEverUsed() { Task { await HelioHealthWake.shared.deviceChanged() } }
        case .ringConn:
            HelioConnection.shared.disconnect()
            store.set(.ringConn)
            RingScanner.shared.reconnectKnownPeripheral()
            // Decision 33: the step-count wake is the strap's; leaving it turns HealthKit delivery off.
            if HelioHealthWake.wasEverUsed() { Task { await HelioHealthWake.shared.deviceChanged() } }
        }
    }
}

/// Which drain a background wake runs (decision 1): the chosen device's, never the other's. The BGTask
/// handler and the Sleep Focus filter decide with it from the persisted choice (UserDefaults only)
/// before touching either driver, so with the strap chosen the ring's scanner and central are never
/// constructed, and with the ring chosen the strap's connection and central never are.
enum BackgroundDrain: Equatable {
    case ring
    case strap

    init(_ choice: ActiveDeviceChoice) {
        switch choice {
        case .ringConn: self = .ring
        case .helioStrap: self = .strap
        }
    }
}
