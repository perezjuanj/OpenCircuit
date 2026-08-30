// WorkoutSessionRecovery.swift — what a fresh process may honestly claim about a workout that was
// running when the previous process died.
//
// WHY THIS EXISTS (tester report 2026-08-29, Gen 2 Air FR04.009, build 49): the running workout
// lived ONLY in `@State` inside the workout sheet, so any sheet teardown destroyed it, and the
// launch path's only reaction to a crash-orphaned session was to end its Live Activity — deleting
// the last evidence that a workout had ever been underway. A ~55-minute evening walk therefore
// vanished from OpenCircuit's own UI. The app now persists a small snapshot while a session runs;
// this file decides what a later launch is ALLOWED to do with it.
//
// The rule the whole file exists to enforce: **the recovered workout ends at the last moment the
// app actually observed the session alive — never at "now".** A process that died at 19:20 has no
// evidence the user kept walking until they next opened the app, and stretching the span to `now`
// would fabricate duration, calories and (via HealthKit) an activity ring credit out of nothing.
// This is the same discipline as the sample-plausibility gate in front of `SyncCursor`: an
// implausible value is refused BEFORE it can reach a durable store.
//
// Deliberately NO staleness threshold. An "offer to save a workout only if it is younger than N"
// rule needs an N, and there is no measured basis for one — so the decision is handed to the user,
// who is the only party that knows whether the walk happened. What IS refused here is the pair of
// spans nobody can defend: a zero/negative one (nothing was ever observed) and one that ends in the
// future (a clock that moved backwards, or a corrupted snapshot).

import Foundation

// MARK: - The persisted snapshot

/// The minimum a running workout writes down so a later launch can prove it existed.
///
/// Kept small and framework-free on purpose: the app persists it as JSON in UserDefaults, which
/// needs no SwiftData schema version (a migration is a launch-crash surface whose recovery path
/// wipes un-resyncable raw history — see the build-44 note in `App.swift`).
///
/// What is NOT in here: the per-reading HR series. Those live in the in-memory aggregator and are
/// lost with the process; persisting a few hundred rows on every heartbeat to save them would be a
/// far larger change than this defect warrants. `hrSampleCount` records how many real readings the
/// dead session had captured, so the recovery UI can say what was lost rather than implying the
/// saved workout carries them.
public struct WorkoutSessionSnapshot: Codable, Equatable, Sendable {
    /// Sport the user selected. Drives the HKWorkoutActivityType a recovered save writes under.
    public var sport: WorkoutSportType
    /// When the session started (the same instant the summary/Live Activity clock counts from).
    public var startDate: Date
    /// The last instant the app OBSERVED this session running — refreshed on the session's periodic
    /// heartbeat. This, not `Date()`, is the recovered workout's end. See the file header.
    public var lastAliveAt: Date
    /// How many genuine HR readings the session had captured by `lastAliveAt`. Not recoverable as
    /// samples; carried so the UI can be honest about what a recovered save does and does not hold.
    public var hrSampleCount: Int
    /// The live active-calorie ESTIMATE as of `lastAliveAt` (Keytel over the readings actually
    /// captured — see `WorkoutSessionAggregator.liveActiveKcal`). nil when no reading ever locked,
    /// in which case a recovered save writes no energy at all rather than inventing one.
    public var activeKcal: Double?
    /// Average / maximum BPM over the readings captured up to `lastAliveAt`, or nil when none were.
    public var avgHR: Int?
    public var maxHR: Int?

    public init(sport: WorkoutSportType,
                startDate: Date,
                lastAliveAt: Date,
                hrSampleCount: Int,
                activeKcal: Double? = nil,
                avgHR: Int? = nil,
                maxHR: Int? = nil) {
        self.sport = sport
        self.startDate = startDate
        self.lastAliveAt = lastAliveAt
        self.hrSampleCount = hrSampleCount
        self.activeKcal = activeKcal
        self.avgHR = avgHR
        self.maxHR = maxHR
    }

    /// JSON for the app's UserDefaults blob. Returns nil only if encoding fails, which for this
    /// all-value-type shape it does not — the optional keeps the call site free of `try!`.
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Decode a persisted blob. Returns nil for absent/garbage data (including a blob written by a
    /// build whose shape differed), so a snapshot we cannot read is treated as no snapshot at all
    /// rather than as a half-populated one.
    public static func decoded(from data: Data?) -> WorkoutSessionSnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(WorkoutSessionSnapshot.self, from: data)
    }
}

// MARK: - The recovered workout

/// A workout an interrupted session left behind, with a span this process is willing to defend.
public struct RecoveredWorkout: Equatable, Sendable {
    public var sport: WorkoutSportType
    public var start: Date
    /// Always the snapshot's `lastAliveAt`. See the file header for why it is never `now`.
    public var end: Date
    public var hrSampleCount: Int
    public var activeKcal: Double?
    public var avgHR: Int?
    public var maxHR: Int?

    public var durationSeconds: TimeInterval { end.timeIntervalSince(start) }

    public init(sport: WorkoutSportType, start: Date, end: Date, hrSampleCount: Int,
                activeKcal: Double? = nil, avgHR: Int? = nil, maxHR: Int? = nil) {
        self.sport = sport
        self.start = start
        self.end = end
        self.hrSampleCount = hrSampleCount
        self.activeKcal = activeKcal
        self.avgHR = avgHR
        self.maxHR = maxHR
    }
}

/// Why a snapshot was refused rather than offered to the user.
public enum WorkoutRecoveryRefusal: String, Equatable, Sendable {
    /// `lastAliveAt <= startDate`: the session died before its first heartbeat, so there is no
    /// observed span at all. Nothing to save and nothing to tell the user about.
    case noObservedSpan
    /// `lastAliveAt > now`: the snapshot claims the session was alive in the future. A device clock
    /// that moved backwards (or a corrupt blob) — refuse it rather than write a future-dated
    /// workout into Apple Health, where it cannot be reasoned about afterwards.
    case endsInTheFuture
}

/// What a launch should do about a persisted snapshot.
public enum WorkoutRecoveryDecision: Equatable, Sendable {
    /// No snapshot, or one this build cannot read. Say nothing.
    case nothingToRecover
    /// A snapshot exists but describes no defensible workout — drop it silently.
    case discard(WorkoutRecoveryRefusal)
    /// Offer the user the choice: save this span to Apple Health, or discard it.
    case offer(RecoveredWorkout)
}

// MARK: - The policy

public enum WorkoutSessionRecovery {

    /// Decide what to do with the snapshot a previous process left behind.
    ///
    /// `now` is injected so the future-span refusal is testable without waiting for a clock.
    public static func decide(snapshot: WorkoutSessionSnapshot?,
                              now: Date = Date()) -> WorkoutRecoveryDecision {
        guard let snapshot else { return .nothingToRecover }
        guard snapshot.lastAliveAt > snapshot.startDate else { return .discard(.noObservedSpan) }
        guard snapshot.lastAliveAt <= now else { return .discard(.endsInTheFuture) }
        return .offer(RecoveredWorkout(
            sport: snapshot.sport,
            start: snapshot.startDate,
            // The observed end, NOT `now`. This is the whole point of the type.
            end: snapshot.lastAliveAt,
            hrSampleCount: snapshot.hrSampleCount,
            activeKcal: snapshot.activeKcal,
            avgHR: snapshot.avgHR,
            maxHR: snapshot.maxHR))
    }
}
