// Rolling archive of recent 0x4c epoch records — the foundation for stitching a night that the
// ring hands off in MORE THAN ONE drain.
//
// WHY THIS EXISTS. The ring's onboard history buffer holds only ~114 epochs (~4.75 h) and drops the
// oldest when full (see ring-history-buffer notes / PROTOCOL §5.3). To stop overnight sleep being
// lost we must drain that buffer periodically — but each drain returns only the slice since the last
// one (the ring advances its resume pointer on ACK), and sleep STAGING needs the per-epoch motion
// channel `[10:15]`, which is NOT recoverable from the derived HR/HRV/SpO₂ samples we persist. So we
// keep the raw records around and re-stage the night from the UNION of all of them.
//
// The on-disk form is dead simple: a `0x4c` record is a fixed 23 bytes, so the archive serializes as
// the records' raw bytes concatenated, and decodes with the same `BulkSleep.records(fromStream:)`
// used for a live page. Pure (no Apple frameworks) so it unit-tests on the CLI; the app layer wraps
// `encode`/`decode` around a UserDefaults blob.

import Foundation

public enum EpochArchive {

    /// How much history to retain (seconds). ~30 h comfortably covers "last night" even after a
    /// lie-in or a late first sync, with margin for a missed day. NOTE: 30 h > 24 h, so the archive
    /// can hold TWO nights — staging must therefore scope to the most recent night itself
    /// (`BulkSleep.latestNightRecords`), never assume retention leaves only one. Counters are
    /// epoch-seconds, so this is compared directly against counter deltas.
    public static let retention: TimeInterval = 30 * 3600

    /// Merge `incoming` records into `existing`: dedup by counter (an epoch is uniquely keyed by its
    /// counter; a later drain's copy wins on collision), sort ascending by counter, and prune
    /// anything older than `retention` before the newest record. Returns the new archive.
    public static func merge(existing: [BulkRecord],
                             incoming: [BulkRecord],
                             retention: TimeInterval = retention) -> [BulkRecord] {
        guard !existing.isEmpty || !incoming.isEmpty else { return [] }
        var byCounter: [UInt32: BulkRecord] = [:]
        byCounter.reserveCapacity(existing.count + incoming.count)
        for r in existing { byCounter[r.counter] = r }
        for r in incoming { byCounter[r.counter] = r }   // a fresher drain overrides an older copy
        let all = byCounter.values.sorted { $0.counter < $1.counter }
        guard let newest = all.last?.counter else { return [] }
        // Counter is UInt32 seconds; guard the subtraction so a small newest can't underflow.
        let span = UInt32(retention)
        let cutoff = newest > span ? newest - span : 0
        return all.filter { $0.counter >= cutoff }
    }

    /// Serialize to a flat blob (concatenated 23-byte records) for persistence.
    public static func encode(_ records: [BulkRecord]) -> Data {
        Data(records.flatMap { $0.raw })
    }

    /// Decode a blob back into records (a trailing partial chunk, if any, is dropped).
    public static func decode(_ data: Data) -> [BulkRecord] {
        BulkSleep.records(fromStream: [UInt8](data))
    }
}
