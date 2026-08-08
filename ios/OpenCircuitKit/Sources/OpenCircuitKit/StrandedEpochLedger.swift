// Which banked epochs still owe their vitals samples to LocalStore (#188 follow-up).
//
// THE PROBLEM. The EpochArchive banks RAW records the moment they are acked (that is the whole point
// — an acked page can never be re-offered). Their HR/HRV/SpO₂/RR rows only reach LocalStore when a
// drain COMMITS, because `BulkSleep.samples` runs off the drain's in-memory buffer. A drain that
// banks and then dies leaves the two out of step: the night's sleep summary heals from the archive,
// its vitals do not, and the forward-only `SyncCursor` means nothing ever comes back for them.
//
// ⚠️ WHY NOT INFER IT FROM THE CURSOR. The first attempt at this asked "which archive records are
// NEWER than `SyncCursor.last(.heartRate)`?" That is unsound, and adversarial review caught it: the
// watermark is a shared forward high-water mark, not a coverage record. Two writers push it past
// genuinely unpersisted history — `bankUnattributedRecords` persists orphan samples earlier in the
// SAME `performHistoryDrain`, and `stopLiveMonitoring` persists a live HR stamped at ≈now, which is
// newer than every history record by construction. Either one silently reduces the fix to a no-op in
// its own flagship scenario. An explicit ledger is exact and order-independent.
//
// Pure so the two directions (select / retire) are unit-tested rather than reasoned about inline —
// the store that persists this lives in the app target, whose XCTest suite is the known-dead
// container-lifetime one.

import Foundation

public enum StrandedEpochLedger {

    /// Add newly banked-without-persisting counters. Idempotent.
    public static func mark(ledger: Set<UInt32>, banked: some Sequence<UInt32>) -> Set<UInt32> {
        ledger.union(banked)
    }

    /// Retire counters that a commit has now run through `persist`.
    ///
    /// ⚠️ Retire UNCONDITIONALLY, not only when a sample was produced. An `.idle` (unworn/charging)
    /// record decodes no HR, HRV or RR at all, so a yield-based rule would re-select it on every
    /// drain forever — and because the archive prunes by AGE while these are the NEWEST records,
    /// retention could never clear them either. One pass through `persist` is all the recovery that
    /// exists for an epoch.
    public static func retire(ledger: Set<UInt32>, committed: some Sequence<UInt32>) -> Set<UInt32> {
        ledger.subtracting(committed)
    }

    /// The archive records a drain should fold into its own buffer so they ride its single `persist`.
    ///
    /// `alreadyHeld` excludes records the drain has in hand (e.g. adopted orphans): `EpochArchive`
    /// dedups by counter but `LocalStore.ingest` has no WITHIN-batch dedup, so a duplicate here would
    /// insert the same epoch twice.
    public static func select(archive: [BulkRecord],
                              ledger: Set<UInt32>,
                              alreadyHeld: Set<UInt32>) -> [BulkRecord] {
        guard !ledger.isEmpty else { return [] }
        return archive.filter { ledger.contains($0.counter) && !alreadyHeld.contains($0.counter) }
    }
}
