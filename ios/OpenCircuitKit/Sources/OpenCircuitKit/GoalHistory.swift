// Historical daily goal-ring completion — the past-days twin of `GoalsCardView`'s four rings.
//
// STORAGE: NONE. There is deliberately no new @Model and no new stored column here. Every input
// a past day's rings need is ALREADY persisted and already recomputed by the trends pipeline:
//
//   • steps            → `StoredDaily.steps`                  (TrendsEngine.DailyPoint.steps)
//   • active kcal      → `Calories.dailyEstimate` per day     (DailyPoint.activeEnergyKcal)
//   • elevated-HR min  → `Calories.dailyEstimate` per day     (DailyPoint.exerciseMin)
//   • sleep minutes    → `StoredSleepSummary.asleepMin` + `StoredNap.asleepMin`
//
// So ring history is a PURE FUNCTION of (already-stored daily rollups × the user's goals), and
// this file is that function. A SwiftData schema change is the single highest-risk edit in this
// project (docs/RUNBOOK_SCHEMA_MIGRATION_REHEARSAL.md — build 44 deleted every raw history row on
// upgrade), and none is needed to show a history of rings, so none is made.
//
// TWO HONEST CONSEQUENCES OF DERIVING RATHER THAN SNAPSHOTTING — both surfaced in the UI:
//
//   1. GOALS ARE NOT VERSIONED. A day is scored against the goals set RIGHT NOW, not the goals
//      that were in force on that day. Nothing records the historical goal, and inventing one
//      would be a fabricated value. Raising a goal therefore re-scores history downward. The
//      weekday/weekend split IS applied per-day (that split is a function of the date itself,
//      not of stored state), so a Saturday is scored against the weekend goal.
//   2. A DAY IS ONLY AS GOOD AS ITS RETAINED DATA. A day whose rollups were pruned, or that
//      predates the app, has no rings — it reports `hasData == false` and is rendered as
//      "no data", never as a failed day. `closedAll` can only be true for a day that had data.
//
// Sleep is credited to the day the night ENDED (via `MissedNight.nightWakeReference`), matching
// `GoalsCardView`'s "last night" ring exactly. That is deliberately DIFFERENT from the Sleep
// Duration trend chart, which plots a night on its bedtime day (`StoredSleepSummary.night`); the
// caller builds the credit map, and the difference is documented at that call site.

import Foundation

public enum GoalHistory {

    // MARK: - Goals

    /// The user's current goal settings, as a value type so the history builder is pure and
    /// testable. Mirrors the six `GoalDefaults` UserDefaults keys the Goals card reads.
    public struct Goals: Equatable, Sendable {
        public var workdaySteps: Int
        public var weekendSteps: Int
        public var activeKcal: Double
        public var activityMinutes: Double
        public var workdaySleepMin: Int
        public var weekendSleepMin: Int

        public init(workdaySteps: Int = GoalDefaults.defaultWorkdaySteps,
                    weekendSteps: Int = GoalDefaults.defaultWeekendSteps,
                    activeKcal: Double = GoalDefaults.defaultActiveKcal,
                    activityMinutes: Double = GoalDefaults.defaultActivityMinutes,
                    workdaySleepMin: Int = GoalDefaults.defaultWorkdaySleepMin,
                    weekendSleepMin: Int = GoalDefaults.defaultWeekendSleepMin) {
            self.workdaySteps = workdaySteps
            self.weekendSteps = weekendSteps
            self.activeKcal = activeKcal
            self.activityMinutes = activityMinutes
            self.workdaySleepMin = workdaySleepMin
            self.weekendSleepMin = weekendSleepMin
        }

        /// The step goal that applies to `date` — the SAME weekday/weekend rule the Goals card
        /// uses for today (`GoalDefaults.isWeekend`), applied to the historical date instead.
        public func stepGoal(on date: Date, calendar: Calendar = .current) -> Int {
            GoalDefaults.isWeekend(date, calendar: calendar) ? weekendSteps : workdaySteps
        }

        /// The sleep-minutes goal that applies to `date`, weekday/weekend split as above.
        public func sleepGoalMinutes(on date: Date, calendar: Calendar = .current) -> Int {
            GoalDefaults.isWeekend(date, calendar: calendar) ? weekendSleepMin : workdaySleepMin
        }

        /// Read the six goals out of UserDefaults using the SAME `GoalDefaults` keys the Goals
        /// card's `@AppStorage` properties bind to. Reading them here (rather than re-declaring the
        /// key strings at the call site) is what keeps the history strip and today's rings scoring
        /// against one set of goals.
        public static func fromDefaults(_ defaults: UserDefaults = .standard) -> Goals {
            func int(_ key: String, _ fallback: Int) -> Int {
                defaults.object(forKey: key) as? Int ?? fallback
            }
            func double(_ key: String, _ fallback: Double) -> Double {
                defaults.object(forKey: key) as? Double ?? fallback
            }
            return Goals(
                workdaySteps:    int(GoalDefaults.workdaySteps, GoalDefaults.defaultWorkdaySteps),
                weekendSteps:    int(GoalDefaults.weekendSteps, GoalDefaults.defaultWeekendSteps),
                activeKcal:      double(GoalDefaults.activeKcal, GoalDefaults.defaultActiveKcal),
                activityMinutes: double(GoalDefaults.activityMinutes, GoalDefaults.defaultActivityMinutes),
                workdaySleepMin: int(GoalDefaults.workdaySleepMin, GoalDefaults.defaultWorkdaySleepMin),
                weekendSleepMin: int(GoalDefaults.weekendSleepMin, GoalDefaults.defaultWeekendSleepMin))
        }
    }

    // MARK: - Input

    /// One calendar day's already-derived rollup. Every field is optional: `nil` means "not
    /// available for this day" (pruned, never synced, or the metric had no qualifying epochs) and
    /// is scored as an EMPTY ring, never as a zero the user failed to beat.
    public struct DayInput: Equatable, Sendable {
        public let date: Date               // start-of-day
        public let steps: Int?
        public let activeKcal: Double?
        public let activityMinutes: Double?
        /// Asleep minutes CREDITED to this calendar day — the night that ended today plus this
        /// day's non-overlapping naps. Built by the caller; see the file header.
        public let sleepMinutes: Int?

        public init(date: Date, steps: Int? = nil, activeKcal: Double? = nil,
                    activityMinutes: Double? = nil, sleepMinutes: Int? = nil) {
            self.date = date
            self.steps = steps
            self.activeKcal = activeKcal
            self.activityMinutes = activityMinutes
            self.sleepMinutes = sleepMinutes
        }
    }

    // MARK: - Output

    /// The four rings a metric can close, in the display order the Goals card uses.
    public enum Ring: String, Equatable, Sendable, CaseIterable {
        case steps, activeKcal, activityMinutes, sleepMinutes
    }

    /// One day of ring history.
    public struct Day: Equatable, Sendable, Identifiable {
        public let date: Date
        public let progress: DailyGoalProgress
        /// Which of the four rings actually had a measured value for this day. A ring absent here
        /// is drawn empty and is NOT counted as missed.
        public let present: Set<Ring>
        /// Which rings reached their goal. Always a subset of `present`.
        public let met: Set<Ring>
        /// True when this day is still accumulating (it is today, or in the future relative to
        /// `now`). A partial day is never called a miss.
        public let isPartial: Bool

        public var id: Date { date }
        /// Any measured data at all for this day.
        public var hasData: Bool { !present.isEmpty }
        /// How many rings closed (0…4).
        public var ringsMet: Int { met.count }
        /// All four rings closed on a day that is finished. The streak unit.
        public var closedAll: Bool { met.count == Ring.allCases.count }

        /// Mean attainment across the rings that HAVE data, 0…1 — `nil` when the day has none.
        /// Averaging over present rings only means a day missing one metric isn't dragged toward
        /// zero by a ring that was never measured.
        public var attainment: Double? {
            guard hasData else { return nil }
            let fractions = present.map { fraction(for: $0) }
            return fractions.reduce(0, +) / Double(fractions.count)
        }

        /// This day's progress for one ring.
        public func goalProgress(for ring: Ring) -> GoalProgress {
            GoalHistory.progressValue(progress, ring)
        }

        /// Ring fill fraction 0…1 — 0 for a ring with no data (drawn empty).
        public func fraction(for ring: Ring) -> Double {
            present.contains(ring) ? goalProgress(for: ring).fraction : 0
        }
    }

    // MARK: - Build

    /// Score a run of daily rollups against the current goals.
    ///
    /// - Parameters:
    ///   - days: per-day rollups, any order; the result is sorted oldest→newest.
    ///   - goals: the goals in force now (see the file header — history is scored against them).
    ///   - now: "today" reference, for the partial-day flag.
    public static func build(days: [DayInput],
                             goals: Goals,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return days.sorted { $0.date < $1.date }.map { input in
            let dayStart = calendar.startOfDay(for: input.date)
            let stepGoal = Double(goals.stepGoal(on: dayStart, calendar: calendar))
            let sleepGoal = Double(goals.sleepGoalMinutes(on: dayStart, calendar: calendar))

            let progress = DailyGoalProgress(
                steps:           GoalProgress(current: Double(input.steps ?? 0),        goal: stepGoal),
                activeKcal:      GoalProgress(current: input.activeKcal ?? 0,           goal: goals.activeKcal),
                activityMinutes: GoalProgress(current: input.activityMinutes ?? 0,      goal: goals.activityMinutes),
                sleepMinutes:    GoalProgress(current: Double(input.sleepMinutes ?? 0), goal: sleepGoal))

            // "Present" is about whether the metric was MEASURED, not whether it was non-zero — but
            // a stored 0 and an absent value are indistinguishable to a user, and every one of these
            // rollups only exists once the day produced data, so `nil` is the honest absence test.
            var present: Set<Ring> = []
            if input.steps           != nil { present.insert(.steps) }
            if input.activeKcal      != nil { present.insert(.activeKcal) }
            if input.activityMinutes != nil { present.insert(.activityMinutes) }
            if input.sleepMinutes    != nil { present.insert(.sleepMinutes) }

            var met: Set<Ring> = []
            for ring in present where progressValue(progress, ring).met { met.insert(ring) }

            return Day(date: dayStart, progress: progress, present: present, met: met,
                       isPartial: dayStart >= today)
        }
    }

    static func progressValue(_ p: DailyGoalProgress, _ ring: Ring) -> GoalProgress {
        switch ring {
        case .steps:           return p.steps
        case .activeKcal:      return p.activeKcal
        case .activityMinutes: return p.activityMinutes
        case .sleepMinutes:    return p.sleepMinutes
        }
    }

    // MARK: - Sleep credit

    /// One stored night, reduced to what the Sleep ring needs.
    public struct NightSleep: Equatable, Sendable {
        /// `startOfDay(StoredSleepSummary.night)` — the BEDTIME day key.
        public let nightKey: Date
        /// The night's real in-bed window; `nil` on a legacy rollup with no clock time.
        public let inBedStart: Date?
        public let inBedEnd: Date?
        public let asleepMinutes: Int

        public init(nightKey: Date, inBedStart: Date?, inBedEnd: Date?, asleepMinutes: Int) {
            self.nightKey = nightKey
            self.inBedStart = inBedStart
            self.inBedEnd = inBedEnd
            self.asleepMinutes = asleepMinutes
        }
    }

    /// One nap's EFFECTIVE (post-edit) window.
    public struct NapSleep: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let asleepMinutes: Int

        public init(start: Date, end: Date, asleepMinutes: Int) {
            self.start = start
            self.end = end
            self.asleepMinutes = asleepMinutes
        }
    }

    /// Asleep minutes credited to each CALENDAR DAY, matching `GoalsCardView`'s Sleep ring:
    ///
    ///   • a night is credited to the day it ENDED (`MissedNight.nightWakeReference` — the real
    ///     wake when known, else the night key, so a legacy rollup can't drift onto a later day).
    ///     This is deliberately NOT the bedtime keying the Sleep Duration chart uses; a night that
    ///     began at 23:40 belongs to the morning it produced, which is the ring the user saw.
    ///   • naps fold into the day they started on, EXCEPT a nap overlapping ANY credited night —
    ///     a manually-added nap has no auto-detection night guard, so without this exclusion a
    ///     manual nap inside the night would double-count against it. Deliberately "any", not
    ///     "that day's": nights are keyed by WAKE day, so a 23:30 nap sits inside a night credited
    ///     to the NEXT day and a same-day lookup misses it entirely.
    ///     ⚠️ The guard is all-or-nothing and needs an in-bed CLOCK. Two known gaps, both erring
    ///     toward under-crediting or toward the pre-existing behaviour, neither introduced here:
    ///     a nap that merely CLIPS a night loses all its minutes, not just the overlap; and a
    ///     legacy night with no clock offers no guard at all, so a nap inside it still
    ///     double-counts.
    public static func sleepCreditByDay(nights: [NightSleep],
                                        naps: [NapSleep],
                                        calendar: Calendar = .current) -> [Date: Int] {
        var credit: [Date: Int] = [:]
        // Keyed by WAKE day, so a lookup by the nap's own start day misses the night it belongs to
        // (a 23:30 nap sits inside a night credited to the NEXT day). Every value is therefore
        // tested for overlap, never just the one on the nap's day — at most a handful per window
        // (measured: 14 nights × 60 naps = 0.0001 s).
        var creditedNight: [Date: DateInterval] = [:]

        for night in nights where night.asleepMinutes > 0 {
            let hasClock: Bool
            if let s = night.inBedStart, let e = night.inBedEnd, e > s { hasClock = true } else { hasClock = false }
            let wake = MissedNight.nightWakeReference(inBedEnd: hasClock ? night.inBedEnd : nil,
                                                      nightKey: night.nightKey)
            let day = calendar.startOfDay(for: wake)
            credit[day, default: 0] += night.asleepMinutes
            if hasClock, let s = night.inBedStart, let e = night.inBedEnd {
                // Widen rather than replace, so two nights landing on one wake day both guard.
                if let existing = creditedNight[day] {
                    creditedNight[day] = DateInterval(start: min(existing.start, s),
                                                      end: max(existing.end, e))
                } else {
                    creditedNight[day] = DateInterval(start: s, end: e)
                }
            }
        }

        for nap in naps where nap.asleepMinutes > 0 {
            // Overlap against EVERY credited night, not just `creditedNight[startOfDay(nap.start)]`.
            // 🟢 The bug that was: a night 23:00→07:00 is credited to the wake day, so a manual
            // 23:30–00:30 nap INSIDE it looked up an empty slot on the previous day and was credited
            // again — a phantom Sleep ring on a day whose minutes already belong to the next day's
            // night. Moving the same nap 60 min later (00:30–01:30) excluded it correctly, so the
            // handling of identical sleep flipped on which side of midnight it started.
            let insideACreditedNight = creditedNight.values.contains {
                nap.start < $0.end && nap.end > $0.start
            }
            if insideACreditedNight { continue }
            credit[calendar.startOfDay(for: nap.start), default: 0] += nap.asleepMinutes
        }
        return credit
    }

    // MARK: - Summary

    /// Roll-up stats over a window of ring history.
    public struct Summary: Equatable, Sendable {
        /// Days in the window that had ANY measured ring.
        public let daysWithData: Int
        /// Finished days on which all four rings closed.
        public let daysAllClosed: Int
        /// Per-ring: how many finished days closed it, and how many had data for it.
        public let metCounts: [Ring: Int]
        public let dataCounts: [Ring: Int]
        /// Consecutive all-closed days ending at the most recent FINISHED day. A still-running
        /// today extends the streak when it has already closed all four, and never breaks it.
        ///
        /// ⚠️ A streak is only CURRENT if it reaches today or yesterday. Without that test a run
        /// that ended days ago reads as live: rows for Aug 10–11 only, opened on Aug 20, reported
        /// `2` and the card rendered a green "2 days streak" nine days after it stopped. Reachable
        /// on any phone left away from the ring, a stranded recorder, or an app not opened.
        public let currentStreak: Int
        /// Longest all-closed run anywhere in the window.
        ///
        /// ⚠️ Admits a still-partial TODAY that has already closed all four — the same rule
        /// `currentStreak` uses, so the two streak numbers agree. `daysAllClosed` deliberately does
        /// NOT: it counts completed days. The doc used to say "finished days only" here, which the
        /// code never did, and the three numbers could read "2 days streak · 1 day all 4 closed ·
        /// 2 best streak" on the same screen.
        public let longestStreak: Int

        public init(daysWithData: Int, daysAllClosed: Int, metCounts: [Ring: Int],
                    dataCounts: [Ring: Int], currentStreak: Int, longestStreak: Int) {
            self.daysWithData = daysWithData
            self.daysAllClosed = daysAllClosed
            self.metCounts = metCounts
            self.dataCounts = dataCounts
            self.currentStreak = currentStreak
            self.longestStreak = longestStreak
        }
    }

    /// Summarise a window produced by `build` (which returns oldest→newest).
    ///
    /// Streak rules, stated so the UI can be trusted:
    ///   • only a day that closed ALL FOUR rings extends a streak;
    ///   • a day with missing data does NOT close, so it breaks the streak — we do not paper over
    ///     a sync gap by pretending the rings closed;
    ///   • a PARTIAL day (today) that hasn't closed everything yet is skipped rather than counted
    ///     as a break, so the streak doesn't visibly reset every midnight;
    ///   • a gap in the calendar (a day absent from the window entirely) also breaks the streak —
    ///     consecutive means consecutive days, not consecutive rows;
    ///   • and a run that does not reach today or yesterday is not CURRENT — see `currentStreak`.
    ///
    /// - Parameter now: the wall clock the streak's currency is judged against. Required rather than
    ///   defaulted so a caller cannot silently reinstate the stale-streak bug by omission.
    public static func summarize(_ days: [Day], now: Date, calendar: Calendar = .current) -> Summary {
        var metCounts: [Ring: Int] = [:]
        var dataCounts: [Ring: Int] = [:]
        var daysWithData = 0
        var daysAllClosed = 0
        for day in days {
            if day.hasData { daysWithData += 1 }
            if day.closedAll && !day.isPartial { daysAllClosed += 1 }
            for ring in day.present { dataCounts[ring, default: 0] += 1 }
            for ring in day.met { metCounts[ring, default: 0] += 1 }
        }

        // Longest run, scanning oldest→newest. Calendar adjacency is required: a missing day is a
        // break even though the array has no row for it.
        //
        // A partial day is admitted ONLY when it has already closed all four — the same rule
        // `currentStreak` uses below, so the two streak numbers and `daysAllClosed` cannot disagree
        // on screen about what today counts as. (`daysAllClosed` still counts finished days only;
        // that is a count of completed days, not of streak membership, and its label says so.)
        var longest = 0, run = 0
        var previous: Date?
        for day in days where !day.isPartial || day.closedAll {
            let adjacent = previous.map {
                calendar.dateComponents([.day], from: $0, to: day.date).day == 1
            } ?? false
            if day.closedAll {
                run = adjacent ? run + 1 : 1
                longest = max(longest, run)
            } else {
                run = 0
            }
            previous = day.date
        }

        // Current streak: walk backwards from the newest day, skipping a not-yet-closed today.
        var current = 0
        var expected: Date?
        for day in days.reversed() {
            if day.isPartial && !day.closedAll { continue }
            if let expected, calendar.dateComponents([.day], from: day.date, to: expected).day != 1 { break }
            guard day.closedAll else { break }
            current += 1
            expected = day.date
        }
        // …and it is only a CURRENT streak if it actually reaches now. `expected` holds the OLDEST
        // day in the run, so the newest counted day is the first one the walk took; recompute from
        // the newest qualifying row rather than tracking it separately.
        if current > 0 {
            let newestCounted = days.reversed().first { !($0.isPartial && !$0.closedAll) }?.date
            let daysSince = newestCounted.flatMap {
                calendar.dateComponents([.day], from: $0, to: calendar.startOfDay(for: now)).day
            }
            // Today (0) or yesterday (1) only. A NEGATIVE value — a row dated in the future, which
            // a ring or phone clock skew can produce — is not "current" either, and a bare
            // `daysSince > 1` let it through.
            if let daysSince, !(0...1).contains(daysSince) { current = 0 }
        }

        return Summary(daysWithData: daysWithData, daysAllClosed: daysAllClosed,
                       metCounts: metCounts, dataCounts: dataCounts,
                       currentStreak: current, longestStreak: longest)
    }
}
