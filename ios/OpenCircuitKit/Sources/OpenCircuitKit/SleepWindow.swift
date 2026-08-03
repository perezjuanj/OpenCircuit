// Pure, platform-agnostic sleep-window date math.
//
// This lives in OpenCircuitKit (no Apple-UI dependencies) so it can be unit-tested with
// `swift test`. The app layer (ios/OpenCircuit) wraps it in a `SleepScheduleProviding`
// implementation that pulls the user's bedtime/wake from `@AppStorage`, and a HealthKit
// implementation that reads the real iOS Sleep schedule. See `SleepSchedule.swift`.

import Foundation

/// Builds a concrete bedtime→wake `DateInterval` from a *time-of-day* schedule
/// (minutes-since-midnight for bed and wake), correctly handling a window that crosses
/// midnight (e.g. bed 22:30 → wake 06:30).
public enum SleepWindow {

    /// Minutes in a day.
    public static let minutesPerDay = 1440

    /// The sleep window whose **wake** time falls nearest to `date`.
    ///
    /// - Parameters:
    ///   - bedMinutes: bedtime as minutes since local midnight (e.g. 22:30 → 1350).
    ///   - wakeMinutes: wake time as minutes since local midnight (e.g. 06:30 → 390).
    ///   - date: the reference instant; the night *ending near* this is chosen.
    ///   - calendar: calendar used to resolve local midnight (default `.current`).
    /// - Returns: a `DateInterval` from bedtime to wake. When the schedule crosses
    ///   midnight (`bedMinutes >= wakeMinutes`) the bedtime lands on the previous day.
    ///   Returns `nil` only for a degenerate zero-length schedule (`bed == wake`).
    public static func interval(bedMinutes: Int,
                                wakeMinutes: Int,
                                nightEndingNear date: Date,
                                calendar: Calendar = .current) -> DateInterval? {
        let bed = ((bedMinutes % minutesPerDay) + minutesPerDay) % minutesPerDay
        let wake = ((wakeMinutes % minutesPerDay) + minutesPerDay) % minutesPerDay

        // Sleep duration, wrapping across midnight. bed==wake → 0 (degenerate; no window).
        let duration = ((wake - bed) + minutesPerDay) % minutesPerDay
        guard duration > 0 else { return nil }

        // Candidate wake instants on the day before / of / after `date`; pick the nearest.
        let midnight = calendar.startOfDay(for: date)
        let candidates: [Date] = (-1...1).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: midnight)
                .map { $0.addingTimeInterval(TimeInterval(wake * 60)) }
        }
        guard let wakeDate = candidates.min(by: {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }) else { return nil }

        let bedDate = wakeDate.addingTimeInterval(TimeInterval(-duration * 60))
        return DateInterval(start: bedDate, end: wakeDate)
    }

    /// Convenience: minutes-since-midnight from an `hour`/`minute` pair.
    public static func minutes(hour: Int, minute: Int) -> Int {
        (hour * 60 + minute + minutesPerDay) % minutesPerDay
    }

    /// A HABITUAL sleep window learned from recent nights' ACTUAL onset/wake times — for gating
    /// overnight capture (skin temp rides the live `0x10/0x87` descriptor and is NOT in the
    /// drainable history, so it can only be captured in real time, inside a window). A fixed
    /// clock default (22:30→06:30) silently drops the temp of anyone who sleeps later or shifts
    /// night to night; this tracks the individual instead.
    ///
    /// Each night contributes its onset and wake TIME-OF-DAY. We take a robust MEDIAN of each
    /// (onsets are unwrapped around local midnight, so a 23:50 and a 00:30 onset average to ~00:10
    /// rather than to midday), widen by the given margins so a shifted night isn't clipped, then
    /// build the concrete interval for the night ending near `date` via `interval` (cross-midnight
    /// aware). Median, not mean, so one fragmented night (a 04:15 onset, an early wake) can't drag
    /// the window. Returns `nil` when fewer than `minNights` usable nights exist — the caller falls
    /// back to a fixed default.
    ///
    /// - Parameters:
    ///   - onsets: recent nights' sleep-onset instants (any count; only the time-of-day is used).
    ///   - wakes: recent nights' final-wake instants.
    ///   - bedMargin: seconds to START the window BEFORE the median onset (default 1 h).
    ///   - wakeMargin: seconds to END the window AFTER the median wake (default 1.5 h).
    ///   - minNights: minimum usable nights before a learned window is trusted (default 3).
    public static func habitualInterval(onsets: [Date], wakes: [Date],
                                        nightEndingNear date: Date,
                                        bedMargin: TimeInterval = 3600,
                                        wakeMargin: TimeInterval = 5400,
                                        minNights: Int = 3,
                                        calendar: Calendar = .current) -> DateInterval? {
        guard onsets.count >= minNights, wakes.count >= minNights else { return nil }
        func tod(_ d: Date) -> Int {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        // Onsets straddle midnight (late evening + small hours), so unwrap times before noon onto
        // the evening scale before taking the median. Wakes cluster in the morning and never wrap,
        // so they take a plain median (unwrapBelow 0 ⇒ no value unwraps).
        let onsetMin = medianMinutes(onsets.map(tod), unwrapBelow: 12 * minutesPerDay / 24)
        let wakeMin = medianMinutes(wakes.map(tod), unwrapBelow: 0)
        return interval(bedMinutes: onsetMin - Int(bedMargin / 60),
                        wakeMinutes: wakeMin + Int(wakeMargin / 60),
                        nightEndingNear: date, calendar: calendar)
    }

    /// Median of minutes-since-midnight values, treating any value `< unwrapBelow` as belonging to
    /// the NEXT day (adds a full day before sorting) so a wrapped cluster (e.g. onsets around
    /// midnight) averages on a continuous scale; the result is wrapped back into `[0, 1440)`. With
    /// `unwrapBelow == 0` nothing unwraps (a plain time-of-day median).
    static func medianMinutes(_ values: [Int], unwrapBelow pivot: Int) -> Int {
        guard !values.isEmpty else { return 0 }
        let unwrapped = values.map { $0 < pivot ? $0 + minutesPerDay : $0 }.sorted()
        let mid = unwrapped[unwrapped.count / 2]
        return ((mid % minutesPerDay) + minutesPerDay) % minutesPerDay
    }

    /// Whether a detected sleep block looks like OVERNIGHT sleep (as opposed to a daytime nap or
    /// a long sedentary daytime period). Used to gate the persistent nightly sleep summary so a
    /// worn-but-still daytime block (a long meeting, a movie, an afternoon nap > 1 h) that a sync
    /// happens to drain isn't staged as "last night" and allowed to overwrite the real night.
    ///
    /// Rule: the block is overnight when its MIDPOINT falls between 21:00 and 09:00 local — i.e. the
    /// middle of the sleep is at night. A real night's midpoint always lands in the small hours
    /// (whether onset is pre- or post-midnight), so a genuine night is never rejected; a midday nap
    /// or a long daytime block has a daytime midpoint and is rejected. Using the midpoint (rather
    /// than an interval-overlap test) avoids fragile behaviour at the window boundaries. This only
    /// decides ACCEPTANCE — the FULL detected block is kept when accepted, so totals are never
    /// clipped.
    public static func isOvernightBlock(start: Date, end: Date,
                                        calendar: Calendar = .current) -> Bool {
        let safeEnd = max(end, start)
        let mid = start.addingTimeInterval(safeEnd.timeIntervalSince(start) / 2)
        let c = calendar.dateComponents([.hour, .minute], from: mid)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minutes < 9 * 60 || minutes >= 21 * 60   // before 09:00 or at/after 21:00
    }

    /// The span we PRESUME a night had when its onset was NOT captured. 7 h is a conservative typical
    /// night: long enough to drag a truncated tail's midpoint back into the night, short enough that a
    /// daytime block with an unobserved onset still has a daytime presumed midpoint under the plain
    /// rule. It is NOT the whole safety story — see `BulkSleep.onsetIsUnobserved` (how much data must
    /// actually be MISSING) and the two-pass filter in `BulkSleep.latestNightRecords` (the correction
    /// may only run when nothing else qualified).
    ///
    /// It doubles as the SIZE OF THE HOLE the correction demands: presuming a `d`-long tail was really
    /// a night means claiming `presumedTruncatedNightSpan - d` of data is missing, and
    /// `BulkSleep.onsetIsUnobserved` requires exactly that much absence before it will say so.
    public static let presumedTruncatedNightSpan: TimeInterval = 7 * 3600

    /// `isOvernightBlock`, corrected for a night whose ONSET WAS NEVER RECORDED.
    ///
    /// WHY: a night can reach us as a TAIL only — an overnight drain that never ran, a ring that was
    /// off the finger for the first half, a first-ever sync, a re-pair. The observed start is then
    /// LATER than the true onset, which drags the observed midpoint towards morning, and the plain
    /// midpoint rule discards the whole night (blank Sleep card, nothing in Apple Health).
    /// 🟢 Measured on a real Gen 2 Air (FR04.009) archive whose night ended 08-02 11:21 local: tails of
    /// 1.5 / 2 / 2.5 / 3 / 3.5 / 4 / 4.5 h were ALL discarded by the plain rule; only >= 4.75 h passed.
    ///
    /// The key insight: if the true onset is EARLIER than observed, the true midpoint is EARLIER than
    /// observed too — so a late observed midpoint is NOT evidence against overnight-ness once we know
    /// the onset was never recorded. When `onsetIsUnobserved`, this ALSO judges a presumed start of
    /// `end - presumedTruncatedNightSpan` and accepts if EITHER midpoint is overnight.
    ///
    /// ⚠️ THIS FUNCTION CANNOT BE SAFE ON ITS OWN, and must never be called as if it were. On date
    /// math alone the correction degenerates to "accept any block whose wake falls in [00:30, 12:30)",
    /// because for anything shorter than the presumed span `min(start, end - 7h)` IS `end - 7h` — the
    /// block's own start and duration are erased. A sedentary 10:29 -> 12:29 desk morning is accepted
    /// by the arithmetic. Two SEPARATE guards, both outside this function, are what make it safe:
    ///   1. `BulkSleep.onsetIsUnobserved(_:in:epoch:)` — the presumed data must genuinely be MISSING:
    ///      the hole before the block must be big enough to have held the presumed onset; and
    ///   2. the two-pass filter in `BulkSleep.latestNightRecords` — the correction runs ONLY when the
    ///      plain rule accepted nothing at all, so it can never outrank, evict or clip a real night.
    /// Nothing else should feed this parameter. This function stays pure date math on purpose.
    ///
    /// ⚠️ There is deliberately NO physiological condition. An earlier revision required the block's
    /// sleep-vitals share to clear 0.40; it was removed as DISCREDITED, not simplified away.
    ///
    /// 🟢 MEASURED on the 2F9F (Gen 2 Air, FR04.009) export, device clock UTC+2: its stored night
    /// scores 88/192 = 0.45833 and that same archive's own app-detected 16:45 nap scores
    /// 11/24 = 0.45833 — identical to five significant figures. The share CANNOT separate a night
    /// from real DAYTIME SLEEP, and daytime sleep is exactly what the overnight gate exists to keep
    /// out of "last night". A gate that cannot make the distinction it is named for is worse than no
    /// gate: it misleads the next reader into thinking the case is covered. Structure replaced it.
    ///
    /// Stated honestly, because an earlier revision of THIS COMMENT overstated it: the share does
    /// separate sleep from AWAKE-WORN stillness (🟢 AA55 night 0.473 vs awake-worn 0.082; 2F9F night
    /// 0.461 vs awake-worn 0.158). The earlier claim that it was "flat at ~0.50 across the AA55 wake"
    /// and therefore always-true on FR04 does NOT reproduce — those figures were the AA55 archive
    /// labelled in the OTHER device's timezone, and all fall INSIDE its staged night. ⚠️ The two
    /// exports were recorded in DIFFERENT zones (AA55 UTC−4, 2F9F UTC+2); always name the offset when
    /// quoting a wall-clock hour from a tester export.
    ///
    /// CRITICAL SAFETY PROPERTIES, both by construction:
    ///   * **never less accepting** than the two-argument form — the OR means the correction can only
    ///     turn a REJECT into an ACCEPT; and
    ///   * with `onsetIsUnobserved == false` it is **byte-identical** to the two-argument form.
    /// A block already longer than `presumedTruncatedNightSpan` keeps its own (earlier) start (the
    /// `min`), so the presumption is inert for a genuinely long night.
    ///
    /// ⚠️ The OR is load-bearing, NOT belt-and-braces. Substituting the presumed start OUTRIGHT is
    /// less accepting for a whole family of real blocks: an early-evening-onset night, e.g.
    /// 20:30 -> 23:30, has observed midpoint 22:00 (accepted) but presumed midpoint 20:00 (rejected).
    /// A brute-force sweep of every start-minute x duration found 7683 such (start, duration) pairs —
    /// see `testEarlyEveningOnsetAtLeadingEdgeStillAccepted`. Judging the presumed midpoint ALONE
    /// would have introduced exactly the class of regression this change exists to fix.
    public static func isOvernightBlock(start: Date, end: Date,
                                        onsetIsUnobserved: Bool,
                                        calendar: Calendar = .current) -> Bool {
        let asObserved = isOvernightBlock(start: start, end: end, calendar: calendar)
        guard onsetIsUnobserved else { return asObserved }
        let safeEnd = max(end, start)
        // `min` (never `max`): the presumption may only move the start EARLIER, so it can never shrink
        // a block that is already longer than the presumed span.
        let effectiveStart = min(start, safeEnd.addingTimeInterval(-presumedTruncatedNightSpan))
        return asObserved || isOvernightBlock(start: effectiveStart, end: safeEnd, calendar: calendar)
    }
}
