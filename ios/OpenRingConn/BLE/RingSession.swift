import Foundation
import CoreBluetooth
import Observation
import OpenRingKit

// An active link to a connected ring: discovers the notify/write characteristics
// by UUID, enables notifications, sends commands, and decodes responses through
// OpenRingKit's confirmed codec. Spec-supported behavior implemented:
//   • live-HR poll (0x95 → 0x15, LiveHR.decode 🟡)
//   • history sync: drain 0x4c activity/sleep pages → BulkSleep → HR/HRV/SpO2
//     samples (PROTOCOL.md §5.3, 🟢 fields). 0x47 PPG pages are acked but not yet
//     decoded (their payload is 🔴 — issue #8).

@Observable
@MainActor
final class RingSession: NSObject {

    private(set) var liveHR: Int?
    private(set) var liveSpO2: Int?       // 🟡 from long 0x15 frame byte[14]
    private(set) var monitoring = false
    private(set) var lastFrame: String?
    private(set) var ready = false

    private var monitorTask: Task<Void, Never>?

    /// Sleep-vitals samples (HR/HRV/SpO2) decoded from the last history sync,
    /// finalized when the ring reports end-of-history (0x50). Feed to HealthKitWriter.
    private(set) var historySamples: [QuantitySample] = []
    /// Sleep-stage segments computed from the motion channel for the last sync
    /// (coarse inBed/asleepCore/awake — the version written to HealthKit).
    private(set) var sleepSegments: [SleepSegment] = []
    /// Experimental Light/Deep/REM/Awake staging (HR+motion heuristic, approximate —
    /// matches stage totals but not architecture; for display, not HealthKit).
    private(set) var stagedSegments: [SleepSegment] = []
    /// True while 0x4c pages are still arriving for the current sync.
    private(set) var syncing = false

    private var bulkRecords: [BulkRecord] = []

    private let peripheral: CBPeripheral
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?

    private let notifyUUID = CBUUID(string: OpenRingKit.Transport.notifyCharUUID)
    private let writeUUID = CBUUID(string: OpenRingKit.Transport.writeCharUUID)

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    /// Begin live monitoring: open the session at *now* (so there's no history backlog
    /// to drain and flood the link), enter HR mode (`d0` → `06 01 00` → fetch), then poll
    /// `95 00 00` ~1/s. Writes are paced ~300 ms apart so CoreBluetooth doesn't drop them.
    /// Updates `liveHR`/`liveSpO2`. Idempotent.
    func startLiveMonitoring() {
        guard monitorTask == nil else { return }
        monitoring = true
        let openNow = Command.syncSince(unixSeconds: Int(Date().timeIntervalSince1970))
        let enterSeq: [[UInt8]] = [Command.status0, Command.status1, openNow,
                                   Command.statusQuery, Command.liveHRMode, Command.fetch]
        monitorTask = Task { [weak self] in
            for cmd in enterSeq {
                guard let self else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(300))
            }
            while !Task.isCancelled {
                guard let self else { return }
                self.write(Command.poll)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stop the poll loop. HR/SpO2 keep their last value.
    func stopLiveMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        monitoring = false
    }

    /// Pull stored history: open the sync session (cursor = everything) and fetch.
    /// The ring streams 0x4c/0x47 pages, drained+decoded in didUpdateValue; results
    /// land in `historySamples` once 0x50 (end-of-history) arrives.
    func syncHistory() {
        bulkRecords.removeAll()
        historySamples.removeAll()
        sleepSegments.removeAll()
        stagedSegments.removeAll()
        syncing = true
        for cmd in [Command.status0, Command.status1, Command.syncAll, Command.fetch] {
            write(cmd)
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let writeChar else { return }
        // Write char advertises `write` (with response).
        peripheral.writeValue(Data(bytes), for: writeChar, type: .withResponse)
    }
}

extension RingSession: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                if ch.uuid == self.notifyUUID {
                    self.notifyChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                } else if ch.uuid == self.writeUUID {
                    self.writeChar = ch
                }
            }
            self.ready = (self.notifyChar != nil && self.writeChar != nil)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            self.lastFrame = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            // Bulk history pages: accumulate + ack to continue draining (47→c7, 4c→cc).
            switch bytes.first {
            case 0x47:
                self.write(Command.pageAck47); return   // PPG page — decode TODO (issue #8)
            case 0x4C:
                if self.syncing { self.bulkRecords += BulkSleep.records(fromPage: bytes) }
                self.write(Command.pageAck4C); return   // always ack to keep draining
            case 0x50:
                // End-of-history cursor report (§5.5) — note: NO XOR trailer, so it
                // never reaches Frame.parse. Finalize the sync here.
                if self.syncing {
                    self.historySamples = BulkSleep.samples(from: self.bulkRecords)
                    self.sleepSegments = BulkSleep.sleepSegments(from: self.bulkRecords)
                    self.stagedSegments = BulkSleep.stagedSegments(from: self.bulkRecords)
                    self.syncing = false
                }
                return
            default: break
            }
            guard let frame = Frame.parse(bytes) else { return }   // XOR-validate responses
            // 0x15 = live-sample stream (resp of 0x95 poll). Two shapes:
            //   short `15 00 <hr> 0a b0`  → HR at byte[2] (🟢)
            //   long  `15 01 … <spo2> …`  → byte[2]=0; SpO2 at byte[14] (🟡)
            // Only the short frame carries HR — don't let a long frame zero it out.
            if frame.opcode == Frame.responseID(Opcode.poll) {
                if let hr = LiveHR.decodeLocked(bytes) { self.liveHR = hr }      // short frame, warm-up filtered
                if let spo2 = LiveHR.decodeSpO2(bytes) { self.liveSpO2 = spo2 }  // long frame, 🟡
            }
        }
    }
}
