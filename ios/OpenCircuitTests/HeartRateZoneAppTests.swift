import CoreLocation
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 83 (#338) in the app target: the stored choices and their one reader, the profile's max HR,
// the strap recorder's zones (fixed at Start, used live and in the summary), and the zone labels.
// Every value is synthetic.

private let zt0 = Date(timeIntervalSince1970: 1_789_862_400 + 10 * 3600)

// MARK: - Fakes (the recorder's collaborators, as in StrapWorkoutRecorderTests)

@MainActor
private final class ZonesHRSource: StrapWorkoutHeartRateSource {
    let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-Z")
    var isLinkConnected = true
    var ready = true
    var syncing = false
    var canStreamHeartRate = true
    var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    var rrIntervalsReceived = 0
    func startWorkoutHeartRate() {}
    func stopWorkoutHeartRate() {}
    func sendOwedOrphanStop() {}
    func syncHistory(manual: Bool) {}
}

@MainActor
private final class ZonesHealthWriter: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    func save(_ write: StrapWorkoutWrite) async -> Bool { writes.append(write); return true }
}

@MainActor
private final class ZonesJournal: StrapWorkoutJournalStoring {
    var journal: StrapWorkoutJournal?
    var samples: [HRSample] = []
    var parked: [StrapWorkoutParked] = []
    var landing: [StrapWorkoutLandingBatch] = []
    func loadJournal() -> StrapWorkoutJournal? { journal }
    func saveJournal(_ journal: StrapWorkoutJournal) { self.journal = journal }
    func appendSamples(_ samples: [HRSample]) { self.samples += samples }
    func loadSamples() -> [HRSample] { samples }
    func clearRunning() { journal = nil; samples = [] }
    func parkRunning() { clearRunning() }
    func loadParked() -> [StrapWorkoutParked] { parked }
    func saveParked(_ parked: [StrapWorkoutParked]) { self.parked = parked }
    func loadLanding() -> [StrapWorkoutLandingBatch] { landing }
    func saveLanding(_ batches: [StrapWorkoutLandingBatch]) { landing = batches }
}

@MainActor
private final class ZonesLocation: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    func start(route: Bool) {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
}

@MainActor
private final class ZonesHRStore: StrapWorkoutHRStore {
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {}
}

@MainActor
final class HeartRateZoneAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "HeartRateZoneAppTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: Stored choices

    func testNothingStoredIsAutomaticMaxAndPercentOfMax() {
        XCTAssertEqual(HeartRateZoneDefaults.settings(defaults), .standard)
        XCTAssertNil(HeartRateZoneDefaults.manualMaxHR(defaults))
    }

    func testChoicesRoundTripThroughTheStoredKeys() {
        let settings = HeartRateZoneSettings(method: .custom, manualMaxHR: 188,
                                             customLowerBounds: [100, 120, 140, 160, 180])
        HeartRateZoneDefaults.save(settings, to: defaults)
        XCTAssertEqual(HeartRateZoneDefaults.settings(defaults), settings)
        XCTAssertEqual(defaults.string(forKey: HeartRateZoneDefaults.customBoundsKey), "100,120,140,160,180")
    }

    func testAnUnusableStoredValueIsIgnoredNotTrusted() {
        defaults.set("nonsense", forKey: HeartRateZoneDefaults.methodKey)
        defaults.set(99, forKey: HeartRateZoneDefaults.manualMaxHRKey)
        defaults.set("1,2,3", forKey: HeartRateZoneDefaults.customBoundsKey)
        let settings = HeartRateZoneDefaults.settings(defaults)
        XCTAssertEqual(settings.method, .percentOfMax)
        XCTAssertNil(settings.manualMaxHR)
        XCTAssertEqual(settings.customLowerBounds, HeartRateZoneSettings.defaultCustomLowerBounds)
        defaults.set(231, forKey: HeartRateZoneDefaults.manualMaxHRKey)
        XCTAssertNil(HeartRateZoneDefaults.manualMaxHR(defaults))
        HeartRateZoneDefaults.save(HeartRateZoneSettings(manualMaxHR: 500), to: defaults)
        XCTAssertEqual(defaults.integer(forKey: HeartRateZoneDefaults.manualMaxHRKey), 0, "an invalid max is never written")
    }

    // MARK: Profile max HR (the helper behind every 220 - age site)

    func testTheStoredProfileKeepsTwoTwentyMinusAgeAtEveryAgeWithAutomatic() {
        for age in [1, 30, 90] {
            defaults.set(age, forKey: "userProfile.age")
            XCTAssertEqual(HealthKitWriter.storedUserProfile(defaults).maxHR, max(220 - age, 1), "age \(age)")
            XCTAssertNil(HealthKitWriter.storedUserProfile(defaults).manualMaxHR)
        }
    }

    func testTheStoredProfileCarriesAManualMaxAndEverySiteReadsIt() {
        defaults.set(30, forKey: "userProfile.age")
        HeartRateZoneDefaults.save(HeartRateZoneSettings(manualMaxHR: 175), to: defaults)
        let profile = HealthKitWriter.storedUserProfile(defaults)
        XCTAssertEqual(profile.maxHR, 175)
        XCTAssertEqual(HeartRateZoneDefaults.zones(profile: profile, restingHR: nil, defaults: defaults).maxHR, 175)
        XCTAssertFalse(HeartRateZoneDefaults.zones(profile: profile, restingHR: nil, defaults: defaults).maxHRIsAutomatic)
    }

    func testTheCaloriesReferenceLineIsUnchangedWithAutomaticAndNamesAManualMax() {
        let status = ProfileDefaultsStatus(age: false, weight: false, height: false, sex: false)
        XCTAssertEqual(CaloriesReferenceLine.text(bmr: 1700, maxHR: 180, age: 40, status: status),
                       "BMR 1700 kcal/day · est. max HR 180 bpm (220 − age)")
        XCTAssertEqual(CaloriesReferenceLine.text(bmr: 1700, maxHR: 175, age: 40, status: status, manualMaxHR: 175),
                       "BMR 1700 kcal/day · max HR 175 bpm (set by you)")
        XCTAssertEqual(CaloriesReferenceLine.text(bmr: 1700, maxHR: 180, age: 40, status: status, manualMaxHR: 0),
                       "BMR 1700 kcal/day · est. max HR 180 bpm (220 − age)")
    }

    // MARK: The reader

    func testTheReaderBuildsTheZonesFromTheStoredChoicesAndTheProfileAge() {
        defaults.set(40, forKey: "userProfile.age")
        let profile = HealthKitWriter.storedUserProfile(defaults)
        XCTAssertEqual(HeartRateZoneDefaults.zones(profile: profile, restingHR: nil, defaults: defaults).lowerBounds,
                       [90, 108, 126, 144, 162])
        HeartRateZoneDefaults.save(HeartRateZoneSettings(method: .percentOfReserve), to: defaults)
        let reserve = HeartRateZoneDefaults.zones(profile: profile, restingHR: 60, defaults: defaults)
        XCTAssertEqual(reserve.method, .percentOfReserve)
        XCTAssertEqual(reserve.lowerBounds, [120, 132, 144, 156, 168])
    }

    func testAWorkoutStartingWithReserveZonesAndNoStoreFallsBackToPercentOfMaxWithANote() {
        defaults.set(40, forKey: "userProfile.age")
        HeartRateZoneDefaults.save(HeartRateZoneSettings(method: .percentOfReserve), to: defaults)
        let zones = HeartRateZoneDefaults.zonesForNewWorkout(profile: HealthKitWriter.storedUserProfile(defaults),
                                                             store: nil, defaults: defaults)
        XCTAssertEqual(zones.fallback, .noRestingHR)
        XCTAssertEqual(zones.lowerBounds, [90, 108, 126, 144, 162])
    }

    // MARK: Labels (83a)

    func testZoneRowsAndTheLiveActivityNameZonesAsZoneN() {
        XCTAssertEqual(WorkoutActivityAttributes.ContentState.zoneLabel(3), "Zone 3")
        XCTAssertEqual(WorkoutActivityAttributes.ContentState.zoneAccessibilityLabel(3), "Heart rate zone 3")
        XCTAssertEqual(ZoneBarRow.accessibilityLabel(zone: .aerobic, seconds: 190, rangeText: "140–159 bpm"),
                       "Zone 3, 140 to 159 beats per minute, 3 minutes 10 seconds")
        XCTAssertEqual(ZoneBarRow.accessibilityLabel(zone: .extreme, seconds: 0, rangeText: "180+ bpm"),
                       "Zone 5, 180 beats per minute and up, no time")
        XCTAssertEqual(ZoneBarRow.accessibilityLabel(zone: .warmUp, seconds: 45, rangeText: nil), "Zone 1, 45 seconds")
    }

    // MARK: History re-derives from stored readings (83f)

    func testWorkoutHistoryZonesAndLoadFollowTheUsersZones() {
        let t = zt0
        let hr = (0..<120).map { HRSample(bpm: 135, start: t.addingTimeInterval(Double($0)), end: t.addingTimeInterval(Double($0 + 1))) }
        let end = t.addingTimeInterval(120)
        let byDefault = WorkoutDetailContent.zones(hr, zones: HeartRateZones(percentOfMax: 200), end: end)
        XCTAssertEqual(byDefault?.fatBurnSeconds ?? 0, 120, accuracy: 0.001)
        let custom = HeartRateZones(settings: HeartRateZoneSettings(method: .custom, customLowerBounds: [101, 110, 120, 130, 140]),
                                    age: 30, restingHR: nil)
        let byCustom = WorkoutDetailContent.zones(hr, zones: custom, end: end)
        XCTAssertEqual(byCustom?.anaerobicSeconds ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(byCustom?.fatBurnSeconds ?? -1, 0, accuracy: 0.001)
    }

    // MARK: The strap recorder

    private var clockNow = zt0

    private func makeRecorder(zones: @escaping @MainActor (UserProfile) -> HeartRateZones)
        -> (StrapWorkoutRecorder, ZonesHRSource, ZonesHealthWriter) {
        let source = ZonesHRSource()
        let health = ZonesHealthWriter()
        let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)
        let recorder = StrapWorkoutRecorder(
            source: { source }, health: health, journal: ZonesJournal(), hrStore: { ZonesHRStore() },
            location: ZonesLocation(), liveActivity: nil, profile: { profile }, zones: zones,
            indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(UserDefaults(suiteName: "zones-orphan-\(UUID().uuidString)")!),
            tombstones: WorkoutTombstones(UserDefaults(suiteName: "zones-tombstones-\(UUID().uuidString)")!),
            clock: { [unowned self] in self.clockNow }, autoTick: false, managesIdleTimer: false)
        return (recorder, source, health)
    }

    func testTheStrapRecorderClassifiesLiveAndInTheSummaryWithTheZonesItWasGiven() async throws {
        // 152 bpm: Zone 4 on the default zones for a 180 max, Zone 5 on these.
        let custom = HeartRateZones(settings: HeartRateZoneSettings(method: .custom, customLowerBounds: [100, 110, 120, 130, 140]),
                                    age: 40, restingHR: nil)
        let (recorder, source, health) = makeRecorder(zones: { _ in custom })
        recorder.selectedSport = .runningIndoor
        recorder.start()
        XCTAssertEqual(recorder.activeZones, custom)
        var now = zt0
        for second in 1...60 {
            now = zt0.addingTimeInterval(Double(second))
            clockNow = now
            source.heartRateObserver?(152, now)
            await recorder.tick(now: now)
        }
        XCTAssertGreaterThan(recorder.liveZoneBreakdown.extremeSeconds, 0)
        XCTAssertEqual(recorder.liveZoneBreakdown.anaerobicSeconds, 0)
        await recorder.end()
        let summary = try XCTUnwrap(health.writes.first).summary.summary
        XCTAssertGreaterThan(summary.zoneBreakdown.extremeSeconds, 0)
        XCTAssertEqual(summary.zoneBreakdown.anaerobicSeconds, 0)
    }

    func testTheStrapRecordersZonesAreFixedWhenTheWorkoutStarts() {
        var calls = 0
        let first = HeartRateZones(percentOfMax: 180)
        let second = HeartRateZones(percentOfMax: 200)
        let (recorder, _, _) = makeRecorder(zones: { _ in calls += 1; return calls == 1 ? first : second })
        recorder.selectedSport = .runningIndoor
        recorder.start()
        XCTAssertEqual(recorder.activeZones, first)
        XCTAssertEqual(recorder.activeZones, first, "later edits do not move a running workout's zones")
        XCTAssertEqual(calls, 1)
    }

    // MARK: Ring live zones (SF-2)

    func testTheRingsLiveZoneBarsAndActiveZonesUseTheSessionsZones() {
        // 152 bpm: Zone 4 on the default zones for a 180 max, Zone 5 on these.
        let custom = HeartRateZones(settings: HeartRateZoneSettings(method: .custom, customLowerBounds: [100, 110, 120, 130, 140]),
                                    age: 40, restingHR: nil)
        let manager = WorkoutSessionManager()
        XCTAssertNil(manager.activeZones)
        let agg = WorkoutSessionAggregator(startDate: zt0, userAge: 40, zones: custom)
        agg.add(sample: HRSample(bpm: 152, start: zt0, end: zt0.addingTimeInterval(10)))
        manager.aggregator = agg
        XCTAssertEqual(manager.activeZones, custom)
        manager.recomputeLiveZones(agg: agg, now: zt0.addingTimeInterval(10))
        XCTAssertEqual(manager.liveZoneBreakdown.extremeSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(manager.liveZoneBreakdown.anaerobicSeconds, 0)
    }

    // MARK: The active device's resting heart rate (SF-3, decision 29)

    private func zonesStoreContainer() throws -> ModelContainer {
        try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// A day of readings 08:00-14:00 every 10 minutes at one rate, from `device`, yesterday.
    private func insertReadings(_ bpm: Double, device: SyncDeviceID, into context: ModelContext) {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        for step in 0...36 {
            let at = day.addingTimeInterval(8 * 3600 + Double(step) * 600)
            context.insert(StoredSample(QuantitySample(kind: .heartRate, start: at, end: at, value: bpm), device: device))
        }
    }

    func testPercentOfReserveReadsTheActiveDevicesRestingHeartRateNotAnotherDevicesLower() async throws {
        let strap = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-Z")
        let container = try zonesStoreContainer()
        insertReadings(48, device: .ringConn, into: container.mainContext)   // the ring's: lower
        insertReadings(66, device: strap, into: container.mainContext)       // the strap's: the active device
        try container.mainContext.save()

        let override = OwnershipOverride()
        defer { override.restore() }
        override.install(.strapOwnsAllTime)
        let off = await HeartRateZoneRestingHR.latest(container: container, log: .strapOwnsAllTime)
        XCTAssertEqual(off ?? 0, 66, accuracy: 0.5, "the strap owns the present: only its readings")
        XCTAssertEqual(HeartRateZoneRestingHR.latest(store: LocalStore(container.mainContext)) ?? 0, 66, accuracy: 0.5)

        // With the ring as the active device, the ring's own value is read.
        override.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast),
                                                       .init(family: .ringConn, since: Date().addingTimeInterval(-3 * 86_400))]))
        let ringLog = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast),
                                                   .init(family: .ringConn, since: Date().addingTimeInterval(-3 * 86_400))])
        let ring = await HeartRateZoneRestingHR.latest(container: container, log: ringLog)
        XCTAssertEqual(ring ?? 0, 48, accuracy: 0.5)
    }

    // MARK: Settings preview (SF-4)

    func testAnInvalidCustomDraftShowsTheLastValidSetInForce() {
        let stored = HeartRateZoneDefaults.encode([100, 120, 140, 160, 180])
        XCTAssertEqual(HeartRateZoneDefaults.customBoundsInForce(draft: [100, 120, 120, 160, 180], storedText: stored),
                       [100, 120, 140, 160, 180])
        XCTAssertEqual(HeartRateZoneDefaults.customBoundsInForce(draft: [90, 110, 130, 150, 170], storedText: stored),
                       [90, 110, 130, 150, 170])
        XCTAssertEqual(HeartRateZoneDefaults.customBoundsInForce(draft: [5, 4, 3, 2, 1], storedText: nil),
                       HeartRateZoneSettings.defaultCustomLowerBounds)
    }
}
