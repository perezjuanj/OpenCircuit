// Non-destructive nightly-sleep-summary merge policy.
//
// The ring's onboard history buffer holds only ~114 epochs (~4.75 h) and DROPS THE OLDEST when
// full (proven from the device unified log, night of 2026-06-17→18: a single morning sync drained
// records=114 ≈ 4.75 h — the early, deep-sleep-rich half had already been overwritten on the ring
// because nothing synced for ~9 h). A later sync therefore often drains only a PARTIAL slice of the
// night. `LocalStore.saveSleepSummary` upserts by start-of-day, and blindly overwriting let a 4 h
// morning fragment clobber a fuller capture for the same date.
//
// This pure policy decides whether a freshly-staged night should REPLACE the stored one: a shorter
// slice can never shrink a fuller night for the same date. Pure (no Apple frameworks) so it
// unit-tests on the CLI, matching `KeepaliveCadence` / `ReconnectBackoff`.
//
// SCOPE / LIMITS: this keeps the single MOST-COMPLETE drain (widest in-bed span); it does NOT stitch
// two DISJOINT partial slices into one night — that needs per-epoch persistence + re-staging from the
// union (the planned follow-up that also unlocks SAFE periodic overnight draining). With today's
// drain sites (one real overnight drain in the morning, plus the occasional background drain) this is
// non-regressive vs. blind overwrite — it can only keep a FULLER night, never a smaller one. The one
// edge it does NOT improve: two equal-span DISJOINT slices replace each other by arrival order (the
// `>=`), which only matters once something drains a night in many equal pieces — i.e. exactly the
// periodic-drain feature that must wait for stitching. Until then this is a strict improvement.

import Foundation

public enum SleepSummaryMerge {

    /// Whether a newly-staged night should REPLACE the stored summary for the same date.
    ///
    /// - Parameters:
    ///   - storedInBed: the stored row's in-bed span (seconds); pass `0` for a legacy row with no
    ///     valid clock window (`inBedEnd <= inBedStart`).
    ///   - newInBed: the freshly-staged in-bed span (seconds).
    /// - Returns: `true` to overwrite. Replace only when the new capture is at least as COMPLETE —
    ///   its in-bed span is not shorter than the stored one (longer/equal span ⇒ it covers at least
    ///   as much of the night). A stored span of `0` (or non-positive) is always replaced, so the
    ///   first real capture of a night always lands.
    public static func shouldReplace(storedInBed: TimeInterval, newInBed: TimeInterval) -> Bool {
        guard storedInBed > 0 else { return true }
        return newInBed >= storedInBed
    }
}
