// WorkoutSessionManager.swift — App-side workout session: HR collection via the ring's
// existing live-HR poll path, GPS route capture (phone CoreLocation), and HKWorkout write.
//
// RISK — Issue #45 (live HR flakiness):
//   The 0x95→0x15 live-HR path has no background refresh; on-demand polling often misses
//   updates. A long workout session is the worst-case scenario for this flakiness. This
//   manager tolerates HR dropouts gracefully: only ACTUAL decoded readings are recorded;
//   gaps are never filled by interpolation or fabrication. A best-effort note is surfaced
//   to the user in the UI. See #45 for the root cause and expected follow-up.
//
// GPS: phone-side only (CoreLocation). The ring has no GPS. Route capture is opt-in —
//   only for outdoor sport types — and gracefully degrades when location permission is
//   denied (workout still proceeds without a route).
//
// HealthKit: writes HKWorkout + HR quantity samples + HKWorkoutRoute (outdoor only).
//   Sport type is mapped to HKWorkoutActivityType; active calories are labeled ESTIMATE.

import Foundation
import CoreLocation
import HealthKit
import OpenCircuitKit
import Observation
import UIKit

// MARK: - Workout state

enum WorkoutRecordingState: Equatable {
    case idle
    case starting   // brief: monitoring starting, drain in progress
    case active
    case finishing  // writing to HealthKit
    case finished(summary: WorkoutSummary)
    case error(String)

    static func == (lhs: WorkoutRecordingState, rhs: WorkoutRecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.starting, .starting), (.active, .active), (.finishing, .finishing): return true
        case (.finished(let a), .finished(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Manager

@Observable
@MainActor
final class WorkoutSessionManager: NSObject {

    // MARK: Public state (observed by WorkoutView)

    private(set) var recordingState: WorkoutRecordingState = .idle
    var selectedSport: WorkoutSportType = .runningOutdoor

    /// Live elapsed seconds since the session started (updated by the timer loop).
    private(set) var elapsedSeconds: TimeInterval = 0
    /// Live HR mirror — the last GENUINELY FRESH lock recorded (not the ring's held latch; see
    /// #45). Persists between locks so the UI doesn't flicker; `currentHRIsStale` marks it old.
    private(set) var currentHR: Int?
    /// Capture time of `currentHR` (the lock's true time, not "now"). Drives staleness.
    private(set) var currentHRAt: Date?
    /// True when the displayed HR is older than ~3 missed polls — the UI shows "measuring…"
    /// instead of implying the frozen number is a live reading. Honest gap, never fabricated.
    var currentHRIsStale: Bool {
        guard let at = currentHRAt else { return true }
        return Date().timeIntervalSince(at) > 8
    }
    /// Running zone breakdown updated as HR samples arrive.
    private(set) var liveZoneBreakdown = WorkoutZoneBreakdown()
    /// GPS distance in meters (phone CoreLocation). nil until first location fix.
    private(set) var distanceMeters: Double?
    /// Whether GPS is currently active for this session.
    private(set) var gpsActive = false
    /// Location authorization status — surfaced so the UI can explain a denied state.
    private(set) var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    /// True when the user opted into indoor keep-alive but location permission isn't granted — so
    /// this indoor workout will STOP recording once the screen locks. Surfaced in the workout UI so
    /// the opt-in doesn't fail silently (the keep-alive needs location to hold the app alive).
    private(set) var keepAliveUnavailable = false
    /// Count of HR samples captured so far (helps UI surface "good / sparse data").
    private(set) var hrSampleCount: Int = 0

    // MARK: Private

    private var aggregator: WorkoutSessionAggregator?
    private var sessionStart: Date?

    /// Drives the workout Live Activity (Lock Screen + Dynamic Island: time / calories / BPM). Owns
    /// all ActivityKit calls so this manager stays a plain state machine. No-op when the user has
    /// Live Activities disabled — the workout is unaffected. See WorkoutLiveActivityController.
    private let liveActivity = WorkoutLiveActivityController()
    /// Profile captured at session start (weight/age/sex) for the live Keytel calorie estimate. The
    /// user's profile can't change mid-workout, so snapshotting it avoids re-reading UserDefaults on
    /// every Live Activity update.
    private var profileSnapshot: UserProfile?

    /// Capture time of the last HR sample we actually recorded — the dedupe key that stops a held
    /// latch from being re-recorded every poll (the "stuck at 98" climbing-counter bug, #45).
    private var lastRecordedHRAt: Date?

    private var hrPollTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    /// CoreLocation manager for outdoor GPS route capture (or the indoor keep-alive session).
    private var locationManager: CLLocationManager?
    /// Accumulated route locations (outdoor `.route` sessions only — never the keep-alive).
    private var routeLocations: [CLLocation] = []
    private var lastLocation: CLLocation?

    /// Why a location session is running this workout. `.route`: outdoor — store fixes for the
    /// HKWorkoutRoute + GPS distance. `.keepAlive`: indoor — run coarse location purely to keep the
    /// app alive while the phone is locked so HR keeps recording; fixes are NEVER stored. nil when
    /// no location session is running (indoor with the toggle off, or permission denied).
    private enum LocationPurpose { case route, keepAlive }
    private var locationPurpose: LocationPurpose?

    /// Opt-in (Settings ▸ Workouts): keep recording during INDOOR workouts while the screen is
    /// locked by running a coarse location session purely to stay alive — the only sanctioned iOS
    /// keep-alive for a request/response BLE device with no GPS. Off by default: costs battery and
    /// shows the blue location indicator. Shared key with `UserProfileSettingsView`.
    static let indoorKeepAliveEnabledKey = "workout.indoorKeepAlive"

    // MARK: - Durable "workout in progress" flag (T6)

    /// UserDefaults key for the durable "a workout is in progress" flag. `nonisolated` so the
    /// nonisolated accessors below (and ContentView's launch/foreground paths) can read it without
    /// hopping to the main actor.
    nonisolated static let workoutInProgressKey = "workout.inProgress"

    /// True iff a workout was started and has not yet cleanly ended. PERSISTED (UserDefaults) so a
    /// crash/relaunch can tell a workout was underway when the process died. ContentView reads this
    /// to SUPPRESS the once-a-morning whole-night backlog drain while a workout owns (or should own)
    /// the BLE link — that drain takes the link (`syncTask != nil`) and would starve a just-
    /// (re)started workout of native `0x4e` HR (T6). In-memory `RingSession.workoutHolding` can't
    /// cover a crash-relaunch (a fresh session reads it false); this durable flag does. Nonisolated:
    /// a plain global flag over thread-safe UserDefaults, read from ContentView's launch/foreground
    /// paths. The crash-orphan case (flag left set with no live workout) is reconciled at launch by
    /// ContentView (clear + re-arm the deferred drain) — see `clearWorkoutInProgressFlag`.
    nonisolated static var isWorkoutInProgressPersisted: Bool {
        UserDefaults.standard.bool(forKey: workoutInProgressKey)
    }

    /// Set/clear the durable flag. `true` on workout start; `false` on EVERY end path
    /// (normal stop, error, cancel, reset) and on the crash-orphan cleanup at launch.
    nonisolated static func setWorkoutInProgressPersisted(_ inProgress: Bool) {
        UserDefaults.standard.set(inProgress, forKey: workoutInProgressKey)
    }

    /// Convenience for the end paths and the launch-time orphan cleanup.
    nonisolated static func clearWorkoutInProgressFlag() {
        setWorkoutInProgressPersisted(false)
    }

    private weak var session: RingSession?
    /// Where to persist this workout's continuous HR samples so they count toward today's
    /// Activity-minutes goal and Trends/exports — the same store the ring's history sync writes
    /// to. Without this, a workout's HR only ever reached HealthKit via its own HKWorkoutBuilder
    /// write; LocalStore (and anything reading from it, like GoalsCardView) never saw it, so a
    /// fully-tracked workout with clearly elevated HR throughout still counted 0 Activity minutes.
    private var store: LocalStore?

    // MARK: HealthKit

    private let hkStore = HKHealthStore()

    /// Mapping from WorkoutSportType to HKWorkoutActivityType.
    static func hkActivityType(for sport: WorkoutSportType) -> HKWorkoutActivityType {
        switch sport {
        case .walkingOutdoor:    return .walking
        case .runningOutdoor:    return .running
        case .runningIndoor:     return .running
        case .cyclingOutdoor:    return .cycling
        case .cyclingIndoor:     return .cycling
        case .rowing:            return .rowing
        case .hiking:            return .hiking
        case .strengthTraining:  return .traditionalStrengthTraining
        case .yoga:              return .yoga
        case .other:             return .other
        }
    }

    // MARK: - Start / Stop

    /// Begin a workout session. Drives the ring's existing live-HR poll (0x95→0x15) via
    /// `RingSession.startMonitoring`. Does NOT send any new BLE write command to the ring
    /// beyond what the existing live-HR path already uses.
    func start(session: RingSession, store: LocalStore? = nil) {
        guard case .idle = recordingState else { return }
        self.session = session
        self.store = store
        let start = Date()
        sessionStart = start
        let profile = HealthKitWriter.storedUserProfile()
        profileSnapshot = profile
        aggregator = WorkoutSessionAggregator(startDate: start, userAge: profile.age)
        elapsedSeconds = 0
        currentHR = nil
        currentHRAt = nil
        lastRecordedHRAt = nil
        liveZoneBreakdown = WorkoutZoneBreakdown()
        distanceMeters = nil
        gpsActive = false
        keepAliveUnavailable = false
        hrSampleCount = 0
        routeLocations = []
        lastLocation = nil

        recordingState = .starting

        // T6: mark a workout in progress DURABLY (survives a crash-relaunch). ContentView reads this
        // to suppress the relaunch/foreground whole-night backlog drain while the workout owns the
        // link, so the just-started session gets the clean native `0x4e` stream instead of being
        // starved by a drain that holds `syncTask`. Cleared on every end path (stop/cancel/reset)
        // and reconciled at launch if the process was killed mid-workout.
        Self.setWorkoutInProgressPersisted(true)

        // Enter the ring's NATIVE sport mode for this workout (#90): SportStart → the ring streams
        // `0x4e` HR+steps frames (~10 s) which RingSession routes into `liveHR`/`liveHRAt` (picked up
        // by `collectHRSnapshot` below) and sums into `sportSteps`. This is the ring's dedicated
        // workout HR path (and the only source of per-workout step counts), replacing the generic
        // live-HR poll for the session's duration.
        session.beginSportSession(typeByte: selectedSport.firmwareByte)

        // Keep the screen awake while a workout is foregrounded so it doesn't auto-dim → lock →
        // suspend (which would stall the poll loops). Background tracking is handled by the
        // location session below; this is the foreground-UX half.
        UIApplication.shared.isIdleTimerDisabled = true

        // Begin a location session: outdoor → GPS route + distance; indoor → optional keep-alive so
        // HR keeps recording while the phone is locked (opt-in, since it costs battery). The
        // `location` background mode + continuous updates keep the app alive so the BLE poll loops
        // keep ticking under lock — the only sanctioned keep-alive for our request/response ring.
        if selectedSport.isOutdoor {
            startLocation(purpose: .route)
        } else if UserDefaults.standard.bool(forKey: Self.indoorKeepAliveEnabledKey) {
            startLocation(purpose: .keepAlive)
        }

        // HR collection loop: snapshots session.liveHR every 2 s.
        // #45 NOTE: live HR is best-effort. Gaps are preserved (no gap-filling/interpolation).
        hrPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { break }   // self-terminate if the manager went away
                await MainActor.run { self.collectHRSnapshot() }
            }
        }
        // Elapsed-time ticker (1 s resolution). Also refreshes the Live Activity's calories/BPM on a
        // slower heartbeat (~every 10 s); the elapsed CLOCK self-ticks in the widget via
        // Text(timerInterval:), so it stays live between these updates. Fresh HR readings push their
        // own immediate update from collectHRSnapshot, so BPM never waits a full heartbeat.
        timerTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }   // self-terminate if the manager went away
                self.elapsedSeconds = self.sessionStart.map { Date().timeIntervalSince($0) } ?? self.elapsedSeconds
                tick += 1
                if tick % 10 == 0 { await self.pushLiveActivityUpdate() }
            }
        }

        recordingState = .active

        // Present the Live Activity now that the session is live. Initial state: zeroed metrics, no HR
        // yet (honest — the ring hasn't locked a reading). No-op if Live Activities are disabled.
        liveActivity.start(
            sport: selectedSport,
            startDate: start,
            initial: WorkoutActivityAttributes.ContentState(
                elapsedSeconds: 0, activeKcal: 0, bpm: nil, hrIsStale: true)
        )
    }

    /// Stop the session, write to HealthKit, transition to `.finished`.
    func stop() async {
        // Allow stopping from both .starting and .active
        switch recordingState {
        case .starting, .active: break
        default: return
        }
        recordingState = .finishing

        // T6: clear the durable flag FIRST — before `endSportSession()` below flips
        // `session.workoutHolding` false (which fires ContentView's re-arm). Clearing here covers
        // BOTH the normal completion below AND the `guard let agg` error-return, so no end path can
        // leave the flag set and suppress the morning drain forever (#119 lane).
        Self.setWorkoutInProgressPersisted(false)

        hrPollTask?.cancel(); hrPollTask = nil
        timerTask?.cancel(); timerTask = nil

        // End the ring's native sport mode (SportStop) and capture the ring-counted step total (#90).
        // Flipping `session.workoutHolding` false here is what re-arms the T6-suppressed drain
        // (ContentView observes it) so the deferred morning night still drains after the workout.
        let sportSteps = session?.endSportSession() ?? 0
        session = nil

        // Stop the location session (route or keep-alive) and let the screen sleep again.
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationPurpose = nil
        gpsActive = false
        UIApplication.shared.isIdleTimerDisabled = false

        let endDate = Date()
        let profile = HealthKitWriter.storedUserProfile()

        guard let agg = aggregator else {
            recordingState = .error("No session data")
            return
        }

        // The workout's HR is whatever it captured live — the native `0x4e` sport stream (continuous)
        // or the `0x95` fallback poll. No stop-time history drain: native sport mode (#90, enter from
        // synced-idle) now carries continuous HR directly, so the old `0x4c` backfill was empty when
        // sport streamed AND a multi-second "saving…" stall when it fell back — removed.
        let hasRoute = !routeLocations.isEmpty && selectedSport.isOutdoor
        let summary = agg.finalize(
            sport: selectedSport,
            endDate: endDate,
            distanceMeters: hasRoute ? distanceMeters : nil,
            hasRoute: hasRoute,
            profile: profile,
            steps: sportSteps > 0 ? sportSteps : nil
        )

        // Dismiss the Live Activity now (before the slower HealthKit write) so it clears as the
        // summary screen appears. Publish a final coherent state from the finalized summary.
        await liveActivity.end(final: WorkoutActivityAttributes.ContentState(
            elapsedSeconds: summary.durationSeconds,
            activeKcal: Int((summary.estimatedActiveKcal ?? 0).rounded()),
            bpm: summary.avgHR,
            hrIsStale: true))

        // Write to HealthKit (best-effort; gracefully silent on failure).
        await writeWorkout(summary: summary,
                           hrSamples: agg.collectedSamples,
                           routeLocations: hasRoute ? routeLocations : [])

        // Persist this workout's continuous HR into LocalStore — same store the ring's history
        // sync writes to. These samples carry REAL start/end spans (unlike the zero-duration point
        // samples live-monitoring/history-sync persist elsewhere), so GoalsCardView's
        // ExerciseMinutes estimate can credit them directly without needing two elevated point
        // samples within one epoch of each other. `ingest` is cursor-gated, so re-running a workout
        // (or this code path firing twice) can't double-count.
        //
        // ORDERING (double-count guard): this ingest MUST run AFTER `writeWorkout` returns — i.e.
        // after the workout's active-energy credit is banked via `recordWorkoutActiveKcal` — and in
        // this suspension-free stretch. `endWorkoutHR()` above flipped `monitoring` false, which
        // fires ContentView's `flushHealth()`. That flush computes the day's active-energy delta
        // from LocalStore HR. If we ingested the workout HR BEFORE the credit was banked, a flush
        // could observe the workout HR with `workoutActiveKcalCredited == 0`, write the workout's
        // TRIMP kcal as the daily active-energy delta AND let the workout's own `activeEnergyBurned`
        // sample land too — a permanent, unretractable double-count. Ingesting only now guarantees
        // any flush that sees the workout HR also sees the banked credit and nets it out.
        //
        // The guard holds PER CHUNK. We split the ingest into small LOSSLESS sub-batches below —
        // each `store.ingest(...)` is a single `context.save()`, so a one-shot ingest of the whole
        // workout's HR invalidated EVERY `@Query[StoredSample]` (Calories/Goals/Vitals cards) at
        // once and the dashboard `List` diffed all of it synchronously on the main thread — >10 s →
        // the FRONTBOARD `0x8BADF00D` scene-update-watchdog SIGKILL a user hit when backgrounding
        // right after a long workout summary. Chunking makes each save a SMALL @Query invalidation
        // (a small List scene-update), and `await Task.yield()` hands the main actor back between
        // saves so the diffs spread across runloop turns instead of one giant blocking update.
        // Every chunk still runs AFTER the banked active-energy credit, so a `flushHealth()` that
        // lands between chunks still nets out exactly as the single-shot ingest did.
        if let store {
            // Sort ascending by `start` BEFORE chunking so the forward-only SyncCursor
            // (`selectNew` keeps `start > watermark`, strictly) advances monotonically and never
            // discards a later chunk. The chunks are disjoint and together cover EVERY sample, and
            // each boundary is extended to swallow any equal-`start` run at its tail (see below), so
            // the total StoredSample rows are identical to the old single `store.ingest(toIngest)` —
            // lossless, nothing dropped or deduped away.
            let sorted = agg.collectedSamples.sorted { $0.start < $1.start }
            let toIngest = sorted.map {
                QuantitySample(kind: .heartRate, start: $0.start, end: $0.end, value: Double($0.bpm))
            }
            let chunkSize = 64
            var i = 0
            while i < toIngest.count {
                var end = min(i + chunkSize, toIngest.count)
                // Never split an equal-`start` run across a boundary: once the head sample advances
                // the cursor watermark to that instant, `selectNew`'s strict `start > watermark`
                // would drop the tail sample in the next chunk. Extend to swallow the whole run so
                // chunking stays byte-for-byte lossless vs. the single-batch ingest.
                while end < toIngest.count && toIngest[end].start == toIngest[end - 1].start {
                    end += 1
                }
                _ = try? store.ingest(Array(toIngest[i..<end]))
                i = end
                // Hand the main actor back between saves: each small @Query invalidation gets its
                // own runloop turn, so no single dashboard-List scene-update exceeds the watchdog
                // budget. (Escalate to `try? await Task.sleep(for: .milliseconds(16))` if on-device
                // background throttling makes a bare yield insufficient.)
                await Task.yield()
            }
        }

        recordingState = .finished(summary: summary)
    }

    /// Discard the session without writing to HealthKit.
    func cancel() {
        // T6: clear the durable flag on the cancel end path too (before `endSportSession()` below
        // releases `workoutHolding` and re-arms the deferred drain).
        Self.setWorkoutInProgressPersisted(false)
        hrPollTask?.cancel(); hrPollTask = nil
        timerTask?.cancel(); timerTask = nil
        // Tear down the Live Activity too — a discarded session should leave nothing on the Lock
        // Screen. Fire-and-forget (cancel() is synchronous); end() no-ops if none is presented.
        let finalState = currentLiveActivityState()
        Task { await liveActivity.end(final: finalState) }
        session?.endSportSession()   // SportStop — discarded session, nothing persisted
        session = nil
        store = nil   // discarded session — nothing to persist
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationPurpose = nil
        UIApplication.shared.isIdleTimerDisabled = false
        recordingState = .idle
    }

    func reset() {
        // T6: belt-and-suspenders — `reset()` runs from the summary "Done" / error "Dismiss"
        // buttons (after `stop()` already cleared it), but clear again so no path can leave it set.
        Self.setWorkoutInProgressPersisted(false)
        recordingState = .idle
        elapsedSeconds = 0
        currentHR = nil
    }

    // Belt-and-suspenders: the poll/timer loops capture `self` weakly and `break` as soon as
    // the manager is deallocated (the `guard let self else { break }` in `start`), so they can
    // never outlive the manager even without an explicit cancel. Ring teardown
    // (`stopLiveMonitoring`) is handled by `stop()` via the view's `.onDisappear`. (#75)

    // MARK: - HR collection

    /// Snapshot the ring's live HR — but record a sample ONLY for a genuinely fresh lock, never
    /// the value the ring holds in `liveHR` between polls. `RingSession.liveHR` is a latch that is
    /// never cleared while monitoring, so the old "record it every poll" logic re-emitted one early
    /// still reading (e.g. 98) forever — freezing the UI number while the reading counter climbed
    /// and writing a flat, fabricated HR line to HealthKit (the #45 "stuck at 98" bug).
    ///
    /// `WorkoutHRGate.shouldRecord` admits only a lock that is fresh (captured recently), in-session
    /// (at/after the cycle start, so a pre-workout resting lock can't seed it) and not-yet-recorded
    /// (its capture time advanced). On any miss we record nothing — the gap is preserved, never
    /// interpolated. The displayed `currentHR` is kept (UI marks it stale via `currentHRIsStale`)
    /// so it doesn't flicker; what we never do is COUNT or PERSIST a held value as a new reading.
    private func collectHRSnapshot() {
        // `workoutHRActive` (not `sportSessionActive`): the workout records HR from EITHER the native
        // `0x4e` sport stream OR the live-HR-poll fallback RingSession switches to when the ring never
        // streams `0x4e`. Gating on `sportSessionActive` would drop every reading after that fallback.
        guard let session, session.workoutHRActive else { return }
        guard WorkoutHRGate.shouldRecord(liveHRAt: session.liveHRAt,
                                         sessionStart: sessionStart,
                                         lastRecordedAt: lastRecordedHRAt,
                                         now: Date()),
              let bpm = session.liveHR, LiveHR.validBPM.contains(bpm),
              let at = session.liveHRAt else {
            // No fresh lock this tick — gap preserved (#45). Keep currentHR; the UI ages it out.
            return
        }
        lastRecordedHRAt = at
        // Attribute the ~2 s window leading up to the lock's true capture time (not "now").
        let sample = HRSample(bpm: bpm, start: at.addingTimeInterval(-2), end: at)
        aggregator?.add(sample: sample)
        hrSampleCount += 1
        currentHR = bpm
        currentHRAt = at

        // Update live zone breakdown. Held (step-function) attribution so the live totals track the
        // real elapsed time each reading covers (~10 s cadence), not just the stamped ~2 s windows.
        if let agg = aggregator {
            let maxHR = max(220 - HealthKitWriter.storedUserProfile().age, 1)
            liveZoneBreakdown = HRZoneClassifier.timeInZonesHeld(
                hrSamples: agg.collectedSamples, maxHR: maxHR, sessionEnd: Date())
        }

        // A genuinely fresh reading is a meaningful change — refresh the Live Activity's BPM (and the
        // running calorie estimate) immediately, rather than waiting for the ~10 s timer heartbeat.
        Task { await pushLiveActivityUpdate() }
    }

    // MARK: - Live Activity feed

    /// Build the Live Activity's dynamic state from the current live fields: self-reported elapsed
    /// seconds (fallback for surfaces that can't self-tick), the running Keytel calorie ESTIMATE
    /// (HR-only; the distance fallback is a finalize-time concern), the last GENUINE BPM, and its
    /// staleness. Never fabricates HR — `currentHR`/`currentHRIsStale` carry the #45 honesty through.
    private func currentLiveActivityState() -> WorkoutActivityAttributes.ContentState {
        let kcal = aggregator?.liveActiveKcal(
            profile: profileSnapshot ?? HealthKitWriter.storedUserProfile(),
            asOf: Date()) ?? 0
        return WorkoutActivityAttributes.ContentState(
            elapsedSeconds: elapsedSeconds,
            activeKcal: Int(kcal.rounded()),
            bpm: currentHR,
            hrIsStale: currentHRIsStale
        )
    }

    /// Push the current state to the Live Activity (no-op when none is presented).
    private func pushLiveActivityUpdate() async {
        await liveActivity.update(currentLiveActivityState())
    }

    // MARK: - GPS / CoreLocation

    private func startLocation(purpose: LocationPurpose) {
        locationPurpose = purpose
        let mgr = CLLocationManager()
        mgr.delegate = self
        locationManager = mgr
        locationAuthStatus = mgr.authorizationStatus
        switch mgr.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            configureAndStart(mgr, purpose: purpose)
        case .notDetermined:
            // Configured in didChangeAuthorization once the user responds to the prompt.
            mgr.requestWhenInUseAuthorization()
        default:
            // Denied. Outdoor: proceed without a route (graceful). Indoor keep-alive: we can't stay
            // alive in the background without it, so HR records only while the app is foreground —
            // flag it so the UI can tell the user instead of failing silently.
            gpsActive = false
            if purpose == .keepAlive { keepAliveUnavailable = true }
        }
    }

    /// Apply the background-capable configuration for `purpose` and begin updates. Called only once
    /// authorization is WhenInUse/Always (from `startLocation` or `didChangeAuthorization`).
    ///
    /// `allowsBackgroundLocationUpdates = true` (paired with the `location` UIBackgroundMode) is
    /// what keeps a foreground-started workout running after the phone locks — without it the BLE
    /// poll loops freeze on suspend. `pausesLocationUpdatesAutomatically = false` is critical:
    /// otherwise iOS auto-pauses at a rest/stoplight, the app suspends, and HR polling dies
    /// mid-workout. The blue indicator is shown honestly while we hold location.
    private func configureAndStart(_ mgr: CLLocationManager, purpose: LocationPurpose) {
        switch purpose {
        case .route:
            mgr.desiredAccuracy = kCLLocationAccuracyBest
            mgr.distanceFilter = 5                                  // update every 5 m
        case .keepAlive:
            mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters  // coarse — save battery; fixes discarded
            mgr.distanceFilter = kCLDistanceFilterNone
        }
        mgr.activityType = .fitness
        mgr.pausesLocationUpdatesAutomatically = false
        mgr.allowsBackgroundLocationUpdates = true
        mgr.showsBackgroundLocationIndicator = true
        mgr.startUpdatingLocation()
        gpsActive = true
        keepAliveUnavailable = false   // location granted — keep-alive can hold the app alive
    }

    // MARK: - HealthKit write

    /// Write the completed workout to Apple Health. Best-effort: silent on auth/API failures.
    /// Writes HKWorkout, HR quantity samples, and optional HKWorkoutRoute.
    private func writeWorkout(
        summary: WorkoutSummary,
        hrSamples: [HRSample],
        routeLocations: [CLLocation]
    ) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let activityType = Self.hkActivityType(for: summary.sport)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        if summary.sport.isOutdoor { configuration.locationType = .outdoor }
        else { configuration.locationType = .indoor }

        let builder = HKWorkoutBuilder(
            healthStore: hkStore,
            configuration: configuration,
            device: .local()
        )

        // Begin collection
        do {
            try await builder.beginCollection(at: summary.startDate)
        } catch {
            return   // HealthKit auth not granted or unavailable
        }

        // Add HR samples during the workout window
        if !hrSamples.isEmpty {
            let hrType = HKQuantityType(.heartRate)
            let hkHRSamples: [HKQuantitySample] = hrSamples.map { s in
                let q = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()),
                                   doubleValue: Double(s.bpm))
                return HKQuantitySample(
                    type: hrType, quantity: q, start: s.start, end: s.end,
                    metadata: [HKMetadataKeyWasUserEntered: false])
            }
            try? await builder.addSamples(hkHRSamples)
        }

        // Add the ring-counted step total for the workout window (#90 native sport-mode `0x4e`
        // stream — the ring reports real per-interval steps, unlike the generic live-HR path).
        // Best-effort: silent if step-count share auth isn't granted.
        if let steps = summary.steps, steps > 0 {
            let stepType = HKQuantityType(.stepCount)
            let q = HKQuantity(unit: .count(), doubleValue: Double(steps))
            let stepSample = HKQuantitySample(
                type: stepType, quantity: q,
                start: summary.startDate, end: summary.endDate,
                metadata: [HKMetadataKeyWasUserEntered: false])
            try? await builder.addSamples([stepSample])
        }

        // Add active energy (ESTIMATE — HR-TRIMP or, when HR didn't lock, a distance estimate).
        // The daily active-energy estimate nets this workout's committed kcal out below, so
        // Health's Move total does not double-count the same workout energy.
        //
        // Track whether the sample actually landed: the daily estimate is netted by the credit
        // `recordWorkoutActiveKcal` banks AFTER `finishWorkout`. If we banked that credit while the
        // energy sample silently failed to write (the old unconditional `try?`), the workout's kcal
        // would be subtracted from the daily estimate WITHOUT any workout sample in Health — a
        // permanent under-count. So credit only when the sample was accepted by the builder.
        var energySampleWritten = false
        if let kcal = summary.estimatedActiveKcal, kcal > 0 {
            let energyType = HKQuantityType(.activeEnergyBurned)
            let q = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
            let energySample = HKQuantitySample(
                type: energyType, quantity: q,
                start: summary.startDate, end: summary.endDate,
                metadata: [HealthKitWriter.activeEnergyEstimateMetadataKey: true,
                           HKMetadataKeyWasUserEntered: false])
            do {
                try await builder.addSamples([energySample])
                energySampleWritten = true
            } catch {
                // Energy sample failed to add — leave `energySampleWritten` false so the credit
                // below is skipped and the daily estimate isn't netted for energy never written.
            }
        }

        // Add distance (GPS — only for outdoor with route). Pick the correct HK type by sport:
        // cycling → .distanceCycling; walking/running/hiking → .distanceWalkingRunning. Writing
        // a cycling ride to the walk/run type would pollute that total (and never show as cycling
        // distance). Defer the daily-estimate netting record until the workout actually COMMITS.
        var walkRunDistanceToCredit = 0.0
        if let dist = summary.distanceMeters, dist > 0, summary.hasRoute {
            let isCycling = summary.sport == .cyclingOutdoor
            let distType = HKQuantityType(isCycling ? .distanceCycling : .distanceWalkingRunning)
            let q = HKQuantity(unit: .meter(), doubleValue: dist)
            let distSample = HKQuantitySample(
                type: distType, quantity: q,
                start: summary.startDate, end: summary.endDate,
                metadata: [HKMetadataKeyWasUserEntered: false])
            try? await builder.addSamples([distSample])
            if !isCycling { walkRunDistanceToCredit = dist }
        }

        // End collection and finish workout
        do {
            try await builder.endCollection(at: summary.endDate)
        } catch { return }

        let workout: HKWorkout
        do {
            guard let finished = try await builder.finishWorkout() else { return }
            workout = finished
        } catch { return }

        // Workout is now COMMITTED to Health — only NOW record its foot-based GPS distance so the
        // daily steps×stride distance + active-energy estimates net out exactly what was written
        // (recording before finishWorkout would phantom-net a workout that failed to save, leaving
        // Health permanently under-counted for the day).
        if walkRunDistanceToCredit > 0 {
            HealthKitWriter.recordWorkoutWalkRunDistance(walkRunDistanceToCredit)
        }
        // Credit the daily estimate ONLY when the active-energy sample actually landed in Health
        // (see `energySampleWritten` above) — otherwise netting would subtract energy Health never
        // received, permanently under-counting the day.
        if energySampleWritten, let kcal = summary.estimatedActiveKcal, kcal > 0 {
            HealthKitWriter.recordWorkoutActiveKcal(kcal, day: summary.endDate)
        }

        // Write GPS route if available
        if !routeLocations.isEmpty, summary.hasRoute {
            await writeRoute(locations: routeLocations, to: workout)
        }
    }

    private func writeRoute(locations: [CLLocation], to workout: HKWorkout) async {
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: hkStore, device: nil)
        do {
            try await routeBuilder.insertRouteData(locations)
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
        } catch {
            // Route write failed — workout and HR samples already saved; route is optional.
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WorkoutSessionManager: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.locationAuthStatus = manager.authorizationStatus
            if (manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways),
               let purpose = self.locationPurpose {
                self.configureAndStart(manager, purpose: purpose)
            } else {
                self.gpsActive = false
                if self.locationPurpose == .keepAlive { self.keepAliveUnavailable = true }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Indoor keep-alive runs location ONLY to keep the app alive — never store its fixes
            // (no route, no distance). Only an outdoor `.route` session contributes to the map.
            guard self.locationPurpose == .route else { return }
            for loc in locations {
                // Reject stale/cached fixes: CoreLocation delivers a cached last-known location as
                // the first callback after startUpdatingLocation() — and again on each background
                // resume — which would add a bogus distance jump from a previous location. (#75)
                guard abs(loc.timestamp.timeIntervalSinceNow) < 10 else { continue }
                // Reject low-accuracy fixes (> 50 m horizontal accuracy).
                guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 50 else { continue }
                if let prev = self.lastLocation {
                    let delta = loc.distance(from: prev)
                    self.distanceMeters = (self.distanceMeters ?? 0) + delta
                }
                self.lastLocation = loc
                self.routeLocations.append(loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // GPS error — graceful, location data is optional.
        Task { @MainActor [weak self] in
            self?.gpsActive = false
        }
    }
}
