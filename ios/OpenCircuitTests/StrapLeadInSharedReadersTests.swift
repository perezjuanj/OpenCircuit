import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 77h (#328, review-328 N2): a strap night's in-bed lead-in is no sleep for ANY reader that
// averages a night's vitals. The illness alert, Vitals Status, the Sleep card's overnight averages,
// Trends and the headache HRV and bedtime regularity read the night's sleep window, so they read a
// night that gained a lead-in exactly as build 88 stored it. Each test stores the same nights and the
// same samples twice: once with a lead-in whose heart rate is ABOVE the sleeping level (and HRV below,
// breathing faster), once without; the reader must give the same result. Every value is synthetic.

@MainActor
final class StrapLeadInSharedReadersTests: XCTestCase {
    private let ownership = OwnershipOverride()
    private var containers: [ModelContainer] = []
    private var defaults: UserDefaults!
    private var suite = ""
    private let calendar = Calendar.current
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-00000000D078")

    override func setUp() {
        super.setUp()
        suite = "StrapLeadInSharedReadersTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        ownership.restore()
        containers.removeAll()
        super.tearDown()
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

    /// The night ending on `day(daysAgo)`: asleep 23:00–07:00; with `leadIn`, in bed from 22:00.
    private func bed(_ daysAgo: Int) -> Date { day(daysAgo).addingTimeInterval(-3600) }
    private func wake(_ daysAgo: Int) -> Date { day(daysAgo).addingTimeInterval(7 * 3600) }
    private func leadInStart(_ daysAgo: Int) -> Date { day(daysAgo).addingTimeInterval(-2 * 3600) }

    /// Nine strap nights (8 days ago … last night: past Vitals Status' 7-night baseline floor), each stored as the store path stores it (with or
    /// without the 22:00–23:00 lead-in). In both stores the same readings: every 5 minutes, HR 58,
    /// HRV 60, breathing 14 asleep (last night: HR 66, HRV 42), and HR 70, HRV 35, breathing 18 in the
    /// hour before sleep, which a reader that averaged the lead-in would take in.
    private func fixture(leadIn: Bool) throws -> (container: ModelContainer, store: LocalStore) {
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        for k in 0...8 {
            let window = DateInterval(start: bed(k), end: wake(k))
            var segments = [SleepSegment(start: window.start, end: window.end, stage: .inBed),
                            SleepSegment(start: window.start, end: window.end, stage: .asleepCore)]
            if leadIn { segments = HelioSleepSelection.withLeadIn(segments, window: window, from: leadInStart(k)) }
            let start = segments.map(\.start).min()!
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            extras.skinTempC = 34.0
            XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments),
                                                      night: SleepNightKey.night(inBedStart: start, inBedEnd: window.end),
                                                      inBedStart: start, inBedEnd: window.end,
                                                      sleepOnset: window.start, sleepWake: window.end,
                                                      extras: extras, device: strap), .inserted)
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
        let rows = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.compactMap { HelioSleepSelection.leadIn(in: SleepHypnogramCodec.decode($0.hypnogramData)) }.count,
                       leadIn ? 9 : 0)
        return (container, store)
    }

    private func samples(_ store: LocalStore, _ kind: MetricKind) throws -> [StoredSample] {
        let raw = kind.rawValue
        return try store.context.fetch(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == raw },
                                                                     sortBy: [SortDescriptor(\.start)]))
    }

    private func latest(_ store: LocalStore) throws -> StoredSleepSummary { try XCTUnwrap(try store.latestSleepSummary()) }

    // MARK: The stored night's sleep window

    func testTheSleepWindowStartsAfterTheLeadInAndIsTheRecordedStartOtherwise() throws {
        let withLeadIn = try latest(fixture(leadIn: true).store)
        XCTAssertEqual(withLeadIn.inBedStart, leadInStart(0))
        XCTAssertEqual(withLeadIn.sleepWindowInBedStart, bed(0))
        let without = try latest(fixture(leadIn: false).store)
        XCTAssertEqual(without.sleepWindowInBedStart, without.inBedStart, "a night without a lead-in: as before")
        // A manually edited night is the person's own window: as before.
        withLeadIn.isManuallyEdited = true
        XCTAssertEqual(withLeadIn.sleepWindowInBedStart, leadInStart(0))
        XCTAssertEqual(withLeadIn.sleepWindowStart(from: bed(0) - 600), bed(0) - 600, "another start: as given")
    }

    func testARingNightReadsItsRecordedWindow() throws {
        ownership.install(DeviceOwnershipLog())
        let store = LocalStore(try makeContainer().mainContext)
        // The ring's shape: one in-bed over the whole bedtime, its pre-sleep awake inside it.
        let segments = [SleepSegment(start: leadInStart(0), end: wake(0), stage: .inBed),
                        SleepSegment(start: leadInStart(0), end: bed(0), stage: .awake),
                        SleepSegment(start: bed(0), end: wake(0), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        _ = try store.saveSleepSummary(SleepStaging.summary(segments), night: day(0), inBedStart: leadInStart(0), inBedEnd: wake(0),
                                       sleepOnset: bed(0), sleepWake: wake(0), extras: extras)
        let ring = try latest(store)
        XCTAssertEqual(ring.sleepWindowInBedStart, leadInStart(0))
        XCTAssertEqual(VitalsStatusCardView.reportNight(ring).inBedStart, leadInStart(0))
        XCTAssertEqual(HeadacheNightRow(ring).inBedStart, leadInStart(0))
    }

    // MARK: One reader family each

    func testTheIllnessAlertReadsTheNightWithoutItsLeadIn() async throws {
        let center = HealthNotificationCenter()
        let withLeadIn = try fixture(leadIn: true).store
        let readWith = await center.illnessNight(store: withLeadIn, lastNotifiedNight: [:], defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        let without = try fixture(leadIn: false).store
        let readWithout = await center.illnessNight(store: without, lastNotifiedNight: [:], defaults: defaults)
        let a = try XCTUnwrap(readWith), b = try XCTUnwrap(readWithout)
        XCTAssertEqual(a.assessment, b.assessment)
        XCTAssertEqual(a.night, b.night)
        XCTAssertTrue(b.assessment.isSuspected, "last night's HR up and HRV down: the alert's own shape")
    }

    func testVitalsStatusReadsTheNightWithoutItsLeadIn() throws {
        func report(_ store: LocalStore) throws -> VitalsBaseline.Report? {
            let rows = try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)]))
            let hrv = try samples(store, .hrvSDNN).map { (start: $0.start, value: $0.value) }
            return VitalsStatusCardView.computeReport(hr: [], spo2: [], hrv: hrv, nights: rows.map(VitalsStatusCardView.reportNight),
                                                      fallbackRestingHR: nil, fallbackSpO2: nil, fallbackHRV: nil,
                                                      fallbackSkinTempOffsetC: nil)
        }
        let a = try report(fixture(leadIn: true).store), b = try report(fixture(leadIn: false).store)
        let hrvSignal = try XCTUnwrap(b?.signals.first { $0.vital == .overnightHRV }, "last night's low HRV is judged")
        XCTAssertNotNil(hrvSignal.baselineMean)
        XCTAssertEqual(a, b)
    }

    func testTheSleepCardsOvernightAveragesReadTheNightWithoutItsLeadIn() throws {
        func averages(_ store: LocalStore) throws -> [Double?] {
            let row = try latest(store)
            let night = try XCTUnwrap(SleepCardView.selectNight(liveSegments: [], stored: row))
            let window = try XCTUnwrap(SleepCardView.overnightWindow(night, row: row))
            return try [MetricKind.heartRate, .hrvSDNN].map { kind in
                OvernightAverages.mean(try samples(store, kind).map { OvernightAverages.Point(value: $0.value, start: $0.start) }, window: window)
            }
        }
        let a = try averages(fixture(leadIn: true).store), b = try averages(fixture(leadIn: false).store)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b.first ?? nil, 66)
        // A live staging (no stored row) reads its own window, as before.
        let live = [SleepSegment(start: bed(0), end: wake(0), stage: .asleepCore)]
        if let night = SleepCardView.selectNight(liveSegments: live, stored: nil) {
            XCTAssertEqual(SleepCardView.overnightWindow(night, row: nil)?.start, night.inBedStart)
        }
    }

    func testTrendsReadTheNightWithoutItsLeadIn() async throws {
        func point(_ container: ModelContainer) async throws -> TrendsEngine.DailyPoint {
            let trends = await TrendsData.loadAsync(container: container, tempUnitRaw: TemperatureUnit.celsius.rawValue)
            return try XCTUnwrap(trends.points.first { calendar.isDate($0.date, inSameDayAs: day(0)) })
        }
        let a = try await point(fixture(leadIn: true).container), b = try await point(fixture(leadIn: false).container)
        XCTAssertEqual(a.sleepHRAvg, b.sleepHRAvg)
        XCTAssertEqual(a.sleepHRVAvg, b.sleepHRVAvg)
        XCTAssertEqual(a.sleepRRAvg, b.sleepRRAvg)
        XCTAssertEqual(b.sleepHRAvg, 66)
    }

    func testTheHeadacheHRVAndBedtimeReadTheNightWithoutItsLeadIn() async throws {
        func read(_ store: LocalStore) async throws -> (hrv: [Date: Double], bedtimes: [Date]) {
            let snapshot = await HeadacheEngine.snapshotOffMain(store: store, day: day(0), asOf: day(0).addingTimeInterval(10 * 3600),
                                                                restingHR: [], calendar: calendar)
            let hrv = try samples(store, .hrvSDNN).compactMap(\.sample)
            return (HeadacheAssessmentBuilder.nightlyMeans(samples: hrv, nights: snapshot.nights), snapshot.nights.map(\.inBedStart).sorted())
        }
        let a = try await read(fixture(leadIn: true).store), b = try await read(fixture(leadIn: false).store)
        XCTAssertFalse(b.hrv.isEmpty)
        XCTAssertEqual(a.hrv, b.hrv, "nightly HRV")
        XCTAssertEqual(a.bedtimes, b.bedtimes, "bedtime regularity reads the same in-bed starts")
    }
}
