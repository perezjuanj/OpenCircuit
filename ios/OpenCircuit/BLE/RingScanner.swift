import Foundation
import CoreBluetooth
import Observation
import OpenCircuitKit

// Scans for the RingConn ring and connects. On iOS there are NO raw ATT handles
// (docs/HANDOFF_MACOS_IOS.md) — everything is addressed by characteristic UUID,
// so RingSession matches the notify/write characteristics by UUID after connect.
//
// The ring is matched by advertised NAME prefix ("RingConn Gen2…", 🟢). The
// notify/write characteristic UUIDs RingSession binds to are now 🟢 confirmed by
// `opencircuit scan` (service 8327ad99; notify 8327ad97 = handle 0x0804; write
// 8327ad98 = handle 0x0802) — see PROTOCOL.md §1.

@Observable
@MainActor
final class RingScanner: NSObject {

    enum State: Equatable {
        case poweredOff, unauthorized, scanning, connecting(String), connected(String), idle
    }

    /// Shared instance. State restoration + background relaunch require a SINGLE
    /// CBCentralManager that's re-created (with the same restore identifier) early in
    /// every launch — including when iOS relaunches us in the background because the ring
    /// came back in range. A per-view/per-task manager would either miss restoration or
    /// collide on the restore identifier, so everything funnels through this one. (#7)
    static let shared = RingScanner()

    private(set) var state: State = .idle
    private(set) var session: RingSession?

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var localStore: LocalStore?

    /// Stable identifier that lets iOS associate the restored Bluetooth state with this
    /// central across relaunches. Must be constant for the life of the app.
    private static let restoreIdentifier = "com.opencircuit.central.restore"

    /// UserDefaults keys for the remembered ring set. We store a LIST of connected rings'
    /// CoreBluetooth identifiers (per-device UUIDs — NOT the MAC, which iOS never exposes) plus which
    /// one is "active". Multi-ring is SEQUENTIAL: one ring is connected at a time and each ring's data
    /// merges into a single shared timeline (no per-ring data segregation). Reconnect targets the
    /// active ring by identifier with no scan after a cold launch / background relaunch.
    private static let savedPeripheralIDsKey = "com.opencircuit.ring.peripheralIDs"
    private static let activePeripheralIDKey = "com.opencircuit.ring.activePeripheralID"
    /// Legacy single-ring key (pre multi-ring). Migrated into the list once, then retired.
    private static let legacyPeripheralKey = "com.opencircuit.ring.peripheralID"

    /// Every ring the user has connected at least once (its `identifier.uuidString`).
    private static var savedPeripheralIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: savedPeripheralIDsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: savedPeripheralIDsKey) }
    }

    /// The ring we auto-reconnect to. Cleared by an explicit user stop so we don't silently
    /// reconnect; the ring stays in `savedPeripheralIDs` so it's still one tap away in the picker.
    private static var activePeripheralID: String? {
        get { UserDefaults.standard.string(forKey: activePeripheralIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: activePeripheralIDKey) }
    }

    /// Record a freshly connected ring: add it to the remembered set and make it active.
    private static func rememberRing(_ id: String) {
        var ids = savedPeripheralIDs
        if !ids.contains(id) { ids.append(id) }
        savedPeripheralIDs = ids
        activePeripheralID = id
    }

    /// One-time migration from the single-ring key to the multi-ring list. Also moves the active
    /// ring's per-ring sync state (step raw-counter + epoch archive) onto its namespaced keys, so the
    /// existing ring's step deltas and overnight stitching survive the update untouched. Per-ring keys
    /// are `"<base>.<deviceKey>"` — see `RingSession` (steps) and `EpochArchiveStore` (archive).
    private static func migrateLegacyRingStateIfNeeded() {
        let d = UserDefaults.standard
        // Already migrated (or a fresh install with nothing to migrate)?
        guard d.stringArray(forKey: savedPeripheralIDsKey) == nil,
              let legacy = d.string(forKey: legacyPeripheralKey) else { return }
        d.set([legacy], forKey: savedPeripheralIDsKey)
        d.set(legacy, forKey: activePeripheralIDKey)
        for base in ["steps.lastRawValue", "steps.lastRawDay", "sleep.epochArchive", "sleep.lastHistoryDrainAt"] {
            let namespaced = "\(base).\(legacy)"
            if d.object(forKey: namespaced) == nil, let value = d.object(forKey: base) {
                d.set(value, forKey: namespaced)
                d.removeObject(forKey: base)
            }
        }
        d.removeObject(forKey: legacyPeripheralKey)
    }

    /// True when there's an ACTIVE saved ring to reconnect to (a no-scan reconnect-by-identifier is
    /// possible). The foreground auto-refresh uses this to decide whether to reconnect vs. require a
    /// user Scan. False after an explicit stop, even if rings remain remembered.
    var hasSavedRing: Bool { Self.activePeripheralID != nil }

    /// The active ring's id, for the connect UI (the "Last used" picker badge).
    var activeRingID: String? { Self.activePeripheralID }

    /// Set when a reconnect was requested before Bluetooth finished powering on; retried
    /// from `centralManagerDidUpdateState` once `.poweredOn` arrives.
    private var reconnectWhenPoweredOn = false

    /// Consecutive failed auto-reconnect attempts since the last frame-delivering connect (#35).
    /// Drives the backoff delay (`ReconnectBackoff`); reset to 0 once a reconnected link proves
    /// real (`connectStableTask`). A ring on the charger that accepts then drops a connect keeps
    /// this climbing, so the reconnect cadence stretches instead of hammering the radio.
    private var reconnectAttempts = 0
    /// The pending backoff timer: sleeps the computed delay, then re-issues a single standing
    /// pending connect. Cancelled on connect / user stop so we never stack timers.
    private var reconnectTask: Task<Void, Never>?
    /// After a fresh connect, this waits a beat and only resets the backoff if the link SURVIVED
    /// and delivered a real frame — the "successful data frame" reset signal (#35). Guards the
    /// connect/reject loop a charging ring produces (resetting on `didConnect` alone would pin
    /// the backoff at its shortest delay).
    private var connectStableTask: Task<Void, Never>?
    /// How long a new link must hold (and send a frame) before we trust it and reset the backoff.
    private static let connectStablePeriod: TimeInterval = 6

    /// True once enough reconnects have failed that the UI should show a calm "ring unreachable /
    /// charging — will reconnect automatically" instead of a permanent "Connecting…" (#35). Based
    /// on elapsed attempts, NOT a decoded charging byte (that descriptor bit is protocol-blocked,
    /// #41) — we never claim to KNOW the ring is charging.
    private(set) var reconnectStalled = false

    private override init() {
        Self.migrateLegacyRingStateIfNeeded()
        super.init()
        // Opting into state restoration: iOS preserves this central's connections/pending
        // connects while the app is suspended and relaunches the app (into the background)
        // when a relevant BLE event fires — delivered via `willRestoreState`.
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    /// True once the user has connected; keeps us auto-reconnecting if the ring sleeps.
    private var wantConnection = false

    // MARK: Foreground discovery + ring picker (#multi-ring)

    /// A ring seen during a foreground scan, surfaced to the connect UI. The picker is shown ONLY
    /// when more than one distinct ring is discovered; a single match auto-connects (today's UX).
    struct DiscoveredRing: Identifiable, Equatable {
        let id: UUID            // peripheral.identifier
        let name: String
        var rssi: Int
    }
    private(set) var discovered: [DiscoveredRing] = []
    /// The CBPeripheral objects behind `discovered`, kept so a picker tap can connect by id.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    /// Foreground scans accumulate matches and debounce before deciding (auto-connect vs. picker);
    /// background/service-filtered scans connect on the first match (there's no UI off-screen).
    private var allowPicker = false
    /// "Choose a ring" mode (the Switch-ring flow): show the picker for ANY discovered ring and never
    /// auto-connect a lone one — the user is deliberately picking, so even one ring must be confirmed
    /// (otherwise the just-disconnected active ring would silently grab the link straight back).
    private(set) var choosingRing = false
    /// Fires once the discovery set has been quiet briefly: 1 ring → auto-connect, >1 → leave the
    /// picker up for the user. Re-armed only when a NEW distinct ring appears (not on RSSI updates),
    /// so a ring that keeps advertising can't push the decision out forever.
    private var selectionDebounce: Task<Void, Never>?
    /// Gives up a fruitless foreground scan so the radio doesn't spin forever when nothing is found.
    private var scanTimeoutTask: Task<Void, Never>?
    /// Quiet window after the latest new ring before we decide. Sized generously (not snappy-minimal)
    /// so a second, weaker-signal ring whose first advertisement arrives a beat after the first still
    /// surfaces BEFORE a lone-ring auto-connect would fire — i.e. the picker isn't silently skipped.
    /// This only adds latency to the explicit "Scan & connect" tap, never to the silent reconnect path.
    private static let selectionQuietWindow: TimeInterval = 2.5
    private static let scanTimeout: TimeInterval = 25

    /// Service filter for background scans. iOS only delivers scan results to a
    /// backgrounded app when `scanForPeripherals` filters by explicit service UUIDs;
    /// a `nil` filter (used in the foreground) yields nothing in the background (#14).
    /// Caveat: this still requires the ring to advertise its data service — if it
    /// advertises name-only, background reconnection must instead use
    /// `central.connect(knownPeripheral)` against a persisted identifier.
    private static let backgroundScanServices = [CBUUID(string: OpenCircuitKit.Transport.dataServiceUUID)]

    /// Begin scanning. Foreground callers pass no filter: the ring is matched by its
    /// advertised name (`matchesRingName`) and is not known to advertise its data
    /// service, so filtering there could miss it. The background path passes
    /// `backgroundScanServices` because nil-filtered scans are dropped while backgrounded.
    func start(services: [CBUUID]? = nil) {
        guard central.state == .poweredOn else { return }
        wantConnection = true
        resetReconnectBackoff()   // a fresh user scan starts clean — no lingering backoff/calm state
        // Foreground scans (nil filter) accumulate matches and let the user pick when >1 ring is in
        // range; background scans (service-filtered) connect on the first match — there's no UI.
        allowPicker = (services == nil)
        choosingRing = false
        if allowPicker {
            clearDiscovery()
            armScanTimeout()
        }
        state = .scanning
        central.scanForPeripherals(withServices: services)
    }

    /// Scan for OTHER nearby rings for the in-app "Connect a different ring" picker, WITHOUT dropping
    /// the current link. The connected ring doesn't advertise, so it won't appear; the user stays
    /// connected (and reconnect-safe) until they actually pick another. The picker view reads
    /// `discovered`, taps call `connect(to:)`, and dismissing calls `stopBrowsing()`. We deliberately
    /// do NOT enter the `.scanning` state — the existing connection (and its UI) stays as-is.
    func startBrowsing() {
        guard central.state == .poweredOn else { return }
        allowPicker = true     // didDiscover accumulates into `discovered` instead of connect-on-first
        choosingRing = true    // never auto-connect a lone ring — the user is explicitly choosing
        clearDiscovery()
        central.scanForPeripherals(withServices: nil)
    }

    /// Stop the in-app picker scan (sheet dismissed / ring chosen). Leaves any current link intact.
    func stopBrowsing() {
        choosingRing = false
        clearDiscovery()
        central.stopScan()
    }

    /// Connect to a specific discovered ring — a picker tap, or the auto-connect of a lone match.
    /// Makes it the active ring on a successful connect (`didConnect` → `rememberRing`).
    func connect(to id: UUID) {
        guard let peripheral = discoveredPeripherals[id] else { return }
        choosingRing = false
        resetReconnectBackoff()   // drop any pending backoff reconnect to the previous ring (#multi-ring)
        selectionDebounce?.cancel(); selectionDebounce = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        central.stopScan()
        // Switching from a DIFFERENT live ring (the in-app picker scans without dropping the current
        // link): tear the old one down first so we don't leak its connection / run two sessions. The
        // identity guards in didDisconnect/didFailToConnect ignore the old ring's late callbacks.
        if let current = target, current.identifier != id {
            central.cancelPeripheralConnection(current)
            teardownSession()
        }
        wantConnection = true
        target = peripheral
        state = .connecting(peripheral.name ?? "RingConn")
        central.connect(peripheral)
    }

    /// Drop the discovery set and cancel its timers. Called on a fresh scan, on connect, and on stop.
    private func clearDiscovery() {
        selectionDebounce?.cancel(); selectionDebounce = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        discovered = []
        discoveredPeripherals = [:]
    }

    /// After the discovery set settles: a lone ring auto-connects (preserving the one-tap flow);
    /// more than one leaves the picker up for the user. No-op once we've left the scanning state, or
    /// in "choose" mode (where even a lone ring must be confirmed by tapping it).
    private func armSelectionDebounce() {
        selectionDebounce?.cancel()
        selectionDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.selectionQuietWindow))
            guard let self, !Task.isCancelled else { return }
            guard case .scanning = self.state, !self.choosingRing else { return }
            if self.discovered.count == 1, let only = self.discovered.first {
                self.connect(to: only.id)
            }
        }
    }

    /// Stop a foreground scan that turned up nothing, so the radio doesn't spin forever and the UI
    /// can show the Scan button again. If rings WERE found (picker showing) we keep scanning so the
    /// list stays live until the user picks.
    private func armScanTimeout() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.scanTimeout))
            guard let self, !Task.isCancelled else { return }
            guard case .scanning = self.state, self.discovered.isEmpty else { return }
            self.selectionDebounce?.cancel(); self.selectionDebounce = nil
            self.central.stopScan()
            self.state = .idle
        }
    }

    func stop() {
        wantConnection = false
        resetReconnectBackoff()   // user stop: cancel any pending backoff reconnect
        clearDiscovery()          // abandon any in-flight foreground scan / picker
        choosingRing = false
        // Explicit user stop: clear the ACTIVE ring so we don't silently auto-reconnect on the next
        // launch (reconnect-by-identifier only re-arms while a ring is active). The ring stays in the
        // remembered set so it's still one tap away in the picker. (Reviewer MINOR.)
        Self.activePeripheralID = nil
        central.stopScan()
        if let target { central.cancelPeripheralConnection(target) }
        if case .scanning = state { state = .idle }
    }

    /// Abort an in-flight foreground scan / picker WITHOUT forgetting the active ring (unlike `stop`,
    /// which is a deliberate "forget this ring"). Wired to the connect card's Cancel while searching
    /// or choosing, so backing out of a scan never disarms the silent auto-reconnect to the last ring.
    func cancelScan() {
        resetReconnectBackoff()
        clearDiscovery()
        choosingRing = false
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    /// Tear down the active session (#42): persist its last live reading + captured pages
    /// (`stopLiveMonitoring`), then cancel EVERY task it owns (`invalidate`), then release it.
    /// Called everywhere `session` is replaced or dropped — before assigning a new session in
    /// `didConnect`/`willRestoreState`, and on disconnect — so a stale session's keepalive/
    /// auto-measure/sync loops can never keep writing to the peripheral behind a newer one.
    private func teardownSession() {
        session?.stopLiveMonitoring()
        session?.invalidate()
        session = nil
    }

    /// Cancel any in-flight reconnect backoff and clear the calm state (#35). Used on a fresh
    /// user scan, a user stop/disconnect, and once a link proves stable. Also clears the
    /// deferred radio-off reconnect flag: a backoff timer that fired while the radio was off
    /// sets `reconnectWhenPoweredOn`, and a subsequent user `disconnect()` must not leave that
    /// armed — otherwise the next `.poweredOn` would re-issue a reconnect against disconnect()'s
    /// "STOP auto-reconnecting" intent. (Reviewer MINOR.)
    private func resetReconnectBackoff() {
        reconnectTask?.cancel(); reconnectTask = nil
        connectStableTask?.cancel(); connectStableTask = nil
        reconnectAttempts = 0
        reconnectStalled = false
        reconnectWhenPoweredOn = false
    }

    /// Reconnect to the last-known ring WITHOUT scanning. `retrievePeripherals` resurfaces a
    /// peripheral we've connected to before by its CoreBluetooth identifier; `connect` then
    /// issues a *pending* connect that has no timeout — it completes the moment the ring is in
    /// range, even from the background. This is the reliable background path: iOS drops
    /// no-service-filter background scans, but it honours a pending connect-by-identifier and
    /// will relaunch us (via state restoration) to complete it.
    ///
    /// Returns `false` when there's no saved ring to reconnect to (caller falls back to a scan).
    @discardableResult
    func reconnectKnownPeripheral() -> Bool {
        switch state {
        case .connected, .connecting: return true   // already (re)connecting — nothing to do
        default: break
        }
        guard central.state == .poweredOn else {
            // Bluetooth not ready yet (common on a cold/background launch). Retry from
            // centralManagerDidUpdateState once we reach `.poweredOn`.
            reconnectWhenPoweredOn = true
            return false
        }
        reconnectWhenPoweredOn = false
        guard let idString = Self.activePeripheralID,
              let uuid = UUID(uuidString: idString),
              let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
        else { return false }
        wantConnection = true
        target = peripheral
        state = .connecting(peripheral.name ?? "RingConn")
        central.connect(peripheral)
        return true
    }

    func setLocalStore(_ localStore: LocalStore) {
        self.localStore = localStore
        session?.setLocalStore(localStore)
    }

    /// Tear down the live link and STOP auto-reconnecting. Clearing `wantConnection`
    /// before cancelling is essential: otherwise `didDisconnectPeripheral` still wants a
    /// connection and immediately reconnects, looping forever (#14 fix).
    func disconnect() {
        wantConnection = false
        resetReconnectBackoff()   // user stop: drop any pending backoff reconnect (#35)
        clearDiscovery()          // abandon any in-flight foreground scan / picker
        choosingRing = false
        central.stopScan()
        if let target {
            central.cancelPeripheralConnection(target)
        }
        teardownSession()         // cancel all of the session's tasks, not just the live poll (#42)
        target = nil
        state = .idle
    }

    /// End-of-background-read teardown that RE-ARMS reconnection. The bounded read must not
    /// leave the link held open, but a plain `disconnect()` also clears the standing pending
    /// connect that lets iOS wake us (state restoration) next time the ring is in range —
    /// disarming the very background path we want. So: drop the live link, then re-issue a
    /// no-scan pending connect-by-identifier so reconnection stays armed across the next
    /// suspension. (Reviewer MAJOR fix.)
    private func endBackgroundReadRearming() {
        teardownSession()   // stopLiveMonitoring + cancel keepalive/auto-measure/sync tasks (#42)
        if let target { central.cancelPeripheralConnection(target) }
        target = nil
        state = .idle
        reconnectKnownPeripheral()   // re-arm the standing pending connect (no scan)
    }

    /// What a bounded background read captured. The background read runs the SAME two-channel
    /// `syncHistory()` drain the foreground uses (0x00 sleep + 0x03 all-day, #99), so overnight AND
    /// daytime HR/HRV/SpO2 + sleep segments + step/temp land in the store, THEN it polls a quick
    /// live HR — and we still come away with last night's data even when the optical HR never locks.
    /// `gotData` is the BGTask success flag — true if we captured anything worth persisting, not
    /// just an HR.
    struct BackgroundCapture {
        var heartRate: Int?
        var sleepSegments: [SleepSegment] = []
        var steps: Int?
        var gotData: Bool { heartRate != nil || !sleepSegments.isEmpty || (steps ?? 0) > 0 }
    }

    /// Bounded one-shot background read: reconnect (no-scan by identifier, else a
    /// service-filtered scan), drain + decode the ring's history, and snapshot it for the
    /// caller to mirror into Apple Health. Always tears the link down (re-arming the standing
    /// reconnect) on the way out so nothing is held open in the background.
    func captureForBackground(timeout: TimeInterval) async -> BackgroundCapture {
        let deadline = Date().addingTimeInterval(timeout)
        var didDrain = false
        var startedLiveRead = false
        if !reconnectKnownPeripheral() {
            start(services: Self.backgroundScanServices)
        }

        var capture = BackgroundCapture()
        defer { endBackgroundReadRearming() }

        while !Task.isCancelled && Date() < deadline {
            if let session, session.ready {
                if !didDrain {
                    // Thorough history drain — BOTH channels (0x00 sleep + 0x03 all-day daytime
                    // SpO₂/HR), the SAME `syncHistory()` path the foreground Sync / pull-to-refresh
                    // use, so the background captures daytime data too, not just overnight (#99).
                    // Previously this opened the live-enter drain (channel 0x00 only) which is why
                    // automatic syncs never refreshed daytime SpO₂.
                    session.syncHistory()
                    didDrain = true
                } else if session.syncing == false && !startedLiveRead && !session.isInSleepWindow {
                    // Backlog committed — now a quick optical HR read (syncAll → empty → fast lock),
                    // NOT user-initiated so any prior live HR stays until a fresh one locks. The
                    // extended background timeout gives this poll a real budget past its warm-up (#45 A).
                    // Skipped in the sleep window: a live read opens `syncAll` (FFFFFFFF), whose
                    // resume-pointer effect is the 🟡 backlog-shredder risk (PROTOCOL.md §3) — so an
                    // overnight BGTask leaves the ring fully alone to log the night for one morning sync.
                    session.startMonitoring(mode: .hr, userInitiated: false, quickLiveRead: true)
                    startedLiveRead = true
                }
                // Snapshot the decoded history as it lands; the drain completes before the
                // first live HR, so this captures sleep/steps even if HR never locks.
                if !session.sleepSegments.isEmpty { capture.sleepSegments = session.sleepSegments }
                if let s = session.steps { capture.steps = s }
                if let liveHR = session.liveHR { capture.heartRate = liveHR; break }
            } else if case .idle = state {
                if !reconnectKnownPeripheral() {
                    start(services: Self.backgroundScanServices)
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // Final snapshot before teardown, in case we exited on the deadline after the drain
        // completed but before a live HR arrived.
        if let session {
            if capture.sleepSegments.isEmpty { capture.sleepSegments = session.sleepSegments }
            if capture.steps == nil { capture.steps = session.steps }
            if capture.heartRate == nil { capture.heartRate = session.liveHR }
        }
        return capture
    }
}

extension RingScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                // Don't clobber a link state restoration already rebuilt: willRestoreState
                // runs BEFORE this and may have set .connected/.connecting. Only fall back to
                // .idle from a non-connected state (otherwise the UI would show "Scan & connect"
                // over a live connection).
                switch self.state {
                case .connected, .connecting: break
                default: self.state = .idle
                }
                // A reconnect was requested before Bluetooth was ready (cold/background launch,
                // or a backoff reconnect that armed while the radio was off) — complete it now.
                // When we already hold the peripheral object, connect it directly: a backoff sets
                // state to `.connecting`, which `reconnectKnownPeripheral` treats as "already
                // connecting" and no-ops — connecting `target` ourselves avoids that stall. (#35)
                if self.reconnectWhenPoweredOn {
                    self.reconnectWhenPoweredOn = false
                    if let target = self.target {
                        self.central.connect(target)
                    } else {
                        self.reconnectKnownPeripheral()
                    }
                }
                // A session restored before the radio was up may have fired its discovery
                // into the void (chars never matched → never `ready`). Re-kick it now. The
                // session also self-heals on the first frame it receives (#reconnect).
                if let session = self.session, session.ready != true {
                    session.rediscoverIfNeeded()
                }
            case .poweredOff: self.state = .poweredOff
            case .unauthorized: self.state = .unauthorized
            default: self.state = .idle
            }
        }
    }

    /// State restoration entry point. iOS calls this (before `centralManagerDidUpdateState`)
    /// when it relaunches the app and hands back the central's preserved peripherals — those
    /// we were connected to or had a pending connect for at suspension. We re-adopt the ring
    /// as our target and re-attach the session so the link keeps working with no user action.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let peripheral = self.restoredTarget(from: restored) else { return }
            self.wantConnection = true
            self.target = peripheral
            switch peripheral.state {
            case .connected:
                // The link survived the relaunch — rebuild the session now; `didConnect`
                // won't fire again. RingSession re-matches characteristics (skipping a full
                // service re-discovery when they're already present, #42).
                Self.rememberRing(peripheral.identifier.uuidString)
                self.state = .connected(peripheral.name ?? "RingConn")
                // Tear down any session that already exists (e.g. a later `didConnect` racing this
                // restore) before replacing it, so its tasks don't keep writing to the peripheral
                // behind the new session (#42).
                self.teardownSession()
                self.session = RingSession(peripheral: peripheral, localStore: self.localStore)
            case .connecting:
                // Pending connect still in flight; `didConnect` will complete it.
                self.state = .connecting(peripheral.name ?? "RingConn")
            default:
                // Re-issue the pending connect so we reconnect when the ring is in range.
                self.state = .connecting(peripheral.name ?? "RingConn")
                if self.central.state == .poweredOn {
                    self.central.connect(peripheral)
                } else {
                    // Radio not up yet on a cold restoration — retry once powered on.
                    self.reconnectWhenPoweredOn = true
                }
            }
        }
    }

    /// Pick which restored peripheral to re-adopt: prefer the active ring, else the first.
    private func restoredTarget(from peripherals: [CBPeripheral]) -> CBPeripheral? {
        if let id = Self.activePeripheralID,
           let match = peripherals.first(where: { $0.identifier.uuidString == id }) {
            return match
        }
        return peripherals.first
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""
        guard OpenCircuitKit.Transport.matchesRingName(name) else { return }
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard self.allowPicker else {
                // Background / service-filtered scan: no UI — connect on the first match.
                self.central.stopScan()
                self.target = peripheral
                self.state = .connecting(name)
                self.central.connect(peripheral)
                return
            }
            // Foreground: accumulate distinct rings, then debounce → auto-connect one / show a picker.
            let id = peripheral.identifier
            let isNew = self.discoveredPeripherals[id] == nil
            self.discoveredPeripherals[id] = peripheral
            if let idx = self.discovered.firstIndex(where: { $0.id == id }) {
                // Keep a previously-seen name if this advertisement frame lacks one.
                let keptName = name.isEmpty ? self.discovered[idx].name : name
                self.discovered[idx] = DiscoveredRing(id: id, name: keptName, rssi: rssi)
            } else {
                self.discovered.append(DiscoveredRing(id: id, name: name, rssi: rssi))
            }
            // Re-arm only when a NEW ring appears — RSSI refreshes of a known ring must not keep
            // pushing the auto-connect decision out.
            if isNew { self.armSelectionDebounce() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Remember this ring (and make it active) so we can reconnect by identifier (no scan)
            // after a cold launch or background relaunch.
            self.target = peripheral
            Self.rememberRing(peripheral.identifier.uuidString)
            self.central.stopScan()  // defensive: a reconnect/restoration connect may land mid-scan
            self.clearDiscovery()    // scan succeeded — drop the discovery set / picker
            // A connect landed — stop any pending backoff timer and clear the calm "unreachable"
            // note. (We don't reset the attempt COUNT yet: a charging ring can connect then
            // immediately drop, so the backoff only truly resets once the link proves stable.) #35
            self.reconnectTask?.cancel(); self.reconnectTask = nil
            self.reconnectStalled = false
            self.state = .connected(peripheral.name ?? "RingConn")
            // Tear down any prior session before replacing it so its keepalive/auto-measure/sync
            // tasks can't keep driving the same peripheral behind the new session (#42).
            self.teardownSession()
            self.session = RingSession(peripheral: peripheral, localStore: self.localStore)
            self.armConnectStabilityReset()
        }
    }

    /// Arm the backoff reset (#35). Only once a reconnected link has SURVIVED a beat AND delivered
    /// a real frame (`session.lastFrameAt`) do we trust it and zero the attempt count — so a
    /// charging ring's connect/reject loop (which never delivers a frame) keeps the backoff
    /// climbing instead of resetting on every brief connect.
    private func armConnectStabilityReset() {
        connectStableTask?.cancel()
        connectStableTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectStablePeriod))
            guard let self, !Task.isCancelled else { return }
            if case .connected = self.state, self.session?.lastFrameAt != nil {
                self.reconnectAttempts = 0
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            // Ignore disconnects for a ring we've intentionally moved on from. When switching rings,
            // `connect(to:)` cancels the old ring and sets `target` to the new one synchronously — so
            // a late `didDisconnect` for the OLD ring must not tear down the new session or reconnect
            // the old ring (which would bounce us back and leak the new link). (#multi-ring)
            guard peripheral.identifier == self.target?.identifier else { return }
            self.connectStableTask?.cancel(); self.connectStableTask = nil
            self.teardownSession()   // cancel ALL of the session's tasks, persisting last reading (#42)
            // Auto-reconnect: CoreBluetooth's connect has no timeout — it reconnects (using the
            // persisted bond) the moment the ring wakes/comes back in range, so the user never has
            // to re-pair or open the official app again. But we no longer re-issue it IMMEDIATELY:
            // a ring on the charger that drops the link in a loop would keep the radio armed for
            // hours. Back off with a growing delay instead (#35).
            if self.wantConnection {
                self.scheduleReconnect(peripheral)
            } else {
                self.state = .idle
            }
        }
    }

    /// A connect attempt failed outright (as opposed to connecting then dropping). Recover the same
    /// way as a disconnect: back off and retry while we still want the ring, else fall idle — so the
    /// UI never wedges on a permanent "Connecting…" after a failed attempt.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            // Same identity guard as didDisconnect: a failed connect for a ring we've switched away
            // from must not schedule a reconnect to it over the new target. (#multi-ring)
            guard peripheral.identifier == self.target?.identifier else { return }
            self.connectStableTask?.cancel(); self.connectStableTask = nil
            if self.wantConnection {
                self.scheduleReconnect(peripheral)
            } else {
                self.state = .idle
            }
        }
    }
}

extension RingScanner {
    /// Schedule a backoff reconnect after a disconnect (#35). Each consecutive failure stretches
    /// the delay (1 s → 5 s → 30 s cap); a stable, frame-delivering connect resets it. We keep the
    /// cheap standing pending connect — we just delay re-issuing it and do NOT actively re-scan
    /// during the wait. After a few failures the UI switches to a calm "unreachable" note.
    private func scheduleReconnect(_ peripheral: CBPeripheral) {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let delay = ReconnectBackoff.delay(forAttempt: reconnectAttempts)
        reconnectStalled = ReconnectBackoff.shouldSurfaceCalmState(attempts: reconnectAttempts)
        target = peripheral
        state = .connecting(peripheral.name ?? "RingConn")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.wantConnection else { return }
            // Don't fight a link that already came back during the wait.
            if case .connected = self.state { return }
            if self.central.state == .poweredOn {
                self.central.connect(peripheral)   // single standing pending connect (no scan)
            } else {
                // Radio not up yet — let the poweredOn handler complete the reconnect-by-identifier.
                self.reconnectWhenPoweredOn = true
            }
        }
    }
}
