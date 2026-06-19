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
    /// Wall-clock when `liveHR` / `liveSpO2` were last actually LOCKED (a fresh decoded reading) —
    /// NOT when the last frame arrived. The idle keepalive bumps `lastFrameAt` to ≈now on every
    /// descriptor frame, so stamping a persisted reading with `lastFrameAt` re-dated a lingering
    /// (stale) HR/SpO₂ to ~now. Stamp with the true capture time instead (see `stopLiveMonitoring`).
    private var liveHRAt: Date?
    private var liveSpO2At: Date?
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
    /// Wall-clock time of the most recent frame actually received from the ring (#36). Lets the
    /// UI detect a silently-dropped link (values stop updating before CoreBluetooth fires
    /// `didDisconnect`) and stamps the persisted last live reading with when it was REALLY
    /// measured — not `Date()`, which would push a minutes-old reading into HealthKit "now".
    private(set) var lastFrameAt: Date?
    private(set) var monitoring = false
    /// When the current live-monitoring cycle began (set in `startLiveMonitoring`). Lets the
    /// stop-time persist keep ONLY readings actually measured during this cycle, so a value
    /// lingering from an earlier cycle isn't re-persisted (and re-dated) at stop.
    private var monitoringStartedAt: Date?
    /// True during the open→drain phase before the live stream starts. The ring won't
    /// emit live frames until its history backlog is fully drained, so we surface this
    /// so the UI shows "preparing" instead of a dead reading.
    private(set) var livePreparing = false
    private(set) var lastFrame: String?
    private(set) var decodedEpochRecords = 0
    private(set) var storedMetricSamples = 0
    private(set) var ready = false
    /// True once the notify subscription is CONFIRMED (`didUpdateNotificationStateFor` success) —
    /// distinct from `ready`, which only means the notify/write characteristics were DISCOVERED.
    /// An unsubscribed notify char silently drops every inbound frame.
    private(set) var notifySubscribed = false
    /// True when the link is up + subscribed but the ring delivers only `0x81` status replies and
    /// NO data frames (`0x10`/`0x82`/`0x15`/`0x47`/`0x4c`/`0x11`) — the signature of a ring that
    /// hasn't been activated/bonded by the official app (it accepts writes but answers nothing, so
    /// Measure/Sync would just time out). Cleared the instant a data frame arrives. We INFER this
    /// (don't claim to KNOW it's unactivated), per the `reconnectStalled` precedent.
    private(set) var notStreaming = false
    /// Whether any non-`0x81` (data/activity) frame has arrived since connect. Drives `notStreaming`
    /// — the cold status reads always elicit `0x81`, so "frames arrived" alone can't tell us the
    /// data path is alive; a DATA frame can.
    private var gotDataFrame = false
    /// Wall-clock of the last `0x11` heartbeat (optional liveness signal).
    private(set) var lastHeartbeatAt: Date?
    /// True while the periodic auto-measure (not a user tap) is driving a live read, so the
    /// UI can show a subtle "auto-updating" cue instead of reading as a user measurement.
    private(set) var autoMeasuring = false

    // MARK: Wear gate / not-worn proxy (#56, #41)
    //
    // `appearsNotWorn` is true when the ring reads as OFF-WRIST / ON THE CHARGER, inferred from
    // PROVEN proxies only — periodic auto-measures that never lock (🟢) plus, when available, a
    // cold raw skin-temp reading (🟡, AutoMeasureGate). NO charging-flag byte is consulted (that
    // descriptor field is undecoded — #61). It gates only the AUTOMATIC HR/SpO₂ refresh (which on
    // the charger just times out and drains battery, #56) and a small UI hint; manual Measure /
    // Sync are never blocked by it. Reset per connection (a new RingSession each connect).
    private(set) var appearsNotWorn = false
    /// Consecutive periodic auto-measure cycles that never locked a reading — the 🟢 not-worn
    /// signal. Reset to 0 on a lock (or cleared by a warm skin-temp reading).
    private var consecutiveAutoMeasureNoLock = 0
    /// Most recent RAW skin temp (°C) from the 0x10/0x87 descriptor, updated on EVERY temp frame
    /// regardless of the night-window / worn persistence gates below — the 🟡 wear proxy. nil
    /// until the first valid reading.
    private var lastRawSkinTempC: Double?
    /// In-memory log of the night's RAW skin-temp readings (worn AND cold), independent of the
    /// worn-only persistence gate — the ONLY source of the cold readings the sleep wear-gate
    /// (#41) needs to reclassify a charging block out of sleep (the store keeps worn temps only).
    /// Bounded rolling buffer; consumed by `wearTemperatureSamples()`.
    private var nightTemperatureLog: [TemperatureSample] = []
    private static let nightTemperatureLogCap = 2000
    /// Cap on the not-worn auto-measure backoff: a ring left on the charger is re-probed at most
    /// this rarely, but never abandoned — a lock (or warm temp) resumes the base cadence (#56).
    private static let autoMeasureMaxBackoff: TimeInterval = 2 * 3600
    /// Cheap re-check cadence while SKIPPING the probe on a confirmed-cold (not-worn) ring: short,
    /// since it costs no live-enter, so re-wear (temp warming) resumes measurement promptly (#56).
    private static let autoMeasureColdRecheck: TimeInterval = 180

    // MARK: User measure UX (#55)

    /// True while the user has manually tapped "Measure" for a live HR or SpO₂ reading
    /// (as opposed to the periodic `autoMeasuring`). Lets the poll loop enforce a per-mode
    /// timeout and the UI distinguish Preparing → Measuring → failure states.
    private(set) var userMeasuring = false
    /// Set when a user-initiated measure times out without locking a reading. Cleared the
    /// next time the user taps Measure so a retry dismisses the error naturally. Not cleared
    /// on stop or disconnect — the banner persists until the user acts on it.
    private(set) var userMeasureFailed = false
    /// Actionable guidance copy surfaced when `userMeasureFailed` is true.
    private(set) var userMeasureFailedMessage: String? = nil
    /// Absolute deadline for the in-flight user measure's poll loop, or nil on the auto path
    /// (which is bounded by `autoMeasureOnce`). Held on the session — NOT as a Task-local — so a
    /// re-tap (`rearmUserMeasure`) can EXTEND it; otherwise a late re-arm inherits the original
    /// budget and times out almost immediately (#65). Per-mode budget via `userMeasureBudget`.
    private var userMeasureDeadline: Date?

    // MARK: Battery freshness (#57)
    //
    // Battery % is updated ONLY on 0x10/0x87 descriptor frames (DeviceStatus.battery), which
    // are solicited by the keepalive every 60–300 s. Using the global `lastFrameAt` (refreshed
    // on every frame, including 2-s live-HR polls) would let the battery show as "live" for up
    // to 6 minutes (idleStaleAfter) even though the reading is tens of minutes old during a long
    // monitoring session. A dedicated per-read timestamp + a tighter 120 s window catches a
    // silently stale reading after roughly 2 night-keepalive intervals.

    /// Wall-clock of the most recent 0x10/0x87 frame that carried a valid battery % (#57).
    /// Separate from `lastFrameAt` (updated on every frame) — battery freshness is independent
    /// of live-HR polling.
    private(set) var batteryFetchedAt: Date?

    /// True when the last battery reading is old enough to display as stale — i.e. no
    /// 0x10/0x87 descriptor arrived recently (#57). Tighter than `liveReadingsStale`
    /// (idleStaleAfter 360 s), which covers all readings. Shows "as of Xm ago" in the
    /// connection-header battery after `batteryStaleAfter` seconds of silence.
    var batteryStale: Bool {
        guard batteryPercent != nil else { return false }   // nothing to call stale yet
        guard let at = batteryFetchedAt else { return false }
        return Date().timeIntervalSince(at) > Self.batteryStaleAfter
    }
    /// ~2× the tightest keepalive interval (night: 60 s). Battery shows "as of Nm ago" when
    /// no descriptor has arrived in this window. Daytime keepalive (180–300 s) means the battery
    /// will accurately report as stale between keepalive firings — that IS correct, the reading
    /// IS a few minutes old.
    private static let batteryStaleAfter: TimeInterval = 120

    // MARK: Charging inference (#60)
    //
    // The ring's charging byte is NOT on the wire in any confirmed field (PROTOCOL.md §5).
    // A strictly rising battery % across consecutive 0x10/0x87 frames is the best 🟢 proxy.
    // This window is private; `inferredCharging` is computed from it via the kit's pure function.
    // The inference is persisted before session teardown (see `invalidate`) so the connection
    // card can surface a hint during the reconnect backoff when session == nil.

    /// Rolling battery % readings (oldest→newest, capped) for charging inference (#60).
    private var batteryTrend: [Int] = []
    private static let batteryTrendCapacity = 4

    /// True when the last few battery readings are strictly rising — suggesting the ring may
    /// be charging (🟢 proxy). The UI labels this "inferred" to avoid asserting certainty.
    /// Never derived from the reconnect count (#60).
    var inferredCharging: Bool { ChargingInference.inferred(from: batteryTrend) }

    /// UserDefaults key for the last-persisted charging inference (#60). Written before session
    /// teardown so ContentView can read it during the reconnect-backoff window (session == nil).
    private static let inferredChargingKey = "battery.inferredCharging"

    /// True when frames have stopped for long enough that the live readings (HR/SpO₂/battery/
    /// steps/temp) should read as STALE rather than current (#36). A silently-dropped link keeps
    /// its last values until CoreBluetooth eventually fires `didDisconnect`; this lets the UI
    /// show "Xm ago" instead of a minutes-old value masquerading as live. Thresholds are mode-
    /// aware: while monitoring, frames stream ~every 2 s, so a 30 s gap means the stream stalled;
    /// while idle the only frames are the slow keepalive descriptor (up to ~5 min apart in
    /// battery saver), so allow a much longer gap before crying stale.
    var liveReadingsStale: Bool {
        guard let at = lastFrameAt else { return false }   // no frame yet — nothing to call stale
        let gap = Date().timeIntervalSince(at)
        return gap > (monitoring ? Self.liveStaleAfter : Self.idleStaleAfter)
    }
    private static let liveStaleAfter: TimeInterval = 30
    private static let idleStaleAfter: TimeInterval = 360

    private var monitorTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var autoMeasureTask: Task<Void, Never>?
    /// Fires once after the notify subscription is confirmed: if no DATA frame has arrived within
    /// `firstFrameTimeout`, flips `notStreaming` (ring not activated/bonded). #54.
    private var streamWatchdogTask: Task<Void, Never>?
    /// Seconds after a confirmed subscription to wait for the ring's first DATA frame. The keepalive
    /// starts writing status/fetch immediately on `ready`, so an activated ring answers well within
    /// this; only an un-activated ring stays silent past it.
    private static let firstFrameTimeout: TimeInterval = 10

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
    private var dailyStepsTotal = 0      // cached display total for the last sample day (mirrors StoredDaily)
    private var syncTask: Task<Void, Never>?
    private var syncDone = false        // 0x50 end-of-history seen
    private var syncQuietTicks = 0      // seconds since the last page arrived
    private var drainSawPage = false    // a 0x47/0x4c page arrived since last check (live-enter drain)
    private var drainDone = false       // 0x50 end-of-history seen during live-enter drain

    // MARK: #99 — all-day HR/SpO₂ stream probe (DataSyncType byte[6] selector sweep)
    //
    // A deliberate, user-triggered diagnostic: re-run the `0x02` sync-open flag sweep the RIGHT way
    // (real ≈now cursor + post-auth — the two reasons the old PROTOCOL.md §5.3 sweep was
    // inconclusive) across the full candidate set, capturing every RAW response per selector. It
    // does NOT decode HR/SpO₂ records (that needs ground truth) — it gathers the capture that
    // unblocks the ticket. Cancels/pauses live+sync+keepalive while it runs so each response is
    // unambiguously attributable to one selector.

    /// True while a selector sweep is in flight (pauses keepalive/auto-measure/sync).
    private(set) var probing = false
    /// Human-readable summary of the last completed sweep (shown in the debug card + unified log).
    private(set) var probeReport: String?
    /// Per-selector evidence from the last (or in-progress) sweep.
    private(set) var probeResults: [SelectorProbeResult] = []
    private var probeTask: Task<Void, Never>?
    /// The selector currently being probed; non-nil only between `beginSelector`/`endSelector`, so
    /// the frame handler folds raw responses into the right bucket.
    private var probeCurrent: SelectorProbeResult?

    private let peripheral: CBPeripheral
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    /// Throttle for the half-open-link recovery (`rediscoverIfNeeded`).
    private var lastDiscoveryKick: Date?
    private var localStore: LocalStore?
    private var syncSession = EpochSyncSession()
    private let epochDecodingEnabled = false
    /// Rolling archive of recent raw epochs (incl. the motion channel staging needs) + the last-drain
    /// timestamp, persisted across sessions. Lets `finalizeSync` re-stage the night from the UNION of
    /// all drained slices (stitching) and lets the periodic-drain cadence survive reconnects.
    /// Namespaced by the ring's identifier (#multi-ring) so two rings' epoch archives can't collide on
    /// the UInt32 epoch counter (which would corrupt overnight stitching).
    private let epochArchiveStore: EpochArchiveStore

    private let dataServiceUUID = CBUUID(string: OpenRingKit.Transport.dataServiceUUID)
    private let notifyUUID = CBUUID(string: OpenRingKit.Transport.notifyCharUUID)
    private let writeUUID = CBUUID(string: OpenRingKit.Transport.writeCharUUID)
    /// Device-Information System ID (0x2a23) — carries the ring's 6-byte MAC (§1). iOS hides the MAC
    /// from CoreBluetooth, but the per-connection auth (#54) needs it, so we read it from here.
    private let systemIDUUID = CBUUID(string: "2A23")
    /// DIS Firmware Revision String (0x2A26) — human-readable FW version (e.g. "FR02.018"). (#79)
    private let firmwareRevUUID = CBUUID(string: "2A26")
    /// DIS Manufacturer Name String (0x2A29). (#79)
    private let manufacturerUUID = CBUUID(string: "2A29")
    /// DIS Hardware Revision String (0x2A27). (#79)
    private let hardwareRevUUID = CBUUID(string: "2A27")
    /// The ring's 6-byte BLE MAC, recovered from the System ID characteristic. Drives the auth
    /// challenge-response (`RingAuth`); nil until read (then we fall back to the legacy fixed auth).
    private var ringMAC: [UInt8]?
    /// DIS fields collected from the ring (firmware version, generation, manufacturer, etc.) (#79).
    /// Populated incrementally as each DIS characteristic is read; `DeviceInfoView` observes this.
    private(set) var firmwareInfo = FirmwareInfo()
    /// Rolling battery % samples for the TTE estimate (#86). Capped at 20 entries (oldest→newest).
    private var batteryHistory: [BatteryTTE.Sample] = []
    private static let batteryHistoryCap = 20
    /// Read accessor for the TTE sample window (#86).
    var batteryTTESamples: [BatteryTTE.Sample] { batteryHistory }

    init(peripheral: CBPeripheral, localStore: LocalStore? = nil) {
        self.peripheral = peripheral
        self.localStore = localStore
        // Scope the per-ring epoch archive to this ring's identifier (#multi-ring).
        self.epochArchiveStore = EpochArchiveStore(namespace: peripheral.identifier.uuidString)
        super.init()
        peripheral.delegate = self
        // Seed the model name from the peripheral's advertised name; may be overridden later
        // by a dedicated DIS Model Number characteristic if the ring exposes one. (#79)
        firmwareInfo.modelName = peripheral.name ?? ""
        // Re-discovery guard (#42): on a restored / already-connected peripheral the services are
        // usually already cached, so re-scanning them on every relaunch is wasted work. When they're
        // cached, go straight to (re-)matching characteristics — that still re-fires
        // `didDiscoverCharacteristicsFor`, so `ready` lands. Only fall back to a full
        // `discoverServices` when we've never seen the data service.
        //
        // Crucially, re-match EVERY cached service, not just the data service: the DIS System ID
        // characteristic (→ MAC → SM3 auth) lives on a DIFFERENT service. Discovering only the data
        // service skipped it, so a reconnect (cached services, e.g. switching back to a ring) never
        // re-read the MAC and fell back to the legacy fixed auth — which only authenticates a ring
        // whose challenge is 0xb0, hence the flaky "not streaming" on switch-back (#multi-ring).
        if let services = peripheral.services, services.contains(where: { $0.uuid == dataServiceUUID }) {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        } else {
            peripheral.discoverServices(nil)
        }
    }

    /// Hard teardown (#42): cancel EVERY task this session owns so a session that's being
    /// replaced (a second `didConnect`/`willRestoreState`) or torn down on disconnect can't keep
    /// writing to the SHARED peripheral behind a newer session — which would race the delegate
    /// routing and leak the keepalive/auto-measure/sync loops. Callers persist the last live
    /// reading via `stopLiveMonitoring()` BEFORE this where that matters; `invalidate()` itself is
    /// a pure cancel + detach. Idempotent.
    func invalidate() {
        // Persist the charging inference BEFORE cancelling tasks (#60): the session is about
        // to be nil-ed by the scanner; ContentView reads from UserDefaults during the
        // reconnect-backoff window so the hint stays live while reconnecting.
        UserDefaults.standard.set(inferredCharging, forKey: Self.inferredChargingKey)
        monitorTask?.cancel(); monitorTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        autoMeasureTask?.cancel(); autoMeasureTask = nil
        streamWatchdogTask?.cancel(); streamWatchdogTask = nil
        syncTask?.cancel(); syncTask = nil
        probeTask?.cancel(); probeTask = nil   // #99 sweep — don't keep writing selectors after teardown
        monitoring = false
        livePreparing = false
        syncing = false
        probing = false
        autoMeasuring = false
        userMeasuring = false
        userMeasureDeadline = nil
        // Stop CoreBluetooth callbacks routing to a torn-down session. Only clear the delegate if
        // it's still us — a newer session for the same peripheral reassigns it in its own `init`,
        // and we must not clobber that.
        if peripheral.delegate === self { peripheral.delegate = nil }
    }

    /// Begin live monitoring. The proven enter sequence (PROTOCOL.md §5.1 / livehr.py) is
    /// unchanged: open the sync session (cursor 0xFFFFFFFF for a quick read, cursor≈now for the
    /// overnight capture — see `syncOpen` below), let the ring's history backlog drain, THEN `d0`
    /// → mode (`06 01`/`06 02`) → fetch, then poll `95 00 00`. Idempotent.
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
        guard monitorTask == nil, !probing else { return }   // a #99 sweep owns the link; don't fight it
        // Live and history sync can't coexist (ring is one mode at a time). Cancel any
        // in-flight sync so the ring is free to enter live mode.
        syncTask?.cancel(); syncTask = nil
        syncing = false
        monitoring = true
        monitoringStartedAt = Date()
        livePreparing = true
        if clearStaleValue { liveHR = nil; liveHRAt = nil }   // fresh user read — don't let a stale value look live (#45 C)
        liveHRTrend.removeAll()   // fresh convergence window
        liveHRWarmup = nil
        bulkRecords.removeAll()   // any pages we drain below land here (don't lose them)
        bulkFinalized = false
        drainSawPage = false
        drainDone = false
        let modeCmd = liveMode == .hr ? Command.liveHRMode : Command.liveSpO2Mode
        // Quick live read skips the backlog (`syncAll` → empty → lock HR fast); the overnight
        // background capture (quickLiveRead == false) opens at NOW so the night's backlog drains
        // (§3). Computed on the MainActor before the Task.
        let syncOpen = quickLiveRead ? Command.syncAll : Command.syncUpToNow()
        monitorTask = Task { [weak self] in
            // 1. Init + open the sync session at `syncOpen`.
            // `status0` elicits the `81 00` auth challenge; the didUpdateValue handler answers it
            // reactively with the SM3 auth (#54) before `syncOpen` opens the data session.
            for cmd in [Command.status0, syncOpen] {
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
                self.commitDrainedRecords()   // archive merge + stitched re-stage + persist (shared path)
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
            // User-measure deadline: a hand-started read gets a per-mode budget (HR 90 s,
            // SpO₂ 45 s). On expiry without a lock, surface `userMeasureFailed` so the UI
            // shows actionable guidance rather than spinning forever. The auto-measure path
            // is already bounded by `autoMeasureOnce`'s own outer deadline — the poll loop
            // there can be unbounded (the task is cancelled externally when it fires). (#55)
            // Arm the user-measure budget HERE (after the drain) so the per-mode timeout is
            // measured from when polling actually starts. Held on the session so a re-tap can
            // extend it (#65); the auto path leaves it nil (bounded by `autoMeasureOnce`). (#55)
            self?.armUserMeasureDeadline()
            try? await Task.sleep(for: .seconds(2))   // let the ring settle before first poll
            while !Task.isCancelled {
                guard let self else { return }
                self.write(Command.poll)
                // User-measure budget (auto path: userMeasureDeadline is nil). Re-read each
                // iteration so a re-arm (rearmUserMeasure) extends it (#65).
                if let deadline = self.userMeasureDeadline, Date() >= deadline {
                    let locked = self.liveMode == .hr ? self.liveHR != nil : self.liveSpO2 != nil
                    if !locked {
                        // Timed out with NO lock — surface actionable guidance for the banner.
                        self.userMeasureFailed = true
                        self.userMeasureFailedMessage = "Couldn't get a reading — make sure the ring is worn snugly and not on the charger, then hold still."
                        let modeStr = self.liveMode == .hr ? "hr" : "spo2"
                        ringLog.notice("user measure: timeout, no lock (mode=\(modeStr, privacy: .public)) → userMeasureFailed (#55)")
                    }
                    // Full teardown on ANY deadline exit — locked OR not (#65). Previously this
                    // was conditional on `userMeasureFailed`, so a SUCCESSFUL measure that ran past
                    // its budget broke the loop while leaving monitoring/userMeasuring set and a
                    // COMPLETED monitorTask non-nil — freezing live HR, permanently blocking
                    // auto-measure (`idleForAutoMeasure` needs !monitoring) and a fresh
                    // startLiveMonitoring (`guard monitorTask == nil`), and never firing
                    // `.onChange(monitoring)`→flushHealth. stopLiveMonitoring() clears all of it
                    // and persists the last reading.
                    self.stopLiveMonitoring()
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func setLocalStore(_ localStore: LocalStore) {
        self.localStore = localStore
    }

    /// After the notify subscription is confirmed, wait `firstFrameTimeout` for the ring's first
    /// DATA frame. If none arrives (only the cold `0x81` status replies), the ring is almost
    /// certainly not activated/bonded — surface `notStreaming` so the UI can say "open the official
    /// app once to activate" instead of letting Measure/Sync silently time out (#54).
    private func startStreamWatchdog() {
        streamWatchdogTask?.cancel()
        streamWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstFrameTimeout))
            guard let self, !Task.isCancelled else { return }
            if self.notifySubscribed, !self.gotDataFrame {
                self.notStreaming = true
                ringLog.notice("activation: subscribed but no data frame in \(Self.firstFrameTimeout, privacy: .public)s — ring likely not activated/bonded (#54)")
            }
        }
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
            for cmd in [Command.status0] {   // elicits the 81 00 challenge → reactive SM3 auth (#54)
                guard let self, !Task.isCancelled else { return }
                self.write(cmd)
                try? await Task.sleep(for: .milliseconds(250))
            }
            while !Task.isCancelled {
                guard let self else { return }
                // Re-resolve the night window (self-throttled to ≤ every 30 min) so the cadence
                // tightens/relaxes as the window rolls over, not just at connect.
                await self.refreshNightWindowIfNeeded()
                if self.ready, !self.monitoring, !self.livePreparing, self.syncTask == nil, !self.probing {
                    // Periodic history drain (the buffer-overflow fix). The ring's ~4.75 h history
                    // buffer drops its oldest epochs when full, so draining only on foreground/manual
                    // events lets a quietly-held overnight link overflow and lose the early, deep-rich
                    // hours. Drain on a cadence comfortably under the buffer (HistoryDrainCadence,
                    // tighter at night), gated on `gotDataFrame` so we never poke a non-streaming ring
                    // (#54). The cadence clock is persisted (EpochArchiveStore.lastDrainAt), so a fresh
                    // session drains shortly after (re)connect (lastDrainAt nil ⇒ due) yet a flapping
                    // link can't re-drain more often than the interval. Safe to repeat because
                    // `finalizeSync` re-stitches the night from the EpochArchive union.
                    let isNight = self.nightWindow?.contains(Date()) ?? false
                    let saver = UserDefaults.standard.bool(forKey: Self.batterySaverEnabledKey)
                    if self.gotDataFrame,
                       HistoryDrainCadence.isDue(lastDrainAt: self.epochArchiveStore.lastDrainAt,
                                                 now: Date(), isNight: isNight, batterySaver: saver) {
                        ringLog.notice("sync: periodic history drain (keep the ring's ~4.75 h buffer emptied)")
                        self.syncHistory()
                    } else {
                        self.write(Command.fetch)   // 07 00 00 → fresh 0x10/0x87 descriptor
                    }
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
                if Self.autoMeasureEnabled, self.idleForAutoMeasure, !self.skipAutoMeasureProbe {
                    // Refresh BOTH every cycle — HR locks in seconds when still; SpO₂ rides
                    // the same live path. (Was SpO₂ every 3rd cycle, but relaunches reset that
                    // counter so it rarely fired.) Each is bounded, so a moving hand just times
                    // out that read rather than blocking the loop. The HR result feeds the
                    // not-worn inference (#56); a user takeover (nil) is not counted.
                    if let hrLocked = await self.autoMeasureOnce(mode: .hr, timeout: 90) {   // HR can need ~60s of stillness
                        self.noteAutoMeasureCycle(locked: hrLocked)
                    }
                    // Skip SpO₂ if the HR miss above just flipped us to not-worn-with-cold-temp —
                    // no point spending another live-enter we expect to time out (#56).
                    if self.idleForAutoMeasure, !self.skipAutoMeasureProbe {
                        _ = await self.autoMeasureOnce(mode: .spo2, timeout: 45)
                    }
                    // Cadence backs off once the ring is inferred not-worn (#56); a lock above
                    // already reset it to the base interval.
                    try? await Task.sleep(for: .seconds(self.nextAutoMeasureInterval))
                } else {
                    // Disabled, busy with a user measure / sync, or inferred not-worn with a cold
                    // skin temp (#56) — re-check soon rather than deferring a full interval. A
                    // not-worn ring is re-checked cheaply (no live-enter) until its temp warms;
                    // a one-off open-sync shouldn't push the first HR out by 10 min.
                    try? await Task.sleep(for: .seconds(self.skipAutoMeasureProbe ? Self.autoMeasureColdRecheck : 30))
                }
            }
        }
    }

    /// True only when the link is up and nothing else is using it — never interrupt a user
    /// measurement, a sync, or the live-enter drain.
    private var idleForAutoMeasure: Bool {
        ready && !monitoring && !livePreparing && syncTask == nil && !probing
    }

    /// Next sleep between auto-measure cycles: the base interval while worn, exponentially backed
    /// off once the ring is inferred not-worn (#56). Pure policy lives in `AutoMeasureGate`.
    private var nextAutoMeasureInterval: TimeInterval {
        AutoMeasureGate.interval(base: Self.autoMeasureInterval,
                                 cap: Self.autoMeasureMaxBackoff,
                                 consecutiveNoLock: consecutiveAutoMeasureNoLock,
                                 rawSkinTempC: lastRawSkinTempC)
    }

    /// Skip the live-enter probe entirely this cycle (#56): we've inferred not-worn AND the raw
    /// skin temp still reads cold, so a probe would only time out and burn battery. Requires a
    /// COLD reading (positive evidence) — a missing temp falls back to probing so a sensor gap
    /// can't silently stop measuring. Re-wear is caught when the temp warms (the keepalive keeps
    /// it fresh), which clears `appearsNotWorn`.
    private var skipAutoMeasureProbe: Bool {
        appearsNotWorn && (lastRawSkinTempC.map { $0 < ActivityPeriod.wornMinTemperatureC } ?? false)
    }

    /// Fold one finished auto-measure cycle into the not-worn inference (#56): a lock proves the
    /// ring is worn (reset the miss count); a miss accrues toward the backoff. Recomputes the
    /// published `appearsNotWorn`.
    private func noteAutoMeasureCycle(locked: Bool) {
        consecutiveAutoMeasureNoLock = locked ? 0 : consecutiveAutoMeasureNoLock + 1
        refreshWornState()
    }

    /// Recompute the published not-worn flag from the current proxies (#56). Called after each
    /// auto-measure cycle and whenever a fresh raw skin temp arrives. Guarded so `@Observable`
    /// doesn't republish on every (unchanged) temp frame.
    private func refreshWornState() {
        let notWorn = AutoMeasureGate.appearsNotWorn(
            consecutiveNoLock: consecutiveAutoMeasureNoLock,
            rawSkinTempC: lastRawSkinTempC)
        if notWorn != appearsNotWorn { appearsNotWorn = notWorn }
    }

    /// The night's skin-temp samples for the sleep wear-gate (#41): the in-memory log, the only
    /// place cold/charging readings survive (the store keeps worn temps only). Empty ⇒ detection
    /// falls back to motion alone (absence of data is not evidence of being unworn).
    private func wearTemperatureSamples() -> [TemperatureSample] {
        nightTemperatureLog
    }

    /// One bounded auto-measurement: enter `mode`'s live read, wait for a converged value (or
    /// time out), then stop — which persists the reading and lets ContentView mirror it to
    /// Health. If the user takes over mid-read (monitoring an unexpected mode), we leave their
    /// session alone rather than cancelling it.
    /// Returns whether the read LOCKED, or nil if the cycle was ABORTED by a user takeover — the
    /// caller must not count an abort toward the not-worn inference (#56).
    private func autoMeasureOnce(mode: LiveMode, timeout: TimeInterval) async -> Bool? {
        guard idleForAutoMeasure else { return nil }
        autoMeasuring = true
        startMonitoring(mode: mode, userInitiated: false)   // auto refresh: prompt enter, keep last value until it locks
        let deadline = Date().addingTimeInterval(timeout)
        var locked = false
        while !Task.isCancelled && Date() < deadline {
            if mode == .hr, liveHR != nil { locked = true; break }
            if mode == .spo2, liveSpO2 != nil { locked = true; break }
            // Bail if a user tap switched the mode out from under us — don't fight them.
            if !monitoring || liveMode != mode { autoMeasuring = false; return nil }
            try? await Task.sleep(for: .seconds(1))
        }
        // Only tear down if WE still own the live read (user didn't take over).
        if autoMeasuring, monitoring, liveMode == mode { stopLiveMonitoring() }
        autoMeasuring = false
        return locked
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

    /// Staged sleep segments for a sync, but ONLY when the detected block is OVERNIGHT sleep.
    /// A normal daytime "Sync from ring" can drain worn, sedentary daytime epochs (a long meeting,
    /// a movie, an afternoon nap > 1 h); `BulkSleep.stagedSegments` would classify the first still
    /// block > 1 h as sleep, and since this feeds both the persistent Sleep card and the
    /// `StoredSleepSummary` rollup (upserted by start-of-day), a daytime block could be shown as
    /// "last night" and overwrite/supersede the real night — reintroducing the disappearing-sleep
    /// bug through the sync door. Gating to an overnight window (by overlap, never clipping, so the
    /// real night's totals are preserved) means a daytime block yields `[]`, and the card then
    /// falls back to the stored real night. (Adversarial review #1.)
    private func overnightStagedSegments(from records: [BulkRecord]) -> [SleepSegment] {
        let segs = BulkSleep.stagedSegments(from: records)
        guard let block = segs.first(where: { $0.stage == .inBed }) else { return segs }
        return SleepWindow.isOvernightBlock(start: block.start, end: block.end) ? segs : []
    }

    /// Persist the latest night's sleep summary + today's step count so the dashboard
    /// shows them OFFLINE after disconnect. Both UPSERT by day (no duplicates) and bypass
    /// the cumulative-counter `ingest` path entirely — the SyncCursor is untouched.
    /// Persist the night's summary + extras. `nightRecords` is the stitched, night-scoped union the
    /// staging came from, so the per-stage HR / movement / stress / resting HR / Sleep Score are
    /// computed over the WHOLE night — not just the final drained slice (which on a multi-drain night
    /// would skew every derived metric). Naps stay on the per-drain `bulkRecords` (they're daytime,
    /// outside the night-scoped union).
    private func persistSleepAndSteps(nightRecords: [BulkRecord]) {
        guard let localStore else { return }
        if !stagedSegments.isEmpty {
            let summary = SleepStaging.summary(stagedSegments)
            // Real sleep-window clock times (segments carry the dates; Summary doesn't) — so a
            // night-temp window aligns to actual onset/wake, not midnight. `night` (start-of-day)
            // remains the upsert key.
            let start = stagedSegments.map(\.start).min() ?? Date()
            let end = stagedSegments.map(\.end).max() ?? start
            let extras = computeSleepExtras(summary: summary, start: start, end: end,
                                            store: localStore, records: nightRecords)
            try? localStore.saveSleepSummary(summary, night: start, inBedStart: start, inBedEnd: end,
                                             extras: extras)
        }
        // Naps are detected over the whole drained window (independent of the overnight gate)
        // so a daytime-only sync still records them, never folded into the main night (#76).
        persistNaps(store: localStore)
        // Steps are accumulated live in didUpdateValue (addDailySteps) — nothing to do here.
    }

    /// Compute the Wave-1 sleep analytics for the night being persisted (#69/#70/#71): nightly
    /// skin-temp mean + rolling-baseline offset, the 6-factor composite Sleep Score, overnight
    /// stress from sleep-window RMSSD, per-stage average HR, and the movement timeline. All from
    /// already-decoded data; values are estimates (labeled as such in the UI).
    private func computeSleepExtras(summary: SleepStaging.Summary, start: Date, end: Date,
                                    store: LocalStore, records: [BulkRecord]) -> LocalStore.SleepNightExtras {
        var extras = LocalStore.SleepNightExtras()
        let window = DateInterval(start: start, end: max(end, start))

        // Skin temp (#69): nightly mean from the persisted worn overnight readings.
        let tempC = (try? store.samples(kind: .temperature, from: start, to: end))?.map(\.value)
        let nightlyTemp = tempC.flatMap { SkinTempBaseline.nightlyMean($0) }
        if let nightlyTemp { extras.skinTempC = nightlyTemp }

        // Rolling baseline from PRIOR nights (exclude tonight's day), for the composite temp factor.
        let tonightDay = Calendar.current.startOfDay(for: start)
        let priorNights: [SkinTempBaseline.NightlyTemp] = ((try? store.recentSleepSummaries(limit: 40)) ?? [])
            .filter { $0.skinTempC > 0 && Calendar.current.startOfDay(for: $0.night) != tonightDay }
            .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
        let baseline = SkinTempBaseline.baseline(priorNights: priorNights)
        let tempOffset = (nightlyTemp != nil && baseline != nil) ? nightlyTemp! - baseline! : nil

        // Per-stage HR + movement (#70).
        let hrByStage = SleepDetailMetrics.averageHRByStage(records: records, segments: stagedSegments)
        extras.hrByStage = hrByStage
        extras.movementLevels = SleepDetailMetrics.movementSummary(records: records, in: window).levels

        // Overnight stress (#71): median sleep-window RMSSD → band score.
        let rmssd = records.filter { window.contains($0.date()) }.compactMap { $0.hrvRMSSD }
        if let stress = SleepStress.overnightScore(rmssd: rmssd) { extras.stressScore = stress }

        // Resting/asleep HR for the composite HR factor (sleep mean → low-activity floor).
        let nightHR = records.compactMap { r -> HRSample? in
            guard let hr = r.heartRate else { return nil }
            let t = r.date()
            return HRSample(bpm: hr, start: t, end: t)
        }
        let restingHR = RestingHR.value(hr: nightHR, sleep: stagedSegments)

        // Composite 0–100 Sleep Score (#70).
        let composite = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem,
            restingHR: restingHR, tempOffsetC: tempOffset))
        extras.sleepScore = composite.score
        return extras
    }

    /// Detect daytime naps over the drained records and persist them (#76). Excludes the main
    /// overnight block so naps never double-count against the night; the wear gate (#41) drops
    /// off-wrist/charging stillness the same way the night does.
    private func persistNaps(store: LocalStore) {
        guard !bulkRecords.isEmpty else { return }
        let main = BulkSleep.mainSleep(from: bulkRecords, temperatures: wearTemperatureSamples())
        let naps = NapDetection.naps(from: bulkRecords, mainSleep: main,
                                     temperatures: wearTemperatureSamples())
        for nap in naps {
            try? store.saveNap(start: nap.start, end: nap.end,
                               asleepMin: Int((nap.asleep / 60).rounded()),
                               isLongNap: nap.isLongNap)
        }
    }

    // MARK: Step counter state (cross-session, #34)
    //
    // The ring's onboard step counter (descriptor [4:6]) is a since-handoff DELTA the official
    // app resets; if that app isn't running it keeps climbing (it does NOT reset at midnight on
    // its own). To compute a TRUE delta across a reconnect — instead of rebasing to the current
    // counter and dropping every step taken while we were disconnected — we persist the last raw
    // value AND the day it was seen in UserDefaults (not LocalStore: avoids a SwiftData migration
    // and a per-day-row collision). The per-day TOTAL still lives in StoredDaily via addDailySteps.

    // Per-ring (#multi-ring): namespaced by the ring's CoreBluetooth identifier so a second ring's
    // onboard counter is never diffed against the first ring's baseline (which would yield garbage
    // step deltas on a ring switch). `deviceKey` is the same id RingScanner remembers and migrates
    // the legacy un-namespaced state onto.
    private var deviceKey: String { peripheral.identifier.uuidString }
    private var lastRawStepsKey: String { "steps.lastRawValue.\(deviceKey)" }    // Int: last raw [4:6] counter
    private var lastRawStepsDayKey: String { "steps.lastRawDay.\(deviceKey)" }   // Date: start-of-day it was observed

    /// Last raw counter we recorded, or nil if we've never seen one (first run / cleared). Stored
    /// as an object so a legitimate 0 reading is distinguishable from "unset".
    private var persistedLastRawSteps: Int? {
        UserDefaults.standard.object(forKey: lastRawStepsKey) as? Int
    }
    /// Start-of-day the persisted raw counter was observed (for midnight-rollover detection).
    private var persistedLastRawStepsDay: Date? {
        UserDefaults.standard.object(forKey: lastRawStepsDayKey) as? Date
    }
    private func persistStepRawState(raw: Int, day: Date) {
        UserDefaults.standard.set(raw, forKey: lastRawStepsKey)
        UserDefaults.standard.set(day, forKey: lastRawStepsDayKey)
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
        // A #99 sweep owns the link. Refuse here (before mutating userMeasuring/liveMode) so no
        // caller — Measure tap, workout start, auto-measure — can set an orphaned `userMeasuring`
        // flag that `startLiveMonitoring`'s own `!probing` guard would then leave with no task to
        // clear it (review P2). The UI also disables these affordances while probing.
        guard !probing else { return }
        if monitoring {
            if liveMode == mode {
                if userInitiated { rearmUserMeasure() }   // re-poll on demand; auto leaves it alone
            } else {
                setLiveMode(mode)
            }
        } else {
            liveMode = mode
            // User-initiated: arm the timeout UX state so the poll loop can self-terminate (#55).
            if userInitiated {
                userMeasuring = true
                userMeasureFailed = false
                userMeasureFailedMessage = nil
            }
            startLiveMonitoring(quickLiveRead: quickLiveRead, clearStaleValue: userInitiated)
        }
    }

    /// Per-mode user-measure budget (seconds): HR needs longer stillness to converge than SpO₂.
    private func userMeasureBudget(for mode: LiveMode) -> TimeInterval {
        mode == .spo2 ? 45 : 90
    }

    /// (Re)arm the user-measure poll deadline for the current mode, or clear it on the auto path.
    /// Called when the poll loop starts AND on a re-tap (`rearmUserMeasure`) so the budget is
    /// always measured from the latest request, never the original (#65).
    private func armUserMeasureDeadline() {
        userMeasureDeadline = userMeasuring
            ? Date().addingTimeInterval(userMeasureBudget(for: liveMode))
            : nil
    }

    /// Re-arm an already-running live read for a fresh user measurement (#45 B/C): drop the
    /// stale value + convergence window, then re-issue the proven `d0` → mode → fetch enter so
    /// the ring restarts the measurement. The existing poll loop keeps sending `95 00 00`, so no
    /// second loop is spawned. This intentionally kicks HR back to warm-up — exactly what a user
    /// asking for a new reading wants.
    private func rearmUserMeasure() {
        liveHR = nil
        liveHRAt = nil
        liveHRTrend.removeAll()
        liveHRWarmup = nil
        userMeasureFailed = false        // retry: dismiss the prior error naturally (#55)
        userMeasureFailedMessage = nil
        armUserMeasureDeadline()         // fresh budget from THIS re-tap, not the original (#65)
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
        userMeasureFailed = false   // mode switch = fresh start, dismiss any prior failure (#55)
        userMeasureFailedMessage = nil
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
        userMeasuring = false   // user read done (or timed out — `userMeasureFailed` is kept for the banner) (#55)
        userMeasureDeadline = nil   // no in-flight user-measure budget once the loop is torn down (#65)
        // Safety net for a background teardown that interrupted the live-enter drain before its
        // post-drain commit ran (#22 bg race): persist the captured pages so an overnight read
        // that never reached its finalize doesn't silently drop last night's sleep/vitals.
        // No-op once the drain already committed (bulkFinalized) or nothing was captured.
        if !bulkRecords.isEmpty, !bulkFinalized {
            commitDrainedRecords()   // archive merge + stitched re-stage + persist (shared path)
        }
        // Persist the last live reading so the dashboard shows it after disconnect — stamped at
        // WHEN THE VALUE WAS MEASURED (`liveHRAt`/`liveSpO2At`), not `lastFrameAt`. The idle
        // keepalive bumps `lastFrameAt` to ≈now on every descriptor frame, so a lingering
        // `liveHR`/`liveSpO2` (a prior lock — `liveSpO2` is never cleared) was re-stamped to ~now
        // at every stop. That now-dated STALE value advanced the sync cursor past genuinely newer
        // synced sleep epochs (which then deduped out of the store) AND out-ranked them in
        // VitalsTableView.latestReading — so HR/SpO₂ showed the old measured value and never the
        // newer synced one. Stamping at the true capture time, and only persisting a reading
        // measured in THIS cycle (`>= monitoringStartedAt`), makes any re-persist land at its real
        // (old) time: deduped harmlessly, never masking fresher sync data. (#36 still holds — a
        // real lock's capture time is when it was measured, never a wrong "now".)
        let cycleStart = monitoringStartedAt ?? .distantPast
        var last: [QuantitySample] = []
        if let hr = liveHR, let at = liveHRAt, at >= cycleStart {
            last.append(QuantitySample(kind: .heartRate, start: at, value: Double(hr)))
        }
        if let spo2 = liveSpO2, let at = liveSpO2At, at >= cycleStart {
            last.append(QuantitySample(kind: .spo2, start: at, value: Double(spo2) / 100))
        }
        persist(last)
    }

    /// Pull stored history: open the sync session at cursor ≈ now (`syncUpToNow`, §3 — drains
    /// the ring's un-delivered backlog; NOT `syncAll`/0xFFFFFFFF, which returns empty) and fetch.
    /// The ring streams 0x4c/0x47 pages, drained+decoded in didUpdateValue; results
    /// land in `historySamples` once 0x50 (end-of-history) arrives.
    func syncHistory() {
        guard syncTask == nil, !probing else { return }   // already syncing, or a #99 sweep owns the link
        stopLiveMonitoring()                     // live polling would fight the drain
        syncTask = Task { [weak self] in
            await self?.performHistoryDrain()
        }
    }

    /// Open a history sync (cursor ≈ now — drains the ring's un-delivered backlog; NOT
    /// `syncAll`/0xFFFFFFFF, which returns empty), drain 0x4c/0x47 pages to the `0x50` end marker
    /// (or 3 s-quiet / 45 s cap), and COMMIT them via `finalizeSync`. Sets `syncing` for the
    /// duration so the frame handler captures pages into `bulkRecords`. Shared by the user-facing
    /// `syncHistory()` and the #99 probe's Phase 1, which commits the backlog BEFORE sweeping so the
    /// sweep sees an empty backlog and each selector's response is attributable (not leftover sleep
    /// pages still trickling in). `finalizeSync` clears `syncing`/`syncTask` on exit.
    private func performHistoryDrain() async {
        bulkRecords.removeAll()
        bulkFinalized = false                    // fresh capture — uncommitted until finalizeSync
        historySamples.removeAll()
        // Do NOT wipe the staged sleep here. A periodic drain often returns EMPTY (nothing un-synced),
        // and `finalizeSync`'s empty branch deliberately doesn't re-stage; wiping first would blank
        // `sleepSegments`/`stagedSegments` and `flushHealth` reads those live (no store fallback), so
        // last night's Health sleep-mirror could be skipped until the next non-empty drain. Keep the
        // last staged night standing — a non-empty drain overwrites it via `commitDrainedRecords`,
        // and a night that ages out of the archive is harmless to retain (the `.sleep` cursor blocks
        // re-writes and the dashboard reads the persisted summary, not these).
        syncDone = false
        syncQuietTicks = 0
        syncing = true
        syncStatus = nil
        let historyOpen = Command.syncUpToNow()
        ringLog.notice("sync: START open=\(historyOpen.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public) (cursor≈now, §3)")
        // Open at cursor ≈ NOW: the ring streams its un-delivered backlog up to now and advances
        // its own resume pointer (§3). `syncAll`'s far-future cursor returned an empty history —
        // the bug that dropped overnight sleep/HRV/RR.
        for cmd in [Command.status0, historyOpen, Command.fetch] {   // 81 00 challenge → reactive SM3 auth (#54)
            write(cmd)
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { break }
        }
        // Watchdog: finalize on 0x50, or when pages stop (3 s quiet), or a 45 s cap — so the sync
        // can never hang if the end-marker or a write is lost. The common case (ring sends 0x50)
        // exits immediately; the quiet fallback only fires when the end-marker is lost, and pages
        // stream sub-second apart during a real drain, so 3 s of silence reliably means "done".
        for tick in 0 ..< 45 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            if syncDone || syncQuietTicks >= 3 {
                ringLog.notice("sync: watchdog exit at \(tick)s (done=\(self.syncDone), quiet=\(self.syncQuietTicks), records=\(self.bulkRecords.count))")
                break
            }
        }
        finalizeSync()
    }

    /// Commit a freshly-captured batch of epoch records. A history-sync drain (`finalizeSync`), the
    /// live-enter backlog drain, AND the stop-time safety net all funnel through here, so every
    /// capture path stitches identically — fold the batch into the rolling EpochArchive and re-stage
    /// LAST night from the UNION. Centralising this means no path can persist a partial slice that
    /// overwrites a fuller summary, the archive stays complete regardless of which path drained the
    /// tail, and the periodic-drain cadence clock is stamped once per commit. Caller guarantees
    /// `!bulkRecords.isEmpty`.
    ///
    /// Each drain returns only the slice since the last (the ring advances its resume pointer on
    /// ACK), and the motion channel staging needs survives ONLY in the persisted raw records —
    /// derived HR/HRV/SpO₂ samples can't reconstruct it. `latestNightRecords` scopes the (possibly
    /// multi-night) union to LAST night so staging never picks the prior night (`findSleep` returns
    /// the earliest block) or a daytime nap.
    private func commitDrainedRecords() {
        epochArchiveStore.recordDrain()
        let temps = wearTemperatureSamples()
        let union = epochArchiveStore.merge(bulkRecords)
        let nightRecords = BulkSleep.latestNightRecords(from: union, temperatures: temps)
        // HealthKit path: THIS batch's new samples (the SyncCursor dedups against what's written).
        historySamples = BulkSleep.samples(from: bulkRecords)
        // Sleep staging + its analytics come from the stitched, night-scoped union — not this slice.
        sleepSegments = BulkSleep.sleepSegments(from: nightRecords, temperatures: temps)   // wear gate (#41)
        stagedSegments = overnightStagedSegments(from: nightRecords)   // overnight gate (review #1)
        persist(historySamples)   // auto-persist HR/HRV/SpO2 for the dashboard
        persistSleepAndSteps(nightRecords: nightRecords)   // summary + extras from the stitched night
        bulkFinalized = true      // committed — the stop-time safety net can skip these records
    }

    private func finalizeSync() {
        guard syncing else { return }
        if bulkRecords.isEmpty {
            // An empty poll (the periodic cadence fires even with nothing un-synced) brings no new
            // epochs — nothing to stitch. Stamp the cadence clock and finalize WITHOUT re-staging /
            // re-saving / re-flushing, so a periodic drain doesn't churn the stored night.
            epochArchiveStore.recordDrain()
            ringLog.notice("sync: FINALIZE records=0 (no re-stage; cadence stamped)")
            syncStatus = steps != nil
                ? "Up to date — last night is likely already in the vitals dashboard. The ring clears history after each sync, so nothing new to fetch."
                : "No data received — is the ring bonded/awake?"
        } else {
            commitDrainedRecords()
            ringLog.notice("sync: FINALIZE records=\(self.bulkRecords.count) samples=\(self.historySamples.count) sleepSegs=\(self.sleepSegments.count) steps=\(self.steps ?? -1)")
            syncStatus = "Synced \(bulkRecords.count) epochs"
        }
        syncing = false
        syncTask = nil
    }

    /// Per-selector dwell: time to collect responses after the sync-open + fetch. Phase 1 has
    /// already drained the backlog, so a near-now open here returns only the ACK + whatever stream
    /// THIS selector opens — a few seconds is enough before moving to the next selector.
    private static let probeSelectorDwell: Duration = .seconds(3)

    /// #99 — sweep the `0x02` sync-open `byte[6]` (DataSyncType) selector across all candidates,
    /// capturing each selector's raw responses so we can find which one returns an all-day HR/SpO₂
    /// stream. Post-auth (status0 primes the SM3 challenge) with a real ≈now cursor — the two fixes
    /// the inconclusive desktop sweep lacked. Phase 1 first commits the real history backlog so the
    /// sweep is non-destructive and each selector's response is attributable. Results land in
    /// `probeResults`/`probeReport` and the unified log. Idempotent; refuses to start mid-sync/live
    /// (stops live first) so responses aren't muddied.
    func probeAllDayStreams() {
        guard probeTask == nil, !probing, syncTask == nil else { return }   // not mid-sync/probe
        guard ready else { probeReport = "Connect the ring first."; return }
        stopLiveMonitoring()                 // live polling would inject its own 0x15 traffic
        probing = true                       // pauses keepalive/auto-measure for the WHOLE probe
        probeResults.removeAll()
        probeCurrent = nil
        probeReport = "Syncing history first, then probing \(DataSyncProbe.candidates.count) selectors…"
        ringLog.notice("probe #99: START — commit backlog, then sweep \(DataSyncProbe.candidates.count) selectors (real ≈now cursor, post-auth)")
        probeTask = Task { [weak self] in
            guard let self else { return }
            // PHASE 1 — drain + COMMIT the real history backlog first. This makes the probe
            // NON-DESTRUCTIVE (the ring's resume pointer advances either way once pages are ACKed,
            // so we must persist what drains — see PROTOCOL.md §3 backlog-shred). It also gives
            // clean Phase-2 attribution: with the backlog handed off, any pages a selector returns
            // are genuinely THAT selector's stream, not leftover sleep/activity still trickling in.
            await self.performHistoryDrain()     // sets/clears `syncing`; persists via finalizeSync
            guard !Task.isCancelled else { self.finishProbe(); return }
            // PHASE 2 — sweep the byte[6] selectors against the now-empty backlog. `syncing` is
            // false here, so the 0x4c handler no longer folds pages into `bulkRecords`; the probe's
            // `collectProbeFrame` captures the raw responses into the per-selector buckets instead.
            self.write(Command.status0)          // re-prime auth in case the session re-challenged
            try? await Task.sleep(for: .milliseconds(400))
            // One cursor for the whole sweep so the only thing varying is byte[6].
            let nowSecs = Int(Date().timeIntervalSince1970)
            for sel in DataSyncProbe.candidates {
                // BREAK (don't return) on cancel so `finishProbe` always runs and clears `probing`
                // — otherwise a cancelled sweep leaves the link paused (keepalive/sync stay gated).
                guard !Task.isCancelled else { break }
                self.beginSelector(sel)
                self.write(DataSyncProbe.syncOpen(unixSeconds: nowSecs, selector: sel.byte))
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { self.write(Command.fetch) }
                try? await Task.sleep(for: Self.probeSelectorDwell)
                self.endSelector()   // keep the partial bucket even if the dwell was cut short
            }
            self.finishProbe()
        }
    }

    private func beginSelector(_ sel: DataSyncSelector) {
        probeCurrent = SelectorProbeResult(selector: sel.byte, label: sel.label)
    }

    /// Fold one raw response frame into the active selector's bucket (called for EVERY frame while
    /// probing, including the opcodes the normal switch returns early on / drops). No-op between
    /// selectors.
    private func collectProbeFrame(_ bytes: [UInt8]) {
        probeCurrent?.record(bytes)
    }

    private func endSelector() {
        guard let r = probeCurrent else { return }
        probeResults.append(r)
        let ops = r.opcodes.map { String(format: "%02x", $0) }.joined(separator: " ")
        ringLog.notice("probe #99: selector 0x\(String(format: "%02x", r.selector), privacy: .public) ack=\(r.sawAck) frames=\(r.frameCount) op=[\(ops, privacy: .public)] — \(r.label, privacy: .public)")
        // Log EVERY captured raw frame (not just the first) — a novel HR/SpO₂ opcode falls through
        // the handler's `default` with no other log, so this is the only on-device record of the
        // bytes needed to ground-truth the record layout (#99, review P3).
        if !r.sampleFrames.isEmpty {
            ringLog.notice("probe #99:   raw[0x\(String(format: "%02x", r.selector), privacy: .public)]\n\(r.sampleFrames.joined(separator: "\n"), privacy: .public)")
        }
        probeCurrent = nil
    }

    private func finishProbe() {
        probing = false
        probeTask = nil
        let report = DataSyncProbe.summarize(probeResults)
        probeReport = report
        ringLog.notice("probe #99: DONE\n\(report, privacy: .public)")
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
                } else if ch.uuid == self.systemIDUUID, self.ringMAC == nil {
                    peripheral.readValue(for: ch)   // → MAC for the auth challenge-response (#54)
                } else if ch.uuid == self.firmwareRevUUID {
                    peripheral.readValue(for: ch)   // → FW version string (#79)
                } else if ch.uuid == self.manufacturerUUID {
                    peripheral.readValue(for: ch)   // → Manufacturer Name (#79)
                } else if ch.uuid == self.hardwareRevUUID {
                    peripheral.readValue(for: ch)   // → Hardware Revision (#79)
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
            // System ID read (DIS 0x2a23) — recover the ring's MAC for the auth challenge-response
            // (#54). Not a ring data frame, so handle + return before the frame logic below.
            if characteristic.uuid == self.systemIDUUID {
                if let mac = RingAuth.macFromSystemID(bytes) {
                    self.ringMAC = mac
                    let macStr = mac.map { String(format: "%02x", $0) }.joined(separator: ":")
                    ringLog.notice("ring MAC (System ID): \(macStr, privacy: .public) → auth V=0x\(String(format: "%02x", RingAuth.macTailXor(mac)), privacy: .public)")
                    self.firmwareInfo.mac = macStr.uppercased()   // (#79) surfaced in DeviceInfoView
                    // The auth challenge can arrive BEFORE this read completes (service-discovery
                    // race). When it does, it was answered with the legacy fixed fallback — correct
                    // ONLY for the originally-captured ring, so ANY OTHER ring never starts streaming
                    // (#multi-ring). Now that we have THIS ring's MAC, re-prime the handshake: a fresh
                    // `status0` makes the ring re-challenge and we answer with the correct SM3. Gated on
                    // a ready write path + no data yet, so it's a one-shot that never disturbs a stream
                    // that already authed.
                    if self.writeChar != nil, !self.gotDataFrame {
                        ringLog.notice("auth: MAC arrived after challenge — re-priming status0 for SM3 reply (#multi-ring)")
                        self.write(Command.status0)
                    }
                } else {
                    ringLog.notice("System ID unparsed (\(bytes.count, privacy: .public)B): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
                }
                return
            }
            // DIS string reads (firmware/manufacturer/hardware revision) — UTF-8 strings (#79).
            if characteristic.uuid == self.firmwareRevUUID {
                if let s = String(bytes: bytes, encoding: .utf8) { self.firmwareInfo.version = s }
                return
            }
            if characteristic.uuid == self.manufacturerUUID {
                if let s = String(bytes: bytes, encoding: .utf8) { self.firmwareInfo.manufacturer = s }
                return
            }
            if characteristic.uuid == self.hardwareRevUUID {
                if let s = String(bytes: bytes, encoding: .utf8) { self.firmwareInfo.hardwareRevision = s }
                return
            }
            self.lastFrame = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            self.lastFrameAt = Date()   // freshness anchor for staleness + last-reading timestamp (#36)
            // #99 probe: capture EVERY raw frame into the active selector's bucket — including the
            // opcodes the switch below returns early on (0x82/0x50/0x4c…) and any NEW opcode it would
            // drop in `default`. Must precede that switch so nothing is missed.
            if self.probing { self.collectProbeFrame(bytes) }
            // A DATA frame (anything but the cold `0x81` status reply, which even an un-activated ring
            // answers) proves the ring's data path is live: clear `notStreaming` + satisfy the
            // activation watchdog (#54). Guarded so `@Observable` doesn't republish on every frame.
            if let op = bytes.first, op != 0x81 {
                if !self.gotDataFrame { self.gotDataFrame = true }
                if self.notStreaming { self.notStreaming = false }
                self.streamWatchdogTask?.cancel(); self.streamWatchdogTask = nil
                // Durable "last ring data received" timestamp for the wear reminder (#84): a real
                // data frame proves the ring is worn/streaming. Persisted (unlike the in-memory
                // `lastFrameAt`) so a cold foreground doesn't falsely fire "put your ring back on".
                UserDefaults.standard.set(Date().timeIntervalSince1970,
                                          forKey: ReminderDefaults.lastRingDataAt)
            }
            // Frames arriving while the link isn't `ready` mean discovery didn't land on this
            // (restored) reconnect — re-run it so we can ack and the buttons enable. #reconnect
            if !self.ready { self.rediscoverIfNeeded() }
            // The ring's onboard step counter (descriptor [4:6], §5.4) is a since-handoff DELTA the
            // official app resets; if that app isn't running it keeps climbing (it does NOT reset
            // at midnight on its own). Fold each observed counter into a persistent per-day total,
            // reset-aware, using the last raw value persisted ACROSS sessions — so a reconnect
            // computes the TRUE delta since we last saw the ring instead of rebasing to the current
            // counter and dropping every step taken while disconnected (#34). The pure, unit-tested
            // StepAccumulator owns the reset/midnight math; this stays a thin caller.
            if let v = DeviceStatus.steps(bytes) {
                // Stamp by SAMPLE time (when the descriptor arrived), not a hardcoded Date(), so a
                // delta lands on the right StoredDaily row at a day boundary (#34). NOTE: on the LIVE
                // path lastFrameAt was just set to now (line ~689), so sampleDate ≈ ingest time — this
                // picks the correct day for the row/persist + display re-read, but it cannot back-date
                // steps actually taken at 23:59 onto the prior day (no per-step timestamps on the wire).
                let sampleDate = self.lastFrameAt ?? Date()
                let sampleDay = Calendar.current.startOfDay(for: sampleDate)
                let previousRaw = self.persistedLastRawSteps
                let dayChanged = previousRaw != nil && self.persistedLastRawStepsDay != sampleDay
                let update = StepAccumulator.update(previousRaw: previousRaw, newRaw: v, dayChanged: dayChanged)
                if update.isReset {
                    // Disambiguate a mid-day reset/handoff (unexpected — log loudly) from the
                    // official app's normal midnight reset (expected) so we never silently miscount.
                    if update.isAnomalousReset {
                        ringLog.notice("steps: mid-day counter reset \(previousRaw ?? -1)→\(v) — counting \(v) as new (handoff/reboot/wrap)")
                    } else {
                        ringLog.debug("steps: counter reset across midnight \(previousRaw ?? -1)→\(v) — counting \(v) on new day (expected)")
                    }
                }
                if update.deltaToAdd > 0 {
                    try? localStore?.addDailySteps(update.deltaToAdd, day: sampleDate)
                    // Record activity time for the sedentary reminder (#84).
                    UserDefaults.standard.set(sampleDate.timeIntervalSince1970,
                                              forKey: ReminderDefaults.lastActivityAt)
                }
                // Re-read the sample day's total from the store as the live display value: a fresh
                // row on midnight rollover reads its own total (no prior-day baseline bleed), and a
                // baseline-only first reading recovers today's already-accumulated count.
                dailyStepsTotal = (try? localStore?.todaySteps(day: sampleDate)) ?? dailyStepsTotal
                self.steps = dailyStepsTotal
                // Persist the raw counter + its day for the NEXT reading (cross-session, #34).
                self.persistStepRawState(raw: v, day: sampleDay)
            }
            // Skin temperature rides the same 0x10/0x87 descriptor (§5.4). It streams live
            // (~30–60 s) and is NOT in the sleep sync, so capture + persist it here — but ONLY
            // during the nightly sleep window. Daytime readings are too noisy/unpredictable
            // (activity, ambient swings, intermittent skin contact) to be a usable trend, so we
            // drop them and surface no live value outside the window.
            if let t = DeviceStatus.skinTemperature(bytes) {
                // Wear proxy (#56/#41): record the RAW reading BEFORE the night-window / worn
                // gates below. A cold (off-wrist/charging) reading is exactly what the not-worn
                // inference and the sleep wear-gate need, and neither survives those gates.
                self.lastRawSkinTempC = t.celsius
                self.refreshWornState()
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
                let worn = t.celsius >= ActivityPeriod.wornMinTemperatureC
                // Keep EVERY night reading (worn AND cold) in-memory for the sleep wear-gate's
                // median test (#41) — the cold ones are what reclassify a charging block out of
                // sleep. The store (below) keeps worn temps only, so this log is their sole home.
                if inNightWindow {
                    self.nightTemperatureLog.append(TemperatureSample(time: Date(), celsius: t.celsius))
                    if self.nightTemperatureLog.count > Self.nightTemperatureLogCap {
                        self.nightTemperatureLog.removeFirst(self.nightTemperatureLog.count - Self.nightTemperatureLogCap)
                    }
                }
                // Persist / display ONLY a worn reading: a cold charging reading isn't a skin
                // temperature, so it must not pollute the nightly average or reach Apple Health
                // (#41). The cold reading still drives the wear proxies above.
                self.liveTemperature = (inNightWindow && worn) ? t.celsius : nil
                if inNightWindow, worn {
                    self.persist([QuantitySample(kind: .temperature, start: Date(), value: t.celsius)])
                }
            }
            // Ring battery % is descriptor byte[1] (§5.4 🟢, ground-truthed).
            // Also stamps `batteryFetchedAt` (#57) and extends the charging-inference trend (#60)
            // and the TTE sample window (#86).
            if let b = DeviceStatus.battery(bytes) {
                self.batteryPercent = b
                self.batteryFetchedAt = Date()   // dedicated freshness anchor (#57)
                // Charging inference: rolling window of distinct readings (#60).
                if self.batteryTrend.last != b {
                    self.batteryTrend.append(b)
                    if self.batteryTrend.count > Self.batteryTrendCapacity {
                        self.batteryTrend.removeFirst()
                    }
                }
                // TTE: rolling window of timestamped battery % readings (#86).
                self.batteryHistory.append(BatteryTTE.Sample(percent: b, at: Date()))
                if self.batteryHistory.count > Self.batteryHistoryCap {
                    self.batteryHistory.removeFirst()
                }
            }
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
            case 0x82:
                // Sync-open ACK. At NOTICE so an ACCEPTED open (0x82 arrives) is distinguishable
                // from a refused one (silence — cursor out of range); debug writes don't persist.
                ringLog.notice("← 0x82 sync-open ACK: \(self.lastFrame ?? "", privacy: .public)")
                return
            case 0x50:
                // End-of-history cursor report (§5.5) — NO XOR trailer, so it never
                // reaches Frame.parse. Mark done; the sync watchdog / live-enter drain finalizes.
                self.drainDone = true
                if self.syncing { self.syncDone = true }
                ringLog.notice("← 0x50 END-OF-HISTORY (records=\(self.bulkRecords.count)) raw=\(self.lastFrame ?? "", privacy: .public)")
                self.handleEndOfHistory(data)   // finalize epoch session, gated persist (#24)
                return
            case 0x11:
                // Ring heartbeat (unsolicited keepalive, ~2.5 min idle). The official app answers
                // every `0x11` with a constant `91 00 00`; mirror that so an activated ring has no
                // reason to throttle our stream (#54 / §5.8). Don't echo the counter/token.
                self.lastHeartbeatAt = Date()
                ringLog.debug("← 0x11 heartbeat, ack 91 00 00")
                self.write(Command.heartbeatAck)
                return
            case 0x81:
                // Auth handshake (#54, §5.8). `81 00 <chal>` (← our `01 00 00`) is the ring's
                // challenge — reply with `01 01 <SM3([V,chal])[-3:]> 00` so the ring activates its
                // data stream. Needs the MAC (read from System ID); without it, fall back to the
                // legacy fixed auth (`status1`), which is only correct when the challenge is 0xb0.
                if bytes.count >= 3, bytes[1] == 0x00 {
                    let chal = bytes[2]
                    let auth = self.ringMAC.map { RingAuth.authCommand(challenge: chal, mac: $0) } ?? Command.status1
                    ringLog.notice("← 0x81 challenge=0x\(String(format: "%02x", chal), privacy: .public), reply \(self.ringMAC == nil ? "legacy-fixed" : "SM3 auth", privacy: .public)")
                    self.write(auth)
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
                if let hr = LiveHR.decodeLocked(bytes) {                         // short frame, locked on
                    self.liveHR = hr
                    self.liveHRAt = Date()   // true capture time for the stop-time persist (not lastFrameAt)
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
                    self.liveSpO2At = Date()   // true capture time for the stop-time persist (not lastFrameAt)
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

    /// Notify-subscription result (#54). `ready` only means the characteristic was DISCOVERED; this
    /// is the first point we know whether notifications will actually flow. On failure (e.g. the
    /// data char needs an encrypted/bonded link the ring won't grant when un-activated) we surface
    /// `notStreaming` immediately instead of writing commands into the void; on success we arm the
    /// first-DATA-frame watchdog.
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == self.notifyUUID else { return }
            if let error {
                ringLog.error("notify subscribe FAILED: \(error.localizedDescription, privacy: .public)")
                self.notifySubscribed = false
                self.notStreaming = true
                return
            }
            self.notifySubscribed = characteristic.isNotifying
            ringLog.notice("notify subscribed=\(characteristic.isNotifying)")
            if characteristic.isNotifying { self.startStreamWatchdog() }
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
