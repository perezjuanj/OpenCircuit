// The app's pure rules for the strap's own workout records (#226, decision 91): where each sync's walk
// starts and how far its cursor moves (91a, 91c), which records are offered for review (91c), when a
// newly offered one is announced (91e), and what a saved one becomes (91d). Same thresholds as the
// ring's detected-workout inbox (`AutomaticWorkoutDetector`, `AutomaticWorkoutInbox`,
// `AutomaticWorkoutAnnouncement`), which is not changed.

import Foundation
import OpenCircuitKit

// MARK: - Where the walk starts (91a)

public enum HelioWorkoutWalkPlan {

    /// The first-ever walk reaches this far back: the ring inbox's review window (91a).
    public static let lookback: TimeInterval = AutomaticWorkoutInbox.retention

    /// The first pass's *since*: the cursor (the newest stored or judged record's start, 91c), or
    /// `lookback` before `now` when there is none. Never more than `lookback` back however old the
    /// cursor is (every older record is past the inbox's two days), never before `notBefore` (decision
    /// 28: the strap's current ownership start), and whole seconds (the walk's *since* has seconds).
    public static func since(cursor: Date?, now: Date, notBefore: Date?) -> Date {
        let floor = now.addingTimeInterval(-lookback)
        var since = cursor.map { max($0, floor) } ?? floor
        if let notBefore { since = max(since, notBefore) }
        return Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down))
    }
}

/// The walk's cursor (91c), moved only over records judged for good. It stops before the first record
/// whose round failed (retried next sync, 91a) or whose verdict can still change (`notYet`), so a
/// later record judged in the same walk never carries it past one of them.
public struct HelioWorkoutWalkCursor: Equatable, Sendable {
    public private(set) var cursor: Date?
    private var blocked = false

    public init(previous: Date?) { cursor = previous }

    /// A record of the walk, in walk order. `final`: its verdict won't change on a later sync.
    public mutating func judged(start: Date, final: Bool) {
        guard !blocked else { return }
        guard final else { blocked = true; return }
        cursor = max(cursor ?? start, start)
    }

    /// A round of the walk failed: no later record moves the cursor this sync.
    public mutating func failed() { blocked = true }
}

// MARK: - Which records are offered (91c)

public enum HelioStrapWorkoutKeep {

    /// The ring's minimum (`AutomaticWorkoutDetector.minimumDuration`, 10 min; Juan's call, 91).
    public static let minimumDuration: TimeInterval = AutomaticWorkoutDetector.minimumDuration
    /// A record must have ended this long before the sync (§22.5: a record still running is unseen).
    public static let settle: TimeInterval = 5 * 60
    /// The inbox's review window (`AutomaticWorkoutInbox.retention`, two days).
    public static let retention: TimeInterval = AutomaticWorkoutInbox.retention

    public enum Reason: String, Equatable, Sendable {
        case tooShort, tooOld, notOwned, inHistory, deleted, discarded
    }

    public enum Verdict: Equatable, Sendable {
        case keep
        case drop(Reason)
        /// Ended less than `settle` before now (or in the future): judged again on a later sync.
        case notYet

        public var isFinal: Bool { self != .notYet }
    }

    /// - Parameters:
    ///   - window: the record's `[start, start + duration)`.
    ///   - owned: the strap owns ALL of the window (decision 28; `DeviceOwnershipLog.ownsWholly`).
    ///   - history: the windows of the workouts already in the app's history.
    ///   - deleted: the windows of the workouts the person deleted (`WorkoutTombstones`).
    ///   - discarded: the windows of the records the person discarded.
    public static func verdict(window: DateInterval, owned: Bool, history: [DateInterval],
                               deleted: [DateInterval], discarded: [DateInterval], now: Date) -> Verdict {
        guard window.end <= now.addingTimeInterval(-settle) else { return .notYet }
        guard window.end >= now.addingTimeInterval(-retention) else { return .drop(.tooOld) }
        guard window.duration >= minimumDuration else { return .drop(.tooShort) }
        guard owned else { return .drop(.notOwned) }
        if history.contains(where: { overlaps($0, window) }) { return .drop(.inHistory) }
        if deleted.contains(where: { overlaps($0, window) }) { return .drop(.deleted) }
        if discarded.contains(where: { overlaps($0, window) }) { return .drop(.discarded) }
        return .keep
    }

    /// Whether two windows share time; touching ends count, as `WorkoutTombstones.suppresses` does.
    public static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start <= b.end && b.start <= a.end
    }
}

// MARK: - The one notification (91e)

public enum HelioStrapWorkoutAnnouncement {
    /// The ring's rule: only within 24 h of the workout's END (`AutomaticWorkoutAnnouncement.maxAge`).
    public static let maxAge: TimeInterval = AutomaticWorkoutAnnouncement.maxAge

    /// Announce a newly kept record once: within `maxAge` of its end, and never for a start already
    /// announced (the record's identity, 91c).
    public static func shouldAnnounce(start: Date, end: Date, announced: Set<Date>, now: Date) -> Bool {
        now.timeIntervalSince(end) <= maxAge && !announced.contains(start)
    }
}

// MARK: - What a saved record becomes (91d)

public enum HelioStrapWorkoutImport {

    /// The record as the strap workout summary the strap's Health write path takes: the chosen sport,
    /// the record's own window (no pauses, no link gaps), the strap's kcal (`16.1`) as the workout's
    /// energy, its average and maximum heart rate (`19.x`, else the readings'), and zones from the
    /// readings. No distance and no route: the strap has no GPS (§22.4).
    public static func summary(_ record: ZeppWorkoutRecord, sport: WorkoutSportType, zones: HeartRateZones) -> StrapWorkoutSummary {
        let window = record.summary.window
        let readings = samples(record)
        let bpms = readings.map(\.bpm)
        let summary = WorkoutSummary(
            sport: sport,
            startDate: window.start,
            endDate: window.end,
            avgHR: record.summary.averageHeartRate ?? (bpms.isEmpty ? nil : bpms.reduce(0, +) / bpms.count),
            maxHR: record.summary.maximumHeartRate ?? bpms.max(),
            estimatedActiveKcal: record.summary.kilocalories.map(Double.init),
            zoneBreakdown: HRZoneClassifier.timeInZonesHeld(hrSamples: readings, zones: zones, sessionEnd: window.end),
            distanceMeters: nil,
            hasRoute: false,
            hrSampleCount: readings.count,
            steps: nil,
            usedFormulaMaxHR: zones.maxHRIsAutomatic)
        return StrapWorkoutSummary(summary: summary, activeSeconds: window.duration, pauses: [], gaps: [])
    }

    /// The readings, each over its own second and never past the workout's end, one per instant.
    public static func samples(_ record: ZeppWorkoutRecord) -> [HRSample] {
        let end = record.summary.end
        var seen = Set<Date>()
        return record.heartRate
            .filter { $0.time < end && seen.insert($0.time).inserted }
            .sorted { $0.time < $1.time }
            .map { HRSample(bpm: $0.bpm, start: $0.time, end: min($0.time.addingTimeInterval(1), end)) }
    }
}
