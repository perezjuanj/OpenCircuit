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
// Pure value-type math (no HealthKit / device types) so it unit-tests on macOS.

import Foundation

public enum RestingHR {
    /// Shortest span over which a depressed HR counts as "sustained" rather than a
    /// transient dip — 5 minutes, matching Apple Health's resting-HR convention.
    public static let sustainedWindow: TimeInterval = 5 * 60
    /// Floor on the sleep-mean path: fewer asleep readings than this is too thin to trust as
    /// a night's resting value, so we fall back to the low-activity method instead.
    public static let minSleepSamples = 3

    /// One day's resting-HR estimate in bpm, or nil when there are no readings at all.
    /// `sleep` should be the segments overlapping this day; only `asleep*` stages count
    /// (in-bed/awake carry motion and arousals and are excluded).
    public static func value(
        hr: [HRSample],
        sleep: [SleepSegment] = [],
        window: TimeInterval = sustainedWindow,
        minSleepSamples: Int = minSleepSamples
    ) -> Double? {
        // Drop physiologically-impossible readings (LiveHR.validBPM, 30…220) before deriving a
        // resting value — so a stray garbage epoch (the "4 bpm" bug) or a not-yet-purged legacy row
        // can't become the daily resting HR written to Apple Health. The lowest-sustained fallback
        // takes a raw minimum, which is exactly where an unfiltered 4 bpm would otherwise win.
        let hr = hr.filter { LiveHR.validBPM.contains($0.bpm) }
        if let asleepMean = sleepMean(hr: hr, sleep: sleep, minSleepSamples: minSleepSamples) {
            return asleepMean
        }
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

    /// Per-calendar-day resting HR over a span of readings, oldest day first. HR is bucketed
    /// by the local day of each reading's start; `sleep` segments are matched to a day by
    /// temporal overlap (so an early-morning night lands on the day you woke). Days with no
    /// readings are omitted.
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
        minSleepSamples: Int = minSleepSamples
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
                             minSleepSamples: minSleepSamples) {
                out.append(DailyValue(day: day, bpm: v))
            }
        }
        return out
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
