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
//
// ⚠️ AND THE GENEROSITY RULE IS NOT ENOUGH ON ITS OWN — see `trusted(for:)`. The record set this is
// built from is a RETAINED set: `EpochArchiveStore` keeps roughly 30 hours. Absence inside it is
// evidence of absence only where the set could have held the records. Where it could not, the answer
// is UNKNOWN, and this type says so rather than reporting zero coverage.

import Foundation

/// The set of instants a ring's epoch records cover, as merged half-open intervals.
public struct MeasuredCoverage: Equatable, Sendable {

    /// The production epoch cadence — one `0x4c` record every 150 s.
    public static let defaultEpochSeconds: TimeInterval = 150

    /// Merged, ascending, non-overlapping, non-touching `[start, end)` spans.
    public let intervals: [Range<Date>]

    /// The earliest instant this coverage set is ENTITLED TO CALL UNMEASURED. Everything before it
    /// is `.unknown` ground: our records do not reach back that far, so their silence there proves
    /// nothing. `.distantPast` (the default) means "no horizon has been established" — which is what
    /// a raw, un-`trusted` coverage set carries, and why production callers must go through
    /// `trusted(for:)` rather than using one of these directly.
    public let provenFrom: Date

    /// Nothing was recorded anywhere. Distinct from `nil` coverage at a call site, which means
    /// "do not perform a coverage test at all" (the kill switch).
    public static let empty = MeasuredCoverage(intervals: [])

    public init(intervals: [Range<Date>], provenFrom: Date = .distantPast) {
        self.intervals = MeasuredCoverage.merge(intervals)
        self.provenFrom = provenFrom
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
    /// hypnogram LABELS as having measurement underneath it.
    ///
    /// ⚠️ NAMED FOR ITS INPUT ON PURPOSE (S4). This does NOT look at records — it reads back
    /// PROVENANCE LABELS that some earlier call already derived from records. The two are easy to
    /// confuse and the confusion is not hypothetical: an instrument built on a label-derived coverage
    /// reported "0.0 interior-hole minutes across 21 staged nights" when what it had actually
    /// measured was "the staging path emits no `.asserted` labels", which is true by construction and
    /// says nothing at all about holes. A coverage built from records can discover a hole; a coverage
    /// built from labels can only repeat one. Never quote a hole statistic derived from this.
    ///
    /// It exists for the second, independent Health construction in `LocalStore` — the one that
    /// builds extension segments from raw edit anchors and has never seen `SleepEdit.recompute`, so
    /// it holds no records of its own. Reusing the persisted decision keeps the two constructions
    /// from disagreeing about the same night.
    ///
    /// The recovered set carries `provenFrom = .distantPast`: the labels were written by a call that
    /// had already applied `trusted(for:)`, so any span it could not vouch for is labelled
    /// `.assertedCoverageUnknown` and is treated here as covered ground — the conservative reading,
    /// which publishes rather than withholds.
    ///
    /// Returns `nil` when the hypnogram carries NO proven-unmeasured span at all. That is
    /// deliberately ambiguous — it means either "fully covered" or "written before provenance
    /// existed" — and the two must not be conflated, so the caller keeps its previous behaviour
    /// instead of guessing.
    public static func fromProvenanceLabels(_ segments: [SleepSegment]) -> MeasuredCoverage? {
        guard segments.contains(where: { $0.provenance.isProvenUnmeasured }) else { return nil }
        let covered = segments
            .filter { !$0.provenance.isProvenUnmeasured && $0.end > $0.start }
            .map { $0.start ..< $0.end }
        return MeasuredCoverage(intervals: covered)
    }

    // MARK: - The retention guard

    /// The first instant any record covers, or `nil` when nothing is covered.
    public var earliestCovered: Date? { intervals.first?.lowerBound }
    /// The last instant any record covers, or `nil` when nothing is covered.
    public var latestCovered: Date? { intervals.last?.upperBound }

    /// WHETHER THIS RECORD SET IS ENTITLED TO CALL ANY PART OF `window` UNMEASURED — the guard that
    /// stops RETENTION being read as ABSENCE.
    ///
    /// 🟢 THE DEFECT, MEASURED. Coverage is built from `EpochArchiveStore`, a rolling ~30-hour local
    /// archive. Edit a fully-recorded night two days later and every record for it is long gone, so
    /// an un-guarded coverage set reports the whole night as a hole: measured on this branch, the app
    /// published **0.0** asleep minutes to Apple Health where the shipped build published 403.0, and
    /// deleted the previously written samples first. "We no longer hold those records" had become
    /// indistinguishable from "the ring recorded nothing".
    ///
    /// Two rules, and neither carries a fitted constant:
    ///
    /// 1. **AN ALL-EMPTY WINDOW IS UNKNOWN** (`nil`). If not one record falls inside `window`, this
    ///    set has nothing to say about that night: a night we hold no records for and a night the
    ///    ring slept through are the same bytes. It is also the maximum-damage case — every displayed
    ///    minute would be withheld at once — so it is the one that demands the most evidence and has
    ///    the least. 🟢 On the 27-night corpus this rule alone reclaims `R1_2026-08-14` and
    ///    `R1_2026-08-15` (884.6 min), the two nights whose bytes provably are not what the phone
    ///    staged from; before it they were excluded by a hard-coded list of night ids.
    ///
    /// 2. **GROUND OLDER THAN OUR OLDEST RECORD IS UNKNOWN** (`provenFrom`). Retention prunes from
    ///    the FRONT — oldest first — so a record at time *t* proves nothing at or after *t* was
    ///    pruned, and proves nothing at all about what came before the first record we still hold.
    ///    Everything earlier is therefore `.unknown`, never `.unmeasured`.
    ///
    /// THE TRAILING EDGE IS DELIBERATELY NOT GUARDED, and this is the one asymmetry worth arguing
    /// about. Absence AFTER our newest record cannot be explained by retention (which never removes
    /// the newest), only by a drain that has not happened yet — and the edit paths that consume this
    /// run on SETTLED nights, hours after the morning sync. Guarding it would also disable the fix
    /// exactly where it is needed: a wake time dragged hours past where the ring stopped recording is
    /// the archetypal invented-sleep case, 🟢 241.4 min of it on `R2_2026-08-18`.
    ///
    /// - Returns: a copy carrying the proof horizon, or `nil` meaning UNKNOWN — at which point the
    ///   caller must behave exactly as it did before provenance existed. `nil` is the same value the
    ///   kill switch passes, so "we cannot tell" and "do not test" converge on one safe path.
    public func trusted(for window: Range<Date>) -> MeasuredCoverage? {
        guard window.upperBound > window.lowerBound else { return nil }
        guard !measuredPortions(of: window).isEmpty else { return nil }        // rule 1
        guard let earliest = earliestCovered else { return nil }
        return MeasuredCoverage(intervals: intervals, provenFrom: earliest)    // rule 2
    }

    /// What we can say about one stretch of ground.
    public enum Ground: Equatable, Sendable {
        /// Records cover it.
        case measured
        /// No record covers it AND our record set reaches back past it — a proven hole.
        case unmeasured
        /// No record covers it and our record set cannot reach back that far. Absence of evidence.
        case unknown
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

    /// Cut `range` into ascending, contiguous, non-empty pieces each tagged with what we can say
    /// about it. The pieces always tile `range` exactly — this is the primitive `SleepEdit` splits
    /// fills with, so any hole in the tiling would silently drop time off a night.
    ///
    /// A gap earlier than `provenFrom` comes back `.unknown`, and a gap that STRADDLES the horizon is
    /// split at it: the part we can vouch for is `.unmeasured`, the part we cannot is `.unknown`.
    /// With the default `provenFrom` (`.distantPast`) nothing is unknown, so an un-`trusted` coverage
    /// behaves exactly as this method did before the guard existed.
    public func partition(_ range: Range<Date>) -> [(range: Range<Date>, ground: Ground)] {
        guard range.upperBound > range.lowerBound else { return [] }
        var out: [(Range<Date>, Ground)] = []
        func addGap(_ lo: Date, _ hi: Date) {
            guard hi > lo else { return }
            // Split the gap at the proof horizon rather than judging it whole: a leading extension
            // that begins before our oldest record and runs into ground we DO hold is two different
            // claims, and reporting either verdict for both would be wrong in one direction.
            if provenFrom > lo {
                let cut = min(provenFrom, hi)
                out.append((lo ..< cut, .unknown))
                if hi > cut { out.append((cut ..< hi, .unmeasured)) }
            } else {
                out.append((lo ..< hi, .unmeasured))
            }
        }
        var cursor = range.lowerBound
        for m in measuredPortions(of: range) {
            addGap(cursor, m.lowerBound)
            out.append((m, .measured))
            cursor = m.upperBound
        }
        addGap(cursor, range.upperBound)
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
