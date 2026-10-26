import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 77 (#328): a strap night's in-bed lead-in, derived at store time from the strap's own STORED
// heart rate and steps, through the production sync path (`HelioSession` → `HelioStoreSink`). Every
// key, reading, id and time is synthetic: round minutes, round beats per minute, round step counts.

// MARK: - Fixtures

private let lMidnight: TimeInterval = 1_789_862_400          // 2026-09-20T00:00:00Z
private let lNow = Date(timeIntervalSince1970: lMidnight + 12 * 3600)
private let lKeyHex = "00112233445566778899aabbccddeeff"
/// Local hour `h` of `lNow`'s day (negative: the evening before), in the zone current at the call.
private func hour(_ h: Double) -> Date { Calendar.current.startOfDay(for: lNow).addingTimeInterval(h * 3600) }
private func minutes(_ m: Double) -> TimeInterval { m * 60 }

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// Stage bytes (ZEPP_PROTOCOL.md §6.6): light, deep, awake, REM.
private let light: UInt8 = 0x04, deep: UInt8 = 0x05, awake: UInt8 = 0x07, rem: UInt8 = 0x08

/// One strap sleep session record over local hours of `hour(0)`'s day (minute fields from the previous
/// local midnight; a stage's end minute inclusive, decision 70e).
private func session(_ stages: [(Double, Double, UInt8)]) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    func minute(_ h: Double) -> UInt16 { UInt16(((h + 24) * 60).rounded()) }
    let midnight = UInt32(hour(0).timeIntervalSince1970)
    put(le32(midnight), at: 0x000)
    put(le32(midnight), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(minute(stages.first!.0)), at: 0x00A)
    put(le16(minute(stages.last!.1)), at: 0x00C)
    r[0x016] = 81
    r[0x054] = UInt8(stages.count)
    for (i, stage) in stages.enumerated() { put(le16(minute(stage.0)) + le16(minute(stage.1) - 1) + [stage.2], at: 0x056 + 5 * i) }
    return r
}

/// The owner's shape: in the record 23:00–07:00 (light, deep, REM, a short wake, light).
private let night: [(Double, Double, UInt8)] = [(-1, 1, light), (1, 2, deep), (2, 3, rem), (3, 3.25, awake), (3.25, 7, light)]
/// Two sessions 30 min apart, stitched (28f): 23:00–02:00 and 02:30–07:00.
private let firstPart: [(Double, Double, UInt8)] = [(-1, 0.5, light), (0.5, 2, deep)]
private let secondPart: [(Double, Double, UInt8)] = [(2.5, 4, light), (4, 7, rem)]
/// A daytime session, 14:00–15:00 the day before: a nap.
private let afternoon: [(Double, Double, UInt8)] = [(-10, -9, light)]

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

@MainActor
private final class LeadInTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }
    func has(_ c: ZeppCharacteristic) -> Bool { available.contains(c) }
    func canNotify(_ c: ZeppCharacteristic) -> Bool {
        has(c) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(c)
    }
    func write(_ write: ZeppWrite) {
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ c: ZeppCharacteristic, enabled: Bool) { inbox.append((c, nil, enabled)) }
    func read(_ c: ZeppCharacteristic) {
        switch c {
        case .hardwareRevision: inbox.append((c, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((c, [64], false))
        default: break
        }
    }
    func drain() {
        var n = 0
        while !inbox.isEmpty, n < 1_000_000 {
            n += 1
            let (c, bytes, enabled) = inbox.removeFirst()
            if let bytes { session?.received(c, bytes) } else { session?.notificationStateChanged(c, enabled: enabled, failed: false) }
        }
    }
}

@MainActor
private final class LeadInKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(lKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class StrapInBedLeadInTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = lNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D077"
    private var savedZone = NSTimeZone.default

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        clearMirrors()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        clearMirrors()
        NSTimeZone.default = savedZone
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func clearMirrors() {
        for day in -3...2 {
            let key = Calendar.current.startOfDay(for: hour(Double(day) * 24))
            UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(key.timeIntervalSince1970)")
            StrapNightDeclinedOverlay.clear(storedNight: key)
        }
    }

    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    /// One strap sync at `now` delivering each of `sessions` as its own record, and the activity minutes
    /// `activity` (spans of local hours: kind, heart rate, steps per minute), through the production path.
    private func sync(_ sessions: [[(Double, Double, UInt8)]], activity: [(Double, Double, UInt8, UInt8, UInt8)] = [],
                      at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(lKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = services
        device.deviceInfoReply = deviceInfoReply
        device.dataPacketLength = 200
        device.fetchData = [.sleepSession: (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(session))]
        if let first = activity.first {
            let bytes = activity.flatMap { span in
                (0..<Int(((span.1 - span.0) * 60).rounded())).flatMap { _ in [span.2, 0x08, span.4, span.3, 0, 0, 0, 0] as [UInt8] }
            }
            device.fetchData[.activity] = (stamp(hour(first.0).timeIntervalSince1970), bytes)
        }
        let transport = LeadInTransport(device: device)
        let keys = LeadInKeys()
        let helio = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                 sink: HelioStoreSink(store: store), findState: HelioFindState(),
                                 clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = helio
        helio.start()
        transport.drain()
        let result = try XCTUnwrap(helio.lastSyncResult)
        XCTAssertEqual(result.interrupted, false)
        return result
    }

    /// The strap's heart rate, one reading a minute over local hours `from ..< to`, inserted as stored
    /// rows of its timeline (`device`: another device's id instead).
    private func storeHeartRate(_ from: Double, _ to: Double, bpm: Double = 58, device: SyncDeviceID? = nil,
                                store: LocalStore) throws {
        let id = (device ?? timeline).rawValue
        for t in stride(from: hour(from).timeIntervalSince1970, to: hour(to).timeIntervalSince1970, by: 60) {
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: Date(timeIntervalSince1970: t),
                                              end: Date(timeIntervalSince1970: t), value: bpm, deviceID: id))
        }
        try store.context.save()
    }

    /// The strap's per-minute steps at local hour `at`, through its own step writer.
    private func storeSteps(at h: Double, _ count: Int, store: LocalStore) throws {
        try store.ingestHelioStepMinutes([QuantitySample(kind: .steps, start: hour(h), end: hour(h).addingTimeInterval(60),
                                                         value: Double(count))], device: timeline, now: hour(12))
    }

    private func rows(_ store: LocalStore) throws -> [StoredSleepSummary] {
        try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.inBedStart)]))
    }

    private func window(_ row: StoredSleepSummary) -> DateInterval { DateInterval(start: row.inBedStart, end: row.inBedEnd) }

    private func hypnogram(_ store: LocalStore) throws -> [SleepSegment] {
        SleepHypnogramCodec.decode(try XCTUnwrap(try rows(store).first).hypnogramData)
    }

    private var record: DateInterval { DateInterval(start: hour(-1), end: hour(7)) }

    private func leadIn(from h: Double) -> DateInterval { DateInterval(start: hour(h), end: hour(-1)) }

    /// The night stored and handed to the flush with no heart rate before it: what master stores.
    private func plainNight() throws -> HelioSleepSelection.Night {
        let reference = try makeStore()
        try storeHeartRate(-1, 7, store: reference)
        return try XCTUnwrap(try sync([night], at: hour(8), store: reference).nights.first)
    }

    /// What `mirrorSettledNight` records once its write succeeded: signature and the union span.
    @discardableResult
    private func recordWrite(_ segments: [SleepSegment], store: LocalStore) throws -> DateInterval {
        let start = segments.map(\.start).min()!, end = segments.map(\.end).max()!
        let row = try store.sleepSummaryOverlapping(start: start, end: end)
        let key = row?.night ?? SleepNightKey.night(inBedStart: start, inBedEnd: end)
        let last = store.mirroredNight(night: key)
        let lo = min(start, last?.spanStart ?? start, row?.inBedStart ?? start)
        let hi = max(end, last?.spanEnd ?? end, row?.inBedEnd ?? end)
        store.setMirroredNight(night: key, signature: HealthKitWriter.sleepSignature(segments), spanStart: lo, spanEnd: hi)
        return DateInterval(start: lo, end: hi)
    }

    /// One strap flush at `now`, as `HelioConnection.flushStrap` hands the writer its nights (the sync's,
    /// then the backstop's): each ready night to `mirrorSettledNight`; a write is recorded. The spans written.
    private func flush(_ nights: [[SleepSegment]], at now: Date, store: LocalStore) async throws -> [DateInterval] {
        var written: [DateInterval] = []
        for segments in HelioConnection.strapNights(nights, store: store, timeline: timeline, now: now)
        where SleepHealthGate.isReadyToWrite(latestSegmentEnd: segments.map(\.end).max(), now: now, finalized: false) {
            let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: segments)
            if case .declined = outcome { store.noteStrapNightDeclined(segments) }
            switch outcome {
            case .unchanged, .declined: continue
            case .wrote, .failed: break
            }
            try recordWrite(segments, store: store)
            written.append(DateInterval(start: segments.map(\.start).min()!, end: segments.map(\.end).max()!))
        }
        return written
    }

    // MARK: 77a: the walk back over the stored rows

    func testWornStillAndAtTheSleepingLevelTheNightGetsItsLeadIn() throws {
        let store = try makeStore()
        try storeHeartRate(-1 - 40.0 / 60, 7, store: store)
        let result = try sync([night], at: hour(8), store: store)
        let stored = try XCTUnwrap(result.nights.first)
        XCTAssertEqual(stored.leadIn, leadIn(from: -1 - 40.0 / 60), "40 minutes")
        XCTAssertEqual(stored.window, DateInterval(start: hour(-1 - 40.0 / 60), end: hour(7)), "the window moves with it")
        XCTAssertEqual(try rows(store).map(window), [stored.window], "the row's in-bed start is the lead-in's")
        let plain = try plainNight()
        XCTAssertEqual(stored.withoutLeadIn, plain, "stages untouched: without it, the night as before")
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(row.asleepMin, 465, "asleep time unchanged")
        XCTAssertEqual(row.sleepOnset, hour(-1), "sleep onset unchanged")
        XCTAssertEqual(row.night, SleepNightKey.night(inBedStart: record.start, inBedEnd: record.end), "same key")
    }

    func testAStepBurstStoredForTheStrapEndsTheLeadIn() throws {
        let store = try makeStore()
        try storeHeartRate(-1 - 40.0 / 60, 7, store: store)
        try storeSteps(at: -1 - 26.0 / 60, 30, store: store)
        XCTAssertEqual(try sync([night], at: hour(8), store: store).nights.first?.leadIn, leadIn(from: -1 - 25.0 / 60))
    }

    func testAHeartRateWellAboveTheSleepingLevelEndsTheLeadIn() throws {
        let store = try makeStore()
        try storeHeartRate(-2, -1 - 25.0 / 60, bpm: 95, store: store)
        try storeHeartRate(-1 - 25.0 / 60, 7, store: store)
        XCTAssertEqual(try sync([night], at: hour(8), store: store).nights.first?.leadIn, leadIn(from: -1 - 25.0 / 60))
    }

    func testAFiveMinuteHoleIsBridgedAndASixMinuteHoleEndsTheLeadIn() throws {
        let bridged = try makeStore()
        try storeHeartRate(-1 - 40.0 / 60, -1 - 25.0 / 60, store: bridged)
        try storeHeartRate(-1 - 20.0 / 60, 7, store: bridged)
        XCTAssertEqual(try sync([night], at: hour(8), store: bridged).nights.first?.leadIn, leadIn(from: -1 - 40.0 / 60))
        let ended = try makeStore()
        try storeHeartRate(-1 - 40.0 / 60, -1 - 26.0 / 60, store: ended)
        try storeHeartRate(-1 - 20.0 / 60, 7, store: ended)
        XCTAssertEqual(try sync([night], at: hour(8), store: ended).nights.first?.leadIn, leadIn(from: -1 - 20.0 / 60))
    }

    func testUnwornThereIsNoLeadIn() throws {
        let store = try makeStore()
        try storeHeartRate(-1, 7, store: store)
        let result = try sync([night], at: hour(8), store: store)
        XCTAssertNil(result.nights.first?.leadIn)
        XCTAssertEqual(try rows(store).map(window), [record])
    }

    func testAShortLeadInIsNotAddedAndALongOneIsCapped() throws {
        let short = try makeStore()
        try storeHeartRate(-1 - 4.0 / 60, 7, store: short)
        XCTAssertNil(try sync([night], at: hour(8), store: short).nights.first?.leadIn, "under the minimum: nothing")
        let long = try makeStore()
        try storeHeartRate(-5, 7, store: long)
        XCTAssertEqual(try sync([night], at: hour(8), store: long).nights.first?.leadIn,
                       DateInterval(start: hour(-1).addingTimeInterval(-HelioInBedLeadIn.maxLength), end: hour(-1)), "capped")
    }

    func testAnotherDevicesHeartRateIsNoLeadIn() throws {
        let store = try makeStore()
        try storeHeartRate(-2, -1, device: .ringConn, store: store)
        try storeHeartRate(-1, 7, store: store)
        XCTAssertNil(try sync([night], at: hour(8), store: store).nights.first?.leadIn)
    }

    // MARK: 77c: never over another sleep, never in the other device's time

    func testAStoredNapEndingTwentyMinutesBeforeClampsTheLeadIn() throws {
        let store = try makeStore()
        try store.saveNap(start: hour(-2), end: hour(-1 - 20.0 / 60), asleepMin: 40, isLongNap: false, family: .zeppOS)
        try storeHeartRate(-3, 7, store: store)
        XCTAssertEqual(try sync([night], at: hour(8), store: store).nights.first?.leadIn, leadIn(from: -1 - 20.0 / 60))
    }

    func testTheOtherDevicesNightEndingTwentyMinutesBeforeClampsTheLeadIn() throws {
        let store = try makeStore()
        // The ring's evening sleep, stored while the ring owned the time; the strap owns it all now.
        ownership.install(DeviceOwnershipLog())
        let ring = [SleepSegment(start: hour(-5), end: hour(-1 - 20.0 / 60), stage: .inBed),
                    SleepSegment(start: hour(-5), end: hour(-1 - 20.0 / 60), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = ring
        _ = try store.saveSleepSummary(SleepStaging.summary(ring), night: hour(-24), inBedStart: hour(-5), inBedEnd: hour(-1 - 20.0 / 60),
                                       extras: extras)
        XCTAssertEqual(try rows(store).count, 1)
        ownership.install(.strapOwnsAllTime)
        try storeHeartRate(-3, 7, store: store)
        let result = try sync([night], at: hour(8), store: store)
        XCTAssertEqual(result.nights.first?.leadIn, leadIn(from: -1 - 20.0 / 60))
    }

    func testTheRingOwnsTheTimeBeforeTheSwitchSoTheLeadInStartsAtTheSwitch() throws {
        let store = try makeStore()
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(-1 - 30.0 / 60))]))
        // Strap-tagged rows before the switch (none reach the store through the sink; inserted here to pin
        // that the walk never reads them, whatever the store holds).
        try storeHeartRate(-3, 7, store: store)
        XCTAssertEqual(try sync([night], at: hour(8), store: store).nights.first?.leadIn, leadIn(from: -1 - 30.0 / 60))
    }

    // MARK: 77e: the night key

    func testALeadInCrossingMidnightKeepsTheNightKey() throws {
        let store = try makeStore()
        let afterMidnight: [(Double, Double, UInt8)] = [(10.0 / 60, 3, light), (3, 7, deep)]
        try storeHeartRate(-0.5, 7, store: store)
        let stored = try XCTUnwrap(try sync([afterMidnight], at: hour(8), store: store).nights.first)
        XCTAssertEqual(stored.leadIn, DateInterval(start: hour(-0.5), end: hour(10.0 / 60)))
        XCTAssertNotEqual(Calendar.current.startOfDay(for: stored.window.start), Calendar.current.startOfDay(for: hour(10.0 / 60)),
                          "the lead-in starts the evening before")
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(row.night, SleepNightKey.night(inBedStart: hour(10.0 / 60), inBedEnd: hour(7)), "the key of the night itself")
        XCTAssertEqual(row.night, Calendar.current.startOfDay(for: hour(7)))
    }

    // MARK: 77c: after the stitch

    func testAStitchedNightGetsItsLeadInBeforeTheFirstFragmentOnlyAndKeepsItsFill() throws {
        let store = try makeStore()
        try storeHeartRate(-2, 8, store: store)
        let stored = try XCTUnwrap(try sync([firstPart, secondPart], at: hour(8), store: store).nights.first)
        XCTAssertEqual(stored.leadIn, leadIn(from: -2))
        XCTAssertEqual(HelioSleepSelection.awakeFillRuns(in: stored.withoutLeadIn.segments), [DateInterval(start: hour(2), end: hour(2.5))],
                       "the 74 fill, as before")
        XCTAssertEqual(stored.sleepSpans, [DateInterval(start: hour(-1), end: hour(2)), DateInterval(start: hour(2.5), end: hour(7))])
        let reference = try makeStore()
        try storeHeartRate(-1, 8, store: reference)
        let plain = try XCTUnwrap(try sync([firstPart, secondPart], at: hour(8), store: reference).nights.first)
        XCTAssertEqual(stored.withoutLeadIn, plain)
        // The rebuild for Health from the stored hypnogram keeps it (77b): the 50b backstop's segments.
        XCTAssertEqual(store.helioAwakeFilled(try hypnogram(store), window: stored.window, device: timeline), stored.segments)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(11)), [stored.segments])
    }

    func testTheLeadInNeverChangesWhichSleepsJoin() throws {
        // A doze 21:00–21:55, 65 minutes before the record: not stitched, a nap, with or without the lead-in.
        let store = try makeStore()
        try storeHeartRate(-4, 8, store: store)
        let doze: [(Double, Double, UInt8)] = [(-3, -2 + 55.0 / 60 - 1, light)]
        let result = try sync([doze, night], at: hour(12), store: store)
        XCTAssertEqual(result.nights.map(\.windowWithoutLeadIn), [record], "the doze isn't joined")
        XCTAssertEqual(result.nights.first?.leadIn, DateInterval(start: hour(-2 + 55.0 / 60 - 1), end: hour(-1)),
                       "clamped to the doze's end")
        let naps = try store.context.fetch(FetchDescriptor<StoredNap>()).map { DateInterval(start: $0.start, end: $0.end) }
        XCTAssertEqual(naps, [DateInterval(start: hour(-3), end: hour(-2 + 55.0 / 60 - 1))], "and is still a nap")
    }

    // MARK: 77b: from the store, never the sync's fetched minutes

    func testAReDeliveryThatFetchesFewerMinutesDerivesTheSameLeadIn() throws {
        let store = try makeStore()
        let worn: [(Double, Double, UInt8, UInt8, UInt8)] = [(-2, -1, 0x01, 58, 0), (-1, 7, ZeppActivityMinute.kindSleep, 58, 0)]
        let first = try sync([night], activity: worn, at: hour(7.5), store: store)
        XCTAssertEqual(first.nights.first?.leadIn, leadIn(from: -2))
        let again = try sync([night], at: hour(8), store: store)
        XCTAssertEqual(again.nights.first?.leadIn, leadIn(from: -2), "the same lead-in with nothing fetched")
        XCTAssertEqual(try rows(store).map(window), [DateInterval(start: hour(-2), end: hour(7))])
    }

    func testHeartRateStoredBeforeTheSyncGivesTheLeadInWhateverTheSyncFetched() throws {
        let store = try makeStore()
        try storeHeartRate(-2, 7, store: store)
        let result = try sync([night], activity: [(-1, 7, ZeppActivityMinute.kindSleep, 58, 0)], at: hour(8), store: store)
        XCTAssertEqual(result.nights.first?.leadIn, leadIn(from: -2))
    }

    // MARK: 77f: Health, forward-only

    func testMoreHeartRateStoredBeforeTheFirstWriteWidensTheStoredNightAndItIsWrittenOnce() async throws {
        let store = try makeStore()
        try storeHeartRate(-1, 7, store: store)
        let first = try sync([night], at: hour(7 + 10.0 / 60), store: store)
        XCTAssertNil(first.nights.first?.leadIn)
        let flushed1 = try await flush(first.nights.map(\.segments), at: hour(7 + 10.0 / 60), store: store)
        XCTAssertEqual(flushed1, [], "inside the margin")
        try storeHeartRate(-2, -1, store: store)
        let second = try sync([night], at: hour(8), store: store)
        XCTAssertEqual(second.nights.first?.leadIn, leadIn(from: -2))
        XCTAssertEqual(try rows(store).map(window), [DateInterval(start: hour(-2), end: hour(7))], "the stored row follows")
        let written = try await flush(second.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(written, [DateInterval(start: hour(-2), end: hour(7))], "written once, with the lead-in")
        let flushed2 = try await flush(second.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(flushed2, [], "and only once")

        // After the write, a step burst stored inside the written lead-in would shorten a new derivation:
        // 28f keeps that out (the 28f `continue` comes before `saveHelioNight`), and the stored row stays
        // the night Health holds.
        try storeSteps(at: -1.5, 30, store: store)
        XCTAssertEqual(store.helioLeadInStart(second.nights[0].withoutLeadIn, device: timeline), hour(-1.5).addingTimeInterval(60))
        let third = try sync([night], at: hour(9), store: store)
        XCTAssertEqual(third.nights, [], "kept out")
        XCTAssertEqual(try rows(store).map(window), [DateInterval(start: hour(-2), end: hour(7))], "the row agrees with Health")
        let flushed3 = try await flush(third.nights.map(\.segments), at: hour(9), store: store)
        XCTAssertEqual(flushed3, [])
    }

    func testANightAlreadyInHealthIsNeverRewrittenForALeadIn() async throws {
        let store = try makeStore()
        try storeHeartRate(-1, 7, store: store)
        let first = try sync([night], at: hour(8), store: store)
        let flushed4 = try await flush(first.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(flushed4, [record], "written without a lead-in")
        let writtenHypnogram = try hypnogram(store)
        let mirror = store.mirroredNight(night: try XCTUnwrap(try rows(store).first).night)
            .map { "\($0.signature) \($0.spanStart) \($0.spanEnd)" }

        try storeHeartRate(-2, -1, store: store)
        let second = try sync([night], at: hour(9), store: store)
        XCTAssertEqual(second.nights.map(\.leadIn), [nil], "re-delivered as written, no lead-in")
        XCTAssertEqual(try rows(store).map(window), [record], "the row stays the night Health holds")
        XCTAssertEqual(try hypnogram(store), writtenHypnogram)
        let flushed5 = try await flush(second.nights.map(\.segments), at: hour(9), store: store)
        XCTAssertEqual(flushed5, [], "nothing rewritten")
        XCTAssertEqual(store.mirroredNight(night: try XCTUnwrap(try rows(store).first).night)
            .map { "\($0.signature) \($0.spanStart) \($0.spanEnd)" }, mirror, "the mirror record untouched")
    }

    func testAnExtensionOfAWrittenNightTakesItsLeadInAlong() async throws {
        let store = try makeStore()
        try storeHeartRate(-2, 9, store: store)
        let early: [(Double, Double, UInt8)] = [(-1, 1, light), (1, 3, deep)]
        let first = try sync([early], at: hour(3.5), store: store)
        let flushed6 = try await flush(first.nights.map(\.segments), at: hour(3.5), store: store)
        XCTAssertEqual(flushed6, [DateInterval(start: hour(-2), end: hour(3))])
        let final = try sync([night], at: hour(8), store: store)
        XCTAssertEqual(final.nights.first?.leadIn, leadIn(from: -2), "the same stored lead-in")
        let flushed7 = try await flush(final.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(flushed7, [DateInterval(start: hour(-2), end: hour(7))],
                       "rewritten once as an extension (58b), never shortened")
    }

    func testAManuallyEditedNightIsUntouched() throws {
        let store = try makeStore()
        try storeHeartRate(-1, 7, store: store)
        _ = try sync([night], at: hour(8), store: store)
        let row = try XCTUnwrap(try rows(store).first)
        row.isManuallyEdited = true
        row.editedInBedStart = hour(-1)
        row.editedInBedEnd = hour(7)
        try store.context.save()
        let before = row.hypnogramData
        try storeHeartRate(-2, -1, store: store)
        let again = try sync([night], at: hour(9), store: store)
        XCTAssertEqual(again.nights, [])
        XCTAssertEqual(try rows(store).map(window), [record])
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).hypnogramData, before)
    }

    // MARK: 77g: naps and the ring

    func testANapGetsNoLeadIn() throws {
        let store = try makeStore()
        try storeHeartRate(-12, 8, store: store)
        _ = try sync([afternoon, night], at: hour(12), store: store)
        let naps = try store.context.fetch(FetchDescriptor<StoredNap>())
        XCTAssertEqual(naps.map { DateInterval(start: $0.start, end: $0.end) }, [DateInterval(start: hour(-10), end: hour(-9))])
        XCTAssertNil(HelioSleepSelection.leadIn(in: naps.first?.stagedSegments ?? []))
    }

    func testRingOnlyNothingIsStoredAndARingNightsWindowIsReadAsBefore() throws {
        let store = try makeStore()
        ownership.install(DeviceOwnershipLog())
        try storeHeartRate(-2, 7, store: store)
        XCTAssertEqual(try sync([night], at: hour(8), store: store).nights, [])
        XCTAssertEqual(try rows(store), [])
        let ring = [SleepSegment(start: hour(-1.5), end: hour(7), stage: .inBed),
                    SleepSegment(start: hour(-1.5), end: hour(-1), stage: .awake),
                    SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = ring
        _ = try store.saveSleepSummary(SleepStaging.summary(ring), night: SleepNightKey.night(inBedStart: hour(-1.5), inBedEnd: hour(7)),
                                       inBedStart: hour(-1.5), inBedEnd: hour(7), extras: extras)
        XCTAssertEqual(store.storedNightWindows(from: hour(-2), to: hour(8)), [DateInterval(start: hour(-1.5), end: hour(7))])
    }

    // MARK: 77d: the lead-in is no sleep

    func testTheSleepReadersAndTheScoresInputsAreTheNightsWithoutTheLeadIn() throws {
        // In the lead-in, skin temperature and HRV far from the night's: none of it may reach the night.
        func seed(_ store: LocalStore, leadIn: Bool) throws {
            try storeHeartRate(leadIn ? -2 : -1, 7, store: store)
            var samples: [StoredSample] = []
            for t in stride(from: hour(-2).timeIntervalSince1970, to: hour(7).timeIntervalSince1970, by: 60) {
                let inLeadIn = t < hour(-1).timeIntervalSince1970
                samples.append(StoredSample(kindRaw: MetricKind.temperature.rawValue, start: Date(timeIntervalSince1970: t),
                                            end: Date(timeIntervalSince1970: t), value: inLeadIn ? 31 : 34.5, deviceID: timeline.rawValue))
                if Int(t) % 300 == 0 {
                    samples.append(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: Date(timeIntervalSince1970: t),
                                                end: Date(timeIntervalSince1970: t), value: inLeadIn ? 15 : 55, deviceID: timeline.rawValue))
                }
            }
            samples.forEach(store.context.insert)
            try store.context.save()
        }
        let branch = try makeStore()
        try seed(branch, leadIn: true)
        let withLeadIn = try XCTUnwrap(try sync([night], at: hour(8), store: branch).nights.first)
        XCTAssertEqual(withLeadIn.leadIn, leadIn(from: -2))
        let master = try makeStore()
        try seed(master, leadIn: false)
        let without = try XCTUnwrap(try sync([night], at: hour(8), store: master).nights.first)
        XCTAssertNil(without.leadIn)

        XCTAssertEqual(withLeadIn.sleepSpans, without.sleepSpans, "sleepSpans: the fragment only")
        let b = try XCTUnwrap(try rows(branch).first), m = try XCTUnwrap(try rows(master).first)
        XCTAssertEqual(b.skinTempC, m.skinTempC, "the nightly temperature verdict")
        XCTAssertEqual(b.skinTempC, 34.5, accuracy: 0.001)
        XCTAssertEqual(b.stressScore, m.stressScore, "overnight RMSSD")
        XCTAssertGreaterThan(b.stressScore, 0)
        XCTAssertEqual(b.asleepMin, m.asleepMin, "asleep time")
        XCTAssertEqual(b.sleepOnset, m.sleepOnset)
        XCTAssertEqual(b.sleepWake, m.sleepWake)
        XCTAssertEqual(b.night, m.night)
        XCTAssertEqual(b.awakeMin, m.awakeMin + 60, "awake time grows by the lead-in")
        XCTAssertEqual(b.inBedStart, hour(-2))

        // The score's inputs, as `applyHelioNightScores` gathers them: the resting heart rate is the night's.
        let hr = (0..<(8 * 60)).map { HRSample(bpm: 58, start: hour(-1).addingTimeInterval(TimeInterval($0) * 60),
                                               end: hour(-1).addingTimeInterval(TimeInterval($0 + 1) * 60)) }
        let branchScore = StoredNightScore.scores(.init(segments: withLeadIn.segments, heartRate: hr))
        let masterScore = StoredNightScore.scores(.init(segments: without.segments, heartRate: hr))
        XCTAssertEqual(branchScore.restingHR, masterScore.restingHR, "resting heart rate")
        let bs = SleepStaging.summary(withLeadIn.segments), ms = SleepStaging.summary(without.segments)
        XCTAssertEqual(bs.totalAsleep, ms.totalAsleep)
        XCTAssertEqual(bs.inBed, ms.inBed + 3600, "time in bed grows by the lead-in")
        XCTAssertLessThan(bs.totalAsleep / bs.inBed, ms.totalAsleep / ms.inBed, "efficiency drops")
        XCTAssertLessThanOrEqual(b.sleepScore, m.sleepScore, "the score can only drop, through efficiency")
        print("LEADIN-REPORT master: inBed=\(ms.inBed / 60) asleep=\(ms.totalAsleep / 60) awake=\(ms.awake / 60) "
              + "efficiency=\(ms.totalAsleep / ms.inBed) sleepScore=\(m.sleepScore) stressScore=\(m.stressScore) "
              + "restingHR=\(masterScore.restingHR ?? -1) skinTempC=\(m.skinTempC)")
        print("LEADIN-REPORT branch: inBed=\(bs.inBed / 60) asleep=\(bs.totalAsleep / 60) awake=\(bs.awake / 60) "
              + "efficiency=\(bs.totalAsleep / bs.inBed) sleepScore=\(b.sleepScore) stressScore=\(b.stressScore) "
              + "restingHR=\(branchScore.restingHR ?? -1) skinTempC=\(b.skinTempC)")
    }

    // MARK: 77f: what the writer sends to Apple Health

    func testHealthGetsAnAwakeRunBeforeTheFirstStageAndAnInBedSpanFromTheLeadInStart() throws {
        let store = try makeStore()
        try storeHeartRate(-2, 7, store: store)
        let stored = try XCTUnwrap(try sync([night], at: hour(8), store: store).nights.first)
        let samples = HealthKitWriter.sleepSamples(stored.segments, device: nil, site: "test")
        let inBed = samples.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        XCTAssertEqual(inBed, [DateInterval(start: hour(-2), end: hour(-1)), record], "in bed from the lead-in start")
        XCTAssertEqual(inBed.map(\.start).min(), hour(-2))
        let awake = samples.filter { $0.value == HKCategoryValueSleepAnalysis.awake.rawValue }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        XCTAssertEqual(awake.first, DateInterval(start: hour(-2), end: hour(-1)), "an awake run before the first stage")
        let asleepStart = samples.filter {
            [HKCategoryValueSleepAnalysis.asleepCore, .asleepDeep, .asleepREM].map(\.rawValue).contains($0.value)
        }.map(\.startDate).min()
        XCTAssertEqual(asleepStart, hour(-1), "asleep from the first stage, as before")
        XCTAssertEqual(SleepStaging.totalAsleep(stored.segments), SleepStaging.totalAsleep(try plainNight().segments),
                       ".inBed never counts as asleep")
    }
}

// MARK: - Review-328 round 2

extension StrapInBedLeadInTests {
    private func mirror(_ store: LocalStore) throws -> String? {
        store.mirroredNight(night: try XCTUnwrap(try rows(store).first).night)
            .map { "\($0.signature) \($0.spanStart.timeIntervalSince1970) \($0.spanEnd.timeIntervalSince1970)" }
    }

    // MARK: S1: a re-delivery whose lead-in differs from the one written is kept out (77f, 28f)

    func testANightWrittenWithItsLeadInKeepsOutALongerOneFromHeartRateStoredLater() async throws {
        let store = try makeStore()
        try storeHeartRate(-2, 7, store: store)
        let first = try sync([night], at: hour(8), store: store)
        XCTAssertEqual(first.nights.first?.leadIn, leadIn(from: -2))
        let written = try await flush(first.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(written, [DateInterval(start: hour(-2), end: hour(7))], "written with the lead-in from 22:00")
        let (hypnogramBefore, mirrorBefore) = (try hypnogram(store), try mirror(store))

        try storeHeartRate(-3, -2, store: store)
        XCTAssertEqual(store.helioLeadInStart(first.nights[0].withoutLeadIn, device: timeline), hour(-3), "a new derivation reaches 21:00")
        let again = try sync([night], at: hour(9), store: store)
        XCTAssertEqual(again.nights, [], "kept out: a same-end, start-only widening of a written night")
        XCTAssertEqual(try rows(store).map(window), [DateInterval(start: hour(-2), end: hour(7))], "the row is the night Health holds")
        XCTAssertEqual(try hypnogram(store), hypnogramBefore)
        let rewritten = try await flush(again.nights.map(\.segments), at: hour(9), store: store)
        XCTAssertEqual(rewritten, [], "no Health write")
        XCTAssertEqual(try mirror(store), mirrorBefore)
    }

    func testANightWrittenWithoutALeadInIsKeptOutWhenTheStrapReStagesItsStartLater() async throws {
        let store = try makeStore()
        try storeHeartRate(-1, 7, store: store)
        let first = try sync([night], at: hour(8), store: store)
        let written = try await flush(first.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(written, [record], "written without a lead-in (build 88's shape)")
        let (hypnogramBefore, mirrorBefore) = (try hypnogram(store), try mirror(store))

        try storeHeartRate(-2, -1, store: store)
        // The strap re-stages the night's start 10 minutes later; the store now reaches back to 22:00.
        let restaged: [(Double, Double, UInt8)] = [(-1 + 10.0 / 60, 1, light)] + Array(night.dropFirst())
        let again = try sync([restaged], at: hour(9), store: store)
        XCTAssertEqual(again.nights, [], "kept out: neither its start nor its lead-in's is the written one")
        XCTAssertEqual(try rows(store).map(window), [record])
        XCTAssertEqual(try hypnogram(store), hypnogramBefore)
        let rewritten = try await flush(again.nights.map(\.segments), at: hour(9), store: store)
        XCTAssertEqual(rewritten, [], "no rewrite")
        XCTAssertEqual(try mirror(store), mirrorBefore)
    }

    /// Stated: a night written with a capped lead-in (21:00–23:00) that the strap later re-stages to
    /// start at 22:30 keeps what was written. The re-delivery's own lead-in would reach 20:30 (capped from
    /// 22:30), a same-end start-only change, so 28f keeps it out: the row stays 21:00–07:00 with its
    /// 23:00 stages, the extra half hour of staged sleep is not stored, and Health is not touched.
    func testACappedLeadInStaysAsWrittenWhenTheStrapReStagesItsStartEarlier() async throws {
        let store = try makeStore()
        try storeHeartRate(-5, 7, store: store)
        let first = try sync([night], at: hour(8), store: store)
        let capped = DateInterval(start: hour(-1).addingTimeInterval(-HelioInBedLeadIn.maxLength), end: hour(-1))
        XCTAssertEqual(first.nights.first?.leadIn, capped)
        let written = try await flush(first.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(written, [DateInterval(start: capped.start, end: hour(7))])
        let (hypnogramBefore, mirrorBefore) = (try hypnogram(store), try mirror(store))
        let asleepBefore = try XCTUnwrap(try rows(store).first).asleepMin

        let earlier: [(Double, Double, UInt8)] = [(-1.5, -1, light)] + night
        let again = try sync([earlier], at: hour(9), store: store)
        XCTAssertEqual(again.nights, [])
        XCTAssertEqual(try rows(store).map(window), [DateInterval(start: capped.start, end: hour(7))], "the written night stands")
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).asleepMin, asleepBefore, "the earlier half hour is not stored")
        XCTAssertEqual(try hypnogram(store), hypnogramBefore)
        XCTAssertEqual(HelioSleepSelection.leadIn(in: try hypnogram(store)), capped)
        let rewritten = try await flush(again.nights.map(\.segments), at: hour(9), store: store)
        XCTAssertEqual(rewritten, [])
        XCTAssertEqual(try mirror(store), mirrorBefore)
    }

    // MARK: N1 (77i): an earlier build's night, then an extension at the end

    /// Stated: a night an earlier build wrote without a lead-in (23:00–03:00), then extended at the end
    /// (58b, to 07:00) once the strap's heart rate before bed is stored, is rewritten ONCE, and that one
    /// write takes the lead-in along: Health's night then starts at 22:00. No start-only rewrite exists.
    func testANightWrittenWithoutALeadInThatExtendsAtTheEndIsRewrittenOnceWithItsLeadIn() async throws {
        let store = try makeStore()
        try storeHeartRate(-1, 9, store: store)
        let early: [(Double, Double, UInt8)] = [(-1, 1, light), (1, 3, deep)]
        let first = try sync([early], at: hour(3.5), store: store)
        XCTAssertNil(first.nights.first?.leadIn)
        let written = try await flush(first.nights.map(\.segments), at: hour(3.5), store: store)
        XCTAssertEqual(written, [DateInterval(start: hour(-1), end: hour(3))])

        try storeHeartRate(-2, -1, store: store)
        let final = try sync([night], at: hour(8), store: store)
        XCTAssertEqual(final.nights.first?.leadIn, leadIn(from: -2))
        let rewritten = try await flush(final.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(rewritten, [DateInterval(start: hour(-2), end: hour(7))], "one rewrite, the start moves to the lead-in's")
        XCTAssertEqual(try mirror(store)?.hasSuffix("\(hour(-2).timeIntervalSince1970) \(hour(7).timeIntervalSince1970)"), true)
        let again = try await flush(final.nights.map(\.segments), at: hour(8), store: store)
        XCTAssertEqual(again, [], "and only once")
    }

    // MARK: S2 (77d): resting heart rate from sparse sleep heart rate

    /// The night's asleep heart rate is too sparse for `RestingHR`'s asleep mean (fewer than
    /// `minSleepSamples`), so it falls back to the lowest sustained heart rate over the readings it is
    /// given. Those must be the night's own: a calm, LOW lead-in (50 bpm, under the asleep 60) given to
    /// the fallback would lower the resting heart rate and lift the Sleep Score. Here the window (without
    /// the lead-in) is the protection; the asleep filter alone would not be.
    func testRestingHeartRateFromSparseSleepHeartRateNeverReachesIntoTheLeadIn() throws {
        func sparse(_ store: LocalStore, leadInHeartRate: Bool) throws {
            if leadInHeartRate { try storeHeartRate(-2, -1, bpm: 50, store: store) }
            for h in [-0.5, 3.0] {
                store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: hour(h), end: hour(h), value: 60,
                                                  deviceID: timeline.rawValue))
            }
            for m in stride(from: -120.0, to: 480, by: 10) {
                let inLeadIn = m < -60
                for (kind, value) in [(MetricKind.hrvSDNN, inLeadIn ? 15.0 : 55), (.temperature, inLeadIn ? 31.0 : 34.5)] {
                    store.context.insert(StoredSample(kindRaw: kind.rawValue, start: hour(m / 60), end: hour(m / 60), value: value,
                                                      deviceID: timeline.rawValue))
                }
            }
            try store.context.save()
        }
        XCTAssertLessThan(2, RestingHR.minSleepSamples, "two asleep readings: under the asleep mean's floor")
        let withLeadIn = try makeStore()
        try sparse(withLeadIn, leadInHeartRate: true)
        let night = try XCTUnwrap(try sync([night], at: hour(8), store: withLeadIn).nights.first)
        XCTAssertEqual(night.leadIn, leadIn(from: -2), "the calm low heart rate before bed is a lead-in")

        let without = try makeStore()
        try sparse(without, leadInHeartRate: false)
        var a = LocalStore.SleepNightExtras(), b = LocalStore.SleepNightExtras()
        withLeadIn.applyHelioNightScores(to: &a, window: night.window, segments: night.segments, device: timeline)
        without.applyHelioNightScores(to: &b, window: night.window, segments: night.segments, device: timeline)
        XCTAssertGreaterThan(b.sleepScore, 0)
        XCTAssertEqual(a.sleepScore, b.sleepScore, "the save path: the resting HR is the night's (60), not the lead-in's (50)")
        XCTAssertEqual(a.stressScore, b.stressScore, "RMSSD: the sleep spans only")

        // The same night through the repair pass, in both stores.
        XCTAssertEqual(try without.saveHelioNight(night, device: timeline), .inserted)
        let rowA = try XCTUnwrap(try rows(withLeadIn).first), rowB = try XCTUnwrap(try rows(without).first)
        XCTAssertEqual(rowA.skinTempC, rowB.skinTempC, "the skin-temperature verdict")
        XCTAssertEqual(rowA.skinTempC, 34.5, accuracy: 0.001)
        XCTAssertEqual(rowA.hypnogramData, rowB.hypnogramData)
        for row in [rowA, rowB] { row.sleepScore = 0 }
        try withLeadIn.context.save()
        try without.context.save()
        _ = try withLeadIn.scoreUnscoredHelioNights()
        _ = try without.scoreUnscoredHelioNights()
        XCTAssertGreaterThan(rowB.sleepScore, 0)
        XCTAssertEqual(rowA.sleepScore, rowB.sleepScore, "the repair pass: the same resting HR")
    }
}
