import Foundation
import OpenRingKit

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
    func syncVitals(timeout: TimeInterval = RingBackgroundSyncService.defaultTimeout) async throws -> Bool {
        let scanner = RingScanner.shared
        scanner.setLocalStore(store)   // RingSession auto-persists the drained history + temp
        let capture = await scanner.captureForBackground(timeout: timeout)
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
        if HealthKitWriter.isAvailable {
            mirrored = await health.flushToHealth(store: store,
                                                  sleepSegments: capture.sleepSegments).wroteAnything
            // Record the Health write so ContentView's "Last Health write" reflects the
            // background path too, not just the manual button (#44).
            if mirrored { ObservabilityStore().recordHealthWrite() }
        }
        // Success = we captured fresh data OR mirrored previously-pending data to Health, so a
        // run that only flushed a backlog still counts (iOS uses this to keep scheduling us).
        return capture.gotData || mirrored
    }
}
