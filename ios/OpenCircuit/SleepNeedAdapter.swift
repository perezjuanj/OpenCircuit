// Sleep need on the Sleep card (#382, decision 92): reads the stored nights, naps, goals and the sleep
// schedule, and hands plain values to the pure `SleepNeed` in OpenCircuitKit. Nothing here is persisted.
//
// The wake time comes ONLY from `SleepSchedule.current` (the iOS Sleep schedule, else the manual one when
// it is switched on). It never comes from `LocalStore.scheduledWakeMinutes()` or from the registered
// bed/wake defaults: with no schedule, those would show a bedtime the person never chose.

import Foundation
import OpenCircuitKit

enum SleepNeedAdapter {

    /// Days of naps read for the per-night credit: the 14 known nights can span a few weeks of gaps.
    static let napLookbackDays = 45

    /// The next wake time from the schedule, nil when there is no schedule.
    static func nextWake(now: Date,
                         calendar: Calendar = .current,
                         healthKit: SleepScheduleProviding = HealthKitSleepSchedule(),
                         manual: SleepScheduleProviding = ManualSleepSchedule.fromDefaults()) async -> Date? {
        guard let window = await SleepSchedule.current(forNightEndingNear: now, healthKit: healthKit, manual: manual)
        else { return nil }
        return SleepNeed.nextOccurrence(clockTimeOf: window.end, after: now, calendar: calendar)
    }

    /// The Kit's nights from stored rows. A row with no usable wake is dropped; `asleepMin == 0` stays in
    /// (the Kit treats it as unknown but uses its times to bound the naps).
    static func nights(_ rows: [StoredSleepSummary]) -> [SleepNeed.Night] {
        rows.compactMap { row in
            let wake = row.sleepWake > .distantPast ? row.sleepWake : row.inBedEnd
            guard wake > .distantPast, row.inBedStart > .distantPast else { return nil }
            return SleepNeed.Night(wake: wake, inBedStart: row.inBedStart,
                                   sleepOnset: row.sleepOnset > .distantPast ? row.sleepOnset : nil,
                                   asleepMin: row.asleepMin)
        }
    }

    static func naps(_ rows: [StoredNap]) -> [SleepNeed.Nap] {
        rows.map { SleepNeed.Nap(start: $0.effectiveStart, asleepMin: $0.asleepMin) }
    }

    /// The person's weekday and weekend sleep goals, with the app's defaults when never set.
    static func goals(defaults: UserDefaults = .standard) -> (workday: Int, weekend: Int) {
        (defaults.object(forKey: GoalDefaults.workdaySleepMin) as? Int ?? GoalDefaults.defaultWorkdaySleepMin,
         defaults.object(forKey: GoalDefaults.weekendSleepMin) as? Int ?? GoalDefaults.defaultWeekendSleepMin)
    }

    static func compute(nights rows: [StoredSleepSummary], naps napRows: [StoredNap], now: Date,
                        calendar: Calendar = .current,
                        defaults: UserDefaults = .standard,
                        healthKit: SleepScheduleProviding = HealthKitSleepSchedule(),
                        manual: SleepScheduleProviding? = nil) async -> SleepNeed.Result {
        let wake = await nextWake(now: now, calendar: calendar, healthKit: healthKit,
                                  manual: manual ?? ManualSleepSchedule.fromDefaults(defaults))
        let goal = goals(defaults: defaults)
        return SleepNeed.compute(.init(nights: nights(rows), naps: naps(napRows), now: now,
                                       workdayGoalMin: goal.workday, weekendGoalMin: goal.weekend,
                                       nextWake: wake, calendar: calendar))
    }
}

/// The words for sleep need: the Sleep card's one line and the sheet's values.
enum SleepNeedText {

    /// "8 h 10 m", "45 m", "8 h".
    static func duration(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) m" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) m"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The bedtime worth showing: one already past is not a recommendation.
    static func upcomingBedtime(_ result: SleepNeed.Result, now: Date) -> Date? {
        guard let bed = result.bedtime, bed > now else { return nil }
        return bed
    }

    static func debt(_ result: SleepNeed.Result) -> String {
        result.hasEnoughNights ? (result.debtMin > 0 ? duration(result.debtMin) : "none") : "not enough nights yet"
    }

    /// "Need tonight 8 h 10 m · debt 45 m · in bed by 22:40".
    static func line(_ result: SleepNeed.Result, now: Date) -> String {
        var parts = ["Need tonight \(duration(result.needMin))",
                     result.hasEnoughNights ? "debt \(debt(result))" : "debt: not enough nights yet"]
        if let bed = upcomingBedtime(result, now: now) { parts.append("in bed by \(clock(bed))") }
        return parts.joined(separator: " · ")
    }
}
