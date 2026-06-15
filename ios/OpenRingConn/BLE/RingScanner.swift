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
        state = .scanning
        central.scanForPeripherals(withServices: services)
    }

    func stop() {
        wantConnection = false
        // Explicit user stop: forget the ring so we don't silently auto-reconnect on the next
        // launch (reconnect-by-identifier only re-arms while an id is saved). (Reviewer MINOR.)
        Self.savedPeripheralID = nil
        central.stopScan()
        if let target { central.cancelPeripheralConnection(target) }
        if case .scanning = state { state = .idle }
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
        central.stopScan()
        if let target {
            central.cancelPeripheralConnection(target)
        }
        session = nil
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
        session?.stopLiveMonitoring()
        session = nil
        if let target { central.cancelPeripheralConnection(target) }
        target = nil
        state = .idle
        reconnectKnownPeripheral()   // re-arm the standing pending connect (no scan)
    }

    /// Bounded one-shot live-HR read for the background-refresh task: scan/connect,
    /// start HR monitoring, and return the first reading (or nil on timeout). Always
    /// disconnects on the way out so the link isn't held open in the background.
    func readLiveHeartRate(timeout: TimeInterval) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var didStart = false
        // Prefer a no-scan reconnect-by-identifier (works in the background); only fall back
        // to the service-filtered scan if we've never connected to a ring before.
        if !reconnectKnownPeripheral() {
            start(services: Self.backgroundScanServices)
        }

        defer { endBackgroundReadRearming() }

        while !Task.isCancelled && Date() < deadline {
            if let session, session.ready {
                if !didStart {
                    session.startMonitoring(mode: .hr)
                    didStart = true
                }
                if let liveHR = session.liveHR {
                    return liveHR
                }
            } else if case .idle = state {
                if !reconnectKnownPeripheral() {
                    start(services: Self.backgroundScanServices)
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
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
                // A reconnect was requested before Bluetooth was ready (cold/background
                // launch) — complete it now that the radio is on.
                if self.reconnectWhenPoweredOn { self.reconnectKnownPeripheral() }
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
                // won't fire again. RingSession re-discovers services/characteristics.
                Self.savedPeripheralID = peripheral.identifier.uuidString
                self.state = .connected(peripheral.name ?? "RingConn")
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
            self.state = .connected(peripheral.name ?? "RingConn")
            self.session = RingSession(peripheral: peripheral, localStore: self.localStore)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.session?.stopLiveMonitoring()
            self.session = nil
            // Auto-reconnect: CoreBluetooth's connect has no timeout — it reconnects
            // (using the persisted bond) the moment the ring wakes/comes back in range,
            // so the user never has to re-pair or open the official app again.
            if self.wantConnection {
                self.state = .connecting(peripheral.name ?? "RingConn")
                self.central.connect(peripheral)
            } else {
                self.state = .idle
            }
        }
    }
}
