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
}
