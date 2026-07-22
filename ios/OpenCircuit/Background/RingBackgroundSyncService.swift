import Foundation
import OpenCircuitKit

@MainActor
struct RingBackgroundSyncService {
    private let store: LocalStore
    private let health: HealthKitWriter

    init(store: LocalStore, health: HealthKitWriter) {
        self.store = store
        self.health = health
    }

    /// Budget for one background read. The old 20 s let the history drain eat the whole window
    /// before the live-HR poll even started, so HR never locked in the background (#45 A). We now
    /// run nearer the BGAppRefreshTask ceiling so the poll gets a real budget after the drain;
    /// the task's `expirationHandler` (AppDelegate) still cancels cleanly if iOS grants less, and
    /// the capture loop is cancellation-aware. (Honest: BGAppRefreshTask windows are short, so a
    /// full ~60 s optical lock isn't guaranteed every run — but the drain no longer starves it,
    /// any lock now reaches HealthKit, and the standing reconnect gives repeat chances.)
    static let defaultTimeout: TimeInterval = 28

    /// Budget for the BGProcessingTask path (#45). A processing task gets minutes of runtime
    /// (vs. the ~30 s app-refresh ceiling), so the optical-HR poll finally has room past its
    /// ~60 s warm-up to actually lock. We change ONLY the time budget handed to the existing
    /// capture loop — not the drain/decode logic. The loop is cancellation-aware, so if iOS
    /// grants less the AppDelegate `expirationHandler` still tears down cleanly. HONEST: iOS
    /// schedules processing tasks at its discretion (usually overnight on the charger), so this
    /// makes a real background HR lock LIKELY when it runs, not guaranteed for daytime.
    static let processingTimeout: TimeInterval = 150

    /// One bounded background read so the app already has last night's data on open. The
    /// drain inside `captureForBackground` persists overnight HR/HRV/SpO2 + sleep + steps +
    /// skin temp to the local store (the dashboard's source) — skin temp ONLY during the
    /// nightly sleep window (daytime readings are too noisy to trend); here we then mirror
    /// everything pending into Apple Health, each metric watermark-gated so nothing
    /// double-writes. Returns the BGTask success flag — true when we captured ANY data, not
    /// only a live HR, so iOS keeps scheduling us even on nights the optical HR never locks.
    @discardableResult
    func syncVitals(timeout: TimeInterval = RingBackgroundSyncService.defaultTimeout,
                    allowLivePoll: Bool = true,
                    sleepFinalized: Bool = false,
                    forceHistoryDrain: Bool = false) async throws -> Bool {
        let scanner = RingScanner.shared
        scanner.setLocalStore(store)   // RingSession auto-persists the drained history + temp

        // F1 flush-first (#119 early-termination): on the SHORT app-refresh window, mirror any
        // ALREADY-BANKED backlog to Apple Health BEFORE the drain, so a run iOS later cuts mid-capture
        // still advances Health with the prior night/day instead of deferring everything to the next
        // foreground open (the 7d activity log showed 11/15 app-refresh runs "ended early" with a
        // fully-banked-but-unmirrored night). flushToHealth is READ-ONLY w.r.t. the ring — it issues
        // ZERO BLE, so it cannot advance the resume pointer, cannot violate one-writer (never touches
        // `syncTask`), and cannot drain in the overnight-quiet window — and every metric is watermark-
        // gated (SyncCursor), so this pre-flush and the post-capture flush below never double-write.
        // Gated to `!allowLivePoll` (the app-refresh window) so the longer BGProcessing path keeps its
        // capture-first behavior. `preMirrored` records that the mirror actually landed THIS wake,
        // which the task's success flag can't reflect on a cut run (the expirationHandler sets it).
        var preMirrored = false
        if !allowLivePoll && HealthKitWriter.isAvailable {
            let persisted = scanner.loadLastCommittedSleepSegments()
            let priorSegments = !persisted.staged.isEmpty ? persisted.staged : persisted.coarse
            preMirrored = await health.flushToHealth(store: store,
                                                     sleepSegments: priorSegments,
                                                     sleepFinalized: sleepFinalized).wroteAnything
            if preMirrored { ObservabilityStore().recordHealthWrite() }
        }

        let capture = await scanner.captureForBackground(timeout: timeout, allowLivePoll: allowLivePoll,
                                                         forceHistoryDrain: forceHistoryDrain)
        // Resolve the night window for this connect so temp frames are gated correctly even
        // on a fresh background session that never ran the reactive refresh. This CANNOT be
        // hoisted above `captureForBackground`: the `RingSession` is created during that call's
        // connect, so `scanner.session` is nil beforehand and a pre-call refresh would be a
        // no-op. Temp frames arriving DURING the capture are already gated correctly two ways:
        // `RingSession.startKeepalive()` primes the window the moment the session is ready, and
        // the descriptor capture site force-re-resolves on any window miss before dropping a
        // sample. This post-capture refresh keeps the cache warm for any trailing frames.
        await scanner.session?.refreshNightWindowIfNeeded()

        var mirrored = false
        let flushStart = Date()
        if HealthKitWriter.isAvailable {
            mirrored = await health.flushToHealth(store: store,
                                                  sleepSegments: capture.sleepSegments,
                                                  sleepFinalized: sleepFinalized).wroteAnything
            // Record the Health write so ContentView's "Last Health write" reflects the
            // background path too, not just the manual button (#44).
            if mirrored { ObservabilityStore().recordHealthWrite() }
        }

        // Phase-timing breadcrumb (#119 early-termination): splits the wake into connect vs drain vs
        // flush so the next activity-log export can attribute an early kill to a CONNECT-overrun (F3
        // irrelevant) vs a DRAIN-overrun (F3 relevant) — an open question the 7d log couldn't answer
        // (no daytime connection evidence). `preMirrored`/`mirrored` record whether Health actually
        // advanced this wake, independent of the "ended early" completion flag. Lands in the metric
        // log the Diagnostics export reads. (verifier)
        ObservabilityStore().recordMetricEvent(
            source: "bgphase",
            detail: Self.bgPhaseBreadcrumb(
                appRefresh: !allowLivePoll,
                connectToReadyMS: capture.connectToReadyMS,
                drainMS: capture.drainMS,
                flushMS: Int(Date().timeIntervalSince(flushStart) * 1000),
                ready: capture.connectToReadyMS != nil,
                gotData: capture.gotData,
                preMirrored: preMirrored,
                mirrored: mirrored))

        // Success = we captured fresh data, mirrored freshly-drained data, OR flushed a pending
        // backlog (flush-first) to Health — any of the three keeps iOS scheduling us. (#44/#119)
        return capture.gotData || mirrored || preMirrored
    }

    /// Format the `bgphase` diagnostic detail line — the primary metric for validating the #119
    /// early-termination fix, since a cut run's task success flag is set to `false` by the
    /// expirationHandler regardless of whether the flush-first mirror landed. A `nil` connect/drain
    /// duration renders `n/a` (the drain/connect never finished this wake): `connect=n/a ready=false`
    /// is a CONNECT-overrun, `connect=Nms drain=n/a` is a DRAIN-overrun. Pure/static so the format
    /// stays locked for the log parser and is unit-testable without a scanner or HealthKit. (#119)
    nonisolated static func bgPhaseBreadcrumb(appRefresh: Bool, connectToReadyMS: Int?, drainMS: Int?,
                                              flushMS: Int, ready: Bool, gotData: Bool,
                                              preMirrored: Bool, mirrored: Bool) -> String {
        "kind=\(appRefresh ? "appRefresh" : "processing")"
            + " connect=\(connectToReadyMS.map { "\($0)ms" } ?? "n/a")"
            + " drain=\(drainMS.map { "\($0)ms" } ?? "n/a")"
            + " flush=\(flushMS)ms"
            + " ready=\(ready) gotData=\(gotData)"
            + " preMirrored=\(preMirrored) mirrored=\(mirrored)"
    }
}
