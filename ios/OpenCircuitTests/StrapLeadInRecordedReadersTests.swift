import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 79 (#331 items 2-5): the strap in-bed lead-in follow-ups for the readers of a stored night.
// - 79a: a manually edited strap night keeps its RECORDED columns frozen, lead-in included, while the
//   edit rewrites `hypnogramData`. The readers of the recorded columns (the illness alert, Vitals
//   Status, Trends' vitals averages, the strap's nap windows) trim the recorded night's lead-in from
//   `recordedHypnogramData`; the edited window is the person's own and is never trimmed.
// - 79b: only a strap night is read as having a lead-in; a ring night of the same shape reads whole.
// - 79c: Trends' calories and exercise minutes leave out the whole in-bed window, as the dashboard does.
// - 79d: the Vitals Status and Sleep card call lines are one expression a test reaches.
// Every value, time and identifier is synthetic.

@MainActor
final class StrapLeadInRecordedReadersTests: XCTestCase {
    private let ownership = OwnershipOverride()
    private var containers: [ModelContainer] = []
    private var defaults: UserDefaults!
    private var suite = ""
    private let calendar = Calendar.current
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-00000000D079")

    override func setUp() {
        super.setUp()
        suite = "StrapLeadInRecordedReadersTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        clearEditOverlays()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        clearEditOverlays()
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    /// The edit path's night-keyed overlays (`applySleepEdit`), for every night these fixtures store.
    private func clearEditOverlays() {
        for k in 0...10 {
            let key = day(k).timeIntervalSince1970
            UserDefaults.standard.removeObject(forKey: "sleep.edit.onset.\(key)")
            UserDefaults.standard.removeObject(forKey: "sleep.edit.priorTimes.\(key)")
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container
    }

    private func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
    }

    /// The night ending on `day(daysAgo)`: asleep 23:00–07:00; with a lead-in, in bed from 22:00.
    private func bed(_ daysAgo: Int) -> Date { day(daysAgo).addingTimeInterval(-3600) }
    private func wake(_ daysAgo: Int) -> Date { day(daysAgo).addingTimeInterval(7 * 3600) }
    private func leadInStart(_ daysAgo: Int) -> Date { day(daysAgo).addingTimeInterval(-2 * 3600) }

    /// A strap night over `bed…end` (asleep throughout), with the store path's lead-in from `leadIn`.
    private func strapSegments(bed: Date, end: Date, leadIn: Date?) -> [SleepSegment] {
        let window = DateInterval(start: bed, end: end)
        let segments = [SleepSegment(start: bed, end: end, stage: .inBed), SleepSegment(start: bed, end: end, stage: .asleepCore)]
        guard let leadIn else { return segments }
        return HelioSleepSelection.withLeadIn(segments, window: window, from: leadIn)
    }

    @discardableResult
    private func save(_ segments: [SleepSegment], store: LocalStore, device: SyncDeviceID) throws -> SleepPersistOutcome {
        let start = segments.map(\.start).min()!, end = segments.map(\.end).max()!
        let sleep = try XCTUnwrap(SleepStaging.sleepWindow(segments))
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        extras.skinTempC = 34.0
        return try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: start, inBedEnd: end),
                                          inBedStart: start, inBedEnd: end, sleepOnset: sleep.onset, sleepWake: sleep.wake,
                                          extras: extras, device: device)
    }

    /// Nine strap nights (8 days ago … last night), with or without the 22:00–23:00 lead-in, and the same
    /// readings in both stores every 5 minutes: HR 58, HRV 60, breathing 14 asleep (last night HR 66, HRV
    /// 42), and HR 70, HRV 35, breathing 18 in the hour before sleep. Then last night is edited by hand:
    /// its wake moved 30 min earlier, and its in-bed start kept, so the EDITED window still starts where
    /// the recorded one does (with a lead-in: at 22:00, the lead-in's start), or (`movedBedtime`, a night
    /// with a lead-in) moved 30 min later, the edited timeline keeping an awake start from there.
    private func editedFixture(leadIn: Bool, movedBedtime: Bool = false) throws -> (container: ModelContainer, store: LocalStore) {
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        for k in 0...8 {
            XCTAssertEqual(try save(strapSegments(bed: bed(k), end: wake(k), leadIn: leadIn ? leadInStart(k) : nil),
                                    store: store, device: strap), .inserted)
            let asleep: (hr: Double, hrv: Double) = k == 0 ? (66, 42) : (58, 60)
            for t in stride(from: leadInStart(k).timeIntervalSince1970, to: wake(k).timeIntervalSince1970, by: 300) {
                let inLeadIn = t < bed(k).timeIntervalSince1970
                let at = Date(timeIntervalSince1970: t + 30)
                for (kind, value) in [(MetricKind.heartRate, inLeadIn ? 70 : asleep.hr), (.hrvSDNN, inLeadIn ? 35 : asleep.hrv),
                                      (.respiratoryRate, inLeadIn ? 18 : 14)] {
                    store.context.insert(StoredSample(kindRaw: kind.rawValue, start: at, end: at, value: value, deviceID: strap.rawValue))
                }
            }
        }
        try store.context.save()
        let row = try latest(store)
        let editedWake = wake(0).addingTimeInterval(-30 * 60)
        let editedBedtime = leadIn && movedBedtime ? leadInStart(0).addingTimeInterval(30 * 60) : row.inBedStart
        let edited = strapSegments(bed: bed(0), end: editedWake, leadIn: leadIn ? editedBedtime : nil)
        XCTAssertTrue(try store.applySleepEdit(night: row.night,
                                               times: SleepEdit.Times(inBedStart: editedBedtime, sleepOnset: bed(0), sleepWake: editedWake),
                                               summary: SleepStaging.summary(edited), hypnogram: edited))
        XCTAssertTrue(row.isManuallyEdited)
        XCTAssertEqual(row.inBedStart, leadIn ? leadInStart(0) : bed(0), "the recorded columns stay frozen")
        XCTAssertEqual(row.editedInBedStart, editedBedtime)
        XCTAssertEqual(HelioSleepSelection.leadIn(in: SleepHypnogramCodec.decode(row.recordedHypnogramData)) != nil, leadIn)
        return (container, store)
    }

    private func latest(_ store: LocalStore) throws -> StoredSleepSummary { try XCTUnwrap(try store.latestSleepSummary()) }

    private func samples(_ store: LocalStore, _ kind: MetricKind) throws -> [StoredSample] {
        let raw = kind.rawValue
        return try store.context.fetch(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == raw },
                                                                     sortBy: [SortDescriptor(\.start)]))
    }

    // MARK: 79a: an edited strap night's recorded columns

    func testAnEditedStrapNightsRecordedWindowIsReadWithoutTheRecordedLeadIn() throws {
        for moved in [false, true] {
            let row = try latest(editedFixture(leadIn: true, movedBedtime: moved).store)
            XCTAssertEqual(row.recordedSleepWindowStart(log: .strapOwnsAllTime), bed(0), "bedtime moved: \(moved)")
            XCTAssertEqual(row.recordedSleepWindowInBedStart, bed(0), "bedtime moved: \(moved)")
            XCTAssertEqual(VitalsStatusCardView.reportNight(row).inBedStart, bed(0), "bedtime moved: \(moved)")
        }
        // The same row unedited reads the same recorded window.
        let unedited = try latest(editedFixture(leadIn: true).store)
        unedited.isManuallyEdited = false
        unedited.hypnogramData = unedited.recordedHypnogramData
        XCTAssertEqual(unedited.recordedSleepWindowStart(log: .strapOwnsAllTime), bed(0))
    }

    func testTheIllnessAlertReadsAnEditedNightWithoutItsRecordedLeadIn() async throws {
        let center = HealthNotificationCenter()
        for moved in [false, true] {
            defaults.removePersistentDomain(forName: suite)
            let readWith = await center.illnessNight(store: try editedFixture(leadIn: true, movedBedtime: moved).store,
                                                     lastNotifiedNight: [:], defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
            let readWithout = await center.illnessNight(store: try editedFixture(leadIn: false).store, lastNotifiedNight: [:], defaults: defaults)
            let a = try XCTUnwrap(readWith), b = try XCTUnwrap(readWithout)
            XCTAssertTrue(b.assessment.isSuspected, "last night's HR up and HRV down: the alert's own shape")
            XCTAssertEqual(a.assessment, b.assessment, "bedtime moved: \(moved)")
        }
    }

    func testVitalsStatusReadsAnEditedNightWithoutItsRecordedLeadIn() throws {
        func report(_ store: LocalStore) throws -> VitalsBaseline.Report? {
            let rows = try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)]))
            let hrv = try samples(store, .hrvSDNN).map { (start: $0.start, value: $0.value) }
            return VitalsStatusCardView.computeReport(hr: [], spo2: [], hrv: hrv,
                                                      nights: VitalsStatusCardView.reportNights(rows, log: .strapOwnsAllTime),
                                                      fallbackRestingHR: nil, fallbackSpO2: nil, fallbackHRV: nil,
                                                      fallbackSkinTempOffsetC: nil)
        }
        let b = try report(editedFixture(leadIn: false).store)
        XCTAssertNotNil(try XCTUnwrap(b?.signals.first { $0.vital == .overnightHRV }).baselineMean)
        for moved in [false, true] {
            XCTAssertEqual(try report(editedFixture(leadIn: true, movedBedtime: moved).store), b, "bedtime moved: \(moved)")
        }
    }

    func testTrendsVitalsReadAnEditedNightWithoutItsRecordedLeadIn() async throws {
        func point(_ container: ModelContainer) async throws -> TrendsEngine.DailyPoint {
            let trends = await TrendsData.loadAsync(container: container, tempUnitRaw: TemperatureUnit.celsius.rawValue)
            return try XCTUnwrap(trends.points.first { calendar.isDate($0.date, inSameDayAs: day(0)) })
        }
        let b = try await point(editedFixture(leadIn: false).container)
        XCTAssertEqual(b.sleepHRAvg, 66)
        for moved in [false, true] {
            let a = try await point(editedFixture(leadIn: true, movedBedtime: moved).container)
            XCTAssertEqual(a.sleepHRAvg, b.sleepHRAvg, "bedtime moved: \(moved)")
            XCTAssertEqual(a.sleepHRVAvg, b.sleepHRVAvg, "bedtime moved: \(moved)")
            XCTAssertEqual(a.sleepRRAvg, b.sleepRRAvg, "bedtime moved: \(moved)")
        }
    }

    func testTheStrapNapWindowsReadAnEditedNightWithoutItsRecordedLeadIn() throws {
        for moved in [false, true] {
            let store = try editedFixture(leadIn: true, movedBedtime: moved).store
            let windows = store.storedNightWindows(from: bed(0), to: wake(0))
            XCTAssertTrue(windows.contains(DateInterval(start: bed(0), end: wake(0))), "the recorded window, from its sleep (moved: \(moved))")
            let editedStart = leadInStart(0).addingTimeInterval(moved ? 30 * 60 : 0)
            XCTAssertTrue(windows.contains(DateInterval(start: editedStart, end: wake(0).addingTimeInterval(-30 * 60))),
                          "the edited window, whole (moved: \(moved))")
            XCTAssertFalse(windows.contains(DateInterval(start: leadInStart(0), end: wake(0))), "moved: \(moved)")
        }
    }

    /// The edited window is the person's own: the readers of the CURRENT window (the Sleep card's overnight
    /// averages, the headache HRV and bedtime) read it from its start, lead-in shape or not.
    func testTheEditedWindowIsNeverTrimmed() throws {
        for moved in [false, true] {
            let row = try latest(editedFixture(leadIn: true, movedBedtime: moved).store)
            let editedStart = leadInStart(0).addingTimeInterval(moved ? 30 * 60 : 0)
            let night = try XCTUnwrap(SleepCardView.selectNight(liveSegments: [], stored: row))
            XCTAssertEqual(night.inBedStart, editedStart, "moved: \(moved)")
            XCTAssertEqual(SleepCardView.overnightWindow(for: night, latest: row)?.start, editedStart, "moved: \(moved)")
            XCTAssertEqual(HeadacheNightRow(row).inBedStart, editedStart, "moved: \(moved)")
            XCTAssertEqual(row.sleepWindowStart(from: row.sleepEditCurrentInBedStart), editedStart, "moved: \(moved)")
        }
    }

    // MARK: 79b: only a strap night has a lead-in

    /// A row with exactly the strap's lead-in shape, stored in time the ring owns: every reader reads its
    /// whole window. The same row in time the strap owns is read without the lead-in.
    func testARingNightWithTheLeadInShapeIsReadWhole() throws {
        var ringBeforeStrap = DeviceOwnershipLog()
        _ = ringBeforeStrap.record(.zeppOS, since: wake(0).addingTimeInterval(3600))
        for (label, log) in [("empty log", DeviceOwnershipLog()), ("the strap chosen after the night", ringBeforeStrap)] {
            ownership.install(log)
            let store = LocalStore(try makeContainer().mainContext)
            try save(strapSegments(bed: bed(0), end: wake(0), leadIn: leadInStart(0)), store: store, device: .ringConn)
            let row = try latest(store)
            XCTAssertEqual(row.inBedStart, leadInStart(0), label)
            XCTAssertNotNil(HelioSleepSelection.leadIn(in: SleepHypnogramCodec.decode(row.hypnogramData)), "\(label): the strap's shape")
            XCTAssertFalse(row.isStrapNight(log: log), label)
            XCTAssertEqual(row.recordedSleepWindowStart(log: log), leadInStart(0), label)
            XCTAssertEqual(row.sleepWindowInBedStart, leadInStart(0), label)
            XCTAssertEqual(VitalsStatusCardView.reportNight(row).inBedStart, leadInStart(0), label)
            XCTAssertEqual(HeadacheNightRow(row).inBedStart, leadInStart(0), label)
            let night = try XCTUnwrap(SleepCardView.selectNight(liveSegments: [], stored: row))
            XCTAssertEqual(SleepCardView.overnightWindow(for: night, latest: row)?.start, leadInStart(0), label)
            XCTAssertEqual(store.storedNightWindows(from: bed(0), to: wake(0)), [DateInterval(start: leadInStart(0), end: wake(0))], label)

            // The same row, the strap owning its time: without the lead-in.
            ownership.install(.strapOwnsAllTime)
            XCTAssertTrue(row.isStrapNight(log: .strapOwnsAllTime), label)
            XCTAssertEqual(row.recordedSleepWindowStart(log: .strapOwnsAllTime), bed(0), label)
            XCTAssertEqual(row.sleepWindowInBedStart, bed(0), label)
            XCTAssertEqual(store.storedNightWindows(from: bed(0), to: wake(0)), [DateInterval(start: bed(0), end: wake(0))], label)
        }
    }

    /// Trends reads a ring night of the lead-in shape whole: the readings before its sleep are averaged.
    func testTrendsAverageARingNightOfTheLeadInShapeWhole() async throws {
        ownership.install(DeviceOwnershipLog())
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        try save(strapSegments(bed: bed(0), end: wake(0), leadIn: leadInStart(0)), store: store, device: .ringConn)
        for t in stride(from: leadInStart(0).timeIntervalSince1970, to: wake(0).timeIntervalSince1970, by: 300) {
            let at = Date(timeIntervalSince1970: t + 30)
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: at, end: at,
                                              value: t < bed(0).timeIntervalSince1970 ? 82 : 58, deviceID: SyncDeviceID.ringConn.rawValue))
        }
        try store.context.save()
        let trends = await TrendsData.loadAsync(container: container, tempUnitRaw: TemperatureUnit.celsius.rawValue)
        let point = try XCTUnwrap(trends.points.first { calendar.isDate($0.date, inSameDayAs: day(0)) })
        let readings = (0..<12).map { _ in 82.0 } + (0..<96).map { _ in 58.0 }
        XCTAssertEqual(try XCTUnwrap(point.sleepHRAvg), readings.reduce(0, +) / Double(readings.count), accuracy: 1e-9)
    }

    // MARK: 79c: Trends' calories read the in-bed window, like the dashboard

    /// A strap night two days ago, in bed from 00:30 (a lead-in to 01:30, heart rate 140 and 30 steps a
    /// minute, so the motion gate would count it) and asleep 01:30–07:30 (heart rate 55): the day's
    /// active kcal and exercise minutes in Trends are the dashboard's own estimate for that day (its
    /// inputs: the day's heart rate and steps through `DashboardReads.todayActivity`, the stored night's
    /// recorded in-bed window), which leaves the lead-in out. Trends' sleep heart rate still reads the
    /// sleep only (77h).
    func testTheSameDayGivesTheSameActiveKcalInTrendsAndOnTheDashboardPath() async throws {
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        let dayStart = day(2)
        let lead = dayStart.addingTimeInterval(30 * 60), sleep = dayStart.addingTimeInterval(90 * 60)
        let end = dayStart.addingTimeInterval(7.5 * 3600)
        XCTAssertEqual(try save(strapSegments(bed: sleep, end: end, leadIn: lead), store: store, device: strap), .inserted)
        for t in stride(from: lead.timeIntervalSince1970, to: end.timeIntervalSince1970, by: 60) {
            let at = Date(timeIntervalSince1970: t)
            let inLeadIn = t < sleep.timeIntervalSince1970
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: at, end: at.addingTimeInterval(60),
                                              value: inLeadIn ? 140 : 55, deviceID: strap.rawValue))
            // Steps in the lead-in, so the motion gate (#281) would let its heart rate count.
            if inLeadIn { store.context.insert(StoredStepSample(start: at, end: at.addingTimeInterval(60), delta: 30)) }
        }
        store.context.insert(StoredDaily(day: dayStart, steps: 60 * 30))
        try store.context.save()
        let row = try latest(store)
        XCTAssertEqual(row.inBedStart, lead)
        XCTAssertEqual(row.recordedSleepWindowStart(log: .strapOwnsAllTime), sleep)

        // The dashboard's estimate (ContentView's and GoalsCardView's calories task), for that day.
        let read = await DashboardReads.todayActivity(container: container, dayStart: dayStart)
        let activity = try XCTUnwrap(read)
        let profile = HealthKitWriter.storedUserProfile()
        let activityIntervals = RingActivityEventLedger.load().corroboratingIntervals(now: Date())
        func estimate(sleepWindow: DateInterval) -> Calories.DailyEstimate {
            Calories.dailyEstimate(hrSamples: activity.heartRate.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) },
                                   steps: 60 * 30, profile: profile, sleepWindow: sleepWindow,
                                   stepWindows: activity.steps.map { StepWindow(start: $0.start, end: $0.end, delta: $0.delta) },
                                   dayStart: dayStart, activityIntervals: activityIntervals)
        }
        let dashboard = estimate(sleepWindow: DateInterval(start: row.inBedStart, end: row.inBedEnd))
        let sleepOnly = estimate(sleepWindow: DateInterval(start: sleep, end: end))
        XCTAssertGreaterThan(sleepOnly.activeKcal, dashboard.activeKcal, "the lead-in's heart rate is priced unless it is left out")

        let trends = await TrendsData.loadAsync(container: container, tempUnitRaw: TemperatureUnit.celsius.rawValue)
        let point = try XCTUnwrap(trends.points.first { calendar.isDate($0.date, inSameDayAs: dayStart) })
        XCTAssertEqual(try XCTUnwrap(point.activeEnergyKcal), dashboard.activeKcal, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(point.exerciseMin), dashboard.elevatedMinutes, accuracy: 1e-9)
        XCTAssertEqual(point.sleepHRAvg, 55, "the vitals average still reads the sleep only")
    }

    // MARK: 79d: the views' call lines

    /// The Vitals Status card's nights: the current device's own, each from its recorded sleep window.
    func testTheVitalsStatusCallLineReadsTheCurrentDevicesNightsFromTheirSleepWindow() throws {
        var ringThenStrap = DeviceOwnershipLog()
        _ = ringThenStrap.record(.zeppOS, since: day(1))
        let store = LocalStore(try makeContainer().mainContext)
        ownership.install(ringThenStrap)
        try save(strapSegments(bed: bed(0), end: wake(0), leadIn: leadInStart(0)), store: store, device: strap)
        try save(strapSegments(bed: bed(2), end: wake(2), leadIn: nil), store: store, device: .ringConn)
        let rows = try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)]))
        XCTAssertEqual(rows.count, 2)
        let nights = VitalsStatusCardView.reportNights(rows, log: ringThenStrap)
        XCTAssertEqual(nights.map(\.night), [day(0)], "the ring's night is not the strap's baseline (decision 29)")
        XCTAssertEqual(nights.map(\.inBedStart), [bed(0)], "the strap night from its sleep")
        XCTAssertEqual(nights.map(\.inBedEnd), [wake(0)])
        XCTAssertEqual(nights.map(\.skinTempC), [34.0])
    }

    /// The Sleep card's overnight window: the stored night it shows from its sleep, and a live staging
    /// from its own start, even one that starts where the stored night's lead-in does.
    func testTheSleepCardCallLineReadsTheStoredNightsSleepWindowAndALiveStagingsOwn() throws {
        let store = LocalStore(try makeContainer().mainContext)
        try save(strapSegments(bed: bed(0), end: wake(0), leadIn: leadInStart(0)), store: store, device: strap)
        let row = try latest(store)
        let stored = try XCTUnwrap(SleepCardView.selectNight(liveSegments: [], stored: row))
        XCTAssertEqual(SleepCardView.overnightWindow(for: stored, latest: row), DateInterval(start: bed(0), end: wake(0)))

        let live = try XCTUnwrap(SleepCardView.selectNight(
            liveSegments: [SleepSegment(start: leadInStart(0), end: bed(0), stage: .awake),
                           SleepSegment(start: bed(0), end: wake(0).addingTimeInterval(600), stage: .asleepCore)],
            stored: nil))
        XCTAssertEqual(live.inBedStart, leadInStart(0))
        XCTAssertEqual(SleepCardView.overnightWindow(for: live, latest: row)?.start, leadInStart(0), "a live staging: its own window")
    }
}
