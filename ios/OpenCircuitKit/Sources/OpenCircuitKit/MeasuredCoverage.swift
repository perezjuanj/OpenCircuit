// WHICH MINUTES OF A NIGHT THE RING ACTUALLY RECORDED.
//
// The set M of instants covered by at least one epoch record: for every record at time t, the
// half-open span [t, t + epochSeconds). Merged, sorted, and queryable.
//
// WHY THIS EXISTS. `SleepEdit.recompute` took no record timestamps and performed no coverage test.
// It could not tell a user's window extension over dense data from one over four hours of nothing,
// so it treated both as sleep. This type is the missing input. It is deliberately a pure value with
// no dependency on the store, the archive, or HealthKit, so the same object can be built in the app,
// in a test from raw `.b64` bytes, and in the replay harness, and all three agree by construction.
//
// EPOCH LENGTH. 🟢 Measured 2026-08-20 on the two tester nights that motivated this work: the median
// inter-record delta (over deltas under 600 s) is exactly 150.0 s on both — n=165 on 2026-08-17 and
// n=385 on 2026-08-18. `BulkRecord.epochSeconds` is the production constant and is what callers
// should pass; `defaultEpochSeconds` mirrors it for tests that hold no `BulkRecord`.
//
// THE GENEROSITY RULE. Coverage is always computed from the WIDEST record set available, not from
// the night's slice. Every minute this type calls unmeasured is unmeasured under the app's own best
// case, so a claim built on it can never be an artifact of a narrow window.

import Foundation

/// The set of instants a ring's epoch records cover, as merged half-open intervals.
public struct MeasuredCoverage: Equatable, Sendable {

    /// The production epoch cadence — one `0x4c` record every 150 s.
    public static let defaultEpochSeconds: TimeInterval = 150

    /// Merged, ascending, non-overlapping, non-touching `[start, end)` spans.
    public let intervals: [Range<Date>]

    /// Nothing was recorded anywhere. Distinct from `nil` coverage at a call site, which means
    /// "do not perform a coverage test at all" (the kill switch).
    public static let empty = MeasuredCoverage(intervals: [])

    public init(intervals: [Range<Date>]) {
        self.intervals = MeasuredCoverage.merge(intervals)
    }

    /// Build from record timestamps: each record covers `[t, t + epochSeconds)`.
    public init(recordDates: [Date], epochSeconds: TimeInterval = defaultEpochSeconds) {
        let span = max(0, epochSeconds)
        guard span > 0 else { self.init(intervals: []); return }
        self.init(intervals: recordDates.map { $0 ..< $0.addingTimeInterval(span) })
    }

    /// Build from decoded epoch records. The one-liner every production caller wants.
    /// `epoch` is the sync epoch the counters are relative to — the same default `BulkSleep` uses.
    public init(records: [BulkRecord],
                epoch: Int = Command.syncEpoch,
                epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds)) {
        self.init(recordDates: records.map { $0.date(epoch: epoch) }, epochSeconds: epochSeconds)
    }

    public var isEmpty: Bool { intervals.isEmpty }

    /// Recover the coverage decision already recorded in a stored hypnogram: everything the
    /// hypnogram covers EXCEPT its `.asserted` spans.
    ///
    /// This is for the second, independent Health construction in `LocalStore` — the one that builds
    /// extension segments from raw edit anchors and has never seen `SleepEdit.recompute`, so it
    /// holds no records of its own. Reusing the persisted decision keeps the two constructions from
    /// disagreeing about the same night.
    ///
    /// Returns `nil` when the hypnogram carries NO asserted span at all. That is deliberately
    /// ambiguous — it means either "fully covered" or "written before provenance existed" — and the
    /// two must not be conflated, so the caller keeps its previous behaviour instead of guessing.
    public static func fromStoredHypnogram(_ segments: [SleepSegment]) -> MeasuredCoverage? {
        guard segments.contains(where: { $0.provenance.isUnmeasured }) else { return nil }
        let covered = segments
            .filter { !$0.provenance.isUnmeasured && $0.end > $0.start }
            .map { $0.start ..< $0.end }
        return MeasuredCoverage(intervals: covered)
    }

    /// Total measured time inside `range`.
    public func measuredDuration(in range: Range<Date>) -> TimeInterval {
        measuredPortions(of: range).reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
    }

    /// Fraction of `range` that is measured, 0…1. Returns 0 for an empty or reversed range —
    /// callers that must distinguish "no coverage" from "no range" should check the range first.
    public func fraction(of range: Range<Date>) -> Double {
        let total = range.upperBound.timeIntervalSince(range.lowerBound)
        guard total > 0 else { return 0 }
        return measuredDuration(in: range) / total
    }

    /// The measured sub-spans of `range`, ascending.
    public func measuredPortions(of range: Range<Date>) -> [Range<Date>] {
        guard range.upperBound > range.lowerBound else { return [] }
        var out: [Range<Date>] = []
        for iv in intervals {
            if iv.upperBound <= range.lowerBound { continue }
            if iv.lowerBound >= range.upperBound { break }
            let lo = max(iv.lowerBound, range.lowerBound)
            let hi = min(iv.upperBound, range.upperBound)
            if hi > lo { out.append(lo ..< hi) }
        }
        return out
    }

    /// The UNMEASURED sub-spans of `range`, ascending — the complement of `measuredPortions`.
    public func unmeasuredPortions(of range: Range<Date>) -> [Range<Date>] {
        guard range.upperBound > range.lowerBound else { return [] }
        var out: [Range<Date>] = []
        var cursor = range.lowerBound
        for m in measuredPortions(of: range) {
            if m.lowerBound > cursor { out.append(cursor ..< m.lowerBound) }
            cursor = max(cursor, m.upperBound)
        }
        if cursor < range.upperBound { out.append(cursor ..< range.upperBound) }
        return out
    }

    /// The longest single unmeasured run inside `range`, in seconds. 0 when fully covered.
    public func longestGap(in range: Range<Date>) -> TimeInterval {
        unmeasuredPortions(of: range)
            .map { $0.upperBound.timeIntervalSince($0.lowerBound) }
            .max() ?? 0
    }

    /// Cut `range` into ascending, contiguous, non-empty pieces each tagged measured or not.
    /// The pieces always tile `range` exactly — this is the primitive `SleepEdit` splits fills with,
    /// so any hole in the tiling would silently drop time off a night.
    public func partition(_ range: Range<Date>) -> [(range: Range<Date>, measured: Bool)] {
        guard range.upperBound > range.lowerBound else { return [] }
        var out: [(Range<Date>, Bool)] = []
        var cursor = range.lowerBound
        for m in measuredPortions(of: range) {
            if m.lowerBound > cursor { out.append((cursor ..< m.lowerBound, false)) }
            out.append((m, true))
            cursor = m.upperBound
        }
        if cursor < range.upperBound { out.append((cursor ..< range.upperBound, false)) }
        return out
    }

    // MARK: - Internals

    /// Sort and coalesce. Touching spans (`a.upperBound == b.lowerBound`) merge too: consecutive
    /// 150 s epochs are exactly touching, and leaving them separate would make `partition` emit
    /// hundreds of zero-length "gaps" for a perfectly continuous night.
    private static func merge(_ raw: [Range<Date>]) -> [Range<Date>] {
        let sorted = raw.filter { $0.upperBound > $0.lowerBound }.sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Date>] = []
        for iv in sorted {
            if let last = out.last, iv.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound ..< max(last.upperBound, iv.upperBound)
            } else {
                out.append(iv)
            }
        }
        return out
    }
}
