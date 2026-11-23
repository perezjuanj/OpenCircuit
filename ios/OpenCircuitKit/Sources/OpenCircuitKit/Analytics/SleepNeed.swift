import Foundation

// Sleep need, sleep debt and a recommended bedtime (#382, decision 92).
//
// Pure: plain values in, plain values out. No `@Model`, no `UserDefaults`, no `Date()` — the caller
// passes `now`, the calendar, the goals and the next wake time.
//
// The carry-forward debt recurrence follows the approach of the NOOP project's sleep-debt estimate
// (credit only: the idea of carrying a fraction of last night's shortfall into the next night). No
// NOOP code was read or copied; the rule below was written from the decision text alone.
//
// What is sourced and what is not (the sheet says the same):
// - The goal itself is the user's own setting (weekday / weekend), backed by the duration sources
//   (Hirshkowitz 2015, Watson 2015).
// - That restricted sleep accumulates (Van Dongen 2003) and takes several nights to repay (Kitamura
//   2016) is the published basis for carrying debt at all.
// - The 0.55 carry, the 14-night window, the 10-minute floor, the 18-hour nap bound, the -60 / +120 minute bounds on need and the
//   15-minute default onset latency are OpenCircuit estimates, not published constants.
//
// The rule (decision 92i, superseding 92b-92d):
// 1. A night is KNOWN when it has a stored row with `asleepMin > 0`. An unknown night is skipped
//    entirely: never zero-filled, even if it had naps.
// 2. Every nap is counted once. A nap is TONIGHT's when it starts after the most recent stored night's
//    wake and less than 18 hours before now: it lowers tonight's need (rule 4) and is never credited to a
//    night. Every other nap is credited to the night it follows: its asleep minutes join that night's, when
//    it STARTS after that night's wake and before the earlier of the next stored night's in-bed start and the
//    end of that wake day (local midnight; decision 92k). The most recent stored night is credited like any
//    other. A nap on a day with no stored night ending on it is counted nowhere.
// 3. Debt is a recurrence over the most recent 14 KNOWN nights, oldest first, from 0:
//    `debt = 0.55 * max(0, goal(night) + debt - credited(night))`; a result under 10 minutes clears
//    to 0. Surplus sleep never makes a negative debt. With fewer than 3 known nights the debt is
//    "not enough nights yet" and contributes 0.
//    `goal(night)` is the weekday or weekend goal of the day the night ENDS on (decision 92a).
// 4. Need tonight = goal + debt - tonight's nap minutes, clamped to [goal - 60, goal + 120] minutes.
// 5. Bedtime = next wake - need - onset latency; no wake time, no bedtime.
// 6. Onset latency = median of (sleep onset - in-bed start) over the 14 most recent nights where both
//    are recorded, clamped to 0...60 minutes; 15 minutes when fewer than 3 such nights.
public enum SleepNeed {

    // MARK: Constants (OpenCircuit estimates, see the header)

    public static let carry = 0.55
    public static let debtWindowNights = 14
    public static let debtFloorMin = 10
    public static let minKnownNights = 3
    public static let maxBelowGoalMin = 60
    public static let maxAboveGoalMin = 120
    public static let latencyWindowNights = 14
    public static let minLatencyNights = 3
    /// A nap this recent (and after the last stored night's wake) is tonight's, not a past night's.
    public static let tonightNapWindow: TimeInterval = 18 * 3600
    public static let defaultLatencyMin = 15
    public static let latencyRangeMin = 0...60

    // MARK: Input

    /// One stored night. `asleepMin <= 0` marks it unknown.
    public struct Night: Equatable, Sendable {
        /// The end of the night: its recorded wake, or the end of the in-bed window when none.
        public var wake: Date
        public var inBedStart: Date
        /// nil when the night has no recorded onset.
        public var sleepOnset: Date?
        public var asleepMin: Int

        public init(wake: Date, inBedStart: Date, sleepOnset: Date? = nil, asleepMin: Int) {
            self.wake = wake
            self.inBedStart = inBedStart
            self.sleepOnset = sleepOnset
            self.asleepMin = asleepMin
        }

        public var isKnown: Bool { asleepMin > 0 }
    }

    public struct Nap: Equatable, Sendable {
        public var start: Date
        public var asleepMin: Int

        public init(start: Date, asleepMin: Int) {
            self.start = start
            self.asleepMin = asleepMin
        }
    }

    public struct Input: Sendable {
        /// Stored nights, any order; include unknown ones (they bound the naps' days).
        public var nights: [Night]
        public var naps: [Nap]
        public var now: Date
        public var workdayGoalMin: Int
        public var weekendGoalMin: Int
        /// The next time the person wakes, from the sleep schedule only. nil = none.
        public var nextWake: Date?
        public var calendar: Calendar

        public init(nights: [Night], naps: [Nap], now: Date, workdayGoalMin: Int, weekendGoalMin: Int,
                    nextWake: Date?, calendar: Calendar) {
            self.nights = nights
            self.naps = naps
            self.now = now
            self.workdayGoalMin = workdayGoalMin
            self.weekendGoalMin = weekendGoalMin
            self.nextWake = nextWake
            self.calendar = calendar
        }
    }

    // MARK: Result

    public struct Result: Equatable, Sendable {
        /// Tonight's goal: the weekday or weekend goal of the day tonight's sleep ends on.
        public var goalMin: Int
        /// Known nights available (all stored, not only the 14 used).
        public var knownNights: Int
        /// false = fewer than 3 known nights: `debtMin` is 0 and the UI says "not enough nights yet".
        public var hasEnoughNights: Bool
        /// Known nights the debt was worked out over: at most 14, 0 when there are not enough.
        public var nightsUsed: Int
        public var debtMin: Int
        /// Asleep minutes of tonight's naps (after the last stored night's wake, under 18 hours before now).
        public var napMin: Int
        /// goal + debt - naps before the clamp.
        public var unclampedNeedMin: Int
        public var needMin: Int
        public var latencyMin: Int
        /// true = the 15-minute default (fewer than 3 nights with an onset).
        public var latencyIsDefault: Bool
        public var nextWake: Date?
        /// nil without a wake time.
        public var bedtime: Date?
    }

    // MARK: Compute

    public static func compute(_ input: Input) -> Result {
        let cal = input.calendar
        let ordered = input.nights.sorted { $0.wake < $1.wake }
        let known = ordered.filter(\.isKnown)

        // Debt: the recurrence over the most recent 14 known nights, oldest first.
        let enough = known.count >= minKnownNights
        var debt = 0.0
        let window = enough ? Array(known.suffix(debtWindowNights)) : []
        let lastWake = ordered.last?.wake
        func isTonights(_ nap: Nap) -> Bool {
            (lastWake.map { nap.start > $0 } ?? true)
                && nap.start > input.now.addingTimeInterval(-tonightNapWindow) && nap.start < input.now
        }
        // A nap that has not started yet counts nowhere.
        let pastNaps = input.naps.filter { $0.start < input.now && !isTonights($0) }
        for night in window {
            let goal = goalMin(endingOn: night.wake, input)
            let credited = night.asleepMin + napCredit(for: night, in: ordered, naps: pastNaps, calendar: cal)
            debt = carry * max(0, Double(goal) + debt - Double(credited))
            if debt < Double(debtFloorMin) { debt = 0 }
        }
        let debtMin = Int(debt.rounded())

        // Tonight's naps (decision 92l): after the last stored night's wake, within the last 18 hours.
        let napMin = input.naps.filter(isTonights).reduce(0) { $0 + max(0, $1.asleepMin) }

        let goal = goalMin(endingOn: tonightEndDay(input, lastWake: lastWake), input)
        let unclamped = goal + debtMin - napMin
        let need = min(max(unclamped, goal - maxBelowGoalMin), goal + maxAboveGoalMin)

        let (latency, isDefault) = onsetLatency(ordered)
        let bedtime = input.nextWake.map { $0.addingTimeInterval(-Double(need + latency) * 60) }

        return Result(goalMin: goal, knownNights: known.count, hasEnoughNights: enough, nightsUsed: window.count,
                      debtMin: debtMin,
                      napMin: napMin, unclampedNeedMin: unclamped, needMin: need,
                      latencyMin: latency, latencyIsDefault: isDefault,
                      nextWake: input.nextWake, bedtime: bedtime)
    }

    /// The day tonight's sleep ends on: the next wake's day when there is one. Without a wake time
    /// (decision 92k): tomorrow if the last stored night's wake is today, otherwise today before noon
    /// (a night in progress after midnight), otherwise tomorrow.
    static func tonightEndDay(_ input: Input, lastWake: Date?) -> Date {
        if let wake = input.nextWake { return wake }
        let cal = input.calendar
        let tomorrow = cal.date(byAdding: .day, value: 1, to: input.now) ?? input.now
        if let lastWake, cal.isDate(lastWake, inSameDayAs: input.now) { return tomorrow }
        return cal.component(.hour, from: input.now) < 12 ? input.now : tomorrow
    }

    /// The goal for a night that ends at `wake`: weekend or weekday by the wake day.
    static func goalMin(endingOn wake: Date, _ input: Input) -> Int {
        GoalDefaults.isWeekend(wake, calendar: input.calendar) ? input.weekendGoalMin : input.workdayGoalMin
    }

    /// Asleep minutes of the naps credited to `night` (decisions 92k, 92l): those starting after its wake and
    /// before the EARLIER of the next stored night's in-bed start and the end of the wake day (the local
    /// midnight after the wake). A nap on a day with no stored night ending that day credits nothing. The
    /// most recent stored night is credited like any other; `naps` must already exclude tonight's naps.
    static func napCredit(for night: Night, in ordered: [Night], naps: [Nap], calendar: Calendar) -> Int {
        guard let idx = ordered.firstIndex(where: { $0.wake == night.wake && $0.inBedStart == night.inBedStart })
        else { return 0 }
        let nextBed = idx + 1 < ordered.count ? ordered[idx + 1].inBedStart : Date.distantFuture
        let endOfWakeDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: night.wake))
            ?? .distantFuture
        let until = min(nextBed, endOfWakeDay)
        return naps.filter { $0.start > night.wake && $0.start < until }
            .reduce(0) { $0 + max(0, $1.asleepMin) }
    }

    /// Median onset latency (minutes) over the 14 most recent nights with both times recorded,
    /// clamped to 0...60; 15 when fewer than 3 such nights. Second value is true for the default.
    static func onsetLatency(_ ordered: [Night]) -> (Int, Bool) {
        let samples: [Double] = ordered.reversed().compactMap { n in
            guard let onset = n.sleepOnset, onset >= n.inBedStart else { return nil }
            return onset.timeIntervalSince(n.inBedStart) / 60
        }.prefix(latencyWindowNights).sorted()
        guard samples.count >= minLatencyNights else { return (defaultLatencyMin, true) }
        let mid = samples.count / 2
        let median = samples.count % 2 == 1 ? samples[mid] : (samples[mid - 1] + samples[mid]) / 2
        let rounded = Int(median.rounded())
        return (min(max(rounded, latencyRangeMin.lowerBound), latencyRangeMin.upperBound), false)
    }

    // MARK: Wake time

    /// The next occurrence after `now` of the clock time of `reference` (e.g. the end of a schedule
    /// window), in `calendar`. A clock time that does not exist on a DST day moves to the next one that
    /// does. nil only if the calendar cannot find one.
    public static func nextOccurrence(clockTimeOf reference: Date, after now: Date, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute], from: reference)
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
    }
}
