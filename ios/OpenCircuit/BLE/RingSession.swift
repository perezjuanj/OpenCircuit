import Foundation
import CoreBluetooth
import Observation
import OpenCircuitKit
import os
import UIKit
import UserNotifications

/// Unified-logging channel for the BLE/sync path. Stream live from a connected device with:
///   log stream --device --predicate 'subsystem == "com.standardsoftwaresolutions.opencircuit"'
/// (Logger reaches the unified log; plain `print` on iOS does not.)
let ringLog = Logger(subsystem: "com.standardsoftwaresolutions.opencircuit", category: "ring")

// An active link to a connected ring: discovers the notify/write characteristics
// by UUID, enables notifications, sends commands, and decodes responses through
// OpenCircuitKit's confirmed codec. Spec-supported behavior implemented:
//   • live-HR poll (0x95 → 0x15, LiveHR.decode 🟡)
//   • history sync: drain 0x4c activity/sleep pages → BulkSleep → HR/HRV/SpO2
//     samples (PROTOCOL.md §5.3, 🟢 fields). 0x47 PPG pages are acked but not yet
//     decoded (their payload is 🔴 — issue #8).
//   • Layer-A epoch page routing (0x47/0x4c/0x50) also feeds EpochSyncSession in
//     parallel, gated behind `epochDecodingEnabled` (#24).

@Observable
@MainActor
final class RingSession: NSObject {
    private let observability = ObservabilityStore()

    enum LiveMode { case hr, spo2 }

    private(set) var liveHR: Int?
    private(set) var liveSpO2: Int?       // 🟡 from long 0x15 frame byte[14]
    /// Wall-clock when `liveHR` / `liveSpO2` were last actually LOCKED (a fresh decoded reading) —
    /// NOT when the last frame arrived. The idle keepalive bumps `lastFrameAt` to ≈now on every
    /// descriptor frame, so stamping a persisted reading with `lastFrameAt` re-dated a lingering
    /// (stale) HR/SpO₂ to ~now. Stamp with the true capture time instead (see `stopLiveMonitoring`).
    ///
    /// Exposed `private(set)` so a workout poll can tell a genuinely fresh in-motion lock from a
    /// held latch — `liveHR` is never cleared while monitoring, so without the capture time a
    /// consumer re-records the last still value forever (the "stuck at 98" workout bug). (#45)
    private(set) var liveHRAt: Date?
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
    private(set) var liveTemperature: Double?   // live skin temp °C for UI (0x10/0x87 [6:8]/[8:10], §5.4)
    private(set) var batteryPercent: Int?       // ring battery % (0x10/0x87 [1], §5.4 🟢)
    private(set) var liveMode: LiveMode = .hr
    /// Wall-clock time of the most recent frame actually received from the ring (#36). Lets the
    /// UI detect a silently-dropped link (values stop updating before CoreBluetooth fires
    /// `didDisconnect`) and stamps the persisted last live reading with when it was REALLY
    /// measured — not `Date()`, which would push a minutes-old reading into HealthKit "now".
    private(set) var lastFrameAt: Date?
    private(set) var monitoring = false
    /// True while a WORKOUT owns the live-HR link. Set via `beginWorkoutHR()`. Suppresses the
    /// periodic auto-measure (see `idleForAutoMeasure`) so a concurrent measure can't call
    /// `stopLiveMonitoring()` on the workout's cycle mid-session — the silent "records zero HR for
    /// the rest of the workout" contention bug. The workout always runs its OWN fresh cycle.
    private(set) var workoutHolding = false
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
    /// Diagnostic-only decode of the most recent `0x47` PPG/optical-trend page (issue #8 —
    /// PROTOCOL.md §5.2). Bit-width (10-bit BE) and cadence (900s) are settled offline, but
    /// channel identity and absolute units are NOT — so this is surfaced for inspection (e.g.
    /// the Debug card) only, never written to HealthKit or fed into any analytic.
    private(set) var lastPPGTrendSummary: String?
    /// Decode-sanity anomalies from the most recent drain (firmware-drift risk, #firmware-pin) —
    /// PATTERNS across a whole drain that a single-field clamp can't see, distinct from "this
    /// sync got little/no data" (sparse/contended syncs are expected and silent). Computed in
    /// `commitDrainedRecords()`; surfaced via `ObservabilityStore`/`ActivityLogView`.
    private(set) var lastSyncAnomalies: Set<DecodeAnomaly> = []
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
    // `appearsNotWorn` is the temperature/no-lock PROXY for off-wrist (still 🟡 — no confirmed
    // skin-contact byte): periodic auto-measures that never lock (🟢) plus, when available, a cold
    // raw skin-temp reading (🟡, AutoMeasureGate). For the CHARGER case specifically the decoded
    // `charging` byte (#61, `[2]==0x04` 🟢) is now the definitive signal and is consulted directly
    // by `skipAutoMeasureProbe`. This gates only the AUTOMATIC HR/SpO₂ refresh (which on the
    // charger just times out and drains battery, #56) and a small UI hint; manual Measure / Sync
    // are never blocked by it. Reset per connection (a new RingSession each connect).
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

    // MARK: Charging state (#61 — DECODED) + inference fallback (#60)
    //
    // The charging byte IS on the wire (resolved 2026-06-19, PROTOCOL.md §5.4): descriptor
    // `[2] == 0x04` ⟺ on the charger 🟢, confirmed by a labelled A/B (battery 66→74 % over a
    // 6-min charge; 100 % of charging frames read 0x04, `[17]==0x46` as a second witness). So
    // `charging` is the real, per-frame, instant signal. The rising-battery `inferredCharging`
    // proxy (#60) is kept only as a FALLBACK for the reconnect-backoff window when no live frame
    // exists (session == nil) — it's persisted before teardown so the card can still hint.

    /// 🟢 Confirmed on-charger state from the most recent 0x10/0x87 descriptor (`DeviceStatus.isOnCharger`,
    /// `[2]==0x04`). Per-frame and instant — flips on charger contact before temp/battery move.
    /// Reset per connection. Prefer this over `inferredCharging` whenever connected.
    private(set) var charging = false

    /// 🟢 Ring battery voltage in mV from the descriptor `[14:16]` (`DeviceStatus.batteryVoltageMillivolts`,
    /// #89), or nil until a valid frame. ~4000 mV worn, climbs toward ~4400 mV on the charger.
    private(set) var batteryVoltageMV: Int?

    /// 🟢 Charging-case battery from the descriptor `[17]` (`DeviceStatus.caseBattery`, #89): case %
    /// + whether the case itself is charging. nil when the ring isn't docked in the case (0xff).
    private(set) var caseBattery: DeviceStatus.CaseBattery?

    /// Rolling battery % readings (oldest→newest, capped) for the charging-inference fallback (#60).
    private var batteryTrend: [Int] = []
    private static let batteryTrendCapacity = 4

    /// True when the last few battery readings are strictly rising — the pre-#61 fallback used
    /// only when no live frame is in hand (use `charging` while connected). Labelled "inferred".
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
    /// One-shot post-sync device-status refresh. The history drain (`0x4c`/`0x47`) does NOT
    /// guarantee an immediate `0x10`/`0x87` descriptor, so steps / battery / charger / case-state
    /// can stay stale until the next keepalive tick. This bounded follow-up fetch makes the
    /// non-overnight metrics refresh immediately after a sync instead of "eventually".
    private var postSyncStatusTask: Task<Void, Never>?
    /// A status refresh was requested while the link was busy. Fulfilled on the next idle window
    /// so steps/battery still recover even when a live read starts immediately after a sync.
    private var pendingDeviceStatusRefresh = false
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
    /// COARSE sleep segments from the motion channel (inBed/asleepCore/awake, no HR onset
    /// trim). The fallback for HealthKit/store when no HR-staged block exists. Its non-emptiness
    /// also doubles as the wear gate (#41) — empty on a charging/off-wrist night.
    private(set) var sleepSegments: [SleepSegment] = []
    /// HR-aware Light/Deep/REM/Awake staging (the descent-onset trim lives here). The PREFERRED
    /// source for both the dashboard and Apple Health (#15); see `healthSleepSegments`.
    private(set) var stagedSegments: [SleepSegment] = []
    /// The segments to mirror to Apple Health and persist: the HR-aware `stagedSegments` when a
    /// real overnight block was staged, else the coarse `sleepSegments`. Returns empty when the
    /// coarse wear gate is empty (charging/off-wrist), so nothing is written for a non-worn night.
    /// The SINGLE definition of the staged-vs-coarse policy — the foreground flush and the
    /// background BGTask both read it, so they can never drift apart (they previously did: the
    /// BGTask wrote the un-trimmed coarse segments while the foreground wrote staged).
    var healthSleepSegments: [SleepSegment] {
        !stagedSegments.isEmpty && !sleepSegments.isEmpty ? stagedSegments : sleepSegments
    }
    /// True while a history sync is in progress.
    private(set) var syncing = false
    /// User-facing result of the last sync (e.g. "204 epochs"), or an error note.
    private(set) var syncStatus: String?
    /// Per-channel epochs drained by the last `syncHistory()` — e.g. "sleep 42 · all-day 8" — so the
    /// Debug card can show that channel `0x03` (all-day) actually returned data (#99 verification).
    private(set) var lastDrainSummary: String?
    private var drainCountsByLabel: [String: Int] = [:]
    /// What kicked the drain now in flight, when it was a BACKGROUND BLE-event wake (#119) —
    /// e.g. "0x11-wake". nil for foreground/keepalive/manual/BGTask drains. Read (and cleared)
    /// by `performHistoryDrain` to decide whether the drain must deliver its own results.
    private var pendingDrainTrigger: String?
    /// Background-task assertion held across a backgrounded drain (#119): 0x4c pages renew the
    /// BLE wake on their own, but the channel opens, the 3 s quiet tail, and finalize + Health
    /// flush have no BLE traffic — without this, iOS can suspend us mid-commit.
    private var drainAssertion: UIBackgroundTaskIdentifier = .invalid
    private var drainTraces: [HistoryChannelTrace] = []
    private var activeDrainTrace: HistoryChannelTrace?
    private var historySyncTrigger = "foreground"

    private var bulkRecords: [BulkRecord] = []
    private var bulkFinalized = false    // captured pages already committed (sleep/vitals) — stop-time safety net skips re-commit
    private var didRestageFromArchive = false   // once-per-session: surface retained-but-unstaged archive epochs (#119)
    private var dailyStepsTotal = 0      // cached display total for the last sample day (mirrors StoredDaily)
    private var syncTask: Task<Void, Never>?
    private var syncDone = false        // 0x50 end-of-history seen
    private var syncQuietTicks = 0      // seconds since the last page arrived
    private var drainSawPage = false    // a 0x47/0x4c page arrived since last check (live-enter drain)
    private var drainDone = false       // 0x50 end-of-history seen during live-enter drain

    // MARK: OSA dense-PPG burst (#91)
    /// Raw `0x48` frames collected during the current store-and-forward burst. `0x48` is a
    /// free-running stream (no per-frame ack) that the ring dumps unprompted during the morning
    /// sync AFTER the `0x50` end-of-history — so we collect regardless of the `syncing` flag
    /// (gating on it would drop a burst that lands once the drain loop has exited) and finalize via
    /// a debounce timer once frames stop arriving.
    private var osaFrames: [[UInt8]] = []
    private var osaDebounceTask: Task<Void, Never>?
    private var osaDecoding = false      // a burst decode is in flight — serializes finalize
    private var osaHitCap = false        // logged-once guard for the frame cap
    /// Cap on RAW WIRE frames (pre-dedup). ⚠️ a night is NOT ~1900 frames — that's the *deduped*
    /// unique-counter count; the wire burst is retransmit-heavy: the real captures hold 7200 / 6014 /
    /// 13141 frames (the 13141 = one night + a re-dumped prior night). Dedup happens later in
    /// `OSAWaveform.channels`. So this is sized well above the observed max as a pure leak bound;
    /// undersizing it silently truncates the night and corrupts the min/ODI metrics (#91 review).
    private static let osaFrameCap = 20_000
    private static let osaBurstQuiet: Duration = .seconds(5)  // finalize this long after the last frame
    /// Latest decoded OSA SpO₂ night summary (nil until an assessment burst is drained). `averageSpO2`
    /// is validated (±1 %); `timeBelow90Seconds`/`odi` are ESTIMATES — label EXPERIMENTAL wherever shown.
    private(set) var latestOSASummary: OSASpO2.NightSummary?
    /// Local hint that we've armed an overnight OSA assessment this session (the ring can't be queried
    /// for it, so this resets on relaunch/reconnect — it drives the toggle, not ground truth).
    private(set) var osaAssessmentArmed = false

    // MARK: Calibration PPG capture

    /// Guided calibration uses a dedicated raw PPG push-stream (`0x13`) rather than the ordinary
    /// history drain. Keep it separate from `monitoring`/`syncing` so the rest of the app can gate
    /// on it explicitly without pretending it is a normal live-HR read.
    private(set) var calibrationCapturing = false
    private var calibrationKeepaliveTask: Task<Void, Never>?
    private var calibrationWatchdogTask: Task<Void, Never>?
    private var calibrationStopTask: Task<Void, Never>?
    private var calibrationFrameSink: ((PPGRawFrame) -> Void)?
    private var calibrationContinuation: CheckedContinuation<Int, Error>?
    private var calibrationSampleCount = 0
    private var calibrationLastFrameAt = Date.distantPast
    private var calibrationMissCount = 0
    /// #138: how many times the stall watchdog has re-entered PPG mode WITHOUT a frame arriving
    /// since. Reset to 0 whenever a real frame lands (`handleCalibrationPPGFrame`). If it crosses
    /// `calibrationMaxReenters` the link is up but permanently silent → fail the capture instead of
    /// looping `enterCalibrationPPGMode()` forever.
    private var calibrationReenterCount = 0
    /// Ceiling of consecutive stall re-entries with no recovered frames before we declare the
    /// capture dead. Each re-entry follows 5 misses × 1.5 s ≈ 7.5 s of silence, so this is
    /// ~30 s of continuous, unrecovered silence — unreachable by a healthy capture (which streams
    /// continuously and resets the counter on every frame).
    private static let calibrationMaxReenters = 4
    /// #138: minimum average sample rate a genuine capture sustains, used only as a stop-time
    /// backstop against a link that limped to the duration mark with a trickle of frames. The
    /// watchdog's liveness contract already requires a 25-sample frame at least every ~1.4 s
    /// (≈18 samples/s) or it acts; this floor is ~20 % of that (a 5× margin) so a real capture can
    /// never trip it — only one that streamed for a tiny fraction of the window.
    private static let calibrationMinSamplesPerSecond: Double = 3.5

    // MARK: Activity-channel probe (debug / RE — issue #93)
    //
    // The per-day step/activity history record (历史活动响应, PROTOCOL.md §5.3.1) has never been
    // captured: every sync we've ever decoded used sync-open byte[6] ∈ {0x00, 0x03} (sleep,
    // all-day), and both return the MEASUREMENT record, not the ACTIVITY one. The official app is
    // gone now, so OpenCircuit is the only client that can take this capture. This probe sweeps
    // untried byte[6] values and records EVERY raw frame (any opcode) regardless of whether we can
    // decode it — the actual decoding happens offline (`desktop/decode_activity.py`) so a wrong
    // first guess at the record layout doesn't require a new on-device capture.

    /// True while a forensic capture is running — either the activity-channel probe or the
    /// one-time historic pull below. Every write + inbound frame is appended to `rawCaptureLog`
    /// verbatim, independent of the normal decode path, so the capture can be shared and decoded
    /// offline without disturbing the primary workflow.
    private var captureRawFrames = false
    /// Raw frames captured by the most recent forensic session, one per line. Notification lines are
    /// formatted to match the desktop tool's `decode-log` text dump (`Notification 0x0804 <hex>`),
    /// and writes use the sibling `Write 0x0802 <hex>` form so the whole exchange can be replayed
    /// or analyzed offline as a single artifact.
    private(set) var rawCaptureLog: [String] = []
    private var probeTask: Task<Void, Never>?
    /// True while `probeActivityChannels` is running, and which channel it's currently on — surfaced
    /// so the Debug card can show progress instead of looking hung for the ~8s-per-channel sweep.
    private(set) var probing = false
    private(set) var probeStatus: String?
    /// True while the dedicated one-time historic pull is running. Kept separate from `syncing`
    /// because the pull is a user-facing capture mode layered on top of the normal history drain.
    private(set) var capturingHistoricPull = false
    /// User-facing status for the one-time historic pull — start/progress/finish summary surfaced in
    /// the sync card so the user knows when the raw capture is ready to export.
    private(set) var historicPullStatus: String?
    /// True while the full forensic sweep is running: known history drain first, then unknown
    /// channel probes for offline RE on the Mac. Separate from `capturingHistoricPull` because this
    /// is explicitly broader and slower than the known-channel pull.
    private(set) var capturingForensicSweep = false
    /// User-facing status for the full forensic sweep.
    private(set) var forensicSweepStatus: String?

    /// Sweep untried sync-open `byte[6]` channel selectors looking for the undecoded activity/step
    /// history stream (历史活动响应, PROTOCOL.md §5.3.1). For each candidate: open a history sync on
    /// that channel (cursor ≈ now, same "drain up to now" trigger as the known sleep/all-day channels
    /// — PROTOCOL.md §3), fetch, and capture every raw frame until the channel goes quiet. Channels are
    /// independent (their own resume cursor — §5.6.1), so probing an untried one can't disturb the
    /// 0x00/0x03 history this session also drains. `0x02` leads the default order — §5.3.1 names it the
    /// single best-guess selector (enum-idx 2 in the decompiled `DataSyncType`, the same gap as the
    /// all-day HR/SpO2 probe that #99 resolved at `0x03`); the rest are the other untried values the
    /// official app never sends (0x00/0x03 are the only two ever observed in any capture). After this
    /// capture, decode it with the predicted layout in `decode_activity.py` /
    /// `ActivityRecordPredicted.decode(_:)` to confirm or rule it out.
    func probeActivityChannels(_ candidates: [UInt8] = [0x02, 0x01, 0x04, 0x05, 0x08]) {
        guard probeTask == nil else { return }
        captureRawFrames = true
        rawCaptureLog.removeAll()
        probing = true
        probeStatus = "Starting…"
        probeTask = Task { [weak self] in
            for channel in candidates {
                guard let self, !Task.isCancelled else { break }
                self.probeStatus = "Probing channel 0x\(String(format: "%02X", channel))…"
                self.rawCaptureLog.append("# --- probe: channel 0x\(String(format: "%02X", channel)) "
                                          + "at \(Date()) ---")
                self.write(Command.status0)
                try? await Task.sleep(for: .milliseconds(200))
                self.write(Command.syncUpToNow(channel: channel))
                try? await Task.sleep(for: .milliseconds(200))
                self.write(Command.fetch)
                // Drain until quiet (no new frame for ~1s) or an 8s backstop per channel — a real
                // stream answers within a second or two; an unsupported/empty channel just sits idle.
                var lastCount = self.rawCaptureLog.count
                var quiet = 0
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { break }
                    if self.rawCaptureLog.count == lastCount {
                        quiet += 1
                        if quiet >= 5 { break }
                    } else {
                        quiet = 0
                        lastCount = self.rawCaptureLog.count
                    }
                }
            }
            guard let self else { return }
            self.rawCaptureLog.append("# --- probe complete: \(self.rawCaptureLog.count) lines ---")
            self.probeStatus = "Done — \(self.rawCaptureLog.count) lines captured"
            self.probing = false
            self.captureRawFrames = false
            self.probeTask = nil
        }
    }

    /// One-time forensic history capture for "what is on the ring right now?" investigations.
    /// Reuses the SAME two-channel drain as `syncHistory(manual:)` so it does not change the primary
    /// decode path, but additionally records every write + notification into `rawCaptureLog` for
    /// offline mapping. This is intentionally explicit and user-driven — not tied to keepalive,
    /// auto-measure, or pull-to-refresh — so the normal workflow remains unchanged.
    func captureHistoricPull() {
        guard syncTask == nil, probeTask == nil, !capturingHistoricPull else { return }
        stopLiveMonitoring(scheduleStatusRefresh: false)
        historySyncTrigger = "historic-pull"
        captureRawFrames = true
        rawCaptureLog.removeAll()
        capturingHistoricPull = true
        historicPullStatus = "Starting one-time historic pull…"
        rawCaptureLog.append("# --- one-time historic pull started at \(Date()) ---")
        rawCaptureLog.append("# drains known history channels: 0x00 sleep + 0x03 all-day")
        rawCaptureLog.append("# use this capture to map what the ring emitted before another client drains it")
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.performHistoryDrain()
            self.rawCaptureLog.append("# --- one-time historic pull finished at \(Date()) ---")
            self.rawCaptureLog.append("# summary: \(self.lastDrainSummary ?? "no drain summary")")
            self.historicPullStatus = "Done — \(self.lastDrainSummary ?? "capture complete")"
            self.capturingHistoricPull = false
            self.captureRawFrames = false
        }
    }

    /// Full forensic sweep for iPhone -> Mac workflows: first drain the KNOWN history channels
    /// (`0x00` sleep + `0x03` all-day) with the normal history path, then probe a shortlist of
    /// UNKNOWN channel selectors into the SAME raw log so the Mac can decode both the proven and
    /// exploratory traffic from one exported artifact.
    func captureForensicSweep(_ candidates: [UInt8] = [0x02, 0x01, 0x04, 0x05, 0x08]) {
        guard syncTask == nil, probeTask == nil, !capturingHistoricPull, !capturingForensicSweep else { return }
        stopLiveMonitoring(scheduleStatusRefresh: false)
        historySyncTrigger = "forensic-sweep"
        captureRawFrames = true
        rawCaptureLog.removeAll()
        capturingForensicSweep = true
        forensicSweepStatus = "Starting forensic sweep…"
        rawCaptureLog.append("# --- forensic sweep started at \(Date()) ---")
        rawCaptureLog.append("# phase 1: drain known channels 0x00 sleep + 0x03 all-day")
        rawCaptureLog.append("# phase 2: probe unknown channel selectors for hidden history streams")
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.performHistoryDrain()
            self.rawCaptureLog.append("# --- known-channel drain complete: \(self.lastDrainSummary ?? "no drain summary") ---")
            self.forensicSweepStatus = "Known channels drained; probing unknown channels…"
            for channel in candidates {
                guard !Task.isCancelled else { break }
                await self.captureProbeChannel(channel: channel)
            }
            self.rawCaptureLog.append("# --- forensic sweep finished at \(Date()) ---")
            self.forensicSweepStatus = "Done — known channels + \(candidates.count) unknown-channel probes captured"
            self.capturingForensicSweep = false
            self.captureRawFrames = false
        }
    }

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
    let epochArchiveStore: EpochArchiveStore
    /// `writeChar` can outlive an actual usable link during reconnect churn, so connection state
    /// is part of the write gate too.
    private var canWriteCommands: Bool {
        peripheral.state == .connected && writeChar != nil
    }

    private let dataServiceUUID = CBUUID(string: OpenCircuitKit.Transport.dataServiceUUID)
    private let notifyUUID = CBUUID(string: OpenCircuitKit.Transport.notifyCharUUID)
    private let writeUUID = CBUUID(string: OpenCircuitKit.Transport.writeCharUUID)
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
    /// Rolling battery % samples for the TTE estimate (#86), **persisted per-ring** across
    /// reconnects/relaunches so the discharge slope isn't wiped each session — that wipe was why
    /// "time to empty" almost never appeared. Loaded in `init`, rewritten on every reading via the
    /// pure `BatteryTTE.record` (which noise-filters using the decoded charging byte, #61).
    private var batteryHistory: [BatteryTTE.Sample] = []
    private static let batteryHistoryCap = 60
    /// Read accessor for the TTE sample window (#86).
    var batteryTTESamples: [BatteryTTE.Sample] { batteryHistory }
    /// Per-ring UserDefaults key for the persisted TTE history (scoped like the epoch archive).
    private var batteryHistoryKey: String { "battery.tteHistory.v1.\(peripheral.identifier.uuidString)" }

    /// Rolling RISING samples while the ring is on the charger — the time-to-FULL counterpart of
    /// `batteryHistory` (#61). Persisted per-ring too (short-lived; clears on unplug). Fed via the
    /// pure `BatteryTTE.recordCharge`; consumed by `BatteryTTE.timeToFull`.
    private var batteryChargeHistory: [BatteryTTE.Sample] = []
    /// Read accessor for the time-to-full charge window (#61).
    var batteryChargeSamples: [BatteryTTE.Sample] { batteryChargeHistory }
    private var batteryChargeHistoryKey: String { "battery.chargeHistory.v1.\(peripheral.identifier.uuidString)" }

    // MARK: Diagnostics — raw-frame capture + epoch-archive export (tester triage, #111)
    //
    // The capture toggle (default OFF) records the ring's raw 0x47/0x4c/0x50/0x82/0x10 frames so a
    // tester on a new ring generation can hand us the bytes to decode. Separately `archivedEpochs`
    // exposes the persisted, decoded 0x4c history so the diagnostics export can show WHICH epochs were
    // drained — and the gaps where they weren't (the sleep-loss signal). Both feed `DiagnosticsReport`.

    /// UserDefaults toggle gating raw-frame capture (default OFF). Bound from DeviceInfoView.
    static let diagnosticsCaptureKey = "diagnostics.captureHistoryFrames"
    private var historyCapture = HistoryFrameCapture()
    private var historyCaptureKey: String { "diagnostics.historyCapture.v1.\(peripheral.identifier.uuidString)" }
    private var diagnosticsCaptureEnabled: Bool { UserDefaults.standard.bool(forKey: Self.diagnosticsCaptureKey) }

    /// Frames captured so far (drives the DeviceInfoView row).
    var diagnosticsFrameCount: Int { historyCapture.count }
    /// The decoded 0x4c epoch archive this ring has accumulated — the basis for the gap report.
    var archivedEpochs: [BulkRecord] { epochArchiveStore.load() }
    /// Raw-frame capture report (firmware header + per-frame hex). `redactMAC` masks all but the last
    /// octet for sharing (the MAC matters only for auth RE, not sleep triage).
    func frameCaptureReport(redactMAC: Bool) -> String {
        var fw = firmwareInfo
        if redactMAC, let m = fw.mac, m.count >= 2 { fw.mac = "··:··:··:··:··:" + String(m.suffix(2)) }
        return historyCapture.report(firmware: fw)
    }
    /// Clear the capture buffer + its persisted copy.
    func clearDiagnosticsCapture() {
        historyCapture.clear()
        UserDefaults.standard.removeObject(forKey: historyCaptureKey)
    }
    /// Record one raw frame when capture is on and the opcode is one we triage. Persists per-ring so a
    /// BACKGROUND overnight drain survives relaunch. Cheap no-op (UserDefaults bool read) when disabled.
    private func recordDiagnosticFrameIfEnabled(_ bytes: [UInt8]) {
        guard diagnosticsCaptureEnabled, historyCapture.recordIfRelevant(bytes) else { return }
        if let data = try? JSONEncoder().encode(historyCapture) {
            UserDefaults.standard.set(data, forKey: historyCaptureKey)
        }
    }

    init(peripheral: CBPeripheral, localStore: LocalStore? = nil) {
        self.peripheral = peripheral
        self.localStore = localStore
        // Scope the per-ring epoch archive to this ring's identifier (#multi-ring).
        self.epochArchiveStore = EpochArchiveStore(namespace: peripheral.identifier.uuidString)
        super.init()
        // Restore this ring's persisted battery history so the TTE estimate is available
        // immediately on reconnect instead of rebuilding a discharge slope from scratch (#86).
        if let data = UserDefaults.standard.data(forKey: batteryHistoryKey),
           let saved = try? JSONDecoder().decode([BatteryTTE.Sample].self, from: data) {
            self.batteryHistory = saved
        }
        if let data = UserDefaults.standard.data(forKey: batteryChargeHistoryKey),
           let saved = try? JSONDecoder().decode([BatteryTTE.Sample].self, from: data) {
            self.batteryChargeHistory = saved
        }
        // Restore this ring's persisted frame capture (#111) so a buffer built across a background
        // overnight drain survives relaunch and is exportable in the morning.
        if let data = UserDefaults.standard.data(forKey: historyCaptureKey),
           let saved = try? JSONDecoder().decode(HistoryFrameCapture.self, from: data) {
            self.historyCapture = saved
        }
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
        // #138: a ring drop mid raw-PPG calibration capture MUST fail the in-flight capture. Without
        // this the fixed-duration `calibrationStopTask` survives teardown and still fires
        // `success: true` on whatever partial/zero frames arrived, so the flow advances to upload a
        // bogus (or empty) capture. Route through the (previously dead) failure branch so the awaiting
        // `startPPGCalibrationCapture` throws "ring disconnected". Do this FIRST, before the task
        // cancels below, so any device-status refresh it schedules is torn down with the rest. Gated
        // on `calibrationCapturing`, so a NORMAL finish (which already cleared the flag and resumed
        // the continuation) is untouched — this only fires for a genuine mid-capture teardown.
        if calibrationCapturing {
            finishCalibrationPPGCapture(success: false)
        }
        // Persist the charging inference BEFORE cancelling tasks (#60): the session is about
        // to be nil-ed by the scanner; ContentView reads from UserDefaults during the
        // reconnect-backoff window so the hint stays live while reconnecting.
        UserDefaults.standard.set(inferredCharging, forKey: Self.inferredChargingKey)
        flushDrainedToArchive()   // a sync may be in flight — bank its pages before we cancel it (#119)
        monitorTask?.cancel(); monitorTask = nil
        keepaliveTask?.cancel(); keepaliveTask = nil
        autoMeasureTask?.cancel(); autoMeasureTask = nil
        postSyncStatusTask?.cancel(); postSyncStatusTask = nil
        streamWatchdogTask?.cancel(); streamWatchdogTask = nil
        syncTask?.cancel(); syncTask = nil
        rssiPollTask?.cancel(); rssiPollTask = nil   // Find My Ring RSSI poll (#96)
        endDrainAssertion()   // a cancelled drain must not leak its assertion (#119)
        monitoring = false
        livePreparing = false
        syncing = false
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
        guard monitorTask == nil else { return }
        // Live and history sync can't coexist (ring is one mode at a time). Cancel any
        // in-flight sync so the ring is free to enter live mode.
        syncTask?.cancel(); syncTask = nil
        syncing = false
        monitoring = true
        monitoringStartedAt = Date()
        livePreparing = true
        if clearStaleValue {
            // Fresh user read — don't let a stale value look live (#45 C). Clear BOTH metrics: an
            // old liveSpO2 lock (never cleared while monitoring) would otherwise masquerade as live
            // before the ring enters SpO2 mode, skipping preparing/measuring, and count as a lock at
            // the deadline check so an off-finger read never surfaces the failure banner (#125).
            liveHR = nil; liveHRAt = nil
            liveSpO2 = nil; liveSpO2At = nil
        }
        liveHRTrend.removeAll()   // fresh convergence window
        liveHRWarmup = nil
        flushDrainedToArchive()   // an in-flight sync just cancelled above — bank its pages before the wipe (#119)
        bulkRecords.removeAll()   // any pages we drain below land here (don't lose them)
        bulkFinalized = false
        drainSawPage = false
        drainDone = false
        // Quick live reads no longer open a synthetic history session first. The device log showed
        // frequent reads repeatedly entering through `syncAll` (`02 .. ff ff ff ff ..`) before live
        // mode, entangling dense sampling with history/open-state churn. Overnight/background reads
        // still open at NOW so the real backlog drains (§3); quick reads jump straight into live
        // mode and only commit any pages that happen to arrive anyway.
        let syncOpen: [UInt8]? = quickLiveRead ? nil : Command.syncUpToNow()
        monitorTask = Task { [weak self] in
            // 1. Init + open the sync session at `syncOpen`.
            // `status0` elicits the `81 00` auth challenge; the didUpdateValue handler answers it
            // reactively with the SM3 auth (#54) before `syncOpen` opens the data session.
            let startup = [Command.status0] + (syncOpen.map { [$0] } ?? [])
            for cmd in startup {
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
            if syncOpen != nil { s0.write(Command.fetch) }
            // Drain backstop in 500 ms ticks. A quick read starts with a short ~3 s cap so a
            // silent ring can't starve the HR poll (#45); the overnight path uses the full ~15 s.
            // The shared quiet-exit (3 quiet ticks ≈ 1.5 s after the last page) ends a real drain.
            // BUT a quick read must NOT cut off an in-flight backlog: entering live mode while
            // 0x4c pages are still streaming (!drainDone, no quiet beat yet) leaves HR stuck at
            // the warm-up sentinel (8). So if the short cap is reached mid-stream, promote it to
            // the full cap and let the quiet-exit finish the drain — the short cap then only bites
            // a genuinely silent ring (the common no-backlog case still exits at ~1.5 s, unchanged).
            var cap = quickLiveRead ? 0 : 30   // quick reads skip the explicit history-open drain
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
            let modeCmd = s0.liveMode == .hr ? Command.liveHRMode : Command.liveSpO2Mode
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

    /// Idle keepalive — what makes OpenCircuit a *primary* tracker rather than an
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
            // Once per connected session: re-stage last night from the persisted archive, so epochs that
            // were banked by `flushDrainedToArchive` (an interrupted drain) but never staged into a
            // summary still surface — merge-protected, so it can only grow a fuller night (#119).
            if let self, !self.didRestageFromArchive {
                self.didRestageFromArchive = true
                self.restageFromArchive()
            }
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
                if self.ready, !self.monitoring, !self.livePreparing, self.syncTask == nil, !self.calibrationCapturing {
                    self.maybeRequestDeviceStatusRefresh(reason: "idle keepalive")
                    // Connected+idle: either drain the ring's 0x4c history on a cadence
                    // (`evaluatePeriodicDrain` — shared with the background BLE-wake path,
                    // #119), or just keep the link warm.
                    if !self.evaluatePeriodicDrain(trigger: nil) {
                        if self.isInSleepWindow {
                            self.write(Command.statusQuery)  // D0 00 00 → 0x50: keep warm WITHOUT walking the history pointer
                        } else {
                            self.write(Command.fetch)        // 07 00 00 → fresh 0x10/0x87 descriptor (steps/temp/battery)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(self.keepaliveInterval))
            }
        }
    }

    /// One shot of the periodic-drain policy — shared by the keepalive loop (whose `Task.sleep`
    /// cadence only runs while the process has runtime) and the background BLE-event wake path
    /// (`maybeDrainOnBackgroundWake`, #119). Returns true when a drain was started.
    ///
    /// Gated on `gotDataFrame` so we never poke a non-streaming ring (#54). The cadence clock is
    /// persisted (`EpochArchiveStore.lastDrainAt`), so a fresh session drains shortly after
    /// (re)connect (lastDrainAt nil ⇒ due) yet a flapping link can't re-drain more often than
    /// the interval.
    ///
    /// OVERNIGHT-QUIET (#111/#119): inside the sleep window we DO NOT drain at all. Each
    /// drain's cursor≈now open + per-channel `0x07` fetch contends the ring's single resume
    /// pointer; cadenced overnight drains were thought safe (only the old 60 s temp `fetch`
    /// heartbeat shredded the night), but Randy's 6/30 capture disproved it — draining every
    /// ~30 min, the ring still stopped handing off 0x4c sleep history at ~02:35 and lost the
    /// back ~3 h. So overnight we keep the link warm with `0xD0` statusQuery (status only —
    /// does NOT walk the pointer) and let the night accumulate UNTOUCHED on the ring (it
    /// buffers for days), then drain the whole night in ONE pass at WAKE: when `night` flips
    /// false, `lastDrainAt` is hours old ⇒ `isDue` ⇒ `shouldDrain` ⇒ one catch-up drain.
    /// TRADEOFFS (honest): (1) overnight skin temp is ELIMINATED, not merely lower-res —
    /// statusQuery elicits no 0x10/0x87 descriptor, so the only night temp is at wake, and
    /// the #41 sleep wear-gate reverts to MOTION-ONLY overnight (can re-expose the
    /// still/charging-reads-as-sleep over-count). (2) the phone banks NOTHING overnight, so
    /// a co-installed official RingConn app that syncs first in the morning can take the
    /// WHOLE night (shared resume pointer, §3). Accepted because the night's SLEEP data —
    /// the reported loss — is recovered; revisit if temp/over-count regress on device.
    @discardableResult
    private func evaluatePeriodicDrain(trigger: String?) -> Bool {
        // `!workoutHolding`: never open the history channel during an active workout (native sport
        // session OR live-HR-poll workout) — it contends with the busy ring (#90 regression fix).
        guard ready, !monitoring, !livePreparing, !workoutHolding, syncTask == nil else { return false }
        let saver = UserDefaults.standard.bool(forKey: Self.batterySaverEnabledKey)
        let night = isInSleepWindow
        let cadenceDue = gotDataFrame
            && HistoryDrainCadence.isDue(lastDrainAt: epochArchiveStore.lastDrainAt,
                                         now: Date(), isNight: night, batterySaver: saver)
        guard HistoryDrainCadence.shouldDrain(manual: false, inSleepWindow: night, isDue: cadenceDue)
        else { return false }
        ringLog.notice("sync: periodic history drain (\(night ? "night?!" : "daytime / wake catch-up", privacy: .public), trigger=\(trigger ?? "keepalive", privacy: .public))")
        pendingDrainTrigger = trigger
        syncHistory()
        // Never leave the trigger dangling: if syncHistory declined after all (its gates re-check
        // the same state, so today this can't diverge — this guards future gate changes), a LATER
        // unrelated drain must not inherit this wake's attribution.
        if syncTask == nil { pendingDrainTrigger = nil; return false }
        return true
    }

    /// Drain-on-wake (#119): while the app is suspended, an unsolicited BLE event (the ring's
    /// ~2.5 min `0x11` heartbeat) is often the ONLY runtime we get (~10 s per event), and the
    /// keepalive loop's `Task.sleep` is frozen — its cadence cannot fire on time. So the drain
    /// cadence is ALSO evaluated on the wake event itself; once a drain starts, its own 0x4c
    /// pages keep renewing the wake window until it completes, and `performHistoryDrain` holds
    /// a background-task assertion across the gaps. In the foreground this defers to the
    /// keepalive loop (same cadence, no double-drain — `syncHistory` is `syncTask`-guarded
    /// regardless).
    private func maybeDrainOnBackgroundWake(trigger: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        // Refresh the night window BEFORE the gate check (self-throttled to ≤ every 30 min, so
        // usually instant). The keepalive loop always refreshes before evaluating; this path must
        // too — on the first wake after a long suspension the cached `nightWindow` can be hours
        // stale, and evaluating against yesterday's window could drain INSIDE tonight's (#111).
        Task { [weak self] in
            guard let self else { return }
            await self.refreshNightWindowIfNeeded()
            self.evaluatePeriodicDrain(trigger: trigger)
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
    /// measurement, a sync, the live-enter drain, or a workout (which owns the link and must not be
    /// torn down by an auto-measure firing mid-session).
    private var idleForAutoMeasure: Bool {
        // `!isInSleepWindow`: an auto-measure enters live mode, which opens a sync and can advance the
        // ring's resume pointer (syncAll's pointer effect is the 🟡 backlog-shredder risk, PROTOCOL.md
        // §3) — exactly what we must avoid overnight so the night's backlog survives for one morning
        // sync. Overnight HR/SpO₂ come from the synced sleep epochs anyway, so nothing is lost.
        ready && !monitoring && !livePreparing && syncTask == nil && !workoutHolding && !calibrationCapturing && !isInSleepWindow
    }

    /// Next sleep between auto-measure cycles: the base interval while worn, exponentially backed
    /// off once the ring is inferred not-worn (#56). Pure policy lives in `AutoMeasureGate`.
    private var nextAutoMeasureInterval: TimeInterval {
        AutoMeasureGate.interval(base: Self.autoMeasureInterval,
                                 cap: Self.autoMeasureMaxBackoff,
                                 consecutiveNoLock: consecutiveAutoMeasureNoLock,
                                 rawSkinTempC: lastRawSkinTempC)
    }

    /// Skip the live-enter probe entirely this cycle (#56): a probe would only time out and burn
    /// battery. Skips when EITHER the ring reports **confirmed on-charger** (`charging`, decoded
    /// `[2]==0x04` 🟢 — #61, definitive, no temp needed) OR the older proxy fires (inferred
    /// not-worn AND a COLD raw skin temp — positive evidence; a missing temp falls back to probing
    /// so a sensor gap can't silently stop measuring). Re-wear/undock is caught when `charging`
    /// clears or the temp warms (the keepalive keeps both fresh), resuming measurement promptly.
    private var skipAutoMeasureProbe: Bool {
        if charging { return true }
        return appearsNotWorn && (lastRawSkinTempC.map { $0 < ActivityPeriod.wornMinTemperatureC } ?? false)
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
            // Bail if a user tap took ownership or switched the mode out from under us — don't fight
            // them. Same test-locked ownership model as `startMonitoring` (#125).
            if LiveMeasureOwnership.autoShouldStandDown(autoMeasuring: autoMeasuring,
                                                        monitoring: monitoring,
                                                        modeMatches: liveMode == mode,
                                                        calibrationCapturing: calibrationCapturing) {
                autoMeasuring = false
                return nil
            }
            if mode == .hr, liveHR != nil { locked = true; break }
            if mode == .spo2, liveSpO2 != nil { locked = true; break }
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
            nightWindow = w                                   // explicit schedule (HealthKit / manual) wins
        } else if let learned = learnedNightWindow(nightEndingNear: Date()) {
            // No explicit schedule (the default state): ADAPT the window to the user's REAL recent
            // sleep hours, learned from persisted nights. The fixed 22:30→06:30 default below
            // dropped ALL skin temp for anyone who sleeps later or shifts night to night (skin temp
            // is live-only — it rides the 0x10/0x87 descriptor, NOT the drainable history, so a
            // missed window can't be back-filled like HR/HRV/SpO₂). See SleepWindow.habitualInterval.
            nightWindow = learned
        } else if let interval = SleepWindow.interval(
            // No schedule AND too little history yet (< 3 nights). Fall back to a GENEROUS default
            // window (not the narrow 22:30→06:30): wide enough that a late/shifted sleeper isn't
            // clipped before the learned window kicks in. Cross-midnight aware (e.g. last night
            // 21:30 → today 10:00); a naive calendar-day slice would drop pre-midnight onset.
            bedMinutes: Self.tempFallbackBedMinutes,    // 1290 (21:30)
            wakeMinutes: Self.tempFallbackWakeMinutes,  // 600 (10:00)
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

    /// Generous no-schedule / no-history fallback window for skin-temp capture: bed 21:30, wake
    /// 10:00. Wider than the manual-schedule default (22:30→06:30) so a late or shifted sleeper
    /// isn't clipped before enough nights accrue for `learnedNightWindow` to take over.
    static let tempFallbackBedMinutes = 21 * 60 + 30   // 1290
    static let tempFallbackWakeMinutes = 10 * 60        // 600

    /// The user's HABITUAL sleep window learned from recent persisted nights' actual onset/wake, so
    /// skin-temp capture tracks when they REALLY sleep instead of a fixed clock default. Returns nil
    /// when there's no store or fewer than 3 usable nights (the caller falls back to the generous
    /// default above). Pure window math lives in `SleepWindow.habitualInterval` (unit-tested).
    private func learnedNightWindow(nightEndingNear date: Date) -> DateInterval? {
        guard let store = localStore else { return nil }
        let summaries = (try? store.recentSleepSummaries(limit: 21)) ?? []
        let cutoff = date.addingTimeInterval(-21 * 86_400)
        let recent = summaries.filter { $0.night >= cutoff }
        let onsets = recent.compactMap { $0.sleepOnset > .distantPast ? $0.sleepOnset : nil }
        let wakes = recent.compactMap { $0.sleepWake > $0.sleepOnset ? $0.sleepWake : nil }
        return SleepWindow.habitualInterval(onsets: onsets, wakes: wakes, nightEndingNear: date)
    }

    /// Whether `now` falls inside the user's sleep window — the gate that suppresses AUTOMATIC
    /// history drains overnight (see `syncHistory(manual:)`, the keepalive loop, and
    /// `idleForAutoMeasure`). A history open is `02 .. cursor≈now ..`, which advances the ring's
    /// SINGLE resume pointer (PROTOCOL.md §3 "Contention"); draining every ~90 min through the night
    /// kept advancing that pointer past the night, so by morning the ring had no backlog to hand off
    /// (device log 06-22: ~12 sleep epochs the WHOLE night, every drain `sleepSegs=0` → the stale
    /// Sleep card). The official app never syncs overnight — it does ONE big morning sync of the whole
    /// night — and this matches it. Prefers the resolved `nightWindow`; falls back to the stored
    /// manual/default schedule so the gate still holds before the async window resolves (e.g. a cold
    /// background drain). MANUAL user syncs bypass this entirely (user intent wins).
    var isInSleepWindow: Bool {
        if let w = nightWindow { return w.contains(Date()) }
        let d = UserDefaults.standard
        SleepScheduleDefaults.register(d)
        guard let w = SleepWindow.interval(
            bedMinutes: d.integer(forKey: SleepScheduleDefaults.bedMinutes),
            wakeMinutes: d.integer(forKey: SleepScheduleDefaults.wakeMinutes),
            nightEndingNear: Date()) else { return false }
        return w.contains(Date())
    }

    /// Persist decoded samples to the local store (the vitals dashboard reads from it, so
    /// data is always visible offline). The SyncCursor dedupes, so repeated calls are safe.
    private func persist(_ samples: [QuantitySample]) {
        guard let localStore, !samples.isEmpty else { return }
        let preview = try? localStore.previewIngest(samples)
        let ingested: [QuantitySample]
        do {
            ingested = try localStore.ingest(samples)
        } catch {
            let detail = "store save failed input=\(samples.count) error=\(error.localizedDescription)"
            observability.recordMetricEvent(source: "persist", detail: detail)
            ringLog.error("persist FAILED: \(detail, privacy: .public)")
            return
        }
        storedMetricSamples += ingested.count
        // TEMP DIAGNOSTIC (HR-not-recording investigation): how many of the samples HANDED to
        // ingest actually came back as stored. Paired with `hr-diag` above — if `hrSamplesPreIngest`
        // was >0 but `hrIngested` here is 0, `ingest`'s cursor/plausibility gate is still rejecting
        // them post-fix. Remove once the root cause is confirmed.
        let hrIn = samples.filter { $0.kind == .heartRate }.count
        if hrIn > 0 {
            let hrOut = ingested.filter { $0.kind == .heartRate }.count
            ringLog.notice("hr-diag: persist call hrIn=\(hrIn) hrIngested=\(hrOut)")
        }
        if let preview {
            let metrics = Dictionary(grouping: samples, by: \.kind).keys.map(\.rawValue).sorted().joined(separator: ",")
            let detail = "metrics=[\(metrics)] input=\(preview.inputCount) plausible=\(preview.plausibleCount) fresh=\(preview.freshCount) stored=\(ingested.count) dup=\(preview.duplicateCount) invalidTime=\(preview.invalidTimestampCount) invalidHR=\(preview.invalidHeartRateCount)"
            observability.recordMetricEvent(source: "persist", detail: detail)
            ringLog.notice("persist-diag: \(detail, privacy: .public)")
        }
    }

    /// Record a DAYTIME skin-temp reading for the Trends intraday chart only (`StoredDaytimeTemp`)
    /// — deliberately a SEPARATE table from the nightly `.temperature` path above, so this never
    /// touches the nightly cycle-tracking baseline or Apple Health (#41's guarantee is unchanged).
    private func persistDaytimeTemperature(_ celsius: Double, at time: Date) {
        guard let localStore else { return }
        try? localStore.recordDaytimeTemperature(celsius, at: time)
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
        let segs = BulkSleep.stagedSegments(from: records, baseline: personalSleepBaseline(from: records))
        // A stitched night carries one `inBed` segment PER fragment (sorted by start), so gate on the
        // WHOLE-NIGHT envelope — earliest onset to latest wake — not just the first fragment. Testing
        // `first(where: .inBed)` would judge the night by its earliest fragment's midpoint and wrongly
        // reject (→ drop the whole night) an early-evening-onset night whose first fragment alone has a
        // daytime midpoint. (Adversarial review.)
        let inBeds = segs.filter { $0.stage == .inBed }
        guard let lo = inBeds.map(\.start).min(), let hi = inBeds.map(\.end).max() else { return segs }
        return SleepWindow.isOvernightBlock(start: lo, end: hi) ? segs : []
    }

    /// The user's rolling deep-sleep HR baseline from recent stored nights (RingConn is believed to key
    /// its staging off multi-day personalized baselines — 🟡 probable, APK RE, see memory
    /// `ringconn-sleep-is-on-device`; we historically used single-night percentiles only). It anchors
    /// the Deep band so a globally-elevated night isn't mislabeled as having normal Deep (see
    /// `SleepStaging.PersonalBaseline`). Uses the recent stored nights (count-bounded, up to 7 — NOT a
    /// strict time window), nil until ≥3 PRIOR nights exist, so early nights stage exactly
    /// as the single-night classifier — and the median is robust to one outlier (fever) night.
    ///
    /// EXCLUDES the night being staged (its start-of-day, derived from the motion block) — exactly as
    /// the skin-temp rolling baseline above does. Without this, a re-sync of the SAME night would fold
    /// tonight's own (already-persisted) deep HR into its own baseline: staging would become
    /// non-idempotent across drains and the baseline would be contaminated by the very night it
    /// reclassifies. Excluding it makes a night's staging depend only on SETTLED prior nights, so it is
    /// deterministic and the Sleep card can't diverge from what was written to Health. (Code review.)
    private func personalSleepBaseline(from records: [BulkRecord]) -> SleepStaging.PersonalBaseline? {
        guard let localStore else { return nil }
        let stagedDay = BulkSleep.mainSleep(from: records).map { Calendar.current.startOfDay(for: $0.start) }
        let recentDeepHR = ((try? localStore.recentSleepSummaries(limit: 8)) ?? [])
            .filter { stagedDay == nil || Calendar.current.startOfDay(for: $0.night) != stagedDay! }
            .prefix(7)
            .map(\.hrDeep)
        return SleepStaging.PersonalBaseline.fromRecentDeepHR(Array(recentDeepHR))
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
            // Actual sleep onset/wake (first…last asleep epoch) — narrower than the in-bed window by
            // the sleep latency, so the card can show "fell asleep at X" instead of conflating it with
            // bedtime. nil → unknown (no asleep block); persisted as distantPast and the card falls back.
            let sleep = SleepStaging.sleepWindow(stagedSegments)
            let extras = computeSleepExtras(summary: summary, start: start, end: end,
                                            store: localStore, records: nightRecords)
            try? localStore.saveSleepSummary(summary, night: start, inBedStart: start, inBedEnd: end,
                                             sleepOnset: sleep?.onset ?? .distantPast,
                                             sleepWake: sleep?.wake ?? .distantPast,
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
    // The ring's onboard step field (descriptor [4:6]) is the ring's CURRENT DAY total. To avoid
    // double-counting while connected we persist the last raw value AND the day it was seen in
    // UserDefaults, then fold repeated same-day reads into deltas. Crucially, once the day changes
    // the next raw value is already "today so far" and must be credited in full so an afternoon
    // reconnect still recovers the morning's steps. The per-day TOTAL lives in StoredDaily via
    // addDailySteps.

    // Per-ring (#multi-ring): namespaced by the ring's CoreBluetooth identifier so a second ring's
    // onboard counter is never diffed against the first ring's baseline (which would yield garbage
    // step deltas on a ring switch). `deviceKey` is the same id RingScanner remembers and migrates
    // the legacy un-namespaced state onto.
    private var deviceKey: String { peripheral.identifier.uuidString }
    private var lastRawStepsKey: String { "steps.lastRawValue.\(deviceKey)" }    // Int: last raw [4:6] counter
    private var lastRawStepsDayKey: String { "steps.lastRawDay.\(deviceKey)" }   // Date: start-of-day it was observed
    private var lastStepSampleAtKey: String { "steps.lastSampleAt.\(deviceKey)" } // Date: wall-clock of that reading

    /// Last raw counter we recorded, or nil if we've never seen one (first run / cleared). Stored
    /// as an object so a legitimate 0 reading is distinguishable from "unset".
    private var persistedLastRawSteps: Int? {
        UserDefaults.standard.object(forKey: lastRawStepsKey) as? Int
    }
    /// Start-of-day the persisted raw counter was observed (for midnight-rollover detection).
    private var persistedLastRawStepsDay: Date? {
        UserDefaults.standard.object(forKey: lastRawStepsDayKey) as? Date
    }
    /// Wall-clock time of that same last reading — the window START for the NEXT timestamped
    /// step delta (#steps-history), so a steady stream of same-day descriptor reads produces
    /// narrow, accurately-timed snapshots instead of crediting steps to the whole elapsed day.
    private var persistedLastStepSampleAt: Date? {
        UserDefaults.standard.object(forKey: lastStepSampleAtKey) as? Date
    }
    private func persistStepRawState(raw: Int, day: Date, sampleAt: Date) {
        UserDefaults.standard.set(raw, forKey: lastRawStepsKey)
        UserDefaults.standard.set(day, forKey: lastRawStepsDayKey)
        UserDefaults.standard.set(sampleAt, forKey: lastStepSampleAtKey)
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
        // Ownership decision lives in a pure, test-locked model (`LiveMeasureOwnership`) so the
        // "don't fight the current owner" contract can't silently regress (#125).
        let action = LiveMeasureOwnership.decide(monitoring: monitoring,
                                                 userInitiated: userInitiated,
                                                 userMeasuring: userMeasuring,
                                                 workoutHolding: workoutHolding,
                                                 sameMode: liveMode == mode)
        switch action {
        case .takeover:
            // Promote an auto/background live read into an explicit user measurement so the
            // progress/failure UX and deadline belong to the tap instead of the previous owner.
            autoMeasuring = false
            stopLiveMonitoring(scheduleStatusRefresh: false)
            liveMode = mode
            userMeasuring = true
            userMeasureFailed = false
            userMeasureFailedMessage = nil
            startLiveMonitoring(quickLiveRead: quickLiveRead, clearStaleValue: true)
        case .rearm:
            rearmUserMeasure()   // re-poll on demand; auto leaves it alone
        case .ignore:
            break                // auto refresh in the same mode — don't disturb a converging read
        case .switchMode(let armDeadline):
            // `armDeadline` is set iff the switch is user-initiated, so it doubles as the stale-clear
            // signal: a user switch drops the target mode's prior lock (#125), an auto switch keeps
            // its last value on screen until the new one re-locks.
            setLiveMode(mode, clearStaleValue: armDeadline)
            // `userMeasuring` is already true when the switch is user-initiated (a user tap only
            // reaches here having skipped the takeover branch, which falls through only when a user
            // measurement was already in flight). Just re-arm the deadline for the new mode (#125).
            if armDeadline { armUserMeasureDeadline() }
        case .start(let clearStale):
            liveMode = mode
            // User-initiated: arm the timeout UX state so the poll loop can self-terminate (#55).
            if userInitiated {
                userMeasuring = true
                userMeasureFailed = false
                userMeasureFailedMessage = nil
            }
            startLiveMonitoring(quickLiveRead: quickLiveRead, clearStaleValue: clearStale)
        }
    }

    /// Take exclusive ownership of the live-HR link for a workout, then start a fresh HR cycle the
    /// workout owns. Fixes the contention where a workout begun while the ring was already
    /// monitoring (a periodic auto-measure, or a lingering Measure) would RIDE that foreign cycle —
    /// which then tears itself down (`stopLiveMonitoring`) on lock/timeout, silently killing the
    /// workout's HR for the rest of the session. We:
    ///   1. set `workoutHolding` so `idleForAutoMeasure` is false → auto-measure won't start while
    ///      the workout runs (and can't grab the link between our stop+start below), and
    ///   2. clear `autoMeasuring` so a concurrent `autoMeasureOnce` awaiting its lock can't call
    ///      `stopLiveMonitoring()` on our cycle when it wakes (its teardown is gated on that flag),
    ///   3. drop any foreign cycle and start our OWN — `monitoringStartedAt` resets to now.
    /// `@MainActor` makes this run atomically relative to the auto-measure task's await points.
    func beginWorkoutHR() {
        workoutHolding = true
        autoMeasuring = false
        if monitoring { stopLiveMonitoring() }   // drop any auto/user-measure cycle we'd otherwise ride
        startMonitoring(mode: .hr, userInitiated: false, quickLiveRead: true)   // fresh, workout-owned cycle
    }

    /// Release the workout's hold and stop its live cycle. Auto-measure resumes on its own cadence.
    func endWorkoutHR() {
        workoutHolding = false
        stopLiveMonitoring()
    }

    // MARK: - Native sport / workout mode (#90)

    /// True while a native workout is running (SportStart..SportStop), during which the ring
    /// pushes `0x4e` HR+steps frames (~10 s) instead of answering the `0x95` live-HR poll.
    private(set) var sportSessionActive = false
    /// Ring-counted steps during the current/last native workout (Σ of `0x4e` byte[6], #90).
    private(set) var sportSteps = 0
    /// True for the WHOLE workout (`beginSportSession`..`endSportSession`), whether HR is coming from
    /// the native `0x4e` sport stream OR the `0x15` live-poll fallback below. `collectHRSnapshot`
    /// gates on THIS (not `sportSessionActive`) so the workout keeps recording HR after a fallback.
    private(set) var workoutHRActive = false
    /// Set true once the ring streams its FIRST `0x4e` frame this session — stops the SportStart
    /// retry watchdog. Cleared at each `beginSportSession`.
    private var sportGotFirstFrame = false
    /// True once the ring proved it won't stream `0x4e` and we switched the workout to the `0x95`
    /// live-HR poll. `endSportSession` tears that poll down.
    private var sportUsingLivePollFallback = false
    /// Timestamp of the most recent `0x4e` sport frame (any frame, even a warm-up one). The
    /// whole-session watchdog falls back to the live-HR poll if the stream STALLS after starting —
    /// the ring streaming one frame then going silent must not leave the workout HR-less (#90).
    private var lastSportFrameAt: Date?
    /// Set by the `0x86` handler when the ring REJECTS a `0x06`-family command (`86 <err> …`, err≠0).
    /// The enter loop resets it before each SportStart and bails to the fallback the instant a `86 fd`
    /// comes back — on-device the ring rejects SportStart outright (86 fd 7b, even 13 s after `06 00`),
    /// so waiting the full retry budget just delays real HR. `86 00 86` (accept) leaves it false.
    private var sportStartRejected = false
    /// Set by the `0x86` handler when the ring ACCEPTS a `0x06`-family command (`86 00 86`). Ground
    /// truth (yoga snoop 2026-07-09): the ring answers `06 03` with its accept/reject verdict in
    /// ~0.4 s, THEN an accepted start streams its first `0x4e` ~8 s later. So the enter loop watches
    /// this to tell "accepted, waiting for the stream" from "ignored (no `86` — the ring wasn't idle)"
    /// and stop burning the whole stream-watch window on a `06 03` that never landed (#174).
    private var sportStartAccepted = false
    /// The SportStart-with-retry watchdog task (re-sends SportStart until the ring starts streaming,
    /// then falls back to the live-HR poll if it never does).
    private var sportStartTask: Task<Void, Never>?
    /// Wall-clock when the current sport-enter reach-idle sequence began. `awaitIdleDescriptor` only
    /// trusts a descriptor mode reading stamped at/after this, so a STALE pre-live-HR "idle" can't be
    /// mistaken for the ring having returned to idle now (#174).
    private var reachIdleStartedAt = Date.distantPast

    // Sport-enter reach-idle bounds (#174). The old reach-idle reused the FULL history drain and was
    // SKIPPED entirely when a sync was already running; the fast path below reaches idle without a drain
    // when the ring is idle / auto-reverts, and awaits (never skips) an in-flight sync, so the common
    // case starts in ~10–15 s. A genuinely non-idle ring with a real backlog still falls back to the
    // full lossless drain (correct: it syncs the un-synced night) rather than risk losing epochs.
    /// Overall wall-clock budget for the reach-idle WAITS (in-flight-sync + fast-path descriptor probe)
    /// before we give up the fast path. The lossless recovery drain runs to its own natural end.
    private static let sportReachIdleBudget: TimeInterval = 18
    /// Fast-path descriptor-probe window when the ring was already idle (no live poll running): give
    /// the `0x10`/`0x87` mode byte a moment to confirm idle before `06 03`. Also the post-drain confirm.
    private static let sportFastPathIdle: TimeInterval = 5
    /// Fast-path window when we JUST stopped a live-HR poll (ring is in live-HR, unlikely to be idle):
    /// a brief probe still captures how fast — if at all — the ring auto-reverts to idle, then we go
    /// straight to the full drain-to-idle.
    private static let sportFastPathAfterLive: TimeInterval = 2
    /// After an ACCEPTED `06 03` (`86 00 86`), how long to wait for the ring's first `0x4e` stream
    /// frame (ground truth ~8 s). Separate from the reach-idle budget — once accepted, the ring is
    /// idle and streaming is just a matter of time.
    private static let sportFirstFrameWait: TimeInterval = 14

    /// The ring's work-mode as reported by the most recent `0x10`/`0x87` descriptor byte[2]:
    /// `0x02`/`0x03` idle, `0x04` on charger, `0x06` sport active (others, e.g. a live-read mode,
    /// unenumerated). Drives the sport-enter fast path — `06 03` is accepted only from idle (#174).
    private var lastDescriptorMode: UInt8?
    /// When `lastDescriptorMode` was last set — used to reject stale idle readings (#174).
    private var lastDescriptorModeAt = Date.distantPast

    /// `0x02`/`0x03` are the ring work-modes `06 03` SportStart is accepted from (yoga snoop
    /// 2026-07-09: descriptor mode `0x03` → `06 03` → `86 00 86`). `0x04` is on-charger, `0x06` sport.
    private static func isIdleMode(_ mode: UInt8) -> Bool { mode == 0x02 || mode == 0x03 }

    /// Outcome of one `06 03` SportStart attempt (#174).
    private enum SportStartResult: Equatable {
        case streaming     // a 0x4e frame arrived — native sport HR is live
        case rejected      // `86 fd …` — the ring refused (not idle)
        case ignored       // no `86` verdict at all — the command was dropped from a non-idle state
        case silentAccept  // `86 00 86` but no 0x4e stream materialised within the wait
    }

    /// Enter the ring's native workout mode for `typeByte` (`WorkoutSportType.firmwareByte`). The
    /// ring then STREAMS `0x4e` HR+steps frames unsolicited — the `0x4e` handler acks each, routes
    /// HR into `liveHR`/`liveHRAt` (so the workout's existing HR pipeline + live UI pick it up), and
    /// sums steps into `sportSteps`. If the ring never streams `0x4e` (or the stream stalls), the
    /// watchdog falls back to the `0x95` live-HR poll (`fallBackToLivePoll`) so the workout still
    /// records HR; `workoutHRActive` (not `sportSessionActive`) is what keeps `collectHRSnapshot`
    /// recording across that switch.
    func beginSportSession(typeByte: UInt8) {
        sportSessionActive = true
        workoutHRActive = true   // records HR for the whole workout (0x4e stream OR live-poll fallback)
        // Take the shared "a workout owns the ring" hold so the SAME contention gates that already
        // honor a live-HR-poll workout (`beginWorkoutHR`) also defer during a NATIVE sport session.
        // Regression fix (#90): the sport-mode path set only `sportSessionActive`, which no gate
        // checked, so a mid-workout auto-measure / device-status refresh / periodic-or-foreground
        // history drain would open the busy ring's history channel → "no frames received" AND could
        // knock the ring's `0x4e` sport stream off, starving the workout's HR. Unlike `beginWorkoutHR`
        // this must NOT start a `0x95` live poll up front (the ring streams `0x4e` here); we set the
        // hold directly and only start the poll if the fallback below fires.
        workoutHolding = true
        sportSteps = 0
        liveHR = nil
        liveHRAt = nil
        sportGotFirstFrame = false
        sportUsingLivePollFallback = false
        lastSportFrameAt = nil
        sportStartRejected = false
        monitoringStartedAt = Date()   // gate: only in-session locks seed the workout (WorkoutHRGate)
        // Enter sport the OFFICIAL APP's way (ground truth: 1-hour Gentle Yoga snoop, 2026-07-09,
        // captures/workout_yoga_20260709.zip). The app enters `06 03` from clean POST-SYNC IDLE and sends
        // `06 00` ONLY to STOP — never before a start. Our `86 fd` rejection came from sending `06 00`
        // (to exit the dashboard's live-HR mode) right before `06 03`; and `06 03` sent directly from
        // live-HR mode was silently IGNORED. FIX: reach idle the app's way — a history SYNC (live-HR and
        // history sync are mutually exclusive, so the drain forces the ring out of live-HR → idle) — then
        // `06 03` with NO `06 00` anywhere. If the ring still refuses, fall back to the live-HR poll so
        // the workout still records (`workoutHRActive` stays true across the switch).
        let wasMonitoring = monitoring   // were we in the dashboard's live-HR mode? (sizes the fast-path probe)
        if monitoring { stopLiveMonitoring(scheduleStatusRefresh: false) }
        sportStartTask?.cancel()
        sportStartTask = Task { [weak self] in
            guard let self else { return }
            // Reach idle the app's way (ground truth: yoga snoop 2026-07-09) — the ring accepts `06 03`
            // ONLY from idle (descriptor mode 0x02/0x03). We NEVER send `06 00` before `06 03` (that was
            // the old `86 fd` root cause). BOUNDED so a backlogged/busy ring can't hang the start (#174):
            //   attempt 1 — await any in-flight sync (it lands the ring in idle when it finishes, so don't
            //               SKIP it) then let the descriptor confirm idle (already-idle / auto-reverted).
            //   attempt 2 — force the transition with a bounded single-channel sync-to-idle (opening a
            //               sync kicks the ring out of live-HR), then confirm idle.
            // Whole thing capped by `sportReachIdleBudget`; on failure we fall back to the `0x95` poll so
            // the workout still records HR (`workoutHRActive` stays true across the switch).
            self.reachIdleStartedAt = Date()
            let deadline = self.reachIdleStartedAt.addingTimeInterval(RingSession.sportReachIdleBudget)
            var streaming = false
            for attempt in 1...2 {
                guard self.sportSessionActive, !self.sportGotFirstFrame, !Task.isCancelled else { return }
                var idleConfirmed = false
                if attempt == 1 {
                    await self.awaitInFlightSyncForIdle(deadline: deadline)   // #174 #3 — don't skip a running sync
                    guard self.sportSessionActive, !self.sportGotFirstFrame, !Task.isCancelled else { return }
                    let probe = wasMonitoring ? RingSession.sportFastPathAfterLive : RingSession.sportFastPathIdle
                    // Anchor the probe window to NOW (not task start): `awaitInFlightSyncForIdle` may have
                    // just spent several seconds waiting out a sync, and that wait must not eat the probe —
                    // otherwise the just-finished sync leaves the ring idle but we never confirm it and do a
                    // redundant full drain (defeating the #3 await-the-sync mechanism).
                    idleConfirmed = await self.awaitIdleDescriptor(
                        deadline: min(deadline, Date().addingTimeInterval(probe)),
                        reason: "fast-path")
                } else {
                    // Not idle after the fast path: force the ring out of live-HR with a FULL, LOSSLESS
                    // drain to its natural end (the proven recovery). We do NOT cut it short — a partial
                    // drain would ack-and-discard the streamed remainder and truncate an un-synced night
                    // (#119). Skipped overnight; `runGuardedHistoryDrain` also no-ops if a sync is running
                    // (attempt 1 already awaited it). After it the ring is idle, so confirm briefly (the
                    // drain may have run past `deadline`; use a fresh short window) then always try `06 03`.
                    if !self.isInSleepWindow {
                        await self.runGuardedHistoryDrain(trigger: "sport-enter")
                    }
                    guard self.sportSessionActive, !self.sportGotFirstFrame, !Task.isCancelled else { return }
                    idleConfirmed = await self.awaitIdleDescriptor(
                        deadline: Date().addingTimeInterval(RingSession.sportFastPathIdle), reason: "post-drain")
                    ringLog.notice("sport: SportStart retry after full drain-to-idle (idleConfirmed=\(idleConfirmed))")
                }
                guard self.sportSessionActive, !self.sportGotFirstFrame, !Task.isCancelled else { return }
                // Attempt 1 only fires `06 03` with POSITIVE idle confirmation — a `06 03` from a non-idle
                // ring is ignored/rejected and just wastes the watch window, so fall straight to the drain.
                // Attempt 2 always tries: the drain likely reached idle even if the descriptor read lagged.
                if attempt == 1, !idleConfirmed {
                    ringLog.notice("sport: fast path didn't confirm idle — full drain-to-idle next")
                    continue
                }
                // One-writer rule (#174): never inject `06 03` into a link a sync still owns. A foreign
                // sync (morning reconnect / periodic overnight backlog) can outlast the reach-idle budget
                // that `awaitInFlightSyncForIdle` is bounded by; `runGuardedHistoryDrain` then no-ops on
                // its `syncTask == nil` guard, so without this check attempt 2 would write SportStart into
                // the still-active drain. Break to the poll fallback, which takes the link over cleanly
                // (`startLiveMonitoring` cancels the sync AFTER banking its captured pages — lossless).
                if self.syncTask != nil {
                    ringLog.notice("sport: a sync still owns the link after reach-idle — falling back to poll")
                    break
                }
                let result = await self.sendSportStartAndClassify(typeByte: typeByte)
                switch result {
                case .streaming:
                    streaming = true
                case .rejected:
                    ringLog.notice("sport: SportStart rejected (86 fd) on attempt \(attempt)")
                case .ignored:
                    ringLog.notice("sport: SportStart got no 86 (ignored — ring not idle) on attempt \(attempt)")
                case .silentAccept:
                    // `86 00 86` but no 0x4e — the ring took the command from idle yet won't stream on
                    // this link. Retrying won't change that; fall straight to the poll fallback.
                    ringLog.notice("sport: SportStart accepted but no 0x4e stream — falling back to poll")
                }
                // Stop retrying on success (streaming) or a genuine-accept-but-no-stream (retry can't
                // help). A reject/ignore means we weren't idle — attempt 2's full drain-to-idle is the fix.
                if result == .streaming || result == .silentAccept { break }
                guard self.sportSessionActive, !self.sportGotFirstFrame, !Task.isCancelled else { return }
                // A reject/ignore means we weren't idle — always fall through to attempt 2's full
                // lossless drain-to-idle, even if attempt 1's waits consumed the reach-idle budget.
            }
            guard self.sportSessionActive else { return }
            if !streaming {
                // The ring won't stream sport HR on this link (proven iOS behavior — 86 fd reject, no-86
                // ignore, or accepted-but-silent, each logged above). Fall back to the `0x95` live-HR poll
                // so the workout still records best-effort HR (#45) instead of nothing.
                await self.fallBackToLivePoll()
                return
            }
            // Streaming. Guard against an INTERMITTENT stream (one frame then silence — a documented iOS
            // failure mode): if `0x4e` stalls for well past its ~10 s cadence, switch to the live poll so
            // the rest of the workout still records. Re-entry is one-way (the poll then owns the link).
            while self.sportSessionActive, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard self.sportSessionActive, !Task.isCancelled else { return }
                if let last = self.lastSportFrameAt, Date().timeIntervalSince(last) > 35 {
                    ringLog.notice("sport: 0x4e stalled >35 s → falling back to live-HR poll")
                    await self.fallBackToLivePoll()
                    return
                }
            }
        }
    }

    /// Give up on the native `0x4e` sport stream and drive the workout's HR from the `0x95` live poll
    /// instead — the pre-#90 source (inconsistent under motion, but non-zero beats zero). `workoutHRActive`
    /// stays true so `collectHRSnapshot` keeps recording across the switch. Single-mode ring: we must
    /// return to IDLE with `06 00` before the poll's `06 01` — the ring rejects a direct `06 03`→`06 01`
    /// switch (the same reason the enter path leaves live-HR via `06 00` first). Idempotent + end-safe.
    private func fallBackToLivePoll() async {
        guard workoutHRActive, !sportUsingLivePollFallback else { return }   // ended, or already fell back
        sportSessionActive = false        // stop arming the 0x4e path
        sportUsingLivePollFallback = true
        autoMeasuring = false             // don't let a concurrent auto-measure tear the cycle down
        write(Command.sportStop)          // 06 00 00 — sport → IDLE before the live-HR mode switch
        try? await Task.sleep(for: .seconds(1))   // settle in idle so `06 01` is accepted
        guard workoutHRActive, sportUsingLivePollFallback else { return }   // workout ended during the settle
        startMonitoring(mode: .hr, userInitiated: false, quickLiveRead: true)
    }

    /// End the native workout mode; returns the ring-counted step total. Sends `SportStop` (`06 00 00`).
    @discardableResult
    func endSportSession() -> Int {
        sportStartTask?.cancel(); sportStartTask = nil   // stop the retry/fallback watchdog
        sportSessionActive = false
        workoutHRActive = false
        workoutHolding = false   // release the contention hold taken in beginSportSession
        if sportUsingLivePollFallback {
            sportUsingLivePollFallback = false
            if monitoring { stopLiveMonitoring(scheduleStatusRefresh: false) }   // stop the fallback poll
        }
        write(Command.sportStop)
        return sportSteps
    }

    // MARK: Sport-enter reach-idle (#174)

    /// If a history sync is ALREADY draining the ring, it will return the ring to idle when it
    /// finishes — so don't SKIP (the old `runGuardedHistoryDrain` guard's failure mode: a concurrent
    /// dashboard/reconnect sync made the enter fall back to the poll without ever reaching idle). Wait
    /// for the in-flight sync to clear (`finalizeSync` nils `syncTask`), bounded by `deadline`.
    private func awaitInFlightSyncForIdle(deadline: Date) async {
        guard syncTask != nil else { return }
        ringLog.notice("sport-enter: a sync is in flight — awaiting it to reach idle (#174)")
        while syncTask != nil, Date() < deadline {
            guard sportSessionActive, !sportGotFirstFrame, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Poll the device-status descriptor and wait until its work-mode byte reads IDLE (`0x02`/`0x03`)
    /// — the state the ring accepts `06 03` SportStart from (#174). Sends `07 00 00` (fetch) each tick
    /// to elicit a fresh `0x10`/`0x87` descriptor (which carries the mode byte even mid-sync — yoga
    /// snoop 2026-07-09). Returns true the instant a FRESH idle reading (stamped since this reach-idle
    /// began) is seen, false at the deadline. Cheap fast path: an already-idle ring confirms in ~1 tick
    /// with NO history drain, and this also captures how fast — if at all — the ring auto-reverts to
    /// idle after the live poll stops. In the sleep window we do NOT fetch (`07` walks the history
    /// pointer and truncates the night, #119) — we only watch passively, so it simply times out there.
    private func awaitIdleDescriptor(deadline: Date, reason: String) async -> Bool {
        while Date() < deadline {
            guard sportSessionActive, !sportGotFirstFrame, !Task.isCancelled else { return false }
            // A sync owns the link: we can neither FETCH (one-writer rule + `07` walks the history
            // pointer / competes with the #119-critical overnight drain) nor TRUST the mode byte (it
            // reads idle-ish 0x02/0x03 mid-sync — a sync is not a distinct mode — yet the ring rejects
            // `06 03` while draining). `awaitInFlightSyncForIdle` already awaited any sync we could wait
            // out, so if one still owns the link here, bail — the caller falls back to the poll (#174).
            if syncTask != nil { return false }
            if let mode = lastDescriptorMode, RingSession.isIdleMode(mode),
               lastDescriptorModeAt >= reachIdleStartedAt {
                ringLog.notice("sport-enter: descriptor confirms idle (mode=0x\(String(format: "%02x", mode))) via \(reason, privacy: .public)")
                return true
            }
            // Fetch elicits a fresh descriptor — but NOT in the sleep window (`07` walks the history
            // pointer and truncates the night, #119). `syncTask == nil` is guaranteed by the bail above.
            if !isInSleepWindow { write(Command.fetch) }   // 07 00 00 → fresh 0x10/0x87 (carries the mode byte)
            try? await Task.sleep(for: .milliseconds(700))
        }
        return false
    }

    /// Send `06 03 <type>` and classify the ring's response (#174). Ground truth (yoga snoop
    /// 2026-07-09): the ring answers `06 03` with `86 00 86` (accept) or `86 fd …` (reject) within
    /// ~0.4 s, then an accepted start streams its first `0x4e` ~8 s later. So watch a short window for
    /// the `86` verdict — a start that draws NO `86` was dropped from a non-idle state (`.ignored`),
    /// and we return at once instead of burning the whole stream-watch on a command that never landed.
    private func sendSportStartAndClassify(typeByte: UInt8) async -> SportStartResult {
        sportGotFirstFrame = false          // ignore any pre-start straggler
        lastSportFrameAt = nil
        sportStartRejected = false           // arm accept/reject detection for THIS SportStart
        sportStartAccepted = false
        write(Command.sportStart(typeByte))  // 06 03 <type> 04 00 — NO 06 00 before it
        write(Command.statusQuery)           // d0 00 00 — the app's enter sequence
        // Phase A — the `86` accept/reject verdict (~0.4 s in ground truth; cap ~3 s).
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(500))
            guard sportSessionActive, !Task.isCancelled else { return .ignored }
            if sportGotFirstFrame { return .streaming }
            if sportStartRejected { return .rejected }
            if sportStartAccepted { break }
        }
        // No `86` verdict within the window → the `06 03` was dropped from a non-idle state. (A
        // 0x4e this early already returned `.streaming` above, so only the accept flag can be set here.)
        guard sportStartAccepted else { return .ignored }
        // Phase B — accepted: wait for the first unsolicited `0x4e` (~8 s in ground truth).
        let streamDeadline = Date().addingTimeInterval(RingSession.sportFirstFrameWait)
        while Date() < streamDeadline {
            try? await Task.sleep(for: .milliseconds(500))
            guard sportSessionActive, !Task.isCancelled else { return .ignored }
            if sportGotFirstFrame { return .streaming }
            if sportStartRejected { return .rejected }
        }
        return .silentAccept
    }

    /// Force the ring out of live-HR into idle for a workout start via a FULL, LOSSLESS history drain
    /// (#174). Opening a sync kicks the ring out of the dashboard's live-HR mode; letting it run to its
    /// natural end (both channels → `0x50`/quiet, with `drainChannel`'s existing 45 s/channel backstop)
    /// returns the ring to idle AND banks every page. We deliberately do NOT cut the drain short: a
    /// mid-stream cut would ack-and-DISCARD the streamed remainder — the `0x4c`/`0x47` handlers ack
    /// every page unconditionally, so the ring advances its resume pointer past pages that a stopped
    /// (`syncing == false`) drain no longer banks, truncating an un-synced night (the #119/#111 loss
    /// class). The reach-idle fast path (`awaitIdleDescriptor`) is what keeps the common case snappy;
    /// this full drain is the fallback only when the ring is genuinely non-idle with a real backlog (in
    /// which case draining IS the right thing — it syncs the night). Guarded so it never runs overnight
    /// (self-contention truncates the night) or collides with an in-flight sync. Returns false (no-op)
    /// when skipped.
    @discardableResult
    private func runGuardedHistoryDrain(trigger: String) async -> Bool {
        guard ready, syncTask == nil, !calibrationCapturing, !isInSleepWindow else {
            ringLog.notice("\(trigger, privacy: .public): drain SKIP (link busy or sleep-window)")
            return false
        }
        if monitoring { stopLiveMonitoring(scheduleStatusRefresh: false) }   // live polling would fight the drain
        ringLog.notice("\(trigger, privacy: .public): draining history to reach clean idle")
        historySyncTrigger = trigger
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performHistoryDrain()
        }
        syncTask = task            // block any concurrent sync for the drain's duration
        await task.value           // performHistoryDrain runs finalizeSync and clears syncing/syncTask
        return true
    }

    // MARK: - Find My Ring (#96)
    //
    // Mirrors the official app's locator screen: enter the ring's proximity/search mode, poll the BLE
    // link RSSI (~1 Hz) so the UI can show an approximate distance, and blink the LED on/off on demand.
    // CoreBluetooth exposes RSSI on a CONNECTED peripheral via `readRSSI()` → `didReadRSSI`, so we can
    // gauge proximity without scanning. The LED-off / search-stop bytes are 🟡 probable (on/off
    // convention), self-validating on-device — see Command.findRingLightOff.

    /// True while the Find My Ring screen is open (ring in proximity mode + RSSI polling running).
    private(set) var findRingActive = false
    /// Whether the ring's locator LED is currently lit.
    private(set) var findRingLightOn = false
    /// Smoothed link RSSI (dBm), refreshed ~1 Hz while `findRingActive`; nil = no read yet / no signal.
    private(set) var ringRSSI: Int?
    /// Short window of raw RSSI reads, averaged into `ringRSSI` to tame the jitter.
    private var rssiSamples: [Int] = []
    private var rssiPollTask: Task<Void, Never>?

    /// Open Find My Ring: just start polling link RSSI for the distance readout. We send NO command to
    /// the ring on open — proximity comes from CoreBluetooth RSSI, and the ring must stay DARK until the
    /// user taps "light up" (the LED command `24 01 00` lit the ring the instant it was sent on open,
    /// which is why entering here used to auto-light it).
    func startFindingRing() {
        findRingActive = true
        findRingLightOn = false
        rssiSamples.removeAll()
        ringRSSI = nil
        rssiPollTask?.cancel()
        rssiPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.peripheral.state == .connected { self.peripheral.readRSSI() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Turn the ring's locator LED on or off (#96). On = `24 01 00` (🟢 device-verified); off =
    /// `24 00 00` (🟡 probable, same opcode param 0).
    func setFindRingLight(on: Bool) {
        findRingLightOn = on
        write(on ? Command.findRingLight : Command.findRingLightOff)
    }

    /// Close Find My Ring: turn the LED off (if lit) and stop polling RSSI.
    func stopFindingRing() {
        rssiPollTask?.cancel()
        rssiPollTask = nil
        if findRingLightOn { write(Command.findRingLightOff) }
        findRingActive = false
        findRingLightOn = false
        ringRSSI = nil
        rssiSamples.removeAll()
    }

    /// Fold one raw RSSI read into the smoothed `ringRSSI` (5-sample moving average). Drops
    /// CoreBluetooth's out-of-range sentinel (127) and any implausible value.
    private func recordRSSI(_ value: Int) {
        guard value < 0, value > -120 else { return }
        rssiSamples.append(value)
        if rssiSamples.count > 5 { rssiSamples.removeFirst(rssiSamples.count - 5) }
        ringRSSI = Int((Double(rssiSamples.reduce(0, +)) / Double(rssiSamples.count)).rounded())
    }

    /// Put the ring into airplane mode. This DROPS the BLE link immediately — the ring re-wakes ONLY
    /// via the charging case (there is no BLE "off" command). The link will disconnect right after.
    func setAirplaneModeOn() {
        write(Command.airplaneModeOn)
    }

    /// Arm (or disarm) an overnight OSA sleep-apnea assessment (#91). `05 22 01` tells the ring to
    /// record the dense `0x48` PPG overnight; it buffers it store-and-forward and our morning sync's
    /// 0x48 handler drains → OSASpO2 → the Sleep card. Persistent on the ring (survives disconnects),
    /// so this is a single fire-and-forget write — the user arms it before bed and just wears the ring.
    /// Returns false (no-op) if the ring isn't ready or a sync is in flight (one-writer).
    @discardableResult
    func setOSAAssessment(armed: Bool) -> Bool {
        guard ready, syncTask == nil else { return false }
        write(armed ? Command.osaAssessmentStart : Command.osaAssessmentStop)
        osaAssessmentArmed = armed
        ringLog.notice("OSA: assessment \(armed ? "ARMED (05 22 01)" : "disarmed (05 22 02)", privacy: .public)")
        return true
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
        // Re-tap on a live SpO2 read: drop the prior SpO2 lock too, else it counts as live/locked
        // for the fresh cycle (skips measuring UX; a failed retry never times out) (#125).
        if liveMode == .spo2 { liveSpO2 = nil; liveSpO2At = nil }
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
    func setLiveMode(_ mode: LiveMode, clearStaleValue: Bool = false) {
        guard liveMode != mode else { return }
        liveMode = mode
        liveHRTrend.removeAll()   // restarting the HR window
        liveHRWarmup = nil
        if clearStaleValue {
            // User switched INTO this mode for a fresh read — the SpO2→HR→SpO2 toggle path that
            // `startLiveMonitoring(clearStaleValue:)` / `rearmUserMeasure` don't cover (#125). Drop
            // the TARGET mode's prior lock so it can't masquerade as live before the ring re-enters
            // the mode (skipping preparing/measuring) or count as a lock at the user-measure deadline
            // — without this, an off-finger read after the toggle times out with no failure banner.
            // Only on a user switch (`armDeadline`); auto keeps its prior value on screen.
            switch mode {
            case .hr:   liveHR = nil;   liveHRAt = nil
            case .spo2: liveSpO2 = nil; liveSpO2At = nil
            }
        }
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
    func stopLiveMonitoring(scheduleStatusRefresh: Bool = true) {
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
        if scheduleStatusRefresh {
            scheduleDeviceStatusRefresh(reason: "live-stop")
        }
    }

    /// Pull stored history from BOTH ring history channels — `0x00` (sleep/overnight) then `0x03`
    /// (awake/all-day: activity HR + a periodic ~10-min daytime SpO₂ reading). Each is opened at
    /// cursor ≈ now (`syncUpToNow`, §3 — drains the ring's un-delivered backlog on that channel; NOT
    /// `syncAll`/0xFFFFFFFF, which returns empty). The ring streams 0x4c/0x47 pages, drained+decoded
    /// in didUpdateValue; results land in `historySamples` once each channel's 0x50 arrives.
    ///
    /// The official app drains both channels every sync; we previously only pulled `0x00`, so daytime
    /// SpO₂ went stale (the #99 gap — resolved by mining the captures, not a byte[6] selector sweep).
    func syncHistory(manual: Bool = false) {
        // OVERNIGHT-QUIET gate (#111/#119): an AUTOMATIC drain inside the sleep window is suppressed.
        // Cadenced overnight drains were thought "safe and additive" (only the old 60 s `0x07` temp
        // heartbeat shredded the night), but Randy's 6/30 capture disproved that — draining every ~30
        // min, the ring still stopped handing off 0x4c sleep history at ~02:35 and lost the back ~3 h.
        // So we drain NOTHING inside the window (the keepalive keeps the link warm with statusQuery and
        // the night accumulates untouched on the ring) and pull the whole night in ONE pass at wake.
        // A user-initiated sync (`manual`) always bypasses the gate. (See HistoryDrainCadence header.)
        guard HistoryDrainCadence.shouldDrain(manual: manual, inSleepWindow: isInSleepWindow, isDue: true)
        else {
            ringLog.notice("sync: SKIP (overnight-quiet — drain deferred to wake)")
            return
        }
        guard syncTask == nil else { return }    // already syncing
        historySyncTrigger = manual ? "manual" : "auto"
        stopLiveMonitoring(scheduleStatusRefresh: false)   // live polling would fight the drain
        syncTask = Task { [weak self] in
            await self?.performHistoryDrain()
        }
    }

    /// Capture raw push-stream PPG frames for calibration (`0x13`, 25 samples/frame). The caller
    /// receives decoded frames as they arrive and the async result returns the total sample count.
    func startPPGCalibrationCapture(duration: TimeInterval,
                                    onFrame: @escaping (PPGRawFrame) -> Void) async throws -> Int {
        guard ready else { throw NSError(domain: "OpenCircuit.Calibration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ring is not ready"]) }
        guard !syncing, !monitoring, !livePreparing, !calibrationCapturing else {
            throw NSError(domain: "OpenCircuit.Calibration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ring is busy"])
        }
        return try await withCheckedThrowingContinuation { continuation in
            calibrationContinuation = continuation
            calibrationFrameSink = onFrame
            calibrationSampleCount = 0
            calibrationMissCount = 0
            calibrationReenterCount = 0
            calibrationLastFrameAt = Date()
            calibrationCapturing = true
            syncTask?.cancel(); syncTask = nil
            stopLiveMonitoring(scheduleStatusRefresh: false)
            beginCalibrationPPGMode(duration: duration)
        }
    }

    private func beginCalibrationPPGMode(duration: TimeInterval) {
        calibrationKeepaliveTask?.cancel()
        calibrationWatchdogTask?.cancel()
        calibrationStopTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.enterCalibrationPPGMode()

            self.calibrationKeepaliveTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.calibrationCapturing {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, self.calibrationCapturing else { return }
                    self.write([0x96, 0x01, 0x00, 0x00, 0x00])
                }
            }
            self.calibrationWatchdogTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.calibrationCapturing {
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled, self.calibrationCapturing else { return }
                    // #138: the ring dropped but CoreBluetooth hasn't fired `didDisconnect` yet (or
                    // frames just stopped on a half-open link). Fail promptly instead of re-entering
                    // PPG mode against a dead peripheral forever (its writes only no-op).
                    if self.peripheral.state != .connected {
                        ringLog.notice("calibration: link down mid-capture (state != connected) — failing")
                        self.finishCalibrationPPGCapture(success: false)
                        return
                    }
                    let silentFor = Date().timeIntervalSince(self.calibrationLastFrameAt)
                    if silentFor < 1.4 { continue }
                    self.calibrationMissCount += 1
                    self.write([0x96, 0x01, 0x00, 0x00, 0x00])
                    if self.calibrationMissCount >= 5 {
                        // #138: give up after too many re-entries with no recovered frames — the link
                        // reads as connected but the ring stopped streaming for good (~30 s silence).
                        self.calibrationReenterCount += 1
                        if self.calibrationReenterCount > Self.calibrationMaxReenters {
                            ringLog.notice("calibration: raw PPG stalled through \(Self.calibrationMaxReenters) re-entries with no frames — failing")
                            self.finishCalibrationPPGCapture(success: false)
                            return
                        }
                        ringLog.notice("calibration: raw PPG stalled; re-enter mode10+mode01 (\(self.calibrationReenterCount)/\(Self.calibrationMaxReenters))")
                        await self.enterCalibrationPPGMode()
                        self.calibrationMissCount = 0
                        self.calibrationLastFrameAt = Date()
                    }
                }
            }
            self.calibrationStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard let self else { return }
                // #138: don't report success blindly at the duration mark. If the link silently
                // dropped near the end (no `didDisconnect` yet) or the capture only trickled a few
                // frames, this is not a usable capture — fail so it isn't uploaded as valid.
                if self.peripheral.state != .connected {
                    ringLog.notice("calibration: stop mark reached but link is down — failing")
                    self.finishCalibrationPPGCapture(success: false)
                    return
                }
                let minSamples = Int(duration * Self.calibrationMinSamplesPerSecond)
                if self.calibrationSampleCount < minSamples {
                    ringLog.notice("calibration: stop mark reached with only \(self.calibrationSampleCount) samples (< \(minSamples)) — failing (partial)")
                    self.finishCalibrationPPGCapture(
                        success: false,
                        failureReason: "The ring streamed too few PPG samples — try again and keep still.")
                    return
                }
                self.finishCalibrationPPGCapture(success: true)
            }
        }
    }

    private func enterCalibrationPPGMode() async {
        write(Command.status0)
        try? await Task.sleep(for: .milliseconds(250))
        write([0x06, 0x10, 0x00])
        try? await Task.sleep(for: .milliseconds(500))
        write([0x06, 0x00, 0x00])
        try? await Task.sleep(for: .milliseconds(500))
        write(Command.liveHRMode)
        try? await Task.sleep(for: .milliseconds(250))
        write([0x96, 0x01, 0x00, 0x00, 0x00])
    }

    /// Drain BOTH history channels into `bulkRecords` — `0x00` (sleep/overnight) then `0x03`
    /// (awake/all-day) — and COMMIT the union via `finalizeSync`. Sets `syncing` for the whole
    /// duration so the frame handler captures pages into `bulkRecords`. The firmware assigns each
    /// epoch to exactly ONE channel (🟢 the captures show 0 % counter overlap between `0x00` and
    /// `0x03`), so the two streams union cleanly in the EpochArchive with no counter collisions —
    /// the daytime channel never overwrites a sleep epoch's motion/HRV. `finalizeSync` clears
    /// `syncing`/`syncTask` on exit.
    private func performHistoryDrain() async {
        // Backgrounded drain (#119): hold an assertion and remember what woke us — this drain
        // must deliver its own results (Health flush + morning notification) because the
        // foreground pipelines (ContentView's onChange(syncing) mirror) don't run suspended.
        let wakeTrigger = pendingDrainTrigger
        pendingDrainTrigger = nil
        let inBackground = UIApplication.shared.applicationState != .active
        if inBackground { beginDrainAssertion() }
        flushDrainedToArchive()                  // bank any pages a prior interrupted drain left uncommitted (#119)
        bulkRecords.removeAll()
        bulkFinalized = false                    // fresh capture — uncommitted until finalizeSync
        historySamples.removeAll()
        drainTraces.removeAll()
        activeDrainTrace = nil
        // Do NOT wipe the staged sleep here. A periodic drain often returns EMPTY (nothing un-synced),
        // and `finalizeSync`'s empty branch deliberately doesn't re-stage; wiping first would blank
        // `sleepSegments`/`stagedSegments` and `flushHealth` reads those live (no store fallback), so
        // last night's Health sleep-mirror could be skipped until the next non-empty drain. Keep the
        // last staged night standing — a non-empty drain overwrites it via `commitDrainedRecords`,
        // and a night that ages out of the archive is harmless to retain (the `.sleep` cursor blocks
        // re-writes and the dashboard reads the persisted summary, not these).
        syncing = true
        syncStatus = nil
        drainCountsByLabel.removeAll()
        // Channel 0x00 — the sleep/overnight history (+ idle epochs).
        await drainChannel(channel: Command.syncChannelSleep, label: "sleep")
        // Channel 0x03 — the awake/all-day log: activity HR + a periodic ~10-min daytime SpO₂ reading
        // (same 23-byte schema, so it flows through the same BulkSleep decode → Health as-is). The
        // official app drains this too; pulling only 0x00 was why daytime SpO₂ went stale (#99).
        if !Task.isCancelled {
            await drainChannel(channel: Command.syncChannelAllDay, label: "all-day")
        }
        lastDrainSummary = "sleep \(drainCountsByLabel["sleep"] ?? 0) · all-day \(drainCountsByLabel["all-day"] ?? 0) epochs"
        finalizeSync()
        if inBackground { await deliverBackgroundResults(trigger: wakeTrigger) }
        endDrainAssertion()
    }

    // MARK: Background drain delivery (#119)

    private func beginDrainAssertion() {
        endDrainAssertion()
        drainAssertion = UIApplication.shared.beginBackgroundTask(withName: "ring.history.drain") { [weak self] in
            // iOS is ending the window mid-drain: bank the captured pages (the next commit
            // re-stages them from the archive — nothing is lost) and release the assertion.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushDrainedToArchive()
                self.endDrainAssertion()
            }
        }
    }

    private func endDrainAssertion() {
        guard drainAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(drainAssertion)
        drainAssertion = .invalid
    }

    /// A drain that ran while backgrounded delivers its own results (#119). For BLE-wake drains
    /// (`trigger != nil`) that means the Health flush the foreground would have done, plus an
    /// attributed Diagnostics record ("Last background run" finally means something). BGTask
    /// drains (trigger == nil) skip both — `RingBackgroundSyncService`/AppDelegate own their
    /// flush and record. EVERY background drain gets a shot at the morning notification; it's
    /// per-night deduped, so whichever path lands the finished night first posts it.
    private func deliverBackgroundResults(trigger: String?) async {
        if let trigger {
            let epochs = drainCountsByLabel.values.reduce(0, +)
            var wrote = false
            if HealthKitWriter.isAvailable, let localStore {
                let result = await HealthKitWriter().flushToHealth(store: localStore,
                                                                   sleepSegments: healthSleepSegments)
                wrote = result.wroteAnything
                if wrote { ObservabilityStore().recordHealthWrite() }
            }
            ObservabilityStore().recordSyncOutcome(
                kind: .cbWake,
                success: epochs > 0 || wrote,
                detail: "\(trigger): \(lastDrainSummary ?? "no summary")")
            // #146: evaluate body-vital alerts on THIS background wake-drain's data. The BGTask path
            // (AppDelegate) already evaluates after its drain; the hourly 0x11-wake path — the primary
            // all-day delivery — did not, so an over-threshold HR/SpO2/temp crossing that arrives on a
            // wake-drain would otherwise sit silent in the store until app-open. Pass `session: self`
            // so the evaluator also sees this drain's freshly-decoded `historySamples` on top of the
            // just-committed store batch. Placed OUTSIDE the HealthKit-available guard: alerts post
            // local notifications and are independent of Health-mirror authorization. The evaluator's
            // quiet-hours gate + per-notification `lastFired` backoff dedupe any overlap with the
            // BGTask path, and the whole await is covered by the surrounding drain assertion.
            if let localStore {
                await HealthNotificationCenter().evaluate(store: localStore, session: self)
            }
        }
        await postMorningSummaryIfNeeded()
    }

    /// UserDefaults key: the `night` stamp of the last sleep summary announced by notification.
    static let lastNotifiedNightKey = "morning.lastNotifiedNight"

    /// One lock-screen notification per night (#119 UX): "Last night: 7 h 25 min asleep",
    /// posted by the first background drain that lands the finished night — the user sees
    /// their sleep synced BEFORE opening the app, and opening it renders instantly from the
    /// store. Morning-only (never mid-night or afternoon), per-night deduped, quiet
    /// (provisional) authorization so it never interrupts.
    private func postMorningSummaryIfNeeded() async {
        guard let window = nightWindow else { return }
        let now = Date()
        let sinceWake = now.timeIntervalSince(window.end)
        guard sinceWake >= 0, sinceWake <= 6 * 3600 else { return }
        guard let localStore,
              let summary = try? localStore.recentSleepSummaries(limit: 1).first,
              summary.asleepMin > 0,
              now.timeIntervalSince(summary.updatedAt) < 15 * 60   // committed by THIS morning's drain
        else { return }
        let defaults = UserDefaults.standard
        let nightKey = summary.night.timeIntervalSince1970
        guard defaults.double(forKey: Self.lastNotifiedNightKey) != nightKey else { return }

        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) ?? false
            guard granted else { return }
        default:
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Last night"
        content.body = "\(summary.asleepMin / 60) h \(summary.asleepMin % 60) min asleep — synced from your ring."
        try? await center.add(UNNotificationRequest(identifier: "morning.summary",
                                                    content: content, trigger: nil))
        defaults.set(nightKey, forKey: Self.lastNotifiedNightKey)
    }

    /// Open ONE history channel at cursor ≈ now and drain its 0x4c/0x47 pages — the frame handler
    /// folds 0x4c records into `bulkRecords` while `syncing`. Bounded by the channel's `0x50` end
    /// marker, by 3 s of quiet AFTER pages have started (a lost end-marker), or a 45 s hard cap, so
    /// nothing can hang the sync. `syncDone`/`syncQuietTicks` reset per channel so each channel's
    /// end-marker is awaited independently.
    private func drainChannel(channel: UInt8, label: String) async {
        syncDone = false
        syncQuietTicks = 0
        let recordsAtStart = bulkRecords.count
        let open = Command.syncUpToNow(channel: channel)
        var trace = HistoryChannelTrace(label: label, channel: channel)
        trace.recordsAtStart = recordsAtStart
        activeDrainTrace = trace
        if captureRawFrames {
            rawCaptureLog.append("# --- history drain channel \(label) (0x\(String(format: "%02X", channel))) ---")
        }
        ringLog.notice("sync: START ch=\(label, privacy: .public) open=\(open.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public) (cursor≈now, §3)")
        print("[OC] sync START ch=\(label)")
        // Open at cursor ≈ NOW: the ring streams its un-delivered backlog on this channel up to now
        // and advances its own resume pointer (§3). `syncAll`'s far-future cursor returns empty.
        // status0 re-primes the SM3 challenge per channel (the second open may be re-challenged).
        for cmd in [Command.status0, open, Command.fetch] {   // 81 00 challenge → reactive SM3 auth (#54)
            write(cmd)
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        for tick in 0 ..< 45 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled {
                finishActiveDrainTrace(.cancelled)
                return
            }
            // Count seconds since the last page (the frame handler zeroes `syncQuietTicks` on every
            // 0x47/0x4c). The quiet-exit only applies once pages have actually started this channel,
            // so a slow open can't cut the drain off before the stream begins — an empty channel
            // exits on its 0x50 (`syncDone`); only a lost 0x50 falls through to the 45 s cap.
            // Exception: when the ring's 0x82 ACK carries byte[1]==0xff (pointer-at-end signal, 🟡),
            // we know no pages are coming. Apply the same 3-tick quiet exit without waiting for pages
            // to start — saves up to 42 s per empty channel (observed: all-day channel 2026-06-28).
            syncQuietTicks += 1
            let sawPages = bulkRecords.count > recordsAtStart
            let ackedEmpty = activeDrainTrace?.sawEmptyHistorySignal == true && !sawPages
            if syncDone || (sawPages && syncQuietTicks >= 3) || (ackedEmpty && syncQuietTicks >= 3) {
                let added = self.bulkRecords.count - recordsAtStart
                ringLog.notice("sync: ch=\(label, privacy: .public) drained at \(tick)s (done=\(self.syncDone), quiet=\(self.syncQuietTicks), ackedEmpty=\(ackedEmpty), records=\(self.bulkRecords.count))")
                print("[OC] sync DRAIN ch=\(label) added=\(added) ackedEmpty=\(ackedEmpty)")
                finishActiveDrainTrace(syncDone ? .endMarker : .quietAfterPages)
                break
            }
        }
        if activeDrainTrace != nil {
            let sawPages = bulkRecords.count > recordsAtStart
            finishActiveDrainTrace(sawPages ? .hardTimeout : .quietNoPages)
        }
        drainCountsByLabel[label] = bulkRecords.count - recordsAtStart
    }

    /// Probe one speculative sync-open channel into the forensic raw log. Uses the same
    /// cursor≈now open as the proven channels; if the selector is unsupported or empty it simply
    /// goes quiet after a short backstop. Unknown channels are treated as RE-only and are not fed
    /// into the normal decode/persist path here.
    private func captureProbeChannel(channel: UInt8) async {
        rawCaptureLog.append("# --- probe: channel 0x\(String(format: "%02X", channel)) at \(Date()) ---")
        write(Command.status0)
        try? await Task.sleep(for: .milliseconds(200))
        write(Command.syncUpToNow(channel: channel))
        try? await Task.sleep(for: .milliseconds(200))
        write(Command.fetch)
        var lastCount = rawCaptureLog.count
        var quiet = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { break }
            if rawCaptureLog.count == lastCount {
                quiet += 1
                if quiet >= 5 { break }
            } else {
                quiet = 0
                lastCount = rawCaptureLog.count
            }
        }
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
        var anomalies = DecodeAnomaly.detect(records: bulkRecords)
        if DecodeAnomaly.hasSustainedTemperatureAnomaly(nightTemperatureLog.map(\.celsius)) {
            anomalies.insert(.skinTempOutOfPhysicalRange)
        }
        lastSyncAnomalies = anomalies
        if !anomalies.isEmpty {
            let names = anomalies.map(\.rawValue).joined(separator: ", ")
            ringLog.error("decode anomaly detected: \(names, privacy: .public) — possible firmware/format drift")
        }
        let temps = wearTemperatureSamples()
        let union = epochArchiveStore.merge(bulkRecords)
        let nightRecords = BulkSleep.latestNightRecords(from: union, temperatures: temps)
        let sleepTrace = drainTraces.first { $0.label == "sleep" }
        let sleepOutcome = sleepTrace?.outcome
        let sleepCanCommit = sleepOutcome?.allowsSleepCommit ?? false
        let sleepHasFreshRecords = (sleepTrace?.recordsAdded ?? 0) > 0
        // TEMP DIAGNOSTIC (sleep-empty investigation): pinpoint which stage of the staging pipeline
        // loses the night — archive union size, the night-scoped slice `latestNightRecords` picked,
        // and whether `mainSleep`'s motion-based block detector finds anything at all in that slice.
        // Remove once the root cause is confirmed.
        let mainSleepBlock = BulkSleep.mainSleep(from: nightRecords, temperatures: temps)
        ringLog.notice("sleep-diag: union=\(union.count) nightRecords=\(nightRecords.count) temps=\(temps.count) mainSleep=\(mainSleepBlock != nil ? "\(mainSleepBlock!.start)..\(mainSleepBlock!.end)" : "nil", privacy: .public)")
        // HealthKit path: THIS batch's new samples (the SyncCursor dedups against what's written).
        historySamples = BulkSleep.samples(from: bulkRecords)
        // Sleep staging + persistence are conservative: a partial / PPG-only / no-ack sleep drain
        // must NOT overwrite a fuller stored night. We still keep the raw records + scalar samples.
        var committedSleep = false
        if sleepCanCommit, sleepHasFreshRecords {
            sleepSegments = BulkSleep.sleepSegments(from: nightRecords, temperatures: temps)   // wear gate (#41)
            stagedSegments = overnightStagedSegments(from: nightRecords)   // overnight gate (review #1)
            persistSleepAndSteps(nightRecords: nightRecords)   // summary + extras from the stitched night
            // Persist segments to the archive store so they survive session teardown. Without this,
            // a background task expiry or session reconnect clears the in-memory arrays and
            // `flushHealth()` fires with empty segments — sleep is permanently stranded in
            // StoredSleepSummary and never reaches HealthKit. The `.sleep` cursor prevents re-writes.
            epochArchiveStore.savePendingSleepSegments(coarse: sleepSegments, staged: stagedSegments)
            ringLog.notice("sleep-persist: saved coarse=\(self.sleepSegments.count) staged=\(self.stagedSegments.count) segments to archive (survives teardown)")
            print("[OC] sleep COMMITTED coarse=\(self.sleepSegments.count) staged=\(self.stagedSegments.count)")
            committedSleep = true
        } else if let sleepOutcome {
            let detail = "outcome=\(sleepOutcome.rawValue) recordsAdded=\(sleepTrace?.recordsAdded ?? 0) 4c=\(sleepTrace?.page4CCount ?? 0) 47=\(sleepTrace?.page47Count ?? 0) 50=\(sleepTrace?.endMarkerCount ?? 0)"
            observability.recordMetricEvent(source: "sleep-sync", detail: detail)
            ringLog.notice("sleep: skip re-stage/persist — \(detail, privacy: .public)")
        }
        // TEMP DIAGNOSTIC (HR-not-recording investigation): how many of THIS drain's raw records
        // decoded a valid HR (byte[4]) vs how many HR samples that produced, BEFORE ingest. If this
        // shows 0, the decode itself is the problem (bad records this drain); if it's >0 but the
        // local store still isn't growing, the problem is downstream in `persist`/`ingest`. Remove
        // once the root cause is confirmed.
        let decodedHRCount = bulkRecords.compactMap(\.heartRate).count
        let hrSampleCount = historySamples.filter { $0.kind == .heartRate }.count
        ringLog.notice("hr-diag: bulkRecords=\(self.bulkRecords.count) decodedHR=\(decodedHRCount) hrSamplesPreIngest=\(hrSampleCount)")
        persist(historySamples)   // auto-persist HR/HRV/SpO2 for the dashboard
        recordHistorySyncEvidence(sleepCommitted: committedSleep)
        bulkFinalized = true      // committed — the stop-time safety net can skip these records
    }

    /// Durably merge any not-yet-committed drained pages into the persisted EpochArchive BEFORE they're
    /// dropped. Archive-only (no re-stage); idempotent (EpochArchive dedups by counter). A drain can be
    /// superseded before it reaches `finalizeSync` — `startLiveMonitoring`/`performHistoryDrain` wipe
    /// `bulkRecords` up front and `invalidate()` cancels `syncTask` without committing — and the ring
    /// won't re-send those epochs (cursor≈now self-advances its resume pointer on ACK), so without this
    /// they left PERMANENT holes in the committed archive even though they reached the phone (the gap
    /// behind Randy's truncated sleep, #119). Cheap: fires only at the few supersession points, not per
    /// page. The follow-up `restageFromArchive()` turns the retained pages into a summary.
    private func flushDrainedToArchive() {
        guard !bulkRecords.isEmpty, !bulkFinalized else { return }
        _ = epochArchiveStore.merge(bulkRecords)
        ringLog.notice("sync: flushed \(self.bulkRecords.count) uncommitted page-records to archive before teardown")
    }

    /// Re-stage last night from the PERSISTED archive union (not the in-memory drain slice) and refresh
    /// the stored summary. Closes the loop on `flushDrainedToArchive`: pages that merged-on-arrival but
    /// never reached a non-empty `commitDrainedRecords` (an interrupted drain whose follow-up came back
    /// empty) would otherwise sit on disk while the summary stayed truncated. `saveSleepSummary` is
    /// merge-protected (SleepSummaryMerge) so this can only GROW a fuller night, never shrink one, and it
    /// leaves `historySamples` alone (no new HealthKit samples to write). Run once per session (at
    /// connect) so retained-but-unstaged data surfaces without churning the periodic empty-poll path.
    private func restageFromArchive() {
        let union = epochArchiveStore.load()
        guard !union.isEmpty else { return }
        let temps = wearTemperatureSamples()
        let nightRecords = BulkSleep.latestNightRecords(from: union, temperatures: temps)
        sleepSegments = BulkSleep.sleepSegments(from: nightRecords, temperatures: temps)
        stagedSegments = overnightStagedSegments(from: nightRecords)
        persistSleepAndSteps(nightRecords: nightRecords)
        ringLog.notice("sync: re-staged last night from archive union (\(union.count) epochs)")
    }

    /// Decode a completed OSA `0x48` burst into a SpO₂ night summary (#91). Fired ~5 s after the
    /// last `0x48` frame (debounce). Issues no BLE writes and is off the sync resume-pointer
    /// contract, so it can neither stall the ring nor truncate a night. The decode (thousands of
    /// frames) runs off the main actor; the result is published back on the main actor.
    ///
    /// The buffer is NOT cleared on entry: if a mid-burst BLE stall > the debounce window splits the
    /// burst, this first fires on a partial set, then re-runs on the fuller buffer once the rest
    /// arrives — so the PUBLISHED summary reflects the whole night, not a slice. `osaDecoding`
    /// serializes the two decodes; the buffer is freed only once a burst decodes with no growth.
    private func finalizeOSABurst() {
        osaDebounceTask = nil
        guard !osaDecoding, !osaFrames.isEmpty else { return }
        osaDecoding = true
        let frames = osaFrames                 // value snapshot; keep the buffer for a stalled burst
        let count = frames.count
        ringLog.notice("OSA: decoding 0x48 burst — \(count) frames")
        Task.detached(priority: .utility) { [weak self] in
            let summary = OSASpO2.summarize(frames: frames)
            await MainActor.run {
                guard let self else { return }
                self.osaDecoding = false
                if let summary {
                    self.latestOSASummary = summary
                    let attached = self.localStore?.applyOSASummary(summary) ?? false
                    ringLog.notice("""
                    OSA: SpO₂ avg=\(String(format: "%.1f", summary.averageSpO2))% \
                    min=\(String(format: "%.1f", summary.minSpO2))% \
                    t<90=\(Int(summary.timeBelow90Seconds))s ODI≈\(String(format: "%.1f", summary.odi)) \
                    windows=\(summary.validWindows) dur=\(String(format: "%.2f", summary.durationHours))h \
                    persisted=\(attached)
                    """)
                } else {
                    ringLog.notice("OSA: burst produced no usable SpO₂ series (too few clean windows)")
                }
                if self.osaFrames.count > count {
                    // The burst kept streaming during the decode (a stall split it) — re-run on the
                    // fuller buffer so the published summary is the WHOLE night, not the first slice.
                    self.osaDebounceTask?.cancel()
                    self.osaDebounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: Self.osaBurstQuiet)
                        guard !Task.isCancelled else { return }
                        self?.finalizeOSABurst()
                    }
                } else {
                    self.osaFrames.removeAll(keepingCapacity: false)   // burst complete → free frames
                    self.osaHitCap = false
                }
            }
        }
    }

    private func finalizeSync() {
        guard syncing else { return }
        if bulkRecords.isEmpty {
            // An empty poll (the periodic cadence fires even with nothing un-synced) brings no new
            // epochs — nothing to stitch. Stamp the cadence clock and finalize WITHOUT re-staging /
            // re-saving / re-flushing, so a periodic drain doesn't churn the stored night.
            epochArchiveStore.recordDrain()
            ringLog.notice("sync: FINALIZE records=0 (no re-stage; cadence stamped)")
            print("[OC] sync FINALIZE records=0 (ring empty)")
            syncStatus = steps != nil
                ? "Up to date — last night is likely already in the vitals dashboard. The ring clears history after each sync, so nothing new to fetch."
                : "No data received — is the ring bonded/awake?"
            recordHistorySyncEvidence(sleepCommitted: false)
        } else {
            commitDrainedRecords()
            let sleepOutcome = drainTraces.first { $0.label == "sleep" }?.outcome
            ringLog.notice("sync: FINALIZE records=\(self.bulkRecords.count) samples=\(self.historySamples.count) sleepSegs=\(self.sleepSegments.count) sleepOutcome=\(sleepOutcome?.rawValue ?? "none", privacy: .public) steps=\(self.steps ?? -1)")
            print("[OC] sync FINALIZE records=\(self.bulkRecords.count) sleepSegs=\(self.sleepSegments.count) sleepOutcome=\(sleepOutcome?.rawValue ?? "none") steps=\(self.steps ?? -1)")
            if let sleepOutcome, sleepOutcome != .complete, sleepOutcome != .empty {
                syncStatus = "Partial sync — sleep channel \(sleepOutcome.rawValue); raw data kept for retry"
            } else {
                syncStatus = "Synced \(bulkRecords.count) epochs"
            }
        }
        syncing = false
        syncTask = nil
        scheduleDeviceStatusRefresh(reason: "post-sync")
    }

    private func finishActiveDrainTrace(_ exitReason: HistoryChannelExitReason) {
        guard var trace = activeDrainTrace else { return }
        trace.finishedAt = Date()
        trace.recordsAtEnd = bulkRecords.count
        trace.exitReason = exitReason
        drainTraces.append(trace)
        let outcome = trace.outcome.rawValue
        observability.recordMetricEvent(
            source: "history-drain",
            detail: "trigger=\(historySyncTrigger) label=\(trace.label) outcome=\(outcome) ack=\(trace.sawSyncAck) 4c=\(trace.page4CCount) 47=\(trace.page47Count) 50=\(trace.endMarkerCount) added=\(trace.recordsAdded)"
        )
        activeDrainTrace = nil
    }

    private func updateActiveDrainTrace(bytes: [UInt8]) {
        guard var trace = activeDrainTrace else { return }
        guard let opcode = bytes.first else { return }
        if trace.firstOpcode == nil { trace.firstOpcode = opcode }
        trace.lastOpcode = opcode
        switch opcode {
        case 0x82:
            trace.sawSyncAck = true
            trace.syncAckFlag = bytes.count > 2 ? bytes[2] : nil
            // byte[1]==0xff is a new signal (2026-06-28, `82 ff 00 7d`) meaning the ring's
            // history pointer is already at end — nothing to stream on this channel. Distinct
            // from byte[1]==0x00 which preceded real page streams in every prior capture.
            if bytes.count > 1, bytes[1] == 0xff { trace.sawEmptyHistorySignal = true }
        case 0x47:
            trace.page47Count += 1
        case 0x4C:
            trace.page4CCount += 1
        case 0x50:
            trace.endMarkerCount += 1
        default:
            break
        }
        activeDrainTrace = trace
    }

    private func recordHistorySyncEvidence(sleepCommitted: Bool) {
        let entry = HistorySyncEvidence(
            date: Date(),
            ringID: peripheral.identifier.uuidString,
            trigger: historySyncTrigger,
            sleepCommitted: sleepCommitted,
            stagedSleepSegments: sleepSegments.count,
            mergedRecordCount: bulkRecords.count,
            historySampleCount: historySamples.count,
            channels: drainTraces,
            rawRecordBlob: EpochArchive.encode(bulkRecords)
        )
        observability.recordHistorySyncEvidence(entry)
    }

    /// Queue a device-status refresh for the next idle moment. Used after history syncs and after
    /// live monitoring tears down, because both often want an immediate steps/battery refresh but
    /// can overlap with a temporarily busy link.
    private func scheduleDeviceStatusRefresh(reason: String) {
        pendingDeviceStatusRefresh = true
        maybeRequestDeviceStatusRefresh(reason: reason)
    }

    /// Ask the ring for a fresh device-status descriptor (`0x10`/`0x87`) once the link is idle.
    /// The descriptor is the source for the "doesn't need overnight staging" metrics:
    /// today's step counter, battery %, charging state, case battery, and any live-only skin-temp
    /// snapshot. We try the proven command families in increasing strength: `fetch`, then
    /// `status0`→`fetch`, then `d0`→`fetch`. If the ring still stays quiet we leave the request
    /// queued so the next idle transition can retry.
    private func maybeRequestDeviceStatusRefresh(reason: String) {
        guard pendingDeviceStatusRefresh, postSyncStatusTask == nil else { return }
        guard ready else { return }
        guard !isInSleepWindow else {
            ringLog.notice("status: defer device snapshot (\(reason, privacy: .public)) — inside sleep window, would walk the history pointer (0x07)")
            return
        }
        guard !syncing, !monitoring, !livePreparing, !workoutHolding, !calibrationCapturing else {
            ringLog.notice("status: defer device snapshot (\(reason, privacy: .public)) — busy (sync=\(self.syncing), monitor=\(self.monitoring), preparing=\(self.livePreparing), workout=\(self.workoutHolding), calibration=\(self.calibrationCapturing))")
            return
        }
        pendingDeviceStatusRefresh = false
        let previousBatteryFetch = batteryFetchedAt
        postSyncStatusTask = Task { [weak self] in
            guard let self else { return }
            defer { self.postSyncStatusTask = nil }
            ringLog.notice("status: request device snapshot (\(reason, privacy: .public))")
            self.write(Command.fetch)
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            if self.batteryFetchedAt == previousBatteryFetch {
                ringLog.notice("status: no device snapshot after fetch — re-prime status0 then fetch")
                self.write(Command.status0)
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self.write(Command.fetch)
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
            }
            if self.batteryFetchedAt == previousBatteryFetch {
                ringLog.notice("status: no device snapshot after status0/fetch — try d0 then fetch")
                self.write(Command.statusQuery)
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self.write(Command.fetch)
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
            }
            // A fresh device-status frame always carries battery too, so `batteryFetchedAt`
            // advancing is a reliable witness that steps/charger/case-state had the chance to
            // refresh. If it never moved, keep the request queued for the next idle transition.
            if self.batteryFetchedAt == previousBatteryFetch {
                self.pendingDeviceStatusRefresh = true
                ringLog.notice("status: no 0x10/0x87 device snapshot arrived (\(reason, privacy: .public)); will retry on the next idle transition")
            }
        }
    }


    private func write(_ bytes: [UInt8]) {
        guard let writeChar else {
            ringLog.warning("write DROPPED (no writeChar yet): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
            return
        }
        guard canWriteCommands else {
            let state: String
            switch peripheral.state {
            case .connected: state = "connected"
            case .connecting: state = "connecting"
            case .disconnected: state = "disconnected"
            case .disconnecting: state = "disconnecting"
            @unknown default: state = "unknown"
            }
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let detail = "skipped state=\(state) ready=\(ready) notify=\(notifySubscribed) bytes=\(hex)"
            observability.recordMetricEvent(source: "ble-write", detail: detail)
            ringLog.warning("write SKIPPED (unusable link): \(detail, privacy: .public)")
            return
        }
        if captureRawFrames {
            rawCaptureLog.append("Write 0x0802 " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
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
    /// Link RSSI for Find My Ring (#96). Polled ~1 Hz while the locator screen is open; folded into
    /// the smoothed `ringRSSI` on the main actor.
    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let value = RSSI.intValue
        Task { @MainActor in self.recordRSSI(value) }
    }

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
            self.recordDiagnosticFrameIfEnabled(bytes)   // diagnostics capture (#111) — no-op when off
            // Raw capture for the activity-channel probe (#93/#99-style RE) — every inbound frame,
            // any opcode, while a probe is in flight. Format matches the desktop `decode-log` text
            // dump so captures here can feed `desktop/decode_activity.py` unchanged.
            if self.captureRawFrames {
                self.rawCaptureLog.append("Notification 0x0804 " + self.lastFrame!)
            }
            if self.syncing, self.activeDrainTrace != nil {
                self.updateActiveDrainTrace(bytes: bytes)
            }
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
            // The ring's onboard step field (descriptor [4:6], §5.4) is the ring's current-day
            // total. Fold repeated same-day reads into deltas so the keepalive doesn't re-add the
            // whole total every time, but once the calendar day changes treat the next raw value as
            // "today so far" so a reconnect later that day still catches the steps already taken.
            // The pure, unit-tested StepAccumulator owns that day-boundary math; this stays a thin
            // caller.
            // Track the ring's work-mode from every 0x10/0x87 descriptor byte[2] (idle 0x02/0x03,
            // charger 0x04, sport 0x06) so the sport-enter fast path can send `06 03` the instant the
            // ring is confirmably idle (#174). Gated on the descriptor opcode (the whole block runs for
            // every frame; the DeviceStatus decoders below return nil for non-descriptors).
            if let op = bytes.first, op == 0x10 || op == 0x87, bytes.count > 2 {
                self.lastDescriptorMode = bytes[2]
                self.lastDescriptorModeAt = Date()
            }
            let stepCounter = DeviceStatus.steps(bytes)
            let skinTemp = DeviceStatus.skinTemperature(bytes)
            let onCharger = DeviceStatus.isOnCharger(bytes)
            let batteryMV = DeviceStatus.batteryVoltageMillivolts(bytes)
            let caseB = DeviceStatus.caseBattery(bytes)
            let battery = DeviceStatus.battery(bytes)
            if let v = stepCounter {
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
                    // Window this delta to when it was actually observed (#steps-history): from
                    // the LAST same-day reading we saw, so a steady ~30-60s descriptor poll yields
                    // narrow, accurately-timed snapshots instead of crediting steps to the whole
                    // elapsed day. Falls back to the day boundary on a rollover/fresh baseline,
                    // where there genuinely is no prior same-day reading to anchor to. Clamped so a
                    // stale/cross-session timestamp can never produce an inverted or pre-midnight
                    // window.
                    var windowStart = dayChanged ? sampleDay : (self.persistedLastStepSampleAt ?? sampleDay)
                    if windowStart < sampleDay || windowStart > sampleDate { windowStart = sampleDay }
                    try? localStore?.addDailySteps(update.deltaToAdd, day: sampleDate, windowStart: windowStart)
                    // Record activity time for the sedentary reminder (#84).
                    UserDefaults.standard.set(sampleDate.timeIntervalSince1970,
                                              forKey: ReminderDefaults.lastActivityAt)
                }
                // Re-read the sample day's total from the store as the live display value: a fresh
                // row on midnight rollover reads its own total (no prior-day baseline bleed), and a
                // baseline-only first reading recovers today's already-accumulated count.
                dailyStepsTotal = (try? localStore?.todaySteps(day: sampleDate)) ?? dailyStepsTotal
                self.steps = dailyStepsTotal
                // Persist the raw counter + its day + this reading's timestamp for the NEXT
                // reading (cross-session, #34 / #steps-history).
                self.persistStepRawState(raw: v, day: sampleDay, sampleAt: sampleDate)
            }
            // Skin temperature rides the same 0x10/0x87 descriptor (§5.4). It streams live
            // (~30–60 s) and is NOT in the sleep sync, so the connected UI should reflect it
            // immediately whenever the reading looks worn/plausible. Persistence remains stricter:
            // ONLY night-window + worn readings are stored / mirrored into the overnight trend.
            if let t = skinTemp {
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
                // Display any worn/plausible live reading immediately, even by day, so the UI
                // reflects the same device-status snapshot Healthops uses. Still suppress cold
                // charger / off-wrist values from the user-facing skin-temp row.
                self.liveTemperature = worn ? t.celsius : nil
                // Persist ONLY a worn overnight reading into the NIGHTLY path: daytime values
                // must not pollute the nightly average or reach Apple Health (#41).
                if inNightWindow, worn {
                    self.persist([QuantitySample(kind: .temperature, start: Date(), value: t.celsius)])
                } else if worn {
                    // Daytime reading: Trends-only, via the separate StoredDaytimeTemp table —
                    // #41's guarantee above is untouched.
                    self.persistDaytimeTemperature(t.celsius, at: Date())
                }
            }
            // Confirmed charging state (#61 🟢): descriptor [2]==0x04 ⟺ on the charger. Per-frame
            // and instant — drives the auto-measure skip (#56) and a true "charging" UI signal,
            // superseding the rising-% inference while connected. Also decode ring voltage (#89).
            if let onCharger {
                if onCharger != self.charging { self.charging = onCharger }
            }
            if let mv = batteryMV {
                if mv != self.batteryVoltageMV { self.batteryVoltageMV = mv }
            }
            // Charging-case battery (#89): [17] low7 = case %, bit 0x80 = case charging, 0xff = not
            // docked. Always reassign (nil when the ring leaves the case) so the UI clears promptly.
            if caseB != self.caseBattery { self.caseBattery = caseB }
            // Ring battery % is descriptor byte[1] (§5.4 🟢, ground-truthed).
            // Also stamps `batteryFetchedAt` (#57) and extends the charging-inference trend (#60)
            // and the TTE sample window (#86).
            if let b = battery {
                self.batteryPercent = b
                self.batteryFetchedAt = Date()   // dedicated freshness anchor (#57)
                // Charging inference: rolling window of distinct readings (#60).
                if self.batteryTrend.last != b {
                    self.batteryTrend.append(b)
                    if self.batteryTrend.count > Self.batteryTrendCapacity {
                        self.batteryTrend.removeFirst()
                    }
                }
                // TTE (#86): fold into the persisted per-ring discharge history via the pure
                // accumulator — it noise-filters with the decoded charging byte (#61), prunes, and
                // keeps a clean slope across reconnects. Persist only when the history changed.
                let updated = BatteryTTE.record(self.batteryHistory, percent: b, at: Date(),
                                                charging: self.charging,
                                                cap: Self.batteryHistoryCap)
                if updated != self.batteryHistory {
                    self.batteryHistory = updated
                    if let data = try? JSONEncoder().encode(updated) {
                        UserDefaults.standard.set(data, forKey: self.batteryHistoryKey)
                    }
                }
                // Time-to-FULL (#61): mirror window, active only while the charging byte is set.
                let charge = BatteryTTE.recordCharge(self.batteryChargeHistory, percent: b, at: Date(),
                                                     charging: self.charging,
                                                     cap: Self.batteryHistoryCap)
                if charge != self.batteryChargeHistory {
                    self.batteryChargeHistory = charge
                    if let data = try? JSONEncoder().encode(charge) {
                        UserDefaults.standard.set(data, forKey: self.batteryChargeHistoryKey)
                    }
                }
            }
            if stepCounter != nil || skinTemp != nil || onCharger != nil || batteryMV != nil || caseB != nil || battery != nil {
                self.pendingDeviceStatusRefresh = false
                self.postSyncStatusTask?.cancel(); self.postSyncStatusTask = nil
                let tempText = self.liveTemperature.map { String(format: "%.2f", $0) } ?? "-"
                // `mode` = descriptor byte[2]: 0x02/0x03 idle, 0x06 = SPORT MODE ACTIVE. Surfaced so a
                // workout capture shows whether the ring entered sport mode after our SportStart (#90).
                let mode = bytes.count > 2 ? String(format: "0x%02x", bytes[2]) : "-"
                ringLog.notice("status frame: mode=\(mode, privacy: .public) stepsRaw=\(stepCounter ?? -1) total=\(self.steps ?? -1) batt=\(self.batteryPercent ?? -1)% charging=\(self.charging) case=\(self.caseBattery?.percent ?? -1)% temp=\(tempText, privacy: .public)")
            }
            // Bulk history pages: accumulate + ack to continue draining (47→c7, 4c→cc).
            switch bytes.first {
            case 0x47:
                self.drainSawPage = true
                if self.syncing { self.syncQuietTicks = 0 }
                ringLog.debug("← 0x47 PPG page (\(bytes.count)B), ack")
                self.write(Command.pageAck47)
                self.handlePPGPage(data)   // Layer-A epoch decode, gated (#24)
                self.logPPGTrend(bytes)    // diagnostic-only optical-trend decode (issue #8)
                return
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
                // #157: the sync-open ACK marks the START of a fresh drain and always precedes this
                // drain's first 0x47/0x4c page, so re-seed the (gated, #24) epoch-decode session here.
                // Otherwise its raw page buffers accumulate for the whole life of the connection and
                // every 0x50 re-parses ALL pages ever seen (O(n²) CPU, unbounded memory). Re-seeding at
                // the open bounds the buffers to a single drain AND discards a previous drain's partial
                // pages when it ended without a 0x50 (dropped link / watchdog-terminated sync). Safe:
                // `syncSession` is a parallel decode SINK only — the drain's cursor/resume is driven by
                // the ring's self-advancing resume pointer + the persisted SyncCursor, and real history
                // records flow into the separate `bulkRecords` buffer (untouched here), so clearing this
                // can neither drop drain data nor disturb a resume. The correct stream-high byte is
                // recomputed from each drain's own 0x50 in `complete(with:)`, so a plain re-seed is fine.
                self.syncSession = EpochSyncSession()
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
                // This heartbeat is the app's steady background wake source — use it (#119):
                // previously it was spent ack-only, so a suspended app never drained all day.
                self.maybeDrainOnBackgroundWake(trigger: "0x11-wake")
                return
            case 0x13:
                if self.calibrationCapturing {
                    self.handleCalibrationPPGFrame(bytes)
                    return
                }
            case 0x4E:
                // Native sport-mode stream (#90): HR (byte[5]) + steps (byte[6]) every ~10 s, each
                // acked with `ce 00 00` to keep it flowing. Decode HR into `liveHR`/`liveHRAt` so the
                // workout's existing HR pipeline (WorkoutHRGate → aggregator) and the live UI pick it
                // up, and sum steps into `sportSteps`. Ignored unless a native sport session is active.
                if self.sportSessionActive {
                    self.sportGotFirstFrame = true   // stream is live → stop the SportStart retry watchdog
                    self.lastSportFrameAt = Date()   // stream-health heartbeat (drives the stall watchdog)
                    if let sample = SportFrame.decode(bytes) {
                        self.write(Command.sportStreamAck)
                        self.sportSteps += sample.steps
                        if let hr = sample.hr {
                            self.liveHR = hr
                            self.liveHRAt = Date()   // true capture time (drives the workout dedup gate)
                            self.liveHRWarmup = nil
                            ringLog.notice("← 0x4e sport: HR \(hr) bpm, +\(sample.steps) steps (Σ \(self.sportSteps))")
                        }
                    }
                    return
                }
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
            case 0x86:
                // Response to a `0x06`-family command (SportStart `06 03 …` / SportStop `06 00 …` /
                // live-HR `06 01 …`). `86 00 86` = accepted; `86 <err> …` (err≠0, e.g. `86 fd 7b`) =
                // REJECTED. The enter loop watches `sportStartRejected`/`sportStartAccepted` to classify
                // the start (accept→wait for the 0x4e stream, reject→bail) fast (#174).
                let accepted = bytes.count >= 2 && bytes[1] == 0x00
                self.sportStartRejected = bytes.count >= 2 && bytes[1] != 0x00
                self.sportStartAccepted = accepted
                ringLog.notice("← 0x86 sport-cmd resp: \(self.lastFrame ?? "", privacy: .public)")
                return
            case 0x48:
                // OSA dense-PPG store-and-forward burst (#91). Collect raw wire frames (retransmit-
                // heavy — dedup happens later in OSAWaveform.channels); decode once the burst goes
                // quiet (debounce). NO ack — unlike the 0x4e sport stream, the ring floods these
                // unprompted after the 0x50/d0, so sending an unspecified ack risks stalling it. NOT
                // gated on `syncing`: the burst arrives AFTER the drain's 0x50 (when `syncing` may
                // already be false), so gating would drop it. Read-only wrt the ring and off the
                // resume-pointer contract → cannot truncate a night.
                if self.osaFrames.count < Self.osaFrameCap {
                    self.osaFrames.append(bytes)
                } else if !self.osaHitCap {
                    self.osaHitCap = true
                    ringLog.warning("OSA: 0x48 buffer hit cap \(Self.osaFrameCap) — burst truncated, SpO₂ summary will be partial")
                }
                self.osaDebounceTask?.cancel()
                self.osaDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.osaBurstQuiet)
                    guard !Task.isCancelled else { return }
                    self?.finalizeOSABurst()
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

    /// Diagnostic-only decode of a `0x47` page's optical-trend samples (issue #8 —
    /// PROTOCOL.md §5.2). Surfaces a summary for inspection (`lastPPGTrendSummary`, e.g. the
    /// Debug card); never feeds HealthKit or any analytic — channel identity and absolute
    /// units are still unconfirmed (see `PPGTrend.swift`'s header).
    private func logPPGTrend(_ bytes: [UInt8]) {
        let records = EpochRecord.parsePPGPage(Data(bytes))
        guard !records.isEmpty else { return }
        let allSamples = records.flatMap { PPGTrend.samples(from: $0.rawPayload) }
        guard let lo = allSamples.min(), let hi = allSamples.max() else { return }
        let mean = Double(allSamples.reduce(0, +)) / Double(allSamples.count)
        let summary = "\(records.count) records, \(allSamples.count) samples, "
            + "range \(lo)–\(hi), mean \(String(format: "%.0f", mean))"
        self.lastPPGTrendSummary = summary
        ringLog.debug("0x47 optical-trend (diagnostic, issue #8): \(summary, privacy: .public)")
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

    private func handleCalibrationPPGFrame(_ bytes: [UInt8]) {
        guard bytes.count >= 156 else { return }
        calibrationLastFrameAt = Date()
        calibrationMissCount = 0
        calibrationReenterCount = 0   // #138: a real frame recovered the stream — re-arm the stall ceiling
        let seq = bytes[2]
        let wallClockS = Date().timeIntervalSince1970
        var chA: [Int] = []
        var chB: [Int] = []
        var chC: [Int] = []
        chA.reserveCapacity(25)
        chB.reserveCapacity(25)
        chC.reserveCapacity(25)
        for i in 0..<25 {
            let offset = 6 + i * 6
            guard offset + 5 < bytes.count else { break }
            chA.append(Int(bytes[offset]) << 8 | Int(bytes[offset + 1]))
            let rawB = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
            let rawC = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
            chB.append(Int(Int16(bitPattern: rawB)))
            chC.append(Int(Int16(bitPattern: rawC)))
        }
        let frame = PPGRawFrame(seq: seq, wallClockS: wallClockS, chA: chA, chB: chB, chC: chC)
        calibrationSampleCount += chA.count
        calibrationFrameSink?(frame)
    }

    private func finishCalibrationPPGCapture(success: Bool, failureReason: String? = nil) {
        calibrationKeepaliveTask?.cancel()
        calibrationKeepaliveTask = nil
        calibrationWatchdogTask?.cancel()
        calibrationWatchdogTask = nil
        calibrationStopTask?.cancel()
        calibrationStopTask = nil
        // #138: only exit raw-PPG mode on the ring if the link is still up. On a disconnect the
        // peripheral is gone and `invalidate()` may have already nil-ed the delegate, so this write
        // would just no-op with a noisy "unusable link" warning. (`write()` itself also guards on
        // `.connected`; this makes the intent explicit and keeps the failure path quiet.)
        if calibrationCapturing, peripheral.state == .connected {
            write([0x06, 0x00, 0x00])
        }
        calibrationCapturing = false
        calibrationFrameSink = nil
        let count = calibrationSampleCount
        calibrationSampleCount = 0
        calibrationMissCount = 0
        calibrationReenterCount = 0
        calibrationLastFrameAt = .distantPast
        if success {
            calibrationContinuation?.resume(returning: count)
        } else {
            // #138: make the (previously dead) failure branch real and specific. Default to the
            // disconnect message — that is the dominant failure (official-app contention, charger,
            // out of range) — but let callers pass a more precise reason (e.g. a partial capture).
            let message = failureReason ?? "Ring disconnected — try again"
            calibrationContinuation?.resume(throwing: NSError(domain: "OpenCircuit.Calibration", code: 3, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        calibrationContinuation = nil
        scheduleDeviceStatusRefresh(reason: "calibration-stop")
    }
}
