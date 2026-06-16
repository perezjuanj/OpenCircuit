import Foundation
import CoreBluetooth
import Observation
import OpenRingKit
import os

/// Unified-logging channel for the BLE/sync path. Stream live from a connected device with:
///   log stream --device --predicate 'subsystem == "com.dreamality.openringconn"'
/// (Logger reaches the unified log; plain `print` on iOS does not.)
let ringLog = Logger(subsystem: "com.dreamality.openringconn", category: "ring")

// An active link to a connected ring: discovers the notify/write characteristics
// by UUID, enables notifications, sends commands, and decodes responses through
// OpenRingKit's confirmed codec. Spec-supported behavior implemented:
//   • live-HR poll (0x95 → 0x15, LiveHR.decode 🟡)
//   • history sync: drain 0x4c activity/sleep pages → BulkSleep → HR/HRV/SpO2
//     samples (PROTOCOL.md §5.3, 🟢 fields). 0x47 PPG pages are acked but not yet
//     decoded (their payload is 🔴 — issue #8).
//   • Layer-A epoch page routing (0x47/0x4c/0x50) also feeds EpochSyncSession in
//     parallel, gated behind `epochDecodingEnabled` (#24).

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
    private(set) var liveTemperature: Double?   // skin temp °C (0x10/0x87 [6:8]/[8:10], §5.4)
    private(set) var batteryPercent: Int?       // ring battery % (0x10/0x87 [1], §5.4 🟢)
    private(set) var liveMode: LiveMode = .hr
    private(set) var monitoring = false
    /// True during the open→drain phase before the live stream starts. The ring won't
    /// emit live frames until its history backlog is fully drained, so we surface this
    /// so the UI shows "preparing" instead of a dead reading.
    private(set) var livePreparing = false
    private(set) var lastFrame: String?
    private(set) var decodedEpochRecords = 0
    private(set) var storedMetricSamples = 0
    private(set) var ready = false
    /// True while the periodic auto-measure (not a user tap) is driving a live read, so the
    /// UI can show a subtle "auto-updating" cue instead of reading as a user measurement.
    private(set) var autoMeasuring = false

    private var monitorTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var autoMeasureTask: Task<Void, Never>?

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
    private var lastRawSteps: Int?       // last raw descriptor [4:6] counter (for delta accumulation)
    private var dailyStepsTotal = 0      // accumulated daily step total (mirrors StoredDaily)
    private var syncTask: Task<Void, Never>?
    private var syncDone = false        // 0x50 end-of-history seen
    private var syncQuietTicks = 0      // seconds since the last page arrived
    private var drainSawPage = false    // a 0x47/0x4c page arrived since last check (live-enter drain)
    private var drainDone = false       // 0x50 end-of-history seen during live-enter drain

    private let peripheral: CBPeripheral
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    /// Throttle for the half-open-link recovery (`rediscoverIfNeeded`).
    private var lastDiscoveryKick: Date?
    private var localStore: LocalStore?
    private var syncSession = EpochSyncSession()
    private let epochDecodingEnabled = false

    private let notifyUUID = CBUUID(string: OpenRingKit.Transport.notifyCharUUID)
    private let writeUUID = CBUUID(string: OpenRingKit.Transport.writeCharUUID)

    init(peripheral: CBPeripheral, localStore: LocalStore? = nil) {
        self.peripheral = peripheral
        self.localStore = localStore
        super.init()
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    /// Begin live monitoring. The ring will NOT emit live frames until its pending
    /// history backlog is fully drained (PROTOCOL.md §5.1 / livehr.py): open the sync
    /// session (cursor 0xFFFFFFFF), drain every 0x47/0x4c page to completion, THEN
    /// `d0` → mode (`06 01`/`06 02`) → fetch, then poll `95 00 00`. Entering live mode
    /// before the drain finishes leaves HR stuck at the warm-up sentinel (8). Idempotent.
    func startLiveMonitoring() {
        guard monitorTask == nil else { return }
        // Live and history sync can't coexist (ring is one mode at a time). Cancel any
        // in-flight sync so the ring is free to enter live mode.
        syncTask?.cancel(); syncTask = nil
        syncing = false
        monitoring = true
        livePreparing = true
        liveHRTrend.removeAll()   // fresh convergence window
        liveHRWarmup = nil
        bulkRecords.removeAll()   // any pages we drain below land here (don't lose them)
        drainSawPage = false
        drainDone = false
        let modeCmd = liveMode == .hr ? Command.liveHRMode : Command.liveSpO2Mode
        monitorTask = Task { [weak self] in
            // 1. Init + open the sync session (cursor = everything; verified, §5.6).
            for cmd in [Command.status0, Command.status1, Command.syncAll] {
                guard let self, !Task.isCancelled else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(250))
            }
            // 2. CRITICAL: drain the history backlog to completion before live mode.
            //    Pages are acked in didUpdateValue; wait for the 0x50 end marker or
            //    ~1.5 s of quiet (cap ~15 s for a large overnight backlog).
            guard let s0 = self, !Task.isCancelled else { return }
            s0.write(Command.fetch)
            var quiet = 0
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if self.drainDone { break }
                if self.drainSawPage { self.drainSawPage = false; quiet = 0 }
                else { quiet += 1; if quiet >= 3 { break } }
            }
            // Surface anything drained so overnight sleep/vitals aren't lost — the ring
            // discards delivered pages, so this is the only chance to keep them.
            if let self, !self.bulkRecords.isEmpty {
                self.historySamples = BulkSleep.samples(from: self.bulkRecords)
                self.sleepSegments = BulkSleep.sleepSegments(from: self.bulkRecords)
                self.stagedSegments = BulkSleep.stagedSegments(from: self.bulkRecords)
                self.persist(self.historySamples)   // auto-persist HR/HRV/SpO2 for the dashboard
                self.persistSleepAndSteps()          // sleep summary + steps for offline display
            }
            // 3. Leave bulk mode and enter the selected live mode.
            for cmd in [Command.statusQuery, modeCmd, Command.fetch] {
                guard let self, !Task.isCancelled else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.livePreparing = false
            // 4. Poll for live samples at the ring's OWN cadence (~2 s/sample, confirmed
            //    in btsnoop_hr.log). The HR windowed average needs undisturbed time to
            //    settle out of the warm-up sentinel (8); polling faster than the sample
            //    rate keeps resetting it so byte[2] never climbs. The official app waits
            //    then polls ~every 2 s, request/response. (SpO2's byte[14] survives fast
            //    polling, which is why only HR got stuck.) No `d0` here — it re-arms the
            //    mode switch and also kicks HR back to warm-up.
            try? await Task.sleep(for: .seconds(2))   // let the ring settle before first poll
            while !Task.isCancelled {
                guard let self else { return }
                self.write(Command.poll)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func setLocalStore(_ localStore: LocalStore) {
        self.localStore = localStore
    }

    /// Idle keepalive — what makes OpenRingConn a *primary* tracker rather than an
    /// on-demand reader. The 0x10/0x87 descriptor (steps `[4:6]`, skin temp `[6:10]`,
    /// battery `[1]`) is NOT unsolicited: in the official-app captures it arrives ~every
    /// 40 s in response to a `07 00 00` (fetch) heartbeat. Without this, steps only
    /// accumulate during a manual "Measure". With it, as long as we hold the link the ring
    /// keeps reporting, so the live step delta-accumulation tracks the full day (the only
    /// gap is time we're not connected — and with no official-app contention, that's it).
    /// Skips ticks during live monitoring / sync, which generate descriptor traffic of
    /// their own (and where an extra fetch can disturb the HR warm-up window).
    func startKeepalive() {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task { [weak self] in
            // Prime a status session so the ring answers fetch with the descriptor.
            for cmd in [Command.status0, Command.status1] {
                guard let self, !Task.isCancelled else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(250))
            }
            while !Task.isCancelled {
                guard let self else { return }
                if self.ready, !self.monitoring, !self.livePreparing, self.syncTask == nil {
                    self.write(Command.fetch)   // 07 00 00 → fresh 0x10/0x87 descriptor
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// UserDefaults key for the periodic auto-measure toggle (default ON — the user opted in).
    static let autoMeasureEnabledKey = "autoMeasure.enabled"
    /// How often to auto-measure HR while connected+idle. SpO₂ runs every 3rd cycle (~3×).
    private static let autoMeasureInterval: TimeInterval = 600   // 10 min
    /// Delay before the FIRST auto-measure after connecting — short, so opening the app
    /// refreshes HR within ~a minute rather than waiting a full interval.
    private static let autoMeasureFirstDelay: TimeInterval = 45
    private static var autoMeasureEnabled: Bool {
        // Default true when unset (the user chose "periodic"); a stored false disables it.
        UserDefaults.standard.object(forKey: autoMeasureEnabledKey) as? Bool ?? true
    }

    /// Periodic auto-measure — what makes HR/SpO₂ refresh on their own, like the official app
    /// (the ring measures them ONLY on demand; the idle keepalive carries just temp/steps/
    /// battery). While connected and idle it briefly enters HR live mode, waits for a converged
    /// reading, persists it (which the app then mirrors to Health), and returns to idle; SpO₂
    /// every 3rd cycle. Skips entirely while the user is measuring or a sync is running, and
    /// respects the `autoMeasure.enabled` toggle. Battery cost is real — hence the toggle.
    func startAutoMeasure() {
        guard autoMeasureTask == nil else { return }
        autoMeasureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoMeasureFirstDelay))
            while !Task.isCancelled {
                guard let self else { return }
                if Self.autoMeasureEnabled, self.idleForAutoMeasure {
                    // Refresh BOTH every cycle — HR locks in seconds when still; SpO₂ rides
                    // the same live path. (Was SpO₂ every 3rd cycle, but relaunches reset that
                    // counter so it rarely fired.) Each is bounded, so a moving hand just times
                    // out that read rather than blocking the loop.
                    await self.autoMeasureOnce(mode: .hr, timeout: 90)   // HR can need ~60s of stillness
                    if self.idleForAutoMeasure {
                        await self.autoMeasureOnce(mode: .spo2, timeout: 45)
                    }
                    try? await Task.sleep(for: .seconds(Self.autoMeasureInterval))
                } else {
                    // Disabled, or busy with a user measure / sync — re-check soon rather than
                    // deferring a full interval (a one-off open-sync shouldn't push the first
                    // HR out by 10 min).
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    /// True only when the link is up and nothing else is using it — never interrupt a user
    /// measurement, a sync, or the live-enter drain.
    private var idleForAutoMeasure: Bool {
        ready && !monitoring && !livePreparing && syncTask == nil
    }

    /// One bounded auto-measurement: enter `mode`'s live read, wait for a converged value (or
    /// time out), then stop — which persists the reading and lets ContentView mirror it to
    /// Health. If the user takes over mid-read (monitoring an unexpected mode), we leave their
    /// session alone rather than cancelling it.
    private func autoMeasureOnce(mode: LiveMode, timeout: TimeInterval) async {
        guard idleForAutoMeasure else { return }
        autoMeasuring = true
        startMonitoring(mode: mode)             // sets monitoring=true; drains, enters, polls
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled && Date() < deadline {
            if mode == .hr, liveHR != nil { break }
            if mode == .spo2, liveSpO2 != nil { break }
            // Bail if a user tap switched the mode out from under us — don't fight them.
            if !monitoring || liveMode != mode { autoMeasuring = false; return }
            try? await Task.sleep(for: .seconds(1))
        }
        // Only tear down if WE still own the live read (user didn't take over).
        if autoMeasuring, monitoring, liveMode == mode { stopLiveMonitoring() }
        autoMeasuring = false
    }

    /// Persist decoded samples to the local store (the vitals dashboard reads from it, so
    /// data is always visible offline). The SyncCursor dedupes, so repeated calls are safe.
    private func persist(_ samples: [QuantitySample]) {
        guard let localStore, !samples.isEmpty else { return }
        storedMetricSamples += (try? localStore.ingest(samples).count) ?? 0
    }

    /// Persist the latest night's sleep summary + today's step count so the dashboard
    /// shows them OFFLINE after disconnect. Both UPSERT by day (no duplicates) and bypass
    /// the cumulative-counter `ingest` path entirely — the SyncCursor is untouched.
    private func persistSleepAndSteps() {
        guard let localStore else { return }
        if !stagedSegments.isEmpty {
            let summary = SleepStaging.summary(stagedSegments)
            // Real sleep-window clock times (segments carry the dates; Summary doesn't) — so a
            // night-temp window aligns to actual onset/wake, not midnight. `night` (start-of-day)
            // remains the upsert key.
            let start = stagedSegments.map(\.start).min() ?? Date()
            let end = stagedSegments.map(\.end).max() ?? start
            try? localStore.saveSleepSummary(summary, night: start, inBedStart: start, inBedEnd: end)
        }
        // Steps are accumulated live in didUpdateValue (addDailySteps) — nothing to do here.
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
        livePreparing = false
        // Persist the last live reading so the dashboard shows it after disconnect.
        let now = Date()
        var last: [QuantitySample] = []
        if let hr = liveHR { last.append(QuantitySample(kind: .heartRate, start: now, value: Double(hr))) }
        if let spo2 = liveSpO2 { last.append(QuantitySample(kind: .spo2, start: now, value: Double(spo2) / 100)) }
        persist(last)
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
        ringLog.notice("sync: START (cursor=all)")
        syncTask = Task { [weak self] in
            // Paced enter so CoreBluetooth doesn't drop writes.
            for cmd in [Command.status0, Command.status1, Command.syncAll, Command.fetch] {
                guard let self else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Watchdog: finalize on 0x50, or when pages stop (3 s quiet), or a 45 s cap —
            // so the sync can never hang if the end-marker or a write is lost. The common
            // case (ring sends 0x50) exits immediately; the quiet fallback only fires when
            // the end-marker is lost, and pages stream sub-second apart during a real drain,
            // so 3 s of silence reliably means "done" — a second shaved off every such sync.
            for tick in 0 ..< 45 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.syncDone || self.syncQuietTicks >= 3 {
                    ringLog.notice("sync: watchdog exit at \(tick)s (done=\(self.syncDone), quiet=\(self.syncQuietTicks), records=\(self.bulkRecords.count))")
                    break
                }
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
        persist(historySamples)   // auto-persist HR/HRV/SpO2 for the dashboard
        persistSleepAndSteps()    // sleep summary + steps for offline display
        syncing = false
        syncTask = nil
        ringLog.notice("sync: FINALIZE records=\(self.bulkRecords.count) samples=\(self.historySamples.count) sleepSegs=\(self.sleepSegments.count) steps=\(self.steps ?? -1)")
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
        guard let writeChar else {
            ringLog.warning("write DROPPED (no writeChar yet): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
            return
        }
        // Write char advertises `write` (with response).
        ringLog.debug("→ write \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
        peripheral.writeValue(Data(bytes), for: writeChar, type: .withResponse)
    }

    /// Recover a half-open link. On a restored / already-connected reconnect, the persisted
    /// notify subscription can deliver frames before THIS session has matched the notify/write
    /// characteristics — discovery from `init` fires before the central is fully ready and
    /// silently no-ops, so `ready` is stuck false and page-acks get dropped (the ring then
    /// stalls waiting for an ack). Re-running discovery once data is actually flowing relands
    /// the characteristics → `ready` flips true → keepalive/sync resume. Throttled so a burst
    /// of frames doesn't spam discovery. Safe no-op once ready. (Ground-truthed from a device
    /// log: "write DROPPED (no writeChar yet)" with no preceding `ready=`.)
    func rediscoverIfNeeded() {
        guard !ready else { return }
        if let last = lastDiscoveryKick, Date().timeIntervalSince(last) < 2 { return }
        lastDiscoveryKick = Date()
        ringLog.notice("rediscover: link up but not ready (notify=\(self.notifyChar != nil), write=\(self.writeChar != nil)) — re-running discovery")
        peripheral.discoverServices(nil)
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
            ringLog.notice("ready=\(self.ready) (notify=\(self.notifyChar != nil), write=\(self.writeChar != nil))")
            if self.ready {
                self.startKeepalive()      // continuous descriptor polling (temp/steps/battery)
                self.startAutoMeasure()    // periodic HR/SpO₂ reads so those refresh on their own
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            self.lastFrame = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            // Frames arriving while the link isn't `ready` mean discovery didn't land on this
            // (restored) reconnect — re-run it so we can ack and the buttons enable. #reconnect
            if !self.ready { self.rediscoverIfNeeded() }
            // The ring's onboard step counter (descriptor [4:6], §5.4) is a since-handoff DELTA that
            // resets (the official app sums it in local memory). So accumulate observed deltas
            // into a persistent daily total, reset-aware, rather than showing the raw counter
            // (which reset to 0). NOTE: we only count steps while THIS app is connected, so the
            // total lags the always-connected official app — but it never resets to 0.
            if let v = DeviceStatus.steps(bytes) {
                if lastRawSteps == nil {
                    // First reading this session — recover today's accumulated total from the
                    // store and use this counter as the baseline (don't retro-count unseen steps).
                    dailyStepsTotal = (try? localStore?.todaySteps()) ?? 0
                } else if let last = lastRawSteps {
                    let delta = v >= last ? v - last : v   // v < last => ring reset; v is the new count
                    if delta > 0 {
                        dailyStepsTotal += delta
                        try? localStore?.addDailySteps(delta)
                    }
                }
                lastRawSteps = v
                self.steps = dailyStepsTotal
            }
            // Skin temperature rides the same 0x10/0x87 descriptor (§5.4). It streams live
            // (~30–60 s) and is NOT in the sleep sync, so capture + persist it here.
            if let t = DeviceStatus.skinTemperature(bytes) {
                self.liveTemperature = t.celsius
                self.persist([QuantitySample(kind: .temperature, start: Date(), value: t.celsius)])
            }
            // Ring battery % is descriptor byte[1] (§5.4 🟢, ground-truthed).
            if let b = DeviceStatus.battery(bytes) { self.batteryPercent = b }
            // Bulk history pages: accumulate + ack to continue draining (47→c7, 4c→cc).
            switch bytes.first {
            case 0x47:
                self.drainSawPage = true
                if self.syncing { self.syncQuietTicks = 0 }
                ringLog.debug("← 0x47 PPG page (\(bytes.count)B), ack")
                self.write(Command.pageAck47)
                self.handlePPGPage(data)   // Layer-A epoch decode, gated (#24)
                return   // PPG page — BulkSleep decode TODO (issue #8)
            case 0x4C:
                self.drainSawPage = true
                if self.syncing || self.livePreparing {   // keep records during a sync OR a live-enter drain
                    self.bulkRecords += BulkSleep.records(fromPage: bytes)
                    self.syncQuietTicks = 0
                }
                ringLog.debug("← 0x4c sleep page (\(bytes.count)B) → records=\(self.bulkRecords.count), ack")
                self.write(Command.pageAck4C)
                self.handleActivityPage(data)   // Layer-A epoch decode, gated (#24)
                return   // always ack to keep draining
            case 0x50:
                // End-of-history cursor report (§5.5) — NO XOR trailer, so it never
                // reaches Frame.parse. Mark done; the sync watchdog / live-enter drain finalizes.
                self.drainDone = true
                if self.syncing { self.syncDone = true }
                ringLog.notice("← 0x50 END-OF-HISTORY (records=\(self.bulkRecords.count))")
                self.handleEndOfHistory(data)   // finalize epoch session, gated persist (#24)
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
                    ringLog.notice("live HR LOCKED: \(hr) bpm")
                } else if let raw = LiveHR.decode(bytes) {                       // short frame, still warming up
                    self.liveHRWarmup = raw
                    ringLog.notice("live HR warmup: byte2=\(raw) (frame \(self.lastFrame ?? "", privacy: .public))")
                } else if bytes.first == 0x15 {
                    ringLog.notice("live 0x15 frame (no HR): \(self.lastFrame ?? "", privacy: .public)")
                }
                if let spo2 = LiveHR.decodeSpO2(bytes) {                         // long frame, 🟡
                    self.liveSpO2 = spo2
                    ringLog.notice("live SpO2: \(spo2)%")
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            ringLog.error("write FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleActivityPage(_ data: Data) {
        decodedEpochRecords += syncSession.appendActivityPage(data).count
    }

    private func handlePPGPage(_ data: Data) {
        decodedEpochRecords += syncSession.appendPPGPage(data).count
    }

    private func handleEndOfHistory(_ data: Data) {
        guard syncSession.complete(with: data) != nil,
              epochDecodingEnabled else { return }
        let samples = syncSession.placeholderQuantitySamples()
        guard !samples.isEmpty else { return }
        do {
            storedMetricSamples += try localStore?.ingest(samples).count ?? 0
        } catch {
            // Persistence failures should not interrupt the BLE drain/ACK loop.
        }
    }
}
