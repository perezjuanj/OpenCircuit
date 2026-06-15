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

    /// One bounded background read so the app already has last night's data on open. The
    /// drain inside `captureForBackground` persists overnight HR/HRV/SpO2 + sleep + steps +
    /// skin temp to the local store (the dashboard's source) — skin temp ONLY during the
    /// nightly sleep window (daytime readings are too noisy to trend); here we then mirror
    /// everything pending into Apple Health, each metric watermark-gated so nothing
    /// double-writes. Returns the BGTask success flag — true when we captured ANY data, not
    /// only a live HR, so iOS keeps scheduling us even on nights the optical HR never locks.
    @discardableResult
    func syncVitals(timeout: TimeInterval = 20) async throws -> Bool {
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
        }
        // Success = we captured fresh data OR mirrored previously-pending data to Health, so a
        // run that only flushed a backlog still counts (iOS uses this to keep scheduling us).
        return capture.gotData || mirrored
    }
}
