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

    private(set) var state: State = .idle
    private(set) var session: RingSession?

    private var central: CBCentralManager!
    private var target: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        guard central.state == .poweredOn else { return }
        state = .scanning
        // Discover all services (the ring is reportedly not fully GATT-compatible,
        // so we don't filter by service UUID — those roles are 🔴 in PROTOCOL.md).
        central.scanForPeripherals(withServices: nil)
    }

    func stop() {
        central.stopScan()
        if case .scanning = state { state = .idle }
    }
}

extension RingScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: self.state = .idle
            case .poweredOff: self.state = .poweredOff
            case .unauthorized: self.state = .unauthorized
            default: self.state = .idle
            }
        }
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
            self.state = .connected(peripheral.name ?? "RingConn")
            self.session = RingSession(peripheral: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.session = nil
            self.state = .idle
        }
    }
}
