import BackgroundTasks
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 50 (#253): a strap night reaches Apple Health even when a later sync keeps the stored night.
// 50a: the sink hands the STORED night to the sync's flush when the merge keeps it over a re-delivery.
// 50b: every strap flush also offers stored strap nights that never got a mirror record and have a
// later stored night after them. Every key, reading, id and time is synthetic.
//
// The writer itself can't write in the simulator (no Health access), so "the flush mirrors it" is
// shown in two halves: the night is in what `HelioConnection.flushStrap` hands the writer, ready to
// write, and the writer's own `mirrorSettledNight` gets past every bail to its write: any outcome but
// `.unchanged` (without Health access the write itself is refused). Then, with the record a successful
// write leaves, the same call is the signature no-op and neither 50a nor 50b offers the night again.

// MARK: - Fixtures

private let sMidnight: TimeInterval = 1_789_862_400          // 2026-09-20T00:00:00Z
private let sNow = Date(timeIntervalSince1970: sMidnight + 12 * 3600)
private let sKeyHex = "00112233445566778899aabbccddeeff"
private func hour(_ h: Double) -> Date { Calendar.current.startOfDay(for: sNow).addingTimeInterval(h * 3600) }

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// Stage bytes (ZEPP_PROTOCOL.md §6.6): light, deep, awake, REM.
private let light: UInt8 = 0x04, deep: UInt8 = 0x05, awake: UInt8 = 0x07, rem: UInt8 = 0x08

/// One strap sleep session record over local hours of `hour(0)`'s day (minute fields count from the
/// previous local midnight, `ZeppSleepSession.absolute`).
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
    // §6.6 (decision 70e): a stage's end minute is inclusive, so a stage ending at `end` is written as `end − 1`.
    for (i, stage) in stages.enumerated() { put(le16(minute(stage.0)) + le16(minute(stage.1) - 1) + [stage.2], at: 0x056 + 5 * i) }
    return r
}

/// The night as first delivered: 23:00–07:00, all asleep (480 min).
private let firstDelivery: [(Double, Double, UInt8)] = [(-1, 2, light), (2, 3, deep), (3, 4, rem), (4, 7, light)]
/// The same night re-delivered by a later sync: five minutes wider at each end (past the merge's
/// one-epoch "same coverage" tolerance) and 15 asleep minutes fewer. The shape #253 measured: thinner
/// and slightly wider, so the merge keeps the stored night.
private let reDelivery: [(Double, Double, UInt8)] = [
    (-1 - 5.0 / 60, -1, awake), (-1, 2, light), (2, 3, deep), (3, 3.5, rem), (3.5, 3.75, awake), (3.75, 7, light),
    (7, 7 + 5.0 / 60, awake),
]

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func makeStrap(_ stages: [(Double, Double, UInt8)]) -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(sKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
    device.services = services
    device.deviceInfoReply = deviceInfoReply
    device.dataPacketLength = 200
    device.fetchData = [.sleepSession: (stamp(hour(0).timeIntervalSince1970 - 86_400), session(stages))]
    return device
}

@MainActor
private final class Transport: HelioTransport {
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
private final class Keys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(sKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class StrapNightHealthTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = sNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D050"
    /// Night keys whose mirror record a test may have written (`MirroredNightOverlay` lives in the
    /// standard defaults), cleared before and after each test.
    private var touchedNights: [Date] = []
    /// The sleep schedule's keys (decision 58a: none of them plays any part in a strap night). Every
    /// test runs with none set, as on the phone #274 was measured on; a test may set them
    /// (`setSchedule`). The standard defaults' values are put back afterwards.
    private static let scheduleKeys = [SleepScheduleDefaults.enabled, SleepScheduleDefaults.bedMinutes, SleepScheduleDefaults.wakeMinutes]
    private var savedSchedule: [String: Any] = [:]
    /// The metric breadcrumbs the sink leaves (`sleep-extend`, decision 58b), in a suite of their own.
    private var observabilitySuite = ""
    private(set) var observability = ObservabilityStore()

    override func setUp() {
        super.setUp()
        touchedNights = (-12...2).map { hour(Double($0) * 24) }
        touchedNights.forEach(clearMirror)
        observabilitySuite = "StrapNightHealthTests.observability.\(UUID().uuidString)"
        observability = ObservabilityStore(UserDefaults(suiteName: observabilitySuite)!)
        for key in Self.scheduleKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedSchedule[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in Self.scheduleKeys {
            if let value = savedSchedule[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        touchedNights.forEach(clearMirror)
        UserDefaults().removePersistentDomain(forName: observabilitySuite)
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    /// An enabled sleep schedule waking at `wake` (minutes after local midnight), in the standard defaults.
    fileprivate func setSchedule(wake: Int) {
        UserDefaults.standard.set(true, forKey: SleepScheduleDefaults.enabled)
        UserDefaults.standard.set(22 * 60 + 30, forKey: SleepScheduleDefaults.bedMinutes)
        UserDefaults.standard.set(wake, forKey: SleepScheduleDefaults.wakeMinutes)
    }

    private func clearMirror(_ night: Date) {
        UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(Calendar.current.startOfDay(for: night).timeIntervalSince1970)")
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    /// One strap sync at `now` delivering `stages` as one session, through the production path; the result.
    /// nil `stages`: the strap has stopped re-delivering the night (#262), so the sync carries no sleep.
    private func sync(_ stages: [(Double, Double, UInt8)]?, at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let device = makeStrap(stages ?? firstDelivery)
        if stages == nil { device.fetchData = [:] }
        let transport = Transport(device: device)
        let keys = Keys()
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: HelioStoreSink(store: store, observability: observability), findState: HelioFindState(),
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = session
        session.start()
        transport.drain()
        let result = try XCTUnwrap(session.lastSyncResult)
        XCTAssertEqual(result.interrupted, false)
        return result
    }

    private func rows(_ store: LocalStore) throws -> [StoredSleepSummary] {
        try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.inBedStart)]))
    }

    private func storedHypnogram(_ store: LocalStore) throws -> [SleepSegment] {
        SleepHypnogramCodec.decode(try XCTUnwrap(try rows(store).first).hypnogramData)
    }

    /// What `mirrorSettledNight` records once its write succeeded: the signature and the span.
    private func recordMirror(_ segments: [SleepSegment], store: LocalStore) throws {
        let row = try XCTUnwrap(try store.sleepSummaryOverlapping(start: segments.map(\.start).min()!, end: segments.map(\.end).max()!))
        store.setMirroredNight(night: row.night, signature: HealthKitWriter.sleepSignature(segments),
                               spanStart: row.inBedStart, spanEnd: row.inBedEnd)
    }

    /// Whether the writer stopped before its write step: nothing to do, or a refusal (#259 split the
    /// refusals out as `.declined`).
    private func isUnchanged(_ outcome: HealthKitWriter.MirrorOutcome) -> Bool {
        switch outcome {
        case .unchanged, .declined: return true
        case .wrote, .failed: return false
        }
    }

    /// The first sync stores the night 13 minutes after it ended, inside the settle margin.
    private func firstSync(_ store: LocalStore) throws -> HelioSyncResult {
        let first = try sync(firstDelivery, at: hour(7 + 13.0 / 60), store: store)
        XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(7))], "stored and handed over")
        XCTAssertFalse(SleepHealthGate.isReadyToWrite(latestSegmentEnd: hour(7), now: clock, finalized: false),
                       "and held behind the margin, as designed")
        XCTAssertEqual(try rows(store).map(\.asleepMin), [480])
        return first
    }

    // MARK: 50a: the reported case, end to end at sink + flush level

    func testAStoredNightKeptOverAThinnerReDeliveryReachesTheFlushAndTheMirror() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)

        // A later sync, after the margin, re-delivers it thinner and wider: the merge keeps the stored night.
        let second = try sync(reDelivery, at: hour(8), store: store)
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(try rows(store).count, 1)
        XCTAssertEqual(row.asleepMin, 480, "the stored night was kept")
        XCTAssertEqual(row.inBedStart, hour(-1))
        XCTAssertEqual(row.inBedEnd, hour(7))

        // The sync's result carries the STORED night.
        let stored = try storedHypnogram(store)
        XCTAssertEqual(second.nights.map(\.segments), [stored], "the stored night is handed to the flush")
        XCTAssertEqual(second.nights.first?.window, DateInterval(start: hour(-1), end: hour(7)))
        XCTAssertEqual(second.nights.first?.strapScore, 81)

        // The flush offers it to the writer once, ready to write.
        let input = HelioConnection.strapNights(second.nights.map(\.segments), store: store, timeline: timeline, now: clock)
        XCTAssertEqual(input, [stored])
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: stored.map(\.end).max(), now: clock, finalized: false))
        let writer = HealthKitWriter()
        let outcome = await writer.mirrorSettledNight(local: store, segments: stored)
        XCTAssertFalse(isUnchanged(outcome), "the writer gets past every bail to its write")

        // With the record that write leaves: the signature is the stored hypnogram's.
        try recordMirror(stored, store: store)
        XCTAssertEqual(store.mirroredNight(night: row.night)?.signature, HealthKitWriter.sleepSignature(stored))
    }

    /// A second flush after the night is mirrored writes nothing: neither path offers it again, and the
    /// writer's own mirror is the signature no-op.
    func testASecondFlushAfterTheMirrorWritesNothing() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        _ = try sync(reDelivery, at: hour(8), store: store)
        let stored = try storedHypnogram(store)
        try recordMirror(stored, store: store)

        let third = try sync(reDelivery, at: hour(9), store: store)
        XCTAssertEqual(third.nights.count, 0, "a mirrored night is not handed over again")
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: clock), [])
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: stored)
        XCTAssertTrue(isUnchanged(outcome), "the same night again is the signature no-op")
    }

    // MARK: 50a hands nothing over when…

    /// …the strap's re-delivered copy hasn't settled: the stored night ended 21 minutes ago, but the
    /// re-delivery runs five minutes later, so the margin is judged on its end. Five minutes on, it is.
    func testNothingIsHandedOverUntilTheReDeliveredCopyHasSettledToo() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let early = try sync(reDelivery, at: hour(7 + 21.0 / 60), store: store)
        XCTAssertTrue(SleepHealthGate.isSettled(latestSegmentEnd: hour(7), now: clock), "the stored row alone has settled")
        XCTAssertEqual(early.nights.count, 0)
        XCTAssertEqual(try rows(store).map(\.asleepMin), [480], "kept, not re-saved")

        let settled = try sync(reDelivery, at: hour(7 + 26.0 / 60), store: store)
        XCTAssertEqual(settled.nights.map(\.segments), [try storedHypnogram(store)])
    }

    /// …the night already has a Health mirror record (the mirror keeps a written night current), whether
    /// the record's span is the stored night's (28f's guard keeps the re-delivery out) or the re-delivery's.
    func testNothingIsHandedOverForANightWithAMirrorRecord() throws {
        for spanOfReDelivery in [false, true] {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try firstSync(store)
            let row = try XCTUnwrap(try rows(store).first)
            let span = spanOfReDelivery ? DateInterval(start: hour(-1 - 5.0 / 60), end: hour(7 + 5.0 / 60))
                                        : DateInterval(start: row.inBedStart, end: row.inBedEnd)
            store.setMirroredNight(night: row.night, signature: "written", spanStart: span.start, spanEnd: span.end)
            let second = try sync(reDelivery, at: hour(8), store: store)
            XCTAssertEqual(second.nights.count, 0, "record span of the re-delivery: \(spanOfReDelivery)")
            XCTAssertEqual(store.mirroredNight(night: row.night)?.signature, "written")
            clearMirror(row.night)
        }
    }

    /// …the night is manually edited.
    func testNothingIsHandedOverForAnEditedNight() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let row = try XCTUnwrap(try rows(store).first)
        row.isManuallyEdited = true
        try store.context.save()
        let second = try sync(reDelivery, at: hour(8), store: store)
        XCTAssertEqual(second.nights.count, 0)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: clock), [])
    }

    /// …the night is the ring's (28a): the ring went to bed with it, and the strap's re-delivery of it
    /// hands nothing over.
    func testNothingIsHandedOverForTheRingsNight() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(7.5))]))
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  extras: extras), .inserted)
        let second = try sync(reDelivery, at: hour(8), store: store)
        XCTAssertEqual(second.nights.count, 0)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: clock), [])
    }

    /// …the stored night has no hypnogram (it can't be offered as stored, and nothing is invented).
    func testNothingIsHandedOverForAStoredNightWithoutAHypnogram() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  device: timeline), .inserted)
        XCTAssertEqual(SleepHypnogramCodec.decode(try XCTUnwrap(try rows(store).first).hypnogramData), [])
        let second = try sync(reDelivery, at: hour(8), store: store)
        XCTAssertEqual(try rows(store).map(\.asleepMin), [480], "the merge kept the stored night")
        XCTAssertEqual(second.nights.count, 0)
    }

    // MARK: Ring-only: unchanged

    /// An empty ownership log (a ring-only install): the strap's sync stores no night and hands none
    /// over, and the flush input is exactly what it was given, even with the ring's stranded-looking
    /// nights in the store.
    func testRingOnlyTheSyncResultAndTheFlushInputAreUnchanged() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        try saveNight(store, from: -49, to: -41, device: .ringConn)
        try saveNight(store, from: -25, to: -17, device: .ringConn)
        let first = try sync(firstDelivery, at: hour(8), store: store)
        XCTAssertEqual(first.nights.count, 0)
        let given = [[SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]]
        XCTAssertEqual(HelioConnection.strapNights(given, store: store, timeline: timeline, now: hour(8)), given)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(8)), [])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(8)), [])
    }

    // MARK: 50b: the backstop in every strap flush

    /// A stored strap night `[from, to]` (local hours of `hour(0)`'s day) with its hypnogram.
    private func saveNight(_ store: LocalStore, from: Double, to: Double, device: SyncDeviceID? = nil) throws {
        let segments = [SleepSegment(start: hour(from), end: hour(from + 3), stage: .asleepCore),
                        SleepSegment(start: hour(from + 3), end: hour(to), stage: .asleepDeep)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        let outcome = try store.saveSleepSummary(SleepStaging.summary(segments),
                                                 night: SleepNightKey.night(inBedStart: hour(from), inBedEnd: hour(to)),
                                                 inBedStart: hour(from), inBedEnd: hour(to), sleepOnset: hour(from), sleepWake: hour(to),
                                                 extras: extras, device: device ?? timeline)
        XCTAssertEqual(outcome, .inserted)
    }

    private func hypnogram(_ store: LocalStore, endingAt to: Double) throws -> [SleepSegment] {
        let row = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(to) })
        return SleepHypnogramCodec.decode(row.hypnogramData)
    }

    /// A stranded strap night (no mirror record) with a later stored night after it is offered; the
    /// newest night isn't; one the sync already carries isn't offered twice.
    func testAStrandedStrapNightWithALaterNightIsOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let stranded = try hypnogram(store, endingAt: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(9)), [stranded])
        let tonight = try hypnogram(store, endingAt: 7)
        XCTAssertEqual(HelioConnection.strapNights([tonight], store: store, timeline: timeline, now: hour(9)), [tonight, stranded])
        XCTAssertEqual(HelioConnection.strapNights([stranded], store: store, timeline: timeline, now: hour(9)), [stranded],
                       "a night the sync carries is not offered twice")
        // The night 50a and 50b exist for, a day later: the next night stored, last night offered.
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: stranded.map(\.end).max(), now: hour(9), finalized: false))
    }

    /// A newest night that ended far before the scheduled wake (here 23:00–03:00) isn't offered for 3
    /// hours after it ended (decision 57a): it can be the first part of a night still in progress.
    /// Mirrored, 28f's "the written night stands" would keep the full night out for good.
    func testAnEarlyEndingNewestNightIsNotOfferedWithinThreeHoursOfItsEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 3)
        let justBefore = hour(3).addingTimeInterval(LocalStore.strapNewestNightHealthBuffer - 1)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: justBefore), [])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: justBefore), [])
        // And with an earlier night stored too, only the earlier one.
        try saveNight(store, from: -25, to: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: justBefore), [try hypnogram(store, endingAt: -17)])
    }

    func testAStrandedNightWithAMirrorRecordIsNotOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        try recordMirror(try hypnogram(store, endingAt: -17), store: store)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    func testAnEditedNightIsNotOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let edited = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(-17) })
        edited.isManuallyEdited = true
        try store.context.save()
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    /// The ring went to bed with the earlier night (the switch to the strap came after it): it is the
    /// ring's, and the strap's flush never offers it.
    func testARingOwnedNightIsNotOffered() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(-12))]))
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17, device: .ringConn)
        try saveNight(store, from: -1, to: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    /// #259: a night mirrored before a time-zone change is not offered again after it. Its record is
    /// under the start of its day in the zone it was stored in, which the current zone's day key no
    /// longer names.
    func testATimeZoneChangeDoesNotReOfferAMirroredNight() throws {
        ownership.install(.strapOwnsAllTime)
        let savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = savedZone }
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        try recordMirror(try hypnogram(store, endingAt: -17), store: store)
        let key = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(-17) }).night
        defer { UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(key.timeIntervalSince1970)") }
        let now = hour(9)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [])

        NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertNil(store.mirroredNight(night: key),
                     "this test only means something while the current zone's key misses the record")
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [],
                       "the night Apple Health already holds is not offered again")
    }

    /// #259: a stored night the writer declined is not offered on every flush after, until its
    /// stored hypnogram changes.
    func testANightTheWriterDeclinedIsNotOfferedAgainUntilItChanges() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let row = try XCTUnwrap(try rows(store).first { $0.inBedEnd == hour(-17) })
        defer { StrapNightDeclinedOverlay.clear(storedNight: row.night) }
        let stranded = try hypnogram(store, endingAt: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded])

        // A declined offer that is NOT the stored hypnogram notes nothing.
        store.noteStrapNightDeclined(Array(stranded.prefix(1)))
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded])

        store.noteStrapNightDeclined(stranded)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [],
                       "the same stored night would meet the same refusal")

        // The stored night changes: a different offer, so it is offered again.
        let changed = [SleepSegment(start: hour(-25), end: hour(-21), stage: .asleepCore),
                       SleepSegment(start: hour(-21), end: hour(-17), stage: .asleepREM)]
        row.hypnogramData = SleepHypnogramCodec.encode(changed)
        try store.context.save()
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [changed])
    }

    /// #259: the writer reports a refusal the same staging would meet again (here, thinner than the
    /// card) as `declined`, not `unchanged`, so the strap flush can note it.
    func testTheWriterReportsAThinnerStagingAsDeclined() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        let thinner = Array(try hypnogram(store, endingAt: -17).prefix(1))
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: thinner)
        guard case .declined = outcome else { return XCTFail("expected .declined, got \(outcome)") }
    }

    /// #259: a future-dated night (a device clock set ahead) does not become the newest-night guard
    /// and hold back every night before it. The guard reads every device's nights alike, so the
    /// future row here is the strap's; the suspected source is a ring with a mis-set clock.
    func testAFutureKeyedNightDoesNotStallTheBackstop() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        try saveNight(store, from: 47, to: 55)        // keyed two days ahead of `now`
        let stranded = try hypnogram(store, endingAt: -17)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [stranded],
                       "last night is still the newest real night, so it alone is held back")
    }

    /// Older than 7 days: stays in the app.
    func testANightOlderThanSevenDaysIsNotOffered() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -24 * 8 - 1, to: -24 * 8 + 7)
        try saveNight(store, from: -24 * 6 - 1, to: -24 * 6 + 7)
        try saveNight(store, from: -1, to: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)),
                       [try hypnogram(store, endingAt: -24 * 6 + 7)], "the 6-day-old night only")
    }

    /// The backstop for the reported case after its re-delivery window closed: no sync carries the
    /// night any more, the next night is stored, and the flush offers it as stored (the path a later
    /// night opens, unchanged by decision 57).
    func testTheBackstopOffersTheReportedNightOnceTheNextNightIsStored() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let stored = try storedHypnogram(store)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(9)), [],
                       "the newest night, two hours on, waits")
        try saveNight(store, from: 23, to: 31)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(33)), [stored])
    }
}

// MARK: - Decision 57 (#262): the newest night, once it has clearly stopped growing
//
// The newest night waits 3 hours after its end, whatever clock time it ended at (decision 58a, #274,
// withdrew 57d's faster path for an end near the scheduled wake).

/// What the app asked iOS for (decision 57b's margin refresh).
private final class MarginRecorder: BGTaskScheduling {
    private(set) var submitted: BGTaskRequest?
    func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool { true }
    func cancel(taskRequestWithIdentifier identifier: String) {}
    func submit(_ taskRequest: BGTaskRequest) throws { submitted = taskRequest }
}

extension StrapNightHealthTests {
    private var buffer: TimeInterval { LocalStore.strapNewestNightHealthBuffer }

    func testTheNewestNightBufferIsThreeHours() {
        XCTAssertEqual(LocalStore.strapNewestNightHealthBuffer, 3 * 3600, "Juan's choice (57a); don't shorten it without asking")
    }

    /// A 07:00 end, 2:59:59 on, with no later night: its margin has long passed, and it is still not
    /// offered.
    func testAnEarlyEndingNewestNightIsNotOfferedTwoFiftyNineFiftyNineAfterItsEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        let now = hour(7).addingTimeInterval(3 * 3600 - 1)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: now), [])
    }

    /// A 07:00 end, 3:00:01 on, with no later night: offered, once, ready to write; mirrored, never again.
    func testAnEarlyEndingNewestNightIsOfferedOnceThreeHoursAndASecondAfterItsEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        let now = hour(7).addingTimeInterval(3 * 3600 + 1)
        let tonight = try hypnogram(store, endingAt: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [tonight])
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: now), [tonight])
        XCTAssertEqual(HelioConnection.strapNights([tonight], store: store, timeline: timeline, now: now), [tonight],
                       "a night the sync carries is not offered twice")
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: tonight.map(\.end).max(), now: now, finalized: false))
        try recordMirror(tonight, store: store)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: now), [], "mirrored: not offered again")
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: now.addingTimeInterval(86_400)), [])
    }

    /// The buffer runs from the later of the row's end and its hypnogram's last segment.
    func testAnEarlyEndingNewestNightsBufferRunsFromItsLatestEnd() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(3), stage: .asleepCore),
                        SleepSegment(start: hour(3), end: hour(7.5), stage: .asleepDeep)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  extras: extras, device: timeline), .inserted)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7.5).addingTimeInterval(buffer - 1)), [])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7.5).addingTimeInterval(buffer + 1)), [segments])
    }

    // The newest night keeps every other rule of the backstop, 3:00:01 on.

    func testTheNewestNightIsNotOfferedWithAMirrorRecord() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        let row = try XCTUnwrap(try rows(store).first)
        store.setMirroredNight(night: row.night, signature: "written", spanStart: row.inBedStart, spanEnd: row.inBedEnd)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    func testTheNewestNightIsNotOfferedWhenEdited() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7)
        try XCTUnwrap(try rows(store).first).isManuallyEdited = true
        try store.context.save()
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    /// The ring went to bed with it (the switch to the strap came after): the ring's, never the strap's.
    func testTheNewestNightIsNotOfferedWhenTheRingOwnsIt() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(7.5))]))
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7, device: .ringConn)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    func testTheNewestNightIsNotOfferedWithoutAHypnogram() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-1), end: hour(7), stage: .asleepCore)]
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(7)),
                                                  inBedStart: hour(-1), inBedEnd: hour(7), sleepOnset: hour(-1), sleepWake: hour(7),
                                                  device: timeline), .inserted)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
    }

    func testTheNewestNightIsNotOfferedOutsideTheLookback() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -24 * 8 - 1, to: -24 * 8 + 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9)), [])
    }

    /// An empty ownership log (a ring-only install): nothing, however long ago the night ended.
    func testRingOnlyTheNewestNightIsNeverOffered() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7, device: .ringConn)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [])
        XCTAssertNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.1)))
    }

    /// A later night exists: the older night is offered as before, at any time; only the newest waits.
    func testWithALaterNightTheOlderNightIsOfferedAsBefore() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -25, to: -17)
        try saveNight(store, from: -1, to: 7)
        let stranded = try hypnogram(store, endingAt: -17)
        let tonight = try hypnogram(store, endingAt: 7)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7.5)), [stranded])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer - 1)), [stranded])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(7).addingTimeInterval(buffer + 1)), [stranded, tonight])
    }

    /// #262's shape: a wake stores the night (07:00 end) 13 minutes after it ended, then the strap stops re-delivering it, so no sync carries it again. Nothing
    /// offers it for 3 hours, and the first flush after that offers it as stored, past every bail of the
    /// writer to its write.
    func testAnEarlyEndingNightReachesTheFlushThreeHoursOnWithoutAReDelivery() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let stored = try storedHypnogram(store)
        let quiet = try sync(nil, at: hour(7.25), store: store)
        XCTAssertEqual(quiet.nights.count, 0, "the strap no longer re-delivers it")
        for t in [hour(7.25), hour(8), hour(10).addingTimeInterval(-1)] {
            XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: t), [], "at \(t)")
        }
        let later = try sync(nil, at: hour(10).addingTimeInterval(1), store: store)
        let input = HelioConnection.strapNights(later.nights.map(\.segments), store: store, timeline: timeline, now: clock)
        XCTAssertEqual(input, [stored])
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: stored)
        XCTAssertFalse(isUnchanged(outcome), "the writer gets past every bail to its write")
        try recordMirror(stored, store: store)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(11)), [])
    }

    /// Decision 57b: the app opened two minutes after a background wake stored the night. Its sync no
    /// longer carries the night, and before 57b its flush's verdict was nil, which cleared the wake's
    /// margin refresh; the app's `schedule()` on leaving the front then replaced it for good. Now the
    /// flush asks for the same refresh, and it survives the app leaving the front.
    func testAForegroundSyncThatNoLongerCarriesTheNightReArmsItsMarginRefresh() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let first = try firstSync(store)
        let marginEnd = hour(7).addingTimeInterval(SleepHealthGate.settleMargin)
        XCTAssertEqual(HelioConnection.nightRefreshAim(result: first, timeline: timeline, store: store,
                                                       flushStartedAt: clock, now: clock), marginEnd)

        let opened = try sync(nil, at: hour(7.25), store: store)
        XCTAssertEqual(opened.nights.count, 0)
        XCTAssertNil(StrapNightRefresh.aim(nights: opened.nights, focusEndedAt: nil, flushStartedAt: clock, afterWokeUp: false),
                     "the sync's own nights alone ask for nothing")
        let aim = HelioConnection.nightRefreshAim(result: opened, timeline: timeline, store: store, flushStartedAt: clock, now: clock)
        XCTAssertEqual(aim, marginEnd)

        let suite = "StrapNightHealthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = MarginRecorder()
        let now = clock
        let scheduler = BackgroundRefreshScheduler(scheduler: recorder, now: { now }, window: { _ in nil })
        StrapNightRefresh.record(aim, scheduler: scheduler, defaults: defaults)
        XCTAssertEqual(recorder.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertTrue(recorder.submitted is BGAppRefreshTaskRequest)
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, marginEnd)
        scheduler.schedule()
        XCTAssertNotEqual(recorder.submitted?.earliestBeginDate, marginEnd, "the app leaving the front replaced it")
        XCTAssertTrue(StrapNightRefresh.resubmit(scheduler, strapChosen: true, now: now, defaults: defaults))
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, marginEnd, "and it is back")
    }

    /// 57b asks for nothing once the stored night has settled (it then waits for 57a's buffer, on any
    /// flush), nor for a night that isn't the strap's to write.
    func testTheStoredNightAsksForNoRefreshOnceSettledOrNotTheStrapsToWrite() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try firstSync(store)
        let settled = try sync(nil, at: hour(7.5), store: store)
        XCTAssertNil(HelioConnection.nightRefreshAim(result: settled, timeline: timeline, store: store, flushStartedAt: clock, now: clock))
        XCTAssertNotNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.25)))

        let row = try XCTUnwrap(try rows(store).first)
        row.isManuallyEdited = true
        try store.context.save()
        XCTAssertNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.25)), "edited")
        row.isManuallyEdited = false
        try store.context.save()
        store.setMirroredNight(night: row.night, signature: "written", spanStart: row.inBedStart, spanEnd: row.inBedEnd)
        XCTAssertNil(store.newestStrapNightSettles(timeline: timeline, now: hour(7.25)), "mirrored")
    }
}

// MARK: - Review-snh: a held night must still be the stored row when the sync ends

/// Sleep A, 23:00–02:00 (180 min asleep), stored by a sync shortly after a mid-night wake.
private let sleepA: [(Double, Double, UInt8)] = [(-1, 0.5, light), (0.5, 1, deep), (1, 2, light)]
/// A re-delivered: five minutes wider each side and 15 asleep minutes fewer, so the merge keeps A.
private let sleepAAgain: [(Double, Double, UInt8)] = [
    (-1 - 5.0 / 60, -1, awake), (-1, 0.5, light), (0.5, 0.75, awake), (0.75, 1, deep), (1, 2, light), (2, 2 + 5.0 / 60, awake),
]
/// Sleep B, 03:30–07:00 (210 min asleep): 85 minutes after A, an overnight sleep of A's night key, so
/// decision 71b joins the two (before it, 28f kept B apart and B, the fuller, replaced A's row in place).
private let sleepB: [(Double, Double, UInt8)] = [(3.5, 5, light), (5, 6, rem), (6, 7, light)]

extension StrapNightHealthTests {
    /// One strap sync at `now` delivering each of `sessions` as its own session record.
    private func syncSessions(_ sessions: [[(Double, Double, UInt8)]], at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let device = makeStrap(sessions[0])
        device.fetchData[.sleepSession] = (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(session))
        let transport = Transport(device: device)
        let keys = Keys()
        let helio = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                 sink: HelioStoreSink(store: store, observability: observability), findState: HelioFindState(),
                                 clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = helio
        helio.start()
        transport.drain()
        let result = try XCTUnwrap(helio.lastSyncResult)
        XCTAssertEqual(result.interrupted, false)
        return result
    }

    /// Runs `body` with local times in a fixed zone (New York), and clears the mirror records it may leave.
    private func inFixedZone(_ body: () async throws -> Void) async rethrows {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let nights = (-2...2).map { hour(Double($0) * 24) }
        nights.forEach(clearMirror)
        defer {
            nights.forEach(clearMirror)
            NSTimeZone.default = saved
        }
        try await body()
    }

    private func window(_ segments: [SleepSegment]) -> DateInterval? {
        guard let start = segments.map(\.start).min(), let end = segments.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// A was stored at 02:15, inside the margin. The morning sync carries A again and B, which decision
    /// 71b joins into one night (22:55–07:00) that replaces A's row in place.
    private func storeAThenSyncAAgainAndBJoinedToIt(at now: Date, store: LocalStore) throws -> HelioSyncResult {
        let first = try syncSessions([sleepA], at: hour(2.25), store: store)
        XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))], "A stored, held by the margin")
        let morning = try syncSessions([sleepAAgain, sleepB], at: now, store: store)
        let rows = try rows(store)
        XCTAssertEqual(rows.count, 1, "one row for the key")
        XCTAssertEqual(rows.first?.inBedStart, hour(-1 - 5.0 / 60), "the joined night replaced A's row in place")
        XCTAssertEqual(rows.first?.inBedEnd, hour(7))
        return morning
    }

    /// Review-snh test 1: the sync carrying A again and B hands the flush the night joining them (71b),
    /// and no night that isn't a current stored row's (the stale A, which the joined night replaced in
    /// this same sync). This also pins the
    /// re-flush churn: `ContentView.flushHealth` re-flushes `lastSyncResult.nights` until the next sync,
    /// and `[B, staleA]` there would write B, delete A, write A and delete B on every such flush.
    func testASyncJoiningTheKeptNightToALaterSleepHandsOverOnlyTheJoinedRow() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndBJoinedToIt(at: hour(7.5), store: store)
            let current = try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }
            XCTAssertTrue(morning.nights.contains { $0.window == DateInterval(start: hour(-1 - 5.0 / 60), end: hour(7)) },
                          "the joined night is handed over")
            XCTAssertEqual(morning.nights.filter { !current.contains($0.window) }.map(\.window), [], "no stale A")
        }
    }

    /// Review-snh test 2: at 07:10 B (the joined night's end) hasn't settled. Nothing for the key is
    /// ready to write, so nothing reaches the writer's write step and no mirror record is left. A flush
    /// at 07:30 (ContentView's, over the last sync's result) offers exactly the joined night, ready.
    func testBeforeTheJoinedNightSettlesNothingIsWrittenForTheKey() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndBJoinedToIt(at: hour(7 + 10.0 / 60), store: store)
            let key = try XCTUnwrap(try rows(store).first).night

            let input = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: clock)
            let ready = input.filter { SleepHealthGate.isReadyToWrite(latestSegmentEnd: $0.map(\.end).max(), now: clock, finalized: false) }
            XCTAssertEqual(ready.compactMap(window), [], "no night for the key is ready at 07:10")
            for night in ready {
                let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: night)
                XCTAssertTrue(isUnchanged(outcome), "nothing reaches the write step")
            }
            let flush = await HelioConnection.flushStrap(HealthKitWriter(), store: store, timeline: timeline,
                                                         nights: morning.nights.map(\.segments), now: clock)
            XCTAssertEqual(flush.sleepSegments, 0)
            XCTAssertNil(store.mirroredNight(night: key), "no mirror record")

            let later = hour(7.5)
            let laterInput = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: later)
            XCTAssertEqual(laterInput, [try storedHypnogram(store)], "exactly the joined night, as stored")
            XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: hour(7), now: later, finalized: false))
        }
    }

    /// Review-snh test 3: both settled at 07:30. The flush input is exactly the joined night's stored
    /// hypnogram: one night for the key.
    func testWhenTheJoinedNightHasSettledTheFlushInputIsItAlone() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndBJoinedToIt(at: hour(7.5), store: store)
            let input = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: clock)
            let stored = try storedHypnogram(store)
            XCTAssertEqual(window(stored), DateInterval(start: hour(-1 - 5.0 / 60), end: hour(7)))
            XCTAssertEqual(input, [stored])
        }
    }
}

// MARK: - Decision 58 (#274): a night still in progress, and the longer copy that replaces it
//
// The strap lets the phone read its sleep record while the sleep is still going on: the record ends a
// few minutes before the sync that reads it. 58a: the backstop claims the newest night only 3 hours
// after its end, whatever clock time that is. 58b: a later copy that overlaps the night already in
// Apple Health and ends at least 10 minutes later replaces it; anything else is kept out, as before.
//
// Synthetic nights on the fixture day: "partial" 00:30–06:00, "final" the same night to 08:50.
//
// The writer can't write in the simulator (no Health access), so a write is shown as in the tests
// above: the night is in the flush input, ready, and `mirrorSettledNight` gets past every bail to its
// write step; then `recordWrite` leaves the record a successful write leaves. What HealthKit deletes
// is not observable here (no seam on the writer's sleep save or delete); the record's span is the
// span the writer's union delete covers.

/// The final night: 00:30–08:50, asleep throughout.
private let finalNight: [(Double, Double, UInt8)] = [
    (0.5, 2, light), (2, 3, deep), (3, 4.5, rem), (4.5, 6.5, light), (6.5, 7.5, rem), (7.5, 8 + 50.0 / 60, light),
]

/// The record as the strap shows it while the night is still going on, up to `end` (local hours).
private func inProgress(until end: Double) -> [(Double, Double, UInt8)] {
    finalNight.compactMap { stage in stage.0 < end ? (stage.0, min(stage.1, end), stage.2) : nil }
}

/// The partial night: 00:30–06:00.
private let partialNight = inProgress(until: 6)

/// Sleep C, 02:30–07:00: 30 minutes after sleep A (23:00–02:00), so 28f stitches the two.
private let sleepC: [(Double, Double, UInt8)] = [(2.5, 4, light), (4, 5, deep), (5, 7, light)]

extension StrapNightHealthTests {
    private var partialWindow: DateInterval { DateInterval(start: hour(0.5), end: hour(6)) }
    private var finalWindow: DateInterval { DateInterval(start: hour(0.5), end: hour(8 + 50.0 / 60)) }

    private func span(_ segments: [SleepSegment]) -> DateInterval {
        DateInterval(start: segments.map(\.start).min()!, end: segments.map(\.end).max()!)
    }

    /// What `mirrorSettledNight` records once its write of `segments` succeeded, computed as the writer
    /// does: the key of the stored row the night overlaps, the night's signature, and the union of the
    /// night's span, the last record's and the stored row's (the span its delete covered).
    @discardableResult
    private func recordWrite(_ segments: [SleepSegment], store: LocalStore) throws -> DateInterval {
        let night = span(segments)
        let row = try store.sleepSummaryOverlapping(start: night.start, end: night.end)
        let key = row?.night ?? SleepNightKey.night(inBedStart: night.start, inBedEnd: night.end)
        let last = store.mirroredNight(night: key)
        let start = min(night.start, last?.spanStart ?? night.start, row?.inBedStart ?? night.start)
        let end = max(night.end, last?.spanEnd ?? night.end, row?.inBedEnd ?? night.end)
        store.setMirroredNight(night: key, signature: HealthKitWriter.sleepSignature(segments), spanStart: start, spanEnd: end)
        return DateInterval(start: start, end: end)
    }

    /// One strap flush at `now`: what `HelioConnection.flushStrap` hands the writer (`nights`, a sync's,
    /// then the backstop's), through the writer's own margin gate, each ready night to
    /// `mirrorSettledNight`. A night that reaches the write step is recorded as written; a declined one
    /// is noted, as the writer's flush does. The spans written.
    private func flush(_ nights: [[SleepSegment]], at now: Date, store: LocalStore) async throws -> [DateInterval] {
        var written: [DateInterval] = []
        for night in HelioConnection.strapNights(nights, store: store, timeline: timeline, now: now)
        where SleepHealthGate.isReadyToWrite(latestSegmentEnd: night.map(\.end).max(), now: now, finalized: false) {
            let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: night)
            // As the writer's flush does (#259): a refusal is noted against the stored hypnogram.
            if case .declined = outcome { store.noteStrapNightDeclined(night) }
            guard !isUnchanged(outcome) else { continue }
            try recordWrite(night, store: store)
            written.append(span(night))
        }
        return written
    }

    /// A sync at `now` delivering `stages` (nil: no sleep round), then its own flush at the same instant.
    private func syncAndFlush(_ stages: [(Double, Double, UInt8)]?, at now: Date,
                              store: LocalStore) async throws -> (result: HelioSyncResult, written: [DateInterval]) {
        let result = try sync(stages, at: now, store: store)
        return (result, try await flush(result.nights.map(\.segments), at: now, store: store))
    }

    private func extensionBreadcrumbs() -> [String] {
        observability.metricRecords().filter { $0.source == "sleep-extend" }.map(\.detail)
    }

    /// The mirror record for `key`, comparable: signature and span.
    private func mirrorRecord(_ store: LocalStore, _ key: Date) -> String? {
        store.mirroredNight(night: key).map { "\($0.signature) \($0.spanStart.timeIntervalSince1970) \($0.spanEnd.timeIntervalSince1970)" }
    }

    private func mirrorSpan(_ store: LocalStore) throws -> DateInterval? {
        let key = try XCTUnwrap(try rows(store).first).night
        return store.mirroredNight(night: key).map { DateInterval(start: $0.spanStart, end: $0.spanEnd) }
    }

    // MARK: 58a: no faster path for the newest night

    /// T-A. The newest stored night (no mirror record, no later night) is offered only once 3 hours have
    /// passed since its end, at any clock time: ending 06:00, not at 06:45, not at 08:59:59, at 09:00:01.
    /// The same with no sleep schedule keys, and with an enabled schedule waking at 06:30; and the same
    /// for ends at 05:29, 05:30 and 11:59, the old faster path's edges.
    func testTheNewestNightWaitsThreeHoursWhateverItsEndAndTheSchedule() throws {
        for scheduled in [false, true] {
            for end in [6.0, 5 + 29.0 / 60, 5.5, 11 + 59.0 / 60] {
                ownership.install(.strapOwnsAllTime)
                if scheduled { setSchedule(wake: 6 * 60 + 30) }
                let store = try makeStore()
                try saveNight(store, from: 0.5, to: end)
                let tonight = try hypnogram(store, endingAt: end)
                let label = "end \(end), schedule \(scheduled)"
                XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(end + 45.0 / 60)), [], label)
                XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(end + 45.0 / 60)), [], label)
                XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(end).addingTimeInterval(buffer - 1)), [], label)
                XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(end).addingTimeInterval(buffer + 1)), [tonight], label)
            }
        }
    }

    /// T-A, through a sync: the measured shape. An in-progress record ending 06:00 is stored by a sync at
    /// 06:05; a short sync at 06:45 carries no sleep round. Its flush writes nothing, with no schedule
    /// keys or with one waking at 06:30.
    func testAShortSyncAfterAnInProgressRecordWritesNothing() async throws {
        for scheduled in [false, true] {
            ownership.install(.strapOwnsAllTime)
            if scheduled { setSchedule(wake: 6 * 60 + 30) }
            let store = try makeStore()
            let snapshot = try await syncAndFlush(partialNight, at: hour(6 + 5.0 / 60), store: store)
            XCTAssertEqual(snapshot.result.nights.map(\.window), [partialWindow])
            XCTAssertEqual(snapshot.written, [], "inside its margin")
            let short = try await syncAndFlush(nil, at: hour(6 + 45.0 / 60), store: store)
            XCTAssertEqual(short.result.nights.count, 0)
            XCTAssertEqual(short.written, [], "schedule \(scheduled)")
            XCTAssertNil(try mirrorSpan(store))
            touchedNights.forEach(clearMirror)
        }
    }

    /// #262's shape on 58a: a wake stores 00:30–09:00 at 09:05 and the strap stops re-delivering it. It
    /// is not offered when its margin closes (09:20), only 3 hours after its end; mirrored, never again.
    func testANightEndingNearTheScheduledWakeWaitsThreeHoursLikeAnyOther() async throws {
        ownership.install(.strapOwnsAllTime)
        setSchedule(wake: 9 * 60)
        let store = try makeStore()
        let night: [(Double, Double, UInt8)] = [(0.5, 3, light), (3, 5, deep), (5, 7, rem), (7, 9, light)]
        let end = hour(9)
        let first = try sync(night, at: hour(9 + 5.0 / 60), store: store)
        XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(0.5), end: end)])
        let stored = try storedHypnogram(store)
        let opened = try sync(nil, at: hour(9 + 10.0 / 60), store: store)
        XCTAssertEqual(opened.nights.count, 0)
        let flushed1 = try await flush([], at: end.addingTimeInterval(SleepHealthGate.settleMargin), store: store)
        XCTAssertEqual(flushed1, [], "not at 09:20")
        let flushed2 = try await flush([], at: end.addingTimeInterval(buffer - 1), store: store)
        XCTAssertEqual(flushed2, [])
        let flushed3 = try await flush([], at: end.addingTimeInterval(buffer + 1), store: store)
        XCTAssertEqual(flushed3, [span(stored)])
        let flushed4 = try await flush([], at: end.addingTimeInterval(buffer + 60), store: store)
        XCTAssertEqual(flushed4, [], "mirrored: never again")
    }

    /// Round 3's risk (decision 57c), still covered: a sync at 02:15, after a mid-night wake, stores
    /// 23:00–02:00, and 57b aims the margin refresh at 02:20. That refresh's sync carries no night, and
    /// its flush offers nothing, with or without a schedule. A real re-delivery (50a) hands it over as
    /// before, and so does the 3-hour backstop, from 05:00.
    func testAMidNightAwakeningIsNotWrittenByTheMarginRefresh() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let first = try syncSessions([sleepA], at: hour(2.25), store: store)
            XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))], "stored, held by the margin")
            let marginEnd = hour(2).addingTimeInterval(SleepHealthGate.settleMargin)
            XCTAssertEqual(HelioConnection.nightRefreshAim(result: first, timeline: timeline, store: store, flushStartedAt: clock, now: clock),
                           marginEnd, "57b aims the refresh at 02:20")
            let storedA = try storedHypnogram(store)

            for scheduled in [false, true] {
                if scheduled { setSchedule(wake: 2 * 60 + 30) }
                let retry = try sync(nil, at: marginEnd.addingTimeInterval(1), store: store)
                XCTAssertEqual(retry.nights.count, 0)
                XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: clock), [], "schedule \(scheduled)")
                XCTAssertEqual(HelioConnection.strapNights(retry.nights.map(\.segments), store: store, timeline: timeline, now: clock), [],
                               "the flush of the 02:20 refresh offers nothing")
                XCTAssertNil(HelioConnection.nightRefreshAim(result: retry, timeline: timeline, store: store, flushStartedAt: clock, now: clock))
            }

            let reDelivered = try syncSessions([sleepAAgain], at: hour(2.5), store: store)
            XCTAssertEqual(reDelivered.nights.map(\.segments), [storedA])
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(5).addingTimeInterval(-1)), [])
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(5).addingTimeInterval(1)), [storedA])
        }
    }

    // MARK: 58b: the rule

    func testTheExtensionMinimumIsTenMinutes() {
        XCTAssertEqual(LocalStore.strapNightExtensionMinimum, 10 * 60)
    }

    /// Overlap with the written span AND an end at least 10 minutes later. Touching edges don't overlap.
    func testTheExtensionRuleBoundaries() {
        let written = partialWindow
        func extends(_ start: Double, _ end: Date) -> Bool {
            LocalStore.strapNightExtends(DateInterval(start: hour(start), end: end), written: written)
        }
        XCTAssertTrue(extends(0.5, hour(6).addingTimeInterval(600)), "exactly +10 min")
        XCTAssertFalse(extends(0.5, hour(6).addingTimeInterval(599)), "+9:59")
        XCTAssertFalse(extends(0.5, hour(6)), "the same end")
        XCTAssertFalse(extends(0.5, hour(5.5)), "an earlier end")
        XCTAssertTrue(extends(1, hour(8 + 50.0 / 60)), "a later start does not stop an extension")
        XCTAssertTrue(extends(0, hour(8 + 50.0 / 60)), "nor an earlier one")
        XCTAssertFalse(extends(1, hour(6)), "differs only in its start")
        XCTAssertTrue(extends(6 - 1.0 / 60, hour(8 + 50.0 / 60)), "overlaps by a minute")
        XCTAssertFalse(extends(6, hour(8 + 50.0 / 60)), "touches the written end: no overlap")
        XCTAssertFalse(extends(6.5, hour(8 + 50.0 / 60)), "after the written night")
        XCTAssertFalse(LocalStore.strapNightExtends(DateInterval(start: hour(-2), end: hour(0.5)), written: written),
                       "touches the written start")
    }

    // MARK: 58b through the sink and the flush

    /// T-B, the heart of it: a partial night already in Apple Health (the state build 68 left), then the
    /// final copy. It is stored (`.updated`), handed to the flush, and the row, its score and the mirror
    /// record become the final night's. The writer writes it once its margin has passed, once; the
    /// record's span (what its union delete covered) holds the partial span. One `sleep-extend`.
    func testTheFinalCopyReplacesAPartialNightAlreadyInHealth() async throws {
        ownership.install(.strapOwnsAllTime)
        // The final night as a store that never saw the partial keeps it: the reference.
        let reference = try makeStore()
        _ = try sync(finalNight, at: hour(9), store: reference)
        let expected = try XCTUnwrap(try rows(reference).first)
        clearMirror(expected.night)

        let store = try makeStore()
        let snapshot = try sync(partialNight, at: hour(6 + 5.0 / 60), store: store)
        XCTAssertEqual(snapshot.nights.map(\.window), [partialWindow])
        let partialRow = try XCTUnwrap(try rows(store).first)
        let partialAsleep = partialRow.asleepMin
        XCTAssertEqual(try recordWrite(try storedHypnogram(store), store: store), partialWindow, "the partial night is in Health")

        let final = try sync(finalNight, at: hour(9), store: store)
        XCTAssertEqual(final.nights.map(\.window), [finalWindow], "stored and handed to the flush")
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(try rows(store).count, 1)
        XCTAssertEqual(row.inBedStart, hour(0.5))
        XCTAssertEqual(row.inBedEnd, hour(8 + 50.0 / 60))
        XCTAssertEqual(row.asleepMin, expected.asleepMin)
        XCTAssertGreaterThan(row.asleepMin, partialAsleep)
        XCTAssertEqual(row.hypnogramData, expected.hypnogramData)
        XCTAssertEqual(row.sleepScore, expected.sleepScore)
        XCTAssertEqual(row.stressScore, expected.stressScore)

        let flushed5 = try await flush(final.nights.map(\.segments), at: hour(9), store: store)
        XCTAssertEqual(flushed5, [], "inside its margin")
        let flushed6 = try await flush(final.nights.map(\.segments), at: hour(9 + 15.0 / 60), store: store)
        XCTAssertEqual(flushed6, [finalWindow])
        XCTAssertEqual(store.mirroredNight(night: row.night)?.signature, HealthKitWriter.sleepSignature(try storedHypnogram(store)))
        let record = try XCTUnwrap(try mirrorSpan(store))
        XCTAssertEqual(record, finalWindow)
        XCTAssertTrue(record.start <= partialWindow.start && partialWindow.end <= record.end, "the old span is inside the delete")
        let flushed7 = try await flush(final.nights.map(\.segments), at: hour(9.5), store: store)
        XCTAssertEqual(flushed7, [], "written once")

        let formatter = DateFormatter()
        if let zone = final.nights.first?.recordedTimeZone { formatter.timeZone = zone }
        formatter.dateFormat = "HH:mm"
        let crumbs = extensionBreadcrumbs()
        XCTAssertEqual(crumbs.count, 1)
        XCTAssertTrue(crumbs.first?.contains("written=\(formatter.string(from: hour(0.5)))–\(formatter.string(from: hour(6)))") == true, "\(crumbs)")
        XCTAssertTrue(crumbs.first?.contains("incoming=\(formatter.string(from: hour(0.5)))–\(formatter.string(from: hour(8 + 50.0 / 60)))") == true)
    }

    /// T-C: with the partial night in Health, a copy that ends earlier, at the same time, 9 minutes later,
    /// that differs only in its start, that doesn't overlap it (touching its end), or that is thinner, is
    /// kept out: the row is unchanged and nothing is written. No `sleep-extend`.
    func testACopyThatDoesNotExtendTheWrittenNightIsKeptOut() async throws {
        let thinner: [(Double, Double, UInt8)] = [(0.5, 1, light), (1, 8 + 50.0 / 60, awake)]
        let cases: [(String, [(Double, Double, UInt8)])] = [
            ("ends earlier", inProgress(until: 5.5)),
            ("the same night", partialNight),
            ("9 minutes later", inProgress(until: 6 + 9.0 / 60)),
            ("only its start differs", [(1, 2, light), (2, 3, deep), (3, 4.5, rem), (4.5, 6, light)]),
            ("no overlap", [(6, 7.5, rem), (7.5, 8 + 50.0 / 60, light)]),
            ("thinner, though longer", thinner),
        ]
        for (label, incoming) in cases {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try sync(partialNight, at: hour(6 + 5.0 / 60), store: store)
            let before = try XCTUnwrap(try rows(store).first)
            let (hypnogramBefore, asleepBefore, key) = (before.hypnogramData, before.asleepMin, before.night)
            try recordWrite(try storedHypnogram(store), store: store)
            let recordBefore = mirrorRecord(store, key)

            let later = try sync(incoming, at: hour(9), store: store)
            let after = try rows(store)
            XCTAssertEqual(after.count, 1, label)
            XCTAssertEqual(after.first?.inBedStart, hour(0.5), label)
            XCTAssertEqual(after.first?.inBedEnd, hour(6), label)
            XCTAssertEqual(after.first?.hypnogramData, hypnogramBefore, label)
            XCTAssertEqual(after.first?.asleepMin, asleepBefore, label)
            let flushed8 = try await flush(later.nights.map(\.segments), at: hour(9.5), store: store)
            XCTAssertEqual(flushed8, [], label)
            XCTAssertEqual(mirrorRecord(store, key), recordBefore, label)
            XCTAssertEqual(extensionBreadcrumbs(), [], label)
            clearMirror(key)
        }
    }

    /// T-D: the final copy delivered again after the rewrite writes nothing, the record is unchanged, and
    /// a longer but thinner copy (past 58b, kept by the merge) is not handed over by 50a for a written night.
    func testTheFinalCopyAgainAfterTheRewriteWritesNothing() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try sync(partialNight, at: hour(6 + 5.0 / 60), store: store)
        try recordWrite(try storedHypnogram(store), store: store)
        let final = try sync(finalNight, at: hour(9 + 15.0 / 60), store: store)
        let flushed9 = try await flush(final.nights.map(\.segments), at: clock, store: store)
        XCTAssertEqual(flushed9, [finalWindow])
        let key = try XCTUnwrap(try rows(store).first).night
        let record = mirrorRecord(store, key)

        let again = try sync(finalNight, at: hour(10), store: store)
        let flushed10 = try await flush(again.nights.map(\.segments), at: clock, store: store)
        XCTAssertEqual(flushed10, [], "the signature no-op")
        XCTAssertEqual(mirrorRecord(store, key), record)

        // 15 minutes longer, so 58b lets it through to the merge, but thinner: the merge keeps the stored
        // night, and 50a hands nothing over for a written night.
        let longerButThinner: [(Double, Double, UInt8)] = [(0.5, 2, light), (2, 9 + 5.0 / 60, awake)]
        let thinner = try sync(longerButThinner, at: hour(11), store: store)
        XCTAssertEqual(thinner.nights.count, 0, "50a hands nothing over for a written night")
        let flushed11 = try await flush(thinner.nights.map(\.segments), at: clock, store: store)
        XCTAssertEqual(flushed11, [])
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).inBedEnd, hour(8 + 50.0 / 60))
        XCTAssertEqual(mirrorRecord(store, key), record)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(13)), [])
        XCTAssertEqual(extensionBreadcrumbs().count, 1, "the one extension only")
    }

    /// T-E: a night written as 23:00–02:00 grows by a session 30 minutes later (02:30–07:00): 28f
    /// stitches them, the stitched night extends the written one and replaces it. A session 90 minutes
    /// later (03:30–07:00) is an overnight sleep of the same night key, so decision 71b joins it the
    /// same way (#278: before it, it was kept out and lost).
    func testALaterSleepOfTheNightExtendsAWrittenNightWithinOrPastTheStitchGap() async throws {
        try await inFixedZone {
            for (label, later, extends) in [("30 min gap", sleepC, true), ("90 min gap", sleepB, true)] {
                ownership.install(.strapOwnsAllTime)
                let crumbs = extensionBreadcrumbs().count
                let store = try makeStore()
                let first = try syncSessions([sleepA], at: hour(2.25), store: store)
                XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))])
                try recordWrite(try storedHypnogram(store), store: store)
                let key = try XCTUnwrap(try rows(store).first).night

                let morning = try syncSessions([sleepA, later], at: hour(7.5), store: store)
                let row = try XCTUnwrap(try rows(store).first)
                XCTAssertEqual(try rows(store).count, 1, label)
                XCTAssertEqual(row.inBedStart, hour(-1), label)
                let written = try await flush(morning.nights.map(\.segments), at: clock, store: store)
                if extends {
                    XCTAssertEqual(row.inBedEnd, hour(7), label)
                    XCTAssertEqual(morning.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(7))], label)
                    XCTAssertEqual(written, [DateInterval(start: hour(-1), end: hour(7))], label)
                    XCTAssertEqual(extensionBreadcrumbs().count, crumbs + 1, label)
                } else {
                    XCTAssertEqual(row.inBedEnd, hour(2), label)
                    XCTAssertEqual(morning.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))],
                                   "\(label): only the written night itself, re-delivered as it is")
                    XCTAssertEqual(written, [], "\(label): the signature no-op")
                    XCTAssertEqual(store.mirroredNight(night: key).map { DateInterval(start: $0.spanStart, end: $0.spanEnd) },
                                   DateInterval(start: hour(-1), end: hour(2)), label)
                    XCTAssertEqual(extensionBreadcrumbs().count, crumbs, label)
                }
                clearMirror(key)
            }
        }
    }

    /// T-F, the replay of the measured shape, with each sync's own flush: in-progress snapshots read
    /// minutes before their syncs, the margin refresh's sync and a short sync with no sleep round, then
    /// the final record. No partial night is ever written; the final one exactly once, after its margin,
    /// whether a sync re-delivers it then or the strap has stopped (the 3-hour backstop).
    func testReplayNoPartialWriteAndOneFinalWrite() async throws {
        for reDelivered in [true, false] {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            var written: [DateInterval] = []
            // Each snapshot ends a few minutes before the sync that reads it.
            let snapshots: [(end: Double, syncedAt: Double)] = [(3, 3 + 4.0 / 60), (5, 5 + 2.0 / 60), (6, 6 + 5.0 / 60)]
            for snapshot in snapshots {
                written += try await syncAndFlush(inProgress(until: snapshot.end), at: hour(snapshot.syncedAt), store: store).written
            }
            written += try await syncAndFlush(nil, at: hour(6 + 21.0 / 60), store: store).written   // the margin refresh
            written += try await syncAndFlush(nil, at: hour(6 + 45.0 / 60), store: store).written   // the short sync
            written += try await flush([], at: hour(8), store: store)
            XCTAssertEqual(written, [], "no partial night written (re-delivered \(reDelivered))")

            let final = try await syncAndFlush(finalNight, at: hour(8 + 55.0 / 60), store: store)
            XCTAssertEqual(final.written, [], "inside its margin")
            let end = hour(8 + 50.0 / 60)
            if reDelivered {
                written += try await syncAndFlush(finalNight, at: end.addingTimeInterval(SleepHealthGate.settleMargin + 60), store: store).written
            } else {
                written += try await syncAndFlush(nil, at: end.addingTimeInterval(SleepHealthGate.settleMargin + 60), store: store).written
                written += try await flush([], at: end.addingTimeInterval(buffer - 1), store: store)
                written += try await flush([], at: end.addingTimeInterval(buffer + 1), store: store)
            }
            written += try await flush([], at: end.addingTimeInterval(buffer + 3600), store: store)
            XCTAssertEqual(written, [finalWindow], "exactly one write, of the final night (re-delivered \(reDelivered))")
            XCTAssertEqual(extensionBreadcrumbs(), [], "nothing was written early, so nothing extended")
            clearMirror(try XCTUnwrap(try rows(store).first).night)
        }
    }

    /// T-F, from the state build 68 left: the partial night is already in Apple Health (written by the
    /// old faster path at the short sync). The final copy replaces it, once.
    func testReplayFromAPartialNightAlreadyInHealth() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try await syncAndFlush(partialNight, at: hour(6 + 5.0 / 60), store: store)
        try recordWrite(try storedHypnogram(store), store: store)   // the old write at the short sync
        var written: [DateInterval] = []
        written += try await syncAndFlush(nil, at: hour(6 + 45.0 / 60), store: store).written
        written += try await syncAndFlush(finalNight, at: hour(8 + 55.0 / 60), store: store).written
        written += try await syncAndFlush(finalNight, at: hour(9 + 15.0 / 60), store: store).written
        written += try await syncAndFlush(finalNight, at: hour(10), store: store).written
        written += try await syncAndFlush(nil, at: hour(12), store: store).written
        XCTAssertEqual(written, [finalWindow])
        XCTAssertEqual(try mirrorSpan(store), finalWindow)
        XCTAssertEqual(extensionBreadcrumbs().count, 1)
    }

    // MARK: 58b leaves every other rule as it was (T-G)

    /// An edited night is not extended: the final copy is left to the person's edit (the sink skips
    /// it), the row and the record are unchanged, and nothing is written.
    func testAnEditedWrittenNightIsNotExtended() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try sync(partialNight, at: hour(6 + 5.0 / 60), store: store)
        try recordWrite(try storedHypnogram(store), store: store)
        let row = try XCTUnwrap(try rows(store).first)
        row.isManuallyEdited = true
        row.editedInBedStart = hour(0.5)
        row.editedInBedEnd = hour(6)
        try store.context.save()
        let record = mirrorRecord(store, row.night)
        let final = try sync(finalNight, at: hour(9), store: store)
        XCTAssertEqual(final.nights.count, 0)
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).inBedEnd, hour(6))
        let flushed12 = try await flush(final.nights.map(\.segments), at: hour(9.5), store: store)
        XCTAssertEqual(flushed12, [])
        XCTAssertEqual(mirrorRecord(store, row.night), record)
        XCTAssertEqual(extensionBreadcrumbs(), [])
    }

    /// The ring's night (28a): the ring went to bed with it and it is in Health. The strap's longer copy
    /// of it is the other device's night: never stored, never written.
    func testTheRingsWrittenNightIsNotExtendedByTheStrap() async throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(1))]))
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(0.5), end: hour(6), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(0.5), inBedEnd: hour(6)),
                                                  inBedStart: hour(0.5), inBedEnd: hour(6), sleepOnset: hour(0.5), sleepWake: hour(6),
                                                  extras: extras), .inserted)
        try recordWrite(segments, store: store)
        let key = try XCTUnwrap(try rows(store).first).night
        let record = mirrorRecord(store, key)
        let final = try sync(finalNight, at: hour(9), store: store)
        XCTAssertEqual(final.nights.count, 0)
        XCTAssertEqual(try rows(store).map(\.inBedEnd), [hour(6)])
        let flushed13 = try await flush(final.nights.map(\.segments), at: hour(9.5), store: store)
        XCTAssertEqual(flushed13, [])
        XCTAssertEqual(mirrorRecord(store, key), record)
    }

    /// Ring-only (empty ownership log): the strap's sync stores no night, extension or not, and the
    /// flush input is exactly what it was given.
    func testRingOnlyNothingIsExtended() async throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(0.5), end: hour(6), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(0.5), inBedEnd: hour(6)),
                                                  inBedStart: hour(0.5), inBedEnd: hour(6), sleepOnset: hour(0.5), sleepWake: hour(6),
                                                  extras: extras), .inserted)
        try recordWrite(segments, store: store)
        let final = try sync(finalNight, at: hour(9), store: store)
        XCTAssertEqual(final.nights.count, 0)
        XCTAssertEqual(try rows(store).map(\.inBedEnd), [hour(6)])
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(12)), [])
        XCTAssertEqual(extensionBreadcrumbs(), [])
    }
}

// MARK: - Decision 58e (#274, review-275): an extension the merge then keeps still reaches Health
//
// A partial night is in Health. The final copy extends it and is first stored inside its settle margin,
// so that sync's flush holds it. Every later sync re-delivers it a little different (5 min wider at
// each end, 15 asleep-min fewer: the #253 shape), 58b lets each through, and the merge keeps the stored
// night. 50a's hand-over and the 50b backstop skipped a night with a mirror record, so Health kept the
// partial night. Now a stored night that extends its mirror record is offered by both, once.

/// The final night re-delivered a little different: 5 min wider at each end, 15 asleep-min fewer.
private let finalThinner: [(Double, Double, UInt8)] = [
    (0.5 - 5.0 / 60, 0.5, awake), (0.5, 2, light), (2, 3, deep), (3, 4.25, rem), (4.25, 4.5, awake), (4.5, 6.5, light),
    (6.5, 7.5, rem), (7.5, 8 + 50.0 / 60, light), (8 + 50.0 / 60, 8 + 55.0 / 60, awake),
]

extension StrapNightHealthTests {
    /// The partial night in Health (the state a write of an in-progress record leaves), then the final
    /// copy stored at 08:55, inside its margin: its own flush writes nothing.
    private func finalStoredInsideItsMargin(_ store: LocalStore) async throws {
        _ = try sync(partialNight, at: hour(6 + 5.0 / 60), store: store)
        XCTAssertEqual(try recordWrite(try storedHypnogram(store), store: store), partialWindow)
        let final = try await syncAndFlush(finalNight, at: hour(8 + 55.0 / 60), store: store)
        XCTAssertEqual(final.result.nights.map(\.window), [finalWindow], "stored")
        XCTAssertEqual(final.written, [], "held by its margin")
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).inBedEnd, hour(8 + 50.0 / 60))
    }

    /// 58e test 1: then every later sync re-delivers it thinner. The first of them after the margin
    /// hands the stored night over (50a) and the writer replaces the partial night: Health ends with the
    /// row's span. Nothing after that writes again.
    func testAnExtensionStoredInsideItsMarginThenReDeliveredThinnerReachesHealth() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try await finalStoredInsideItsMargin(store)
        let stored = try storedHypnogram(store)

        let first = try await syncAndFlush(finalThinner, at: hour(9.5), store: store)
        XCTAssertEqual(first.result.nights.map(\.segments), [stored], "the stored night, not the thinner copy")
        XCTAssertEqual(first.written, [finalWindow])
        var later: [DateInterval] = []
        for t in [10.5, 12.0, 15.0] { later += try await syncAndFlush(finalThinner, at: hour(t), store: store).written }
        for t in [16.0, 24.0, 30.0] { later += try await flush([], at: hour(t), store: store) }
        XCTAssertEqual(later, [], "written once")
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).inBedEnd, hour(8 + 50.0 / 60), "the card")
        XCTAssertEqual(try mirrorSpan(store), finalWindow, "Health")
    }

    /// 58e test 2: the strap never re-delivers it. The 50b backstop offers it despite its mirror
    /// record: not before 3 hours after its end (it is the newest night), then once.
    func testAnExtensionStoredInsideItsMarginAndNeverReDeliveredReachesHealthThroughTheBackstop() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try await finalStoredInsideItsMargin(store)
        let end = hour(8 + 50.0 / 60)
        var written: [DateInterval] = []
        for t in [9.5, 10.5] { written += try await syncAndFlush(nil, at: hour(t), store: store).written }
        written += try await flush([], at: end.addingTimeInterval(buffer - 1), store: store)
        XCTAssertEqual(written, [], "the newest night waits its 3 hours")
        XCTAssertEqual(store.newestStrapNightSettles(timeline: timeline, now: hour(8 + 55.0 / 60)),
                       end.addingTimeInterval(SleepHealthGate.settleMargin), "and asks for its margin refresh")
        let offered = try await flush([], at: end.addingTimeInterval(buffer + 1), store: store)
        XCTAssertEqual(offered, [finalWindow])
        XCTAssertEqual(try mirrorSpan(store), finalWindow)
        let again = try await flush([], at: end.addingTimeInterval(buffer + 3600), store: store)
        XCTAssertEqual(again, [], "once")
    }

    /// 58e test 3, no loop: after the rewrite the record's span is the union and covers the stored
    /// night, so neither path offers it again, whether by a flush or a further thinner re-delivery.
    func testAfterTheRewriteOfAnExtensionNothingOffersItAgain() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try await finalStoredInsideItsMargin(store)
        let rewrite = try await syncAndFlush(finalThinner, at: hour(9.5), store: store)
        XCTAssertEqual(rewrite.written, [finalWindow])
        let key = try XCTUnwrap(try rows(store).first).night
        XCTAssertFalse(store.storedNightAwaitsHealth(storedNight: key, window: finalWindow), "the exception is false again")
        let record = mirrorRecord(store, key)

        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(14)), [], "the backstop")
        let thinner = try await syncAndFlush(finalThinner, at: hour(14), store: store)
        XCTAssertEqual(thinner.result.nights.count, 0, "50a")
        XCTAssertEqual(thinner.written, [])
        XCTAssertNil(store.newestStrapNightSettles(timeline: timeline, now: hour(9 + 1.0 / 60)), "no refresh asked for")
        XCTAssertEqual(mirrorRecord(store, key), record)
    }

    /// 58e test 4, 50a's protection: a re-delivery the merge keeps is handed over only while the stored
    /// night extends what Health holds. Once Health holds the stored night, a longer but thinner copy
    /// (past 58b, kept by the merge) is not.
    func testAKeptReDeliveryIsHandedOverOnlyWhileItsStoredNightExtendsHealth() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try await finalStoredInsideItsMargin(store)
        let extending = try await syncAndFlush(finalThinner, at: hour(9.5), store: store)
        XCTAssertEqual(extending.result.nights.map(\.window), [finalWindow], "the stored night extends Health: handed over")

        let longerButThinner: [(Double, Double, UInt8)] = [(0.5, 2, light), (2, 9 + 5.0 / 60, awake)]
        let kept = try await syncAndFlush(longerButThinner, at: hour(11), store: store)
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).inBedEnd, hour(8 + 50.0 / 60), "the merge kept the stored night")
        XCTAssertEqual(kept.result.nights.count, 0, "it doesn't extend Health any more: not handed over")
        XCTAssertEqual(kept.written, [])
    }

    /// 58e test 5: a declined extension is offered once, then not on every flush (#259's note now
    /// covers a night offered despite its mirror record). Declined here as thinner than its card.
    func testADeclinedExtensionIsNotOfferedOnEveryFlush() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try await finalStoredInsideItsMargin(store)
        let row = try XCTUnwrap(try rows(store).first)
        defer { StrapNightDeclinedOverlay.clear(storedNight: row.night) }
        row.asleepMin += 60   // the card is fuller than the stored hypnogram: the writer declines it
        try store.context.save()
        let stored = try storedHypnogram(store)
        let end = hour(8 + 50.0 / 60)
        let first = end.addingTimeInterval(buffer + 1)
        XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: first), [stored], "offered")
        let written = try await flush([], at: first, store: store)
        XCTAssertEqual(written, [], "declined")
        for later in [first.addingTimeInterval(60), first.addingTimeInterval(86_400)] {
            XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: later), [], "not again")
        }
        XCTAssertEqual(try mirrorSpan(store), partialWindow, "Health keeps what it has")
    }

    /// 58e test 6: the same through the sync's hand-over (50a). A declined extension is handed over
    /// once, by the first thinner re-delivery after its margin; the writer declines it (thinner than its
    /// card) and the flush notes it. Later re-deliveries hand it over no more, and nor does the backstop.
    func testADeclinedExtensionIsHandedOverOnceNotOnEveryReDelivery() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try await finalStoredInsideItsMargin(store)
        let row = try XCTUnwrap(try rows(store).first)
        defer { StrapNightDeclinedOverlay.clear(storedNight: row.night) }
        row.asleepMin += 60   // the card is fuller than the stored hypnogram: the writer declines it
        try store.context.save()

        let first = try await syncAndFlush(finalThinner, at: hour(9.5), store: store)
        XCTAssertEqual(first.result.nights.count, 1, "handed over once")
        XCTAssertEqual(first.written, [], "declined")
        XCTAssertEqual(StrapNightDeclinedOverlay.load(storedNight: row.night), row.hypnogramData, "and noted")
        var handed: [Int] = []
        for t in [10.5, 12.0] {
            let later = try await syncAndFlush(finalThinner, at: hour(t), store: store)
            handed.append(later.result.nights.count)
            XCTAssertEqual(later.written, [])
        }
        XCTAssertEqual(handed, [0, 0], "not handed over again after the decline")
        let backstop = try await flush([], at: hour(8 + 50.0 / 60).addingTimeInterval(buffer + 1), store: store)
        XCTAssertEqual(backstop, [], "nor offered by the backstop")
        XCTAssertEqual(try mirrorSpan(store), partialWindow, "Health keeps what it has")
    }
}

// MARK: - Decision 70 (#311, #312): the in-bed span, the inclusive stage end, forward-only (70h)
//
// The sessions below carry their own record span (0x00A/0x00C) beside the stages: the strap's in-bed
// span (70a). "An earlier build" is the build before decision 70: no `.inBed` layer, and every stage
// a minute short (its inclusive end minute read as exclusive). As above, the writer can't write in
// the simulator, so a night that reaches the write step is recorded as written (`recordWrite`).

/// `stages` (local hours) as one session record whose own sleep span is `from`–`to` (local hours).
private func recordSession(_ stages: [(Double, Double, UInt8)], record from: Double, _ to: Double) -> [UInt8] {
    var r = session(stages)
    func minute(_ h: Double) -> UInt16 { UInt16(((h + 24) * 60).rounded()) }
    for (i, b) in (le16(minute(from)) + le16(minute(to))).enumerated() { r[0x00A + i] = b }
    return r
}

/// What an earlier build stored and wrote for `stages`: each stage ending a minute short, no `.inBed`.
private func earlierBuild(_ stages: [(Double, Double, UInt8)]) -> [SleepSegment] {
    stages.map { stage in
        let kind: SleepStage = stage.2 == deep ? .asleepDeep : stage.2 == rem ? .asleepREM : stage.2 == awake ? .awake : .asleepCore
        return SleepSegment(start: hour(stage.0), end: hour(stage.1).addingTimeInterval(-60), stage: kind)
    }
}

extension StrapNightHealthTests {
    private var finalEnd: Double { 8 + 50.0 / 60 }

    /// One strap sync at `now` delivering `records` (whole session records), through the production path.
    private func syncRecords(_ records: [[UInt8]], at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let device = makeStrap(firstDelivery)
        device.fetchData[.sleepSession] = (stamp(hour(0).timeIntervalSince1970 - 86_400), records.flatMap { $0 })
        let transport = Transport(device: device)
        let keys = Keys()
        let helio = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                 sink: HelioStoreSink(store: store, observability: observability), findState: HelioFindState(),
                                 clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = helio
        helio.start()
        transport.drain()
        let result = try XCTUnwrap(helio.lastSyncResult)
        XCTAssertEqual(result.interrupted, false)
        return result
    }

    /// One strap flush at `now` as the writer's strap loop mirrors a night (`mirrorStrapNight`, which
    /// carries decision 70h's earlier shapes). The spans written.
    private func strapFlush(_ nights: [[SleepSegment]], at now: Date, store: LocalStore) async throws -> [DateInterval] {
        var written: [DateInterval] = []
        for night in HelioConnection.strapNights(nights, store: store, timeline: timeline, now: now)
        where SleepHealthGate.isReadyToWrite(latestSegmentEnd: night.map(\.end).max(), now: now, finalized: false) {
            let outcome = await HealthKitWriter().mirrorStrapNight(local: store, segments: night)
            if case .declined = outcome { store.noteStrapNightDeclined(night) }
            guard !isUnchanged(outcome) else { continue }
            try recordWrite(night, store: store)
            written.append(span(night))
        }
        return written
    }

    private func isSignatureNoOp(_ outcome: HealthKitWriter.MirrorOutcome) -> Bool {
        if case .unchanged = outcome { return true }
        return false
    }

    /// The state an update meets: `stages` stored and written to Health by an earlier build. The mirror
    /// record's span is `writtenSpan`, or the earlier build's own span. The key and the record.
    private func storeAndWriteAsAnEarlierBuild(_ stages: [(Double, Double, UInt8)], store: LocalStore,
                                               writtenSpan: DateInterval? = nil) throws -> (key: Date, record: String?) {
        let segments = earlierBuild(stages)
        let night = HelioSleepSelection.Night(segments: segments, window: span(segments), strapScore: 81)
        XCTAssertEqual(try store.saveHelioNight(night, device: timeline), .inserted)
        let key = try XCTUnwrap(try rows(store).first).night
        let written = writtenSpan ?? span(segments)
        store.setMirroredNight(night: key, signature: HealthKitWriter.sleepSignature(segments),
                               spanStart: written.start, spanEnd: written.end)
        return (key, mirrorRecord(store, key))
    }

    /// The night this build stages from `record`, from a store with no mirror record.
    private func stagedNow(_ record: [UInt8]) throws -> [SleepSegment] {
        let reference = try makeStore()
        _ = try syncRecords([record], at: hour(10), store: reference)
        return try storedHypnogram(reference)
    }

    /// 70h (i): a night an earlier build wrote, re-delivered after the update. Its only differences are
    /// the `.inBed` layer and the stage end's minute (with a lead-in, an in-bed start 15 minutes earlier
    /// too). The sink keeps it out (58b: it moves the written window without extending it), nothing
    /// offers it, and the strap mirror would be the signature no-op for it, where the ring's (no
    /// earlier shapes) would rewrite it.
    func testANightAnEarlierBuildWroteIsNotRewrittenForItsInBedLayerOrStageMinute() async throws {
        for (label, recordStart) in [("no lead-in", 0.5), ("a 15-minute lead-in", 0.25)] {
            ownership.install(.strapOwnsAllTime)
            let incoming = recordSession(finalNight, record: recordStart, finalEnd)
            let current = try stagedNow(incoming)
            XCTAssertEqual(current.filter { $0.stage == .inBed }.map(\.start), [hour(recordStart)], label)
            let store = try makeStore()
            let (key, record) = try storeAndWriteAsAnEarlierBuild(finalNight, store: store)
            let hypnogram = try XCTUnwrap(try rows(store).first).hypnogramData

            let later = try syncRecords([incoming], at: hour(10), store: store)
            XCTAssertEqual(later.nights.count, 0, "\(label): kept out")
            XCTAssertEqual(try XCTUnwrap(try rows(store).first).hypnogramData, hypnogram, "\(label): the row stands")
            let flushed = try await strapFlush(later.nights.map(\.segments), at: hour(10), store: store)
            XCTAssertEqual(flushed, [], label)
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(14)), [], label)
            XCTAssertEqual(mirrorRecord(store, key), record, label)

            let strap = await HealthKitWriter().mirrorStrapNight(local: store, segments: current)
            XCTAssertTrue(isSignatureNoOp(strap), "\(label): the signature no-op (70h)")
            let withoutShapes = await HealthKitWriter().mirrorSettledNight(local: store, segments: current)
            XCTAssertFalse(isUnchanged(withoutShapes), "\(label): without the earlier shapes it would be rewritten")
            clearMirror(key)
        }
    }

    /// 70h (i), the window Health already holds: an earlier write whose span reached the night's end
    /// minute. The re-delivery's window equals the written span, so it is stored and handed to the flush
    /// as on master (58b), and the strap mirror leaves Health as it is.
    func testAReDeliveryOverTheWrittenSpanIsStoredButNotRewritten() async throws {
        ownership.install(.strapOwnsAllTime)
        let incoming = recordSession(finalNight, record: 0.5, finalEnd)
        let current = try stagedNow(incoming)
        let store = try makeStore()
        let (key, record) = try storeAndWriteAsAnEarlierBuild(finalNight, store: store, writtenSpan: finalWindow)

        let later = try syncRecords([incoming], at: hour(10), store: store)
        XCTAssertEqual(later.nights.map(\.segments), [current], "stored and handed over")
        XCTAssertEqual(try storedHypnogram(store), current, "the card shows the full night with its in-bed layer")
        let flushed = try await strapFlush(later.nights.map(\.segments), at: hour(10), store: store)
        XCTAssertEqual(flushed, [], "not rewritten for the layer and the minute alone")
        XCTAssertEqual(mirrorRecord(store, key), record)
    }

    /// 70h (ii) and 58b: an extension of 10 minutes or more over a night written early is rewritten once,
    /// in-bed layer included. The union delete's span reaches back over the ring's night (before the
    /// switch) and a strap nap already in Health, through a prior write's span: both are in its
    /// exclusions, so neither is deleted.
    func testAnExtensionIsRewrittenOnceAndItsDeleteSparesTheNapAndTheRingsNight() async throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(-12))]))
        let store = try makeStore()
        let ringWindow = DateInterval(start: hour(-25), end: hour(-17))
        let ringSegments = [SleepSegment(start: ringWindow.start, end: ringWindow.end, stage: .inBed),
                            SleepSegment(start: ringWindow.start, end: ringWindow.end, stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = ringSegments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(ringSegments),
                                                  night: SleepNightKey.night(inBedStart: ringWindow.start, inBedEnd: ringWindow.end),
                                                  inBedStart: ringWindow.start, inBedEnd: ringWindow.end,
                                                  sleepOnset: ringWindow.start, sleepWake: ringWindow.end,
                                                  extras: extras, device: .ringConn), .inserted)
        let napWindow = DateInterval(start: hour(-10), end: hour(-9))
        try store.saveNap(start: napWindow.start, end: napWindow.end, asleepMin: 60, isLongNap: false,
                          segments: [SleepSegment(start: napWindow.start, end: napWindow.end, stage: .inBed),
                                     SleepSegment(start: napWindow.start, end: napWindow.end, stage: .asleepCore)],
                          family: .zeppOS)
        try store.markNapWritten(start: napWindow.start)

        let partial = try syncRecords([recordSession(partialNight, record: 0.25, 6)], at: hour(6 + 5.0 / 60), store: store)
        XCTAssertEqual(partial.nights.map(\.window), [DateInterval(start: hour(0.25), end: hour(6))])
        let key = try XCTUnwrap(try rows(store).first { $0.inBedStart == hour(0.25) }).night
        store.setMirroredNight(night: key, signature: HealthKitWriter.sleepSignature(try XCTUnwrap(partial.nights.first).segments),
                               spanStart: hour(-18), spanEnd: hour(6))

        let final = try syncRecords([recordSession(finalNight, record: 0.25, finalEnd)], at: hour(9), store: store)
        let extended = DateInterval(start: hour(0.25), end: hour(finalEnd))
        XCTAssertEqual(final.nights.map(\.window), [extended], "58b: it extends the written night")
        XCTAssertEqual(try XCTUnwrap(final.nights.first).segments.filter { $0.stage == .inBed }.map { DateInterval(start: $0.start, end: $0.end) },
                       [extended], "the write carries the in-bed layer")
        let inMargin = try await strapFlush(final.nights.map(\.segments), at: hour(9), store: store)
        XCTAssertEqual(inMargin, [], "inside its margin")
        let rewritten = try await strapFlush(final.nights.map(\.segments), at: hour(9.5), store: store)
        XCTAssertEqual(rewritten, [extended])
        let record = try XCTUnwrap(store.mirroredNight(night: key))
        let deleted = DateInterval(start: record.spanStart, end: record.spanEnd)
        XCTAssertEqual(deleted, DateInterval(start: hour(-18), end: hour(finalEnd)), "the union delete's span")
        XCTAssertEqual(store.healthWrittenNapWindows(overlapping: deleted.start, to: deleted.end), [napWindow], "the strap's nap is spared")
        XCTAssertEqual(store.otherDevicesNightWindows(.zeppOS, overlapping: deleted.start, to: deleted.end), [ringWindow],
                       "the ring's night is spared")
        let again = try await strapFlush(final.nights.map(\.segments), at: hour(10), store: store)
        XCTAssertEqual(again, [], "rewritten once")
    }

    /// Decision 58 with a lead-in: an in-progress record written early, a re-delivery 5 minutes longer
    /// (jitter, kept out), then the final record (stored, written once over its in-bed span).
    func testAnInProgressRecordWithALeadInGrowsUnderTheExtensionRule() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let early = try syncRecords([recordSession(partialNight, record: 0.25, 6)], at: hour(6 + 5.0 / 60), store: store)
        let earlyWindow = DateInterval(start: hour(0.25), end: hour(6))
        XCTAssertEqual(early.nights.map(\.window), [earlyWindow])
        XCTAssertEqual(try recordWrite(try storedHypnogram(store), store: store), earlyWindow, "written early, the state #274 left")
        let key = try XCTUnwrap(try rows(store).first).night
        let record = mirrorRecord(store, key)

        let jitter = try syncRecords([recordSession(inProgress(until: 6 + 5.0 / 60), record: 0.25, 6 + 5.0 / 60)],
                                     at: hour(6.5), store: store)
        XCTAssertEqual(jitter.nights.count, 0, "5 minutes longer is jitter")
        let jitterFlush = try await strapFlush(jitter.nights.map(\.segments), at: hour(6.5), store: store)
        XCTAssertEqual(jitterFlush, [])
        XCTAssertEqual(mirrorRecord(store, key), record)

        let final = try syncRecords([recordSession(finalNight, record: 0.25, finalEnd)], at: hour(9), store: store)
        let finalSpan = DateInterval(start: hour(0.25), end: hour(finalEnd))
        XCTAssertEqual(final.nights.map(\.window), [finalSpan])
        let written = try await strapFlush(final.nights.map(\.segments), at: hour(9.5), store: store)
        XCTAssertEqual(written, [finalSpan])
        let again = try await strapFlush(final.nights.map(\.segments), at: hour(10), store: store)
        XCTAssertEqual(again, [], "once")
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(row.inBedStart, hour(0.25), "the record's own in-bed start")
        XCTAssertEqual(row.inBedEnd, hour(finalEnd))
    }

    /// Wore both devices, switched to the strap at 23:00: the ring's night began at 22:30 and is stored.
    /// The strap's night is never stored over it, whether its window starts after the switch or a lead-in
    /// widens it across the switch (28a then makes it the ring's time), and the ring keeps its night.
    func testAWiderStrapWindowNeverTakesTheRingsNight() throws {
        let strapStages: [(Double, Double, UInt8)] = [(-0.75, 3, light), (3, 7, deep)]
        let ringWindow = DateInterval(start: hour(-1.5), end: hour(6.5))
        for (label, recordStart) in [("no lead-in", -0.75), ("a lead-in across the switch", -1 - 5.0 / 60)] {
            ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(-1))]))
            let store = try makeStore()
            let ring = [SleepSegment(start: ringWindow.start, end: ringWindow.end, stage: .inBed),
                        SleepSegment(start: ringWindow.start, end: ringWindow.end, stage: .asleepCore)]
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = ring
            XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(ring),
                                                      night: SleepNightKey.night(inBedStart: ringWindow.start, inBedEnd: ringWindow.end),
                                                      inBedStart: ringWindow.start, inBedEnd: ringWindow.end,
                                                      sleepOnset: ringWindow.start, sleepWake: ringWindow.end,
                                                      extras: extras, device: .ringConn), .inserted, label)
            let strap = try syncRecords([recordSession(strapStages, record: recordStart, 7)], at: hour(9), store: store)
            XCTAssertEqual(strap.nights.count, 0, label)
            let stored = try rows(store)
            XCTAssertEqual(stored.map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }, [ringWindow], label)
            XCTAssertEqual(SleepHypnogramCodec.decode(try XCTUnwrap(stored.first).hypnogramData), ring, label)
            XCTAssertTrue(HealthKitWriter.ringOwnsNight(ring, store: store), label)
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(14)), [], label)
        }
    }

    /// A manually edited strap night: a later record with a lead-in that extends it changes nothing.
    func testAManuallyEditedStrapNightIsUntouched() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        _ = try syncRecords([recordSession(partialNight, record: 0.5, 6)], at: hour(6.5), store: store)
        let row = try XCTUnwrap(try rows(store).first)
        row.isManuallyEdited = true
        try store.context.save()
        let before = (row.hypnogramData, row.inBedStart, row.inBedEnd, row.asleepMin)

        let later = try syncRecords([recordSession(finalNight, record: 0.25, finalEnd)], at: hour(9.5), store: store)
        XCTAssertEqual(later.nights.count, 0)
        let after = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(after.hypnogramData, before.0)
        XCTAssertEqual(after.inBedStart, before.1)
        XCTAssertEqual(after.inBedEnd, before.2)
        XCTAssertEqual(after.asleepMin, before.3)
        let flushed = try await strapFlush([], at: hour(12), store: store)
        XCTAssertEqual(flushed, [])
    }

    /// Ring-only (an empty ownership log): a strap record with a lead-in stores and offers nothing.
    func testRingOnlyARecordWithALeadInStoresNothing() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let result = try syncRecords([recordSession(finalNight, record: 0.25, finalEnd)], at: hour(10), store: store)
        XCTAssertEqual(result.nights.count, 0)
        XCTAssertEqual(try rows(store).count, 0)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredNap>()).count, 0)
        XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(14)), [])
    }
}

extension StrapNightHealthTests {
    /// Decision 70k (review-311 S1): a night an earlier build wrote (00:30–08:49, stages only), re-delivered
    /// with the same stages and a record end of 09:05. Its in-bed span alone extends the written night by
    /// 10 minutes or more, so 58b stores it and the flush rewrites it once (70h's no-rewrite guard is not
    /// for an extension). After that nothing offers it again, at +14 h, +20 h or +34 h.
    func testAnExtensionThroughTheInBedSpanAloneIsRewrittenOnceAndNotOfferedAgain() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let (key, _) = try storeAndWriteAsAnEarlierBuild(finalNight, store: store)
        let recordEnd = 9 + 5.0 / 60
        let later = try syncRecords([recordSession(finalNight, record: 0.5, recordEnd)], at: hour(9.5), store: store)
        let extended = DateInterval(start: hour(0.5), end: hour(recordEnd))
        XCTAssertEqual(later.nights.map(\.window), [extended], "58b: stored as an extension")
        XCTAssertEqual(try XCTUnwrap(try rows(store).first).inBedEnd, hour(recordEnd))
        let written = try await strapFlush(later.nights.map(\.segments), at: hour(9.5), store: store)
        XCTAssertEqual(written, [extended], "rewritten once")
        let record = mirrorRecord(store, key)
        for offset in [14.0, 20, 34] {
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(9.5 + offset)), [], "+\(offset) h")
            let again = try await strapFlush([], at: hour(9.5 + offset), store: store)
            XCTAssertEqual(again, [], "+\(offset) h")
        }
        XCTAssertEqual(mirrorRecord(store, key), record, "Health keeps the rewrite")
    }
}

// MARK: - Decision 71 (#278): a long mid-night awakening no longer splits the night
//
// The strap records the night as two sleeps with an awake gap of hours between them: sleep A (23:00–
// 02:00) and a second sleep after the awakening (05:30–07:00). Both are overnight sleeps of one night
// key, so decision 71b joins them into one night (23:00–07:00, 270 asleep minutes, the gap neither
// asleep nor in bed). Before it, once A was in Apple Health the second sleep was stored as neither a
// night nor a nap. As above, a write is recorded as the writer records it (`recordWrite`), and what
// the union delete covers is the record's span less the writer's exclusions.

/// The second sleep, after an awakening of three and a half hours: 05:30–07:00 (90 min asleep).
private let afterTheAwakening: [(Double, Double, UInt8)] = [(5.5, 6, light), (6, 7, rem)]

extension StrapNightHealthTests {
    private var joinedNight: DateInterval { DateInterval(start: hour(-1), end: hour(7)) }

    /// The fragments' in-bed spans. Decision 74 (amended, needs ratification): an awake run of the fill
    /// (74a) is in bed but no fragment, so it is left out; on a night with no fill this is every `.inBed`.
    private func inBedSpans(_ segments: [SleepSegment]) -> [DateInterval] {
        HelioSleepSelection.withoutAwakeFill(segments).filter { $0.stage == .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func napRows(_ store: LocalStore) throws -> [DateInterval] {
        try store.context.fetch(FetchDescriptor<StoredNap>(sortBy: [SortDescriptor(\.start)])).map { DateInterval(start: $0.start, end: $0.end) }
    }

    /// The joined night as stored: one row over the union, both sleeps' stages and one `.inBed` each,
    /// and nothing for the awake gap.
    /// `wornThroughTheGap`: the fixture's activity minutes carry the strap's heart rate through the whole
    /// gap (02:00–05:30), so decision 74a fills exactly that gap with one awake run (74f(1)); otherwise
    /// the store holds no heart rate there and there is no run at all.
    /// `leadIn` (decision 77, amended): the in-bed lead-in the fixture's stored heart rate gives the night
    /// before its first fragment, or nil for none. The row's window starts there; everything else is
    /// judged on the night without it.
    private func assertTheJoinedNightIsStored(_ store: LocalStore, _ label: String = "", wornThroughTheGap: Bool = false,
                                              leadIn: DateInterval? = nil,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let stored = try rows(store)
        XCTAssertEqual(stored.map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) },
                       [DateInterval(start: leadIn?.start ?? joinedNight.start, end: joinedNight.end)], label, file: file, line: line)
        XCTAssertEqual(stored.map(\.asleepMin), [270], label, file: file, line: line)
        XCTAssertEqual(HelioSleepSelection.leadIn(in: try storedHypnogram(store)), leadIn, "\(label): the lead-in", file: file, line: line)
        let segments = HelioSleepSelection.withoutLeadIn(try storedHypnogram(store))
        XCTAssertEqual(inBedSpans(segments), [DateInterval(start: hour(-1), end: hour(2)), DateInterval(start: hour(5.5), end: hour(7))],
                       label, file: file, line: line)
        // Decision 74f (ratified amendment): nothing in the gap but the awake fill of 74a, and that fill
        // exactly: one run over the whole gap when the fixture is worn through it, none otherwise. A run
        // reaching into a fragment, a duplicated run or a partial one fails here.
        XCTAssertFalse(HelioSleepSelection.withoutAwakeFill(segments).contains { $0.start < hour(5.5) && hour(2) < $0.end },
                       "\(label): the gap stays a gap", file: file, line: line)
        XCTAssertEqual(HelioSleepSelection.awakeFillRuns(in: segments),
                       wornThroughTheGap ? [DateInterval(start: hour(2), end: hour(5.5))] : [],
                       "\(label): the exact awake fill", file: file, line: line)
        XCTAssertEqual(segments.filter { $0.start < hour(5.5) && hour(2) < $0.end }.count, wornThroughTheGap ? 2 : 0,
                       "\(label): one .inBed and one .awake over the gap, no duplicate", file: file, line: line)
        XCTAssertEqual(try napRows(store), [], "\(label): no nap beside the night", file: file, line: line)
    }

    /// #278's shape: A was stored at 02:15 and is in Health. The morning sync delivers A and the second
    /// sleep: one joined night that extends the written one (58b), stored in A's row and rewritten once
    /// after its margin. The rewrite's union delete covers A's old span, so Health holds the joined night
    /// once and nothing of A twice.
    func testASecondSleepAfterALongAwakeningExtendsTheFirstPartAlreadyInHealth() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let first = try syncSessions([sleepA], at: hour(2.25), store: store)
            XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))])
            let firstPart = try recordWrite(try storedHypnogram(store), store: store)
            let key = try XCTUnwrap(try rows(store).first).night

            let morning = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            XCTAssertEqual(morning.nights.map(\.window), [joinedNight], "stored and handed to the flush")
            try assertTheJoinedNightIsStored(store)
            XCTAssertEqual(try XCTUnwrap(try rows(store).first).night, key, "in A's row")

            let written = try await strapFlush(morning.nights.map(\.segments), at: hour(7.5), store: store)
            XCTAssertEqual(written, [joinedNight], "rewritten once, as an extension")
            let record = try XCTUnwrap(store.mirroredNight(night: key))
            XCTAssertEqual(record.signature, HealthKitWriter.sleepSignature(try storedHypnogram(store)))
            let deleted = DateInterval(start: record.spanStart, end: record.spanEnd)
            XCTAssertEqual(deleted, joinedNight)
            XCTAssertTrue(deleted.start <= firstPart.start && firstPart.end <= deleted.end, "A's old samples are inside the union delete")
            XCTAssertEqual(store.healthWrittenNapWindows(overlapping: deleted.start, to: deleted.end), [])
            XCTAssertEqual(extensionBreadcrumbs().count, 1)

            let again = try syncSessions([sleepA, afterTheAwakening], at: hour(8.5), store: store)
            let rewritten = try await strapFlush(again.nights.map(\.segments), at: hour(8.5), store: store)
            XCTAssertEqual(rewritten, [], "the signature no-op")
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(12)), [])
            try assertTheJoinedNightIsStored(store)
        }
    }

    /// Before the first part is written: both sleeps arrive together on the morning sync, or A was
    /// stored at 02:15 (inside its margin) and never written. One joined night, written once, after the
    /// settle margin of its own end; no extension.
    func testANightWithALongAwakeningIsWrittenOnceAfterItsMarginWhenNothingWasWrittenBefore() async throws {
        for firstPartStoredFirst in [false, true] {
            try await inFixedZone {
                let label = "first part stored first: \(firstPartStoredFirst)"
                ownership.install(.strapOwnsAllTime)
                let crumbs = extensionBreadcrumbs().count
                let store = try makeStore()
                var written: [DateInterval] = []
                if firstPartStoredFirst {
                    let first = try syncSessions([sleepA], at: hour(2.25), store: store)
                    written += try await strapFlush(first.nights.map(\.segments), at: hour(2.25), store: store)
                }
                let morning = try syncSessions([sleepA, afterTheAwakening], at: hour(7 + 10.0 / 60), store: store)
                XCTAssertEqual(morning.nights.map(\.window), [joinedNight], label)
                try assertTheJoinedNightIsStored(store, label)
                written += try await strapFlush(morning.nights.map(\.segments), at: hour(7 + 10.0 / 60), store: store)
                XCTAssertEqual(written, [], "\(label): inside the margin")
                written += try await strapFlush(morning.nights.map(\.segments), at: hour(7.5), store: store)
                written += try await strapFlush(morning.nights.map(\.segments), at: hour(8), store: store)
                written += try await strapFlush([], at: hour(12), store: store)
                XCTAssertEqual(written, [joinedNight], "\(label): written once")
                XCTAssertEqual(try mirrorSpan(store), joinedNight, label)
                XCTAssertEqual(extensionBreadcrumbs().count, crumbs, "\(label): nothing was written early, so nothing extended")
            }
        }
    }

    /// A nap an earlier build stored for the later sleep (its night split as A plus a nap), possibly
    /// already in Health, with A possibly in Health too. The joined night's store prunes the auto nap
    /// it now covers, so no nap row stands beside the night and the nap is not offered to Health again;
    /// the night's write then no longer excludes the nap's window from its union delete, which covers
    /// it, so the nap's earlier samples are cleared and the sleep is not counted twice.
    func testANapStoredForTheLaterSleepGivesWayToTheJoinedNight() async throws {
        for (firstPartInHealth, napInHealth) in [(false, false), (false, true), (true, false), (true, true)] {
            try await inFixedZone {
                let label = "A in Health: \(firstPartInHealth), nap in Health: \(napInHealth)"
                ownership.install(.strapOwnsAllTime)
                let store = try makeStore()
                _ = try syncSessions([sleepA], at: hour(2.25), store: store)
                if firstPartInHealth { try recordWrite(try storedHypnogram(store), store: store) }
                let napWindow = DateInterval(start: hour(5.5), end: hour(7))
                try store.saveNap(start: napWindow.start, end: napWindow.end, asleepMin: 90, isLongNap: false,
                                  segments: [SleepSegment(start: napWindow.start, end: napWindow.end, stage: .inBed),
                                             SleepSegment(start: napWindow.start, end: napWindow.end, stage: .asleepCore)],
                                  family: .zeppOS)
                if napInHealth { try store.markNapWritten(start: napWindow.start) }
                XCTAssertEqual(try napRows(store), [napWindow], label)

                let morning = try syncSessions([sleepA, afterTheAwakening], at: hour(8.5), store: store)
                XCTAssertEqual(morning.nights.map(\.window), [joinedNight], label)
                try assertTheJoinedNightIsStored(store, label)
                XCTAssertEqual(try store.pendingNaps().map(\.start), [], "\(label): no nap offered to Health")

                let written = try await strapFlush(morning.nights.map(\.segments), at: hour(8.5), store: store)
                XCTAssertEqual(written, [joinedNight], label)
                let record = try XCTUnwrap(try mirrorSpan(store))
                XCTAssertTrue(record.start <= napWindow.start && napWindow.end <= record.end, "\(label): the nap's span is inside the union delete")
                XCTAssertEqual(store.healthWrittenNapWindows(overlapping: record.start, to: record.end), [],
                               "\(label): and not excluded from it")
                XCTAssertEqual(store.otherDevicesNightWindows(.zeppOS, overlapping: record.start, to: record.end), [], label)

                let again = try syncSessions([sleepA, afterTheAwakening], at: hour(10), store: store)
                XCTAssertEqual(try napRows(store), [], "\(label): the later sleep is part of the night, never a nap again")
                let rewritten = try await strapFlush(again.nights.map(\.segments), at: hour(10), store: store)
                XCTAssertEqual(rewritten, [], label)
            }
        }
    }

    /// Decision 58 on the joined night: A is in Health; the second sleep is read while it goes on. Each
    /// copy that grows the joined night by 10 minutes or more is stored and written once after its
    /// margin; a copy 5 minutes longer is jitter and kept out.
    func testAGrowingSecondSleepKeepsExtendingTheJoinedNightOncePerGrowth() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try syncSessions([sleepA], at: hour(2.25), store: store)
            try recordWrite(try storedHypnogram(store), store: store)
            let key = try XCTUnwrap(try rows(store).first).night
            var written: [DateInterval] = []

            let early = try syncSessions([sleepA, [(5.5, 6, light)]], at: hour(6 + 5.0 / 60), store: store)
            let toSix = DateInterval(start: hour(-1), end: hour(6))
            XCTAssertEqual(early.nights.map(\.window), [toSix], "it extends the written first part")
            written += try await strapFlush(early.nights.map(\.segments), at: hour(6 + 5.0 / 60), store: store)
            XCTAssertEqual(written, [], "inside its margin")
            written += try await strapFlush(early.nights.map(\.segments), at: hour(6 + 25.0 / 60), store: store)
            XCTAssertEqual(written, [toSix])
            let record = mirrorRecord(store, key)

            let jitter = try syncSessions([sleepA, [(5.5, 6 + 5.0 / 60, light)]], at: hour(6.5), store: store)
            XCTAssertEqual(jitter.nights.count, 0, "5 minutes longer is jitter")
            written += try await strapFlush(jitter.nights.map(\.segments), at: hour(6.5), store: store)
            XCTAssertEqual(mirrorRecord(store, key), record)

            let final = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            XCTAssertEqual(final.nights.map(\.window), [joinedNight])
            written += try await strapFlush(final.nights.map(\.segments), at: hour(7.5), store: store)
            written += try await strapFlush(final.nights.map(\.segments), at: hour(8), store: store)
            XCTAssertEqual(written, [toSix, joinedNight], "one write per growth")
            XCTAssertEqual(try mirrorSpan(store), joinedNight)
            XCTAssertEqual(extensionBreadcrumbs().count, 2)
            try assertTheJoinedNightIsStored(store)
        }
    }

    /// Wore both devices: the ring went to bed with the night (22:30–06:30, stored), the switch to the
    /// strap came at 23:00. The strap's two sleeps (23:30–02:00, 05:30–07:00) are its own and join, and
    /// the joined night is the ring's night's time (28a): never stored, never offered, never a nap.
    func testAJoinedStrapNightNeverTakesTheRingsNight() throws {
        try inFixedZoneSync {
            ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(-1))]))
            let store = try makeStore()
            let ringWindow = DateInterval(start: hour(-1.5), end: hour(6.5))
            let ring = [SleepSegment(start: ringWindow.start, end: ringWindow.end, stage: .inBed),
                        SleepSegment(start: ringWindow.start, end: ringWindow.end, stage: .asleepCore)]
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = ring
            XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(ring),
                                                      night: SleepNightKey.night(inBedStart: ringWindow.start, inBedEnd: ringWindow.end),
                                                      inBedStart: ringWindow.start, inBedEnd: ringWindow.end,
                                                      sleepOnset: ringWindow.start, sleepWake: ringWindow.end,
                                                      extras: extras, device: .ringConn), .inserted)
            let strap = try syncSessions([[(-0.5, 2, light)], afterTheAwakening], at: hour(9), store: store)
            XCTAssertEqual(strap.nights.count, 0)
            let stored = try rows(store)
            XCTAssertEqual(stored.map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }, [ringWindow])
            XCTAssertEqual(SleepHypnogramCodec.decode(try XCTUnwrap(stored.first).hypnogramData), ring)
            XCTAssertEqual(try napRows(store), [])
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(14)), [])
        }
    }

    /// Decision 71d: ownership is judged on each raw sleep before the join. A switch at 03:30, in the
    /// awake gap: the strap keeps only the sleep in its own time, whichever way the switch went.
    func testASwitchInTheAwakeGapLeavesEachSleepToItsOwnDevice() throws {
        let cases: [(String, DeviceOwnershipLog, DateInterval)] = [
            ("ring to strap", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(3.5))]),
             DateInterval(start: hour(5.5), end: hour(7))),
            ("strap to ring", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast),
                                                           .init(family: .ringConn, since: hour(3.5))]),
             DateInterval(start: hour(-1), end: hour(2))),
        ]
        for (label, log, strapsOwn) in cases {
            try inFixedZoneSync {
                ownership.install(log)
                let store = try makeStore()
                let result = try syncSessions([sleepA, afterTheAwakening], at: hour(9), store: store)
                XCTAssertEqual(result.nights.map(\.window), [strapsOwn], label)
                XCTAssertEqual(try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }, [strapsOwn], label)
                XCTAssertEqual(try napRows(store), [], label)
            }
        }
    }

    /// A manually edited first part is the person's: the joined night overlaps it, so it is neither
    /// stored nor written, the second sleep is no nap, and the row and Health record are unchanged.
    func testAManuallyEditedFirstPartIsUntouchedByTheJoinedNight() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try syncSessions([sleepA], at: hour(2.25), store: store)
            try recordWrite(try storedHypnogram(store), store: store)
            let row = try XCTUnwrap(try rows(store).first)
            row.isManuallyEdited = true
            row.editedInBedStart = hour(-1)
            row.editedInBedEnd = hour(2)
            try store.context.save()
            let before = (row.hypnogramData, row.inBedStart, row.inBedEnd, row.asleepMin)
            let record = mirrorRecord(store, row.night)

            let morning = try syncSessions([sleepA, afterTheAwakening], at: hour(8), store: store)
            XCTAssertEqual(morning.nights.count, 0)
            let after = try XCTUnwrap(try rows(store).first)
            XCTAssertEqual(try rows(store).count, 1)
            XCTAssertEqual(after.hypnogramData, before.0)
            XCTAssertEqual(after.inBedStart, before.1)
            XCTAssertEqual(after.inBedEnd, before.2)
            XCTAssertEqual(after.asleepMin, before.3)
            XCTAssertEqual(try napRows(store), [])
            let flushed = try await strapFlush(morning.nights.map(\.segments), at: hour(8), store: store)
            XCTAssertEqual(flushed, [])
            XCTAssertEqual(mirrorRecord(store, row.night), record)
            XCTAssertEqual(extensionBreadcrumbs(), [])
        }
    }

    /// Ring-only (an empty ownership log): the strap's two sleeps store, offer and write nothing.
    func testRingOnlyANightWithALongAwakeningStoresNothing() throws {
        try inFixedZoneSync {
            ownership.install(DeviceOwnershipLog())
            let store = try makeStore()
            let result = try syncSessions([sleepA, afterTheAwakening], at: hour(9), store: store)
            XCTAssertEqual(result.nights.count, 0)
            XCTAssertEqual(try rows(store).count, 0)
            XCTAssertEqual(try napRows(store), [])
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(14)), [])
            XCTAssertEqual(extensionBreadcrumbs(), [])
        }
    }

    /// `inFixedZone` for a synchronous body.
    private func inFixedZoneSync(_ body: () throws -> Void) throws {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let nights = (-2...2).map { hour(Double($0) * 24) }
        nights.forEach(clearMirror)
        defer {
            nights.forEach(clearMirror)
            NSTimeZone.default = saved
        }
        try body()
    }
}

// MARK: - Review-snh with the later sleep recorded in another zone (decision 71g)

/// `stages` (local hours of `hour(0)`'s day, the phone's zone) as a session whose own local midnight is
/// `west` hours later than the phone's: recorded in a zone `west` hours west of it. Same instants.
private func session(_ stages: [(Double, Double, UInt8)], recordedHoursWest west: Double) -> [UInt8] {
    var r = session(stages.map { ($0.0 - west, $0.1 - west, $0.2) })
    let midnight = le32(UInt32(hour(0).timeIntervalSince1970 + west * 3600))
    for (i, b) in (midnight + midnight).enumerated() { r[i] = b }
    return r
}

extension StrapNightHealthTests {
    /// A was stored at 02:15, inside the margin. The morning sync carries A again (kept as thinner) and B.
    ///
    /// Decision 71g: B is recorded in a zone an hour west of A's (the strap's local midnight moved, as
    /// on a trip), so its own night key differs from A's and 71b keeps the two apart (85 minutes). The
    /// store keys both in the phone's calendar, so B, the fuller, still replaces A's row in place: the
    /// shape these three tests pin (review-snh B-1).
    private func storeAThenSyncAAgainAndB(at now: Date, store: LocalStore) throws -> HelioSyncResult {
        let first = try syncSessions([sleepA], at: hour(2.25), store: store)
        XCTAssertEqual(first.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(2))], "A stored, held by the margin")
        let morning = try syncRecords([session(sleepAAgain), session(sleepB, recordedHoursWest: 1)], at: now, store: store)
        let rows = try rows(store)
        XCTAssertEqual(rows.count, 1, "one row for the key")
        XCTAssertEqual(rows.first?.inBedStart, hour(3.5), "B replaced A's row in place")
        XCTAssertEqual(rows.first?.inBedEnd, hour(7))
        return morning
    }

    /// Review-snh test 1: the sync carrying A again and B hands the flush B, and no night that isn't a
    /// current stored row's (the stale A, which B replaced in this same sync). This also pins the
    /// re-flush churn: `ContentView.flushHealth` re-flushes `lastSyncResult.nights` until the next sync,
    /// and `[B, staleA]` there would write B, delete A, write A and delete B on every such flush.
    func testASyncWhoseLaterSleepReplacedTheKeptNightHandsOverOnlyTheStoredRow() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndB(at: hour(7.5), store: store)
            let current = try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }
            XCTAssertTrue(morning.nights.contains { $0.window == DateInterval(start: hour(3.5), end: hour(7)) }, "B is handed over")
            XCTAssertEqual(morning.nights.filter { !current.contains($0.window) }.map(\.window), [], "no stale A")
        }
    }

    /// Review-snh test 2: at 07:10 B hasn't settled. Nothing for the key is ready to write, so nothing
    /// reaches the writer's write step and no mirror record is left. A flush at 07:30 (ContentView's,
    /// over the last sync's result) offers exactly B, ready.
    func testBeforeTheReplacingSleepSettlesNothingIsWrittenForTheKey() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndB(at: hour(7 + 10.0 / 60), store: store)
            let key = try XCTUnwrap(try rows(store).first).night

            let input = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: clock)
            let ready = input.filter { SleepHealthGate.isReadyToWrite(latestSegmentEnd: $0.map(\.end).max(), now: clock, finalized: false) }
            XCTAssertEqual(ready.compactMap(window), [], "no night for the key is ready at 07:10")
            for night in ready {
                let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: night)
                XCTAssertTrue(isUnchanged(outcome), "nothing reaches the write step")
            }
            let flush = await HelioConnection.flushStrap(HealthKitWriter(), store: store, timeline: timeline,
                                                         nights: morning.nights.map(\.segments), now: clock)
            XCTAssertEqual(flush.sleepSegments, 0)
            XCTAssertNil(store.mirroredNight(night: key), "no mirror record")

            let later = hour(7.5)
            let laterInput = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: later)
            XCTAssertEqual(laterInput, [try storedHypnogram(store)], "exactly B, as stored")
            XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: hour(7), now: later, finalized: false))
        }
    }

    /// Review-snh test 3: both settled at 07:30. The flush input is exactly B's stored hypnogram: one
    /// night for the key.
    func testWhenBothHaveSettledTheFlushInputIsTheReplacingSleepAlone() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let morning = try storeAThenSyncAAgainAndB(at: hour(7.5), store: store)
            let input = HelioConnection.strapNights(morning.nights.map(\.segments), store: store, timeline: timeline, now: clock)
            let stored = try storedHypnogram(store)
            XCTAssertEqual(window(stored), DateInterval(start: hour(3.5), end: hour(7)))
            XCTAssertEqual(input, [stored])
        }
    }
}



// MARK: - Decision 71i: the awake gap of a joined night is no sleep window
//
// Three strap-only readers judge a night's in-bed spans (one per fragment) instead of its union
// window: the skin-temperature gate in the sink, the nightly skin-temperature verdict of
// `saveHelioNight`, and the night score's overnight HRV (save path and repair pass). A night that
// wasn't joined has one span, its window, so it is judged exactly as before.

/// `count` 8-byte activity minutes, all worn (kind 0x01, HR 55).
private func wornMinutes(_ count: Int) -> [UInt8] {
    (0..<count).flatMap { _ in [UInt8]([0x01, 0x08, 0, 55, 0, 0, 0, 0]) }
}

/// `count` 8-byte temperature minutes at `centi` hundredths of a °C.
private func temperatureMinutes(_ count: Int, centi: UInt16) -> [UInt8] {
    (0..<count).flatMap { _ in [0xff, 0x7f] + le16(centi) + [0x5a, 0x5a, 0x5a, 0x5a] }
}

extension StrapNightHealthTests {
    /// A sync delivering `sessions`, then worn activity and skin temperature for every minute from
    /// 23:00 to 07:00, through the production path. The stored temperature minutes' local hours.
    private func syncWithTemperatures(_ sessions: [[(Double, Double, UInt8)]], store: LocalStore) throws -> [Date] {
        clock = hour(9)
        let device = makeStrap(sessions[0])
        let from = hour(-1).timeIntervalSince1970
        device.fetchData[.sleepSession] = (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(session))
        device.fetchData[.activity] = (stamp(from), wornMinutes(480))
        device.fetchData[.temperature] = (stamp(from), temperatureMinutes(480, centi: 3350))
        let transport = Transport(device: device)
        let keys = Keys()
        let helio = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                 sink: HelioStoreSink(store: store, observability: observability), findState: HelioFindState(),
                                 clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = helio
        helio.start()
        transport.drain()
        XCTAssertEqual(helio.lastSyncResult?.interrupted, false)
        let kind = MetricKind.temperature.rawValue
        return try store.context.fetch(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == kind },
                                                                     sortBy: [SortDescriptor(\.start)])).map(\.start)
    }

    /// The gate: a temperature minute in the awake gap (03:30) is not kept; one in either fragment
    /// (01:00, 06:00) is. Over a night that wasn't joined (23:00–07:00), 03:30 is kept as before.
    func testATemperatureMinuteInTheAwakeGapIsNotGatedIn() throws {
        try inFixedZoneSync {
            ownership.install(.strapOwnsAllTime)
            let joined = try syncWithTemperatures([sleepA, afterTheAwakening], store: try makeStore())
            XCTAssertTrue(joined.contains(hour(1)), "in the first fragment")
            XCTAssertTrue(joined.contains(hour(6)), "in the second fragment")
            XCTAssertFalse(joined.contains(hour(3.5)), "in the awake gap")
            XCTAssertFalse(joined.contains { $0 >= hour(2) && $0 < hour(5.5) }, "nothing from the gap")

            let single = try syncWithTemperatures([[(-1, 3, light), (3, 7, deep)]], store: try makeStore())
            XCTAssertTrue(single.contains(hour(3.5)), "a night that wasn't joined: as before")
            XCTAssertEqual(single.count, 480)
        }
    }

    /// The verdict and the overnight HRV, as `finishSync` re-saves the night: readings in the awake gap
    /// (31 °C, 90 ms) are in neither; the same readings inside a fragment are. A night that wasn't
    /// joined judges its whole window, as before. The repair pass judges the same spans.
    func testTemperatureAndHRVInTheAwakeGapAreNotInTheNightsVerdictOrScore() throws {
        let fragmentHRV: [Double] = [41, 47, 44]
        let expected = try XCTUnwrap(SleepStress.overnightScore(rmssd: [41, 44, 47]))
        XCTAssertNotEqual(SleepStress.overnightScore(rmssd: [41, 44, 47, 90]), expected, "the gap's reading would move the score")
        for joined in [true, false] {
            try inFixedZoneSync {
                let label = joined ? "joined" : "not joined"
                ownership.install(.strapOwnsAllTime)
                let store = try makeStore()
                let result = try syncSessions(joined ? [sleepA, afterTheAwakening] : [[(-1, 3, light), (3, 7, deep)]],
                                              at: hour(9), store: store)
                let night = try XCTUnwrap(result.nights.first, label)
                // Every 5 minutes, 23:00–07:00: 34 °C in bed, 31 °C in the joined night's awake gap.
                let temperatures = stride(from: hour(-1).timeIntervalSince1970, to: hour(7).timeIntervalSince1970, by: 300).map { t in
                    let time = Date(timeIntervalSince1970: t)
                    let inGap = time > hour(2) && time < hour(5.5)
                    return QuantitySample(kind: .temperature, start: time, value: inGap ? 31 : 34)
                }
                _ = try store.ingest(temperatures, device: timeline)
                let hrv = zip([hour(0), hour(1), hour(6)], fragmentHRV).map { QuantitySample(kind: .hrvSDNN, start: $0, value: $1) }
                    + [QuantitySample(kind: .hrvSDNN, start: hour(3.5), value: 90)]
                _ = try store.ingest(hrv, device: timeline)

                XCTAssertEqual(try store.saveHelioNight(night, device: timeline), .updated, label)
                let row = try XCTUnwrap(try rows(store).first, label)
                let allTemps = temperatures.map(\.value)
                if joined {
                    XCTAssertEqual(row.skinTempC, 34, accuracy: 1e-9, "\(label): the gap's 31 °C is not in the mean")
                    XCTAssertEqual(row.stressScore, expected, "\(label): the gap's HRV is not in the score")
                } else {
                    XCTAssertEqual(row.skinTempC, allTemps.reduce(0, +) / Double(allTemps.count), accuracy: 1e-9, label)
                    XCTAssertEqual(row.stressScore, SleepStress.overnightScore(rmssd: [41, 44, 47, 90]), label)
                }

                // The repair pass, for both of its branches (both scores missing; only the stress score).
                let stress = row.stressScore
                for clearSleepScore in [true, false] {
                    row.stressScore = 0
                    if clearSleepScore { row.sleepScore = 0 }
                    try store.context.save()
                    _ = try store.scoreUnscoredHelioNights()
                    XCTAssertEqual(try XCTUnwrap(try rows(store).first).stressScore, stress,
                                   "\(label): the repair pass judges the same spans (sleep score cleared: \(clearSleepScore))")
                }
            }
        }
    }
}

// MARK: - Decision 73 (#278): a later sleep the strap marks only per minute joins its night
//
// The strap writes one session record per night: sleep A (23:00–02:00). The later sleep after a long
// awakening (05:30–07:00) is in no record, only in the activity minutes, as kind sleep (`0x78`). Those
// minutes are a block (73a/73b) that joins A's night (71b) like a second session would, so the result
// is the night decision 71 already stores and writes (`assertTheJoinedNightIsStored`). A block that
// would stand alone is used nowhere (73c). Every minute here is synthetic.

/// Activity minute kinds (§6.5): asleep, and an ordinary kind for the minutes up.
private let asleepKind = ZeppActivityMinute.kindSleep, upKind: UInt8 = 0x01

/// The night's activity minutes as the strap marks them, to `until`: asleep in A (23:00–02:00, inside
/// A's record, so never a block), up 02:00–05:30, asleep 05:30–07:00, up after.
private func nightActivity(until: Double) -> [(Double, Double, UInt8)] {
    [(-1, 2, asleepKind), (2, 5.5, upKind), (5.5, 7, asleepKind), (7, until, upKind)].filter { $0.0 < until }
        .map { ($0.0, min($0.1, until), $0.2) }
}

extension StrapNightHealthTests {
    /// One strap sync at `now` delivering each of `sessions` as its own session record and the activity
    /// minutes `activity` (contiguous spans of local hours, each one kind), through the production path.
    /// `temperatureFrom`: skin temperature minutes from that local hour to `now`.
    /// `noHeartRateBefore` (decision 77, merge of #329): minutes before that local hour carry the strap's
    /// "no reading" heart-rate byte, so the night gets no in-bed lead-in from the stored heart rate.
    private func syncWithActivity(_ sessions: [[(Double, Double, UInt8)]], activity: [(Double, Double, UInt8)],
                                  temperatureFrom: Double? = nil, at now: Date, store: LocalStore,
                                  noHeartRateBefore: Double? = nil) throws -> HelioSyncResult {
        clock = now
        let device = makeStrap(sessions[0])
        device.fetchData[.sleepSession] = (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(session))
        if let temperatureFrom {
            let count = Int((now.timeIntervalSince(hour(temperatureFrom)) / 60).rounded())
            device.fetchData[.temperature] = (stamp(hour(temperatureFrom).timeIntervalSince1970), temperatureMinutes(count, centi: 3350))
        }
        if let first = activity.first {
            let bytes = activity.flatMap { span in
                (0..<Int(((span.1 - span.0) * 60).rounded())).flatMap { i -> [UInt8] in
                    let worn = noHeartRateBefore.map { span.0 + Double(i) / 60 >= $0 - 1e-9 } ?? true
                    return [span.2, 0x08, 0, worn ? 55 : 0, 0, 0, 0, 0]
                }
            }
            device.fetchData[.activity] = (stamp(hour(first.0).timeIntervalSince1970), bytes)
        }
        let transport = Transport(device: device)
        let keys = Keys()
        let helio = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                 sink: HelioStoreSink(store: store, observability: observability), findState: HelioFindState(),
                                 clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: true)
        transport.session = helio
        helio.start()
        transport.drain()
        let result = try XCTUnwrap(helio.lastSyncResult)
        XCTAssertEqual(result.interrupted, false)
        return result
    }

    private var sleepAWindow: DateInterval { DateInterval(start: hour(-1), end: hour(2)) }

    /// The owner's shape: A was stored at 02:15 and is in Health. The morning sync carries the same
    /// record and the night's activity minutes: one joined night, stored in A's row, rewritten once as
    /// an extension (58b) whose union delete covers A's old span, so nothing is counted twice. A later
    /// sync with the same data writes nothing.
    func testALaterSleepInTheActivityMinutesExtendsTheNightAlreadyInHealth() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let first = try syncWithActivity([sleepA], activity: nightActivity(until: 2.25), at: hour(2.25), store: store)
            XCTAssertEqual(first.nights.map(\.window), [sleepAWindow])
            let firstPart = try recordWrite(try storedHypnogram(store), store: store)
            let key = try XCTUnwrap(try rows(store).first).night

            let morning = try syncWithActivity([sleepA], activity: nightActivity(until: 8), at: hour(8), store: store)
            XCTAssertEqual(morning.nights.map(\.window), [joinedNight], "stored and handed to the flush")
            try assertTheJoinedNightIsStored(store, wornThroughTheGap: true)
            XCTAssertEqual(try XCTUnwrap(try rows(store).first).night, key, "in A's row")
            XCTAssertEqual(morning.sleepRound?.activityBlocksJoined, 1)
            XCTAssertEqual(morning.sleepRound?.activityBlocksAlone, 0)

            let written = try await strapFlush(morning.nights.map(\.segments), at: hour(8), store: store)
            XCTAssertEqual(written, [joinedNight], "rewritten once, as an extension")
            let record = try XCTUnwrap(store.mirroredNight(night: key))
            XCTAssertEqual(record.signature, HealthKitWriter.sleepSignature(try storedHypnogram(store)))
            let deleted = DateInterval(start: record.spanStart, end: record.spanEnd)
            XCTAssertEqual(deleted, joinedNight)
            XCTAssertTrue(deleted.start <= firstPart.start && firstPart.end <= deleted.end, "A's old samples are inside the union delete")
            XCTAssertEqual(store.healthWrittenNapWindows(overlapping: deleted.start, to: deleted.end), [])
            XCTAssertEqual(extensionBreadcrumbs().count, 1)

            let again = try syncWithActivity([sleepA], activity: nightActivity(until: 9), at: hour(9), store: store)
            let rewritten = try await strapFlush(again.nights.map(\.segments), at: hour(9), store: store)
            XCTAssertEqual(rewritten, [], "the signature no-op")
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(13)), [])
            try assertTheJoinedNightIsStored(store, wornThroughTheGap: true)
            XCTAssertEqual(extensionBreadcrumbs().count, 1)
        }
    }

    /// Before A is written (it arrives with the block on the morning sync, or was stored at 02:15 inside
    /// its margin and never written): one joined night, written once, no extension.
    func testALaterSleepInTheActivityMinutesIsWrittenOnceWithItsNightWhenNothingWasWrittenBefore() async throws {
        for firstPartStoredFirst in [false, true] {
            try await inFixedZone {
                let label = "first part stored first: \(firstPartStoredFirst)"
                ownership.install(.strapOwnsAllTime)
                let crumbs = extensionBreadcrumbs().count
                let store = try makeStore()
                var written: [DateInterval] = []
                if firstPartStoredFirst {
                    let first = try syncWithActivity([sleepA], activity: nightActivity(until: 2.25), at: hour(2.25), store: store)
                    written += try await strapFlush(first.nights.map(\.segments), at: hour(2.25), store: store)
                }
                let morning = try syncWithActivity([sleepA], activity: nightActivity(until: 7.5), at: hour(7.5), store: store)
                XCTAssertEqual(morning.nights.map(\.window), [joinedNight], label)
                try assertTheJoinedNightIsStored(store, label, wornThroughTheGap: true)
                written += try await strapFlush(morning.nights.map(\.segments), at: hour(7.5), store: store)
                written += try await strapFlush(morning.nights.map(\.segments), at: hour(8), store: store)
                written += try await strapFlush([], at: hour(12), store: store)
                XCTAssertEqual(written, [joinedNight], "\(label): written once")
                XCTAssertEqual(try mirrorSpan(store), joinedNight, label)
                XCTAssertEqual(extensionBreadcrumbs().count, crumbs, "\(label): nothing was written early, so nothing extended")
            }
        }
    }

    /// Decision 73d: at 07:05 the strap still marks the wearer asleep up to its newest minute, so the
    /// block is not used: the night stays A as written, and nothing is written or stored for the block.
    /// The next sync, after it has ended, joins it and rewrites the night once.
    func testABlockStillInProgressIsNotUsedUntilTheNextSyncAfterItEnded() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try syncWithActivity([sleepA], activity: nightActivity(until: 2.25), at: hour(2.25), store: store)
            try recordWrite(try storedHypnogram(store), store: store)
            let key = try XCTUnwrap(try rows(store).first).night
            let record = mirrorRecord(store, key)

            let asleep: [(Double, Double, UInt8)] = [(-1, 2, asleepKind), (2, 5.5, upKind), (5.5, 7 + 5.0 / 60, asleepKind)]
            let early = try syncWithActivity([sleepA], activity: asleep, at: hour(7 + 5.0 / 60), store: store)
            XCTAssertFalse(early.nights.contains { $0.window.end > hour(2) }, "no night reaches past A")
            XCTAssertEqual(try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }, [sleepAWindow])
            XCTAssertEqual(try napRows(store), [])
            XCTAssertEqual(early.sleepRound?.activityBlocksJoined, 0, "held, so neither joined…")
            XCTAssertEqual(early.sleepRound?.activityBlocksAlone, 0, "…nor alone")
            let none = try await strapFlush(early.nights.map(\.segments), at: hour(7.5), store: store)
            XCTAssertEqual(none, [])
            XCTAssertEqual(mirrorRecord(store, key), record)

            let later = try syncWithActivity([sleepA], activity: nightActivity(until: 7.5), at: hour(7.5), store: store)
            XCTAssertEqual(later.nights.map(\.window), [joinedNight])
            try assertTheJoinedNightIsStored(store, wornThroughTheGap: true)
            let written = try await strapFlush(later.nights.map(\.segments), at: hour(7.5), store: store)
            XCTAssertEqual(written, [joinedNight], "rewritten once")
            XCTAssertEqual(extensionBreadcrumbs().count, 1)
        }
    }

    /// Decision 58 on a night grown by blocks: A is in Health; the wearer sleeps 05:30–06:00, is up half an
    /// hour, sleeps again 06:30–07:00. Each settled block that grows the night is one extension written
    /// once; a sync while the second block goes on, or one with nothing new, writes nothing.
    func testAGrowingLaterSleepExtendsTheNightOncePerGrowth() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try syncWithActivity([sleepA], activity: nightActivity(until: 2.25), at: hour(2.25), store: store)
            try recordWrite(try storedHypnogram(store), store: store)
            let key = try XCTUnwrap(try rows(store).first).night
            let night: [(Double, Double, UInt8)] = [(-1, 2, asleepKind), (2, 5.5, upKind), (5.5, 6, asleepKind), (6, 6.5, upKind),
                                                     (6.5, 7, asleepKind), (7, 9, upKind)]
            func activity(until: Double) -> [(Double, Double, UInt8)] {
                night.filter { $0.0 < until }.map { ($0.0, min($0.1, until), $0.2) }
            }
            var written: [DateInterval] = []

            let toSix = DateInterval(start: hour(-1), end: hour(6))
            let first = try syncWithActivity([sleepA], activity: activity(until: 6 + 25.0 / 60), at: hour(6 + 25.0 / 60), store: store)
            XCTAssertEqual(first.nights.map(\.window), [toSix], "the first block extends the written night")
            written += try await strapFlush(first.nights.map(\.segments), at: hour(6 + 25.0 / 60), store: store)
            XCTAssertEqual(written, [toSix])
            let record = mirrorRecord(store, key)

            let during = try syncWithActivity([sleepA], activity: activity(until: 6.75), at: hour(6.75), store: store)
            XCTAssertFalse(during.nights.contains { $0.window.end > hour(6) }, "the second block is in progress")
            written += try await strapFlush(during.nights.map(\.segments), at: hour(6.75), store: store)
            XCTAssertEqual(mirrorRecord(store, key), record)

            let final = try syncWithActivity([sleepA], activity: activity(until: 7.5), at: hour(7.5), store: store)
            XCTAssertEqual(final.nights.map(\.window), [joinedNight])
            XCTAssertEqual(final.sleepRound?.activityBlocksJoined, 2)
            written += try await strapFlush(final.nights.map(\.segments), at: hour(7.5), store: store)
            written += try await strapFlush(final.nights.map(\.segments), at: hour(8), store: store)
            let same = try syncWithActivity([sleepA], activity: activity(until: 9), at: hour(9), store: store)
            written += try await strapFlush(same.nights.map(\.segments), at: hour(9), store: store)
            XCTAssertEqual(written, [toSix, joinedNight], "one write per growth")
            XCTAssertEqual(try mirrorSpan(store), joinedNight)
            XCTAssertEqual(extensionBreadcrumbs().count, 2)
            XCTAssertEqual(try rows(store).map(\.asleepMin), [180 + 30 + 30])
            XCTAssertEqual(inBedSpans(try storedHypnogram(store)),
                           [sleepAWindow, DateInterval(start: hour(5.5), end: hour(6)), DateInterval(start: hour(6.5), end: hour(7))])
        }
    }

    /// Decision 73c, amended by 76b (76g): blocks that would stand alone are never a night. An evening
    /// doze before the night (20:00–21:00) and a daytime sleep after it (13:00–14:00), each more than
    /// 60 min from the night, are naps. A night whose only record is the NEXT night's gets no night from
    /// that record. Counted in the sleep-round line.
    func testStandaloneBlocksAwayFromTheNightAreNapsAndTheNextNightsRecordMakesNoNightForTheFirst() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let wholeNight: [(Double, Double, UInt8)] = [(-1, 7, light)]
            let activity: [(Double, Double, UInt8)] = [(-4, -3, asleepKind), (-3, -1, upKind), (-1, 7, asleepKind), (7, 13, upKind),
                                                        (13, 14, asleepKind), (14, 15, upKind)]
            let result = try syncWithActivity([wholeNight], activity: activity, at: hour(15), store: store)
            // Decision 77 (amended): every fixture minute carries the strap's heart rate (55 bpm, no steps),
            // so the record gets the capped in-bed lead-in from the store. The night's own window is the record's.
            let capped = DateInterval(start: hour(-1).addingTimeInterval(-HelioInBedLeadIn.maxLength), end: hour(-1))
            XCTAssertEqual(result.nights.map(\.windowWithoutLeadIn), [DateInterval(start: hour(-1), end: hour(7))])
            XCTAssertEqual(result.nights.map(\.leadIn), [capped])
            XCTAssertEqual(try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) },
                           [DateInterval(start: capped.start, end: hour(7))])
            XCTAssertEqual(try rows(store).map(\.asleepMin), [480], "nothing of either block in the night")
            XCTAssertEqual(try napRows(store), [DateInterval(start: hour(-4), end: hour(-3)), DateInterval(start: hour(13), end: hour(14))],
                           "both are naps (decision 76b: more than 60 min from the night, settled)")
            XCTAssertEqual(result.sleepRound?.activityBlocksJoined, 0)
            XCTAssertEqual(result.sleepRound?.activityBlocksAlone, 2)
            XCTAssertEqual(result.sleepRound?.text.hasSuffix("; activity blocks: joined=0 alone=2"), true, result.sleepRound?.text ?? "")

            // The strap's only record is the NEXT night's (23:00–07:00 a day later); the first night has none.
            let noRecord = try makeStore()
            let nextNight: [(Double, Double, UInt8)] = [(23, 31, light)]
            let synced = try syncWithActivity([nextNight], activity: [(-1, 7, asleepKind), (7, 23, upKind), (23, 32, upKind)],
                                              at: hour(32), store: noRecord)
            // Decision 77 (amended): the capped lead-in from the stored heart rate, as above.
            let cappedNext = hour(23).addingTimeInterval(-HelioInBedLeadIn.maxLength)
            XCTAssertEqual(synced.nights.map(\.windowWithoutLeadIn), [DateInterval(start: hour(23), end: hour(31))])
            XCTAssertEqual(try rows(noRecord).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) },
                           [DateInterval(start: cappedNext, end: hour(31))], "only the night with a record")
            XCTAssertEqual(try napRows(noRecord), [])
            XCTAssertEqual(synced.sleepRound?.activityBlocksAlone, 1)
        }
    }

    /// Decision 76b (76g): a block inside the 00:00–08:00 main-sleep window of a night no stored night
    /// covers (23:00–06:00, the strap's only record the next night's) is that night's provisional main
    /// sleep: stored as nothing, neither night nor nap, and counted as main-only.
    func testABlockThatIsTheMainSleepOfANightNoStoredNightCoversIsStoredAsNothing() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let nextNight: [(Double, Double, UInt8)] = [(23, 31, light)]
            let synced = try syncWithActivity([nextNight], activity: [(-1, 6, asleepKind), (6, 23, upKind), (23, 32, upKind)],
                                              at: hour(32), store: store, noHeartRateBefore: 23)
            XCTAssertEqual(try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) },
                           [DateInterval(start: hour(23), end: hour(31))], "no night for the block")
            XCTAssertEqual(try napRows(store), [], "no nap")
            XCTAssertEqual(synced.sleepRound?.activityBlocksAlone, 1)
            XCTAssertEqual(synced.sleepRound?.mainOnlyBlocks, 1)
            XCTAssertEqual(synced.sleepRound?.napsStored, 0)
        }
    }

    /// Ownership is judged per block (71d). Wore both devices and switched in the awake gap (03:30):
    /// ring to strap, the strap owns only the block, which has no record of the strap's to join, so
    /// nothing is stored; strap to ring, the block is the ring's time and is not used, so the night is A.
    func testABlockInTimeTheRingOwnsIsNotUsed() throws {
        let cases: [(String, DeviceOwnershipLog, [DateInterval])] = [
            ("ring to strap", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(3.5))]), []),
            ("strap to ring", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast),
                                                           .init(family: .ringConn, since: hour(3.5))]),
             [DateInterval(start: hour(-1), end: hour(2))]),
        ]
        for (label, log, strapsOwn) in cases {
            try inFixedZoneSync {
                ownership.install(log)
                let store = try makeStore()
                let result = try syncWithActivity([sleepA], activity: nightActivity(until: 9), at: hour(9), store: store)
                XCTAssertEqual(result.nights.map(\.window), strapsOwn, label)
                XCTAssertEqual(try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }, strapsOwn, label)
                XCTAssertEqual(try napRows(store), [], label)
                XCTAssertEqual(result.sleepRound?.activityBlocksJoined, 0, label)
            }
        }
    }

    /// The sleep-round line's block counts are digits only, and a sync with no block leaves the line
    /// decision 72 shipped.
    func testTheSleepRoundLineCountsBlocksWithNoClockTime() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let joined = try syncWithActivity([sleepA], activity: nightActivity(until: 8), at: hour(8), store: store)
            let line = try XCTUnwrap(joined.sleepRound?.text)
            XCTAssertTrue(line.hasSuffix("; activity blocks: joined=1 alone=0"), line)
            XCTAssertNil(line.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression), line)

            let none = try syncWithActivity([sleepA], activity: [(-1, 2, asleepKind), (2, 8, upKind)], at: hour(8), store: try makeStore())
            let plain = try XCTUnwrap(none.sleepRound?.text)
            XCTAssertFalse(plain.contains("activity blocks"), plain)
        }
    }
}

extension StrapNightHealthTests {
    /// Decision 73d/73e: the joined block is a sleep window for the skin-temperature gate (its minutes are
    /// kept, the awake gap's are not), but the temperature watermark stays at the record's end, as
    /// before decision 73. The activity round starts there at the latest, so the next sync re-fetches
    /// every minute after the record and sees each block whole.
    func testTheTemperatureWatermarkStaysAtTheRecordsEndSoTheNextSyncSeesTheBlockWhole() throws {
        try inFixedZoneSync {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let result = try syncWithActivity([sleepA], activity: nightActivity(until: 8), temperatureFrom: -1, at: hour(8), store: store)
            XCTAssertEqual(result.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(7))])
            XCTAssertEqual(store.helioFetchCursors(device: timeline)[.temperature], hour(2), "held at the record's end")
            let kind = MetricKind.temperature.rawValue
            let kept = try store.context.fetch(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == kind })).map(\.start)
            XCTAssertEqual(kept.filter { $0 >= hour(5.5) && $0 < hour(7) }.count, 90, "the block is a sleep window")
            XCTAssertEqual(kept.filter { $0 >= hour(2) && $0 < hour(5.5) }.count, 0, "the awake gap is not")
        }
    }
}

// MARK: - Decisions 73f-73h (review-73): the night's edges

extension StrapNightHealthTests {
    /// Decision 73f, in the production fetch shape: a doze 22:00–22:40, 20 minutes before the record
    /// (23:00–02:00), is no lead-in. A is written alone at 03:00. The temperature watermark then sits at
    /// 02:00, so the 08:00 sync fetches activity only from 02:00 (the fake strap re-sends everything, so
    /// the test sends what production fetches): the later block extends A once, and nothing written is
    /// ever shortened.
    func testADozeBeforeTheRecordIsNoLeadInSoNoWrittenNightIsShortened() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let early: [(Double, Double, UInt8)] = [(-2, -1 - 20.0 / 60, asleepKind), (-1 - 20.0 / 60, -1, upKind),
                                                     (-1, 2, asleepKind), (2, 3, upKind)]
            let first = try syncWithActivity([sleepA], activity: early, at: hour(3), store: store)
            // Decision 77 (amended): the doze's and the following minutes' STORED heart rate (55 bpm, no
            // steps, from 22:00) give A an in-bed lead-in from 22:00, awake and in bed, no sleep. It comes
            // from the store, so the 08:00 sync, which fetches nothing before 02:00, derives the same one.
            let leadIn = DateInterval(start: hour(-2), end: hour(-1))
            let leadInA = DateInterval(start: leadIn.start, end: sleepAWindow.end)
            let leadInJoined = DateInterval(start: leadIn.start, end: joinedNight.end)
            XCTAssertEqual(first.nights.map(\.windowWithoutLeadIn), [sleepAWindow], "the doze doesn't join")
            XCTAssertEqual(first.nights.map(\.leadIn), [leadIn])
            XCTAssertEqual(first.sleepRound?.activityBlocksAlone, 1)
            XCTAssertEqual(try napRows(store), [], "and is no nap")
            let firstWrite = try await strapFlush(first.nights.map(\.segments), at: hour(3), store: store)
            XCTAssertEqual(firstWrite, [leadInA])
            XCTAssertEqual(store.helioFetchCursors(device: timeline)[.temperature] ?? hour(2), hour(2), "nothing moved it past the record")
            let before = try XCTUnwrap(try rows(store).first)
            let (key, beforeStart, beforeAsleep) = (before.night, before.inBedStart, before.asleepMin)
            XCTAssertEqual(beforeAsleep, 180)

            let fromTwo: [(Double, Double, UInt8)] = [(2, 5.5, upKind), (5.5, 7, asleepKind), (7, 8, upKind)]
            let second = try syncWithActivity([sleepA], activity: fromTwo, at: hour(8), store: store)
            XCTAssertEqual(second.nights.map(\.window), [leadInJoined])
            let secondWrite = try await strapFlush(second.nights.map(\.segments), at: hour(8), store: store)
            XCTAssertEqual(secondWrite, [leadInJoined], "one extension")
            let after = try XCTUnwrap(try rows(store).first)
            XCTAssertLessThanOrEqual(after.inBedStart, beforeStart, "the written start stands")
            XCTAssertEqual(after.asleepMin, beforeAsleep + 90)
            XCTAssertEqual(try mirrorSpan(store), leadInJoined)
            XCTAssertEqual(store.mirroredNight(night: key)?.spanStart, hour(-2))
            try assertTheJoinedNightIsStored(store, wornThroughTheGap: true, leadIn: leadIn)
        }
    }

    /// Decision 73g, the review's lie-in: record 23:00–07:00, sleep minutes 07:30–12:10, first sync at
    /// 13:00. Joined, the night would end after noon and be no night at all. With or without the block,
    /// the record's night is stored and written once, the block is counted alone, and there is no nap.
    func testALieInBlockPastTheWakeWindowNeverCostsTheNight() async throws {
        for withBlock in [false, true] {
            try await inFixedZone {
                let label = "with block: \(withBlock)"
                ownership.install(.strapOwnsAllTime)
                let store = try makeStore()
                let recordNight = DateInterval(start: hour(-1), end: hour(7))
                let activity: [(Double, Double, UInt8)] = withBlock
                    ? [(-1, 7, asleepKind), (7, 7.5, upKind), (7.5, 12 + 10.0 / 60, asleepKind), (12 + 10.0 / 60, 13, upKind)]
                    : [(-1, 7, asleepKind), (7, 13, upKind)]
                let result = try syncWithActivity([[(-1, 7, light)]], activity: activity, at: hour(13), store: store)
                XCTAssertEqual(result.nights.map(\.window), [recordNight], label)
                XCTAssertEqual(try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }, [recordNight], label)
                XCTAssertEqual(try rows(store).map(\.asleepMin), [480], label)
                XCTAssertEqual(try napRows(store), [], label)
                XCTAssertEqual(result.sleepRound?.activityBlocksAlone, withBlock ? 1 : 0, label)
                var written = try await strapFlush(result.nights.map(\.segments), at: hour(13), store: store)
                written += try await strapFlush([], at: hour(16), store: store)
                XCTAssertEqual(written, [recordNight], "\(label): written once")
            }
        }
    }

    /// Decision 73h: a sleep minute inside a session's in-bed span never creates or extends a block.
    /// Asleep only inside A: no block at all. Asleep 01:00–03:00 across A's end: the block is 02:00–03:00,
    /// the part after A, so the night is A plus that hour, with A's in-bed span as A's own.
    func testSleepMinutesInsideTheRecordNeverCreateOrExtendABlock() throws {
        try inFixedZoneSync {
            ownership.install(.strapOwnsAllTime)
            let inside = try syncWithActivity([sleepA], activity: [(-1, 2, asleepKind), (2, 4, upKind)], at: hour(4), store: try makeStore())
            XCTAssertEqual(inside.nights.map(\.window), [sleepAWindow])
            XCTAssertEqual(inside.sleepRound?.activityBlocksJoined, 0)
            XCTAssertEqual(inside.sleepRound?.activityBlocksAlone, 0)

            let store = try makeStore()
            let across = try syncWithActivity([sleepA], activity: [(-1, 1, upKind), (1, 3, asleepKind), (3, 4, upKind)],
                                              at: hour(4), store: store)
            XCTAssertEqual(across.nights.map(\.window), [DateInterval(start: hour(-1), end: hour(3))])
            XCTAssertEqual(across.sleepRound?.activityBlocksJoined, 1)
            XCTAssertEqual(inBedSpans(try storedHypnogram(store)), [sleepAWindow, DateInterval(start: hour(2), end: hour(3))])
            XCTAssertEqual(try rows(store).map(\.asleepMin), [180 + 60])
        }
    }
}

// MARK: - Decision 73i (review-73b): no block between a night's records

extension StrapNightHealthTests {
    /// Decision 73i, in the production fetch shape: records A1 23:00–01:00 and A2 02:30–05:00, sleep minutes
    /// 01:15–02:15 between them. The block is before A2's in-bed end, so it is alone: the night written at
    /// 06:00 is A1 + A2 (joined by 71b). The watermark then sits at 05:00, so the 08:00 sync fetches
    /// activity only from 05:00 (the fake strap re-sends everything, so the test sends what production
    /// fetches) and brings a block 05:30–07:00, after A2: the night extends to 07:00, and every stage and
    /// in-bed span written at 06:00 is still in the night written at 08:00.
    func testABlockBetweenTwoRecordsIsAloneSoALaterExtensionDeletesNothingWritten() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let a1: [(Double, Double, UInt8)] = [(-1, 1, light)], a2: [(Double, Double, UInt8)] = [(2.5, 5, light)]
            let early: [(Double, Double, UInt8)] = [(-1, 1, asleepKind), (1, 1.25, upKind), (1.25, 2.25, asleepKind),
                                                     (2.25, 2.5, upKind), (2.5, 5, asleepKind), (5, 6, upKind)]
            let first = try syncWithActivity([a1, a2], activity: early, at: hour(6), store: store)
            let firstNight = DateInterval(start: hour(-1), end: hour(5))
            XCTAssertEqual(first.nights.map(\.window), [firstNight])
            XCTAssertEqual(first.sleepRound?.activityBlocksJoined, 0)
            XCTAssertEqual(first.sleepRound?.activityBlocksAlone, 1, "the mid-night block is alone")
            XCTAssertEqual(try napRows(store), [])
            let firstWrite = try await strapFlush(first.nights.map(\.segments), at: hour(6), store: store)
            XCTAssertEqual(firstWrite, [firstNight])
            let writtenFirst = try storedHypnogram(store)
            let firstAsleep = try XCTUnwrap(try rows(store).first).asleepMin
            XCTAssertEqual(firstAsleep, 120 + 150)
            XCTAssertEqual(inBedSpans(writtenFirst), [DateInterval(start: hour(-1), end: hour(1)), DateInterval(start: hour(2.5), end: hour(5))])

            let fromFive: [(Double, Double, UInt8)] = [(5, 5.5, upKind), (5.5, 7, asleepKind), (7, 8, upKind)]
            let second = try syncWithActivity([a1, a2], activity: fromFive, at: hour(8), store: store)
            XCTAssertEqual(second.nights.map(\.window), [joinedNight])
            XCTAssertEqual(second.sleepRound?.activityBlocksJoined, 1)
            let secondWrite = try await strapFlush(second.nights.map(\.segments), at: hour(8), store: store)
            XCTAssertEqual(secondWrite, [joinedNight], "one extension")
            let writtenSecond = try storedHypnogram(store)
            XCTAssertEqual(try XCTUnwrap(try rows(store).first).asleepMin, firstAsleep + 90)
            XCTAssertEqual(inBedSpans(writtenSecond), inBedSpans(writtenFirst) + [DateInterval(start: hour(5.5), end: hour(7))])
            XCTAssertTrue(writtenFirst.allSatisfy(writtenSecond.contains), "nothing written at 06:00 is gone")
            XCTAssertEqual(try mirrorSpan(store), joinedNight)
        }
    }
}

// MARK: - Decision 74 (#278): the awake time between a strap night's fragments
//
// The joined night of decision 71 (sleep A 23:00–02:00, the sleep after the awakening 05:30–07:00).
// Where the store holds the strap's own heart rate in the gap, that time is awake and in bed: one
// `.awake` and one `.inBed` segment per run (74a), derived from the STORED rows (74b). Where it holds
// none, the gap stays a gap. Every heart rate, minute and night here is synthetic.

extension StrapNightHealthTests {
    /// The strap's heart rate, one reading a minute over local hours `from ..< to`, stored for its timeline.
    private func storeHeartRate(_ from: Double, _ to: Double, store: LocalStore, bpm: Double = 62) throws {
        let samples = stride(from: hour(from).timeIntervalSince1970, to: hour(to).timeIntervalSince1970, by: 60).map {
            QuantitySample(kind: .heartRate, start: Date(timeIntervalSince1970: $0), value: bpm)
        }
        _ = try store.ingest(samples, device: timeline)
    }

    /// The awake runs in `segments` (an `.inBed` and an `.awake` over the same span).
    private func awakeRuns(_ segments: [SleepSegment]) -> [DateInterval] {
        HelioSleepSelection.awakeFillRuns(in: segments)
    }

    /// The joined night as this build stores it with no heart rate in the store: what build 82 stored.
    private func joinedNightWithoutFill() throws -> HelioSleepSelection.Night {
        let reference = try makeStore()
        let night = try XCTUnwrap(try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: reference).nights.first)
        XCTAssertEqual(awakeRuns(night.segments), [])
        return night
    }

    /// The state build 82 left on the owner's phone: the joined night stored and written without its
    /// fill, while the store already held the strap's heart rate for the whole night. The key.
    private func storeAndWriteAsBuild82(_ store: LocalStore) throws -> Date {
        let night = try joinedNightWithoutFill()
        try storeHeartRate(-1, 8, store: store)
        XCTAssertEqual(try store.saveHelioNight(night, device: timeline), .inserted)
        XCTAssertEqual(try recordWrite(night.segments, store: store), joinedNight)
        return try XCTUnwrap(try rows(store).first).night
    }

    /// 74d, the owner's shape: the re-delivered night differs from the written one only by the fill
    /// inside the written span. It is stored with the fill, rewritten once, the record's span (the union
    /// delete) is still the written span, and the next flush is the signature no-op.
    func testAJoinedNightWrittenWithoutItsFillIsRewrittenOnceWithItOnReDelivery() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let key = try storeAndWriteAsBuild82(store)
            let unfilled = try storedHypnogram(store)

            let morning = try syncSessions([sleepA, afterTheAwakening], at: hour(8.5), store: store)
            XCTAssertEqual(morning.nights.map(\.window), [joinedNight], "the same window")
            let stored = try storedHypnogram(store)
            XCTAssertEqual(awakeRuns(stored), [DateInterval(start: hour(2), end: hour(5.5))])
            XCTAssertEqual(morning.nights.map(\.segments), [stored], "handed to the flush as stored")
            XCTAssertEqual(HelioSleepSelection.withoutAwakeFill(stored), unfilled, "the fragments as written")
            XCTAssertEqual(try XCTUnwrap(try rows(store).first).asleepMin, 270)

            let written = try await strapFlush(morning.nights.map(\.segments), at: hour(8.5), store: store)
            XCTAssertEqual(written, [joinedNight], "rewritten once")
            let record = try XCTUnwrap(store.mirroredNight(night: key))
            XCTAssertEqual(record.signature, HealthKitWriter.sleepSignature(stored))
            XCTAssertEqual(DateInterval(start: record.spanStart, end: record.spanEnd), joinedNight,
                           "the delete covers the written span, nothing outside it")
            XCTAssertEqual(extensionBreadcrumbs(), [], "no extension: the same span")

            let again = try syncSessions([sleepA, afterTheAwakening], at: hour(9.5), store: store)
            let rewritten = try await strapFlush(again.nights.map(\.segments), at: hour(9.5), store: store)
            XCTAssertEqual(rewritten, [], "the signature no-op")
            let outcome = await HealthKitWriter().mirrorStrapNight(local: store, segments: stored)
            XCTAssertTrue(isSignatureNoOp(outcome))
            XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(13)), [])
        }
    }

    /// The card reads the stored summary: the run is time in bed and awake time, so the 98%-style
    /// efficiency drops (74e) and the "nothing was recorded" caption gives way to the plain one.
    func testTheCardCountsTheAwakeRunAsTimeInBed() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            _ = try storeAndWriteAsBuild82(store)
            let before = SleepStaging.summary(try storedHypnogram(store))
            _ = try syncSessions([sleepA, afterTheAwakening], at: hour(8.5), store: store)
            let row = try XCTUnwrap(try rows(store).first)
            let after = SleepStaging.summary(try storedHypnogram(store))
            XCTAssertEqual(before.minutes.inBed, 270)
            XCTAssertEqual(after.minutes.inBed, 480, "the fragments + the 210-minute run")
            XCTAssertEqual(after.minutes.awake, before.minutes.awake + 210)
            XCTAssertEqual(row.awakeMin, after.minutes.awake)
            XCTAssertEqual(row.asleepMin, before.minutes.asleep, "no sleep added")
            XCTAssertLessThan(row.efficiency, before.efficiency)
            let asleep = row.sleepWake.timeIntervalSince(row.sleepOnset)
            XCTAssertFalse(SleepWindowCaption.isContiguous(span: asleep, measuredInBed: before.inBed))
            XCTAssertTrue(SleepWindowCaption.isContiguous(span: asleep, measuredInBed: after.inBed))
        }
    }

    /// 74d: not written yet. Stored with its fill, held behind the margin, then written once with it.
    func testAJoinedNightNotYetWrittenIsWrittenOnceWithItsFillAfterTheMargin() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            try storeHeartRate(-1, 8, store: store)
            let early = try syncSessions([sleepA, afterTheAwakening], at: hour(7 + 13.0 / 60), store: store)
            XCTAssertEqual(awakeRuns(try storedHypnogram(store)), [DateInterval(start: hour(2), end: hour(5.5))])
            let held = try await strapFlush(early.nights.map(\.segments), at: hour(7 + 13.0 / 60), store: store)
            XCTAssertEqual(held, [], "inside the margin")

            let later = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            let written = try await strapFlush(later.nights.map(\.segments), at: hour(7.5), store: store)
            XCTAssertEqual(written, [joinedNight], "written once")
            let key = try XCTUnwrap(try rows(store).first).night
            XCTAssertEqual(store.mirroredNight(night: key)?.signature, HealthKitWriter.sleepSignature(try storedHypnogram(store)))

            let again = try syncSessions([sleepA, afterTheAwakening], at: hour(8.5), store: store)
            let rewritten = try await strapFlush(again.nights.map(\.segments), at: hour(8.5), store: store)
            XCTAssertEqual(rewritten, [])
        }
    }

    /// 74b, every path the same segments: a night build 82 stored without its fill and never wrote, that
    /// the strap no longer re-delivers, is offered by the 50b backstop with the fill the store path
    /// gives it, written once, and then offered no more. A refusal of that offer is noted against the
    /// stored hypnogram like any other (#259).
    func testTheBackstopOffersAStoredNightWithTheFillTheStorePathGivesIt() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let night = try joinedNightWithoutFill()
            let expected = HelioSleepSelection.awakeFilled(night.segments, window: night.window,
                                                           heartRateMinutes: stride(from: hour(-1).timeIntervalSince1970,
                                                                                    to: hour(8).timeIntervalSince1970, by: 60)
                                                               .map { Date(timeIntervalSince1970: $0) })
            XCTAssertEqual(awakeRuns(expected), [DateInterval(start: hour(2), end: hour(5.5))])
            for declined in [false, true] {
                let store = try makeStore()
                try storeHeartRate(-1, 8, store: store)
                XCTAssertEqual(try store.saveHelioNight(night, device: timeline), .inserted)
                let storedKey = try XCTUnwrap(try rows(store).first).night
                clearMirror(storedKey)   // the mirror records live in the standard defaults, by key
                defer { StrapNightDeclinedOverlay.clear(storedNight: storedKey) }
                let filledByStorePath = try makeStore()
                try storeHeartRate(-1, 8, store: filledByStorePath)
                _ = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: filledByStorePath)
                XCTAssertEqual(try storedHypnogram(filledByStorePath), expected, "the store path's segments")

                let offered = store.strapNightsAwaitingHealth(timeline: timeline, now: hour(10.5))
                XCTAssertEqual(offered, [expected], "the backstop's segments")
                if declined {
                    store.noteStrapNightDeclined(expected)
                    XCTAssertEqual(store.strapNightsAwaitingHealth(timeline: timeline, now: hour(10.5)), [], "noted, not offered again")
                    continue
                }
                let written = try await strapFlush([], at: hour(10.5), store: store)
                XCTAssertEqual(written, [joinedNight])
                let key = try XCTUnwrap(try rows(store).first).night
                XCTAssertEqual(store.mirroredNight(night: key)?.signature, HealthKitWriter.sleepSignature(expected))
                let again = try await strapFlush([], at: hour(11), store: store)
                XCTAssertEqual(again, [], "offered no more")
            }
        }
    }

    /// 74d: a night with one fragment is byte-identical, with the strap's heart rate all night.
    func testANightWithOneFragmentIsByteIdenticalWithHeartRateAllNight() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let single: [(Double, Double, UInt8)] = [(-1, 2, light), (2, 2.5, awake), (2.5, 7, deep)]
            let reference = try makeStore()
            let plain = try syncSessions([single], at: hour(8), store: reference)
            let store = try makeStore()
            try storeHeartRate(-2, 9, store: store)
            let withHR = try syncSessions([single], at: hour(8), store: store)
            // Decision 77 (amended): the heart rate from 22:00 gives the night the in-bed lead-in 22:00–23:00.
            // Without it the night is byte-identical: one fragment gets no awake fill.
            XCTAssertEqual(withHR.nights.map(\.leadIn), [DateInterval(start: hour(-2), end: hour(-1))])
            XCTAssertEqual(withHR.nights.map(\.withoutLeadIn), plain.nights)
            XCTAssertEqual(HelioSleepSelection.withoutLeadIn(SleepHypnogramCodec.decode(try XCTUnwrap(try rows(store).first).hypnogramData)),
                           SleepHypnogramCodec.decode(try XCTUnwrap(try rows(reference).first).hypnogramData))
            XCTAssertEqual(store.helioAwakeFilled(withHR.nights[0].segments, window: withHR.nights[0].window, device: timeline),
                           withHR.nights[0].segments)
        }
    }

    /// 74a: heart rate in part of the gap (02:00–03:00, 04:30–05:30). Those parts are awake and in bed;
    /// 03:00–04:30 has none and stays a gap.
    func testHeartRateMissingInPartOfTheGapLeavesThatPartAGap() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            try storeHeartRate(2, 3, store: store)
            try storeHeartRate(4.5, 5.5, store: store)
            let result = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            let stored = try storedHypnogram(store)
            XCTAssertEqual(awakeRuns(stored), [DateInterval(start: hour(2), end: hour(3)), DateInterval(start: hour(4.5), end: hour(5.5))])
            XCTAssertFalse(stored.contains { $0.start < hour(4.5) && hour(3) < $0.end }, "the unworn part stays a gap")
            XCTAssertEqual(result.nights.map(\.segments), [stored])
            XCTAssertEqual(SleepStaging.summary(stored).minutes.inBed, 270 + 120)
            let written = try await strapFlush(result.nights.map(\.segments), at: hour(7.5), store: store)
            XCTAssertEqual(written, [joinedNight])
        }
    }

    /// Decision 28: the ring owns 03:00–04:00 (a switch to it and back). The strap's heart rate there,
    /// even stored under the strap's timeline, fills nothing; the strap's own time around it is filled.
    func testTheRingsTimeInTheGapIsNotFilled() throws {
        try inFixedZoneSync {
            ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast),
                                                           .init(family: .ringConn, since: hour(3)),
                                                           .init(family: .zeppOS, since: hour(4))]))
            let store = try makeStore()
            try storeHeartRate(-1, 8, store: store)
            _ = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            XCTAssertEqual(try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }, [joinedNight])
            XCTAssertEqual(awakeRuns(try storedHypnogram(store)),
                           [DateInterval(start: hour(2), end: hour(3)), DateInterval(start: hour(4), end: hour(5.5))])
        }
    }

    /// 74f(2): another device's heart rate never fills a strap gap. The ring's readings cover the whole
    /// night, the strap owns all of it, and the store holds no strap heart rate: no awake run.
    func testAnotherDevicesHeartRateInTheGapFillsNothing() throws {
        try inFixedZoneSync {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let ringHR = stride(from: hour(-1).timeIntervalSince1970, to: hour(8).timeIntervalSince1970, by: 60).map {
                QuantitySample(kind: .heartRate, start: Date(timeIntervalSince1970: $0), value: 60)
            }
            _ = try store.ingest(ringHR, device: .ringConn)
            let result = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            let stored = try storedHypnogram(store)
            XCTAssertEqual(awakeRuns(stored), [], "the ring's heart rate fills nothing")
            XCTAssertFalse(stored.contains { $0.start < hour(5.5) && hour(2) < $0.end }, "the gap stays a gap")
            XCTAssertEqual(result.nights.map(\.segments), [stored])
        }
    }

    /// 74b: the fill comes from the store, never the sync's fetched minutes. A later sync that fetched
    /// only the minutes after 07:30 (none of the gap) stores and hands over the same fill.
    func testAReDeliveryThatFetchedFewerMinutesKeepsTheSameFill() throws {
        try inFixedZoneSync {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let wholeNight: [(Double, Double, UInt8)] = [(-1, 2, asleepKind), (2, 5.5, upKind), (5.5, 7, asleepKind), (7, 7.5, upKind)]
            let first = try syncWithActivity([sleepA, afterTheAwakening], activity: wholeNight, at: hour(7.5), store: store)
            let filled = try storedHypnogram(store)
            XCTAssertEqual(awakeRuns(filled), [DateInterval(start: hour(2), end: hour(5.5))])
            XCTAssertEqual(first.nights.map(\.segments), [filled])

            let later = try syncWithActivity([sleepA, afterTheAwakening], activity: [(7.5, 8.5, upKind)], at: hour(8.5), store: store)
            XCTAssertEqual(try storedHypnogram(store), filled)
            XCTAssertEqual(later.nights.map(\.segments), [filled])
        }
    }

    /// 74b: a night stored before its gap's heart rate was (the activity round didn't reach it) gets the
    /// fill on the re-delivery after the heart rate is stored, and that reaches Health once.
    func testAGapWhoseHeartRateArrivesLaterIsFilledOnThatReDelivery() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let first = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            XCTAssertEqual(awakeRuns(try storedHypnogram(store)), [])
            let firstWrite = try await strapFlush(first.nights.map(\.segments), at: hour(7.5), store: store)
            XCTAssertEqual(firstWrite, [joinedNight])

            let later = try syncWithActivity([sleepA, afterTheAwakening], activity: [(2, 5.5, upKind), (7, 9, upKind)],
                                             at: hour(9), store: store)
            XCTAssertEqual(awakeRuns(try storedHypnogram(store)), [DateInterval(start: hour(2), end: hour(5.5))])
            let rewrite = try await strapFlush(later.nights.map(\.segments), at: hour(9), store: store)
            XCTAssertEqual(rewrite, [joinedNight], "rewritten once with the fill")
            XCTAssertEqual(try mirrorSpan(store), joinedNight)
            let again = try await strapFlush(later.nights.map(\.segments), at: hour(9.5), store: store)
            XCTAssertEqual(again, [])
        }
    }

    /// Decision 58 still works with the fill: A written at 02:15, then the joined night (an extension)
    /// with its fill is rewritten once, as 58b admits it.
    func testANightThatGrowsAfterItWasWrittenIsExtendedWithItsFill() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            try storeHeartRate(-1, 2.25, store: store)
            _ = try syncSessions([sleepA], at: hour(2.25), store: store)
            try recordWrite(try storedHypnogram(store), store: store)
            try storeHeartRate(2.25, 8, store: store)
            let morning = try syncSessions([sleepA, afterTheAwakening], at: hour(7.5), store: store)
            XCTAssertEqual(morning.nights.map(\.window), [joinedNight])
            let stored = try storedHypnogram(store)
            XCTAssertEqual(awakeRuns(stored), [DateInterval(start: hour(2), end: hour(5.5))])
            let written = try await strapFlush(morning.nights.map(\.segments), at: hour(7.5), store: store)
            XCTAssertEqual(written, [joinedNight], "one extension")
            XCTAssertEqual(try mirrorSpan(store), joinedNight)
            XCTAssertEqual(store.mirroredNight(night: try XCTUnwrap(try rows(store).first).night)?.signature,
                           HealthKitWriter.sleepSignature(stored))
            XCTAssertEqual(extensionBreadcrumbs().count, 1)
        }
    }

    /// 74d: an edited night is untouched. Build 82's night, edited, re-delivered with heart rate in the
    /// gap: nothing is stored over it, nothing is handed over, and the mirror leaves it alone.
    func testAnEditedNightGetsNoFill() async throws {
        try await inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let key = try storeAndWriteAsBuild82(store)
            let row = try XCTUnwrap(try rows(store).first)
            row.isManuallyEdited = true
            row.editedInBedStart = hour(-1)
            row.editedInBedEnd = hour(7)
            try store.context.save()
            let hypnogram = row.hypnogramData
            let record = mirrorRecord(store, key)

            let morning = try syncSessions([sleepA, afterTheAwakening], at: hour(8.5), store: store)
            XCTAssertEqual(morning.nights.count, 0)
            XCTAssertEqual(try XCTUnwrap(try rows(store).first).hypnogramData, hypnogram)
            let filled = store.helioAwakeFilled(SleepHypnogramCodec.decode(hypnogram), window: joinedNight, device: timeline)
            let outcome = await HealthKitWriter().mirrorStrapNight(local: store, segments: filled)
            XCTAssertTrue(isSignatureNoOp(outcome))
            let flushed = try await strapFlush(morning.nights.map(\.segments), at: hour(8.5), store: store)
            XCTAssertEqual(flushed, [])
            XCTAssertEqual(mirrorRecord(store, key), record)
        }
    }

    /// 74c: the readers that judge sleep give build 82's results on the filled night. Skin temperature
    /// 31 °C and HRV 90 ms in the gap (where the strap's heart rate makes a run) are in neither the
    /// nightly verdict nor the overnight stress score, on the save path and the repair pass.
    func testTheFillMovesNoSleepReader() throws {
        try inFixedZoneSync {
            ownership.install(.strapOwnsAllTime)
            let expected = try XCTUnwrap(SleepStress.overnightScore(rmssd: [41, 44, 47]))
            let store = try makeStore()
            try storeHeartRate(-1, 8, store: store)
            let night = try XCTUnwrap(try syncSessions([sleepA, afterTheAwakening], at: hour(9), store: store).nights.first)
            XCTAssertEqual(awakeRuns(night.segments), [DateInterval(start: hour(2), end: hour(5.5))])
            XCTAssertEqual(night.sleepSpans, [DateInterval(start: hour(-1), end: hour(2)), DateInterval(start: hour(5.5), end: hour(7))])
            let temperatures = stride(from: hour(-1).timeIntervalSince1970, to: hour(7).timeIntervalSince1970, by: 300).map { t in
                let time = Date(timeIntervalSince1970: t)
                return QuantitySample(kind: .temperature, start: time, value: time > hour(2) && time < hour(5.5) ? 31 : 34)
            }
            _ = try store.ingest(temperatures, device: timeline)
            let hrv = zip([hour(0), hour(1), hour(6)], [41.0, 47, 44]).map { QuantitySample(kind: .hrvSDNN, start: $0, value: $1) }
                + [QuantitySample(kind: .hrvSDNN, start: hour(3.5), value: 90)]
            _ = try store.ingest(hrv, device: timeline)

            XCTAssertEqual(try store.saveHelioNight(night, device: timeline), .updated)
            let row = try XCTUnwrap(try rows(store).first)
            XCTAssertEqual(row.skinTempC, 34, accuracy: 1e-9, "the run's 31 °C is not in the mean")
            XCTAssertEqual(row.stressScore, expected, "the run's HRV is not in the score")
            for clearSleepScore in [true, false] {
                row.stressScore = 0
                if clearSleepScore { row.sleepScore = 0 }
                try store.context.save()
                _ = try store.scoreUnscoredHelioNights()
                XCTAssertEqual(try XCTUnwrap(try rows(store).first).stressScore, expected, "the repair pass (sleep score cleared: \(clearSleepScore))")
            }
        }
    }
}

// MARK: - Decision 78 (#332): the Sleep Focus end outlives the Focus-off run

/// Every flush here runs through `HelioConnection.flushStrap` (both strap flush sites' shared pass) and
/// reads the writer's per-night verdict before its authorization guard (`lastStrapNights`): the
/// simulator has no Health access, so "skips the margin" is the verdict the writer's gate receives.
/// Sleep Focus ends at 07:00 (`focusEnd`); the persisted T lives in a suite of its own.
extension StrapNightHealthTests {
    private var focusEnd: Date { hour(7) }

    private func focusDefaults() throws -> (UserDefaults, String) {
        let suite = "StrapNightHealthTests.focus.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    /// A flush at `now` through the shared strap pass; what the writer was offered, with each night's verdict.
    private func focusFlush(_ store: LocalStore, nights: [[SleepSegment]] = [], focusEndedAt: Date? = nil, at now: Date,
                            defaults: UserDefaults) async -> [(night: [SleepSegment], finalized: Bool)] {
        let writer = HealthKitWriter()
        _ = await HelioConnection.flushStrap(writer, store: store, timeline: timeline, nights: nights,
                                             focusEndedAt: focusEndedAt, now: now, defaults: defaults)
        return writer.lastStrapNights
    }

    func testTheFocusEndConstantsAreSixHoursAndTenMinutes() {
        XCTAssertEqual(SleepFocusFinalization.persistedValidity, 6 * 3600)
        XCTAssertEqual(SleepFocusFinalization.nightEndSlack, 10 * 60)
        XCTAssertEqual(SleepFocusFinalization.persistedKey, "helio.sleepFocusEndedAt.v1")
    }

    /// The Focus-off run ran out of time before any sleep round; a background run 2 h later fetches the
    /// night, which ended 5 minutes before Focus did. With the persisted T: finalized (no margin), and
    /// the stored copy is offered despite the 3 h newest-night hold.
    func testAPersistedFocusEndFinalizesANightThatEndedBeforeItInAFlushTwoHoursLater() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7 - 5.0 / 60)
        let night = try hypnogram(store, endingAt: 7 - 5.0 / 60)
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let without = await focusFlush(store, nights: [night], at: hour(9), defaults: defaults)
        XCTAssertEqual(without.map(\.finalized), [false], "no Focus end: the normal rules")
        let heldWithout = await focusFlush(store, at: hour(9), defaults: defaults)
        XCTAssertEqual(heldWithout.count, 0, "the 3 h hold keeps the stored copy back")

        SleepFocusFinalization.persist(focusEnd, defaults: defaults)
        let carried = await focusFlush(store, nights: [night], at: hour(9), defaults: defaults)
        XCTAssertEqual(carried.map(\.night), [night])
        XCTAssertEqual(carried.map(\.finalized), [true], "finalized: it skips the margin")
        let stored = await focusFlush(store, at: hour(9), defaults: defaults)
        XCTAssertEqual(stored.map(\.night), [night], "the stored night is offered despite the 3 h hold (58a)")
        XCTAssertEqual(stored.map(\.finalized), [true])
    }

    /// The same 7 h after Focus ended: the persisted T no longer applies (6 h), so the normal rules.
    /// The boundary: 6 h exactly applies, a second later doesn't.
    func testAPersistedFocusEndOverSixHoursOldIsIgnored() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7 - 5.0 / 60)
        let night = try hypnogram(store, endingAt: 7 - 5.0 / 60)
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        SleepFocusFinalization.persist(focusEnd, defaults: defaults)

        let late = await focusFlush(store, nights: [night], at: hour(14), defaults: defaults)
        XCTAssertEqual(late.map(\.finalized), [false], "7 h after Focus ended: the normal rules")
        let edge = await focusFlush(store, nights: [night], at: focusEnd.addingTimeInterval(6 * 3600), defaults: defaults)
        XCTAssertEqual(edge.map(\.finalized), [true], "6 h exactly")
        let past = await focusFlush(store, nights: [night], at: focusEnd.addingTimeInterval(6 * 3600 + 1), defaults: defaults)
        XCTAssertEqual(past.map(\.finalized), [false], "6 h and a second")
    }

    /// The Focus run stored the night but its flush didn't run (it ran out of time after the sleep round).
    /// The next flush, 20 minutes after Focus ended, from the post-sync hook or the app in front (both
    /// `flushStrap`), carries no night: it offers the stored one, finalized, despite 58a's 3 h hold.
    func testANightTheFocusRunStoredButDidNotFlushIsOfferedByTheNextFlushDespiteTheHold() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7 - 5.0 / 60)
        let night = try hypnogram(store, endingAt: 7 - 5.0 / 60)
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let next = focusEnd.addingTimeInterval(20 * 60)
        let heldBefore = await focusFlush(store, at: next, defaults: defaults)
        XCTAssertEqual(heldBefore.count, 0, "without T: held 3 h (58a)")
        SleepFocusFinalization.persist(focusEnd, defaults: defaults)
        let offered = await focusFlush(store, at: next, defaults: defaults)
        XCTAssertEqual(offered.map(\.night), [night])
        XCTAssertEqual(offered.map(\.finalized), [true])
    }

    /// The person went back to sleep: the night ends 30 minutes AFTER Focus ended. It is not over by T:
    /// the margin and 58a's hold apply as usual.
    func testANightEndingThirtyMinutesAfterTheFocusEndIsNotFinalized() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7.5)
        let night = try hypnogram(store, endingAt: 7.5)
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        SleepFocusFinalization.persist(focusEnd, defaults: defaults)
        let now = hour(7.5 + 10.0 / 60)
        let growing = await focusFlush(store, nights: [night], at: now, defaults: defaults)
        XCTAssertEqual(growing.map(\.finalized), [false])
        let heldGrowing = await focusFlush(store, at: hour(9), defaults: defaults)
        XCTAssertEqual(heldGrowing.count, 0, "58a's hold: 3 h from its end")
        let inMemory = await focusFlush(store, nights: [night], focusEndedAt: focusEnd, at: hour(7.6), defaults: defaults)
        XCTAssertEqual(inMemory.map(\.finalized), [false], "decision 31's in-memory T is judged per night too")
    }

    /// The boundary of "ended by T": the last segment at T + 10 min is over, a second later it isn't.
    func testANightEndingTenMinutesAfterTheFocusEndIsTheLastOneFinalized() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        SleepFocusFinalization.persist(focusEnd, defaults: defaults)
        let atSlack = [SleepSegment(start: hour(-1), end: focusEnd.addingTimeInterval(10 * 60), stage: .asleepCore)]
        let past = [SleepSegment(start: hour(-1), end: focusEnd.addingTimeInterval(10 * 60 + 1), stage: .asleepCore)]
        let verdicts = await focusFlush(store, nights: [atSlack, past], at: hour(8), defaults: defaults)
        XCTAssertEqual(verdicts.map(\.finalized), [true, false])
    }

    /// The next evening's night, synced while still in progress within 6 h of T: it ends after T + 10
    /// min, so never finalized. And the morning's night beside it still is: per night, never per flush.
    func testTheNextNightSyncedInProgressWithinSixHoursIsNeverFinalized() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        SleepFocusFinalization.persist(focusEnd, defaults: defaults)
        let morning = [SleepSegment(start: hour(-1), end: hour(6.9), stage: .asleepCore)]
        let inProgress = [SleepSegment(start: hour(11), end: hour(12.9), stage: .asleepCore)]
        let verdicts = await focusFlush(store, nights: [morning, inProgress], at: hour(12.95), defaults: defaults)
        XCTAssertEqual(verdicts.map(\.finalized), [true, false])
    }

    /// No persisted T, or one in the future (a clock moved back): the flush is exactly master's.
    func testAnAbsentOrFuturePersistedFocusEndChangesNothing() async throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7 - 5.0 / 60)
        let night = try hypnogram(store, endingAt: 7 - 5.0 / 60)
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(SleepFocusFinalization.persisted(defaults: defaults))
        for _ in 0..<2 {
            let carried = await focusFlush(store, nights: [night], at: hour(9), defaults: defaults)
            XCTAssertEqual(carried.map(\.night), [night])
            XCTAssertEqual(carried.map(\.finalized), [false])
            let backstop = await focusFlush(store, at: hour(9), defaults: defaults)
            XCTAssertEqual(backstop.count, 0)
            XCTAssertEqual(HelioConnection.strapNights([], store: store, timeline: timeline, now: hour(9)), [])
            SleepFocusFinalization.persist(hour(10), defaults: defaults)   // the second pass: a T after the flush
        }
        XCTAssertEqual(SleepFocusFinalization.nights(inMemory: nil, persisted: nil, flushStartsAt: hour(9)), .none)
        XCTAssertEqual(SleepFocusFinalization.nights(inMemory: nil, persisted: hour(10), flushStartsAt: hour(9)), .none)
    }

    /// Decision 31's in-memory T keeps working on its own (within 30 minutes), and the later of the two
    /// T's applies; the persisted one alone is what the 78c line counts.
    func testTheInMemoryAndPersistedFocusEndsMeetAsTheLatest() {
        let t = focusEnd
        let memory = SleepFocusFinalization.nights(inMemory: t, persisted: nil, flushStartsAt: t.addingTimeInterval(60))
        XCTAssertEqual(memory, SleepFocusFinalization.Nights(focusEnd: t, fromPersisted: false))
        XCTAssertEqual(SleepFocusFinalization.nights(inMemory: t, persisted: nil, flushStartsAt: t.addingTimeInterval(31 * 60)), .none,
                       "decision 31: in memory, 30 minutes")
        XCTAssertEqual(SleepFocusFinalization.nights(inMemory: t, persisted: t, flushStartsAt: t.addingTimeInterval(60)),
                       SleepFocusFinalization.Nights(focusEnd: t, fromPersisted: false), "the Focus run's own flush")
        XCTAssertEqual(SleepFocusFinalization.nights(inMemory: t, persisted: t, flushStartsAt: t.addingTimeInterval(31 * 60)),
                       SleepFocusFinalization.Nights(focusEnd: t, fromPersisted: true))
        let later = t.addingTimeInterval(600)
        XCTAssertEqual(SleepFocusFinalization.nights(inMemory: t, persisted: later, flushStartsAt: later.addingTimeInterval(60)),
                       SleepFocusFinalization.Nights(focusEnd: later, fromPersisted: true))
    }

    /// Decision 78c's second line: once per T, minutes after it, counts only.
    func testThePersistedFocusEndWriteLineIsRecordedOncePerFocusEnd() throws {
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        SleepFocusFinalization.notePersistedWrite(focusEnd: focusEnd, flushStart: focusEnd.addingTimeInterval(125 * 60), defaults: defaults)
        SleepFocusFinalization.notePersistedWrite(focusEnd: focusEnd, flushStart: focusEnd.addingTimeInterval(200 * 60), defaults: defaults)
        SleepFocusFinalization.notePersistedWrite(focusEnd: hour(31), flushStart: hour(32), defaults: defaults)
        let lines = ObservabilityStore(defaults).metricRecords().filter { $0.source == "focus" }.map(\.detail)
        XCTAssertEqual(lines, ["night written from the Sleep Focus end, 125 min after it",
                               "night written from the Sleep Focus end, 60 min after it"])
    }

    // MARK: 78b: the retry after a strap Focus run

    private func followUpScheduler(now: Date) -> (BackgroundRefreshScheduler, MarginRecorder) {
        let recorder = MarginRecorder()
        return (BackgroundRefreshScheduler(scheduler: recorder, now: { now }, window: { _ in nil }), recorder)
    }

    /// The Focus run ran out of time with the night stored but not in Health: a refresh at T + 15 min,
    /// recorded, so the app's `schedule()` doesn't replace it.
    func testAFocusRunThatLeftTheNightOutOfHealthRecordsARetryThatSurvivesSchedule() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7 - 5.0 / 60)
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = focusEnd.addingTimeInterval(28)
        let (scheduler, recorder) = followUpScheduler(now: now)
        let night = store.strapFocusNight(timeline: timeline, focusEnd: focusEnd)
        XCTAssertEqual(night, .storedNotWritten)
        let retry = SleepFocusStrapFollowUp.finish(HelioBackgroundRun(ending: .outOfTime), focusEnd: focusEnd, night: night,
                                                   expired: false, scheduler: scheduler, observability: observability,
                                                   defaults: defaults, now: now)
        XCTAssertTrue(retry)
        let at = focusEnd.addingTimeInterval(15 * 60)
        XCTAssertEqual(StrapNightRefresh.pending(now: now, defaults: defaults), at)
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, at)
        scheduler.schedule()
        XCTAssertTrue(StrapNightRefresh.resubmit(scheduler, strapChosen: true, now: now, defaults: defaults))
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, at, "it survives `schedule()`")
        XCTAssertEqual(observability.metricRecords().filter { $0.source == "focus" }.map(\.detail),
                       ["ending=outOfTime night=stored-not-written retry=yes"])
    }

    /// Every ending is included: coalesced, another run active, strap busy, and an expired task (which
    /// still records it, with no resubmit after a `schedule()` that never ran). No night stored at all
    /// asks too.
    func testEveryFocusRunEndingAsksForTheRetryWhenNoNightIsInHealth() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        XCTAssertEqual(store.strapFocusNight(timeline: timeline, focusEnd: focusEnd), .none)
        let endings: [HelioBackgroundRun.Ending] = [.coalesced(into: .processing), .anotherRunActive, .strapBusy, .expired, .synced]
        for ending in endings {
            let (defaults, suite) = try focusDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let now = focusEnd.addingTimeInterval(10)
            let (scheduler, recorder) = followUpScheduler(now: now)
            XCTAssertTrue(SleepFocusStrapFollowUp.finish(HelioBackgroundRun(ending: ending), focusEnd: focusEnd, night: .none,
                                                         expired: ending == .expired, scheduler: scheduler,
                                                         observability: observability, defaults: defaults, now: now), ending.label)
            XCTAssertEqual(StrapNightRefresh.pending(now: now, defaults: defaults), focusEnd.addingTimeInterval(15 * 60), ending.label)
            XCTAssertEqual(recorder.submitted?.earliestBeginDate, focusEnd.addingTimeInterval(15 * 60), ending.label)
        }
        XCTAssertEqual(observability.metricRecords().filter { $0.source == "focus" }.map(\.detail).last,
                       "ending=synced night=none retry=yes")
    }

    /// A Focus run that wrote the night: no retry, and its flush's verdict (nil) clears a pending refresh.
    func testAFocusRunThatWroteTheNightAsksForNoRetry() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7 - 5.0 / 60)
        try recordMirror(try hypnogram(store, endingAt: 7 - 5.0 / 60), store: store)
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = focusEnd.addingTimeInterval(20)
        let (scheduler, _) = followUpScheduler(now: now)
        StrapNightRefresh.record(focusEnd.addingTimeInterval(10 * 60), scheduler: scheduler, defaults: defaults)
        let night = store.strapFocusNight(timeline: timeline, focusEnd: focusEnd)
        XCTAssertEqual(night, .written)
        var run = HelioBackgroundRun(ending: .synced)
        run.flushMS = 40
        XCTAssertFalse(SleepFocusStrapFollowUp.finish(run, focusEnd: focusEnd, night: night, expired: false, scheduler: scheduler,
                                                      observability: observability, defaults: defaults, now: now))
        XCTAssertNil(StrapNightRefresh.pending(now: now, defaults: defaults))
        XCTAssertEqual(observability.metricRecords().filter { $0.source == "focus" }.map(\.detail), ["ending=synced night=written retry=no"])
    }

    /// A later refresh already pending is kept, not pulled forward.
    func testAPendingLaterRefreshIsKeptByTheFocusRetry() throws {
        let (defaults, suite) = try focusDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = focusEnd.addingTimeInterval(20)
        let (scheduler, _) = followUpScheduler(now: now)
        let later = focusEnd.addingTimeInterval(40 * 60)
        StrapNightRefresh.record(later, scheduler: scheduler, defaults: defaults)
        XCTAssertTrue(SleepFocusStrapFollowUp.finish(HelioBackgroundRun(ending: .outOfTime), focusEnd: focusEnd, night: .storedNotWritten,
                                                     expired: false, scheduler: scheduler, observability: observability,
                                                     defaults: defaults, now: now))
        XCTAssertEqual(StrapNightRefresh.pending(now: now, defaults: defaults), later)
    }

    /// The night a Focus run was for: one ending after T + 10 min (still growing), or over 18 h before T,
    /// or the ring's, is not it.
    func testTheFocusRunsNightEndsByTheSlackAndWithinEighteenHoursBeforeIt() throws {
        ownership.install(.strapOwnsAllTime)
        let store = try makeStore()
        try saveNight(store, from: -1, to: 7.5)
        XCTAssertEqual(store.strapFocusNight(timeline: timeline, focusEnd: focusEnd), .none, "ends 30 min after T")
        XCTAssertEqual(store.strapFocusNight(timeline: timeline, focusEnd: hour(7.5).addingTimeInterval(18 * 3600)), .storedNotWritten)
        XCTAssertEqual(store.strapFocusNight(timeline: timeline, focusEnd: hour(7.5).addingTimeInterval(18 * 3600 + 1)), .none)
        XCTAssertEqual(store.strapFocusNight(timeline: timeline, focusEnd: hour(7.5).addingTimeInterval(-10 * 60)), .storedNotWritten)

        ownership.install(DeviceOwnershipLog())
        XCTAssertEqual(store.strapFocusNight(timeline: timeline, focusEnd: hour(7.5)), .none, "ring-only: no strap night")
    }
}
