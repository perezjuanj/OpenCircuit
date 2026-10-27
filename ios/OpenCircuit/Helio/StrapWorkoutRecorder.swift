import CoreLocation
import Foundation
import Observation
import OpenCircuitKit
import UIKit

// A workout recorded with the Amazfit Helio Strap (#227, decision 34): the strap's live heart rate
// for the whole workout, the phone's GPS route for outdoor sports, pause and resume, and ONE
// `HKWorkout` attributed to the strap. The ring's workout (`WorkoutSessionManager`, #75/#173) is not
// touched: this recorder is the strap's own, driven through `StrapWorkoutHeartRateSource` (a thin
// adapter over `HelioSession`, as decision 30's `StrapLiveHeartRate` is).
//
// Robustness, each mirroring the ring where the ring has an answer:
//   • background: the same location session the ring's workout uses (outdoor route, or the opt-in
//     indoor keep-alive, `WorkoutSessionManager.indoorKeepAliveEnabledKey`), so the 1 s keep-alive
//     keeps going while the phone is locked. A Measure stream stops on backgrounding; a workout's
//     doesn't (`HelioSession.appDidEnterBackground`).
//   • the app is killed: a journal (`StrapWorkoutJournal` + an append-only reading file) is kept as
//     the workout runs; the next launch offers the workout back, closed at its last reading
//     (`StrapWorkoutRecovery`), like the ring's interrupted-workout offer.
//   • the link drops: the workout keeps running, the gap is recorded in the ledger and shown, and the
//     reconnected session (HelioConnection's standing connect builds a new one) is adopted and its
//     stream started again.
//
// This is the spec's "route 1" (ZEPP_PROTOCOL.md §18.1): the strap stays in its normal all-day mode.
// Nothing is ever sent on the workout endpoint `0x0019` (no start/pause/end, which no permitted source
// gives, and never the phone-GPS message of §18.5); the route is the phone's own location only. The
// totals are OpenCircuit's own (§18.6): no training effect or recovery time is claimed, and the
// strap's own VO₂ max is never read. An outdoor run gets OpenCircuit's VO₂ max ESTIMATE (#232) from
// the strap's heart rate and the phone's route, exactly the ring's method (docs/TRAINING_METRICS.md),
// saved to Apple Health attributed to the strap.
//
// Heart rate recovery (#337, decision 82): End is unchanged (the same end time, `HKWorkout` and
// samples, saved at once), but the strap's stream keeps running for a recovery window of 120 s (+ up
// to 10 s to catch the +120 s reading). The end of a workout is a small state machine:
//
//     .active ──End──▶ .finishing ──saved──▶ .measuringRecovery ──window closed──▶ .finished
//                         (the HKWorkout write)   (countdown + Skip)
//
// The window closes on its own at the +120 s reading (or end + 130 s), or on Skip, a new workout, or
// the link dropping; it may close while `.finishing` is still writing, and then `.measuringRecovery`
// passes straight on. Only then: HRR1/HRR2 (`HeartRateRecovery`), the recovery readings to Apple
// Health and `LocalStore`, Cardio Recovery, and the sync the workout held back (82g). The hold on the
// strap lasts through the window. A recorder built without a `recoveryHealth` writer has no window:
// End goes straight from `.finishing` to `.finished`, exactly as before #337.
//
// Ring-only users: one recorder is still built per launch (ContentView's hooks are unconditional),
// and it is inert. It touches no CoreBluetooth and no CoreLocation until a strap workout starts, and
// its launch checks find no journal (review-238b N-3).

/// What the recorder needs from a strap connection. `HelioSession` conforms.
@MainActor
protocol StrapWorkoutHeartRateSource: AnyObject {
    var timeline: SyncDeviceID { get }
    var isLinkConnected: Bool { get }
    var ready: Bool { get }
    var syncing: Bool { get }
    var canStreamHeartRate: Bool { get }
    var heartRateObserver: (@MainActor (Int, Date) -> Void)? { get set }
    /// Beat-to-beat (RR) intervals received on this connection so far (a running total).
    var rrIntervalsReceived: Int { get }
    func startWorkoutHeartRate()
    func stopWorkoutHeartRate()
    /// Send the `04 00` a killed process's stream is owed (`StrapWorkoutOrphanStop`), if it is owed and
    /// this connection is authenticated; a connection that isn't sends it at its own `ready`.
    func sendOwedOrphanStop()
    func syncHistory(manual: Bool)
}

extension HelioSession: StrapWorkoutHeartRateSource {}

/// An indoor run or walk's steps from the strap (#339, decision 84b): the realtime step stream. Apart
/// from `StrapWorkoutHeartRateSource` so a source without it simply has no steps. `HelioSession` conforms.
@MainActor
protocol StrapWorkoutStepSource: AnyObject {
    var stepCounterObserver: (@MainActor (Int, Date) -> Void)? { get set }
    /// `05 01`, refused unless the connection can stream steps and a workout holds the link. true when sent.
    @discardableResult func startWorkoutSteps() -> Bool
    func stopWorkoutSteps()
    /// The `05 00` owed for a stream left on (`StrapStepStreamFlag`), if owed and authenticated.
    func sendOwedStepsOff()
}

extension HelioSession: StrapWorkoutStepSource {}

/// What became of one heart-rate recovery write to Apple Health (decision 82c, 82e).
enum HeartRateRecoveryHealthStatus: Equatable {
    case saved
    /// Apple Health isn't connected, or hasn't been asked for this type yet (the app asks once, at
    /// its next open: `ContentView.reconcileNewlyAuthorizableShareTypes`).
    case notConnected
    /// The person turned this type off in Health.
    case sharingOff
    case failed
}

/// The Apple Health half of heart rate recovery, apart from the workout's own write, so neither can
/// fail the other or the workout (decision 82c, 82e).
@MainActor
protocol HeartRateRecoveryHealthWriting: AnyObject {
    /// The recovery readings as plain heart-rate samples, all after the workout's end.
    func saveRecoveryHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus
    /// HRR1 as Cardio Recovery (`heartRateRecoveryOneMinute`, count/min), dated `date`.
    func saveCardioRecovery(_ bpm: Int, at date: Date, timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus
}

/// Why a heart-rate recovery window closed.
enum RecoveryWindowClose: Equatable {
    /// The +120 s reading arrived, or the window's limit passed.
    case complete
    case skipped
    /// The strap's link dropped (or another session replaced it).
    case linkLost
    /// Another workout started; it takes over the hold, so the held-back sync waits for its End.
    case newWorkout
}

/// Where each strap workout's recovery window sat (workout end → window close), so the workout
/// detail can tell recovery readings from the next workout's (#337). UserDefaults, not SwiftData
/// (no schema change). Bounded to the latest `limit` windows.
struct WorkoutRecoveryWindows {
    nonisolated static let key = "strapWorkout.recoveryWindows.v1"
    static let limit = 500
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    var all: [DateInterval] {
        guard let pairs = defaults.array(forKey: Self.key) as? [[Double]] else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2, pair[1] >= pair[0] else { return nil }
            return DateInterval(start: Date(timeIntervalSince1970: pair[0]), end: Date(timeIntervalSince1970: pair[1]))
        }
    }

    func add(_ window: DateInterval) {
        let kept = all.filter { $0.start != window.start } + [window]
        defaults.set(kept.suffix(Self.limit).map { [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970] },
                     forKey: Self.key)
    }

    /// The window of the workout that ended at `end` (within a second: Health stores the same date).
    func window(endingWorkoutAt end: Date) -> DateInterval? {
        all.last { abs($0.start.timeIntervalSince(end)) < 1 }
    }
}

/// One finished strap workout on its way to Apple Health.
struct StrapWorkoutWrite {
    let summary: StrapWorkoutSummary
    /// The readings, each over its own second, inside the running stretches.
    let samples: [HRSample]
    let route: [CLLocation]
    let timeline: SyncDeviceID
    /// An indoor run or walk's step-based distance (#339), nil otherwise.
    var indoorDistance: IndoorDistanceWrite? = nil
}

@MainActor
protocol StrapWorkoutHealthWriting: AnyObject {
    /// One `HKWorkout` (with its heart rate, energy, distance and route). true when it committed.
    func save(_ write: StrapWorkoutWrite) async -> Bool
}

/// The durable journal of a running workout, interrupted workouts the person postponed ("Not now"),
/// and readings still waiting to be stored in `LocalStore` (a store that wasn't available at End).
@MainActor
protocol StrapWorkoutJournalStoring: AnyObject {
    func loadJournal() -> StrapWorkoutJournal?
    func saveJournal(_ journal: StrapWorkoutJournal)
    func appendSamples(_ samples: [HRSample])
    func loadSamples() -> [HRSample]
    /// Remove the running workout's journal and readings (not the parked ones, not the landing queue).
    func clearRunning()
    /// Move the running journal and its readings aside, so a new workout can start without deleting an
    /// interrupted one the person was told they'd be asked about again (review-238 N1).
    func parkRunning()
    func loadParked() -> [StrapWorkoutParked]
    func saveParked(_ parked: [StrapWorkoutParked])
    func loadLanding() -> [StrapWorkoutLandingBatch]
    func saveLanding(_ batches: [StrapWorkoutLandingBatch])
}

/// An interrupted workout set aside by a new workout's start, offered again at the next launch.
struct StrapWorkoutParked: Codable, Equatable {
    var journal: StrapWorkoutJournal
    var samples: [HRSample]
}

/// Readings of one workout not yet stored in `LocalStore` (retried at launch and the next End).
struct StrapWorkoutLandingBatch: Codable, Equatable {
    var timelineRaw: String
    var samples: [HRSample]
}

/// Review-238 SF2: one `04 00` owed to the strap after a killed process's workout stream (§7.1).
/// Persisted, because the recovery offer is answered at launch, usually before the strap is connected:
/// the next authenticated `ready` sends it (`HelioSession.sendOwedOrphanStop`) and clears it.
// SPEC-GAP: whether the strap keeps streaming once the 1 s keep-alive stops is not specified, so the
// stop is sent rather than assumed. It is transient and harmless (§15.1).
struct StrapWorkoutOrphanStop {
    nonisolated static let key = "strapWorkout.orphanStopOwed.v1"
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    var owed: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { if newValue { defaults.set(true, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) } }
    }
}

/// What the VO₂ max estimate (#232) needs beyond the workout itself: the age the user set, the daily
/// resting heart rate before the run, and the Apple Health write. `StrapVO2MaxLive` in the app.
@MainActor
protocol StrapVO2MaxProviding: AnyObject {
    /// nil while the user never set an age (the profile's placeholder is not an age).
    func userSetAge() -> Int?
    /// The daily resting HR from the stored history, the workout's own window left out.
    func restingHR(workoutStart: Date, workoutEnd: Date) -> Double?
    func save(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date,
              timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status
}

/// The app's provider: the profile's age, `LocalStore`'s heart-rate history, `VO2MaxHealthWriter`.
@MainActor
final class StrapVO2MaxLive: StrapVO2MaxProviding {
    private let store: @MainActor () -> LocalStore?
    init(store: @escaping @MainActor () -> LocalStore?) { self.store = store }
    func userSetAge() -> Int? { VO2MaxInputs.userSetAge() }
    func restingHR(workoutStart: Date, workoutEnd: Date) -> Double? {
        guard let store = store() else { return nil }
        return VO2MaxInputs.restingHR(store: store, workoutStart: workoutStart, workoutEnd: workoutEnd)
    }
    func save(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date,
              timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status {
        await VO2MaxHealthWriter().save(estimate, workoutEnd: workoutEnd, timeline: timeline)
    }
}

/// The phone's location for a workout: the route outdoors, or the indoor keep-alive.
@MainActor
protocol WorkoutLocationTracking: AnyObject {
    var gpsActive: Bool { get }
    var distanceMeters: Double? { get }
    var route: [CLLocation] { get }
    var keepAliveUnavailable: Bool { get }
    /// `route == true`: record the route and distance. false: coarse fixes only to stay alive, never stored.
    func start(route: Bool)
    /// Paused: fixes are not stored and no distance accrues; the session keeps the app alive.
    func setPaused(_ paused: Bool)
    func stop()
}

@Observable
@MainActor
final class StrapWorkoutRecorder {

    enum State: Equatable {
        case idle
        case active
        case finishing
        /// Saved; the heart-rate recovery window is still open (decision 82b). Not the
        /// interrupted-workout recovery (`recoverable`), which is about a killed process.
        case measuringRecovery(StrapWorkoutSummary, savedToHealth: Bool)
        case finished(StrapWorkoutSummary, savedToHealth: Bool)
        case error(String)
    }

    // MARK: Observable state (the strap's workout screen)

    private(set) var state: State = .idle
    var selectedSport: WorkoutSportType = .runningOutdoor
    /// Running time so far, pauses left out (refreshed every second).
    private(set) var activeSeconds: TimeInterval = 0
    /// The last reading, shown live (also while paused; it is not RECORDED while paused).
    private(set) var currentHR: Int?
    private(set) var currentHRAt: Date?
    private(set) var liveZoneBreakdown = WorkoutZoneBreakdown()
    private(set) var hrSampleCount = 0
    private(set) var ledger: WorkoutActivityLedger?
    /// When the GPS distance last moved, for the Live Activity's current pace (#283). Reset at every
    /// pause and resume: a pace never spans a pause.
    @ObservationIgnored private var paceTracker = WorkoutPaceTracker()
    /// Beat-to-beat (RR) intervals the strap sent during this workout. A diagnostic: whether the Helio
    /// sends them at all is unknown (ZEPP_PROTOCOL.md §7.1), and an on-demand HRV reading needs them.
    private(set) var rrIntervalCount = 0
    /// The attached session's running total when last read, so a reconnect's new session counts from 0.
    @ObservationIgnored private var rrIntervalsRead = 0
    /// The finished outdoor run's VO₂ max estimate, or why there is none (#232). nil for any other
    /// sport, and while no workout has finished.
    private(set) var vo2MaxOutcome: VO2MaxEstimate.Outcome?
    /// What became of the estimate's Apple Health write: nil while it is in flight.
    private(set) var vo2MaxHealthStatus: VO2MaxHealthWriter.Status?
    /// The +120 s mark of the open recovery window, for the countdown. nil when no window is open.
    private(set) var recoveryMarkAt: Date?
    /// An indoor run or walk (#339): steps per minute over the last 60 s, nil while paused or before any.
    private(set) var liveCadence: Double?
    /// Active steps × stride so far ("est."), nil without steps or a stride.
    private(set) var liveEstimatedMeters: Double?
    /// The finished indoor run or walk: the distance prompt, cadence, its Health writes and indoor VO₂ max.
    private(set) var indoorRun: IndoorRunFinish?
    /// HRR1/HRR2 once the window closed (decision 82d). nil while it is open, and with no window.
    private(set) var heartRateRecovery: HeartRateRecovery.Outcome?
    /// How the window closed.
    private(set) var recoveryClosedBy: RecoveryWindowClose?
    /// The recovery readings' and Cardio Recovery's Apple Health writes: nil while in flight, and a
    /// nil member when that write wasn't attempted.
    private(set) var recoveryHealthStatus: (readings: HeartRateRecoveryHealthStatus?, cardioRecovery: HeartRateRecoveryHealthStatus?)?
    /// A workout the previous process was running when it died, offered back (save or discard). What
    /// the alert shows: nil once it is answered or put off.
    private(set) var recoverable: RecoveredStrapWorkout?
    /// The offer Save and Discard answer, with where it came from so they clear exactly that journal.
    /// It outlives "Not now"'s hide (#296): SwiftUI may run the alert's `isPresented` setter (which
    /// puts it off) before the Save button's action, and the user's Save must still find it. Taken
    /// (set to nil) by the first Save or Discard, so a later put-off is a no-op for that workout.
    @ObservationIgnored private var offer: RecoveryOffer?
    private struct RecoveryOffer {
        let workout: RecoveredStrapWorkout
        let slot: RecoverySlot
    }
    private enum RecoverySlot: Equatable { case running, parked(Int) }

    var isRecording: Bool { state == .active }
    var isPaused: Bool { ledger?.isPaused == true }
    /// The strap's link is down right now (a gap is being recorded).
    var linkDown: Bool { ledger?.isInGap == true }

    /// The reading is too old to show as live (the strap streams once a second).
    var currentHRIsStale: Bool {
        guard let at = currentHRAt else { return true }
        return clock().timeIntervalSince(at) > Self.staleAfter
    }

    static let staleAfter: TimeInterval = 5

    /// A workout owns the strap's link in THIS process: the strap's history syncs wait
    /// (`HelioSession.syncHistory`), and no wake, background run or expiry may sync, tear down or
    /// disconnect it (review-238 B1). In memory on purpose: a killed process leaves nothing holding it.
    ///
    /// It covers `.finishing` as well as `.active` (review-238b SF-1): writing the `HKWorkout` is a
    /// whole `HKWorkoutBuilder` round trip, seconds for a long run with a route, and a background run
    /// that started in that window used to tear the link down before `end()` could run the sync the
    /// workout had held back. Every terminal state (`.finished`, `.idle`, `.error`) releases it, and
    /// `end()` clears `running` on the way out whatever happens.
    static var holdsStrapLink: Bool {
        guard let running else { return false }
        return running.state == .active || running.state == .finishing || running.isMeasuringRecovery
    }

    /// The recovery window is open and the workout is saved (decision 82b). The hold lasts through it.
    var isMeasuringRecovery: Bool {
        if case .measuringRecovery = state { return true }
        return false
    }

    /// The summary on screen, during the recovery window and after it.
    private var shownSummary: StrapWorkoutSummary? {
        switch state {
        case .measuringRecovery(let summary, _), .finished(let summary, _): return summary
        default: return nil
        }
    }
    private static weak var running: StrapWorkoutRecorder?

    // MARK: Collaborators

    @ObservationIgnored private let source: @MainActor () -> (any StrapWorkoutHeartRateSource)?
    @ObservationIgnored private let health: any StrapWorkoutHealthWriting
    @ObservationIgnored private let journal: any StrapWorkoutJournalStoring
    @ObservationIgnored private let hrStore: @MainActor () -> (any StrapWorkoutHRStore)?
    let location: any WorkoutLocationTracking
    @ObservationIgnored private let liveActivity: WorkoutLiveActivityController?
    @ObservationIgnored private let profile: @MainActor () -> UserProfile
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private let managesIdleTimer: Bool
    @ObservationIgnored private let indoorKeepAlive: () -> Bool
    @ObservationIgnored private let orphanStop: StrapWorkoutOrphanStop
    @ObservationIgnored private let vo2: (any StrapVO2MaxProviding)?
    /// Workouts deleted from the history screen (#293): never offered back after a kill.
    @ObservationIgnored private let tombstones: WorkoutTombstones
    /// Heart rate recovery's Apple Health writes. nil: no recovery window (End as before #337).
    @ObservationIgnored private let recoveryHealth: (any HeartRateRecoveryHealthWriting)?
    @ObservationIgnored private let recoveryWindows: WorkoutRecoveryWindows
    /// Indoor runs' Health writes beyond the workout (#339). nil: none (a rig that didn't ask).
    @ObservationIgnored private let indoorHealth: (any IndoorRunHealthWriting)?
    @ObservationIgnored private let stepStreamFlag: StrapStepStreamFlag
    @ObservationIgnored private let strideCalibrations: IndoorStrideCalibrations
    @ObservationIgnored private let userHeightCm: () -> Double?

    // MARK: Session state

    @ObservationIgnored private weak var attached: (any StrapWorkoutHeartRateSource)?
    @ObservationIgnored private var timeline: SyncDeviceID?
    @ObservationIgnored private var samples: [HRSample] = []
    @ObservationIgnored private var unjournaled: [HRSample] = []
    @ObservationIgnored private var lastRecordedAt: Date?
    @ObservationIgnored private var profileSnapshot: UserProfile?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// The open recovery window: from End until its readings are handed on.
    private struct RecoveryWindow {
        let workoutEnd: Date
        let timeline: SyncDeviceID
        var readings: [HRSample] = []
        var closedBy: RecoveryWindowClose?
        var closedAt: Date?
        /// The workout's active-time readings, for the peak (set once the workout is saved).
        var activeReadings: [HRSample]?
    }
    @ObservationIgnored private var recoveryWindow: RecoveryWindow?
    /// An indoor run or walk's steps (#339, decision 84c); nil for every other sport.
    @ObservationIgnored private var steps: IndoorStepTracker?
    @ObservationIgnored private weak var stepSource: (any StrapWorkoutStepSource)?
    /// This workout's `05 01` is in force (decision 84b).
    @ObservationIgnored private var stepsStreaming = false
    /// The stream stopped with the link and wasn't turned on again (no `05 01` after a reconnect).
    @ObservationIgnored private var stepsInterrupted = false
    /// Readings received during the open pause (82d measures from the end, and a workout ended while
    /// paused ended where the pause began). Cleared at every pause and resume.
    @ObservationIgnored private var pausedReadings: [HRSample] = []
    /// The recovery Health writes and landing, for tests to await.
    @ObservationIgnored private(set) var recoveryWriteTask: Task<Void, Never>?

    /// Journal heartbeat and Live Activity refresh, the ring's ~10 s cadence.
    static let heartbeatTicks = 10

    init(source: @escaping @MainActor () -> (any StrapWorkoutHeartRateSource)?,
         health: any StrapWorkoutHealthWriting,
         journal: any StrapWorkoutJournalStoring,
         hrStore: @escaping @MainActor () -> (any StrapWorkoutHRStore)?,
         location: any WorkoutLocationTracking,
         liveActivity: WorkoutLiveActivityController?,
         profile: @escaping @MainActor () -> UserProfile = { HealthKitWriter.storedUserProfile() },
         indoorKeepAlive: @escaping () -> Bool = {
             UserDefaults.standard.bool(forKey: WorkoutSessionManager.indoorKeepAliveEnabledKey)
         },
         orphanStop: StrapWorkoutOrphanStop = StrapWorkoutOrphanStop(),
         vo2: (any StrapVO2MaxProviding)? = nil,
         tombstones: WorkoutTombstones = WorkoutTombstones(),
         recoveryHealth: (any HeartRateRecoveryHealthWriting)? = nil,
         recoveryWindows: WorkoutRecoveryWindows = WorkoutRecoveryWindows(),
         indoorHealth: (any IndoorRunHealthWriting)? = nil,
         stepStreamFlag: StrapStepStreamFlag = StrapStepStreamFlag(),
         strideCalibrations: IndoorStrideCalibrations = IndoorStrideCalibrations(),
         userHeightCm: @escaping () -> Double? = { IndoorRunProfile.userSetHeightCm() },
         clock: @escaping () -> Date = Date.init,
         autoTick: Bool = true,
         managesIdleTimer: Bool = true) {
        self.source = source
        self.health = health
        self.journal = journal
        self.hrStore = hrStore
        self.location = location
        self.liveActivity = liveActivity
        self.profile = profile
        self.indoorKeepAlive = indoorKeepAlive
        self.orphanStop = orphanStop
        self.vo2 = vo2
        self.tombstones = tombstones
        self.recoveryHealth = recoveryHealth
        self.recoveryWindows = recoveryWindows
        self.indoorHealth = indoorHealth
        self.stepStreamFlag = stepStreamFlag
        self.strideCalibrations = strideCalibrations
        self.userHeightCm = userHeightCm
        self.clock = clock
        self.autoTick = autoTick
        self.managesIdleTimer = managesIdleTimer
    }

    /// The app's one recorder, built the first time it is used (review-238 N2: a `@State` initial value
    /// is evaluated on every `ContentView` init). Nothing in it touches CoreLocation, CoreBluetooth or
    /// the journal files until a strap workout starts or the launch looks for an interrupted one.
    static let shared = live(store: { OpenCircuitApp.sharedContainer.map { LocalStore($0.mainContext) } })

    /// The app's recorder: the shared strap connection, Apple Health, files in Application Support.
    static func live(store: @escaping @MainActor () -> LocalStore?) -> StrapWorkoutRecorder {
        StrapWorkoutRecorder(source: { HelioConnection.shared.session },
                             health: StrapWorkoutHealthWriter(),
                             journal: StrapWorkoutFileJournal(),
                             hrStore: store,
                             location: StrapWorkoutLocation(),
                             liveActivity: WorkoutLiveActivityController(),
                             vo2: StrapVO2MaxLive(store: store),
                             recoveryHealth: HeartRateRecoveryHealthWriter(),
                             indoorHealth: IndoorRunHealthWriter())
    }

    // MARK: Start, pause, resume

    /// Whether Start may be offered: an authenticated strap that can stream, and no sync on the link
    /// (the ring's Start waits for its sync the same way, T1).
    func canStart(_ session: (any StrapWorkoutHeartRateSource)?) -> Bool {
        guard state == .idle, let session else { return false }
        return session.ready && session.canStreamHeartRate && !session.syncing
    }

    func start() {
        guard state == .idle, let session = source(), canStart(session) else { return }
        let now = clock()
        let sport = selectedSport
        Self.running = self
        timeline = session.timeline
        ledger = WorkoutActivityLedger(start: now)
        profileSnapshot = profile()
        samples = []
        unjournaled = []
        lastRecordedAt = nil
        activeSeconds = 0
        currentHR = nil
        currentHRAt = nil
        liveZoneBreakdown = WorkoutZoneBreakdown()
        paceTracker.reset()
        hrSampleCount = 0
        tickCount = 0
        vo2MaxOutcome = nil
        vo2MaxHealthStatus = nil
        clearHeartRateRecovery()
        rrIntervalCount = 0
        clearSteps()
        if IndoorStepWorkout.applies(to: sport) {
            steps = IndoorStepTracker(sport: sport, stride: IndoorStride.forWorkout(
                sport: sport, heightCm: userHeightCm(),
                calibrated: strideCalibrations.stride(timeline: session.timeline, sport: sport)))
        }
        // Review-238 N1: an interrupted workout still waiting for the person's answer ("Not now") is set
        // aside, never deleted; the next launch offers it again. A put-off offer's slot no longer points
        // at it once it is parked, so nothing may answer it in this process any more.
        if recoverable == nil { offer = nil }
        if journal.loadJournal() != nil { journal.parkRunning() } else { journal.clearRunning() }
        persistJournal(now: now)
        attach(session, now: now)
        if sport.isOutdoor {
            location.start(route: true)
        } else if indoorKeepAlive() {
            location.start(route: false)
        }
        if managesIdleTimer { UIApplication.shared.isIdleTimerDisabled = true }
        state = .active
        // Decision 84b: `05 01` at the start of an indoor workout, once the workout holds the link.
        turnStepsOn(session, now: now)
        helioLog.notice("helio: workout started (\(sport.rawValue, privacy: .public))")
        liveActivity?.start(sport: sport, startDate: now,
                            initial: WorkoutActivityAttributes.ContentState(
                                elapsedSeconds: 0, activeKcal: 0, bpm: nil, hrIsStale: true))
        if autoTick { startTicking() }
    }

    func pause() {
        guard state == .active, var ledger, !ledger.isPaused else { return }
        let now = clock()
        ledger.pause(at: now)
        self.ledger = ledger
        pausedReadings = []
        paceTracker.reset()
        turnStepsOff()   // decision 84b: `05 00` at pause
        location.setPaused(true)
        refresh(now: now)
        persistJournal(now: now)
        helioLog.notice("helio: workout paused")
        Task { await pushLiveActivity() }
    }

    func resume() {
        guard state == .active, var ledger, ledger.isPaused else { return }
        let now = clock()
        ledger.resume(at: now)
        self.ledger = ledger
        pausedReadings = []
        paceTracker.reset()
        if let attached { turnStepsOn(attached, now: now) }   // decision 84b: `05 01` at resume
        location.setPaused(false)
        refresh(now: now)
        persistJournal(now: now)
        helioLog.notice("helio: workout resumed")
        Task { await pushLiveActivity() }
    }

    // MARK: Time

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.tick(now: self.clock())
            }
        }
    }

    /// Once a second in production; tests call it directly. Follows the link (gap, adoption), keeps
    /// the readings journaled, and on the heartbeat re-stamps the journal and the Live Activity.
    func tick(now: Date) async {
        if recoveryWindow != nil { return followRecovery(now: now) }
        guard state == .active else { return }
        followLink(now: now)
        flushReadings()
        refresh(now: now)
        tickCount += 1
        if tickCount % Self.heartbeatTicks == 0 {
            persistJournal(now: now)
            await pushLiveActivity()
        }
    }

    private func refresh(now: Date) {
        guard let ledger else { return }
        activeSeconds = ledger.activeSeconds(until: now)
        if !ledger.isPaused, selectedSport.isOutdoor { paceTracker.observe(distanceMeters: location.distanceMeters, at: now) }
        if let steps {
            liveCadence = ledger.isPaused ? nil : steps.liveCadence(now: now)
            liveEstimatedMeters = steps.estimatedMeters
        }
        liveZoneBreakdown = StrapWorkoutSummaryBuilder.zones(samples, ledger: ledger, end: now, maxHR: maxHR)
    }

    private var maxHR: Int { max(220 - max((profileSnapshot ?? profile()).age, 1), 1) }

    // MARK: The link

    /// The attached session lost its link, or HelioConnection replaced it: open a gap. A session that
    /// is back and ready: adopt it, start its stream, close the gap.
    private func followLink(now: Date) {
        guard var ledger else { return }
        let current = source()
        if let attached, attached !== current || !attached.isLinkConnected {
            attached.heartRateObserver = nil
            self.attached = nil
            // Decision 84b: the stream went with the link. The reconnected session sends the owed
            // `05 00` at its setup, and nothing turns it on again until a resume.
            if stepsStreaming {
                stepsStreaming = false
                stepsInterrupted = true
                persistJournal(now: now)
            }
            stepSource?.stepCounterObserver = nil
            stepSource = nil
        }
        if attached == nil, !ledger.isInGap {
            ledger.beginGap(at: now)
            helioLog.notice("helio: workout link lost; the workout keeps running")
        }
        self.ledger = ledger
        if attached == nil, let current, current.isLinkConnected, current.ready, current.canStreamHeartRate,
           current.timeline == timeline {
            attach(current, now: now)
        }
    }

    private func attach(_ session: any StrapWorkoutHeartRateSource, now: Date) {
        attached = session
        session.heartRateObserver = { [weak self] bpm, at in self?.receive(bpm: bpm, at: at) }
        rrIntervalsRead = session.rrIntervalsReceived
        session.startWorkoutHeartRate()
        if var ledger, ledger.isInGap {
            ledger.endGap(at: now)
            self.ledger = ledger
            helioLog.notice("helio: workout link back; heart rate restarted")
        }
    }

    /// One reading from the strap. Shown always; recorded only while running, once per instant.
    func receive(bpm: Int, at: Date) {
        if recoveryWindow != nil { return receiveRecovery(bpm: bpm, at: at) }
        guard state == .active, let ledger, LiveHR.validBPM.contains(bpm) else { return }
        currentHR = bpm
        currentHRAt = at
        if let total = attached?.rrIntervalsReceived {
            rrIntervalCount += max(0, total - rrIntervalsRead)
            rrIntervalsRead = total
        }
        if let pausedAt = ledger.openPauseStart { keepPausedReading(bpm: bpm, at: at, pausedAt: pausedAt) }
        guard !ledger.isPaused, at > ledger.start, at > (lastRecordedAt ?? .distantPast) else { return }
        lastRecordedAt = at
        let sample = HRSample(bpm: bpm, start: at.addingTimeInterval(-StrapWorkoutSampleLine.span), end: at)
        samples.append(sample)
        unjournaled.append(sample)
        hrSampleCount += 1
    }

    // MARK: Steps (#339, decision 84b, 84c)

    /// `05 01` for an indoor run or walk that is running, on a source that has the stream. The first
    /// frame after it is a base (`IndoorStepTracker.rebase`), so nothing from before is credited.
    private func turnStepsOn(_ session: any StrapWorkoutHeartRateSource, now: Date) {
        guard steps != nil, state == .active, ledger?.isPaused == false, !stepsStreaming,
              let source = session as? any StrapWorkoutStepSource else { return }
        steps?.rebase()
        source.stepCounterObserver = { [weak self] counter, at in self?.receiveSteps(counter: counter, at: at) }
        stepSource = source
        if source.startWorkoutSteps() {
            stepsStreaming = true
            persistJournal(now: now)
        }
    }

    /// `05 00` for this workout's stream (pause, End, cancel). The next reading is a base.
    private func turnStepsOff() {
        guard steps != nil else { return }
        if stepsStreaming { stepSource?.stopWorkoutSteps() }
        stepsStreaming = false
        steps?.rebase()
        liveCadence = nil
    }

    /// One counter reading from the strap: counted only while the workout runs (84c).
    private func receiveSteps(counter: Int, at: Date) {
        guard state == .active, var tracker = steps, let ledger else { return }
        tracker.observe(counter, at: at, running: !ledger.isPaused && !ledger.isInGap)
        steps = tracker
        liveEstimatedMeters = tracker.estimatedMeters
    }

    private func clearSteps() {
        steps = nil
        stepSource?.stepCounterObserver = nil
        stepSource = nil
        stepsStreaming = false
        stepsInterrupted = false
        liveCadence = nil
        liveEstimatedMeters = nil
        indoorRun = nil
    }

    // MARK: End

    /// End the workout: write one `HKWorkout`, queue its readings for `LocalStore`, then keep the strap's
    /// stream for the heart-rate recovery window (decision 82) and release the link when it closes.
    func end() async {
        guard state == .active, let ledger, let timeline else { return }
        state = .finishing
        // The hold lasts until this returns, through the Health write (SF-1), and on through an open
        // recovery window (82g); released here whatever path leaves the function otherwise, so nothing
        // can hold the strap for good.
        defer { if Self.running === self, !isMeasuringRecovery { Self.running = nil } }
        let now = clock()
        // Ended while paused: the workout ends where it stopped running.
        let end = ledger.openPauseStart ?? now
        // 82a/82b: the stream keeps running after End for the recovery window; the workout below is
        // exactly today's. Without a window (no recovery writer) the stream stops here, as before.
        // Decision 84b: `05 00` at End, before anything else can wait.
        turnStepsOff()
        stepSource?.stepCounterObserver = nil
        stepSource = nil
        let indoorSteps = steps
        let windowOpen = openRecoveryWindow(end: end, now: now, timeline: timeline)
        if !windowOpen {
            tickTask?.cancel()
            tickTask = nil
            attached?.stopWorkoutHeartRate()
            attached?.heartRateObserver = nil
            attached = nil
        }
        location.stop()
        // The screen stays on through an open window: the countdown is on it.
        if managesIdleTimer, !windowOpen { UIApplication.shared.isIdleTimerDisabled = false }

        let hasRoute = selectedSport.isOutdoor && !location.route.isEmpty
        let summary = StrapWorkoutSummaryBuilder.summarize(
            sport: selectedSport, ledger: ledger, samples: samples, end: end,
            distanceMeters: hasRoute ? location.distanceMeters : nil, hasRoute: hasRoute,
            profile: profileSnapshot ?? profile())
        let counted = StrapWorkoutSummaryBuilder.activeSamples(samples, ledger: ledger, end: end)

        // Queue the readings for LocalStore BEFORE dropping the journal, so a kill in between loses
        // nothing; then drop the journal BEFORE the Health write, as the ring drops its snapshot: a
        // kill during the write costs this one workout's recovery offer, never a duplicate in Health.
        // They are stored after the write; Health never gets them a second time from the store
        // (`StrapWorkoutHealthExclusions`). A kill in the recovery window that follows loses only the
        // recovery readings, which are in memory (82g).
        enqueueLanding(counted, timeline: timeline)
        journal.clearRunning()

        await liveActivity?.end(final: WorkoutActivityAttributes.ContentState(
            elapsedSeconds: summary.activeSeconds,
            activeKcal: Int((summary.summary.estimatedActiveKcal ?? 0).rounded()),
            bpm: summary.summary.avgHR, hrIsStale: true))

        // An indoor run or walk: its step estimate is the workout's distance (84f), replaced later if the
        // person types the treadmill's (84e). Nothing about it delays this write.
        let indoorDistance = indoorSteps?.estimatedMeters.map(IndoorDistanceWrite.init(meters:))
        let saved = await health.save(StrapWorkoutWrite(summary: summary, samples: counted,
                                                         route: hasRoute ? location.route : [], timeline: timeline,
                                                         indoorDistance: indoorDistance))
        helioLog.notice("helio: workout ended, \(counted.count, privacy: .public) reading(s), saved to Health \(saved, privacy: .public)")
        landPendingHeartRate()
        // #232: the VO₂ max estimate for an outdoor run, after the workout's own write so a one-time
        // VO₂ max permission sheet never sits on the "Saving workout…" path (the ring's order).
        vo2MaxOutcome = summary.summary.sport == .runningOutdoor
            ? vo2MaxEstimate(summary, samples: counted, route: hasRoute ? location.route : [])
            : nil
        // Not saved: the workout isn't in Health, so neither is its estimate (the ring's rule).
        vo2MaxHealthStatus = saved ? nil : .failed
        if let indoorSteps {
            let finish = IndoorRunFinish(inputs: IndoorRunInputs(
                sport: selectedSport, timeline: timeline, start: ledger.start, end: end,
                activeSeconds: summary.activeSeconds, activeSegments: ledger.activeSegments(until: end),
                steps: indoorSteps.log, stride: indoorSteps.stride, stepsInterrupted: stepsInterrupted,
                savedToHealth: saved, heartRate: counted,
                age: vo2?.userSetAge(),
                restingHR: selectedSport == .runningIndoor
                    ? vo2?.restingHR(workoutStart: ledger.start, workoutEnd: end) : nil),
                health: indoorHealth, calibrations: strideCalibrations)
            indoorRun = finish
            finish.writeEstimateMetrics()
        }
        // `.finished` BEFORE the sync, so the hold is already released when `syncHistory` asks:
        // otherwise the workout's own hold would defer the very sync it held back. With a recovery
        // window, `.measuringRecovery` first: the hold stays, and the sync waits for the window.
        if recoveryWindow != nil {
            recoveryWindow?.activeReadings = counted
            state = .measuringRecovery(summary, savedToHealth: saved)
        } else {
            state = .finished(summary, savedToHealth: saved)
        }
        if saved, case .estimate(let estimate)? = vo2MaxOutcome, let vo2 {
            let workoutEnd = summary.summary.endDate
            Task { [weak self] in
                let status = await vo2.save(estimate, workoutEnd: workoutEnd, timeline: timeline)
                // Only into the summary it belongs to (the person may have started another workout).
                guard let self, let shown = self.shownSummary,
                      shown.summary.startDate == summary.summary.startDate else { return }
                self.vo2MaxHealthStatus = status
            }
        }
        if recoveryWindow != nil {
            // The window may have closed while the workout was being written.
            finishRecoveryIfClosed()
            return
        }
        // The sync the workout held back (T6's re-arm, for the strap).
        runHeldBackSync()
    }

    private func runHeldBackSync() {
        if let session = source(), session.ready, !session.syncing { session.syncHistory(manual: false) }
    }

    // MARK: Heart rate recovery (#337, decision 82)

    /// Skip on the summary: the window closes now with the readings so far.
    func skipRecovery() {
        closeRecovery(.skipped, now: clock())
    }

    /// Another workout is about to start (the "Start Workout" shortcut): the window closes now, and
    /// the summary passes on to `.finished` so `reset()` can clear it. The new workout takes the hold,
    /// so the held-back sync runs at ITS end instead (82g). Only once the workout is saved.
    func endRecoveryForNewWorkout() {
        guard isMeasuringRecovery else { return }
        closeRecovery(.newWorkout, now: clock())
    }

    /// Open the window at End. False when there is none: no recovery writer, or nothing left to
    /// wait for. A window with no stream to keep (the link already down, or a long pause that already
    /// outlasted it) opens closed, so the readings the pause kept are still measured.
    private func openRecoveryWindow(end: Date, now: Date, timeline: SyncDeviceID) -> Bool {
        guard recoveryHealth != nil else { return false }
        var window = RecoveryWindow(workoutEnd: end, timeline: timeline)
        window.readings = pausedReadings.filter { $0.start >= end && $0.end <= end.addingTimeInterval(HeartRateRecovery.windowLimit) }
        pausedReadings = []
        recoveryWindow = window
        recoveryMarkAt = end.addingTimeInterval(HeartRateRecovery.window)
        let streaming = attached.map { $0 === source() && $0.isLinkConnected } ?? false
        if !streaming {
            closeRecovery(.linkLost, now: now)
        } else if let last = window.readings.last, last.end >= end.addingTimeInterval(HeartRateRecovery.window) {
            closeRecovery(.complete, now: now)
        } else if now >= end.addingTimeInterval(HeartRateRecovery.windowLimit) {
            closeRecovery(.complete, now: now)
        }
        return recoveryWindow?.closedBy == nil
    }

    /// While paused: a reading the strap still streams, kept in case the workout ends in this pause.
    private func keepPausedReading(bpm: Int, at: Date, pausedAt: Date) {
        let sample = HRSample(bpm: bpm, start: at.addingTimeInterval(-StrapWorkoutSampleLine.span), end: at)
        guard sample.start >= pausedAt, at <= pausedAt.addingTimeInterval(HeartRateRecovery.windowLimit),
              at > (pausedReadings.last?.end ?? .distantPast) else { return }
        pausedReadings.append(sample)
    }

    /// One reading inside the window: shown live, and kept when it lies wholly after the workout's
    /// end (never inside it, 82c) and inside the window. The +120 s reading closes the window.
    private func receiveRecovery(bpm: Int, at: Date) {
        guard var window = recoveryWindow, window.closedBy == nil, LiveHR.validBPM.contains(bpm) else { return }
        currentHR = bpm
        currentHRAt = at
        let limit = window.workoutEnd.addingTimeInterval(HeartRateRecovery.windowLimit)
        let sample = HRSample(bpm: bpm, start: at.addingTimeInterval(-StrapWorkoutSampleLine.span), end: at)
        if sample.start >= window.workoutEnd, at <= limit, at > (window.readings.last?.end ?? .distantPast) {
            window.readings.append(sample)
            recoveryWindow = window
        }
        if at >= window.workoutEnd.addingTimeInterval(HeartRateRecovery.window) {
            closeRecovery(.complete, now: at)
        }
    }

    /// Each tick of an open window: the link dropped or was replaced, or the window ran out.
    private func followRecovery(now: Date) {
        guard let window = recoveryWindow, window.closedBy == nil else { return }
        if let attached, attached === source(), attached.isLinkConnected {
            if now >= window.workoutEnd.addingTimeInterval(HeartRateRecovery.windowLimit) {
                closeRecovery(.complete, now: now)
            }
        } else {
            attached?.heartRateObserver = nil
            attached = nil
            closeRecovery(.linkLost, now: now)
        }
    }

    /// Close the window: the stream stops, the screen may sleep. The readings are handed on once the
    /// workout is saved (`finishRecoveryIfClosed`).
    private func closeRecovery(_ reason: RecoveryWindowClose, now: Date) {
        guard var window = recoveryWindow, window.closedBy == nil else { return }
        window.closedBy = reason
        window.closedAt = min(max(now, window.workoutEnd),
                              window.workoutEnd.addingTimeInterval(HeartRateRecovery.windowLimit))
        recoveryWindow = window
        tickTask?.cancel()
        tickTask = nil
        attached?.stopWorkoutHeartRate()
        attached?.heartRateObserver = nil
        attached = nil
        if managesIdleTimer { UIApplication.shared.isIdleTimerDisabled = false }
        helioLog.notice("helio: recovery window closed (\(String(describing: reason), privacy: .public)), \(window.readings.count, privacy: .public) reading(s)")
        finishRecoveryIfClosed()
    }

    /// A closed window of a saved workout: HRR1/HRR2, `.finished`, the hold released, the readings to
    /// Apple Health and `LocalStore`, Cardio Recovery, then the held-back sync (82g).
    private func finishRecoveryIfClosed() {
        guard let window = recoveryWindow, let closedBy = window.closedBy, let active = window.activeReadings,
              case .measuringRecovery(let summary, let saved) = state else { return }
        recoveryWindow = nil
        recoveryMarkAt = nil
        let bound = HeartRateRecovery.zoneFourLowerBound { [maxHR] in HRZoneClassifier.zone(bpm: $0, maxHR: maxHR) }
            ?? LiveHR.validBPM.upperBound + 1
        let outcome = HeartRateRecovery.measure(activeReadings: active, recoveryReadings: window.readings,
                                                end: window.workoutEnd, zoneFourLowerBound: bound)
        heartRateRecovery = outcome
        recoveryClosedBy = closedBy
        state = .finished(summary, savedToHealth: saved)
        if Self.running === self { Self.running = nil }
        recoveryWindows.add(DateInterval(start: window.workoutEnd, end: window.closedAt ?? window.workoutEnd))
        // Queued before any Health write, so a kill in between still stores them (never twice in Health:
        // they land behind a `StrapWorkoutHealthExclusions` span, as the workout's own readings do).
        enqueueLanding(window.readings, timeline: window.timeline)
        let timeline = window.timeline
        let readings = window.readings
        let cardioAt = window.workoutEnd.addingTimeInterval(HeartRateRecovery.oneMinute)
        recoveryWriteTask = Task { [weak self] in
            guard let self else { return }
            var readingsStatus: HeartRateRecoveryHealthStatus?
            var cardioStatus: HeartRateRecoveryHealthStatus?
            if let health = self.recoveryHealth {
                // Each write on its own: neither can fail the other, and the workout is already saved.
                if !readings.isEmpty {
                    readingsStatus = await health.saveRecoveryHeartRate(readings, timeline: timeline)
                }
                // 82e: HRR1 to Cardio Recovery, when computed. Not for a workout Health refused (the
                // VO₂ max rule): the value would describe a workout that isn't there.
                if saved, let drop = outcome.oneMinute.drop {
                    cardioStatus = await health.saveCardioRecovery(drop, at: cardioAt, timeline: timeline)
                }
            }
            self.landPendingHeartRate()
            guard let shown = self.shownSummary, shown.summary.startDate == summary.summary.startDate else { return }
            self.recoveryHealthStatus = (readingsStatus, cardioStatus)
        }
        if closedBy != .newWorkout { runHeldBackSync() }
    }

    private func clearHeartRateRecovery() {
        recoveryWindow = nil
        pausedReadings = []
        recoveryMarkAt = nil
        heartRateRecovery = nil
        recoveryClosedBy = nil
        recoveryHealthStatus = nil
    }

    /// `VO2MaxEstimate` over this workout. The strap's readings are only those inside the running
    /// stretches, and the route stores no fixes while paused, so a steady segment can never span a
    /// pause or a strap disconnect (no readings, or no GPS fix within 15 s, there). The 10-minute rule
    /// is on the RUNNING time: a 7-minute run with a long pause in it is still too short.
    private func vo2MaxEstimate(_ result: StrapWorkoutSummary, samples: [HRSample],
                                route: [CLLocation]) -> VO2MaxEstimate.Outcome? {
        // No provider (a rig that didn't ask for one): no outcome at all rather than a wrong reason.
        guard let vo2 else { return nil }
        guard result.activeSeconds >= VO2MaxEstimate.minimumDuration else { return .skipped(.tooShort) }
        let summary = result.summary
        return VO2MaxEstimate.estimate(VO2MaxEstimate.Input(
            sport: summary.sport, start: summary.startDate, end: summary.endDate,
            heartRate: samples, route: VO2MaxInputs.routePoints(route),
            age: vo2.userSetAge(),
            restingHR: vo2.restingHR(workoutStart: summary.startDate, workoutEnd: summary.endDate)))
    }

    /// Discard the workout: nothing is written anywhere.
    func cancel() {
        guard state == .active else { return }
        tickTask?.cancel()
        tickTask = nil
        if Self.running === self { Self.running = nil }
        turnStepsOff()   // decision 84b: `05 00` at cancel
        clearSteps()
        attached?.stopWorkoutHeartRate()
        attached?.heartRateObserver = nil
        attached = nil
        location.stop()
        if managesIdleTimer { UIApplication.shared.isIdleTimerDisabled = false }
        journal.clearRunning()
        let final = WorkoutActivityAttributes.ContentState(elapsedSeconds: activeSeconds, activeKcal: 0,
                                                           bpm: nil, hrIsStale: true)
        Task { await liveActivity?.end(final: final) }
        samples = []
        unjournaled = []
        ledger = nil
        state = .idle
        if let session = source(), session.ready, !session.syncing { session.syncHistory(manual: false) }
    }

    /// Back to the sport picker after the summary (or an error).
    func reset() {
        switch state {
        case .finished, .error: break
        default: return
        }
        state = .idle
        ledger = nil
        samples = []
        activeSeconds = 0
        currentHR = nil
        currentHRAt = nil
        hrSampleCount = 0
        liveZoneBreakdown = WorkoutZoneBreakdown()
        vo2MaxOutcome = nil
        vo2MaxHealthStatus = nil
        clearHeartRateRecovery()
        rrIntervalCount = 0
        clearSteps()
    }

    // MARK: Journal

    private func persistJournal(now: Date) {
        guard let ledger, let timeline else { return }
        flushReadings()
        journal.saveJournal(StrapWorkoutJournal(sport: selectedSport, ledger: ledger, lastAliveAt: now,
                                                timelineRaw: timeline.rawValue,
                                                distanceMeters: location.distanceMeters,
                                                stepStreamOn: steps == nil ? nil : stepsStreaming))
    }

    private func flushReadings() {
        guard !unjournaled.isEmpty else { return }
        journal.appendSamples(unjournaled)
        unjournaled = []
    }

    // MARK: Recovery

    /// At launch: offer back a workout the previous process was running when it died, or one a new
    /// workout set aside after "Not now". Never while a workout runs in this process.
    func resolveOrphan(now: Date? = nil) {
        guard state == .idle, recoverable == nil else { return }
        let now = now ?? clock()
        var found: RecoveryOffer?
        defer {
            offer = found
            recoverable = found?.workout
        }
        if let running = journal.loadJournal() {
            // Review-238 SF2: whatever the answer (Save, Discard, Not now, or a refusal below), the dead
            // process's stream is owed one `04 00`, sent at the strap's next authenticated `ready`.
            orphanStop.owed = true
            // Decision 84b: a workout killed with the step stream on owes the strap a `05 00` too.
            if running.stepStreamOn == true { stepStreamFlag.offOwed = true }
            switch tombstones.filter(StrapWorkoutRecovery.decide(journal: running, samples: journal.loadSamples(), now: now)) {
            case .nothingToRecover:
                break
            case .discard(let refusal):
                helioLog.notice("helio: discarding an interrupted workout journal (\(refusal.rawValue, privacy: .public))")
                journal.clearRunning()
            case .offer(let recovered):
                helioLog.notice("helio: offering an interrupted workout back")
                found = RecoveryOffer(workout: recovered, slot: .running)
            }
        }
        if found == nil {
            // A workout set aside by a new one's start after "Not now"; one with no defensible span, or one
            // the user has since deleted from the history (#293), is dropped.
            var parked = journal.loadParked()
            let before = parked.count
            while let first = parked.first {
                if case .offer(let recovered) = tombstones.filter(StrapWorkoutRecovery.decide(journal: first.journal, samples: first.samples, now: now)) {
                    helioLog.notice("helio: offering a postponed interrupted workout back")
                    found = RecoveryOffer(workout: recovered, slot: .parked(0))
                    break
                }
                parked.removeFirst()
            }
            if parked.count != before { journal.saveParked(parked) }
        }
        if orphanStop.owed, let session = source(), session.ready { session.sendOwedOrphanStop() }
        if stepStreamFlag.owesOff, let session = source(), session.ready,
           let steps = session as? any StrapWorkoutStepSource { steps.sendOwedStepsOff() }
    }

    /// Take the offer on screen (or put off by the alert's dismissal a moment ago) as answered.
    private func takeOffer() -> RecoveryOffer? {
        let taken = offer
        offer = nil
        recoverable = nil
        return taken
    }

    private func clear(_ slot: RecoverySlot) {
        switch slot {
        case .running: journal.clearRunning()
        case .parked(let index):
            var parked = journal.loadParked()
            if parked.indices.contains(index) { parked.remove(at: index) }
            journal.saveParked(parked)
        }
    }

    /// Save's synchronous half (#296), run from the button itself: takes the offer, queues its readings
    /// for `LocalStore` and drops its journal BEFORE the Health write (a kill mid-write can never offer
    /// or write it twice), and returns the write for `writeRecovered`. nil once it is answered. Its
    /// route lived in memory and is gone, so it is saved without one (as the ring's recovery is).
    func takeRecoveredForSave() -> StrapWorkoutWrite? {
        guard let offer = takeOffer() else { return nil }
        let recovered = offer.workout
        let timeline = SyncDeviceID(rawValue: recovered.timelineRaw)
        let summary = StrapWorkoutSummaryBuilder.summarize(
            sport: recovered.sport, ledger: recovered.ledger, samples: recovered.samples, end: recovered.end,
            distanceMeters: nil, hasRoute: false, profile: profile())
        let counted = StrapWorkoutSummaryBuilder.activeSamples(recovered.samples, ledger: recovered.ledger, end: recovered.end)
        enqueueLanding(counted, timeline: timeline)
        clear(offer.slot)   // before the write: a second offer can never write it twice
        return StrapWorkoutWrite(summary: summary, samples: counted, route: [], timeline: timeline)
    }

    /// Save's async half: one `HKWorkout` over the recovered span, with its readings.
    func writeRecovered(_ write: StrapWorkoutWrite) async -> Bool {
        let saved = await health.save(write)
        helioLog.notice("helio: interrupted workout saved to Health \(saved, privacy: .public)")
        landPendingHeartRate()
        return saved
    }

    /// Save the interrupted workout, both halves.
    @discardableResult
    func saveRecovered() async -> Bool {
        guard let write = takeRecoveredForSave() else { return false }
        return await writeRecovered(write)
    }

    func discardRecovered() {
        guard let offer = takeOffer() else { return }
        clear(offer.slot)
    }

    /// "Not now", and any dismissal of the alert: hidden now, asked again at the next launch. The offer
    /// stays answerable, so a Save or Discard of the same alert that SwiftUI runs after this still wins.
    func postponeRecovered() {
        recoverable = nil
    }

    // MARK: Heart rate into LocalStore

    private func enqueueLanding(_ samples: [HRSample], timeline: SyncDeviceID) {
        guard !samples.isEmpty else { return }
        var batches = journal.loadLanding()
        batches.append(StrapWorkoutLandingBatch(timelineRaw: timeline.rawValue, samples: samples))
        journal.saveLanding(batches)
    }

    /// Store queued workout readings in `LocalStore` (`insertWorkoutHeartRate`: no watermark moves, and
    /// they never reach Health again). Called after End and a recovered Save, and at launch for a
    /// batch a store that wasn't available left behind.
    func landPendingHeartRate() {
        let batches = journal.loadLanding()
        guard !batches.isEmpty, let store = hrStore() else { return }
        var kept: [StrapWorkoutLandingBatch] = []
        for batch in batches {
            do {
                try store.insertWorkoutHeartRate(batch.samples, timeline: SyncDeviceID(rawValue: batch.timelineRaw))
            } catch {
                helioLog.error("helio: storing workout heart rate failed; kept for next time")
                kept.append(batch)
            }
        }
        journal.saveLanding(kept)
    }

    // MARK: Live Activity

    private func pushLiveActivity() async {
        guard let liveActivity, let ledger else { return }
        let now = clock()
        let counted = StrapWorkoutSummaryBuilder.activeSamples(samples, ledger: ledger, end: now)
        let avg = counted.isEmpty ? nil : counted.reduce(0) { $0 + $1.bpm } / counted.count
        let kcal = avg.map {
            Calories.workoutActiveKcal(avgHR: $0, durationSeconds: ledger.activeSeconds(until: now),
                                       profile: profileSnapshot ?? profile())
        } ?? 0
        let active = ledger.activeSeconds(until: now)
        // The Lock Screen clock shows running time: counted up from `now − active` while running,
        // standing still while paused. Distance / pace / zone are the same figures the screen shows
        // (#283), built by the shared constructor the ring uses.
        let distance = selectedSport.isOutdoor && !location.route.isEmpty ? location.distanceMeters : nil
        await liveActivity.update(WorkoutLiveActivityController.state(
            activeSeconds: active, activeKcal: Int(kcal.rounded()),
            bpm: currentHR, hrIsStale: currentHRIsStale,
            paused: isPaused, everPaused: true,
            distanceMeters: distance,
            currentPaceSecPerKm: paceTracker.currentSecPerKm(now: now),
            avgPaceSecPerKm: WorkoutPace.averageSecPerKm(distanceMeters: distance, activeSeconds: active),
            hrZone: WorkoutPace.liveZone(bpm: currentHR, isStale: currentHRIsStale, maxHR: maxHR),
            now: now))
    }
}

/// The strap's "Interrupted workout" alert, button by button (#296). SwiftUI runs a button's action and
/// the alert's `isPresented` setter in either order, so each entry point here is synchronous and the
/// answer can't depend on that order: Save takes the workout before its Task is even created, and a
/// dismissal only hides the alert. The ring's alert (`ContentView.saveRecoverableWorkout`) captures its
/// workout synchronously the same way.
@MainActor
struct StrapRecoveryAlert {
    let recorder: StrapWorkoutRecorder
    /// After a Save that reached Health.
    let onSaved: @MainActor () -> Void

    var isPresented: Bool { recorder.recoverable != nil }

    /// The `isPresented` setter.
    func setPresented(_ presented: Bool) {
        if !presented { recorder.postponeRecovered() }
    }

    /// The Health write runs in the returned Task (nil when the workout was already answered).
    @discardableResult
    func save() -> Task<Void, Never>? {
        guard let write = recorder.takeRecoveredForSave() else { return nil }
        let recorder = recorder
        let onSaved = onSaved
        return Task { @MainActor in
            if await recorder.writeRecovered(write) { onSaved() }
        }
    }

    func discard() { recorder.discardRecovered() }

    func notNow() { recorder.postponeRecovered() }
}
