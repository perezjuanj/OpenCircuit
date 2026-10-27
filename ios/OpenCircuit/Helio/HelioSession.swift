import Foundation
import Observation
import OpenCircuitKit
import os
import ZeppKit

// The Amazfit Helio Strap as a `WearableSession` (#215 phase 3). One session per connection, like
// `RingSession`. It holds no CoreBluetooth: `HelioConnection` moves bytes between the radio and this
// class through `HelioTransport`, so the whole flow runs in tests against `FakeZeppDevice`.
//
// Connection sequence, mirroring HelioVerify (proven on a real strap, ZEPP_PROTOCOL.md §10.1):
//   read DIS hardware revision + battery level → enable notify on …0017 (+ …0016) → auth (§4) →
//   services list (§5.2) → device info (§5.3) → battery (§5.3) → set the clock (§5.1, decision 9) →
//   HEALTH recording switches (§5.5) → find-device capabilities (§11.2) → alarm list (§12) →
//   haptic alert settings (§13.4, read-only) → history fetch over Path A (§6), then Apple Health.
// Without a usable key the session stays keyless: standard 0x2A37 heart rate only, if the strap
// sends it unauthenticated (§7.1 Tier 0, decision 7). Nothing is ever written at setup except the
// clock (§15.1); alarm writes happen only on an explicit user edit, one slot at a time.

let helioLog = Logger(subsystem: "com.standardsoftwaresolutions.opencircuit", category: "helio")

/// The link-level half of a strap connection. `HelioConnection` implements it over CoreBluetooth;
/// the tests implement it over `FakeZeppDevice`.
@MainActor
protocol HelioTransport: AnyObject {
    /// The characteristic was discovered on this connection.
    func has(_ characteristic: ZeppCharacteristic) -> Bool
    /// The characteristic supports notifications.
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool
    /// The "(MTU − 3)" term for chunking (§3.2): the OS-negotiated value, never a hard-coded one.
    var maxWriteLength: Int { get }
    func write(_ write: ZeppWrite)
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool)
    func read(_ characteristic: ZeppCharacteristic)
}

/// One reading shown in the app only (stress, PAI: decision 15).
struct HelioReading: Equatable {
    let value: Double
    let at: Date
}

/// What one history sync delivered.
struct HelioSyncResult: Equatable {
    /// The strap's staged nights stored this sync (manually edited nights excluded), for Apple Health.
    var nights: [HelioSleepSelection.Night] = []
    var roundsStored = 0
    var roundsFailed = 0
    /// Types the strap had nothing new for.
    var typesEmpty = 0
    var todaySteps: Int?
    var latestStress: HelioReading?
    var latestPAI: HelioReading?
    /// The sync ended early (link lost, or no progress for too long).
    var interrupted = false
    /// A background run owned this sync (#215 phase 4): the run flushes Apple Health and logs it, so
    /// the connection doesn't do it a second time.
    var endedInBackgroundRun = false
    /// The strap's identity when the sync ended, so its Health flush names the strap even if the
    /// person switched devices meanwhile (review-224 S3: attribution follows the row).
    var identity: WearableIdentity?
    /// The sync was handed over by a Sleep Focus run (review-225b S-B): the time T that Focus ended.
    /// Its nights skip the 20-minute quiet margin in the post-sync hook's flush, as they would have in
    /// the run's own, if that flush starts within 30 minutes of T (decision 31).
    var nightsFinalized: Date?
    /// Decision 72: counts for the diagnostics line when this sync fetched a sleep-session round; nil
    /// otherwise.
    var sleepRound: StrapSleepRoundSummary?
}

/// What a session reports to its connection beyond a finished sync (#233): breadcrumbs and wakes.
enum HelioSessionEvent: Equatable {
    /// A history sync started on this session.
    case syncStarted
    /// A message the strap sent on its own, outside any request this session started: its endpoint,
    /// opcode bytes and length only (never the payload, which can hold health data; §16.5).
    case strapMessage(endpoint: UInt16, opcode: [UInt8], length: Int)
    /// A notification on a standard characteristic that nothing on this connection asked for.
    case strapNotification(ZeppCharacteristic)
    /// The strap's sleep events on `0x001D` (§16.2 rows 1–2): `06 01` fell asleep, `06 00` woke up. 🔴
    /// whether the Helio sends them at all, so they are only ever a hint (§16.4). They carry no time.
    case fellAsleep
    case wokeUp
}

/// Where fetched rounds go. `HelioStoreSink` is the `LocalStore` implementation.
@MainActor
protocol HelioHistorySink: AnyObject {
    /// Each type's persisted watermark on `timeline`, at the sync's own `now`. `now` is the session
    /// clock, not `Date()`: the one-time backfills the store runs here bound their rewind by it
    /// (review-248 SF-1), so every time in a sync comes from one source.
    func fetchCursors(timeline: SyncDeviceID, now: Date) -> [ZeppFetchType: Date]
    /// No fetch starts before this (decision 28: the strap's current ownership start).
    func notBefore(timeline: SyncDeviceID, now: Date) -> Date?
    func beginSync(timeline: SyncDeviceID, now: Date)
    /// Store one round and advance its type's watermark. true only when both are durably saved.
    func persist(_ round: ZeppFetchRound, timeline: SyncDeviceID, now: Date) -> Bool
    /// Every round of this sync is in: finish the per-night work and report.
    func finishSync(timeline: SyncDeviceID, now: Date) -> HelioSyncResult
}

/// The find-device machine outlives a connection: it carries a stop owed since the link dropped
/// mid-find to the next connection (§11.4, §15.4). `HelioConnection` owns one and lends it to each
/// session.
@MainActor
final class HelioFindState {
    var machine: ZeppFindDevice

    /// Decision 18: the app stops a find after 60 s. Decision 19: a buzz is 2 s.
    static let configuration = ZeppFindDevice.Configuration(maxDuration: 60, buzzLength: 2)
    /// "A find may still be running on the strap" (#215 phase 4). The machine's owed stop lives in
    /// memory, so a process the system ends (in the background, or killed while suspended) would
    /// forget it; this flag hands it to the next process, whose first connection sends the `06`.
    nonisolated static let stopOwedKey = "helio.findStopOwed.v1"

    /// nil `defaults`: nothing persisted (the tests' default).
    private let defaults: UserDefaults?

    init(configuration: ZeppFindDevice.Configuration? = nil, defaults: UserDefaults? = nil) {
        self.defaults = defaults
        machine = ZeppFindDevice(configuration: configuration ?? Self.configuration,
                                 stopOwed: defaults?.bool(forKey: Self.stopOwedKey) ?? false)
    }

    /// Record whether a stop may be owed: set while a find runs or after a link loss mid-find,
    /// cleared once the `06` went out.
    func persist() {
        defaults?.set(machine.isBuzzing || machine.isStopOwed, forKey: Self.stopOwedKey)
    }
}

@Observable
@MainActor
final class HelioSession: WearableSession {

    enum Phase: Equatable {
        /// Characteristics discovered; the basics are being read.
        case starting
        /// No key saved: standard heart rate only, if the strap sends it (decision 7).
        case keyless
        case authenticating
        /// The strap answered `10 05 25`: the key is wrong or was invalidated. Never retried.
        case keyRejected
        /// Auth failed another way, or the strap didn't answer: another phone or app probably holds
        /// it (§9 "Competing central"). Not retried on this connection.
        case strapBusy
        /// The strap lacks the characteristics this app needs.
        case unsupported
        case settingUp
        case ready
        case syncing
    }

    /// Decision 8: v1 always acks keep-on-strap (`03 09`). There is no delete path in the app.
    static let ackPolicy: ZeppAckPolicy = .keepOnDevice
    /// How long after this session last sent to an endpoint a message there still counts as a reply
    /// rather than something the strap sent on its own (twice a setup step's timeout).
    static let replyWindow: TimeInterval = 10
    /// The workout endpoint (§16.2 rows 8–9). The app sends nothing there; what arrives is logged.
    static let workoutEndpoint: UInt16 = 0x0019
    /// How long auth may take before the strap is reported busy.
    static let authTimeout: TimeInterval = 10
    /// How long a setup step waits for its reply (the same 5 s HelioVerify and ZeppKit use).
    static let stepTimeout: TimeInterval = 5
    /// A sync with no fetch traffic for this long is aborted (with `03 09`).
    static let syncStallTimeout: TimeInterval = 90
    /// Decision 11's name for the strap in Apple Health and on screen.
    static let displayName = "Helio Strap"

    // MARK: Identity

    /// The strap's CoreBluetooth peripheral UUID: per install, never its MAC.
    let identityID: String
    let model: ZeppDeviceModel
    /// Where everything this strap measures is stored: `zeppos:<identityID>` (decision 10).
    let timeline: SyncDeviceID
    private(set) var hardwareVersion: String?
    private(set) var firmwareVersion: String?

    // MARK: Observable state

    private(set) var phase: Phase = .starting
    private(set) var isLinkConnected = true
    private(set) var lastFrameAt: Date?
    private(set) var batteryPercent: Int?
    private(set) var charging = false
    private(set) var liveHR: Int?
    private(set) var liveHRAt: Date?
    /// Beat-to-beat (RR) intervals received in `0x2A37` frames on this connection (§7.1 flag bit 4).
    /// Whether the Helio sends them at all is 🔴 (ZEPP_PROTOCOL.md §7.1, §10 item 11); the strap's
    /// workout summary reports this count so a phone can answer it. Not observed: it changes every
    /// second during a stream and nothing renders it live.
    @ObservationIgnored private(set) var rrIntervalsReceived = 0
    /// The authenticated heart-rate stream (§7.1) is running.
    private(set) var liveHeartRateRunning = false
    /// Who started the running stream: the Measure control (90 s), or a workout (until it ends, #227).
    private(set) var liveHeartRateOwner: LiveHeartRateOwner?
    /// Standard heart-rate notifications arrived without auth (Tier 0) on this connection.
    private(set) var tierZeroHeartRateSeen = false
    private(set) var steps: Int?
    private(set) var syncStatus: String?
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncResult: HelioSyncResult?
    private(set) var services: ZeppServicesList?
    private(set) var controlCapabilities: ZeppControlCapabilities = .disconnected
    /// HEALTH switches that are off, so the matching history comes back empty (§5.5).
    private(set) var recordingWarnings: [String] = []
    /// The strap confirmed the clock set on this connection (`06 01`, decision 9).
    private(set) var clockSet = false
    private(set) var alarmEditor: ZeppAlarmEditor?
    /// The last alarm outcome, in plain language, for the alarm screen.
    private(set) var alarmNotice: String?
    private(set) var configCapabilities: ZeppConfigCapabilities?
    private(set) var hapticAlerts: ZeppHapticAlertSettings?
    /// The strap's own settings (measurement, alerts, workout detection), changed one at a time
    /// through §17.8 (#228, #229, #230). Built with the services list; nothing is read or written
    /// until a settings screen asks.
    private(set) var settingsEditor: ZeppSettingsEditor?
    /// The last settings outcome, in plain language, for the settings screens.
    private(set) var settingsNotice: HelioSettingsNotice?
    /// Mirrors of the shared find machine, so the find screen re-renders.
    private(set) var findPhase: ZeppFindDevice.State = .idle
    private(set) var findVersion: UInt8?
    /// Every acknowledgement byte sent for a fetch round on this connection, in order (always `09`).
    private(set) var fetchAcksSent: [UInt8] = []
    /// Syncs that ended on this connection, finished or interrupted (`lastSyncResult` is the latest).
    /// The background run waits on it (#215 phase 4).
    private(set) var syncsFinished = 0
    /// The sync whose body-alert pass was claimed (`StrapSyncAlertPass`, review-236 S1). On the session,
    /// so a new session (a reconnect) starts unclaimed (review-225f SF-1).
    @ObservationIgnored var alertPassClaimedSync: Int?
    /// Set by a background run while it owns this connection's syncs (`HelioSyncResult.endedInBackgroundRun`).
    @ObservationIgnored var backgroundRunOwnsSyncs = false
    /// Set by a Sleep Focus run that hands its sync to the app (review-225b S-B): the time T that Focus
    /// ended. Carried into the next `HelioSyncResult.nightsFinalized`, then cleared, so later syncs
    /// don't inherit it.
    @ObservationIgnored var finalizeNightsOnHandOff: Date?

    // MARK: Collaborators

    @ObservationIgnored private weak var transport: (any HelioTransport)?
    @ObservationIgnored private let key: ZeppAuthKey?
    @ObservationIgnored private let keyStore: (any HelioKeyStoring)?
    @ObservationIgnored private let sink: (any HelioHistorySink)?
    @ObservationIgnored private let findState: HelioFindState
    @ObservationIgnored private let onSyncFinished: @MainActor (HelioSyncResult, SyncDeviceID) async -> Void
    @ObservationIgnored private let onEvent: @MainActor (HelioSessionEvent) -> Void
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let random: ZeppRandom
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private let autoSyncOnConnect: Bool
    /// True while the app records a workout on this strap (#227): history syncs wait until it ends.
    @ObservationIgnored private let workoutHoldsLink: @MainActor () -> Bool
    /// Every valid heart-rate reading, as it arrives (the workout recorder, #227).
    @ObservationIgnored var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    /// The `04 00` owed after an interrupted workout (#227, review-238 SF2).
    @ObservationIgnored var orphanStop = StrapWorkoutOrphanStop()
    /// Every alarm editor event, after the session's own handling: Shortcuts' wake alarm (#260, decision
    /// 52b) records its slot only from the re-read that confirms its write (`StrapWakeAlarmApplier`).
    @ObservationIgnored var alarmEventObserver: (@MainActor (ZeppAlarmEditor.Event) -> Void)?
    /// Called right after setup's alarm list read, once per connection (the clock was set before it):
    /// where a Shortcuts wake alarm saved while the strap was away is applied (decision 52b).
    @ObservationIgnored var onSetupAlarmsRead: (@MainActor () -> Void)?

    // MARK: Protocol state

    @ObservationIgnored private var link: ZeppLink?
    @ObservationIgnored private var fetch: ZeppHistoryFetch?
    @ObservationIgnored private var pendingNotify = Set<ZeppCharacteristic>()
    @ObservationIgnored private var notifyPurpose: NotifyPurpose?
    @ObservationIgnored private var authDeadline: Date?
    @ObservationIgnored private var setupQueue: [SetupStep] = []
    @ObservationIgnored private var currentStep: SetupStep?
    @ObservationIgnored private var stepDeadline: Date?
    @ObservationIgnored private var lastFetchProgressAt: Date?
    @ObservationIgnored private var syncCounts = (stored: 0, failed: 0, empty: 0)
    @ObservationIgnored private var liveHRKeepAliveAt: Date?
    @ObservationIgnored private var liveHREndsAt: Date?
    /// When the workout stream was last (re)started, for its restart watchdog.
    @ObservationIgnored private var liveHRStartedAt: Date?
    @ObservationIgnored private var disHardwareRevision: String?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// When this session last sent to each endpoint, to tell a reply from a message the strap sent on
    /// its own (#233).
    @ObservationIgnored private var lastSentAt: [UInt16: Date] = [:]
    @ObservationIgnored private var liveHRStoppedAt: Date?
    /// Keyless standard heart rate is subscribed (Tier 0, decision 7): only with the app in front.
    @ObservationIgnored private var tierZeroSubscribed = false
    /// The app is in the background: nothing is subscribed for display (§16.5), so Tier 0 waits.
    @ObservationIgnored var appInBackground = false
    /// Decision 81b: this foreground's activation sync has been decided (started, or left alone by its
    /// throttle), or the connection's own on-connect sync has been asked for. Live heart rate on open
    /// waits for it, so it can never take the link ahead of the sync (a running stream would stop the
    /// activation sync from starting: `HelioActivationSync`). Observed, so the auto-start re-asks.
    private(set) var activationSyncSettled = false
    /// §16.5's fail-safes, each sent at most once per connection.
    @ObservationIgnored private var heartRateFailSafeSent = false
    @ObservationIgnored private var realtimeStepsOffSent = false
    @ObservationIgnored private var chunkedWriteSubscribed = false

    private enum NotifyPurpose { case auth, fetch }

    enum LiveHeartRateOwner: Equatable { case measure, workout }

    /// A workout started the heart-rate stream and no reading has arrived for this long: send the
    /// start again (#227).
    // SPEC-GAP: §7.1 says only that `04 02` every second keeps the stream running. Whether the strap
    // ever stops on its own (a maximum duration, or after the keep-alive paused while the app was
    // suspended), and whether `04 02` alone restarts it, is not specified. A stalled stream is
    // restarted with `04 01`, at most once per this interval.
    static let workoutStreamRestartAfter: TimeInterval = 10

    private enum SetupStep: Equatable {
        case servicesList, deviceInfo, battery, setTime, healthConfig
        case findCapabilities, alarms, alertCapabilities, alertSettings
    }

    init(transport: any HelioTransport, identityID: String, model: ZeppDeviceModel = .helioStrap,
         key: ZeppAuthKey?, keyStore: (any HelioKeyStoring)?, sink: (any HelioHistorySink)?,
         findState: HelioFindState,
         onSyncFinished: @escaping @MainActor (HelioSyncResult, SyncDeviceID) async -> Void = { _, _ in },
         onEvent: @escaping @MainActor (HelioSessionEvent) -> Void = { _ in },
         clock: @escaping () -> Date = Date.init, random: ZeppRandom = .system,
         autoTick: Bool = true, autoSyncOnConnect: Bool = true,
         workoutHoldsLink: @escaping @MainActor () -> Bool = { false }) {
        self.transport = transport
        self.identityID = identityID
        self.model = model
        self.key = key
        self.keyStore = keyStore
        self.sink = sink
        self.findState = findState
        self.onSyncFinished = onSyncFinished
        self.onEvent = onEvent
        self.clock = clock
        self.random = random
        self.autoTick = autoTick
        self.autoSyncOnConnect = autoSyncOnConnect
        self.workoutHoldsLink = workoutHoldsLink
        timeline = SyncDeviceID.timeline(for: .zeppOS(model: Self.displayName), identityID: identityID)
        findPhase = findState.machine.state
    }

    // MARK: WearableSession

    var deviceKind: WearableDeviceKind { .zeppOS(model: Self.displayName) }

    /// Decision 11: name "Helio Strap", manufacturer "Amazfit" (`WearableDeviceKind.brand`), model
    /// from the advertised product, hardware and firmware from the strap's own reads when present.
    var identity: WearableIdentity {
        WearableIdentity(id: identityID, kind: deviceKind, name: Self.displayName,
                         hardwareVersion: hardwareVersion, firmwareVersion: firmwareVersion)
    }

    /// The seam's flags, intersected with what THIS connection proved (`ZeppControlCapabilities`,
    /// decision 22): unknown is unsupported.
    var capabilities: WearableCapabilities {
        var caps: WearableCapabilities = []
        if isAuthenticated { caps.formUnion([.historySync, .skinTemperature]) }
        if batteryPercent != nil { caps.insert(.battery) }
        if canStreamHeartRate || tierZeroHeartRateSeen { caps.insert(.liveHeartRate) }
        if controlCapabilities.isSupported(.findDevice) { caps.insert(.findMyDevice) }
        if controlCapabilities.isSupported(.buzz) { caps.insert(.vibration) }
        if controlCapabilities.isSupported(.alarms), alarmEditor?.malformedList == nil { caps.insert(.alarm) }
        return caps
    }

    var ready: Bool { isLinkConnected && (phase == .ready || phase == .syncing) }
    var syncing: Bool { phase == .syncing }
    var isAuthenticated: Bool { link?.isAuthenticated == true }
    /// A find or buzz is running (from the observable mirror, so views re-render).
    var isFinding: Bool {
        if case .buzzing = findPhase { return true }
        return false
    }

    /// Authenticated heart-rate streaming is possible on this connection (§7.1).
    var canStreamHeartRate: Bool {
        isAuthenticated && services?.contains(ZeppEndpoint.heartRate) == true
            && transport?.has(.heartRateMeasurement) == true
    }

    func syncHistory(manual: Bool) {
        // A workout holds the link (#227), like the ring's (T6): the sync runs when it ends.
        // SPEC-GAP: whether a history fetch (…0004/…0005) and the heart-rate stream (`0x001D`) can
        // run together on one connection is not specified, so they never do.
        guard !workoutHoldsLink() else {
            if manual { syncStatus = "Syncs after the workout ends" }
            helioLog.notice("helio: sync deferred, a workout holds the link")
            return
        }
        guard phase == .ready, isAuthenticated else {
            if manual { syncStatus = phase == .syncing ? "Already syncing" : "Not ready to sync" }
            return
        }
        guard let transport, transport.has(.activityControl), transport.has(.activityData), sink != nil else {
            syncStatus = "This strap doesn't offer history over Bluetooth"
            return
        }
        phase = .syncing
        syncStatus = "Syncing…"
        lastFetchProgressAt = clock()
        notifyPurpose = .fetch
        pendingNotify = [.activityControl, .activityData]
        transport.setNotify(.activityControl, enabled: true)
        transport.setNotify(.activityData, enabled: true)
        helioLog.notice("helio: sync started (\(manual ? "manual" : "on connect", privacy: .public))")
        onEvent(.syncStarted)
    }

    // MARK: Connection lifecycle (called by HelioConnection)

    /// The characteristics are known: read the basics, then authenticate or stay keyless.
    func start() {
        guard let transport else { return }
        for characteristic in [ZeppCharacteristic.hardwareRevision, .batteryLevel] where transport.has(characteristic) {
            transport.read(characteristic)
        }
        if autoTick { startTicking() }
        guard let key, keyStore?.isRejected != true else {
            phase = keyStore?.isRejected == true ? .keyRejected : .keyless
            helioLog.notice("helio: \(self.phase == .keyRejected ? "key rejected earlier" : "no key", privacy: .public); standard heart rate only")
            startTierZero()
            return
        }
        guard transport.has(.chunkedRead), transport.has(.chunkedWrite) else {
            phase = .unsupported
            helioLog.error("helio: chunked characteristics …0016/…0017 not found")
            return
        }
        link = ZeppLink(authKey: key, random: random, maxWriteLength: transport.maxWriteLength)
        phase = .authenticating
        notifyPurpose = .auth
        pendingNotify = [.chunkedRead]
        if transport.canNotify(.chunkedWrite) {
            pendingNotify.insert(.chunkedWrite)
            chunkedWriteSubscribed = true
        }
        authDeadline = clock().addingTimeInterval(Self.authTimeout)
        for characteristic in pendingNotify { transport.setNotify(characteristic, enabled: true) }
    }

    /// CoreBluetooth reported a notification state change.
    func notificationStateChanged(_ characteristic: ZeppCharacteristic, enabled: Bool, failed: Bool) {
        // Only an ENABLE (or a failure) settles a pending entry: a late "off" from the previous
        // sync's teardown must not start the next fetch before notify is back on.
        guard pendingNotify.contains(characteristic), enabled || failed else { return }
        if failed {
            pendingNotify.removeAll()
            switch notifyPurpose {
            case .auth?: failAuthentication(busy: true, reason: "notify on \(characteristic.rawValue) failed")
            case .fetch?: finishFetch(interrupted: true)
            case nil: break
            }
            notifyPurpose = nil
            return
        }
        pendingNotify.remove(characteristic)
        guard pendingNotify.isEmpty else { return }
        let purpose = notifyPurpose
        notifyPurpose = nil
        switch purpose {
        case .auth?: startAuthentication()
        case .fetch?: startFetch()
        case nil: break
        }
    }

    /// A read response or a notification.
    func received(_ characteristic: ZeppCharacteristic, _ bytes: [UInt8]) {
        let now = clock()
        lastFrameAt = now
        switch characteristic {
        case .hardwareRevision:
            let text = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            disHardwareRevision = text.isEmpty ? nil : text
            if hardwareVersion == nil { hardwareVersion = disHardwareRevision }
        case .firmwareRevision:
            // Not exposed by the Helio (§1); kept for another Zepp OS model.
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if firmwareVersion == nil, !text.isEmpty { firmwareVersion = text }
        case .batteryLevel:
            if let level = ZeppBatteryLevelCharacteristic.parse(bytes), !isAuthenticated { batteryPercent = level }
        case .heartRateMeasurement:
            // With a key, `0x2A37` comes only from the stream this app starts (§7.1). Anything else
            // (a Heart Rate Push setting, say) is the strap talking on its own: noted, never shown.
            if !(liveHeartRateRunning || (tierZeroSubscribed && !isAuthenticated)),
               !within(Self.replyWindow, of: liveHRStoppedAt, now: now) {
                onEvent(.strapNotification(.heartRateMeasurement))
                heartRateFailSafe()
                return
            }
            guard let measurement = ZeppHeartRateMeasurement.parse(bytes),
                  LiveHR.validBPM.contains(measurement.beatsPerMinute) else { return }
            liveHR = measurement.beatsPerMinute
            liveHRAt = now
            rrIntervalsReceived += measurement.rrIntervals.count
            if !isAuthenticated { tierZeroHeartRateSeen = true }
            heartRateObserver?(measurement.beatsPerMinute, now)
        case .chunkedRead, .chunkedWrite:
            // Mutated in place, not through a `guard var` copy: a copy shares the reassembly buffer's
            // storage with `self.link`, so every append would copy the whole message so far (CoW).
            guard link != nil else { return }
            let out = link!.receive(bytes)
            handle(out)
        case .activityControl:
            guard fetch != nil else {
                if !within(Self.replyWindow, of: lastFetchProgressAt, now: now) { onEvent(.strapNotification(.activityControl)) }
                return
            }
            lastFetchProgressAt = now
            let actions = fetch!.receiveControl(bytes)
            perform(actions)
        case .activityData:
            guard fetch != nil else {
                if !within(Self.replyWindow, of: lastFetchProgressAt, now: now) { onEvent(.strapNotification(.activityData)) }
                return
            }
            lastFetchProgressAt = now
            // In place (see `.chunkedRead`): a copy made the round buffer's every append O(round size).
            let actions = fetch!.receiveData(bytes)
            perform(actions)
        case .currentTime:
            break
        }
    }

    /// The link dropped. A running find owes its stop to the next connection; a fetch round in
    /// progress can't be acked (the strap keeps unacked data, §6.3); what was stored stays stored.
    func linkLost() {
        isLinkConnected = false
        findState.machine.connectionLost()
        findState.persist()
        findPhase = findState.machine.state
        if fetch != nil || phase == .syncing { finishFetch(interrupted: true) }
        liveHeartRateRunning = false
        liveHeartRateOwner = nil
        liveHRKeepAliveAt = nil
        liveHREndsAt = nil
        liveHRStartedAt = nil
        authDeadline = nil
        stepDeadline = nil
        tickTask?.cancel()
        tickTask = nil
        helioLog.notice("helio: link lost")
    }

    /// A user disconnect mid-sync: ack the open round `03 09` while the link is still up (the strap
    /// keeps the data either way), then let `linkLost` finish the sync as interrupted.
    func abortSync() {
        guard var fetch else { return }
        let actions = fetch.abort()
        self.fetch = fetch
        perform(actions)
    }

    /// An expiry's teardown (review-225e SF-2): ack the open round `03 09` (queued first), then end the
    /// fetch now as interrupted. `abortSync` alone leaves the session "syncing" (the fetch machine emits
    /// no `.finished` on an abort), which made the caller's disconnect defer its cancel.
    func stopSyncForTeardown() {
        abortSync()
        if fetch != nil || phase == .syncing { finishFetch(interrupted: true) }
    }

    /// Decision 18: backgrounding stops a find; a Measure stream stops too, and so does the keyless
    /// Tier 0 subscription (§16.5: none for background work). A workout's stream keeps running (#227):
    /// the workout's location session keeps the app alive, as the ring's does.
    func appDidEnterBackground() {
        appInBackground = true
        activationSyncSettled = false
        stopFind()
        if liveHeartRateOwner != .workout { stopLiveHeartRate() }
        stopTierZero()
    }

    /// The activation sync has been decided for this foreground (decision 81b).
    func activationSyncWasDecided() {
        activationSyncSettled = true
    }

    /// Back in front: a keyless session listens for standard heart rate again (decision 7).
    func appDidBecomeActive() {
        appInBackground = false
        switch phase {
        case .keyless, .keyRejected, .strapBusy: startTierZero()
        case .starting, .authenticating, .settingUp, .ready, .syncing, .unsupported: break
        }
    }

    // MARK: Time

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick(now: self.clock())
            }
        }
    }

    /// Timeouts, the find machine's stops, the alarm editor's reply timeouts, the live-HR
    /// keep-alive and the sync watchdog. Production calls it every 250 ms; tests call it directly.
    func tick(now: Date) {
        if let authDeadline, now >= authDeadline, phase == .authenticating {
            failAuthentication(busy: true, reason: "no auth reply in \(Int(Self.authTimeout)) s")
        }
        if findState.machine.nextDeadline.map({ now >= $0 }) == true {
            performFind(findState.machine.tick(now: now))
        }
        if var editor = alarmEditor, editor.nextDeadline.map({ now >= $0 }) == true {
            let out = editor.tick(now: now)
            alarmEditor = editor
            performAlarm(out)
        }
        if var editor = settingsEditor, editor.nextDeadline.map({ now >= $0 }) == true {
            let out = editor.tick(now: now)
            settingsEditor = editor
            performSettings(out)
        }
        if let stepDeadline, now >= stepDeadline {
            helioLog.notice("helio: setup step \(String(describing: self.currentStep), privacy: .public) timed out")
            nextSetupStep()
        }
        if liveHeartRateRunning {
            if let end = liveHREndsAt, now >= end {
                stopLiveHeartRate()
            } else if liveHeartRateOwner == .workout, let started = liveHRStartedAt,
                      now.timeIntervalSince(max(liveHRAt ?? started, started)) >= Self.workoutStreamRestartAfter {
                helioLog.notice("helio: workout heart rate stalled; sending start again")
                send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
                liveHRStartedAt = now
                liveHRKeepAliveAt = now.addingTimeInterval(1)
            } else if let next = liveHRKeepAliveAt, now >= next {
                send(ZeppEndpoint.heartRate, ZeppHeartRateControl.keepRunning)
                liveHRKeepAliveAt = now.addingTimeInterval(1)
            }
        }
        if phase == .syncing, let last = lastFetchProgressAt, now.timeIntervalSince(last) > Self.syncStallTimeout {
            helioLog.error("helio: sync stalled; aborting with 03 09")
            if var fetch {
                let actions = fetch.abort()
                self.fetch = fetch
                perform(actions)
            }
            finishFetch(interrupted: true)
        }
    }

    // MARK: Auth (§4)

    private func startAuthentication() {
        guard var link else { return }
        helioLog.notice("helio: authenticating")
        let out = link.startAuthentication()
        self.link = link
        handle(out)
    }

    private func failAuthentication(busy: Bool, reason: String) {
        authDeadline = nil
        link = nil
        phase = busy ? .strapBusy : .keyRejected
        helioLog.error("helio: auth failed (\(reason, privacy: .public))")
        startTierZero()
    }

    private func handle(_ out: ZeppLink.Output) {
        for write in out.writes { transport?.write(write) }
        for event in out.events {
            switch event {
            case .authenticated:
                authDeadline = nil
                helioLog.notice("helio: authenticated")
                // §16.1/§16.5: the strap reaches an idle link through `…0017` only. `…0016` was
                // subscribed for auth (as HelioVerify proved it on a real strap) and carries nothing
                // but the strap's chunk acks to our own writes, which are not used; it's turned off for
                // the rest of the connection.
                if chunkedWriteSubscribed {
                    chunkedWriteSubscribed = false
                    transport?.setNotify(.chunkedWrite, enabled: false)
                }
                beginSetup()
            case .authenticationFailed(.wrongAuthKey):
                // Decision 7: "key rejected", never a retry loop. The mark stays until the key changes.
                keyStore?.markRejected()
                failAuthentication(busy: false, reason: "10 05 25, wrong key")
            case .authenticationFailed(let failure):
                failAuthentication(busy: true, reason: "\(failure)")
            case .message(let message):
                handleMessage(message)
            case .undecryptable(let endpoint):
                helioLog.error("helio: could not decrypt a message on 0x\(String(format: "%04x", endpoint), privacy: .public)")
            case .droppedChunk, .deviceChunkAck:
                break
            }
        }
    }

    private func send(_ endpoint: UInt16, _ payload: [UInt8]) {
        guard var link else { return }
        lastSentAt[endpoint] = clock()
        do {
            let writes = try link.send(endpoint: endpoint, payload: payload)
            self.link = link
            for write in writes { transport?.write(write) }
        } catch {
            helioLog.error("helio: cannot send to 0x\(String(format: "%04x", endpoint), privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ messages: [ZeppControlMessage]) {
        for message in messages { send(message.endpoint, message.payload) }
    }

    // MARK: Setup (§5, §11–§14)

    private func beginSetup() {
        phase = .settingUp
        setupQueue = [.servicesList, .deviceInfo, .battery, .setTime, .healthConfig,
                      .findCapabilities, .alarms, .alertCapabilities, .alertSettings]
        nextSetupStep()
    }

    private func nextSetupStep() {
        currentStep = nil
        stepDeadline = nil
        while !setupQueue.isEmpty {
            let step = setupQueue.removeFirst()
            // Marked current BEFORE the request goes out, so a reply that arrives within the same
            // call still finds its step.
            currentStep = step
            stepDeadline = clock().addingTimeInterval(Self.stepTimeout)
            if run(step) { return }
            currentStep = nil
            stepDeadline = nil
        }
        setupFinished()
    }

    /// Sends the step's request. true when a reply is awaited.
    private func run(_ step: SetupStep) -> Bool {
        let listed = { (endpoint: UInt16) in self.services?.contains(endpoint) == true }
        switch step {
        case .servicesList:
            send(ZeppEndpoint.servicesList, ZeppServicesList.request)
            return true
        case .deviceInfo:
            guard listed(ZeppEndpoint.deviceInfo) else { return false }
            send(ZeppEndpoint.deviceInfo, ZeppDeviceInfo.request)
            return true
        case .battery:
            guard listed(ZeppEndpoint.battery) else { return false }
            send(ZeppEndpoint.battery, ZeppBatteryStatus.request)
            return true
        case .setTime:
            // Decision 9: the phone's current local time on every connection, after auth. No DST
            // transition command (`07`) in v1.
            let now = clock()
            if listed(ZeppEndpoint.time) {
                send(ZeppEndpoint.time, ZeppTimeCommand.setTime(now, timeZone: .current))
                return true
            }
            if transport?.has(.currentTime) == true {
                // SPEC-GAP: the 0x2A2B fallback has no reply, so it never enables alarm edits (§14).
                transport?.write(ZeppWrite(.currentTime, ZeppTimeCommand.currentTimeBytes(now, timeZone: .current)))
                helioLog.notice("helio: clock set via 0x2A2B (no reply)")
            }
            return false
        case .healthConfig:
            guard listed(ZeppEndpoint.config) else { return false }
            // The hardware-validated read (#223): byte-identical to what HelioVerify sent on a real
            // strap (§10.1 item 8), `03 00 08 07 01 04 05 11 12 13 31`. It includes `0x04`, which is
            // read but never shown as a warning (`recordingWarnings`).
            let request = ZeppConfig.readRequest(group: ZeppConfig.healthGroup, arguments: ZeppConfig.healthReadArguments)
            let spaced = request.map { String(format: "%02x", $0) }.joined(separator: " ")
            helioLog.notice("helio: HEALTH read \(spaced, privacy: .public)")   // control bytes only
            send(ZeppEndpoint.config, request)
            return true
        case .findCapabilities:
            // Sends a stop owed since a link loss first (decision 18), then the read-only `01`.
            let out = findState.machine.connected(controlCapabilities)
            performFind(out)
            return controlCapabilities.isSupported(.findDevice)
        case .alarms:
            guard var editor = alarmEditor, controlCapabilities.isSupported(.alarms) else { return false }
            do {
                let out = try editor.read(now: clock())
                alarmEditor = editor
                performAlarm(out)
                return true
            } catch {
                return false
            }
        case .alertCapabilities:
            guard controlCapabilities.isSupported(.hapticAlerts) else { return false }
            send(ZeppEndpoint.config, ZeppConfigCapabilities.request)
            return true
        case .alertSettings:
            guard configCapabilities?.groups.contains(ZeppConfig.healthGroup) == true else { return false }
            send(ZeppEndpoint.config, ZeppHapticAlertSettings.readRequest)
            return true
        }
    }

    private func advance(from step: SetupStep) {
        guard currentStep == step else { return }
        nextSetupStep()
    }

    private func setupFinished() {
        phase = .ready
        helioLog.notice("helio: ready (clock \(self.clockSet ? "set" : "NOT set", privacy: .public), controls: find \(self.controlCapabilities.isSupported(.findDevice), privacy: .public), alarms \(self.controlCapabilities.isSupported(.alarms), privacy: .public))")
        sendOwedOrphanStop()   // before any stream or sync (review-238 SF2)
        if autoSyncOnConnect {
            syncHistory(manual: false)
            if !appInBackground { activationSyncSettled = true }
        }
    }

    private func handleMessage(_ message: ZeppMessage) {
        let payload = message.payload
        if isStrapInitiated(message) {
            onEvent(.strapMessage(endpoint: message.endpoint, opcode: Self.opcode(of: message), length: payload.count))
        }
        switch message.endpoint {
        case ZeppEndpoint.servicesList:
            guard currentStep == .servicesList else { return }
            if let list = ZeppServicesList.parse(payload) {
                services = list
                link?.apply(servicesList: list)
                controlCapabilities = ZeppControlCapabilities(model: model, isAuthenticated: isAuthenticated, services: list)
                alarmEditor = ZeppAlarmEditor(capabilities: controlCapabilities)
                settingsEditor = ZeppSettingsEditor(capabilities: controlCapabilities)
                helioLog.notice("helio: services list, \(list.entries.count) endpoints")
            } else {
                helioLog.error("helio: malformed services list; controls stay off")
            }
            advance(from: .servicesList)
        case ZeppEndpoint.deviceInfo:
            if let info = ZeppDeviceInfo.parse(payload), !info.isAmbiguous {
                // A mis-located field could shift the serial number into a version (the SPEC-GAP in
                // ZeppDeviceInfo.parse). When DIS gave a hardware revision and this one differs, keep
                // neither version (HelioVerify's rule).
                if let dis = disHardwareRevision, let hardware = info.hardwareVersion, dis != hardware {
                    helioLog.notice("helio: device info disagrees with DIS; versions withheld")
                } else {
                    if let hardware = info.hardwareVersion { hardwareVersion = hardware }
                    if let firmware = info.firmwareVersion { firmwareVersion = firmware }
                }
            }
            advance(from: .deviceInfo)
        case ZeppEndpoint.battery:
            if let battery = ZeppBatteryStatus.parse(payload) {
                batteryPercent = battery.level
                charging = battery.isCharging ?? false
            }
            advance(from: .battery)
        case ZeppEndpoint.time:
            guard currentStep == .setTime else { return }
            clockSet = ZeppTimeCommand.isSuccessReply(payload)
            if var editor = alarmEditor {
                editor.noteTimeSetReply(payload)
                alarmEditor = editor
            }
            helioLog.notice("helio: clock \(self.clockSet ? "set" : "set: unexpected reply", privacy: .public)")
            advance(from: .setTime)
        case ZeppEndpoint.config:
            handleConfig(payload)
        case ZeppEndpoint.findDevice:
            performFind(findState.machine.receive(payload, now: clock()))
        case ZeppEndpoint.alarms:
            guard var editor = alarmEditor else { return }
            let out = editor.receive(payload, now: clock())
            alarmEditor = editor
            performAlarm(out)
        case ZeppEndpoint.connection:
            switch payload.first {
            case 0x03?:
                // §3.5, §16.5: a ping `03` is answered `04` on the same endpoint, the one unsolicited
                // message that needs a reply. An unanswered ping may be what drops an idle link.
                send(ZeppEndpoint.connection, [0x04])
            case 0x02? where payload.count >= 3:
                // §16.2 row 13, §16.5: an MTU announce (u16 LE = MTU − 3). Chunk at the smaller of it
                // and what CoreBluetooth allows; nothing is sent back.
                let announced = Int(payload[1]) | Int(payload[2]) << 8
                if announced >= 20, var link {
                    link.setMaxWriteLength(min(announced, transport?.maxWriteLength ?? announced))
                    self.link = link
                }
            default:
                break
            }
        case ZeppEndpoint.heartRate:
            // §16.2 rows 1–2, §16.4: the sleep events arrive on the `…0017` subscription every session
            // has; nothing is written to the strap to get them (decision 33). 🔴 whether the Helio
            // sends them, so they are an opportunistic hint and nothing depends on them. They carry
            // no time: the connection fetches history, and only the night selection writes sleep.
            switch ZeppHeartRateControl.parse(payload) {
            case .fellAsleep?: onEvent(.fellAsleep)
            case .wokeUp?: onEvent(.wokeUp)
            case .controlReply?, nil: break
            }
        case ZeppEndpoint.realtimeSteps where payload.first == 0x07:
            // §16.2 row 5, §16.5: realtime steps flowing unasked means someone else turned the
            // persistent stream on. `05 00` once undoes that and records nothing. Never `05 01`.
            if !realtimeStepsOffSent {
                realtimeStepsOffSent = true
                send(ZeppEndpoint.realtimeSteps, [0x05, 0x00])
            }
        case ZeppEndpoint.activityFetch:
            // Path B replies (§6.1). The app drives Path A, so this only arrives if the strap answers there.
            guard var fetch else { return }
            lastFetchProgressAt = clock()
            let actions = fetch.receiveControl(payload)
            self.fetch = fetch
            perform(actions)
        default:
            break
        }
    }

    private func handleConfig(_ payload: [UInt8]) {
        switch currentStep {
        case .healthConfig?:
            if let reply = ZeppConfig.parseReadReply(payload), reply.group == ZeppConfig.healthGroup {
                recordingWarnings = Self.recordingWarnings(ZeppHealthSettings(reply))
                helioLog.notice("helio: HEALTH reply read, \(self.recordingWarnings.count, privacy: .public) recording warning(s)")
            } else {
                helioLog.notice("helio: HEALTH reply unreadable; no recording warnings")
            }
            advance(from: .healthConfig)
        case .alertCapabilities?:
            configCapabilities = ZeppConfigCapabilities.parse(payload)
            settingsEditor?.noteConfigCapabilities(configCapabilities)
            advance(from: .alertCapabilities)
        case .alertSettings?:
            let reply = ZeppConfig.parseReadReply(payload)
            hapticAlerts = ZeppHapticAlertSettings(capabilities: controlCapabilities,
                                                   configCapabilities: configCapabilities, healthReply: reply)
            advance(from: .alertSettings)
        default:
            // Outside setup, config replies belong to the settings editor (#228, #229, #230).
            guard var editor = settingsEditor else { return }
            // §17.8 step 1, checked again NOW: a pre-read's reply releases the write only if no sync
            // started and the app didn't go to the background since the tap (review-240 S1, S2).
            settingsWriteBlockedReason = settingsWriteBlockedNow
            let out = editor.receive(payload, now: clock(), mayWrite: settingsWriteBlockedReason == nil)
            settingsEditor = editor
            performSettings(out)
        }
    }

    // MARK: History fetch (§6), decisions 8, 10

    private func startFetch() {
        guard let sink else { return finishFetch(interrupted: true) }
        let now = clock()
        let plan = HelioFetchPlan.plan(cursors: sink.fetchCursors(timeline: timeline, now: now), now: now,
                                       notBefore: sink.notBefore(timeline: timeline, now: now))
        sink.beginSync(timeline: timeline, now: now)
        syncCounts = (0, 0, 0)
        var machine = ZeppHistoryFetch(plan: plan, now: now, configuration: .init(ackPolicy: Self.ackPolicy))
        let actions = machine.start()
        fetch = machine
        lastFetchProgressAt = now
        perform(actions)
    }

    private func perform(_ actions: [ZeppHistoryFetch.Action]) {
        for action in actions {
            switch action {
            case .sendControl(let bytes):
                if bytes.count == 2, bytes[0] == ZeppFetchCommand.ackMarker { fetchAcksSent.append(bytes[1]) }
                transport?.write(ZeppWrite(.activityControl, bytes))
            case .roundReady(let round):
                let durable = sink?.persist(round, timeline: timeline, now: clock()) ?? false
                if durable { syncCounts.stored += 1 } else { syncCounts.failed += 1 }
                helioLog.notice("helio: round \(round.type.displayName, privacy: .public) \(round.parsed.records.count) record(s) \(durable ? "stored" : "NOT stored", privacy: .public); ack 03 09")
                guard var machine = fetch else { continue }
                let next = machine.commit(roundID: round.id, durable: durable)
                fetch = machine
                perform(next)
            case .roundFailed(let type, let failure):
                syncCounts.failed += 1
                helioLog.error("helio: round \(type.displayName, privacy: .public) failed (\(String(describing: failure), privacy: .public))")
            case .noData:
                syncCounts.empty += 1
            case .finished:
                finishFetch(interrupted: false)
            }
        }
    }

    private func finishFetch(interrupted: Bool) {
        guard phase == .syncing || fetch != nil else { return }
        fetch = nil
        pendingNotify.subtract([.activityControl, .activityData])
        if isLinkConnected {
            transport?.setNotify(.activityControl, enabled: false)
            transport?.setNotify(.activityData, enabled: false)
        }
        var result = sink?.finishSync(timeline: timeline, now: clock()) ?? HelioSyncResult()
        result.roundsStored = syncCounts.stored
        result.roundsFailed = syncCounts.failed
        result.typesEmpty = syncCounts.empty
        result.interrupted = interrupted
        result.endedInBackgroundRun = backgroundRunOwnsSyncs
        result.identity = identity
        result.nightsFinalized = finalizeNightsOnHandOff
        finalizeNightsOnHandOff = nil
        let now = clock()
        lastSyncResult = result
        syncsFinished += 1
        if let today = result.todaySteps { steps = today }
        if !interrupted { lastSyncAt = now }
        if phase == .syncing { phase = .ready }
        syncStatus = Self.status(for: result)
        helioLog.notice("helio: sync finished: \(result.roundsStored, privacy: .public) stored, \(result.roundsFailed, privacy: .public) failed, \(result.typesEmpty, privacy: .public) empty, \(result.nights.count, privacy: .public) night(s)\(interrupted ? ", interrupted" : "", privacy: .public)")
        if isLinkConnected, services?.contains(ZeppEndpoint.battery) == true {
            send(ZeppEndpoint.battery, ZeppBatteryStatus.request)
        }
        let timeline = self.timeline
        Task { @MainActor in await self.onSyncFinished(result, timeline) }
    }

    /// Plain-language warnings for the HEALTH switches that stop the strap RECORDING something
    /// (§5.5), off only when the strap reported them off (unknown is not off). HEALTH `0x04` ("Active
    /// HR monitoring") is a sampling boost during activity, not a recording switch, so it is never a
    /// warning; neither is heart-rate sharing, which only affects live broadcast without a key.
    static func recordingWarnings(_ settings: ZeppHealthSettings) -> [String] {
        var out: [String] = []
        if settings.heartRateMonitoring == 0x00 {
            out.append("All-day heart rate is off, so heart rate, resting heart rate and HRV history may be missing.")
        }
        if settings.highAccuracySleep == false {
            out.append("High-accuracy sleep monitoring is off, so sleep stages may be missing.")
        }
        if settings.sleepBreathingQuality == false {
            out.append("Sleep breathing quality is off, so sleep respiratory rate may be missing.")
        }
        if settings.stressMonitoring == false { out.append("Stress monitoring is off, so stress will be empty.") }
        if settings.allDaySpO2 == false { out.append("All-day SpO₂ is off, so automatic SpO₂ readings will be empty.") }
        return out
    }

    static func status(for result: HelioSyncResult) -> String {
        if result.interrupted { return "Sync interrupted: what arrived is saved, the rest stays on the strap" }
        if result.roundsFailed > 0 { return "Synced with \(result.roundsFailed) failed round(s); they stay on the strap for next time" }
        return result.roundsStored == 0 ? "Up to date" : "Synced"
    }

    // MARK: What the strap sends on its own (#233)

    /// A message this session didn't ask for: one of the strap-to-phone messages the spec lists (§16.2),
    /// or anything on an endpoint this session hasn't sent to in the last `replyWindow`. Its time is its
    /// arrival, which is "at or before now" for the strap: whether it queues messages is unknown.
    private func isStrapInitiated(_ message: ZeppMessage) -> Bool {
        let first = message.payload.first
        switch message.endpoint {
        case ZeppEndpoint.heartRate where first == 0x06: return true                     // sleep events, §16.2
        case ZeppEndpoint.connection where first == 0x03 || first == 0x02: return true   // ping, MTU, §16.2
        case ZeppEndpoint.realtimeSteps where first == 0x07: return true                 // steps, §16.2 row 5
        case Self.workoutEndpoint where first == 0x20 || first == 0x11: return true      // workout, §16.2 rows 8–9
        case ZeppEndpoint.alarms where first == 0x0f: return true                        // edited on the strap, §12.5
        case ZeppEndpoint.findDevice where [0x07, 0x11, 0x13].contains(first): return true  // §11.3, §11.5
        default: return !within(Self.replyWindow, of: lastSentAt[message.endpoint], now: clock())
        }
    }

    /// The opcode bytes logged for a message: its first byte, and the event byte too for the sleep
    /// events (`06 01` / `06 00`). Never more: the rest can be a measurement.
    static func opcode(of message: ZeppMessage) -> [UInt8] {
        let isSleepEvent = message.endpoint == ZeppEndpoint.heartRate && message.payload.first == 0x06
        return Array(message.payload.prefix(isSleepEvent ? 2 : 1))
    }

    /// §16.5: standard heart rate that nothing on this connection asked for. Do what Gadgetbridge does,
    /// once: `04 00` on `0x001D` (with a key) and unsubscribe. It only stops a stream.
    private func heartRateFailSafe() {
        // Never the workout's own stream (#227, review-238 B1 d). It can't reach here today (a running
        // stream is never "unasked for"); the guard keeps it that way.
        guard !heartRateFailSafeSent, liveHeartRateOwner != .workout else { return }
        heartRateFailSafeSent = true
        if isAuthenticated, services?.contains(ZeppEndpoint.heartRate) == true {
            send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
        }
        transport?.setNotify(.heartRateMeasurement, enabled: false)
    }

    /// The chunk size this connection's link uses (for tests of the MTU announce).
    var chunkWriteLength: Int? { link?.transport.maxWriteLength }

    private func within(_ window: TimeInterval, of time: Date?, now: Date) -> Bool {
        guard let time else { return false }
        return now >= time && now.timeIntervalSince(time) <= window
    }

    // MARK: Live heart rate (§7.1)

    /// Tier 0 (decision 7): listen to standard heart rate without auth. Shown only if it arrives.
    private func startTierZero() {
        // §16.5: nothing is subscribed for display while the app is in the background.
        guard !appInBackground, !tierZeroSubscribed, let transport, transport.has(.heartRateMeasurement),
              transport.canNotify(.heartRateMeasurement) else { return }
        tierZeroSubscribed = true
        transport.setNotify(.heartRateMeasurement, enabled: true)
    }

    private func stopTierZero() {
        // The 0x2A37 subscription is the workout stream's too: never dropped under it (#227).
        guard tierZeroSubscribed, liveHeartRateOwner != .workout else { return }
        tierZeroSubscribed = false
        transport?.setNotify(.heartRateMeasurement, enabled: false)
    }

    /// The authenticated stream: start, then `04 02` every second, stop after `duration`.
    func startLiveHeartRate(duration: TimeInterval = 60) {
        guard canStreamHeartRate, !liveHeartRateRunning, let transport else { return }
        // A new measurement shows only its own readings (decision 30), never the last one's.
        liveHR = nil
        liveHRAt = nil
        transport.setNotify(.heartRateMeasurement, enabled: true)
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
        let now = clock()
        liveHRKeepAliveAt = now.addingTimeInterval(1)
        liveHREndsAt = now.addingTimeInterval(duration)
        liveHeartRateRunning = true
        liveHeartRateOwner = .measure
    }

    /// A workout's stream (#227): the same start and 1 s `04 02` keep-alive, with no time limit, until
    /// `stopWorkoutHeartRate()` (or the link drops). A running Measure is taken over, not restarted.
    // SPEC-GAP: §7.1 gives no maximum stream duration; none is applied here (see
    // `workoutStreamRestartAfter` for a strap that stops by itself).
    func startWorkoutHeartRate() {
        guard canStreamHeartRate, let transport else { return }
        let now = clock()
        if liveHeartRateRunning {
            liveHeartRateOwner = .workout
            liveHREndsAt = nil
            liveHRStartedAt = now
            return
        }
        transport.setNotify(.heartRateMeasurement, enabled: true)
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
        liveHRKeepAliveAt = now.addingTimeInterval(1)
        liveHREndsAt = nil
        liveHRStartedAt = now
        liveHeartRateRunning = true
        liveHeartRateOwner = .workout
    }

    /// Stops the stream only if a workout owns it.
    func stopWorkoutHeartRate() {
        guard liveHeartRateOwner == .workout else { return }
        stopLiveHeartRate()
    }

    /// Review-238 SF2: a killed process's workout stream is owed one `04 00` (§7.1), set by the
    /// recorder's launch recovery (`StrapWorkoutOrphanStop`). Sent at this connection's first
    /// authenticated `ready` (`setupFinished`, before any stream or sync) or at once if already ready,
    /// then cleared. A stream this connection runs itself means the strap streams for us now: nothing
    /// to stop, so it's only cleared. A strap without the heart-rate endpoint never streamed: cleared.
    func sendOwedOrphanStop() {
        guard orphanStop.owed, isAuthenticated else { return }
        if canStreamHeartRate, !liveHeartRateRunning {
            send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
            helioLog.notice("helio: sent the 04 00 owed since an interrupted workout")
        }
        orphanStop.owed = false
    }

    func stopLiveHeartRate() {
        guard liveHeartRateRunning else { return }
        liveHeartRateRunning = false
        liveHeartRateOwner = nil
        liveHRStoppedAt = clock()
        liveHRKeepAliveAt = nil
        liveHREndsAt = nil
        liveHRStartedAt = nil
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
        transport?.setNotify(.heartRateMeasurement, enabled: false)
    }

    // MARK: Find my strap and buzz (§11, §13.2), decisions 18, 19, 22

    /// Starts "find device". Stops by itself after 60 s. nil on success, else why it didn't start.
    @discardableResult
    func startFind() -> String? {
        do {
            let out = try findState.machine.start(now: clock())
            helioLog.notice("helio: find START")
            performFind(out)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func stopFind() {
        guard findState.machine.isBuzzing else { return }
        helioLog.notice("helio: find STOP (user or screen left)")
        performFind(findState.machine.stop())
    }

    /// One short buzz (2 s): find start, then stop.
    @discardableResult
    func buzz() -> String? {
        do {
            let out = try findState.machine.buzz(now: clock())
            helioLog.notice("helio: buzz")
            performFind(out)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    private func performFind(_ out: ZeppFindDevice.Output) {
        send(out.messages)
        findState.persist()
        findPhase = findState.machine.state
        for event in out.events {
            switch event {
            case .capabilities(let version):
                findVersion = version
                advance(from: .findCapabilities)
            case .stopped(let reason):
                helioLog.notice("helio: find stopped (\(String(describing: reason), privacy: .public))")
            case .owedStopSent:
                helioLog.notice("helio: sent the find stop owed since the link dropped")
            default:
                break
            }
        }
    }

    // MARK: Alarms (§12, §15.2), decision 20

    /// Re-reads the strap's list. Read-only.
    func readAlarms() {
        guard var editor = alarmEditor else { return }
        do {
            let out = try editor.read(now: clock())
            alarmEditor = editor
            performAlarm(out)
        } catch {
            alarmNotice = Self.describe(error)
        }
    }

    /// A new alarm in the lowest free slot. nil when the write went out. `quiet`: a write the person
    /// didn't make on the Alarms screen (Shortcuts' wake alarm, review-261 N2) leaves that screen's
    /// `alarmNotice` alone, from the write to its re-read.
    @discardableResult
    func addAlarm(hour: UInt8, minute: UInt8, days: ZeppAlarmDays, quiet: Bool = false) -> String? {
        editAlarm(quiet: quiet) { try $0.add(hour: hour, minute: minute, days: days, isEnabled: true, now: self.clock()) }
    }

    /// Replaces one slot (an edit, or enable/disable).
    @discardableResult
    func replaceAlarm(_ alarm: ZeppAlarm, quiet: Bool = false) -> String? {
        editAlarm(quiet: quiet) { try $0.replace(alarm, now: self.clock()) }
    }

    @discardableResult
    func deleteAlarm(slot: UInt8, quiet: Bool = false) -> String? {
        editAlarm(quiet: quiet) { try $0.delete(slot: slot, now: self.clock()) }
    }

    private func editAlarm(quiet: Bool, _ body: (inout ZeppAlarmEditor) throws -> ZeppAlarmEditor.Output) -> String? {
        guard var editor = alarmEditor else { return "Alarms aren't available on this connection." }
        do {
            let out = try body(&editor)
            alarmEditor = editor
            quietAlarmWrite = quiet
            if !quiet { alarmNotice = "Saving to the strap…" }
            performAlarm(out)
            return nil
        } catch {
            let reason = Self.describe(error)
            if !quiet { alarmNotice = reason }
            return reason
        }
    }

    /// The write in flight is a quiet one (`addAlarm(…, quiet: true)`): its outcome leaves `alarmNotice`.
    @ObservationIgnored private var quietAlarmWrite = false

    private func performAlarm(_ out: ZeppAlarmEditor.Output) {
        send(out.messages)
        for event in out.events {
            switch event {
            case .listRead(let alarms):
                helioLog.notice("helio: alarm list read, \(alarms.count, privacy: .public) alarm(s)")
                if currentStep == .alarms { onSetupAlarmsRead?() }
                advance(from: .alarms)
            case .listUnreadable(let error):
                alarmNotice = "Couldn't read the strap's alarms."
                helioLog.error("helio: alarm list unreadable (\(String(describing: error), privacy: .public))")
                advance(from: .alarms)
            case .changedOnStrap:
                alarmNotice = "The strap's alarms changed. Reading them again."
                readAlarms()
            case .writeAcknowledged(let write):
                helioLog.notice("helio: alarm slot \(write.slot, privacy: .public) acknowledged; reading back")
            case .writeFailed(let write, let failure):
                if !quietAlarmWrite { alarmNotice = "The strap didn't confirm the change. Nothing was retried." }
                quietAlarmWrite = false
                helioLog.error("helio: alarm slot \(write.slot, privacy: .public) write failed (\(String(describing: failure), privacy: .public))")
            case .writeChecked(let check):
                if !quietAlarmWrite {
                    alarmNotice = check.slotMatches && check.otherSlotsUnchanged
                        ? "Saved on the strap."
                        : "The strap's list doesn't match what was saved. Check it below."
                }
                quietAlarmWrite = false
                helioLog.notice("helio: alarm slot \(check.write.slot, privacy: .public) re-read: matches \(check.slotMatches, privacy: .public), others unchanged \(check.otherSlotsUnchanged, privacy: .public)")
            case .writeUnverified:
                if !quietAlarmWrite { alarmNotice = "Saved, but the strap's list couldn't be read back." }
                quietAlarmWrite = false
            }
            alarmEventObserver?(event)
        }
    }

    // MARK: Strap settings (§17, §19), #228, #229, #230

    /// Settings can be read: authenticated, set up, the link up, and the config endpoint offered.
    /// Never during setup, whose own config reads are routed by step.
    var canReadStrapSettings: Bool {
        isLinkConnected && isAuthenticated && (phase == .ready || phase == .syncing)
            && settingsEditor?.capabilities.isSupported(.hapticAlerts) == true
    }

    /// Settings can be changed: as above, not during a history fetch (§17.8 step 1), and not from the
    /// background. Checked at the tap AND again when the write would leave (`settingsWriteBlockedNow`).
    var canChangeStrapSettings: Bool { canReadStrapSettings && settingsWriteBlockedNow == nil }

    /// Why a config write may not leave right now; nil when it may. `syncHistory` never waits on the
    /// editor: a sync always wins, and a change caught by one is refused, not queued.
    private var settingsWriteBlockedNow: String? {
        if appInBackground { return "Not saved: the app went to the background. Try again with the app open." }
        if phase == .syncing { return "Not saved: a sync started. Try again when it finishes." }
        if phase != .ready || !isLinkConnected { return "Not saved: the strap isn't ready for changes right now." }
        return nil
    }

    /// The reason the latest pre-read reply was not allowed to release its write.
    @ObservationIgnored private var settingsWriteBlockedReason: String?

    /// Reads the groups in full, with constraints. Read-only. A fresh read clears the last outcome.
    func readStrapSettings(groups: [UInt8]) {
        guard canReadStrapSettings, var editor = settingsEditor else { return }
        if editor.changeInFlight == nil { settingsNotice = nil }
        do {
            let out = try editor.read(groups: groups, now: clock())
            settingsEditor = editor
            performSettings(out)
        } catch {
            settingsNotice = HelioSettingsNotice(groups: groups, text: Self.describe(error))
        }
    }

    /// One user edit of one setting: `from` is the value the screen showed. nil when the change
    /// went out to the strap (a fresh read first, then the write, then a re-read), else why not.
    @discardableResult
    func changeStrapSetting(_ setting: ZeppSetting, from: ZeppConfigValue, to: ZeppConfigValue) -> String? {
        guard canChangeStrapSettings, var editor = settingsEditor else {
            // Refused, not queued: the user tries again.
            let reason: String
            if appInBackground {
                reason = "Settings can be changed with the app open."
            } else if phase == .syncing {
                reason = "Settings can be changed when the sync finishes."
            } else {
                reason = "The strap isn't ready for changes right now."
            }
            settingsNotice = HelioSettingsNotice(setting: setting, text: reason)
            return reason
        }
        do {
            let out = try editor.change(.init(setting: setting, from: from, to: to), now: clock())
            settingsEditor = editor
            settingsNotice = HelioSettingsNotice(setting: setting, text: "Saving to the strap…")
            performSettings(out)
            return nil
        } catch {
            let reason = Self.describe(error)
            settingsNotice = HelioSettingsNotice(setting: setting, text: reason)
            return reason
        }
    }

    private func performSettings(_ out: ZeppSettingsEditor.Output) {
        send(out.messages)
        // §17.8 step 7: group, arg, old and new value and the ack status, logged on the device only
        // (settings, not health data, but personal: never `.public`).
        for event in out.events {
            switch event {
            case .read(let group):
                if group == ZeppConfig.healthGroup, let snapshot = settingsEditor?.snapshot {
                    // The recording warnings follow the strap's current values.
                    recordingWarnings = Self.recordingWarnings(ZeppHealthSettings(snapshot))
                }
                cacheSettingsForDisplay()
                helioLog.notice("helio: config group \(group, privacy: .public) read")
            case .readFailed(let group, let failure):
                settingsNotice = HelioSettingsNotice(groups: [group], text: "Couldn't read the strap's settings.")
                helioLog.error("helio: config group \(group, privacy: .public) unreadable (\(String(describing: failure), privacy: .public))")
            case .changedOnStrap(let change, _):
                settingsNotice = HelioSettingsNotice(setting: change.setting,
                                                     text: "This setting changed on the strap since you opened the screen. Nothing was saved; check it and try again.")
                helioLog.notice("helio: config \(change.setting.group, privacy: .public)/\(change.setting.argument, privacy: .public) changed on the strap; not written")
            case .refused(let change, let error):
                // `.busy` here is the write gate (no other change can be in flight): say why.
                let text = error == .busy
                    ? (settingsWriteBlockedReason ?? "Not saved: the strap isn't ready for changes right now.")
                    : Self.describe(error) + " Nothing was saved."
                settingsNotice = HelioSettingsNotice(setting: change.setting, text: text)
                helioLog.notice("helio: config \(change.setting.group, privacy: .public)/\(change.setting.argument, privacy: .public) refused after the fresh read")
            case .writeAcknowledged(let change):
                helioLog.notice("helio: config \(change.setting.group, privacy: .public)/\(change.setting.argument, privacy: .public) \(String(describing: change.from), privacy: .private) → \(String(describing: change.to), privacy: .private): 06 01; reading back")
            case .writeNotAcknowledged(let change, let failure):
                helioLog.error("helio: config \(change.setting.group, privacy: .public)/\(change.setting.argument, privacy: .public) \(String(describing: change.from), privacy: .private) → \(String(describing: change.to), privacy: .private): \(String(describing: failure), privacy: .public); reading back, no retry")
            case .writeChecked(let check):
                if check.change.setting.group == ZeppConfig.healthGroup, let snapshot = settingsEditor?.snapshot {
                    recordingWarnings = Self.recordingWarnings(ZeppHealthSettings(snapshot))
                }
                cacheSettingsForDisplay()
                settingsNotice = HelioSettingsNotice(setting: check.change.setting, text: Self.notice(for: check))
                helioLog.notice("helio: config \(check.change.setting.group, privacy: .public)/\(check.change.setting.argument, privacy: .public) re-read: took the change \(check.tookChange, privacy: .public), group version changed \(check.groupVersionChanged, privacy: .public)")
            case .writeUnverified(let change, let failure, let readFailure):
                settingsNotice = HelioSettingsNotice(setting: change.setting, text: failure == nil
                    ? "The strap confirmed the change, but the setting couldn't be read back. Reopen this screen to check."
                    : "The strap didn't confirm the change, and the setting couldn't be read back. Reopen this screen to check.")
                helioLog.error("helio: config \(change.setting.group, privacy: .public)/\(change.setting.argument, privacy: .public) unverified (\(String(describing: readFailure), privacy: .public))")
            }
        }
    }

    /// Whether the Measurement screen can turn ON every recording switch that reads off right now
    /// (review-240 N3, review-240b N-a): the Today card only points there when it can. That means the
    /// HEALTH group was read on this connection, a change may be written now (`canChangeStrapSettings`),
    /// and for each switch that reads off the strap both allows a change (`availability == .available`)
    /// and offers a value other than off, which is the same condition the row uses to enable its
    /// control. An empty or off-only allowed list can't turn anything on (§17.6).
    var canFixRecordingWarningsHere: Bool {
        guard canChangeStrapSettings, let editor = settingsEditor, editor.hasRead(group: ZeppConfig.healthGroup) else { return false }
        let snapshot = editor.snapshot
        let off = ZeppSetting.measurement.filter { setting in
            guard let value = snapshot.value(setting) else { return false }
            return value == .bool(false) || value == .byte(0)
        }
        return off.allSatisfy { setting in
            snapshot.availability(setting) == .available
                && snapshot.options(setting).contains { $0 != .bool(false) && $0 != .byte(0) }
        }
    }

    private func cacheSettingsForDisplay() {
        if let snapshot = settingsEditor?.snapshot { HelioSettingsDisplayCache.store(snapshot, strap: identityID, at: clock()) }
    }

    /// The outcome of a write, from the strap's re-read value (§17.4: only `06 01` with the new value
    /// on re-read counts as taken).
    static func notice(for check: ZeppSettingsEditor.WriteCheck) -> String {
        if check.readBack == nil { return "The strap no longer reports this setting, so it's hidden until the strap reconnects." }
        if check.groupVersionChanged { return "The strap's settings changed version, so they're read-only until the strap reconnects." }
        return check.tookChange
            ? "Saved on the strap."
            : "The strap didn't take the change. Its current value is shown. Nothing was retried."
    }

    // MARK: Plain-language errors

    static func describe(_ error: Error) -> String {
        switch error {
        case ZeppControlError.unsupported:
            return "The strap didn't report support for this on this connection."
        case ZeppFindDevice.Error.alreadyActive:
            return "The strap is already vibrating."
        case let error as ZeppAlarmEditor.Error:
            switch error {
            case .busy: return "Another alarm change is still in progress."
            case .listMalformedThisConnection: return "The strap's alarm list couldn't be read on this connection."
            case .listNotRead: return "The alarm list hasn't been read yet."
            case .listChangedOnStrap: return "The strap's alarms changed. Review them and try again."
            case .timeNotSet: return "The strap's clock wasn't confirmed on this connection, so alarms can't be edited."
            case .noFreeSlot: return "The strap already has 10 alarms."
            case .slotEmpty: return "That alarm is no longer on the strap."
            case .smartWakeNotOffered: return "Smart wake can't be changed in this version."
            case .invalidAlarm: return "That time isn't valid."
            }
        case let error as ZeppSettingsEditor.Error:
            switch error {
            case .busy: return "Another change is still being saved."
            case .groupNotOffered: return "The strap didn't offer these settings on this connection."
            case .notRead: return "The strap's settings haven't been read on this connection."
            case .notReported: return "The strap didn't report this setting."
            case .readOnly: return "The strap's version of these settings isn't one OpenCircuit knows, so they're read-only."
            case .unchanged: return "That's already the strap's setting."
            case .valueNotAllowed: return "The strap doesn't allow that value."
            case .prerequisiteOff(_, let needs): return HelioSettingsCopy.needs(needs)
            }
        default:
            return "That didn't work."
        }
    }
}
