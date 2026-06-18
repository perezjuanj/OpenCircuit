import Foundation
import OpenRingKit

// Persists the rolling EpochArchive (recent raw 0x4c records) + the last-drain timestamp, so a night
// the ring hands off in MULTIPLE slices can be re-staged from the UNION (stitching), and so the
// periodic-drain cadence is honored ACROSS reconnects (not reset on every brief link flap).
//
// UserDefaults-backed, deliberately NOT SwiftData — a small (~single-digit KB) blob with no schema,
// mirroring ObservabilityStore. Shared between the foreground UI and the background sync task (same
// app process). The pure encode/decode/merge + cadence math live in OpenRingKit (EpochArchive /
// HistoryDrainCadence); this is just the persistence plumbing.
struct EpochArchiveStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let archive = "sleep.epochArchive"
        static let lastDrain = "sleep.lastHistoryDrainAt"
    }

    /// The stored archive (decoded), or `[]` when none yet.
    func load() -> [BulkRecord] {
        guard let data = defaults.data(forKey: Key.archive) else { return [] }
        return EpochArchive.decode(data)
    }

    /// Merge `incoming` into the stored archive (dedup by counter + prune to retention) and persist;
    /// returns the new union for immediate staging.
    @discardableResult
    func merge(_ incoming: [BulkRecord]) -> [BulkRecord] {
        let union = EpochArchive.merge(existing: load(), incoming: incoming)
        defaults.set(EpochArchive.encode(union), forKey: Key.archive)
        return union
    }

    /// When the ring's history buffer was last drained (any drain, incl. an empty one — we still
    /// polled the buffer). Drives `HistoryDrainCadence.isDue` so the cadence survives reconnects.
    var lastDrainAt: Date? {
        let t = defaults.double(forKey: Key.lastDrain)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Stamp a completed drain (foreground, background, or periodic).
    func recordDrain(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastDrain)
    }
}
