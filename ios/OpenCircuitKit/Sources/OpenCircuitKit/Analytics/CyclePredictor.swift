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

    /// Maximum number of days an OPEN period (started, never ended) may AUTO-EXTEND itself.
    ///
    /// 🟡 probable — a clinical convention, not a measurement from this device. FIGO's AUB
    /// System 1 (Munro et al., *Int J Gynaecol Obstet* 2018;143:393–408) defines normal
    /// menstrual bleeding DURATION as ≤ 8 days, and classifies anything longer as "prolonged
    /// menstrual bleeding"; ACOG's patient guidance uses the same ≤ 8-day frame. Eight days
    /// (inclusive of the start day) is therefore the widest span we can assert on the user's
    /// behalf while still being ordinary rather than a reportable clinical finding.
    ///
    /// This bounds AUTO-EXTENSION ONLY. It is not a claim about how long the user bled and it
    /// never shortens anything: a period with an EXPLICIT logged end is untouched by this at
    /// any length (see `periodMirrorLastDay`), and days already written to Apple Health are
    /// never retroactively withdrawn — reaching the cap only stops the app ADDING further days
    /// on its own. A wearer who genuinely bled longer says so by logging the end date.
    ///
    /// Without this bound an unended period grew by one Apple Health sample per elapsed day
    /// forever, which is the accuracy half of the 2026-08-24 tester report ("once a period has
    /// started, the app keeps syncing the following days as period days even after it ended").
    public static let maxAutoExtendPeriodDays = 8

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

    // MARK: Apple Health mirror bounds (open-period auto-extension)
    //
    // Apple Health models flow as one sample PER DAY, so mirroring a period means deciding which
    // DAYS it covers. That decision is pure date math, so it lives here rather than in the app
    // target's `HealthKitWriter` — the app-target XCTest suite is not in preflight, and these are
    // exactly the rules that were silently wrong in production.

    /// The last day an OPEN period (no logged end) may cover: today, or the auto-extension cap,
    /// whichever comes FIRST. Both operands are already day-floored, so this never reaches into
    /// the future and never past `start + maxAutoExtendPeriodDays - 1`.
    public static func openPeriodAutoExtendLastDay(start: Date, today: Date,
                                                   calendar: Calendar = .current) -> Date {
        let firstDay = calendar.startOfDay(for: start)
        let todayDay = calendar.startOfDay(for: today)
        // -1 because the span is INCLUSIVE of the start day: an 8-day cap covers day 1…day 8.
        let capDay = calendar.date(byAdding: .day, value: maxAutoExtendPeriodDays - 1, to: firstDay)
            ?? firstDay
        return min(todayDay, capDay)
    }

    /// The last day this period should be mirrored to Apple Health.
    ///
    /// An EXPLICIT end is authoritative and is NOT capped — the user stated it, so we assert it at
    /// whatever length they logged (clamped only to today, since a future day is never asserted).
    /// This is the pre-existing finalized behaviour, kept byte-for-byte. Only the open case, where
    /// the app would otherwise be inventing days on the user's behalf, is bounded.
    public static func periodMirrorLastDay(start: Date, end: Date?, today: Date,
                                            calendar: Calendar = .current) -> Date {
        guard let end else {
            return openPeriodAutoExtendLastDay(start: start, today: today, calendar: calendar)
        }
        return min(calendar.startOfDay(for: end), calendar.startOfDay(for: today))
    }

    /// How many one-day Apple Health samples this period should currently have. 0 when the span
    /// is empty (a start dated in the future).
    public static func periodMirrorDayCount(start: Date, end: Date?, today: Date,
                                             calendar: Calendar = .current) -> Int {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = periodMirrorLastDay(start: start, end: end, today: today, calendar: calendar)
        guard lastDay >= firstDay else { return 0 }
        return (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
    }

    /// Whether an already-mirrored period's Apple Health copy is still CORRECT — i.e. rebuilding
    /// it now would produce the same set of days, so a rewrite carries no new information and must
    /// be skipped.
    ///
    /// `writtenSampleCount` is the number of samples the store currently tracks for this entry.
    /// Because the mirror is exactly one sample per covered day, that count IS the covered span,
    /// which is why this needs no extra stored watermark (and therefore no SwiftData schema
    /// change — see `docs/RUNBOOK_SCHEMA_MIGRATION_REHEARSAL.md` for why that matters).
    ///
    /// This deliberately answers only "has a new DAY appeared?". A change to a CLINICAL field
    /// (flow level, symptoms, the end date) leaves the day count equal, so it is NOT detected
    /// here — it is caught upstream by `savePeriodEntry` clearing the written watermark. Both
    /// gates are required; neither is sufficient alone.
    public static func periodMirrorIsUpToDate(writtenSampleCount: Int,
                                              start: Date, end: Date?, today: Date,
                                              calendar: Calendar = .current) -> Bool {
        let expected = periodMirrorDayCount(start: start, end: end, today: today, calendar: calendar)
        // expected == 0 means nothing should be written; that is "nothing to do", not "up to date
        // with 0 samples", and the caller's `samples.isEmpty` guard handles it. Requiring > 0 here
        // keeps a never-written entry from ever being mistaken for a settled one.
        return expected > 0 && writtenSampleCount == expected
    }

    /// Whether an OPEN period has hit the auto-extension cap and has therefore stopped growing.
    /// Drives the UI copy that tells the wearer what happens if they never log an end date.
    public static func openPeriodHasReachedAutoExtendCap(start: Date, today: Date,
                                                         calendar: Calendar = .current) -> Bool {
        let firstDay = calendar.startOfDay(for: start)
        let todayDay = calendar.startOfDay(for: today)
        let elapsed = (calendar.dateComponents([.day], from: firstDay, to: todayDay).day ?? 0) + 1
        return elapsed >= maxAutoExtendPeriodDays
    }
}
