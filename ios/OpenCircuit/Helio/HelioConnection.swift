import CoreBluetooth
import Foundation
import Observation
import OpenCircuitKit
import UIKit
import ZeppKit

// CoreBluetooth for the Amazfit Helio Strap (#215 phase 3). Thin glue, like HelioVerify: discovery,
// characteristic lookup by UUID across every service (ZEPP_PROTOCOL.md §2), notify toggles, and
// write-without-response flow control. Every protocol decision lives in `HelioSession` / ZeppKit.
//
// Its OWN central with its own restore identifier, so the ring's central (`RingScanner`) and this one
// never share state (decision 1: the inactive device is never scanned for or connected). Created
// lazily, like the ring's (#142), so merely constructing this object never prompts for Bluetooth.
// State restoration re-adopts the strap's peripheral; a session that connects then syncs on its own.
// The BGTask and Sleep Focus wakes drive it through `HelioBackgroundLink` (#215 phase 4).

@Observable
@MainActor
final class HelioConnection: NSObject {
    static let shared = HelioConnection()

    /// Constant for the life of the app: iOS hands restored state back by this identifier.
    static let restoreIdentifier = "com.standardsoftwaresolutions.opencircuit.helio"
    /// The strap's CoreBluetooth identifier (per install, never its MAC).
    nonisolated static let savedPeripheralKey = "helio.peripheralID.v1"
    /// How long a foreground search runs before it reports "not found".
    static let scanTimeout: TimeInterval = 20

    enum State: Equatable {
        case idle
        case bluetoothOff
        case bluetoothDenied
        case searching
        case notFound
        case connecting
        case connected
    }

    private(set) var state: State = .idle
    private(set) var session: HelioSession?
    /// The link's signal strength while the find screen polls it.
    private(set) var rssi: Int?
    /// The last connection ended with the strap refusing auth in a way that looks like another
    /// phone or app holds it. Nothing retries inside that connection or on a timer (no retry loop,
    /// decision 7). The next connect clears it: "Try again", or the one `reconnectKnown()` every
    /// foreground activation makes, so a busy strap costs at most one re-auth per foreground.
    var endedBusy: Bool { endedBusyAt != nil }
    /// When it was set (decision 78d, #316). For the background paths (a run, a re-arm, the standing
    /// connect) it holds only `HelioBusyLatch.expiry`: after that they try once more.
    private(set) var endedBusyAt: Date?

    @ObservationIgnored let keyStore: any HelioKeyStoring
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [ZeppCharacteristic: CBCharacteristic] = [:]
    @ObservationIgnored private var pendingServices = 0
    @ObservationIgnored private var writeQueue: [ZeppWrite] = []
    @ObservationIgnored private var localStore: LocalStore?
    @ObservationIgnored private let findState = HelioFindState(defaults: .standard)
    @ObservationIgnored private var wantConnection = false
    @ObservationIgnored private var pendingAction: PendingAction?
    @ObservationIgnored private var scanTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var rssiTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    /// When the current link came up, for the link-down breadcrumb (does the strap drop a silent link?).
    @ObservationIgnored private var linkUpAt: Date?
    /// Background runs in progress (`HelioBackgroundLink`, review-225 S2): only serialises runs.
    @ObservationIgnored var activeBackgroundRuns = 0
    /// True only while a background run's watch loop runs (review-225b S-A). `makeSession` reads it:
    /// a session made then leaves its syncs to that run, which flushes and logs them. A session made
    /// after the loop (including during the run's teardown or Health flush) flushes and logs its own;
    /// one made before the loop is the run's only if the loop adopts it (`HelioBackgroundLink`).
    @ObservationIgnored var backgroundRunAdoptsNewSessions = false
    /// A Sleep Focus run's finalization, left when it gave up waiting for the run holding the link
    /// (`HelioBackgroundLink`, review-225b N-a); cleared when that run returns (review-225c SF-1).
    @ObservationIgnored var pendingNightsFinalization: Date?
    /// The run holding the link and a sync handed between runs (`HelioBackgroundLink`, #233 item 3).
    @ObservationIgnored var activeRun: HelioActiveRun?
    @ObservationIgnored var handOver: HelioHandOver?
    /// The link and wake breadcrumbs (#233).
    @ObservationIgnored let breadcrumbs: HelioBreadcrumbs
    /// This process was launched (or relaunched) by CoreBluetooth state restoration.
    @ObservationIgnored private(set) var restoredThisLaunch = false
    /// The first link after a restoration relaunch is the restoration's wake; later ones are reconnects.
    @ObservationIgnored private var restorationWakePending = false
    /// A background run tore the link down; arm a standing connect once the cancel has gone through
    /// (decision 33).
    @ObservationIgnored private var rearmOnDisconnect = false
    /// Where decision 33's wakes go (the strap's woke-up event, a reconnect or restoration in the
    /// background). Static, so setting it never constructs the connection for a ring user.
    static var wakeHandler: @MainActor (HelioWake) -> Void = { HelioWakeCoordinator.shared.wake($0) }
    /// Decision 35: the strap's own traffic over the idle link, checked at most every few minutes.
    @ObservationIgnored private var idleTraffic = HelioIdleTrafficGate()
    /// Review-225e SF-1: the activation sync's throttle (`HelioActivationSync`).
    @ObservationIgnored private var activationSync = HelioActivationSync()

    private enum PendingAction { case scan, reconnect, resumeRestored }

    init(keyStore: (any HelioKeyStoring)? = nil, breadcrumbs: HelioBreadcrumbs? = nil) {
        self.keyStore = keyStore ?? HelioKeyStore.shared
        self.breadcrumbs = breadcrumbs ?? .shared
        super.init()
        // Decision 18: backgrounding sends the find stop. Observed here rather than in a view, so it
        // holds whichever screen is showing.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session?.appDidEnterBackground()
                self?.stopRSSIUpdates()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                Self.becameActive(session, gate: &self.activationSync, lastCompletedSync: HelioWakeState().lastCompletedSync,
                                  now: Date())
            }
        }
    }

    // MARK: Saved strap

    nonisolated static var savedPeripheralID: String? {
        UserDefaults.standard.string(forKey: savedPeripheralKey)
    }

    /// A strap was connected before. Reads UserDefaults only: it never creates the central.
    nonisolated static var hasSavedStrap: Bool { savedPeripheralID != nil }

    /// The saved strap's timeline (`zeppos:<id>`), or nil when none was ever connected.
    nonisolated static var savedTimeline: SyncDeviceID? {
        savedPeripheralID.map { SyncDeviceID.timeline(for: .zeppOS(model: HelioSession.displayName), identityID: $0) }
    }

    func setLocalStore(_ store: LocalStore) {
        localStore = store
    }

    /// This connection has created its central (decision 1's tests: the strap's central exists only
    /// while the strap is the chosen device).
    var hasCentral: Bool { central != nil }

    // MARK: User actions

    /// Connect: to the saved strap by identifier, else by a foreground search.
    func connect() {
        endedBusyAt = nil
        wantConnection = true
        if Self.hasSavedStrap, reconnectKnown() { return }
        scan()
    }

    /// A foreground search for an advertising Helio Strap (by name, §1).
    func scan() {
        wantConnection = true
        ensureCentral()
        guard central?.state == .poweredOn else {
            pendingAction = .scan
            return
        }
        pendingAction = nil
        state = .searching
        // SPEC-GAP: the strap's advertised services are unknown (§1, §10 item 1), so the scan is
        // unfiltered and matched by name. Foreground only: iOS drops unfiltered background scans.
        central?.scanForPeripherals(withServices: nil, options: nil)
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.scanTimeout))
            guard let self, !Task.isCancelled, self.state == .searching else { return }
            self.central?.stopScan()
            self.state = .notFound
        }
    }

    /// A standing connect to the saved strap (no scan). false when there is none to reconnect to.
    @discardableResult
    func reconnectKnown() -> Bool {
        endedBusyAt = nil
        guard ActiveDeviceChoiceStore.persisted() == .helioStrap,
              let id = Self.savedPeripheralID, let uuid = UUID(uuidString: id) else { return false }
        if state == .connecting || (state == .connected && session != nil) { return true }
        if state == .connected, let peripheral, peripheral.state == .connected, central?.state == .poweredOn {
            // Linked but no session (a discovery that never finished): discover again.
            characteristics = [:]
            peripheral.discoverServices(nil)
            return true
        }
        wantConnection = true
        ensureCentral()
        guard central?.state == .poweredOn else {
            pendingAction = .reconnect
            return true
        }
        pendingAction = nil
        guard let known = central?.retrievePeripherals(withIdentifiers: [uuid]).first else { return false }
        adopt(known)
        state = .connecting
        central?.connect(known, options: nil)
        return true
    }

    /// Drop the link and stop reconnecting. The saved strap stays, for a later reconnect.
    /// `cancelNow`: cancel the link in this call even when a find or a sync was running. Only an
    /// expiry's teardown asks for it (`tearDownForExpiry`, review-225e SF-2): iOS suspends the app when
    /// that returns, so a cancel deferred by 500 ms would never run. Everything else, a foreground
    /// disconnect with a find running included, keeps the 500 ms (§15.4).
    func disconnect(cancelNow: Bool = false) {
        wantConnection = false
        pendingAction = nil
        scanTimeoutTask?.cancel()
        stopRSSIUpdates()
        // Never leave the strap buzzing (§15.4): the stop goes out, and gets half a second to leave
        // the radio (HelioVerify's margin), before the link is cancelled.
        // A sync in progress gets its `03 09` before the link goes (the strap keeps the data either way).
        let wasBusy = session?.isFinding == true || session?.syncing == true
        session?.stopFind()
        session?.stopLiveHeartRate()
        session?.abortSync()
        session?.linkLost()
        session = nil
        state = .idle
        let central = self.central
        let peripheral = self.peripheral
        let cancel = { [weak self] in
            if central?.state == .poweredOn {
                central?.stopScan()
                if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            }
            self?.characteristics = [:]
            self?.writeQueue = []
        }
        if wasBusy && !cancelNow {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                cancel()
            }
        } else {
            cancel()
        }
    }

    /// Forget the strap on this phone (its stored history stays).
    func forgetStrap() {
        disconnect()
        peripheral = nil
        // Its timeline is retired: nothing will flush it again, so its workout exclusions go too
        // (review-238b N-1). Its stored rows stay, as every other forget leaves them.
        if let timeline = Self.savedTimeline { StrapWorkoutHealthExclusions.retire(timeline: timeline) }
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
    }

    /// Drop and re-open the link: a fresh auth with the key saved now.
    func reconnectNow() {
        let wasFinding = session?.isFinding == true || session?.syncing == true
        disconnect()
        let reopen = { [weak self] in
            guard let self else { return }
            // A saved strap the system no longer knows falls back to a search.
            if !(Self.hasSavedStrap && self.reconnectKnown()) { self.scan() }
        }
        if wasFinding {
            // `disconnect()` gives a running find's stop half a second before cancelling the link;
            // reopen after that, so the cancel can't land on the new connect.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                reopen()
            }
        } else {
            reopen()
        }
    }

    // MARK: RSSI (Find My Strap's distance hint)

    func startRSSIUpdates() {
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let peripheral = self.peripheral, peripheral.state == .connected { peripheral.readRSSI() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopRSSIUpdates() {
        rssiTask?.cancel()
        rssiTask = nil
        rssi = nil
    }

    // MARK: Plumbing

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
    }

    private func adopt(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
    }

    private func makeSession(for peripheral: CBPeripheral) {
        // The process-wide container when no view handed a store over yet (a switch made from a
        // screen, or a restoration launch), opened now if launch couldn't (before the first unlock);
        // never `makeContainer()`, whose recovery path can wipe.
        let store = localStore ?? (try? OpenCircuitApp.backgroundStore())
        // Decision 33: a link that comes back in the background (a reconnect, a restoration relaunch)
        // doesn't sync by itself; `HelioWakePolicy` decides whether it catches up, under a background
        // assertion and with the BGTask run's budget and teardown. In front, and for a background run's
        // own connect, a session syncs on connect as before.
        let syncOnConnect = Self.appIsActive || backgroundRunAdoptsNewSessions
        let made = SessionReference()
        let session = HelioSession(
            transport: self, identityID: peripheral.identifier.uuidString, model: .helioStrap,
            key: keyStore.load(), keyStore: keyStore, sink: store.map { HelioStoreSink(store: $0, breadcrumbs: breadcrumbs) },
            findState: findState,
            onSyncFinished: { [breadcrumbs] result, timeline in
                // Decision 72: one counts-only line for a sync that fetched a sleep-session round.
                if let summary = result.sleepRound { breadcrumbs.strapSleepRound(summary) }
                let appIsActive = Self.appIsActive   // as the sync ends, before the flush's awaits
                if !result.interrupted { HelioWakeState().lastCompletedSync = Date() }
                await HelioConnection.syncEnded(
                    result, session: made.session, appIsActive: appIsActive,
                    flush: { await HelioConnection.flushToHealth(result: result, timeline: timeline, store: store) },
                    alertPass: { if let store { await HelioConnection.bodyAlertPass?(store) } })
            },
            onEvent: { [weak self] event in self?.handle(event) },
            autoSyncOnConnect: syncOnConnect,
            // A strap workout holds the link (#227): syncs wait until it ends.
            workoutHoldsLink: { StrapWorkoutRecorder.holdsStrapLink })
        session.backgroundRunOwnsSyncs = backgroundRunAdoptsNewSessions
        session.appInBackground = !Self.appIsActive
        made.session = session
        self.session = session
        // Shortcuts' wake alarm (#260, decision 52b): a request saved while the strap was away is
        // applied right after this connection's setup reads the alarm list.
        StrapWakeAlarmApplier.shared.attach(to: session)
        session.start()
    }

    /// The end of every sync on a session this connection made.
    /// - A background run that owns the sync flushes it and runs its own alert passes (#215 phase 4):
    ///   nothing here.
    /// - Otherwise the sync is flushed here. Review-236 S1: if it ended with the app not active (it
    ///   started in front, the person left), ContentView's foreground hook may not run until the app is
    ///   next opened, and since #236 a missed pass is a lost alert, not a late one. So the body-alert
    ///   pass runs here too, once per sync (`StrapSyncAlertPass`, shared with that hook; the claim is
    ///   the session's own, so a reconnect's new session is never refused, review-225f SF-1). Ending
    ///   with the app active, the foreground hook runs it, and this path doesn't.
    static func syncEnded(_ result: HelioSyncResult, session: HelioSession?, appIsActive: Bool,
                          flush: @MainActor () async -> Void, alertPass: @MainActor () async -> Void) async {
        guard !result.endedInBackgroundRun else { return }
        await flush()
        guard !appIsActive, let session, StrapSyncAlertPass.claim(session) else { return }
        await alertPass()
    }

    /// The background runs' body-alert pass (`AppDelegate.evaluateBodyAlerts`), set at launch, so a
    /// sync that ends in the background runs the same pass and no second implementation exists.
    static var bodyAlertPass: (@MainActor (LocalStore) async -> Void)?

    /// After every sync no background run owns: the strap's timeline and nights through the ring's
    /// Health writer, carrying the strap's `HKDevice` (decisions 10–17). Logged as a foreground sync
    /// only while the app is active; one that ends in the background (a restoration relaunch, a link
    /// that came back while suspended) is logged as a background sync.
    static func flushToHealth(result: HelioSyncResult, timeline: SyncDeviceID, store: LocalStore?) async {
        let observability = ObservabilityStore()
        let kind: TaskRecord.Kind = UIApplication.shared.applicationState == .active ? .foreground : .backgroundSync
        observability.recordSyncOutcome(kind: kind, success: !result.interrupted && result.roundsFailed == 0,
                                        detail: "helio: \(result.roundsStored) round(s) stored, \(result.roundsFailed) failed, \(result.nights.count) night(s)")
        guard let store else { return }
        let flushStart = Date()
        guard let flush = await healthFlush(timeline: timeline, store: store, nights: result.nights,
                                            identity: result.identity,
                                            nightsFinalized: result.nightsFinalized) else { return }
        if flush.wroteAnything { observability.recordHealthWrite() }
        // #233 item 5: a night this flush held back gets a refresh at its margin's end, kept so the
        // app's own `schedule()` when it leaves the front doesn't replace it (review-225e SF-3).
        StrapNightRefresh.record(nightRefreshAim(result: result, timeline: timeline, store: store, flushStartedAt: flushStart),
                                 scheduler: BackgroundRefreshScheduler())
    }

    /// `flushToHealth`'s refresh verdict, read after its flush: the margin end of a night the flush held
    /// back (#233 item 5), and, decision 57b (#262), of the newest stored night still inside its margin
    /// when this sync didn't carry it. Without the second, a sync whose strap had stopped re-delivering
    /// the night (the app opened after a background wake stored it) answered nil and cleared the
    /// refresh that wake had asked for.
    static func nightRefreshAim(result: HelioSyncResult, timeline: SyncDeviceID, store: LocalStore,
                                flushStartedAt: Date, now: Date = Date()) -> Date? {
        StrapNightRefresh.aim(nights: result.nights,
                              storedNightSettles: store.newestStrapNightSettles(timeline: timeline, now: now),
                              focusEndedAt: result.nightsFinalized, persistedFocusEnd: SleepFocusFinalization.persisted(),
                              flushStartedAt: flushStartedAt, afterWokeUp: false)
    }

    /// The strap's Apple Health pass, shared by the post-sync hook and the background run (#215
    /// phase 4): its timeline's pending samples (`HelioHealthPolicy.healthMirroredKinds()`) and `nights`. nil when
    /// Health isn't available on this device, or when `mayFlush` says no. `nightsFinalized` is the
    /// time T Sleep Focus ended, if a Focus wake is behind this flush (decision 31's in-memory T): it
    /// reaches `flushStrap`, which decides per night with the persisted T (decision 78a).
    static func healthFlush(timeline: SyncDeviceID, store: LocalStore, nights: [HelioSleepSelection.Night],
                            identity: WearableIdentity?, nightsFinalized: Date? = nil) async -> HealthKitWriter.FlushResult? {
        guard HealthKitWriter.isAvailable else { return nil }
        // Decision 28 (review-224 S3): record the identity the sync ended with, so this flush — and
        // any later one for these rows — names THIS strap even if the wearer has switched back to
        // the ring meanwhile. A strap that never passed the first-write guard writes nothing once
        // it's no longer chosen; its rows stay pending for its next sync.
        if let identity { ActiveWearable.shared.recordIdentity(identity) }
        guard mayFlush(timeline: timeline, strapChosen: ActiveDeviceChoiceStore.shared.isHelio,
                       wearable: ActiveWearable.shared) else {
            helioLog.notice("helio: Health flush skipped: switched away before the strap had an identity")
            return nil
        }
        let flush = await flushStrap(HealthKitWriter(), store: store, timeline: timeline,
                                     nights: nights.map(\.segments), focusEndedAt: nightsFinalized)
        helioLog.notice("helio: Health flush samples=\(flush.samples, privacy: .public) sleep=\(flush.sleepSegments, privacy: .public) steps=\(flush.steps, privacy: .public) rhr=\(flush.restingDays, privacy: .public)\(flush.recoveryHRVLogSuffix, privacy: .public)")
        return flush
    }

    /// The strap's pass through `writer`, run by both strap flush sites (`healthFlush` above and
    /// `ContentView.flushHealth`): the strap's timeline, the kinds `HelioHealthPolicy` mirrors (HRV
    /// included, decision 44) and its nights. The kinds are decided here only, and a test pins them
    /// through `HealthKitWriter.lastFlushRequest` (review-244 SF-2).
    ///
    /// Decision 78a (#332): which nights are over is decided here, once per flush, for both sites:
    /// from `focusEndedAt` (decision 31's in-memory T, the background run's and the post-sync hook's)
    /// and the Sleep Focus end persisted in `defaults`, at `now` (the flush's start), per night by its
    /// end (`SleepFocusFinalization.nights`). The same verdict lifts the settle margin in the writer
    /// and the newest-night hold in the backstop. With no T (none persisted, or one in the future or
    /// over 6 h old, and no in-memory T) every night is judged exactly as before.
    static func flushStrap(_ writer: HealthKitWriter, store: LocalStore, timeline: SyncDeviceID,
                           nights: [[SleepSegment]], focusEndedAt: Date? = nil,
                           now: Date = Date(), defaults: UserDefaults = .standard) async -> HealthKitWriter.FlushResult {
        let finalization = SleepFocusFinalization.nights(inMemory: focusEndedAt, persisted: SleepFocusFinalization.persisted(defaults: defaults),
                                                         flushStartsAt: now)
        let flush = await writer.flushToHealth(store: store, device: timeline, mirroredKinds: HelioHealthPolicy.healthMirroredKinds(),
                                               strapNights: strapNights(nights, store: store, timeline: timeline, now: now,
                                                                        finalization: finalization),
                                               strapNightsFinalized: finalization)
        if finalization.fromPersisted, flush.finalizedStrapNights > 0, let focusEnd = finalization.focusEnd {
            SleepFocusFinalization.notePersistedWrite(focusEnd: focusEnd, flushStart: now, defaults: defaults)
        }
        return flush
    }

    /// The nights a strap flush offers the writer: the sync's own `nights`, then the stored strap
    /// nights that never reached Apple Health (decision 50b, #253). A sync's nights cover that sync
    /// only, so a night whose later re-deliveries were all kept as thinner was never offered again;
    /// both flush sites run through here, so every strap flush catches it. A stored night is skipped
    /// when the sync already carries the same window. The writer's gate, `mirrorSettledNight` and its
    /// bails judge these exactly as the sync's own.
    static func strapNights(_ nights: [[SleepSegment]], store: LocalStore, timeline: SyncDeviceID,
                            now: Date, finalization: SleepFocusFinalization.Nights = .none) -> [[SleepSegment]] {
        func window(_ night: [SleepSegment]) -> DateInterval? {
            guard let start = night.map(\.start).min(), let end = night.map(\.end).max(), end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
        let carried = Set(nights.compactMap(window))
        return nights + store.strapNightsAwaitingHealth(timeline: timeline, now: now, finalization: finalization)
            .filter { window($0).map { !carried.contains($0) } ?? false }
    }

    /// Whether a strap sync's flush may write (decision 28, review-224 S3). Attribution follows the
    /// row: the strap's rows name the strap. While the strap is chosen that follows the first-write
    /// guard (#222: no identity yet → no device attached); once it isn't, a write with no identity
    /// would be anonymous rows from a device the wearer has left, so nothing is written.
    static func mayFlush(timeline: SyncDeviceID, strapChosen: Bool, wearable: ActiveWearable) -> Bool {
        strapChosen || wearable.identityForHealthWrite(timeline: timeline) != nil
    }

    private func known(_ characteristic: CBCharacteristic) -> ZeppCharacteristic? {
        characteristics.first { $0.value === characteristic }?.key
    }

    // SPEC-GAP: which write types `…0016` and `…0004` accept is a §10 capture item. Write without
    // response when the characteristic offers it, else with response (HelioVerify's rule).
    private func flushWrites() {
        guard let peripheral else { return }
        while let next = writeQueue.first, let characteristic = characteristics[next.characteristic] {
            let withoutResponse = characteristic.properties.contains(.writeWithoutResponse)
            if withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            writeQueue.removeFirst()
            peripheral.writeValue(Data(next.bytes), for: characteristic,
                                  type: withoutResponse ? .withoutResponse : .withResponse)
        }
        // A write for a characteristic this strap doesn't have is dropped, never retried.
        if let next = writeQueue.first, characteristics[next.characteristic] == nil {
            writeQueue.removeFirst()
            flushWrites()
        }
    }
}

/// Review-225e SF-1: opening the app syncs a strap session that is up and idle. A link that came back
/// in the background (a run's teardown re-arm, a reconnect or restoration inside the wake gates, or a
/// connect that completed while the app was `.inactive`) makes a session that doesn't sync on connect
/// (decision 33), and `ContentView`'s activation reconnect returns early for a connected session; so
/// without this, nothing synced the night until a pull-to-refresh. Mirrors the ring's
/// `maybeAutoSyncOnReady` throttle, so Control Center or a banner flapping the app between `.inactive`
/// and `.active` gives at most one sync.
struct HelioActivationSync {
    /// When this throttle last started a sync (in memory, as the ring's `lastForegroundSync`).
    private(set) var lastStarted: Date?

    /// Sync now: the session is `.ready` and idle (no sync, no find, no live heart rate), and neither
    /// this throttle's last start nor the last completed strap sync (persisted, so a relaunch counts
    /// it) is younger than `ForegroundAutoSync.interval`.
    /// `workoutHoldsStrap` (#227, review-238 B1): a strap workout holds the link; nothing is started and
    /// the throttle doesn't count it. The workout's own End runs the sync it held back.
    mutating func shouldSync(phase: HelioSession.Phase, syncing: Bool, finding: Bool, liveHeartRate: Bool,
                             lastCompletedSync: Date?, now: Date, workoutHoldsStrap: Bool = false) -> Bool {
        guard phase == .ready, !syncing, !finding, !liveHeartRate, !workoutHoldsStrap else { return false }
        if let last = [lastStarted, lastCompletedSync].compactMap({ $0 }).max(),
           now >= last, now.timeIntervalSince(last) < ForegroundAutoSync.interval { return false }
        lastStarted = now
        return true
    }
}

extension HelioConnection {
    /// The app came to the front: the session's own reaction (Tier 0), then the activation sync. A sync
    /// started here is a foreground sync: if the app leaves before it ends, `syncEnded` runs its alert
    /// pass (review-236 S1).
    static func becameActive(_ session: HelioSession, gate: inout HelioActivationSync, lastCompletedSync: Date?, now: Date) {
        session.appDidBecomeActive()
        if gate.shouldSync(phase: session.phase, syncing: session.syncing, finding: session.isFinding,
                           liveHeartRate: session.liveHeartRateRunning, lastCompletedSync: lastCompletedSync, now: now,
                           workoutHoldsStrap: StrapWorkoutRecorder.holdsStrapLink) {
            session.syncHistory(manual: false)
        }
    }
}

/// A session `makeSession` creates, for its own sync-end hook (the hook is built before the session).
@MainActor
private final class SessionReference {
    weak var session: HelioSession?
}

/// Review-236 S1: one body-alert pass per strap sync, whichever path gets there first: the sync-end
/// hook (`HelioConnection.syncEnded`, app not active) or ContentView's foreground hook. Both run on the
/// main actor, so they can't both claim the same sync.
///
/// The claim lives on the session (`HelioSession.alertPassClaimedSync`), never in a global keyed by
/// `ObjectIdentifier` (review-225f SF-1): an identifier is unique only while its object lives, a
/// reconnect's new session usually gets the freed one's address with `syncsFinished` back at 0, so its
/// first sync matched the old claim and both hooks skipped the pass. A new session starts unclaimed.
@MainActor
enum StrapSyncAlertPass {
    /// true the first time it's asked for the session's latest finished sync; false after that.
    static func claim(_ session: HelioSession) -> Bool {
        if session.alertPassClaimedSync == session.syncsFinished { return false }
        session.alertPassClaimedSync = session.syncsFinished
        return true
    }
}

// MARK: - Session events (#233)

extension HelioConnection {
    /// What the session reports beyond a finished sync: breadcrumbs (and, for the woke-up event, a wake).
    func handle(_ event: HelioSessionEvent) {
        switch event {
        case .syncStarted:
            // A background run logs its own sync's wake; this is every other sync.
            guard session?.backgroundRunOwnsSyncs != true else { return }
            breadcrumbs.syncStarted(wake: Self.appIsActive ? .foreground : (restoredThisLaunch ? .restoration : .reconnect))
        case .strapMessage(let endpoint, let opcode, let length):
            breadcrumbs.strapMessage(endpoint: endpoint, opcode: opcode, length: length)
            idleTrafficArrived()
        case .strapNotification(let characteristic):
            breadcrumbs.strapNotification(characteristic: characteristic.rawValue)
            idleTrafficArrived()
        case .wokeUp:
            // Decision 33, §16.4: an opportunistic hint (🔴 whether the Helio sends it). It carries no
            // time, so nothing is written from it: the catch-up fetches history and the night selection
            // decides. Not a finalization either: the night still waits for its settle margin (decision
            // 31 is about Sleep Focus only).
            Self.wakeHandler(.strapEvent)
        case .fellAsleep:
            break   // a breadcrumb only (the strap-message line above)
        }
    }

    /// Decision 35: something the strap sent on its own over the held link, with the app in the
    /// background and no sync running, is a wake gated like a reconnect (`HelioWakePolicy`).
    private func idleTrafficArrived() {
        guard idleTraffic.shouldCheck(now: Date(), appIsActive: Self.appIsActive, syncing: session?.syncing == true,
                                      runActive: activeBackgroundRuns > 0,
                                      workoutHoldsStrap: StrapWorkoutRecorder.holdsStrapLink) else { return }
        Self.wakeHandler(.idleTraffic)
    }

    /// The link came up while the app is in the background: the restoration's wake, or a reconnect.
    private func linkCameBackInBackground() {
        guard !Self.appIsActive else { return }
        let wake: HelioWake = restorationWakePending ? .restoration : .reconnect
        restorationWakePending = false
        Self.wakeHandler(wake)
    }

    static var appIsActive: Bool { UIApplication.shared.applicationState == .active }

    /// CoreBluetooth's error code for a drop, when there is one.
    nonisolated static func errorCode(_ error: Error?) -> Int? {
        guard let error else { return nil }
        if let cb = error as? CBError { return cb.code.rawValue }
        return (error as NSError).code
    }

    nonisolated static func describe(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - HelioBackgroundLink

extension HelioConnection: HelioBackgroundLink {
    var strapTimeline: SyncDeviceID? {
        if let session { return session.timeline }
        return Self.savedPeripheralID.map {
            SyncDeviceID.timeline(for: .zeppOS(model: HelioSession.displayName), identityID: $0)
        }
    }

    func connectForBackground() -> Bool {
        reconnectKnown()
    }

    func disconnectForBackground(cancelNow: Bool) {
        // `disconnect()` drops the session before the link goes, so `didDisconnectPeripheral` can't see
        // a busy strap any more: note it here, so nothing reconnects by itself (decision 7).
        if session?.phase == .strapBusy { latchBusy() }
        disconnect(cancelNow: cancelNow)
    }

    /// Decision 78d: a Sleep Focus run tries the strap once, whatever an earlier connection said.
    func clearBusyLatch() {
        endedBusyAt = nil
    }

    /// The connection ended with the strap busy: note when, and which path said so (a reason word).
    private func latchBusy() {
        endedBusyAt = Date()
        breadcrumbs.strapBusy(reason: session?.busyReason)
    }

    /// A busy latch still holds for the background paths (decision 78d).
    private var busyLatchHolds: Bool { HelioBusyLatch.holds(since: endedBusyAt, now: Date()) }

    /// Decision 33: after a run's teardown (out of time, or expired), arm a standing connect again, so
    /// the strap coming back (or still in range) can wake the app later. Never after a quiet ending
    /// (decision 7). The reconnect itself doesn't sync: `HelioWakePolicy`'s cooldown sees the run.
    func rearmAfterTeardown() {
        guard ActiveDeviceChoiceStore.persisted() == .helioStrap, !busyLatchHolds, Self.hasSavedStrap else { return }
        if peripheral == nil || peripheral?.state == .disconnected, state == .idle {
            reconnectKnown()
        } else {
            rearmOnDisconnect = true   // the cancel is still on its way: re-arm when it lands
        }
    }

    func noteBackgroundRunStarted(at date: Date) {
        HelioWakeState().lastBackgroundRunStart = date
    }

    /// A Shortcuts action's connect (#260, review-261 U1). A `disconnect()` with a find or a sync
    /// running drops the session at once but cancels the link 500 ms later. A connect issued inside that
    /// window would be cancelled by the deferred cancel, so there it re-arms on the disconnect, the way
    /// a run's teardown does (`rearmAfterTeardown` → `rearmOnDisconnect`). Otherwise: the standing connect.
    func reconnectForShortcut() -> Bool {
        if state == .idle, session == nil, let peripheral,
           peripheral.state == .connected || peripheral.state == .disconnecting {
            rearmAfterTeardown()
            return true
        }
        return reconnectKnown()
    }
}

// MARK: - HelioTransport

extension HelioConnection: HelioTransport {
    func has(_ characteristic: ZeppCharacteristic) -> Bool { characteristics[characteristic] != nil }

    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        guard let c = characteristics[characteristic] else { return false }
        return c.properties.contains(.notify) || c.properties.contains(.indicate)
    }

    var maxWriteLength: Int { peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20 }

    func write(_ write: ZeppWrite) {
        writeQueue.append(write)
        flushWrites()
    }

    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) {
        guard let c = characteristics[characteristic] else { return }
        peripheral?.setNotifyValue(enabled, for: c)
    }

    func read(_ characteristic: ZeppCharacteristic) {
        guard let c = characteristics[characteristic] else { return }
        peripheral?.readValue(for: c)
    }
}

// MARK: - CBCentralManagerDelegate

extension HelioConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { centralStateChanged(central.state) }
    }

    /// Tests only: a session as if this connection had made it, so the Bluetooth-state handling can be
    /// driven without CoreBluetooth (review-238 S1).
    func installSessionForTesting(_ session: HelioSession, wantConnection: Bool = true) {
        self.session = session
        self.wantConnection = wantConnection
        state = .connected
    }

    /// A reconnect to the saved strap waits for Bluetooth to come back on (review-238 S1).
    var reconnectArmedForPowerOn: Bool { pendingAction == .reconnect }

    /// The central's state, apart from CoreBluetooth so a test can deliver it (review-238 S1).
    func centralStateChanged(_ newState: CBManagerState) {
        switch newState {
        case .poweredOn:
            if state == .bluetoothOff || state == .bluetoothDenied { state = .idle }
            switch pendingAction {
            case .scan?: scan()
            case .reconnect?: reconnectKnown()
            case .resumeRestored?: resumeRestored()
            case nil: break
            }
        case .poweredOff:
            // Decision 33: the link is gone (CoreBluetooth may not report the disconnect). Keep the
            // wish to be connected: power-on reconnects (`pendingAction`), and that can wake the app.
            if session != nil || wantConnection {
                session?.linkLost()
                session = nil
                characteristics = [:]
                writeQueue = []
                if wantConnection { pendingAction = .reconnect }
                breadcrumbs.bluetoothOff(standingConnectArmed: wantConnection,
                                         upFor: linkUpAt.map { Date().timeIntervalSince($0) })
                linkUpAt = nil
            }
            state = .bluetoothOff
        case .unauthorized:
            state = .bluetoothDenied
        default:
            break
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            // Minimal restoration: re-adopt the saved strap's peripheral so its callbacks land here.
            // Nothing is sent to the radio yet (CoreBluetooth ignores calls before power-on); the
            // `.poweredOn` update resumes it (`resumeRestored`).
            restoredThisLaunch = true
            let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            let saved = Self.savedPeripheralID
            let match = peripherals.first(where: { $0.identifier.uuidString == saved })
            breadcrumbs.restored(peripheralStates: peripherals.map { Self.describe($0.state) },
                                 savedStrapState: match.map { Self.describe($0.state) })
            guard let restored = match else { return }
            restorationWakePending = true
            adopt(restored)
            wantConnection = true
            pendingAction = .resumeRestored
            state = restored.state == .connected ? .connected : .connecting
            helioLog.notice("helio: restored the strap's peripheral (state \(restored.state.rawValue, privacy: .public))")
        }
    }

    /// After restoration and power-on: discover a live link, or re-issue the standing connect.
    private func resumeRestored() {
        pendingAction = nil
        guard let peripheral, wantConnection, central?.state == .poweredOn else { return }
        if peripheral.state == .connected {
            state = .connected
            linkUpAt = Date()
            breadcrumbs.linkUp("restored, already connected", appActive: Self.appIsActive)
            if session == nil { characteristics = [:]; peripheral.discoverServices(nil) }
            linkCameBackInBackground()
        } else {
            state = .connecting
            central?.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard state == .searching else { return }
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
            // §14 device gate: the Helio Strap only (the Helio Ring shares the protocol, untested).
            guard ZeppDeviceModel.match(advertisedName: name) == .helioStrap else { return }
            scanTimeoutTask?.cancel()
            central.stopScan()
            adopt(peripheral)
            state = .connecting
            helioLog.notice("helio: found the strap (RSSI \(RSSI.intValue, privacy: .public)); connecting")
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            state = .connected
            linkUpAt = Date()
            breadcrumbs.linkUp(restoredThisLaunch ? "connected after a restoration relaunch" : "connected",
                               appActive: Self.appIsActive)
            // A different strap (or the same one re-added, which gets a new identity): the old
            // timeline is retired, so its workout exclusions go (review-238b N-1).
            if let previous = Self.savedTimeline, previous != peripheral.strapTimeline {
                StrapWorkoutHealthExclusions.retire(timeline: previous)
            }
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
            characteristics = [:]
            peripheral.discoverServices(nil)
            linkCameBackInBackground()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            state = .idle
            // Retry once after a pause, never in a tight loop; the retry is a standing connect that
            // iOS completes whenever the strap is in range.
            guard wantConnection else { return }
            state = .connecting
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.wantConnection, self.peripheral === peripheral,
                      self.central?.state == .poweredOn else { return }
                self.central?.connect(peripheral, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            // Auth refused as "busy" on this connection: don't reconnect by itself, or a strap held
            // by another app would be re-authenticated in a loop.
            if session?.phase == .strapBusy {
                latchBusy()
                wantConnection = false
            }
            session?.linkLost()
            session = nil
            characteristics = [:]
            writeQueue = []
            stopRSSIUpdates()
            let expected = !wantConnection
            if rearmOnDisconnect {
                rearmOnDisconnect = false
                if ActiveDeviceChoiceStore.persisted() == .helioStrap, !busyLatchHolds { wantConnection = true }
            }
            if wantConnection, central.state == .poweredOn {
                state = .connecting
                central.connect(peripheral, options: nil)
            } else {
                state = .idle
            }
            breadcrumbs.linkDown(errorCode: Self.errorCode(error), expected: expected,
                                 standingConnectArmed: state == .connecting,
                                 upFor: linkUpAt.map { Date().timeIntervalSince($0) })
            linkUpAt = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension HelioConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            guard error == nil, !services.isEmpty else {
                // A discovery that failed would leave "connected" with no session: drop the link
                // instead, so the standing reconnect starts over.
                helioLog.error("helio: service discovery failed; reconnecting")
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            pendingServices = services.count
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                // By UUID across ALL services (§2). Never the firmware-update service.
                guard service.uuid != CBUUID(string: ZeppGATT.firmwareUpdateServiceUUID) else { continue }
                for known in ZeppCharacteristic.allCases where CBUUID(string: known.uuidString) == characteristic.uuid {
                    characteristics[known] = characteristic
                }
            }
            pendingServices -= 1
            guard pendingServices == 0, session == nil else { return }
            makeSession(for: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let which = known(characteristic) else { return }
            session?.notificationStateChanged(which, enabled: characteristic.isNotifying, failed: error != nil)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let which = known(characteristic), let value = characteristic.value else { return }
            session?.received(which, [UInt8](value))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { flushWrites() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, rssiTask != nil else { return }
            rssi = RSSI.intValue
        }
    }
}

extension CBPeripheral {
    /// This peripheral's strap timeline (`zeppos:<identifier>`), the id every strap row is stored under.
    var strapTimeline: SyncDeviceID {
        SyncDeviceID.timeline(for: .zeppOS(model: HelioSession.displayName), identityID: identifier.uuidString)
    }
}
