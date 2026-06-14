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

    enum LiveMode { case hr, spo2 }

    private(set) var liveHR: Int?
    private(set) var liveSpO2: Int?       // 🟡 from long 0x15 frame byte[14]
    /// Recent live-HR samples (oldest→newest, capped). Lets the UI show whether the
    /// reading is converging vs. stuck — these sensors report a windowed average that
    /// climbs over ~20–60 s of stillness, so a single number is misleading.
    private(set) var liveHRTrend: [Int] = []
    /// Raw byte[2] of the most recent SHORT HR frame while still below the lock
    /// threshold (sensor warming up / poor contact). Lets the UI prove frames are
    /// arriving and climbing, vs. no HR frames at all.
    private(set) var liveHRWarmup: Int?
    private(set) var steps: Int?          // ring onboard step count (0x10/0x87 [4:6], §5.4)
    private(set) var liveMode: LiveMode = .hr
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
    /// True while a history sync is in progress.
    private(set) var syncing = false
    /// User-facing result of the last sync (e.g. "204 epochs"), or an error note.
    private(set) var syncStatus: String?

    private var bulkRecords: [BulkRecord] = []
    private var syncTask: Task<Void, Never>?
    private var syncDone = false        // 0x50 end-of-history seen
    private var syncQuietTicks = 0      // seconds since the last page arrived

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
        // Live and history sync can't coexist (ring is one mode at a time). Cancel any
        // in-flight sync so the ring is free to enter live mode.
        syncTask?.cancel(); syncTask = nil
        syncing = false
        monitoring = true
        liveHRTrend.removeAll()   // fresh convergence window
        liveHRWarmup = nil
        let modeCmd = liveMode == .hr ? Command.liveHRMode : Command.liveSpO2Mode
        // Proven enter sequence (PROTOCOL.md §5.1): open session, drain a history record
        // (the extra `fetch`), then d0 status query → mode byte → fetch. The history
        // drain + d0 are what reliably leaves bulk mode so the live stream starts.
        let enterSeq: [[UInt8]] = [Command.status0, Command.status1, Command.syncAll,
                                   Command.fetch, Command.statusQuery, modeCmd, Command.fetch]
        monitorTask = Task { [weak self] in
            for cmd in enterSeq {
                guard let self else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Pure polling only. Do NOT inject `d0` (status query) here to refresh steps:
            // d0 re-arms the mode switch and kicks the HR session back to its warm-up
            // sentinel (byte[2]=8), so the reading never climbs. Steps refresh from the
            // ring's spontaneous 0x10/0x87 frames instead.
            while !Task.isCancelled {
                guard let self else { return }
                self.write(Command.poll)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Start (or switch) live monitoring in a single mode. Guarantees only one metric
    /// reads at a time: switching to a mode puts the ring in `06 01`/`06 02`, so frames
    /// for the other metric stop arriving.
    func startMonitoring(mode: LiveMode) {
        if monitoring {
            setLiveMode(mode)
        } else {
            liveMode = mode
            startLiveMonitoring()
        }
    }

    /// Switch live measurement between HR (`06 01 00`) and SpO2 (`06 02 00`). The ring
    /// measures one at a time; the other metric keeps its last value. No-op until the
    /// next start if not currently monitoring.
    func setLiveMode(_ mode: LiveMode) {
        guard liveMode != mode else { return }
        liveMode = mode
        liveHRTrend.removeAll()   // restarting the HR window
        liveHRWarmup = nil
        guard monitoring else { return }
        let modeCmd = mode == .hr ? Command.liveHRMode : Command.liveSpO2Mode
        // Re-arm with the d0 status query before the mode byte (mirrors the proven enter
        // sequence) — switching the mode byte alone doesn't reliably restart the short
        // 15 00 HR stream when coming back from SpO2.
        Task { [weak self] in
            guard let self else { return }
            self.write(Command.statusQuery)
            try? await Task.sleep(for: .milliseconds(250))
            self.write(modeCmd)
            try? await Task.sleep(for: .milliseconds(250))
            self.write(Command.fetch)
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
        guard syncTask == nil else { return }   // already syncing
        stopLiveMonitoring()                     // live polling would fight the drain
        bulkRecords.removeAll()
        historySamples.removeAll()
        sleepSegments.removeAll()
        stagedSegments.removeAll()
        syncDone = false
        syncQuietTicks = 0
        syncing = true
        syncStatus = nil
        syncTask = Task { [weak self] in
            // Paced enter so CoreBluetooth doesn't drop writes.
            for cmd in [Command.status0, Command.status1, Command.syncAll, Command.fetch] {
                guard let self else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Watchdog: finalize on 0x50, or when pages stop (4 s quiet), or a 45 s cap —
            // so the sync can never hang if the end-marker or a write is lost.
            for tick in 0 ..< 45 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.syncDone || self.syncQuietTicks >= 4 { break }
                _ = tick
            }
            self?.finalizeSync()
        }
    }

    private func finalizeSync() {
        guard syncing else { return }
        historySamples = BulkSleep.samples(from: bulkRecords)
        sleepSegments = BulkSleep.sleepSegments(from: bulkRecords)
        stagedSegments = BulkSleep.stagedSegments(from: bulkRecords)
        syncing = false
        syncTask = nil
        if !bulkRecords.isEmpty {
            syncStatus = "Synced \(bulkRecords.count) epochs"
        } else if steps != nil {
            // Link is fine (status frames arrived) — the ring just had no un-synced
            // sleep/vitals pages. It only holds history it hasn't handed off yet, so
            // once the official app (or a prior sync) drains it, there's nothing left.
            syncStatus = "No new sleep/vitals history on the ring (it only keeps un-synced data). Live status OK."
        } else {
            syncStatus = "No data received — is the ring bonded/awake?"
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
            // Ring step count rides the 0x10/0x87 descriptor [4:6] (§5.4). Frames with 0
            // are interleaved, so take the running max (today's cumulative count).
            if let s = DeviceStatus.steps(bytes), s > 0 {
                self.steps = max(self.steps ?? 0, s)
            }
            // Bulk history pages: accumulate + ack to continue draining (47→c7, 4c→cc).
            switch bytes.first {
            case 0x47:
                if self.syncing { self.syncQuietTicks = 0 }
                self.write(Command.pageAck47); return   // PPG page — decode TODO (issue #8)
            case 0x4C:
                if self.syncing {
                    self.bulkRecords += BulkSleep.records(fromPage: bytes)
                    self.syncQuietTicks = 0
                }
                self.write(Command.pageAck4C); return   // always ack to keep draining
            case 0x50:
                // End-of-history cursor report (§5.5) — NO XOR trailer, so it never
                // reaches Frame.parse. Mark done; the sync watchdog finalizes.
                if self.syncing { self.syncDone = true }
                return
            default: break
            }
            guard let frame = Frame.parse(bytes) else { return }   // XOR-validate responses
            // 0x15 = live-sample stream (resp of 0x95 poll). Two shapes:
            //   short `15 00 <hr> 0a b0`  → HR at byte[2] (🟢)
            //   long  `15 01 … <spo2> …`  → byte[2]=0; SpO2 at byte[14] (🟡)
            // Only the short frame carries HR — don't let a long frame zero it out.
            if frame.opcode == Frame.responseID(Opcode.poll) {
                if let hr = LiveHR.decodeLocked(bytes) {                         // short frame, locked on
                    self.liveHR = hr
                    self.liveHRWarmup = nil
                    self.liveHRTrend.append(hr)
                    if self.liveHRTrend.count > 12 { self.liveHRTrend.removeFirst() }
                } else if let raw = LiveHR.decode(bytes) {                       // short frame, still warming up
                    self.liveHRWarmup = raw
                }
                if let spo2 = LiveHR.decodeSpO2(bytes) { self.liveSpO2 = spo2 }  // long frame, 🟡
            }
        }
    }
}
