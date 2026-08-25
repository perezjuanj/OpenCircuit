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
    /// Last DECIDED HRV-pooling verdict (#185 gate). See `loadHRVPoolingVerdict`.
    private let hrvPoolingKey: String
    /// Counters banked to the archive WITHOUT their vitals samples being persisted. See
    /// `loadUnpersistedCounters`.
    private let unpersistedKey: String

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
        self.hrvPoolingKey = "sleep.hrvPoolingVerdict\(suffix)"
        self.unpersistedKey = "sleep.unpersistedEpochCounters\(suffix)"
    }

    // MARK: Banked-but-unpersisted ledger (#188 follow-up)
    //
    // The archive banks RAW records the moment they are acked; their vitals samples only reach
    // LocalStore when a drain commits. A drain that banks and then dies leaves the two out of step,
    // and nothing downstream could tell which epochs were affected.
    //
    // ⚠️ THE CURSOR CANNOT ANSWER THIS. The first attempt inferred it from `SyncCursor.last(.heartRate)`
    // ("archive newer than the HR watermark was never persisted"). That is unsound: the watermark is a
    // shared forward high-water mark, not a coverage record. `bankUnattributedRecords` persists orphan
    // samples 35 lines EARLIER in the same `performHistoryDrain`, and `stopLiveMonitoring` persists a
    // live HR stamped at ≈now — either one pushes the watermark past genuinely unpersisted history and
    // silently blinds the probe. An explicit ledger is exact and order-independent.

    /// Counters banked to the archive whose samples have not reached LocalStore yet.
    func loadUnpersistedCounters() -> Set<UInt32> {
        guard let raw = defaults.array(forKey: unpersistedKey) as? [NSNumber] else { return [] }
        return Set(raw.map { $0.uint32Value })
    }

    /// Note that `counters` were banked without persisting their samples. Idempotent (a set).
    func markUnpersisted(_ counters: some Sequence<UInt32>) {
        let updated = StrandedEpochLedger.mark(ledger: loadUnpersistedCounters(), banked: counters)
        guard !updated.isEmpty else { return }
        defaults.set(updated.map { NSNumber(value: $0) }, forKey: unpersistedKey)
    }

    /// Retire `counters` once a commit has run them through `persist`.
    ///
    /// Retired unconditionally, NOT only when a sample was produced: an `.idle` (unworn/charging)
    /// record yields no samples at all, so a yield-based rule would re-select it on every drain
    /// forever — the archive prunes by age and these are the NEWEST records, so retention could never
    /// clear them either. One pass through `persist` is all the recovery that exists.
    func clearUnpersisted(_ counters: some Sequence<UInt32>) {
        let remaining = StrandedEpochLedger.retire(ledger: loadUnpersistedCounters(), committed: counters)
        if remaining.isEmpty { defaults.removeObject(forKey: unpersistedKey) }
        else { defaults.set(remaining.map { NSNumber(value: $0) }, forKey: unpersistedKey) }
    }

    /// The last DECIDED HRV-pooling verdict for this ring (#185 regression gate), or nil before the
    /// first decision. Persisted per ring for the same reason the archive is: the verdict describes
    /// the ring's own two record templates, so it must never be shared between rings.
    func loadHRVPoolingVerdict() -> BulkSleep.HRVPooling? {
        switch defaults.string(forKey: hrvPoolingKey) {
        case "agree": return .agree
        case "disagree": return .disagree
        default: return nil          // never persist `.noEvidence` — it is the ABSENCE of a decision
        }
    }

    /// Record a DECIDED verdict. `.noEvidence` is deliberately not persistable: it means "this run
    /// could not judge", which must leave any earlier decision standing rather than erase it.
    func saveHRVPoolingVerdict(_ verdict: BulkSleep.HRVPooling) {
        switch verdict {
        case .agree: defaults.set("agree", forKey: hrvPoolingKey)
        case .disagree: defaults.set("disagree", forKey: hrvPoolingKey)
        case .noEvidence: break
        }
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
    //
    // ⚠️ "SAVE NOTHING" AND "CLEAR" ARE DIFFERENT OPERATIONS — do not collapse them.
    // `savePendingSleepSegments` PUBLISHES what one drain staged. A pass that staged nothing is the
    // ABSENCE of a publication, not an instruction to forget the last good one, so it must leave the
    // stored pair standing. The write used to be unconditional, and that was live collateral of the
    // #204 `noStagedSegments` defect: on the 2026-08-24 tester export the three consecutive drains at
    // 09:48:57 / 09:57:09 / 10:17:01 local all reported `nightRowOutcome: noStagedSegments` with
    // `stagedSleepSegments: 0`, so each was a pass that staged nothing while the relaunch fallback
    // `ContentView.flushHealth()` reads was the only surviving copy.
    // ⚠️ Stated precisely, because review pushed on it: the export proves the three EMPTY STAGINGS,
    // not that this function ran on each of them — `savePendingSleepSegments` is reached only via
    // `commitDecision == .stage`, and the export carries no field that witnesses that branch. The
    // defect class is what is established; the per-row causal step is not. The new
    // "STAGED NOTHING — kept previously persisted" log line makes it directly observable on the next
    // tester night instead of inferred.
    // The explicit clear is `clearPendingSleepSegments()`, called from
    // `RingScanner.clearLastCommittedSleepSegments()` after a CONFIRMED HealthKit write. That is the
    // only path that may zero the slot, and it stays unconditional.

    /// Publish the sleep segments a committed drain just staged, so they survive session teardown.
    ///
    /// The two arrays are ONE drain's two views of the same night (`coarse` = wear-gated motion
    /// segments, `staged` = the preferred HR-aware hypnogram) and are therefore written as an atomic
    /// pair: `ContentView.flushHealth()` picks `staged` when non-empty and falls back to `coarse`, so
    /// letting the slots come from two different passes could leave a stale `staged` permanently
    /// shadowing a fresher `coarse` (the flush only clears the slot after a write that produced
    /// segments, and a cursor-filtered stale set produces none — it would never self-heal).
    /// An empty member is therefore allowed to clear its slot ONLY when its pair-mate carries a real
    /// publication from the same pass; a pass with nothing in either slot writes neither.
    func savePendingSleepSegments(coarse: [SleepSegment], staged: [SleepSegment]) {
        guard !coarse.isEmpty || !staged.isEmpty else { return }
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
