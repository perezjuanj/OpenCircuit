// Analytics/CyclePredictor.swift — Women's health cycle prediction (#78).
//
// Pure math: rolling average cycle length from logged period history,
// next-period date, fertile/ovulation window, and an optional soft
// skin-temperature corroboration signal.
//
// IMPORTANT: All outputs are ESTIMATES only.
// This is NOT a medical device; outputs are NOT a basis for contraception
// or medical decisions. Label all predictions in the UI.
//
// Skin-temp integration: a post-ovulation BBT rise (typically +0.2–0.5 °C,
// APK: "temperature fluctuations may affect the accuracy of the prediction"
// pp.txt:46113) is used as a SOFT corroboration signal only — it never
// overrides the calendar estimate. Requires SkinTempBaseline data from #69.

import Foundation

public enum CyclePredictor {

    // MARK: Constants

    /// Minimum logged period starts (separate cycles) before predicting.
    /// Two is the minimum to derive one cycle length; three gives a first average.
    public static let minPeriodsForPrediction = 2

    /// Typical luteal phase used when estimating ovulation from the predicted
    /// next period. Clinical mean ≈ 14 days; individual range 12–16. We use 14.
    public static let lutealPhaseDays = 14

    /// Days before ovulation included in the fertile window (+ ovulation day = 6 days total).
    public static let fertileWindowDaysBeforeOvulation = 5

    /// Minimum sane cycle length (days). Intervals shorter than this are excluded
    /// as likely logging errors or back-to-back partial entries.
    public static let minCycleLengthDays = 21

    /// Maximum sane cycle length (days). Intervals longer than this are excluded
    /// (likely a skipped log rather than a true 46+ day cycle).
    public static let maxCycleLengthDays = 45

    /// Skin-temp offset (°C above baseline) required to count as a "post-ovulation
    /// rise" data point for the soft corroboration signal.
    public static let tempRiseCorroborationC: Double = 0.2

    /// Number of nights with a qualifying temp rise needed to set `tempCorroborated`.
    /// Require two nights to reduce single-reading noise.
    public static let tempRiseNightsRequired = 2

    // MARK: Input types

    /// One manually-logged period entry.
    public struct PeriodEntry: Equatable, Sendable {
        /// First day of the period (required).
        public let start: Date
        /// Last day of the period (optional — user may not log end immediately).
        public let end: Date?

        public init(start: Date, end: Date? = nil) {
            self.start = start
            self.end = end
        }
    }

    // MARK: Output types

    /// Descriptive statistics derived from logged cycle history.
    public struct CycleStats: Equatable, Sendable {
        /// Rolling mean cycle length (days) from the valid inter-period intervals.
        public let avgCycleLengthDays: Double
        /// Number of complete cycle intervals used (always ≥ 1).
        public let sampleCount: Int
        /// Mean period duration (days) from completed (start + end) entries, or nil.
        public let avgPeriodDurationDays: Double?

        public init(avgCycleLengthDays: Double, sampleCount: Int,
                    avgPeriodDurationDays: Double?) {
            self.avgCycleLengthDays = avgCycleLengthDays
            self.sampleCount = sampleCount
            self.avgPeriodDurationDays = avgPeriodDurationDays
        }
    }

    /// ESTIMATE — predicted next period + fertile/ovulation window.
    /// All dates are statistical estimates; label them clearly in the UI.
    public struct CyclePrediction: Equatable, Sendable {
        /// Predicted first day of the next period (ESTIMATE).
        public let nextPeriodStart: Date
        /// Predicted last day of the next period (ESTIMATE — start + avg duration).
        public let nextPeriodEnd: Date
        /// Predicted fertile window start (ESTIMATE — ovulation − 5 days).
        public let fertileWindowStart: Date
        /// Predicted fertile window end = ovulation day (ESTIMATE).
        public let fertileWindowEnd: Date
        /// Predicted ovulation day (ESTIMATE — nextPeriodStart − lutealPhaseDays).
        public let ovulationEstimate: Date
        /// Average cycle length used for this prediction (days).
        public let avgCycleLengthDays: Double
        /// True when skin-temp data shows a qualifying rise near the predicted ovulation
        /// window (soft corroboration signal only — labeled as such in the UI).
        public let tempCorroborated: Bool

        public init(nextPeriodStart: Date, nextPeriodEnd: Date,
                    fertileWindowStart: Date, fertileWindowEnd: Date,
                    ovulationEstimate: Date, avgCycleLengthDays: Double,
                    tempCorroborated: Bool) {
            self.nextPeriodStart = nextPeriodStart
            self.nextPeriodEnd = nextPeriodEnd
            self.fertileWindowStart = fertileWindowStart
            self.fertileWindowEnd = fertileWindowEnd
            self.ovulationEstimate = ovulationEstimate
            self.avgCycleLengthDays = avgCycleLengthDays
            self.tempCorroborated = tempCorroborated
        }
    }

    // MARK: Core functions

    /// Compute rolling cycle statistics from logged period history.
    ///
    /// Periods are sorted by start internally; inter-period intervals outside
    /// `[minCycleLengthDays, maxCycleLengthDays]` are excluded as likely errors.
    /// Returns `nil` when fewer than `minPeriodsForPrediction` valid cycles exist.
    public static func cycleStats(from periods: [PeriodEntry]) -> CycleStats? {
        let sorted = periods.sorted { $0.start < $1.start }
        guard sorted.count >= minPeriodsForPrediction else { return nil }

        var intervals: [Double] = []
        for i in 1 ..< sorted.count {
            let days = sorted[i].start.timeIntervalSince(sorted[i - 1].start) / 86_400
            if days >= Double(minCycleLengthDays) && days <= Double(maxCycleLengthDays) {
                intervals.append(days)
            }
        }
        guard !intervals.isEmpty else { return nil }

        let avgCycle = intervals.reduce(0, +) / Double(intervals.count)

        // Average period duration — only from entries with both start and end.
        let completedDurations: [Double] = sorted.compactMap { e in
            guard let end = e.end else { return nil }
            let d = end.timeIntervalSince(e.start) / 86_400
            return (d >= 1 && d <= 10) ? d : nil   // sanity: 1–10 day periods
        }
        let avgDuration = completedDurations.isEmpty ? nil
            : completedDurations.reduce(0, +) / Double(completedDurations.count)

        return CycleStats(avgCycleLengthDays: avgCycle,
                          sampleCount: intervals.count,
                          avgPeriodDurationDays: avgDuration)
    }

    /// Predict next period + fertile/ovulation window from logged history.
    ///
    /// - Parameters:
    ///   - periods: All logged period entries (in any order; sorted internally).
    ///   - skinTempDeviations: Optional nightly signed offsets (°C above baseline)
    ///     from `SkinTempBaseline.offset`. Used as a SOFT corroboration signal only —
    ///     clearly labeled as such in the UI. Pass `[]` when unavailable.
    ///   - now: Reference "present" used to roll the prediction forward (injected for
    ///     deterministic tests). The next period is always in the future relative to this.
    ///
    /// - Returns: `nil` when fewer than `minPeriodsForPrediction` valid cycles exist.
    public static func predict(
        from periods: [PeriodEntry],
        skinTempDeviations: [(night: Date, offsetC: Double)] = [],
        now: Date = Date()
    ) -> CyclePrediction? {
        guard let stats = cycleStats(from: periods) else { return nil }
        let sorted = periods.sorted { $0.start < $1.start }
        guard let lastPeriod = sorted.last else { return nil }

        let cycleInterval = stats.avgCycleLengthDays * 86_400
        // One cycle after the last LOGGED period — then roll forward by whole cycles until it
        // is in the future, so a user who stopped logging for ≥1 cycle still sees the NEXT
        // period (and a future fertile/ovulation window) rather than a date already elapsed.
        var nextStart = lastPeriod.start.addingTimeInterval(cycleInterval)
        if cycleInterval > 0 {
            while nextStart < now { nextStart = nextStart.addingTimeInterval(cycleInterval) }
        }

        let durationDays = stats.avgPeriodDurationDays ?? 5.0   // default 5 days
        let nextEnd = nextStart.addingTimeInterval(durationDays * 86_400)

        // Ovulation = predicted next period start − luteal phase (14 days).
        let ovulation = nextStart.addingTimeInterval(-Double(lutealPhaseDays) * 86_400)
        // Fertile window: 5 days before ovulation up to and including ovulation day.
        let fertileStart = ovulation.addingTimeInterval(-Double(fertileWindowDaysBeforeOvulation) * 86_400)

        // Skin-temp corroboration: look for ≥ tempRiseNightsRequired nights with
        // offsetC ≥ tempRiseCorroborationC in a ±3-day window around predicted ovulation.
        // "temperature fluctuations may affect the accuracy of the prediction" (APK).
        // This is labeled as a SOFT signal — it cannot confirm ovulation occurred.
        let corrobWindowStart = ovulation.addingTimeInterval(-3 * 86_400)
        let corrobWindowEnd   = ovulation.addingTimeInterval( 3 * 86_400)
        let risingNights = skinTempDeviations.filter {
            $0.night >= corrobWindowStart
            && $0.night <= corrobWindowEnd
            && $0.offsetC >= tempRiseCorroborationC
        }.count
        let corroborated = risingNights >= tempRiseNightsRequired

        return CyclePrediction(
            nextPeriodStart:    nextStart,
            nextPeriodEnd:      nextEnd,
            fertileWindowStart: fertileStart,
            fertileWindowEnd:   ovulation,      // fertile window ends on ovulation day
            ovulationEstimate:  ovulation,
            avgCycleLengthDays: stats.avgCycleLengthDays,
            tempCorroborated:   corroborated
        )
    }

    // MARK: Day-classification helpers

    /// Whether `date` falls within a logged period (start…end, inclusive on both ends).
    /// When `end` is nil, considers only the single start day logged.
    public static func isLoggedPeriodDay(_ date: Date, entries: [PeriodEntry],
                                         calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        for entry in entries {
            let start = calendar.startOfDay(for: entry.start)
            let end = entry.end.map { calendar.startOfDay(for: $0) } ?? start
            if day >= start && day <= end { return true }
        }
        return false
    }

    /// Whether `date` falls within the predicted period (inclusive).
    public static func isInPredictedPeriod(_ date: Date, prediction: CyclePrediction,
                                            calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        let s = calendar.startOfDay(for: prediction.nextPeriodStart)
        let e = calendar.startOfDay(for: prediction.nextPeriodEnd)
        return day >= s && day <= e
    }

    /// Whether `date` falls within the predicted fertile window (inclusive).
    public static func isInFertileWindow(_ date: Date, prediction: CyclePrediction,
                                          calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        let s = calendar.startOfDay(for: prediction.fertileWindowStart)
        let e = calendar.startOfDay(for: prediction.fertileWindowEnd)
        return day >= s && day <= e
    }

    /// Whether `date` is the predicted ovulation day.
    public static func isOvulationDay(_ date: Date, prediction: CyclePrediction,
                                       calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: prediction.ovulationEstimate)
    }
}
