import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Possible illness signs, through the real store: `HealthNotificationCenter.illnessNight` reads the
// latest night and its device's prior nights, reduces the month of HR / HRV / respiratory-rate rows
// off the main actor, and `tempFeverCandidates` routes the verdict. Every value here is synthetic.

@MainActor
final class IllnessSignalsWiringTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let strap = SyncDeviceID(rawValue: "zeppos:5B1E4C2A-0000-4000-8000-0000000111A5")
    private let calendar = Calendar.current
    private var defaults: UserDefaults!
    private let suite = "IllnessSignalsWiringTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
    }

    /// One strap night, in bed 23:00 → 07:00 ending on `day(daysAgo)`, with a reading of each vital
    /// every 5 minutes at the given level.
    private func saveNight(_ store: LocalStore, daysAgo: Int, skinTempC: Double,
                           hr: Double, hrv: Double, rr: Double) throws {
        let start = day(daysAgo).addingTimeInterval(-3600), end = day(daysAgo).addingTimeInterval(7 * 3600)
        let segments = [SleepSegment(start: start, end: end, stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        extras.skinTempC = skinTempC
        _ = try store.saveSleepSummary(SleepStaging.summary(segments),
                                   night: SleepNightKey.night(inBedStart: start, inBedEnd: end),
                                   inBedStart: start, inBedEnd: end, sleepOnset: start, sleepWake: end,
                                   extras: extras, device: strap)
        for i in 0..<96 {
            let t = start.addingTimeInterval(Double(i) * 300 + 30)
            let wobble = Double(i % 3) - 1   // −1, 0, +1: a mean-preserving texture
            for (kind, value) in [(MetricKind.heartRate, hr + wobble), (.hrvSDNN, hrv + wobble),
                                  (.respiratoryRate, rr)] {
                store.context.insert(StoredSample(kindRaw: kind.rawValue, start: t, end: t, value: value,
                                                  deviceID: strap.rawValue))
            }
        }
        try store.context.save()
    }

    /// Five ordinary strap nights, then last night as given.
    private func fixture(lastNight skinTempC: Double, hr: Double, hrv: Double, rr: Double) throws -> LocalStore {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast)]))
        let store = try makeStore()
        for k in 1...5 {
            try saveNight(store, daysAgo: k, skinTempC: 34.0 + Double(k % 2) * 0.1, hr: 58, hrv: 60, rr: 14)
        }
        try saveNight(store, daysAgo: 0, skinTempC: skinTempC, hr: hr, hrv: hrv, rr: rr)
        return store
    }

    func testHeartRateAndHRVAloneRaiseIllnessSigns() async throws {
        let store = try fixture(lastNight: 34.1, hr: 66, hrv: 42, rr: 14)
        let center = HealthNotificationCenter()
        let illnessRead = await center.illnessNight(store: store, lastNotifiedNight: [:],
                                                              defaults: defaults)
        let illness = try XCTUnwrap(illnessRead)
        XCTAssertEqual(illness.night, day(0))
        XCTAssertTrue(illness.assessment.isSuspected)
        XCTAssertEqual(illness.assessment.signals, [.restingHRRise, .hrvDrop])
        XCTAssertEqual(center.tempFeverCandidates(store: store, restingHRDaily: [], illness: illness).candidates,
                       [.illnessSigns])
        XCTAssertNil(defaults.string(forKey: HealthNotificationCenter.illnessQuietNightKey),
                     "a suspected night is never cached as quiet")
    }

    /// The cold-night shape: warm, faster, lower HRV. One alert, not "skin temperature" AND "illness".
    func testIllnessStandsInForTheTemperatureAlertItNames() async throws {
        let store = try fixture(lastNight: 35.2, hr: 66, hrv: 42, rr: 14)
        let center = HealthNotificationCenter()
        XCTAssertEqual(center.tempFeverCandidates(store: store, restingHRDaily: []).candidates,
                       [.skinTempRise, .skinTempFluctuationRise], "the shipped routing, without the check")
        let illnessRead = await center.illnessNight(store: store, lastNotifiedNight: [:],
                                                              defaults: defaults)
        let illness = try XCTUnwrap(illnessRead)
        XCTAssertEqual(illness.assessment.signals, [.skinTempRise, .restingHRRise, .hrvDrop])
        XCTAssertEqual(center.tempFeverCandidates(store: store, restingHRDaily: [], illness: illness).candidates,
                       [.illnessSigns])
        let copy = HealthNotificationCenter.copy(for: .illnessSigns, hit: nil, illness: illness.assessment)
        XCTAssertEqual(copy.title, "Possible illness signs")
        XCTAssertTrue(copy.body.contains("sleeping HR +8 bpm"), copy.body)
    }

    func testAnOrdinaryNightIsQuietAndCachedUntilRestaged() async throws {
        let store = try fixture(lastNight: 34.1, hr: 59, hrv: 58, rr: 14)
        let center = HealthNotificationCenter()
        let firstRead = await center.illnessNight(store: store, lastNotifiedNight: [:], defaults: defaults)
        let first = try XCTUnwrap(firstRead)
        XCTAssertFalse(first.assessment.isSuspected)
        XCTAssertEqual(first.assessment.readings.count, 4, "every vital had a baseline")
        XCTAssertNotNil(defaults.string(forKey: HealthNotificationCenter.illnessQuietNightKey))
        let again = await center.illnessNight(store: store, lastNotifiedNight: [:], defaults: defaults)
        XCTAssertNil(again, "the same night at the same updatedAt is not re-read")
    }

    func testANotifiedNightIsNotReRead() async throws {
        let store = try fixture(lastNight: 34.1, hr: 66, hrv: 42, rr: 14)
        let key = TempFeverNotifications.dayKey(for: day(0))
        let out = await HealthNotificationCenter().illnessNight(store: store,
                                                                lastNotifiedNight: [.illnessSigns: key],
                                                                defaults: defaults)
        XCTAssertNil(out)
    }

    /// Decision 29: the ring's earlier nights are not the strap's usual. With only the strap's first
    /// night after fourteen ring nights there is no baseline, so nothing is suspected.
    func testAnotherDevicesNightsAreNotTheBaseline() async throws {
        let store = try makeStore()
        for k in 1...5 {
            let start = day(k).addingTimeInterval(-3600), end = day(k).addingTimeInterval(7 * 3600)
            let segments = [SleepSegment(start: start, end: end, stage: .asleepCore)]
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            extras.skinTempC = 33.0
            _ = try store.saveSleepSummary(SleepStaging.summary(segments),
                                       night: SleepNightKey.night(inBedStart: start, inBedEnd: end),
                                       inBedStart: start, inBedEnd: end, sleepOnset: start, sleepWake: end,
                                       extras: extras, device: .ringConn)
            for i in 0..<96 {
                let t = start.addingTimeInterval(Double(i) * 300 + 30)
                for (kind, value) in [(MetricKind.heartRate, 50.0), (.hrvSDNN, 90.0), (.respiratoryRate, 12.0)] {
                    store.context.insert(StoredSample(kindRaw: kind.rawValue, start: t, end: t, value: value))
                }
            }
        }
        try store.context.save()
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS,
                                                               since: day(0).addingTimeInterval(-3 * 3600))]))
        try saveNight(store, daysAgo: 0, skinTempC: 34.6, hr: 66, hrv: 42, rr: 15)
        let outRead = await HealthNotificationCenter().illnessNight(store: store, lastNotifiedNight: [:],
                                                                               defaults: defaults)
        let out = try XCTUnwrap(outRead)
        XCTAssertTrue(out.assessment.readings.isEmpty)
        XCTAssertFalse(out.assessment.isSuspected)
    }
}
