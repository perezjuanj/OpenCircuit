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

    /// Cached nightly sleep window — skin-temp capture is gated to this span (see the
    /// descriptor handler). Daytime readings are too noisy/unpredictable (activity,
    /// ambient swings, intermittent skin contact) to trend, so we only persist overnight.
    private var nightWindow: DateInterval?
    private var nightWindowRefreshedAt: Date?

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
    private var bulkFinalized = false    // captured pages already committed (sleep/vitals) — stop-time safety net skips re-commit
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

    /// Begin live monitoring. The proven enter sequence (PROTOCOL.md §5.1 / livehr.py) is
    /// unchanged: open the sync session (cursor 0xFFFFFFFF), let the ring's history backlog
    /// drain, THEN `d0` → mode (`06 01`/`06 02`) → fetch, then poll `95 00 00`. Idempotent.
    ///
    /// - `quickLiveRead`: the goal is a prompt live HR/SpO₂ (a user tap or the daytime auto/
    ///   background refresh), not the overnight sleep dump. The drain still runs and pages are
    ///   still captured, but we don't wait out a long backlog before entering live mode — the
    ///   old 15 s worst-case wait starved the HR poll of its budget so it never locked in the
    ///   background (#45). On a quiet ring the drain already exits on a beat of quiet, so this
    ///   mostly just caps the pathological never-quiet case. The full (quiet-bounded) drain —
    ///   used by the overnight background capture — still runs when this is false so sleep isn't
    ///   lost.
    /// - `clearStaleValue`: drop the last `liveHR` up front so an old reading can't masquerade
    ///   as live while a fresh user measurement warms up (#45 C). Off for auto/background so a
    ///   prior value stays on screen until the new one locks.
    func startLiveMonitoring(quickLiveRead: Bool = false, clearStaleValue: Bool = false) {
        guard monitorTask == nil else { return }
        // Live and history sync can't coexist (ring is one mode at a time). Cancel any
        // in-flight sync so the ring is free to enter live mode.
        syncTask?.cancel(); syncTask = nil
        syncing = false
        monitoring = true
        livePreparing = true
        if clearStaleValue { liveHR = nil }   // fresh user read — don't let a stale value look live (#45 C)
        liveHRTrend.removeAll()   // fresh convergence window
        liveHRWarmup = nil
        bulkRecords.removeAll()   // any pages we drain below land here (don't lose them)
        bulkFinalized = false
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
            // 2. Drain the history backlog before live mode. Pages are acked in
            //    didUpdateValue; exit on the 0x50 end marker or a beat of quiet. A normal
            //    overnight dump streams sub-second apart and then stops, so the quiet exit
            //    fires right after the last page — the cap is only a backstop for a ring that
            //    never goes quiet. For a quick live read that backstop is short (don't let a
            //    pathological backlog eat the HR poll's budget, #45); the full-drain path keeps
            //    the longer cap so a big overnight backlog is fully captured.
            guard let s0 = self, !Task.isCancelled else { return }
            s0.write(Command.fetch)
            // Drain backstop in 500 ms ticks. A quick read starts with a short ~3 s cap so a
            // silent ring can't starve the HR poll (#45); the overnight path uses the full ~15 s.
            // The shared quiet-exit (3 quiet ticks ≈ 1.5 s after the last page) ends a real drain.
            // BUT a quick read must NOT cut off an in-flight backlog: entering live mode while
            // 0x4c pages are still streaming (!drainDone, no quiet beat yet) leaves HR stuck at
            // the warm-up sentinel (8). So if the short cap is reached mid-stream, promote it to
            // the full cap and let the quiet-exit finish the drain — the short cap then only bites
            // a genuinely silent ring (the common no-backlog case still exits at ~1.5 s, unchanged).
            var cap = quickLiveRead ? 6 : 30   // ×500 ms ⇒ ~3 s quick / ~15 s full backstop
            var quiet = 0
            var tick = 0
            while tick < cap {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if self.drainDone { break }
                if self.drainSawPage { self.drainSawPage = false; quiet = 0 }
                else { quiet += 1; if quiet >= 3 { break } }
                tick += 1
                if tick >= cap, quiet == 0, cap < 30 { cap = 30 }   // quick read still streaming a backlog → drain it fully (#45)
            }
            // Surface anything drained so overnight sleep/vitals aren't lost — the ring
            // discards delivered pages, so this is the only chance to keep them.
            if let self, !self.bulkRecords.isEmpty {
                self.historySamples = BulkSleep.samples(from: self.bulkRecords)
                self.sleepSegments = BulkSleep.sleepSegments(from: self.bulkRecords)
                self.stagedSegments = BulkSleep.stagedSegments(from: self.bulkRecords)
                self.persist(self.historySamples)   // auto-persist HR/HRV/SpO2 for the dashboard
                self.persistSleepAndSteps()          // sleep summary + steps for offline display
                self.bulkFinalized = true            // committed — the stop-time safety net can skip it
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
    ///
    /// The cadence is ADAPTIVE (#31): a fixed 30 s poll around the clock measurably drained
    /// both batteries for a step counter that barely moves. Steps/battery drift slowly, and
    /// skin temp only matters overnight (already window-gated), so we poll slowly by day and
    /// tighten only inside the nightly window — `KeepaliveCadence` owns the policy.
    func startKeepalive() {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task { [weak self] in
            // Resolve the night window up front so the first temp frame is gated correctly
            // (otherwise the very first reading races the reactive refresh and could leak).
            await self?.refreshNightWindowIfNeeded()
            // Prime a status session so the ring answers fetch with the descriptor.
            for cmd in [Command.status0, Command.status1] {
                guard let self, !Task.isCancelled else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(250))
            }
            while !Task.isCancelled {
                guard let self else { return }
                // Re-resolve the night window (self-throttled to ≤ every 30 min) so the cadence
                // tightens/relaxes as the window rolls over, not just at connect.
                await self.refreshNightWindowIfNeeded()
                if self.ready, !self.monitoring, !self.livePreparing, self.syncTask == nil {
                    self.write(Command.fetch)   // 07 00 00 → fresh 0x10/0x87 descriptor
                }
                try? await Task.sleep(for: .seconds(self.keepaliveInterval))
            }
        }
    }

    /// UserDefaults key for the battery-saver toggle — stretches the idle keepalive cadence (#31).
    /// Default OFF (max fidelity); a stored `true` opts into the slower daytime/night cadences.
    static let batterySaverEnabledKey = "keepalive.batterySaver"

    /// Adaptive idle-keepalive interval (seconds): slow by day, tighter inside the nightly temp
    /// window or while a live read holds the link, stretched further in battery saver (#31).
    /// Policy lives in the pure, unit-tested `KeepaliveCadence`.
    private var keepaliveInterval: TimeInterval {
        KeepaliveCadence.interval(
            isNight: nightWindow?.contains(Date()) ?? false,
            activeMeasurement: monitoring || livePreparing,
            batterySaver: UserDefaults.standard.bool(forKey: Self.batterySaverEnabledKey)
        )
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
        startMonitoring(mode: mode, userInitiated: false)   // auto refresh: prompt enter, keep last value until it locks
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

    /// Resolve and cache the nightly sleep window used to gate skin-temp capture. Re-resolves
    /// at most every 30 min (the window only shifts day-to-day) unless `force` is set — the
    /// capture site forces a re-resolve on a window miss so it can re-check before dropping a
    /// sample (a stale/expired window at night-start or after midnight would otherwise silently
    /// drop up to 30 min of onset data). Prefers the real schedule via `SleepSchedule.current`
    /// (HealthKit, else manual).
    func refreshNightWindowIfNeeded(force: Bool = false) async {
        let stale = nightWindowRefreshedAt.map { Date().timeIntervalSince($0) > 30 * 60 } ?? true
        guard stale || force else { return }
        if let w = await SleepSchedule.current(forNightEndingNear: Date()) {
            nightWindow = w
        } else if let interval = SleepWindow.interval(
            // No real schedule (default state: manual schedule disabled AND no HealthKit
            // entitlement). Fall back to the registered DEFAULT bed/wake times even though the
            // manual schedule is disabled — this yields a correct CROSS-MIDNIGHT window (e.g.
            // last night 22:30 → today 06:30). A naive 00:00–06:00 calendar-day slice would
            // drop all pre-midnight sleep onset (a 23:00→07:00 sleeper never matches), killing
            // the feature for every default-config user.
            bedMinutes: SleepScheduleDefaults.defaultBedMinutes,    // 1350 (22:30)
            wakeMinutes: SleepScheduleDefaults.defaultWakeMinutes,  // 390 (06:30)
            nightEndingNear: Date()
        ) {
            nightWindow = interval
        } else {
            // Pure fallback — should never happen with valid (non-degenerate) defaults.
            let dayStart = Calendar.current.startOfDay(for: Date())
            nightWindow = DateInterval(start: dayStart, end: dayStart.addingTimeInterval(6 * 3600))
        }
        nightWindowRefreshedAt = Date()
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
    ///
    /// - `userInitiated`: a real Measure tap. When already live in the SAME mode it re-arms a
    ///   fresh poll (#45 B) — without this, tapping Measure on a stalled stream was a silent
    ///   no-op. The periodic auto-measure passes `false` so it never disturbs a converging read.
    /// - `quickLiveRead`: prompt live-read entry (the default for foreground/auto). The overnight
    ///   background capture passes `false` for the full sleep drain (see `startLiveMonitoring`).
    func startMonitoring(mode: LiveMode, userInitiated: Bool = true, quickLiveRead: Bool = true) {
        if monitoring {
            if liveMode == mode {
                if userInitiated { rearmUserMeasure() }   // re-poll on demand; auto leaves it alone
            } else {
                setLiveMode(mode)
            }
        } else {
            liveMode = mode
            startLiveMonitoring(quickLiveRead: quickLiveRead, clearStaleValue: userInitiated)
        }
    }

    /// Re-arm an already-running live read for a fresh user measurement (#45 B/C): drop the
    /// stale value + convergence window, then re-issue the proven `d0` → mode → fetch enter so
    /// the ring restarts the measurement. The existing poll loop keeps sending `95 00 00`, so no
    /// second loop is spawned. This intentionally kicks HR back to warm-up — exactly what a user
    /// asking for a new reading wants.
    private func rearmUserMeasure() {
        liveHR = nil
        liveHRTrend.removeAll()
        liveHRWarmup = nil
        let modeCmd = liveMode == .hr ? Command.liveHRMode : Command.liveSpO2Mode
        Task { [weak self] in
            guard let self else { return }
            self.write(Command.statusQuery)
            try? await Task.sleep(for: .milliseconds(250))
            self.write(modeCmd)
            try? await Task.sleep(for: .milliseconds(250))
            self.write(Command.fetch)
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
        // Safety net for a background teardown that interrupted the live-enter drain before its
        // post-drain commit ran (#22 bg race): persist the captured pages so an overnight read
        // that never reached its finalize doesn't silently drop last night's sleep/vitals.
        // No-op once the drain already committed (bulkFinalized) or nothing was captured.
        if !bulkRecords.isEmpty, !bulkFinalized {
            historySamples = BulkSleep.samples(from: bulkRecords)
            sleepSegments = BulkSleep.sleepSegments(from: bulkRecords)
            stagedSegments = BulkSleep.stagedSegments(from: bulkRecords)
            persist(historySamples)
            persistSleepAndSteps()
            bulkFinalized = true
        }
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
        bulkFinalized = false                    // fresh capture — uncommitted until finalizeSync
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
        bulkFinalized = true      // committed — the stop-time safety net can skip these records
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
            // (~30–60 s) and is NOT in the sleep sync, so capture + persist it here — but ONLY
            // during the nightly sleep window. Daytime readings are too noisy/unpredictable
            // (activity, ambient swings, intermittent skin contact) to be a usable trend, so we
            // drop them and surface no live value outside the window.
            if let t = DeviceStatus.skinTemperature(bytes) {
                // Window-miss guard: if we're outside the cached window (or it's nil), the cache
                // may simply be stale/expired (night just started, or midnight rolled the window
                // forward). Force a synchronous re-resolve BEFORE deciding to drop — this whole
                // block already runs inside the `Task { @MainActor in … }` above, so the await is
                // safe. Otherwise (we're inside the window) refresh in the background without
                // blocking the frame. Without the force path, up to 30 min of onset samples are
                // silently dropped against a stale window.
                if self.nightWindow?.contains(Date()) != true {
                    await self.refreshNightWindowIfNeeded(force: true)
                } else {
                    Task { await self.refreshNightWindowIfNeeded() }   // background, don't block the frame
                }
                let inNightWindow = self.nightWindow?.contains(Date()) ?? false
                self.liveTemperature = inNightWindow ? t.celsius : nil
                if inNightWindow {
                    self.persist([QuantitySample(kind: .temperature, start: Date(), value: t.celsius)])
                }
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
