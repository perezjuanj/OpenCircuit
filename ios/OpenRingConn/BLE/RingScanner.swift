import Foundation
import CoreBluetooth
import Observation
import OpenRingKit

// Scans for the RingConn ring and connects. On iOS there are NO raw ATT handles
// (docs/HANDOFF_MACOS_IOS.md) — everything is addressed by characteristic UUID,
// so RingSession matches the notify/write characteristics by UUID after connect.
//
// The ring is matched by advertised NAME prefix ("RingConn Gen2…", 🟢). The
// notify/write characteristic UUIDs RingSession binds to are now 🟢 confirmed by
// `openringconn scan` (service 8327ad99; notify 8327ad97 = handle 0x0804; write
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
    private static let restoreIdentifier = "com.openringconn.central.restore"

    /// UserDefaults key holding the last connected peripheral's CoreBluetooth identifier
    /// (a per-device UUID — NOT the MAC, which iOS never exposes). Lets us reconnect by
    /// identifier with no scan after a cold launch / background relaunch.
    private static let savedPeripheralKey = "com.openringconn.ring.peripheralID"

    /// Last connected peripheral's `identifier.uuidString`, persisted across launches.
    private static var savedPeripheralID: String? {
        get { UserDefaults.standard.string(forKey: savedPeripheralKey) }
        set { UserDefaults.standard.set(newValue, forKey: savedPeripheralKey) }
    }

    /// True when a previously connected ring's identifier is saved, so a no-scan
    /// reconnect-by-identifier is possible. The foreground auto-refresh uses this to
    /// decide whether there's anything to reconnect to (vs. requiring a user Scan).
    var hasSavedRing: Bool { Self.savedPeripheralID != nil }

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

    /// Service filter for background scans. iOS only delivers scan results to a
    /// backgrounded app when `scanForPeripherals` filters by explicit service UUIDs;
    /// a `nil` filter (used in the foreground) yields nothing in the background (#14).
    /// Caveat: this still requires the ring to advertise its data service — if it
    /// advertises name-only, background reconnection must instead use
    /// `central.connect(knownPeripheral)` against a persisted identifier.
    private static let backgroundScanServices = [CBUUID(string: OpenRingKit.Transport.dataServiceUUID)]

    /// Begin scanning. Foreground callers pass no filter: the ring is matched by its
    /// advertised name (`matchesRingName`) and is not known to advertise its data
    /// service, so filtering there could miss it. The background path passes
    /// `backgroundScanServices` because nil-filtered scans are dropped while backgrounded.
    func start(services: [CBUUID]? = nil) {
        guard central.state == .poweredOn else { return }
        wantConnection = true
        resetReconnectBackoff()   // a fresh user scan starts clean — no lingering backoff/calm state
        state = .scanning
        central.scanForPeripherals(withServices: services)
    }

    func stop() {
        wantConnection = false
        resetReconnectBackoff()   // user stop: cancel any pending backoff reconnect
        // Explicit user stop: forget the ring so we don't silently auto-reconnect on the next
        // launch (reconnect-by-identifier only re-arms while an id is saved). (Reviewer MINOR.)
        Self.savedPeripheralID = nil
        central.stopScan()
        if let target { central.cancelPeripheralConnection(target) }
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
    /// user scan, a user stop/disconnect, and once a link proves stable.
    private func resetReconnectBackoff() {
        reconnectTask?.cancel(); reconnectTask = nil
        connectStableTask?.cancel(); connectStableTask = nil
        reconnectAttempts = 0
        reconnectStalled = false
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
        guard let idString = Self.savedPeripheralID,
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

    /// What a bounded background read captured. The background read uses the FULL (quiet-bounded)
    /// drain — `startMonitoring(.hr, userInitiated: false, quickLiveRead: false)` — so the
    /// overnight HR/HRV/SpO2 + sleep segments + step/temp descriptor land in the store before it
    /// polls a live HR, and we still come away with last night's data even when the optical HR
    /// never locks. `gotData` is the BGTask success flag — true if we captured anything worth
    /// persisting, not just an HR.
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
        var didStart = false
        if !reconnectKnownPeripheral() {
            start(services: Self.backgroundScanServices)
        }

        var capture = BackgroundCapture()
        defer { endBackgroundReadRearming() }

        while !Task.isCancelled && Date() < deadline {
            if let session, session.ready {
                if !didStart {
                    // Full drain (capture overnight sleep) but NOT user-initiated — keep any
                    // prior live HR until a fresh one locks. The extended background timeout
                    // (below) is what finally gives the HR poll a real budget so it can lock
                    // instead of being crammed behind the drain (#45 A).
                    session.startMonitoring(mode: .hr, userInitiated: false, quickLiveRead: false)
                    didStart = true
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
                Self.savedPeripheralID = peripheral.identifier.uuidString
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

    /// Pick which restored peripheral to re-adopt: prefer the saved id, else the first.
    private func restoredTarget(from peripherals: [CBPeripheral]) -> CBPeripheral? {
        if let id = Self.savedPeripheralID,
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
        guard OpenRingKit.Transport.matchesRingName(name) else { return }
        Task { @MainActor in
            self.central.stopScan()
            self.target = peripheral
            self.state = .connecting(name)
            self.central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Remember this ring so we can reconnect by identifier (no scan) after a
            // cold launch or background relaunch.
            self.target = peripheral
            Self.savedPeripheralID = peripheral.identifier.uuidString
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
