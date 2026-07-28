// Decide WHICH active-energy increments to write to Apple Health, and where.
//
// `ActiveEnergyWindow` answered "one delta already exists — what window does it belong in?".
// This answers the question before it: given the day attributed into buckets
// (`Calories.EnergyBucket`) and a record of what each bucket has already contributed, which
// buckets owe kcal right now?
//
// The defect this replaces: the writer kept ONE scalar high-water mark for the whole day and
// wrote `estimate - written`. Because the legacy estimate is `max(hrKcal, stepKcal)` over two
// whole-day snapshots, it stops growing the moment the last elevated-HR bout ends — so the delta
// was exactly 0.000 on every flush for the rest of the day and Apple Health showed a hard stop
// mid-afternoon (tester, 2026-07-28). A per-bucket mark cannot behave that way: an afternoon
// bucket that earns walking energy owes it regardless of what the morning did.
//
// HealthKit SUMS `activeEnergyBurned`, so a double write is PERMANENT in the user's Health store.
// Every rule here is built around that: marks advance only on a confirmed save, debts are consumed
// exactly once, and buckets are addressed by their ordinal from local midnight — never by array
// position, since a late drain inserts an EARLIER bucket and positional indexing would re-pay
// everything after it.
//
// Pure Foundation, no HealthKit — same seam as `ActiveEnergyWindow` / `StepAccumulator`.

import Foundation

public enum ActiveEnergyLedger {

    /// One active-energy sample to save: `kcal` accrued over `[start, end]`.
    public struct Write: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let kcal: Double

        public init(start: Date, end: Date, kcal: Double) {
            self.start = start
            self.end = end
            self.kcal = kcal
        }
    }

    /// What to save now, and the state to persist ONLY IF the save succeeds.
    public struct Plan: Equatable, Sendable {
        public let writes: [Write]
        /// Per-bucket kcal accounted for, indexed by ordinal from `dayStart`. Commit verbatim.
        public let watermarks: [Double]
        /// Legacy-seed debt still unconsumed.
        public let carryRemaining: Double
        /// Workout kcal netted out by this plan; add it to the credited-so-far mark on success.
        public let workoutConsumed: Double

        public var totalKcal: Double { writes.reduce(0) { $0 + $1.kcal } }

        public init(writes: [Write], watermarks: [Double],
                    carryRemaining: Double, workoutConsumed: Double) {
            self.writes = writes
            self.watermarks = watermarks
            self.carryRemaining = carryRemaining
            self.workoutConsumed = workoutConsumed
        }
    }

    /// Minimum AGGREGATE kcal before anything is saved, matching the old `delta >= 1.0` gate.
    ///
    /// Deliberately applied to the day's whole pending sum and never per bucket: light constant
    /// walking is worth well under 1 kcal per 15 minutes, so a per-bucket floor would strand every
    /// such bucket forever — the reported bug reproduced in miniature.
    public static let minWriteKcal = 1.0

    public static func ordinal(_ t: Date, dayStart: Date, bucketSeconds: TimeInterval) -> Int {
        guard bucketSeconds > 0 else { return 0 }
        return Int((t.timeIntervalSince(dayStart) / bucketSeconds).rounded(.down))
    }

    /// Decide what to write.
    ///
    /// Debt (`carry`, then `uncreditedWorkoutKcal`) is consumed FIFO from the OLDEST pending
    /// increments. Consumed kcal still advances its bucket's watermark — it has been accounted
    /// for, just not by a write — otherwise the same debt would be re-applied on every flush and
    /// the energy could never be written.
    ///
    /// Returns an empty plan with UNCHANGED state when the writable total is below
    /// `minWriteKcal`: the kcal stays owed and rides the next flush, exactly as the old
    /// skip-and-owe semantics did.
    public static func plan(buckets: [Calories.EnergyBucket],
                            watermarks: [Double],
                            dayStart: Date,
                            now: Date,
                            carry: Double = 0,
                            uncreditedWorkoutKcal: Double = 0,
                            savedKcal: Double = 0,
                            bucketSeconds: TimeInterval = Calories.energyBucketSeconds,
                            minWriteKcal: Double = minWriteKcal) -> Plan {
        let unchanged = Plan(writes: [], watermarks: watermarks,
                             carryRemaining: carry, workoutConsumed: 0)
        // An empty bucket set means "no data yet", NOT "the day lost its energy" — returning here
        // keeps the fall-netting below from reading a still-empty morning as a giant overpayment.
        guard bucketSeconds > 0, !buckets.isEmpty else { return unchanged }

        var byOrdinal: [Int: Double] = [:]
        var windows: [Int: (start: Date, end: Date)] = [:]
        for bucket in buckets.sorted(by: { $0.start < $1.start }) {
            let o = ordinal(bucket.start, dayStart: dayStart, bucketSeconds: bucketSeconds)
            guard o >= 0 else { continue }
            byOrdinal[o, default: 0] += bucket.activeKcal
            windows[o] = (bucket.start, Swift.min(bucket.end, now))
        }
        guard let highest = byOrdinal.keys.max() else { return unchanged }

        var marks = watermarks
        if marks.count <= highest {
            marks.append(contentsOf: Array(repeating: 0, count: highest + 1 - marks.count))
        }

        var carryLeft = Swift.max(0, carry)

        // A bucket's attributed energy can FALL between flushes — a later drain inserts an earlier
        // HR point that re-prices a piece, the sleep window widens over morning HR, a store recovery
        // drops rows. Per-bucket high-water marks alone would keep the inflated mark and pay a rise
        // elsewhere in full, so Health would drift permanently high (activeEnergyBurned SUMS, and it
        // cannot be reconciled back down). Lower the mark and carry the shortfall as debt, so the
        // day nets out exactly the way the single day-scalar this replaced always did.
        for o in marks.indices where marks[o] > 0 {
            let current = byOrdinal[o] ?? 0
            guard current < marks[o] else { continue }
            carryLeft += marks[o] - current
            marks[o] = current
        }

        // Pending increments, oldest first, with the window each would be written over.
        var pending: [(ordinal: Int, start: Date, end: Date, kcal: Double)] = []
        for o in byOrdinal.keys.sorted() {
            let increment = (byOrdinal[o] ?? 0) - marks[o]
            guard increment > 0, let window = windows[o] else { continue }
            // A bucket still in progress is written up to `now`, never into the future.
            guard window.end > window.start else { continue }  // wholly ahead of now — stays owed
            pending.append((o, window.start, window.end, increment))
        }
        guard !pending.isEmpty else {
            // Nothing to write, but a fall may still have been netted — hand back the debt so the
            // caller can persist it, otherwise the overpayment is forgotten and re-paid later.
            return carryLeft > Swift.max(0, carry)
                ? Plan(writes: [], watermarks: marks, carryRemaining: carryLeft, workoutConsumed: 0)
                : unchanged
        }

        var workoutLeft = Swift.max(0, uncreditedWorkoutKcal)
        var writes: [Write] = []

        for item in pending {
            var remaining = item.kcal
            let fromCarry = Swift.min(remaining, carryLeft)
            remaining -= fromCarry
            carryLeft -= fromCarry
            let fromWorkout = Swift.min(remaining, workoutLeft)
            remaining -= fromWorkout
            workoutLeft -= fromWorkout
            // The whole increment is accounted for either way — written, or netted against debt.
            marks[item.ordinal] += item.kcal
            if remaining > 0 {
                writes.append(Write(start: item.start, end: item.end, kcal: remaining))
            }
        }

        // Day-total backstop. The marks say WHERE energy sits; this says how much the day is worth
        // in total. Any path that relocates energy between buckets without the marks following —
        // a store recovery that rebuilds the day from fewer rows, a mid-day fall back to the
        // single-delta path, the residual step reconciliation moving to a different bucket — could
        // otherwise re-pay kcal Health already holds. Clamping to what the day is still worth makes
        // that structurally impossible, and it only ever REDUCES a write.
        let dayTotal = byOrdinal.values.reduce(0, +)
        var headroom = Swift.max(0, dayTotal - Swift.max(0, savedKcal))
        var clamped: [Write] = []
        for write in writes {
            guard headroom > 0 else { break }
            let kcal = Swift.min(write.kcal, headroom)
            headroom -= kcal
            clamped.append(Write(start: write.start, end: write.end, kcal: kcal))
        }
        writes = clamped

        let writable = writes.reduce(0) { $0 + $1.kcal }
        guard writable >= minWriteKcal else { return unchanged }

        return Plan(writes: writes,
                    watermarks: marks,
                    carryRemaining: carryLeft,
                    workoutConsumed: Swift.max(0, uncreditedWorkoutKcal) - workoutLeft)
    }

    /// Upgrade-day seeding: convert the single legacy `writtenKcal` scalar into per-bucket marks.
    ///
    /// Fills buckets chronologically until the scalar is exhausted, so a user who upgrades
    /// mid-afternoon writes only the energy the old code never got to — landing in the buckets
    /// where they actually earned it — instead of re-paying the morning. Any excess (the legacy
    /// mark exceeding today's attributed total, e.g. because a workout credit was already netted)
    /// becomes `carry`, consumed FIFO by later increments so a growing bucket cannot re-pay
    /// energy Health already holds.
    public static func seed(buckets: [Calories.EnergyBucket],
                            legacyWrittenKcal: Double,
                            dayStart: Date,
                            bucketSeconds: TimeInterval = Calories.energyBucketSeconds)
        -> (watermarks: [Double], carry: Double) {
        var remaining = Swift.max(0, legacyWrittenKcal)
        var marks: [Double] = []
        guard bucketSeconds > 0 else { return ([], remaining) }

        for bucket in buckets.sorted(by: { $0.start < $1.start }) {
            let o = ordinal(bucket.start, dayStart: dayStart, bucketSeconds: bucketSeconds)
            guard o >= 0 else { continue }
            if marks.count <= o { marks.append(contentsOf: Array(repeating: 0, count: o + 1 - marks.count)) }
            let fill = Swift.min(bucket.activeKcal, remaining)
            marks[o] = fill
            remaining -= fill
        }
        return (marks, remaining)
    }
}
