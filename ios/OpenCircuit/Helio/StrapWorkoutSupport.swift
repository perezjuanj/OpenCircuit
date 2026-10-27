import CoreLocation
import Foundation
import HealthKit
import Observation
import OpenCircuitKit

// The strap workout recorder's production collaborators (#227): Apple Health, the journal files, and
// the phone's location. Each mirrors the ring workout's code in `WorkoutSessionManager`, which is left
// untouched (ring-only users: byte-identical).

// MARK: - Apple Health

/// One `HKWorkout` per strap workout, the way `WorkoutSessionManager.writeWorkout` writes the ring's,
/// with two differences: the strap is named (the existing `HKDevice` attribution, decision 11), and
/// the workout carries its pause/resume events so Health's duration is the running time.
@MainActor
final class StrapWorkoutHealthWriter: StrapWorkoutHealthWriting {
    private let hkStore = HKHealthStore()

    func save(_ write: StrapWorkoutWrite) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let summary = write.summary.summary
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = WorkoutSessionManager.hkActivityType(for: summary.sport)
        configuration.locationType = summary.sport.isOutdoor ? .outdoor : .indoor

        // The strap, through the same resolver every strap sample uses (attribution follows the row).
        // Before the strap has an identity (#222's first-write guard) the workout is the phone's, as
        // the ring's workout always is.
        let strap = HealthKitWriter.wearableDevice(forTimeline: write.timeline, wearable: .shared)
        let builder = HKWorkoutBuilder(healthStore: hkStore, configuration: configuration, device: strap ?? .local())
        do {
            try await builder.beginCollection(at: summary.startDate)
        } catch {
            return false
        }

        let events = write.summary.pauses.flatMap { pause in
            [HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pause.start, duration: 0), metadata: nil),
             HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: pause.end, duration: 0), metadata: nil)]
        }
        if !events.isEmpty { try? await builder.addWorkoutEvents(events) }

        if !write.samples.isEmpty {
            let hrType = HKQuantityType(.heartRate)
            let unit = HKUnit.count().unitDivided(by: .minute())
            let hr = write.samples.map {
                HKQuantitySample(type: hrType, quantity: HKQuantity(unit: unit, doubleValue: Double($0.bpm)),
                                 start: $0.start, end: $0.end, device: strap,
                                 metadata: [HKMetadataKeyWasUserEntered: false])
            }
            try? await builder.addSamples(hr)
        }

        // Energy: an ESTIMATE, labelled as the ring's is. Netted out of the daily estimate only if it
        // actually landed (see the ring's `energySampleWritten`).
        var energySampleWritten = false
        if let kcal = summary.estimatedActiveKcal, kcal > 0 {
            let sample = HKQuantitySample(
                type: HKQuantityType(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                start: summary.startDate, end: summary.endDate, device: strap,
                metadata: [HealthKitWriter.activeEnergyEstimateMetadataKey: true, HKMetadataKeyWasUserEntered: false])
            do {
                try await builder.addSamples([sample])
                energySampleWritten = true
            } catch {}
        }

        // Distance: the phone's GPS (no device: the strap didn't measure it), cycling to its own type.
        var walkRunDistanceToCredit = 0.0
        if let distance = summary.distanceMeters, distance > 0, summary.hasRoute {
            let isCycling = summary.sport == .cyclingOutdoor
            let sample = HKQuantitySample(
                type: HKQuantityType(isCycling ? .distanceCycling : .distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                start: summary.startDate, end: summary.endDate, metadata: [HKMetadataKeyWasUserEntered: false])
            try? await builder.addSamples([sample])
            if !isCycling { walkRunDistanceToCredit = distance }
        }

        do {
            try await builder.endCollection(at: summary.endDate)
        } catch { return false }
        let workout: HKWorkout
        do {
            guard let finished = try await builder.finishWorkout() else { return false }
            workout = finished
        } catch { return false }

        // Committed: only now credit the daily estimates, and only for today (the ring's rule).
        if walkRunDistanceToCredit > 0 { HealthKitWriter.recordWorkoutWalkRunDistance(walkRunDistanceToCredit) }
        if energySampleWritten, let kcal = summary.estimatedActiveKcal, kcal > 0,
           Calendar.current.isDateInToday(summary.endDate) {
            HealthKitWriter.recordWorkoutActiveKcal(kcal, day: summary.endDate)
            HealthKitWriter.recordWorkoutCreditedSpan(start: summary.startDate, end: summary.endDate)
        }
        if !write.route.isEmpty, summary.hasRoute {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: hkStore, device: nil)
            do {
                try await routeBuilder.insertRouteData(write.route)
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            } catch {
                // The route is optional; the workout and its samples are saved.
            }
        }
        return true
    }
}

// MARK: - Heart rate recovery in Apple Health (#337)

/// The recovery readings and Cardio Recovery (decision 82c, 82e), each its own `HKHealthStore.save`,
/// never part of the workout's `HKWorkoutBuilder`. The readings are plain heart-rate samples built by
/// the flush's own `HealthKitWriter.quantitySample` with the strap's `HKDevice` (the resolver every
/// strap sample uses), so they are attributed exactly as other heart-rate writes. Only readings in
/// time the strap owns are written (decision 28; `LocalStore` keeps the same rule for its rows).
@MainActor
final class HeartRateRecoveryHealthWriter: HeartRateRecoveryHealthWriting {
    /// Cardio Recovery. Third-party writable (decision 82: the share probe doesn't throw), and in the
    /// app's one share set (`HealthKitWriter.allTypes`), so an existing install is asked for it once.
    nonisolated static let cardioRecoveryType = HKQuantityType(.heartRateRecoveryOneMinute)
    private let hkStore = HKHealthStore()

    func saveRecoveryHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus {
        guard HKHealthStore.isHealthDataAvailable(), HealthKitWriter().isShareAuthorized else { return .notConnected }
        let log = LocalStore.ownershipLog()
        let device = HealthKitWriter.wearableDevice(forTimeline: timeline, wearable: .shared)
        let hr = samples
            .filter { log.owns(timeline, at: $0.start) }
            .compactMap {
                HealthKitWriter.quantitySample(QuantitySample(kind: .heartRate, start: $0.start, end: $0.end,
                                                              value: Double($0.bpm)), device: device)
            }
        guard !hr.isEmpty else { return .saved }
        do {
            try await hkStore.save(hr)
            return .saved
        } catch {
            helioLog.error("helio: recovery heart rate not saved to Health")
            return .failed
        }
    }

    func saveCardioRecovery(_ bpm: Int, at date: Date, timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus {
        guard HKHealthStore.isHealthDataAvailable(), HealthKitWriter().isShareAuthorized else { return .notConnected }
        // Never asked here: the app's one request asks for it (ContentView's reconcile at the next open).
        switch hkStore.authorizationStatus(for: Self.cardioRecoveryType) {
        case .sharingAuthorized: break
        case .sharingDenied: return .sharingOff
        default: return .notConnected
        }
        let sample = HKQuantitySample(
            type: Self.cardioRecoveryType,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: Double(bpm)),
            start: date, end: date,
            device: HealthKitWriter.wearableDevice(forTimeline: timeline, wearable: .shared),
            metadata: [HKMetadataKeyWasUserEntered: false])
        do {
            try await hkStore.save(sample)
            return .saved
        } catch {
            helioLog.error("helio: Cardio Recovery not saved to Health")
            return .failed
        }
    }
}

// MARK: - Journal files

/// The journal in Application Support/StrapWorkout: the small journal (rewritten on the heartbeat),
/// the readings (appended, one line each), the parked interrupted workouts, and the landing queue.
/// Nothing is created until a strap workout starts, so a ring-only install never gets the folder.
@MainActor
final class StrapWorkoutFileJournal: StrapWorkoutJournalStoring {
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StrapWorkout", isDirectory: true)
    }

    private var journalURL: URL { folder.appendingPathComponent("journal.json") }
    private var samplesURL: URL { folder.appendingPathComponent("readings.csv") }
    private var landingURL: URL { folder.appendingPathComponent("landing.json") }
    private var parkedURL: URL { folder.appendingPathComponent("parked.json") }

    private func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    func loadJournal() -> StrapWorkoutJournal? {
        StrapWorkoutJournal.decoded(from: try? Data(contentsOf: journalURL))
    }

    func saveJournal(_ journal: StrapWorkoutJournal) {
        guard let data = journal.encoded() else { return }
        ensureFolder()
        try? data.write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func appendSamples(_ samples: [HRSample]) {
        guard !samples.isEmpty else { return }
        ensureFolder()
        let data = Data(samples.map(StrapWorkoutSampleLine.encode).joined().utf8)
        if let handle = try? FileHandle(forWritingTo: samplesURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: samplesURL, options: [.completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func loadSamples() -> [HRSample] {
        guard let data = try? Data(contentsOf: samplesURL) else { return [] }
        return StrapWorkoutSampleLine.decode(String(decoding: data, as: UTF8.self))
    }

    func clearRunning() {
        try? FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(at: samplesURL)
    }

    func parkRunning() {
        guard let running = loadJournal() else { return clearRunning() }
        saveParked(loadParked() + [StrapWorkoutParked(journal: running, samples: loadSamples())])
        clearRunning()
    }

    func loadParked() -> [StrapWorkoutParked] {
        guard let data = try? Data(contentsOf: parkedURL) else { return [] }
        return (try? JSONDecoder().decode([StrapWorkoutParked].self, from: data)) ?? []
    }

    func saveParked(_ parked: [StrapWorkoutParked]) {
        if parked.isEmpty {
            try? FileManager.default.removeItem(at: parkedURL)
            return
        }
        guard let data = try? JSONEncoder().encode(parked) else { return }
        ensureFolder()
        try? data.write(to: parkedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadLanding() -> [StrapWorkoutLandingBatch] {
        guard let data = try? Data(contentsOf: landingURL) else { return [] }
        return (try? JSONDecoder().decode([StrapWorkoutLandingBatch].self, from: data)) ?? []
    }

    func saveLanding(_ batches: [StrapWorkoutLandingBatch]) {
        if batches.isEmpty {
            try? FileManager.default.removeItem(at: landingURL)
            return
        }
        guard let data = try? JSONEncoder().encode(batches) else { return }
        ensureFolder()
        try? data.write(to: landingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - Location

/// The phone's location for a strap workout: the same configuration as the ring's workout
/// (`WorkoutSessionManager.configureAndStart`): best accuracy with a 5 m filter for a route, coarse
/// for the indoor keep-alive, never auto-paused, background updates on with the indicator shown. The
/// `location` background mode is what keeps a locked phone's workout (and its 1 s strap keep-alive)
/// running. Same fix filters as the ring's (#75): no cached fix, nothing worse than 50 m.
@Observable
@MainActor
final class StrapWorkoutLocation: NSObject, WorkoutLocationTracking, CLLocationManagerDelegate {
    private(set) var gpsActive = false
    private(set) var distanceMeters: Double?
    private(set) var keepAliveUnavailable = false
    @ObservationIgnored private(set) var route: [CLLocation] = []

    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var recordsRoute = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var lastLocation: CLLocation?

    func start(route recordsRoute: Bool) {
        stop()
        self.recordsRoute = recordsRoute
        running = true
        paused = false
        route = []
        distanceMeters = nil
        lastLocation = nil
        keepAliveUnavailable = false
        let manager = CLLocationManager()
        manager.delegate = self
        self.manager = manager
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            configureAndStart(manager)
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            gpsActive = false
            if !recordsRoute { keepAliveUnavailable = true }
        }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        // After a pause, the next fix starts a new leg: no distance across the paused stretch.
        if !paused { lastLocation = nil }
    }

    func stop() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        running = false
        gpsActive = false
    }

    private func configureAndStart(_ manager: CLLocationManager) {
        if recordsRoute {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 5
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone
        }
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        gpsActive = true
        keepAliveUnavailable = false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.running, manager === self.manager else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.configureAndStart(manager)
            case .notDetermined:
                break
            default:
                self.gpsActive = false
                if !self.recordsRoute { self.keepAliveUnavailable = true }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.running, self.recordsRoute, !self.paused, manager === self.manager else { return }
            for location in locations {
                guard abs(location.timestamp.timeIntervalSinceNow) < 10 else { continue }
                guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 else { continue }
                if let previous = self.lastLocation {
                    self.distanceMeters = (self.distanceMeters ?? 0) + location.distance(from: previous)
                }
                self.lastLocation = location
                self.route.append(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, manager === self.manager else { return }
            self.gpsActive = false
        }
    }
}
