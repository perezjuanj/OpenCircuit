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
import OpenRingKit
import Observation

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
    /// Live HR mirror (nil when the ring hasn't locked a reading or HR is dropping; see #45).
    private(set) var currentHR: Int?
    /// Running zone breakdown updated as HR samples arrive.
    private(set) var liveZoneBreakdown = WorkoutZoneBreakdown()
    /// GPS distance in meters (phone CoreLocation). nil until first location fix.
    private(set) var distanceMeters: Double?
    /// Whether GPS is currently active for this session.
    private(set) var gpsActive = false
    /// Location authorization status — surfaced so the UI can explain a denied state.
    private(set) var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    /// Count of HR samples captured so far (helps UI surface "good / sparse data").
    private(set) var hrSampleCount: Int = 0

    // MARK: Private

    private var aggregator: WorkoutSessionAggregator?
    private var sessionStart: Date?

    private var hrPollTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    /// CoreLocation manager for outdoor GPS route capture.
    private var locationManager: CLLocationManager?
    /// Accumulated route locations (outdoor sessions only).
    private var routeLocations: [CLLocation] = []
    private var lastLocation: CLLocation?

    private weak var session: RingSession?

    // MARK: HealthKit

    private let hkStore = HKHealthStore()

    /// Mapping from WorkoutSportType to HKWorkoutActivityType.
    static func hkActivityType(for sport: WorkoutSportType) -> HKWorkoutActivityType {
        switch sport {
        case .walkingOutdoor:    return .walking
        case .runningOutdoor:    return .running
        case .cyclingOutdoor:    return .cycling
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
    func start(session: RingSession) {
        guard case .idle = recordingState else { return }
        self.session = session
        let start = Date()
        sessionStart = start
        let age = HealthKitWriter.storedUserProfile().age
        aggregator = WorkoutSessionAggregator(startDate: start, userAge: age)
        elapsedSeconds = 0
        currentHR = nil
        liveZoneBreakdown = WorkoutZoneBreakdown()
        distanceMeters = nil
        gpsActive = false
        hrSampleCount = 0
        routeLocations = []
        lastLocation = nil

        recordingState = .starting

        // Start the ring's live HR polling (existing path — no new BLE commands).
        session.startMonitoring(mode: .hr, userInitiated: false, quickLiveRead: true)

        // Begin GPS if this is an outdoor sport type.
        if selectedSport.isOutdoor { startGPS() }

        // HR collection loop: snapshots session.liveHR every 2 s.
        // #45 NOTE: live HR is best-effort. Gaps are preserved (no gap-filling/interpolation).
        hrPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { break }   // self-terminate if the manager went away
                await MainActor.run { self.collectHRSnapshot() }
            }
        }
        // Elapsed-time ticker (1 s resolution).
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }   // self-terminate if the manager went away
                await MainActor.run {
                    guard let start = self.sessionStart else { return }
                    self.elapsedSeconds = Date().timeIntervalSince(start)
                }
            }
        }

        recordingState = .active
    }

    /// Stop the session, write to HealthKit, transition to `.finished`.
    func stop() async {
        // Allow stopping from both .starting and .active
        switch recordingState {
        case .starting, .active: break
        default: return
        }
        recordingState = .finishing

        hrPollTask?.cancel(); hrPollTask = nil
        timerTask?.cancel(); timerTask = nil

        // Capture any REAL HR the ring already surfaced (e.g. epochs drained during this session)
        // so it can backfill the workout window below. The live poll often can't lock HR while
        // moving (#45); this fills from on-device data when present. Empty stays empty — never
        // interpolated. NOTE: history-stream HR comes only from still/sleep-vitals epochs (active-
        // movement epochs carry no HR field), so for an in-motion walk this is usually a no-op —
        // the durable source for continuous workout HR is the all-day HR stream decode (#99).
        let backfillHR: [HRSample] = (session?.historySamples ?? [])
            .filter { $0.kind == .heartRate }
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }

        // Stop the ring's live monitoring.
        session?.stopLiveMonitoring()
        session = nil

        // Stop GPS.
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        gpsActive = false

        let endDate = Date()
        let profile = HealthKitWriter.storedUserProfile()

        guard let agg = aggregator else {
            recordingState = .error("No session data")
            return
        }

        // Backfill the workout window with any real in-window stored HR before finalizing, so
        // avg/max HR + zones reflect on-device data the live poll missed. No-op (preserved) when
        // the store has nothing for the window. Captured live samples win on a timestamp tie.
        if let start = sessionStart {
            agg.backfill(backfillHR, window: DateInterval(start: start, end: max(endDate, start)))
        }

        let hasRoute = !routeLocations.isEmpty && selectedSport.isOutdoor
        let summary = agg.finalize(
            sport: selectedSport,
            endDate: endDate,
            distanceMeters: hasRoute ? distanceMeters : nil,
            hasRoute: hasRoute,
            profile: profile
        )

        // Write to HealthKit (best-effort; gracefully silent on failure).
        await writeWorkout(summary: summary,
                           hrSamples: agg.collectedSamples,
                           routeLocations: hasRoute ? routeLocations : [])

        recordingState = .finished(summary: summary)
    }

    /// Discard the session without writing to HealthKit.
    func cancel() {
        hrPollTask?.cancel(); hrPollTask = nil
        timerTask?.cancel(); timerTask = nil
        session?.stopLiveMonitoring()
        session = nil
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        recordingState = .idle
    }

    func reset() {
        recordingState = .idle
        elapsedSeconds = 0
        currentHR = nil
    }

    // Belt-and-suspenders: the poll/timer loops capture `self` weakly and `break` as soon as
    // the manager is deallocated (the `guard let self else { break }` in `start`), so they can
    // never outlive the manager even without an explicit cancel. Ring teardown
    // (`stopLiveMonitoring`) is handled by `stop()` via the view's `.onDisappear`. (#75)

    // MARK: - HR collection

    /// Snapshot the current liveHR from the ring session. Only records when monitoring is
    /// active AND the ring has a locked reading (>= LiveHR.minValidBPM). Attributes a 2-s
    /// window to each poll result — the ring holds the last known value between polls, so
    /// this is the best honest approximation of "HR was X for the last 2 s."
    ///
    /// Gaps (liveHR == nil or below minValidBPM) are preserved — we NEVER fabricate or
    /// interpolate values to fill them (ref #45: live HR is best-effort / on-demand).
    private func collectHRSnapshot() {
        guard let session, session.monitoring,
              let bpm = session.liveHR, bpm >= LiveHR.minValidBPM else {
            // No lock — gap preserved, not filled (#45).
            currentHR = nil
            return
        }
        let now = Date()
        let sampleStart = now.addingTimeInterval(-2)
        let sample = HRSample(bpm: bpm, start: sampleStart, end: now)
        aggregator?.add(sample: sample)
        hrSampleCount += 1
        currentHR = bpm

        // Update live zone breakdown.
        if let agg = aggregator {
            let maxHR = max(220 - HealthKitWriter.storedUserProfile().age, 1)
            liveZoneBreakdown = HRZoneClassifier.timeInZones(
                hrSamples: agg.collectedSamples, maxHR: maxHR)
        }
    }

    // MARK: - GPS / CoreLocation

    private func startGPS() {
        let mgr = CLLocationManager()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        mgr.distanceFilter = 5   // update every 5 m
        locationManager = mgr
        locationAuthStatus = mgr.authorizationStatus
        switch mgr.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            mgr.startUpdatingLocation()
            gpsActive = true
        case .notDetermined:
            mgr.requestWhenInUseAuthorization()
        default:
            // Permission denied — workout proceeds without GPS (graceful).
            gpsActive = false
        }
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

        // Add active energy (ESTIMATE — HR-TRIMP or, when HR didn't lock, a distance estimate;
        // labeled in metadata). The daily step/distance active-energy estimate nets this out via
        // the foot-distance recorded below, so it isn't double-counted in Health's Move total.
        if let kcal = summary.estimatedActiveKcal, kcal > 0 {
            let energyType = HKQuantityType(.activeEnergyBurned)
            let q = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
            let energySample = HKQuantitySample(
                type: energyType, quantity: q,
                start: summary.startDate, end: summary.endDate,
                metadata: ["OpenRingConnCaloriesEstimated": true,
                           HKMetadataKeyWasUserEntered: false])
            try? await builder.addSamples([energySample])
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
            if manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways {
                manager.startUpdatingLocation()
                self.gpsActive = true
            } else {
                self.gpsActive = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for loc in locations {
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
