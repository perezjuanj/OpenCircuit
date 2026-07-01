import Foundation
import OpenCircuitKit

// Persists the rolling EpochArchive (recent raw 0x4c records) + the last-drain timestamp, so a night
// the ring hands off in MULTIPLE slices can be re-staged from the UNION (stitching), and so the
// periodic-drain cadence is honored ACROSS reconnects (not reset on every brief link flap).
//
// UserDefaults-backed, deliberately NOT SwiftData — a small (~single-digit KB) blob with no schema,
// mirroring ObservabilityStore. Shared between the foreground UI and the background sync task (same
// app process). The pure encode/decode/merge + cadence math live in OpenCircuitKit (EpochArchive /
// HistoryDrainCadence); this is just the persistence plumbing.
struct EpochArchiveStore {
    private let defaults: UserDefaults
    private let archiveKey: String
    private let lastDrainKey: String
    // Persisted sleep segments from the most recent committed drain. Survives session teardown so
    // `flushHealth()` can re-use them when a fresh/nil session has empty stagedSegments.
    private let pendingCoarseSleepKey: String
    private let pendingStagedSleepKey: String

    /// `namespace` scopes the keys to a single ring (its CoreBluetooth identifier) so two rings'
    /// epoch archives can't collide on the UInt32 epoch counter (which would corrupt overnight
    /// stitching) (#multi-ring). An empty namespace keeps the legacy un-suffixed keys for any caller
    /// that isn't ring-scoped.
    init(namespace: String = "", _ defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let suffix = namespace.isEmpty ? "" : ".\(namespace)"
        self.archiveKey = "sleep.epochArchive\(suffix)"
        self.lastDrainKey = "sleep.lastHistoryDrainAt\(suffix)"
        self.pendingCoarseSleepKey = "sleep.pendingCoarseSegments\(suffix)"
        self.pendingStagedSleepKey = "sleep.pendingStagedSegments\(suffix)"
    }

    /// The stored archive (decoded), or `[]` when none yet.
    func load() -> [BulkRecord] {
        guard let data = defaults.data(forKey: archiveKey) else { return [] }
        return EpochArchive.decode(data)
    }

    /// Merge `incoming` into the stored archive (dedup by counter + prune to retention) and persist;
    /// returns the new union for immediate staging.
    @discardableResult
    func merge(_ incoming: [BulkRecord]) -> [BulkRecord] {
        let union = EpochArchive.merge(existing: load(), incoming: incoming)
        defaults.set(EpochArchive.encode(union), forKey: archiveKey)
        return union
    }

    /// When the ring's history buffer was last drained (any drain, incl. an empty one — we still
    /// polled the buffer). Drives `HistoryDrainCadence.isDue` so the cadence survives reconnects.
    var lastDrainAt: Date? {
        let t = defaults.double(forKey: lastDrainKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Stamp a completed drain (foreground, background, or periodic).
    func recordDrain(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: lastDrainKey)
    }

    // MARK: Pending sleep segment persistence
    //
    // The `[SleepSegment]` arrays computed by a drain live only in-memory on `RingSession`. If the
    // session is torn down (background task expires, disconnect, app relaunch) before `flushHealth()`
    // can mirror them to HealthKit, they're lost. Persisting them here lets `flushHealth()` fall back
    // to the last committed segments when `session?.stagedSegments` is empty. The `.sleep` cursor in
    // `LocalStore` guards against double-writing — segments whose end is already past the cursor are
    // filtered by `pendingHealthSleep`, so re-using stale segments is harmless.

    /// Persist the last committed sleep segments so they survive session teardown.
    func savePendingSleepSegments(coarse: [SleepSegment], staged: [SleepSegment]) {
        if let data = try? JSONEncoder().encode(coarse) { defaults.set(data, forKey: pendingCoarseSleepKey) }
        if let data = try? JSONEncoder().encode(staged)  { defaults.set(data, forKey: pendingStagedSleepKey) }
    }

    /// Load the last persisted segments, or empty arrays if nothing was saved.
    func loadPendingSleepSegments() -> (coarse: [SleepSegment], staged: [SleepSegment]) {
        let coarse = defaults.data(forKey: pendingCoarseSleepKey)
            .flatMap { try? JSONDecoder().decode([SleepSegment].self, from: $0) } ?? []
        let staged  = defaults.data(forKey: pendingStagedSleepKey)
            .flatMap { try? JSONDecoder().decode([SleepSegment].self, from: $0) } ?? []
        return (coarse, staged)
    }

    /// Clear persisted segments after a confirmed HealthKit write (good hygiene; the `.sleep`
    /// cursor also prevents re-writes so this is not strictly required for correctness).
    func clearPendingSleepSegments() {
        defaults.removeObject(forKey: pendingCoarseSleepKey)
        defaults.removeObject(forKey: pendingStagedSleepKey)
    }
}
