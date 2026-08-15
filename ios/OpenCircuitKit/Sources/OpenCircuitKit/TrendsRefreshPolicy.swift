import Foundation

/// When a trends reload is worth paying for.
///
/// The trends snapshot is the single most expensive read in the app: 🟢 MEASURED 2026-08-14 on a
/// real device (39,434 `StoredSample` rows) one load fetches **24,959 rows** over its 14-day
/// window. The reload itself now runs off the main actor, but it is still real work — SQLite
/// pages, ~25 k object materializations and a per-day rollup — so firing it three times for one
/// user action is three times the battery and three times the contention with the drain that is
/// running at exactly that moment.
///
/// And it *was* firing three times. `ContentView` drives the load from three independent hooks:
/// the view's first `.task`, `scenePhase == .active`, and `syncing → false`. At a cold launch the
/// first two both fire within a frame or two of each other, for the same unchanged data.
///
/// The asymmetry this policy encodes: **only `.syncFinished` knows new rows exist.** Appearing and
/// foregrounding are user-navigation events that say nothing about the store's contents, so they
/// are debounced; a sync completing is the one signal that the underlying data actually changed,
/// so it always reloads. A first load with nothing on screen yet is never suppressed — a debounce
/// that leaves the user staring at empty charts is worse than the work it saves.
public enum TrendsRefreshPolicy {

    /// What is asking for the reload.
    public enum Reason: Sendable, Equatable {
        /// The view appeared for the first time this launch (`.task`).
        case appeared
        /// The app came back to the foreground (`scenePhase == .active`).
        case foregrounded
        /// A history sync just finished (`syncing → false`) — new rows may have landed.
        case syncFinished
    }

    /// How stale a snapshot must be before a navigation event (appear / foreground) re-reads it.
    ///
    /// 60 s is chosen against the ring's own 150 s epoch cadence: inside one minute the store
    /// cannot have gained more than a single epoch's worth of rows, so a suppressed reload can be
    /// behind by at most one epoch — and `.syncFinished` reloads unconditionally the moment a drain
    /// actually delivers anything, so that bound is only ever reached when nothing arrived.
    public static let minInterval: TimeInterval = 60

    /// Whether to run the reload now.
    ///
    /// - Parameters:
    ///   - reason: what triggered the request.
    ///   - lastLoadedAt: when the current snapshot was loaded; `nil` if none has ever loaded.
    ///   - now: the clock (injectable for tests).
    public static func shouldReload(reason: Reason,
                                    lastLoadedAt: Date?,
                                    now: Date = Date()) -> Bool {
        // Nothing on screen yet — always load, whatever asked.
        guard let lastLoadedAt else { return true }
        // A finished sync is the only trigger that carries information about the STORE rather than
        // about navigation, so it is never debounced.
        if reason == .syncFinished { return true }
        // A clock that moved backwards (timezone/NTP correction) must not latch the snapshot
        // stale forever: treat any non-forward interval as "due".
        let elapsed = now.timeIntervalSince(lastLoadedAt)
        return elapsed < 0 || elapsed >= minInterval
    }
}
