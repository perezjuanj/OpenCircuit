// Resting heart rate (daily) — derived on-device; the ring does not report it (#18, #37).
//
// Two tiers, in preference order:
//   1. Sleep mean — the average HR across the night's `asleep*` segments. Sleeping HR is
//      the most stable, least motion-contaminated signal, so its mean is the best single
//      resting estimate when sleep staging is available.
//   2. Lowest sustained — the minimum of a rolling `window`-length mean (default 5 min).
//      This mirrors the convention Apple Health uses for its own resting-HR estimate
//      (lowest sustained HR during inactivity), so our value sits alongside Apple's on a
//      comparable basis. Requiring a multi-reading window rejects single-reading dips.
//
// Coverage floor on tier 2 (#298), OPT-IN: a caller that shows or alerts on a day's value passes
// `dayCoverage`, and a day whose value would come from tier 2 on fewer readings, or a shorter
// span of them, than the floor gets NO value — exactly as if it had no readings. Without it, the
// few awake readings synced so far today became "today's resting HR" (≈ the current HR) and raised
// an elevated-RHR WATCH. The Apple Health resting-HR write applies the floor too (a thin finalized
// day is not written, #298). The default (nil) is the old behaviour, unchanged; the basal-energy
// scaling and the VO2 max input still use it.
//
// Pure value-type math (no HealthKit / device types) so it unit-tests on macOS.

import Foundation

public enum RestingHR {
    /// Shortest span over which a depressed HR counts as "sustained" rather than a
    /// transient dip — 5 minutes, matching Apple Health's resting-HR convention.
    public static let sustainedWindow: TimeInterval = 5 * 60
    /// Floor on the sleep-mean path: fewer asleep readings than this is too thin to trust as
    /// a night's resting value, so we fall back to the low-activity method instead.
    public static let minSleepSamples = 3

    /// The least daytime evidence a day needs before its lowest-sustained value is shown or judged.
    /// Both bounds must hold: `minReadings` stops a few scattered spot reads that happen to span
    /// hours, `minSpan` (first to last reading) stops a short dense burst. The sleep-mean tier keeps
    /// its own floor (`minSleepSamples`) and is not affected.
    public struct DaytimeCoverage: Equatable, Sendable {
        public let minReadings: Int
        public let minSpan: TimeInterval
        public init(minReadings: Int, minSpan: TimeInterval) {
            self.minReadings = minReadings
            self.minSpan = minSpan
        }

        /// Whether `hr` (already plausibility-filtered) clears both bounds.
        func isMet(by hr: [HRSample]) -> Bool {
            guard hr.count >= minReadings,
                  let first = hr.min(by: { $0.start < $1.start }),
                  let last = hr.max(by: { $0.start < $1.start }) else { return false }
            return last.start.timeIntervalSince(first.start) >= minSpan
        }
    }

    /// The floor the Today tile, Vitals Status and the notifications apply (#298). 🟡 Set from the
    /// cadences, not from a coverage histogram: the strap logs one HR per activity minute (60 s),
    /// the ring one per 150 s history epoch plus a 600 s auto-measure while connected.
    /// - 12 readings: the in-repo daytime floor (`HeadacheAssessmentBuilder.minDaytimeHRSamples`);
    ///   about 30 min of ring epochs, 2 h of auto-measure-only spot reads, 12 min of strap minutes.
    /// - 4 h: a day that includes its night clears this by early morning on either device; a short
    ///   burst of awake readings (a strap opened before last night synced) does not.
    public static let dayCoverage = DaytimeCoverage(minReadings: 12, minSpan: 4 * 3600)

    /// One day's resting-HR estimate in bpm, or nil when there are no readings at all.
    /// `sleep` should be the segments overlapping this day; only `asleep*` stages count
    /// (in-bed/awake carry motion and arousals and are excluded). With `daytimeCoverage`, also nil
    /// when the value would come from the lowest-sustained tier on readings below that floor.
    public static func value(
        hr: [HRSample],
        sleep: [SleepSegment] = [],
        window: TimeInterval = sustainedWindow,
        minSleepSamples: Int = minSleepSamples,
        daytimeCoverage: DaytimeCoverage? = nil
    ) -> Double? {
        // Drop physiologically-impossible readings (LiveHR.validBPM, 30…220) before deriving a
        // resting value — so a stray garbage epoch (the "4 bpm" bug) or a not-yet-purged legacy row
        // can't become the daily resting HR written to Apple Health. The lowest-sustained fallback
        // takes a raw minimum, which is exactly where an unfiltered 4 bpm would otherwise win.
        let hr = hr.filter { LiveHR.validBPM.contains($0.bpm) }
        if let asleepMean = sleepMean(hr: hr, sleep: sleep, minSleepSamples: minSleepSamples) {
            return asleepMean
        }
        if let daytimeCoverage, !daytimeCoverage.isMet(by: hr) { return nil }
        return lowestSustained(hr: hr, window: window)
    }

    /// Mean HR of readings that fall inside an `asleep*` segment; nil below the floor or
    /// when there are no asleep segments.
    static func sleepMean(hr: [HRSample], sleep: [SleepSegment], minSleepSamples: Int) -> Double? {
        let asleep = sleep.filter { isAsleep($0.stage) }
        guard !asleep.isEmpty else { return nil }
        let inSleep = hr.filter { s in
            asleep.contains { seg in s.start >= seg.start && s.start < seg.end }
        }
        guard inSleep.count >= minSleepSamples else { return nil }
        return mean(inSleep)
    }

    /// Lowest rolling `window`-mean across the readings. Each window is anchored at a
    /// reading and must hold ≥2 readings to count as "sustained"; if no window qualifies
    /// (all readings isolated) we fall back to the single lowest reading. nil if empty.
    static func lowestSustained(hr: [HRSample], window: TimeInterval) -> Double? {
        guard !hr.isEmpty else { return nil }
        let sorted = hr.sorted { $0.start < $1.start }
        let n = sorted.count
        var best: Double?
        // Two-pointer sliding window (was O(m²): a fresh forward bucket + mean rebuilt from EVERY
        // index — a dense same-day cluster, e.g. a workout, is the worst case and hung the main
        // thread past the 10 s scene-update watchdog on backgrounding). `cutoff` is monotonic in
        // `left`, so `right` only advances → O(m log m) (the sort) overall.
        //
        // BYTE-IDENTICAL: the window mean is `windowSum / count`; every bpm ≤ 220 and a window's sum
        // stays far below 2⁵³, so the running Double sum (add on right-advance, subtract on left-
        // advance) is the EXACT integer sum of the window — bit-for-bit equal to the old per-bucket
        // `reduce`. Regression-locked in RestingHRLowestSustainedTests.
        var right = 0
        var windowSum = 0.0   // Σ Double(bpm) over [left, right)
        for left in 0..<n {
            let cutoff = sorted[left].start.addingTimeInterval(window)
            while right < n, sorted[right].start < cutoff {
                windowSum += Double(sorted[right].bpm)
                right += 1
            }
            let count = right - left   // == the old bucket.count
            if count >= 2 || n == 1 {
                let m = windowSum / Double(count)
                best = best.map { Swift.min($0, m) } ?? m
            }
            windowSum -= Double(sorted[left].bpm)   // `left` leaves the window before the next step
        }
        // Readings existed but none formed a sustained window (all isolated): fall back to
        // the single lowest reading so the day still produces a value.
        if best == nil { best = sorted.map { Double($0.bpm) }.min() }
        return best
    }

    /// As `lowestSustained`, but reports whether a GENUINELY SUSTAINED window (≥2 readings inside
    /// `window`) actually produced the value, rather than the single-lowest-reading fallback above.
    ///
    /// The distinction matters to any caller deriving a THRESHOLD from the result. The production
    /// auto-measure cadence is 600 s — longer than the 5-min `sustainedWindow` — so on a day whose
    /// HR set is spot reads only, EVERY window holds one reading, the fallback fires, and the
    /// "resting HR" is literally the day's single lowest read. One poor-contact 40 bpm read then
    /// sets the baseline (adversarial review, 2026-08-12). For the daily-value path that fallback is
    /// still the right behaviour — a day with readings should produce a value — so it is unchanged;
    /// callers that need the stronger guarantee ask for it here.
    static func lowestSustainedDetailed(hr: [HRSample], window: TimeInterval)
    -> (value: Double, wasSustained: Bool)? {
        guard let value = lowestSustained(hr: hr, window: window) else { return nil }
        return (value, hasSustainedWindow(hr: hr, window: window))
    }

    /// Whether any two readings fall inside one `window`. Deliberately mirrors the `count >= 2`
    /// test inside `lowestSustained`'s sweep — the two must agree about what "sustained" means, or
    /// `lowestSustainedDetailed` would vouch for a value the fallback produced.
    static func hasSustainedWindow(hr: [HRSample], window: TimeInterval) -> Bool {
        let sorted = hr.sorted { $0.start < $1.start }
        guard sorted.count >= 2 else { return false }
        for i in 0 ..< (sorted.count - 1) where
            sorted[i + 1].start.timeIntervalSince(sorted[i].start) < window {
            return true
        }
        return false
    }

    /// Per-calendar-day resting HR over a span of readings, oldest day first. HR is bucketed
    /// by the local day of each reading's start; `sleep` segments are matched to a day by
    /// temporal overlap (so an early-morning night lands on the day you woke). Days with no
    /// readings are omitted, and so are days below `daytimeCoverage` when one is given.
    /// `reported` are the device's own resting-HR records (the Helio Strap's `0x3a`, decision 92):
    /// a day with one takes it instead of the derived value, whatever `daytimeCoverage` says.
    public struct DailyValue: Equatable, Sendable {
        public let day: Date    // start-of-day (in `calendar`)
        public let bpm: Double
        public init(day: Date, bpm: Double) { self.day = day; self.bpm = bpm }
    }

    public static func dailyValues(
        hr: [HRSample],
        sleep: [SleepSegment] = [],
        calendar: Calendar = .current,
        window: TimeInterval = sustainedWindow,
        minSleepSamples: Int = minSleepSamples,
        daytimeCoverage: DaytimeCoverage? = nil,
        reported: [HRSample] = []
    ) -> [DailyValue] {
        let derived = derivedDailyValues(hr: hr, sleep: sleep, calendar: calendar, window: window,
                                         minSleepSamples: minSleepSamples, daytimeCoverage: daytimeCoverage)
        guard !reported.isEmpty else { return derived }
        return preferringReported(derived, reported: reportedDailyValues(reported, calendar: calendar))
    }

    /// `dailyValues` without device-reported values: the on-device derivation alone.
    static func derivedDailyValues(
        hr: [HRSample],
        sleep: [SleepSegment],
        calendar: Calendar,
        window: TimeInterval,
        minSleepSamples: Int,
        daytimeCoverage: DaytimeCoverage?
    ) -> [DailyValue] {
        guard !hr.isEmpty else { return [] }
        let byDay = Dictionary(grouping: hr) { calendar.startOfDay(for: $0.start) }
        var out: [DailyValue] = []
        for day in byDay.keys.sorted() {
            let dayHR = byDay[day] ?? []
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)
                ?? day.addingTimeInterval(86_400)
            let daySleep = sleep.filter { $0.start < dayEnd && $0.end > day }
            if let v = value(hr: dayHR, sleep: daySleep, window: window,
                             minSleepSamples: minSleepSamples, daytimeCoverage: daytimeCoverage) {
                out.append(DailyValue(day: day, bpm: v))
            }
        }
        return out
    }

    // MARK: Device-reported resting HR (decision 92)
    //
    // The Helio Strap reports its own resting HR (`0x3a`), computed on the strap from its own HR,
    // which is denser than the per-minute HR the app receives. For a day the strap reported one, that
    // value is THE day's resting HR: in Apple Health, on the tile and in every baseline. The
    // derivation above stays the fallback for every other day, and the only source for the ring
    // (which reports none).
    //
    // A strap revises its value during the night (about half the days of a 28-day pull carry 2–4
    // records, a few bpm apart), and stamps some records the evening BEFORE (22:00–23:59). So a
    // record is filed by the night key's rule: before noon it belongs to its own day, from noon on to
    // the next one (`SleepNightKey.wakeWindowEndHour`). The day's value is its LATEST record, the
    // strap's own final answer. Measured on Juan's 28 strap days against the sleep mean: filing by the
    // noon rule gave r 0.94 (MAE 2.3 bpm), filing by calendar day r 0.85 (MAE 3.0).

    /// The day a device-reported resting-HR record belongs to (start-of-day in `calendar`).
    public static func reportedDay(of start: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: start)
        guard calendar.component(.hour, from: start) >= SleepNightKey.wakeWindowEndHour else { return day }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    /// One value per day from device-reported records, oldest day first: each day's LATEST record
    /// (by `start`). Readings outside `LiveHR.validBPM` are dropped first, like `value(hr:)` does.
    public static func reportedDailyValues(_ readings: [HRSample],
                                           calendar: Calendar = .current) -> [DailyValue] {
        let valid = readings.filter { LiveHR.validBPM.contains($0.bpm) }
        let byDay = Dictionary(grouping: valid) { reportedDay(of: $0.start, calendar: calendar) }
        return byDay.keys.sorted().compactMap { day in
            byDay[day]?.max { $0.start < $1.start }.map { DailyValue(day: day, bpm: Double($0.bpm)) }
        }
    }

    /// `derived` with every day the device reported replaced by (or, for a day `derived` lacks, added
    /// as) the reported value; oldest day first. With no reported days this is `derived`, sorted.
    public static func preferringReported(_ derived: [DailyValue], reported: [DailyValue]) -> [DailyValue] {
        guard !reported.isEmpty else { return derived.sorted { $0.day < $1.day } }
        var byDay = Dictionary(derived.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for r in reported { byDay[r.day] = r }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func isAsleep(_ stage: SleepStage) -> Bool {
        switch stage {
        case .asleepCore, .asleepDeep, .asleepREM: return true
        case .inBed, .awake: return false
        }
    }

    private static func mean(_ samples: [HRSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0.0) { $0 + Double($1.bpm) } / Double(samples.count)
    }
}
