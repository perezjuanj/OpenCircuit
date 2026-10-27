import Foundation
import OpenCircuitKit

// MARK: - The in-bed lead-in before a strap night's first sleep (decision 77)

/// Decision 77 (#328): a strap night's in-bed span used to start at the record's own sleep start
/// (decision 70a), so it read about 5 minutes before sleep on every night, and an app that derives
/// Time to Fall Asleep from the `.inBed` sample read it as near zero. The lead-in reaches back from
/// the night's first in-bed start over the minutes where the strap's own STORED rows show the wearer
/// lying in bed: the strap worn (a heart-rate sample), no walking (steps), and a heart rate near the
/// night's sleeping level.
///
/// It is an ESTIMATE from the strap's measured rows, not the record's own span. It is added as one
/// `.inBed` segment and one `.awake` segment over the same span before the first fragment (the shape
/// of the ring's pre-sleep awake-in-bed and of decision 74's awake run), so time in bed and awake
/// time grow, asleep time doesn't, and every reader that judges sleep (`HelioSleepSelection.sleepSpans`)
/// never sees it.
///
/// Derived from the STORED rows, never a sync's fetched minutes (77b, the 73f/73i/74b lesson): the
/// caller (`LocalStore`) supplies them, already the strap's own and clamped to time it owns.
public enum HelioInBedLeadIn {

    // MARK: 77a's constants (provisional: the orchestrator calibrates them on the owner's store)

    /// A lead-in minute's heart rate may be at most this far above the night's sleeping level. Lying in
    /// bed awake sits a little above sleep; walking about, showering or sitting up reads well above it.
    public static let heartRateMarginBPM: Double = 15

    /// The night's sleeping level is the median heart rate over this long from the first sleep minute:
    /// long enough to ride out a single high minute, short enough to stay in the night's first cycle.
    public static let sleepingLevelSpan: TimeInterval = 60 * 60

    /// The longest lead-in. Past two hours, "in bed, worn, still, calm" is as likely the sofa as bed.
    public static let maxLength: TimeInterval = 120 * 60

    /// A shorter lead-in is not added: the record's own span already leaves a few minutes before the
    /// first stage, and a lead-in of a minute or two is noise, not time in bed.
    public static let minLength: TimeInterval = 5 * 60

    /// A minute with this many steps or more ends the walk: the wearer was up. A few steps (turning
    /// over, a shuffle to the bed) don't.
    public static let stepsThatEndIt = 10

    /// Holes in the heart rate of this many minutes or fewer are bridged; one minute more ends the
    /// walk. Decision 74a's rule for the awake fill, so the two read the strap's wear the same way.
    public static var maxHoleMinutes: Int { HelioSleepSelection.awakeFillMaxHoleMinutes }

    /// One stored heart-rate sample: the minute it starts and its beats per minute.
    public struct HeartRateMinute: Equatable, Sendable {
        public let time: Date
        public let bpm: Double
        public init(time: Date, bpm: Double) {
            self.time = time
            self.bpm = bpm
        }
    }

    /// One stored step row: its span and its count.
    public struct StepMinute: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let steps: Int
        public init(start: Date, end: Date, steps: Int) {
            self.start = start
            self.end = end
            self.steps = steps
        }
    }

    /// Decision 77a: where the lead-in before `inBedStart` (the night's first in-bed start) starts, or
    /// nil when there is none.
    ///
    /// The sleeping level is the median of `heartRate` in `[firstSleep, firstSleep + sleepingLevelSpan)`;
    /// with none there, nothing can be judged and there is no lead-in. Then, minute by minute back from
    /// `inBedStart` (each minute `[t − 1 min, t)`, never before `earliest` nor `maxLength` back):
    /// - a minute with `stepsThatEndIt` steps or more (step rows overlapping it) ends the walk;
    /// - a minute with heart rate above the level + `heartRateMarginBPM` ends the walk;
    /// - a minute with heart rate at or below it joins the lead-in, with the holes walked over since;
    /// - a minute with no heart rate is a hole; `maxHoleMinutes` + 1 in a row end the walk.
    /// The lead-in starts at the earliest minute that joined. One under `minLength` is nil.
    ///
    /// `earliest` is the latest of the end of the previous sleep (night or nap, either device) and the
    /// start of time the strap owns (decisions 28, 77c): the lead-in never overlaps another sleep or
    /// reaches into the other device's time.
    public static func start(inBedStart: Date, firstSleep: Date, heartRate: [HeartRateMinute],
                             steps: [StepMinute], earliest: Date) -> Date? {
        let levelEnd = firstSleep.addingTimeInterval(sleepingLevelSpan)
        guard let level = median(heartRate.filter { $0.time >= firstSleep && $0.time < levelEnd }.map(\.bpm)) else { return nil }
        let ceiling = level + heartRateMarginBPM
        let floor = max(earliest, inBedStart.addingTimeInterval(-maxLength))
        let minute: TimeInterval = 60
        var start = inBedStart
        var holes = 0
        var minuteEnd = inBedStart
        while minuteEnd > floor {
            let minuteStart = max(minuteEnd.addingTimeInterval(-minute), floor)
            defer { minuteEnd = minuteStart }
            let stepCount = steps.filter { $0.start < minuteEnd && $0.end > minuteStart }.reduce(0) { $0 + $1.steps }
            if stepCount >= stepsThatEndIt { break }
            let bpm = heartRate.filter { $0.time >= minuteStart && $0.time < minuteEnd }.map(\.bpm)
            guard let highest = bpm.max() else {
                holes += 1
                if holes > maxHoleMinutes { break }
                continue
            }
            if highest > ceiling { break }
            start = minuteStart
            holes = 0
        }
        guard inBedStart.timeIntervalSince(start) >= minLength else { return nil }
        return start
    }

    /// The median, or nil for none.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

// MARK: - The lead-in in a night's segments

extension HelioSleepSelection {

    /// Decision 77a: the lead-in in `segments`, or nil: the run of the awake-run shape (an `.inBed`
    /// and an `.awake` over one span with no asleep segment in it, `awakeFillRuns`) that lies before
    /// the night's first sleep fragment. Decision 74's awake fill only ever fills BETWEEN fragments,
    /// so a run before the first one can only be the lead-in. nil on a night with no lead-in, and on
    /// every night a build before decision 77 stored. This judges the shape only: the app reads a stored
    /// row as having a lead-in only when it is a strap night (decision 79b, `StoredSleepSummary.isStrapNight`).
    public static func leadIn(in segments: [SleepSegment]) -> DateInterval? {
        let runs = awakeFillRuns(in: segments)
        guard !runs.isEmpty else { return nil }
        let fragments = segments.filter { $0.stage == .inBed && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
            .filter { !runs.contains($0) }
        guard let firstSleep = fragments.map(\.start).min() else { return nil }
        return runs.filter { $0.end <= firstSleep }.min { $0.start < $1.start }
    }

    /// `segments` without their lead-in (`leadIn(in:)`): the night as its fragments (and decision 74's
    /// fill) describe it. Unchanged for a night with none.
    public static func withoutLeadIn(_ segments: [SleepSegment]) -> [SleepSegment] {
        guard let lead = leadIn(in: segments) else { return segments }
        return segments.filter { segment in
            !((segment.stage == .inBed || segment.stage == .awake) && segment.start == lead.start && segment.end == lead.end)
        }
    }

    /// `segments` (a strap night over `window`) with a lead-in from `start` to the first in-bed start:
    /// one `.inBed` and one `.awake` segment over that span, first. Any lead-in already there is
    /// replaced. `start` at or after the first in-bed start gives the night without a lead-in.
    public static func withLeadIn(_ segments: [SleepSegment], window: DateInterval, from start: Date) -> [SleepSegment] {
        let base = withoutLeadIn(segments)
        let firstInBed = windowWithoutLeadIn(segments, window: window).start
        guard start < firstInBed else { return base }
        return [SleepSegment(start: start, end: firstInBed, stage: .inBed),
                SleepSegment(start: start, end: firstInBed, stage: .awake)] + base
    }

    /// Decision 77d/77e: `window` without the lead-in: from the end of the lead-in when the night has
    /// one, else `window` itself. The window every rule that judges the night's SLEEP keeps reading
    /// (the night score's heart rate and HRV, the nap split's main sleeps), so for those a night with a
    /// lead-in is exactly the night without it.
    public static func windowWithoutLeadIn(_ segments: [SleepSegment], window: DateInterval) -> DateInterval {
        guard let lead = leadIn(in: segments), lead.end > window.start, lead.end < window.end else { return window }
        return DateInterval(start: lead.end, end: window.end)
    }
}

extension HelioSleepSelection.Night {
    /// Decision 77: the night's lead-in span (`HelioSleepSelection.leadIn(in:)`), or nil.
    public var leadIn: DateInterval? { HelioSleepSelection.leadIn(in: segments) }

    /// Decision 77: the night's window without its lead-in (`HelioSleepSelection.windowWithoutLeadIn`).
    public var windowWithoutLeadIn: DateInterval { HelioSleepSelection.windowWithoutLeadIn(segments, window: window) }

    /// Decision 77a: this night with a lead-in from `start` (`HelioSleepSelection.withLeadIn`). Its
    /// window starts there; the score and recorded zone are unchanged.
    public func withLeadIn(from start: Date) -> HelioSleepSelection.Night {
        let base = windowWithoutLeadIn
        let segments = HelioSleepSelection.withLeadIn(self.segments, window: window, from: start)
        let window = start < base.start ? DateInterval(start: start, end: base.end) : base
        return HelioSleepSelection.Night(segments: segments, window: window, strapScore: strapScore,
                                         recordedTimeZone: recordedTimeZone)
    }

    /// This night without its lead-in: its window starts at its first fragment again.
    public var withoutLeadIn: HelioSleepSelection.Night {
        HelioSleepSelection.Night(segments: HelioSleepSelection.withoutLeadIn(segments), window: windowWithoutLeadIn,
                                  strapScore: strapScore, recordedTimeZone: recordedTimeZone)
    }
}
