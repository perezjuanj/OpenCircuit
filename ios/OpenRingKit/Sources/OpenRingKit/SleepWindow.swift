// Pure, platform-agnostic sleep-window date math.
//
// This lives in OpenRingKit (no Apple-UI dependencies) so it can be unit-tested with
// `swift test`. The app layer (ios/OpenRingConn) wraps it in a `SleepScheduleProviding`
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
}
