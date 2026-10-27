// StrapWorkout.swift — pure rules for a workout the app records with the Amazfit Helio Strap (#227,
// decision 34): the strap's live heart rate plus the phone's GPS, written as one `HKWorkout`.
//
// The ring's workout (`WorkoutSessionAggregator`, `WorkoutSessionRecovery`) is left exactly as it is;
// these types add what the strap's recorder needs on top of it, without touching the ring's path:
//   • `WorkoutActivityLedger`: pauses (user) and gaps (link down), so the active duration and the
//     zones never count time the person paused, and a link drop is MARKED instead of papered over;
//   • `StrapWorkoutSummaryBuilder`: the ring's summary maths over the active segments only;
//   • `StrapWorkoutJournal` + `StrapWorkoutRecovery`: what a fresh process may claim about a workout
//     that was running when the app was killed: it closes at its LAST SAMPLE (never at "now").
// (How the readings enter `LocalStore` without moving the strap's watermarks, or reaching Apple Health
// a second time, is the app's: `LocalStore+StrapWorkout.swift`.)
//
// Same honesty rules as the ring's workout (#45): only real readings are recorded, gaps are never
// interpolated, and no number is reported that was not measured.

import Foundation

// MARK: - Pauses and gaps

/// The time line of one workout: when it started, when the person paused it, and when the strap's
/// link was down. Value type, Codable, so it is journaled as-is.
public struct WorkoutActivityLedger: Codable, Equatable, Sendable {
    public let start: Date
    /// Closed pauses, in order.
    public private(set) var pauses: [DateInterval] = []
    /// When the current pause began, or nil while running.
    public private(set) var openPauseStart: Date?
    /// Closed link gaps, in order. Informational: heart rate is simply absent for them.
    public private(set) var gaps: [DateInterval] = []
    /// When the current gap began, or nil while the link is up.
    public private(set) var openGapStart: Date?

    public init(start: Date) { self.start = start }

    public var isPaused: Bool { openPauseStart != nil }
    public var isInGap: Bool { openGapStart != nil }

    /// Begin a pause. A second pause while paused, or one dated before the last event, is ignored.
    public mutating func pause(at date: Date) {
        guard openPauseStart == nil, date >= lastPauseEvent else { return }
        openPauseStart = date
    }

    /// End the current pause. A zero-length pause leaves no record.
    public mutating func resume(at date: Date) {
        guard let began = openPauseStart else { return }
        openPauseStart = nil
        let end = max(date, began)
        if end > began { pauses.append(DateInterval(start: began, end: end)) }
    }

    public mutating func beginGap(at date: Date) {
        guard openGapStart == nil, date >= start else { return }
        openGapStart = date
    }

    public mutating func endGap(at date: Date) {
        guard let began = openGapStart else { return }
        openGapStart = nil
        let end = max(date, began)
        if end > began { gaps.append(DateInterval(start: began, end: end)) }
    }

    private var lastPauseEvent: Date { pauses.last?.end ?? start }

    /// Every pause up to `end`, the open one closed at `end`.
    public func pauses(until end: Date) -> [DateInterval] {
        var out = pauses.filter { $0.start < end }.map { DateInterval(start: $0.start, end: min($0.end, end)) }
        if let began = openPauseStart, began < end { out.append(DateInterval(start: began, end: end)) }
        return out
    }

    /// Every gap up to `end`, the open one closed at `end`.
    public func gaps(until end: Date) -> [DateInterval] {
        var out = gaps.filter { $0.start < end }.map { DateInterval(start: $0.start, end: min($0.end, end)) }
        if let began = openGapStart, began < end { out.append(DateInterval(start: began, end: end)) }
        return out
    }

    /// The running stretches between `start` and `end`, pauses removed.
    public func activeSegments(until end: Date) -> [DateInterval] {
        guard end > start else { return [] }
        var out: [DateInterval] = []
        var cursor = start
        for pause in pauses(until: end) {
            if pause.start > cursor { out.append(DateInterval(start: cursor, end: pause.start)) }
            cursor = max(cursor, pause.end)
        }
        if end > cursor { out.append(DateInterval(start: cursor, end: end)) }
        return out
    }

    /// Seconds of running time between `start` and `end` (the workout's active duration).
    public func activeSeconds(until end: Date) -> TimeInterval {
        activeSegments(until: end).reduce(0) { $0 + $1.duration }
    }

    /// Whether `date` falls inside a running stretch (not paused), as of `end`.
    public func isActive(at date: Date, until end: Date) -> Bool {
        activeSegments(until: end).contains { date >= $0.start && date <= $0.end }
    }
}

// MARK: - Summary

/// A finished strap workout: the ring's `WorkoutSummary` plus what pauses and link gaps add.
///
/// `summary.durationSeconds` stays wall-clock (end − start), exactly as the ring's; the strap's
/// screens and Apple Health use `activeSeconds` (Health gets pause/resume events, so its duration
/// matches).
public struct StrapWorkoutSummary: Equatable, Sendable {
    public let summary: WorkoutSummary
    public let activeSeconds: TimeInterval
    public let pauses: [DateInterval]
    public let gaps: [DateInterval]

    public init(summary: WorkoutSummary, activeSeconds: TimeInterval, pauses: [DateInterval], gaps: [DateInterval]) {
        self.summary = summary
        self.activeSeconds = activeSeconds
        self.pauses = pauses
        self.gaps = gaps
    }

    /// Seconds the strap's link was down while the workout was running (pauses excluded).
    public var gapSeconds: TimeInterval {
        gaps.reduce(0) { total, gap in
            let paused = pauses.reduce(0.0) { $0 + (gap.intersection(with: $1)?.duration ?? 0) }
            return total + max(gap.duration - paused, 0)
        }
    }
}

public enum StrapWorkoutSummaryBuilder {

    /// The readings that count toward the workout: those that END inside a running stretch (a reading
    /// ending exactly at a resume was measured during the pause), deduplicated by time.
    public static func activeSamples(_ samples: [HRSample], ledger: WorkoutActivityLedger, end: Date) -> [HRSample] {
        let segments = ledger.activeSegments(until: end)
        var seen = Set<Date>()
        return samples
            .filter { s in segments.contains { s.end > $0.start && s.end <= $0.end } }
            .sorted { $0.end < $1.end }
            .filter { seen.insert($0.end).inserted }
    }

    /// Time in zones, held (step-function) attribution like the ring's (`timeInZonesHeld`), run per
    /// running stretch so no reading is ever held across a pause. A gap longer than the hold cap
    /// (30 s) contributes no zone time at all, so a link drop is never filled in.
    public static func zones(_ samples: [HRSample], ledger: WorkoutActivityLedger, end: Date, maxHR: Int) -> WorkoutZoneBreakdown {
        var total = WorkoutZoneBreakdown()
        for segment in ledger.activeSegments(until: end) {
            let inside = samples.filter { $0.end > segment.start && $0.end <= segment.end }
            let z = HRZoneClassifier.timeInZonesHeld(hrSamples: inside, maxHR: maxHR, sessionEnd: segment.end)
            total.warmUpSeconds += z.warmUpSeconds
            total.fatBurnSeconds += z.fatBurnSeconds
            total.aerobicSeconds += z.aerobicSeconds
            total.anaerobicSeconds += z.anaerobicSeconds
            total.extremeSeconds += z.extremeSeconds
        }
        return total
    }

    /// Build the summary. Same maths as `WorkoutSessionAggregator.finalize` (Keytel over the average
    /// heart rate, the distance fallback, the larger of the two), but over the ACTIVE duration, and
    /// with zones per running stretch. All heart-rate fields are nil when no reading was captured.
    public static func summarize(sport: WorkoutSportType,
                                 ledger: WorkoutActivityLedger,
                                 samples: [HRSample],
                                 end: Date,
                                 distanceMeters: Double?,
                                 hasRoute: Bool,
                                 profile: UserProfile) -> StrapWorkoutSummary {
        let end = max(end, ledger.start)
        let counted = activeSamples(samples, ledger: ledger, end: end)
        let active = ledger.activeSeconds(until: end)
        let maxHR = max(220 - max(profile.age, 1), 1)
        let avgHR = counted.isEmpty ? nil : counted.reduce(0) { $0 + $1.bpm } / counted.count
        let maxBPM = counted.map(\.bpm).max()
        let hrKcal = avgHR.map { Calories.workoutActiveKcal(avgHR: $0, durationSeconds: active, profile: profile) }
        let distKcal = (distanceMeters ?? 0) > 0 ? Calories.activeKcalFromDistance(meters: distanceMeters!, profile: profile) : nil
        let summary = WorkoutSummary(
            sport: sport,
            startDate: ledger.start,
            endDate: end,
            avgHR: avgHR,
            maxHR: maxBPM,
            estimatedActiveKcal: [hrKcal, distKcal].compactMap { $0 }.max(),
            zoneBreakdown: zones(counted, ledger: ledger, end: end, maxHR: maxHR),
            distanceMeters: distanceMeters,
            hasRoute: hasRoute,
            hrSampleCount: counted.count,
            steps: nil,   // the strap reports no per-workout steps here (realtime steps stay off, §7.2)
            usedFormulaMaxHR: true)
        return StrapWorkoutSummary(summary: summary, activeSeconds: active,
                                   pauses: ledger.pauses(until: end), gaps: ledger.gaps(until: end))
    }
}

// MARK: - Journal (what a running workout writes down)

/// The small, frequently rewritten half of a running strap workout's journal. The readings are
/// appended to a separate file (`StrapWorkoutSampleLine`), so a heartbeat never rewrites them.
///
/// UserDefaults/files, never SwiftData: a schema change is a launch-crash surface whose recovery
/// path wipes raw history (see the build-44 note in `App.swift`), the same reason the ring's
/// `WorkoutSessionSnapshot` lives in UserDefaults.
public struct StrapWorkoutJournal: Codable, Equatable, Sendable {
    public var sport: WorkoutSportType
    public var ledger: WorkoutActivityLedger
    /// The last instant the app OBSERVED the workout running (the ~10 s heartbeat).
    public var lastAliveAt: Date
    /// The strap's timeline (`zeppos:<id>`) the readings belong to.
    public var timelineRaw: String
    /// GPS distance so far, informational (the route itself is not journaled; see recovery).
    public var distanceMeters: Double?
    /// The strap's realtime step stream was on for this indoor workout (#339, decision 84b): a killed
    /// process leaves the next connection an owed `05 00`. nil in journals written before #339.
    public var stepStreamOn: Bool?

    public init(sport: WorkoutSportType, ledger: WorkoutActivityLedger, lastAliveAt: Date,
                timelineRaw: String, distanceMeters: Double? = nil, stepStreamOn: Bool? = nil) {
        self.sport = sport
        self.ledger = ledger
        self.lastAliveAt = lastAliveAt
        self.timelineRaw = timelineRaw
        self.distanceMeters = distanceMeters
        self.stepStreamOn = stepStreamOn
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decoded(from data: Data?) -> StrapWorkoutJournal? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(StrapWorkoutJournal.self, from: data)
    }
}

/// One reading as a line of the append-only sample file: `<end epoch seconds>,<bpm>`. Each reading
/// spans the second before it (the strap streams once a second, §7.1).
public enum StrapWorkoutSampleLine {
    public static let span: TimeInterval = 1

    public static func encode(_ sample: HRSample) -> String {
        String(format: "%.3f,%d\n", sample.end.timeIntervalSince1970, sample.bpm)
    }

    /// Every well-formed line; a torn last line (the process died mid-append) is skipped.
    public static func decode(_ text: String) -> [HRSample] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ",")
            guard parts.count == 2, let t = Double(parts[0]), let bpm = Int(parts[1]),
                  LiveHR.validBPM.contains(bpm) else { return nil }
            let end = Date(timeIntervalSince1970: t)
            return HRSample(bpm: bpm, start: end.addingTimeInterval(-span), end: end)
        }
    }
}

// MARK: - Recovery after the app was killed

/// A strap workout an interrupted process left behind, with a span this process can defend.
public struct RecoveredStrapWorkout: Equatable, Sendable {
    public let sport: WorkoutSportType
    public let ledger: WorkoutActivityLedger
    /// The last reading's time when there is one, else the last heartbeat; never later than a pause
    /// that was open when the process died. Never "now".
    public let end: Date
    /// The readings inside the recovered span.
    public let samples: [HRSample]
    public let timelineRaw: String

    public var activeSeconds: TimeInterval { ledger.activeSeconds(until: end) }
}

public enum StrapWorkoutRecovery {
    public enum Decision: Equatable, Sendable {
        case nothingToRecover
        case discard(WorkoutRecoveryRefusal)
        case offer(RecoveredStrapWorkout)
    }

    /// Decide what to do with a journal the previous process left behind.
    ///
    /// The workout closes at its LAST SAMPLE: the app has evidence the person was exercising up to
    /// the last reading it journaled (readings are appended every second, the heartbeat every ten),
    /// and none after. When no reading ever arrived (the strap never connected, say), it closes at
    /// the last heartbeat, exactly like the ring's recovery. A pause open at death closes it at the
    /// pause's start (the last running instant; pauses are journaled the moment they happen).
    /// Anything dated in the future is refused rather than written into Apple Health.
    public static func decide(journal: StrapWorkoutJournal?, samples: [HRSample], now: Date = Date()) -> Decision {
        guard let journal else { return .nothingToRecover }
        let start = journal.ledger.start
        guard journal.lastAliveAt <= now else { return .discard(.endsInTheFuture) }
        let inSpan = samples.filter { $0.end > start }
        var end = inSpan.map(\.end).max() ?? journal.lastAliveAt
        if let paused = journal.ledger.openPauseStart { end = min(end, paused) }
        guard end > start, journal.ledger.activeSeconds(until: end) > 0 else { return .discard(.noObservedSpan) }
        guard end <= now else { return .discard(.endsInTheFuture) }
        return .offer(RecoveredStrapWorkout(sport: journal.sport, ledger: journal.ledger, end: end,
                                            samples: inSpan.filter { $0.end <= end }, timelineRaw: journal.timelineRaw))
    }
}
