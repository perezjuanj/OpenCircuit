// Sleep need on the Sleep card (#382, decision 92): reads the stored nights, naps, goals and the sleep
// schedule, and hands plain values to the pure `SleepNeed` in OpenCircuitKit. Nothing here is persisted.
//
// The wake time comes ONLY from the manual sleep schedule set in OpenCircuit's Profile, and only while it is
// switched on (decision 92k, the `ExportBuilder.manualScheduleWake` precedent). It never comes from the
// schedule swap point or its HealthKit reader (that reads RECORDED sleep from any source, this app's own
// mirrored nights and naps included, so it is not a schedule), `LocalStore.scheduledWakeMinutes()` or the
// registered bed/wake defaults: those would show a bedtime the person never chose.

import Foundation
import OpenCircuitKit

enum SleepNeedAdapter {

    /// Days of naps read for the per-night credit: the 14 known nights can span a few weeks of gaps.
    static let napLookbackDays = 45

    /// The next wake time from the manual schedule, nil when it is off. The schedule is injected so tests
    /// never touch `UserDefaults.standard`.
    static func nextWake(now: Date, calendar: Calendar = .current, schedule: ManualSleepSchedule) -> Date? {
        guard schedule.enabled,
              let window = SleepWindow.interval(bedMinutes: schedule.bedMinutes, wakeMinutes: schedule.wakeMinutes,
                                                nightEndingNear: now, calendar: calendar)
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
                        schedule: ManualSleepSchedule? = nil) -> SleepNeed.Result {
        let wake = nextWake(now: now, calendar: calendar,
                            schedule: schedule ?? ManualSleepSchedule.fromDefaults(defaults))
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
        result.hasEnoughNights ? debtValue(result) : "not enough nights yet"
    }

    /// The debt figure once there are enough nights; zero reads "none" everywhere (line and sheet).
    static func debtValue(_ result: SleepNeed.Result) -> String {
        result.debtMin > 0 ? duration(result.debtMin) : "none"
    }

    /// "Need tonight 8 h 10 m · debt 45 m · in bed by 22:40".
    static func line(_ result: SleepNeed.Result, now: Date) -> String {
        var parts = ["Need tonight \(duration(result.needMin))",
                     result.hasEnoughNights ? "debt \(debt(result))" : "debt: not enough nights yet"]
        if let bed = upcomingBedtime(result, now: now) { parts.append("in bed by \(clock(bed))") }
        return parts.joined(separator: " · ")
    }
}
