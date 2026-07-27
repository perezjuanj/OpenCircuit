// Where in the day an active-energy DELTA gets stamped in Apple Health.
//
// THE BUG THIS EXISTS TO FIX (tester report 2026-07-27: "it says I burned 300 calories at 12am
// today — this was while I was laying in bed"). `HealthKitWriter.flushActiveCalories` computes a
// running daily active-energy total and writes the DELTA since the last flush, which is correct
// arithmetic — HealthKit SUMs `activeEnergyBurned`, so the day's total lands right. But every
// delta was stamped `start: startOfDay, end: startOfDay + 1h`, so Apple Health's Activity chart
// apportioned the WHOLE DAY's active energy into the 00:00–01:00 bar. The number was right; the
// placement said the user burned it all while asleep.
//
// (The sibling basal path `writePassiveCalories` uses the same `date … date+3600` shape and is
// FINE — `flushPassiveCalories` walks a real per-hour watermark. Active energy copied the sample
// shape without copying the loop.)
//
// WHY A SEPARATE PURE TYPE. The clamps below are the entire correctness surface of the fix and
// each one guards a specific, non-obvious way a naive `[lastFlush, now]` window goes wrong —
// several of them silently and PERMANENTLY corrupting historical days in Health. `HealthKitWriter`
// is `@MainActor` and builds a live `HKHealthStore`, so it cannot be unit-tested; this is Date math
// with no HealthKit types, so it can be. Matches the LiveMeasureOwnership / StepAccumulator /
// HistoryDrainCadence pattern.
//
// ⚠️ KNOWN RESIDUAL (deliberate, documented — NOT fixed here). `Calories.dailyEstimate` prices the
// day with the whole-day AVERAGE qualifying HR, so a hard 19:00 session retroactively re-prices
// every elevated minute earned since 08:00. The delta is therefore part new-energy and part
// revaluation of hours already past, and windowing it can only ever be approximate. This type
// bounds the damage (never before the day, never into the sleep the estimate already excluded);
// it does not make the estimate additive. The real fix is per-interval Keytel integration —
// attribute each HR interval's own kcal to its own window — which changes the daily total's
// derivation and so wants its own change + validation cycle.
//
// Pure (no Apple frameworks beyond Foundation) so it unit-tests on the CLI.

import Foundation

public enum ActiveEnergyWindow {

    /// Ceiling on how fast a window is allowed to imply energy was burned, kcal per minute.
    ///
    /// The window ends at the flush's wall-clock `now`, but the DELTA it carries comes from data
    /// that arrives in BULK and out of order — a drain after hours out of range banks a whole
    /// afternoon of HR at once. Without a floor on width, a flush 25 s after the previous one can
    /// carry that entire afternoon: Apple Health then permanently records e.g. 190 kcal burned in
    /// 44 seconds, an order of magnitude past any human burn rate, sitting in whichever hour bar the
    /// SYNC happened to land in. That is the same defect class this type exists to fix (energy
    /// placed when we synced, not when it was earned), so a delta too large for its elapsed window
    /// widens the window backwards instead of spiking.
    ///
    /// 20 kcal/min is deliberately generous — around the peak sustained output of an elite athlete,
    /// so it can never clip a genuine reading from a ring-derived ESTIMATE. It is a sanity bound on
    /// placement, not a physiological model.
    public static let maxPlausibleKcalPerMinute = 20.0

    /// Widen `start` backwards (never past `dayStart`) until the window is wide enough that `kcal`
    /// over it does not exceed `maxPlausibleKcalPerMinute`. Returns `start` unchanged when the
    /// window is already plausible or `kcal` is non-positive.
    static func widenedStart(_ start: Date, end: Date, kcal: Double, dayStart: Date) -> Date {
        guard kcal > 0 else { return start }
        let needed = (kcal / maxPlausibleKcalPerMinute) * 60.0      // seconds
        guard end.timeIntervalSince(start) < needed else { return start }
        return max(dayStart, end.addingTimeInterval(-needed))
    }

    /// The time window one active-energy delta should be stamped over, or `nil` when there is no
    /// legal window and the caller must NOT write (writing anyway is what corrupts Health).
    ///
    /// The window always ends at `now` and starts at the LATEST of the lower bounds below — each is
    /// a floor, and taking the max means the tightest applicable one wins:
    ///
    /// - `dayStart` — **the load-bearing clamp.** Every other date here comes from `UserDefaults`,
    ///   where an unset key reads back as `0` ⇒ `Date(timeIntervalSince1970: 0)` ⇒ 1970-01-01. Without
    ///   this floor the first flush after install/upgrade would write a sample spanning FIVE DECADES
    ///   and Health would apportion today's kcal across all of it. The same clamp is what stops a
    ///   multi-day quiet spell (app not opened, no BGTask ever ran) from stamping today's delta
    ///   backwards across days whose totals were already final — an unretractable inflation of
    ///   history, since `flushActiveCalories` only ever computes TODAY and never backfills.
    ///
    /// - `anchor` — the end of the last window we SUCCESSFULLY wrote today. Keeps consecutive deltas
    ///   non-overlapping so HealthKit's SUM stays exact. Must be advanced by the caller only after a
    ///   confirmed write, mirroring how `hk.activeEnergy.writtenKcal` is only advanced on success:
    ///   advancing it on a skipped/failed write would consume elapsed time that no sample covers, and
    ///   the next real delta would then land compressed into a short window as a false spike.
    ///
    /// - `notBefore` — the earliest moment this energy could plausibly have accrued. In practice the
    ///   caller passes the end of the sleep window, because `Calories.dailyEstimate` has ALREADY
    ///   excluded sleep-window HR from the estimate. Without it the day's first flush — which after
    ///   overnight-quiet is typically the ~07:00–11:00 wake catch-up — would be `[00:00, 09:00]` and
    ///   smear the morning's energy back across the whole night. That is the reported bug wearing a
    ///   different hat: it would still show energy at 12am, and it would put it into hours the app
    ///   itself determined had none, contaminating Health's sleep views.
    ///
    /// Returns `nil` when the resulting window is empty or inverted (`start >= now`). That happens on
    /// a clock step-back, a restored backup, or simply two flushes inside the same second. Returning
    /// `nil` — rather than clamping to a zero-width sample — matters because `HKHealthStore.save`
    /// REJECTS `end < start`: the throw would leave both the kcal watermark and the anchor unadvanced,
    /// and active energy would then fail on every subsequent flush until wall-clock passed the anchor.
    /// A skipped window is self-healing (the kcal is still owed and rides into the next delta);
    /// a stuck watermark is not.
    public static func resolve(anchor: Date?,
                               notBefore: Date?,
                               now: Date,
                               dayStart: Date,
                               kcal: Double = 0) -> DateInterval? {
        guard dayStart < now else { return nil }

        // A FUTURE anchor is discarded, not honoured. It happens on a clock step-forward (bad RTC
        // before NTP, a restored backup, a user setting the date) and if it were kept as a floor it
        // would make every window inverted — and since a skipped write never advances the anchor,
        // active energy would stay dead until wall-clock passed it. Falling back to the `notBefore`
        // path instead is self-correcting: this flush writes, and the anchor is re-based to `now`.
        if let anchor, anchor > dayStart, anchor <= now {
            // Authoritative once we have written a window TODAY: the next delta covers exactly the
            // time since that one, so the day tiles without gaps or overlaps.
            //
            // `notBefore` is deliberately NOT re-applied here. It is a first-flush floor, and it can
            // legitimately move LATER during the day — `StoredSleepSummary` is merge-protected so a
            // night only ever GROWS, and the morning-tail rescue / re-stage passes push `inBedEnd`
            // forward hours after wake. Taking the max with an already-written anchor would then
            // discard elapsed time the delta genuinely accrued in and cram it into whatever sliver
            // remained, reading as a sudden kcal spike.
            let start = widenedStart(anchor, end: now, kcal: kcal, dayStart: dayStart)
            guard start < now else { return nil }
            return DateInterval(start: start, end: now)
        }

        // First write of the day: floor at the earliest moment this energy could have accrued.
        var start = dayStart
        if let notBefore, notBefore > start, notBefore < now { start = notBefore }
        start = widenedStart(start, end: now, kcal: kcal, dayStart: dayStart)
        guard start < now else { return nil }
        return DateInterval(start: start, end: now)
    }
}
