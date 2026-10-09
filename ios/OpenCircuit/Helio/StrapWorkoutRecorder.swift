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

/// One finished strap workout on its way to Apple Health.
struct StrapWorkoutWrite {
    let summary: StrapWorkoutSummary
    /// The readings, each over its own second, inside the running stretches.
    let samples: [HRSample]
    let route: [CLLocation]
    let timeline: SyncDeviceID
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
    /// A workout the previous process was running when it died, offered back (save or discard).
    private(set) var recoverable: RecoveredStrapWorkout?
    /// Where `recoverable` came from, so Save/Discard clear exactly that journal.
    @ObservationIgnored private var recoverableSlot: RecoverySlot?
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
        return running.state == .active || running.state == .finishing
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

    // MARK: Session state

    @ObservationIgnored private weak var attached: (any StrapWorkoutHeartRateSource)?
    @ObservationIgnored private var timeline: SyncDeviceID?
    @ObservationIgnored private var samples: [HRSample] = []
    @ObservationIgnored private var unjournaled: [HRSample] = []
    @ObservationIgnored private var lastRecordedAt: Date?
    @ObservationIgnored private var profileSnapshot: UserProfile?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?

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
                             vo2: StrapVO2MaxLive(store: store))
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
        rrIntervalCount = 0
        // Review-238 N1: an interrupted workout still waiting for the person's answer ("Not now") is set
        // aside, never deleted; the next launch offers it again.
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
        paceTracker.reset()
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
        paceTracker.reset()
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
        guard state == .active, let ledger, LiveHR.validBPM.contains(bpm) else { return }
        currentHR = bpm
        currentHRAt = at
        if let total = attached?.rrIntervalsReceived {
            rrIntervalCount += max(0, total - rrIntervalsRead)
            rrIntervalsRead = total
        }
        guard !ledger.isPaused, at > ledger.start, at > (lastRecordedAt ?? .distantPast) else { return }
        lastRecordedAt = at
        let sample = HRSample(bpm: bpm, start: at.addingTimeInterval(-StrapWorkoutSampleLine.span), end: at)
        samples.append(sample)
        unjournaled.append(sample)
        hrSampleCount += 1
    }

    // MARK: End

    /// End the workout: write one `HKWorkout`, queue its readings for `LocalStore`, release the link.
    func end() async {
        guard state == .active, let ledger, let timeline else { return }
        state = .finishing
        // The hold lasts until this returns, through the Health write (SF-1); released here whatever
        // path leaves the function, so nothing can hold the strap for good.
        defer { if Self.running === self { Self.running = nil } }
        let now = clock()
        // Ended while paused: the workout ends where it stopped running.
        let end = ledger.openPauseStart ?? now
        tickTask?.cancel()
        tickTask = nil
        attached?.stopWorkoutHeartRate()
        attached?.heartRateObserver = nil
        attached = nil
        location.stop()
        if managesIdleTimer { UIApplication.shared.isIdleTimerDisabled = false }

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
        // (`StrapWorkoutHealthExclusions`).
        enqueueLanding(counted, timeline: timeline)
        journal.clearRunning()

        await liveActivity?.end(final: WorkoutActivityAttributes.ContentState(
            elapsedSeconds: summary.activeSeconds,
            activeKcal: Int((summary.summary.estimatedActiveKcal ?? 0).rounded()),
            bpm: summary.summary.avgHR, hrIsStale: true))

        let saved = await health.save(StrapWorkoutWrite(summary: summary, samples: counted,
                                                         route: hasRoute ? location.route : [], timeline: timeline))
        helioLog.notice("helio: workout ended, \(counted.count, privacy: .public) reading(s), saved to Health \(saved, privacy: .public)")
        landPendingHeartRate()
        // #232: the VO₂ max estimate for an outdoor run, after the workout's own write so a one-time
        // VO₂ max permission sheet never sits on the "Saving workout…" path (the ring's order).
        vo2MaxOutcome = summary.summary.sport == .runningOutdoor
            ? vo2MaxEstimate(summary, samples: counted, route: hasRoute ? location.route : [])
            : nil
        // Not saved: the workout isn't in Health, so neither is its estimate (the ring's rule).
        vo2MaxHealthStatus = saved ? nil : .failed
        // `.finished` BEFORE the sync, so the hold is already released when `syncHistory` asks:
        // otherwise the workout's own hold would defer the very sync it held back.
        state = .finished(summary, savedToHealth: saved)
        if saved, case .estimate(let estimate)? = vo2MaxOutcome, let vo2 {
            let workoutEnd = summary.summary.endDate
            Task { [weak self] in
                let status = await vo2.save(estimate, workoutEnd: workoutEnd, timeline: timeline)
                // Only into the summary it belongs to (the person may have started another workout).
                guard let self, case .finished(let shown, _) = self.state,
                      shown.summary.startDate == summary.summary.startDate else { return }
                self.vo2MaxHealthStatus = status
            }
        }
        // The sync the workout held back (T6's re-arm, for the strap).
        if let session = source(), session.ready, !session.syncing { session.syncHistory(manual: false) }
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
        rrIntervalCount = 0
    }

    // MARK: Journal

    private func persistJournal(now: Date) {
        guard let ledger, let timeline else { return }
        flushReadings()
        journal.saveJournal(StrapWorkoutJournal(sport: selectedSport, ledger: ledger, lastAliveAt: now,
                                                timelineRaw: timeline.rawValue,
                                                distanceMeters: location.distanceMeters))
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
        if let running = journal.loadJournal() {
            // Review-238 SF2: whatever the answer (Save, Discard, Not now, or a refusal below), the dead
            // process's stream is owed one `04 00`, sent at the strap's next authenticated `ready`.
            orphanStop.owed = true
            switch tombstones.filter(StrapWorkoutRecovery.decide(journal: running, samples: journal.loadSamples(), now: now)) {
            case .nothingToRecover:
                break
            case .discard(let refusal):
                helioLog.notice("helio: discarding an interrupted workout journal (\(refusal.rawValue, privacy: .public))")
                journal.clearRunning()
            case .offer(let recovered):
                helioLog.notice("helio: offering an interrupted workout back")
                recoverable = recovered
                recoverableSlot = .running
            }
        }
        if recoverable == nil {
            // A workout set aside by a new one's start after "Not now"; one with no defensible span, or one
            // the user has since deleted from the history (#293), is dropped.
            var parked = journal.loadParked()
            let before = parked.count
            while let first = parked.first {
                if case .offer(let recovered) = tombstones.filter(StrapWorkoutRecovery.decide(journal: first.journal, samples: first.samples, now: now)) {
                    helioLog.notice("helio: offering a postponed interrupted workout back")
                    recoverable = recovered
                    recoverableSlot = .parked(0)
                    break
                }
                parked.removeFirst()
            }
            if parked.count != before { journal.saveParked(parked) }
        }
        if orphanStop.owed, let session = source(), session.ready { session.sendOwedOrphanStop() }
    }

    private func clearRecoverableSlot() {
        switch recoverableSlot {
        case .running?: journal.clearRunning()
        case .parked(let index)?:
            var parked = journal.loadParked()
            if parked.indices.contains(index) { parked.remove(at: index) }
            journal.saveParked(parked)
        case nil: break
        }
        recoverableSlot = nil
    }

    /// Save the interrupted workout: one `HKWorkout` over the recovered span, with its readings. Its
    /// route lived in memory and is gone, so it is saved without one (as the ring's recovery is).
    @discardableResult
    func saveRecovered() async -> Bool {
        guard let recovered = recoverable else { return false }
        recoverable = nil
        let timeline = SyncDeviceID(rawValue: recovered.timelineRaw)
        let summary = StrapWorkoutSummaryBuilder.summarize(
            sport: recovered.sport, ledger: recovered.ledger, samples: recovered.samples, end: recovered.end,
            distanceMeters: nil, hasRoute: false, profile: profile())
        let counted = StrapWorkoutSummaryBuilder.activeSamples(recovered.samples, ledger: recovered.ledger, end: recovered.end)
        enqueueLanding(counted, timeline: timeline)
        clearRecoverableSlot()   // before the write: a second offer can never write it twice
        let saved = await health.save(StrapWorkoutWrite(summary: summary, samples: counted, route: [], timeline: timeline))
        helioLog.notice("helio: interrupted workout saved to Health \(saved, privacy: .public)")
        landPendingHeartRate()
        return saved
    }

    func discardRecovered() {
        recoverable = nil
        clearRecoverableSlot()
    }

    /// "Not now": asked again at the next launch.
    func postponeRecovered() {
        recoverable = nil
        recoverableSlot = nil
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
