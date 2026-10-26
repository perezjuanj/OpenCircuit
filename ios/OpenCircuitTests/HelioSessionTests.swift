import BackgroundTasks
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// `HelioSession` end to end against the simulated strap (`FakeZeppDevice`, shared with ZeppKitTests)
// and a real in-memory `LocalStore` (#215 phase 3). Every key, reading and time is synthetic.

// MARK: - Fixtures

/// 2026-09-20T00:00:00Z. Test clocks sit in the past so `ingest`'s "not in the future" guard, which
/// reads the real clock, always passes.
private let midnight: TimeInterval = 1_789_862_400
private let testNow = Date(timeIntervalSince1970: midnight + 12 * 3600)

private let keyHex = "00112233445566778899aabbccddeeff"
private let strapPrivateKey = Array(UInt8(0x81)...UInt8(0x98))
private let strapRandom = Array(UInt8(0xf0)...UInt8(0xff))

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// One night 23:00 → 07:00 (UTC), staged light / deep / REM / light.
private func sessionRecord() -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(midnight)), at: 0x000)
    put(le32(UInt32(midnight)), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(1380), at: 0x00A)
    put(le16(1860), at: 0x00C)
    r[0x016] = 81
    let stages: [(UInt16, UInt16, UInt8)] = [(1380, 1500, 0x04), (1500, 1560, 0x05), (1560, 1620, 0x08), (1620, 1860, 0x04)]
    r[0x054] = UInt8(stages.count)
    // §6.6 (decision 70e): a stage's end minute is inclusive, so a stage ending at `end` is written as `end − 1`.
    for (i, s) in stages.enumerated() { put(le16(s.0) + le16(s.1 - 1) + [s.2], at: 0x056 + 5 * i) }
    return r
}

/// Back to bed within the hour (decision 28f): 07:40 → 08:30, 40 min after `sessionRecord()`'s night
/// ends, one light stage. Same midnight reference.
private func laterSessionRecord() -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(midnight + 7 * 3600 + 40 * 60)), at: 0x000)
    put(le32(UInt32(midnight)), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(1900), at: 0x00A)
    put(le16(1950), at: 0x00C)
    r[0x016] = 70
    r[0x054] = 1
    // §6.6 (decision 70e): a stage's end minute is inclusive, so a stage ending at `end` is written as `end − 1`.
    put(le16(1900) + le16(1950 - 1) + [0x04], at: 0x056)
    return r
}

/// 60 activity minutes from 23:00: worn (kind 0x01, 5 steps, HR 55), except minutes 10–14 not
/// worn (0x73, no HR) and 20–24 charging (0x76, no HR).
private func activityData() -> [UInt8] {
    (0..<60).flatMap { i -> [UInt8] in
        switch i {
        case 10..<15: return [0x73, 0, 0, 0xff, 0, 0, 0, 0]
        case 20..<25: return [0x76, 0, 0, 0xff, 0, 0, 0, 0]
        default: return [0x01, 0x08, 5, 55, 0, 0, 0, 0]
        }
    }
}

/// 60 temperature minutes from 23:00 at 33.50 °C, except minute 30 at 29.00 °C (out of range).
private func temperatureData() -> [UInt8] {
    (0..<60).flatMap { i -> [UInt8] in
        let centi = UInt16(i == 30 ? 2900 : 3350)
        return [0xff, 0x7f] + le16(centi) + [0x5a, 0x5a, 0x5a, 0x5a]
    }
}

/// Two HRV readings during the night (made-up values).
private func hrvData() -> [UInt8] {
    le32(UInt32(midnight + 3600)) + [0x00, 41] + le32(UInt32(midnight + 7200)) + [0x00, 47]
}

/// One SpO₂ record (version 02, 65-byte record): automatic, 96 %.
private func spo2Data() -> [UInt8] {
    [0x02] + le32(UInt32(midnight + 1800)) + [0x80 | 96] + [UInt8](repeating: 0, count: 60)
}

/// The endpoints a Helio lists, with the controls (§3.5): find encrypted, alarms plaintext.
private let helioServices: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]

/// A device-info reply (§5.3): `02 01`, flags 0x0C (hardware + firmware, no bit-0 blob), then the two
/// NUL-terminated versions. Made-up versions; the hardware one matches the fake DIS read.
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func makeStrap(authKey: String = keyHex) -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(authKey)!, privateKey: strapPrivateKey, random: strapRandom,
                                writeLength: 244)
    device.services = helioServices
    device.deviceInfoReply = deviceInfoReply
    device.dataPacketLength = 200
    let night = midnight - 3600
    device.fetchData = [
        .activity: (stamp(night), activityData()),
        .sleepSession: (stamp(midnight), sessionRecord()),
        .temperature: (stamp(night), temperatureData()),
        .hrv: (stamp(midnight + 3600), hrvData()),
        .spo2: (stamp(midnight + 1800), spo2Data()),
    ]
    return device
}

/// `HelioTransport` over `FakeZeppDevice`. Deliveries are QUEUED and handed to the session by
/// `drain()`, as CoreBluetooth hands them over on a later run-loop turn, never inside a write.
@MainActor
private final class FakeStrapTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    /// When true, writes vanish (a strap that never answers).
    var silent = false
    private(set) var writes: [ZeppWrite] = []
    private(set) var notifyChanges: [(ZeppCharacteristic, Bool)] = []
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }

    func write(_ write: ZeppWrite) {
        writes.append(write)
        guard !silent else { return }
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }

    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) {
        notifyChanges.append((characteristic, enabled))
        inbox.append((characteristic, nil, enabled))
    }

    func read(_ characteristic: ZeppCharacteristic) {
        switch characteristic {
        case .hardwareRevision: inbox.append((characteristic, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((characteristic, [64], false))
        default: break
        }
    }

    /// A strap-originated message (e.g. find device `07`).
    func push(_ notifications: [FakeZeppDevice.Notification]) {
        for n in notifications { inbox.append((n.characteristic, n.bytes, false)) }
    }

    /// A raw notification on a standard characteristic (e.g. `0x2A37`).
    func push(_ characteristic: ZeppCharacteristic, _ bytes: [UInt8]) {
        inbox.append((characteristic, bytes, false))
    }

    /// Deliver only the next `count` queued events.
    func drainSteps(_ count: Int) {
        for _ in 0..<count where !inbox.isEmpty {
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes {
                session?.received(characteristic, bytes)
            } else {
                session?.notificationStateChanged(characteristic, enabled: enabled, failed: false)
            }
        }
    }

    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 100_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes {
                session?.received(characteristic, bytes)
            } else {
                session?.notificationStateChanged(characteristic, enabled: enabled, failed: false)
            }
        }
    }
}

@MainActor
private final class MemoryKeyStore: HelioKeyStoring {
    var text: String?
    var isRejected = false
    init(_ text: String?) { self.text = text }
    func load() -> ZeppAuthKey? { text.flatMap(HelioKeyText.parse) }
    func save(pasted text: String) throws -> Bool {
        guard HelioKeyText.normalized(text) != nil else { return false }
        self.text = text
        isRejected = false
        return true
    }
    func forget() { text = nil; isRejected = false }
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class HelioSessionTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = testNow
    private let strapID = "5B1E4C2A-0000-4000-8000-0000000000A1"
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)   // a strap-only install (decision 28's first entry)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private struct Rig {
        let session: HelioSession
        let transport: FakeStrapTransport
        let keyStore: MemoryKeyStore
        var synced: [HelioSyncResult]
    }

    /// A connected session over `device`, started and drained until it settles.
    private func connect(_ device: FakeZeppDevice, store: LocalStore?, key: String? = keyHex,
                         keyStore: MemoryKeyStore? = nil, findState: HelioFindState? = nil,
                         autoSync: Bool = true, finished: @escaping (HelioSyncResult) -> Void = { _ in },
                         onEvent: @escaping (HelioSessionEvent) -> Void = { _ in }) -> Rig {
        let transport = FakeStrapTransport(device: device)
        let keys = keyStore ?? MemoryKeyStore(key)
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: store.map { HelioStoreSink(store: $0) }, findState: findState ?? HelioFindState(),
                                   onSyncFinished: { result, _ in finished(result) }, onEvent: onEvent,
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: autoSync)
        transport.session = session
        session.start()
        transport.drain()
        return Rig(session: session, transport: transport, keyStore: keys, synced: [])
    }

    private func rows(_ store: LocalStore) throws -> [String] {
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "\($0.deviceID) \($0.kindRaw) \($0.start.timeIntervalSince1970) \($0.value)" }
        let steps = try store.context.fetch(FetchDescriptor<StoredStepSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "step \($0.start.timeIntervalSince1970) \($0.end.timeIntervalSince1970) \($0.delta)" }
        let dailies = try store.context.fetch(FetchDescriptor<StoredDaily>()).map { "daily \($0.day.timeIntervalSince1970) \($0.steps)" }
        let nights = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            .map { "night \($0.night.timeIntervalSince1970) asleep \($0.asleepMin) deep \($0.deepMin) rem \($0.remMin) temp \($0.skinTempC)" }
        return (samples + steps + dailies + nights).sorted()
    }

    // MARK: auth ok → clock set → fetch all types → store rows → ack 03 09 every round

    func testAFullSyncSetsTheClockStoresEveryTypeAndAcksKeepEveryRound() async throws {
        let store = try makeStore()
        let device = makeStrap()
        var results: [HelioSyncResult] = []
        let rig = connect(device, store: store, finished: { results.append($0) })

        XCTAssertTrue(device.authenticated)
        XCTAssertEqual(device.timeSetCount, 1, "decision 9: the clock is set after auth on every connection")
        XCTAssertTrue(rig.session.clockSet)
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.batteryPercent, 0x57, "the battery endpoint's level replaces the unauthenticated read")
        XCTAssertEqual(rig.session.hardwareVersion, "9.9.9.9")

        // Every planned type was started, each first round from its watermark.
        let startedTypes = Set(device.fetchStarts.compactMap { ZeppFetchType(rawValue: $0[1]) })
        XCTAssertEqual(startedTypes, Set(HelioFetchPlan.types))
        // Decision 8: every round, delivered or empty, is acked 03 09. Never 03 01.
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertEqual(Set(rig.session.fetchAcksSent), [0x09])
        XCTAssertEqual(device.failures, [])

        // Rows, all on the strap's own timeline (decision 10).
        let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: strapID)
        XCTAssertEqual(timeline.rawValue, "zeppos:\(strapID)")
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertTrue(samples.allSatisfy { $0.deviceID == timeline.rawValue })
        XCTAssertEqual(samples.filter { $0.kindRaw == "heartRate" }.count, 50, "60 minutes minus 10 unworn/charging without HR")
        XCTAssertEqual(samples.filter { $0.kindRaw == "hrvSDNN" }.map(\.value).sorted(), [41, 47], "HRV stored locally")
        XCTAssertEqual(samples.filter { $0.kindRaw == "spo2" }.map(\.value), [0.96])
        // Temperature: worn, in the strap's sleep window, 30–42 °C: 60 − 5 unworn − 5 charging − 1 at 29 °C.
        XCTAssertEqual(samples.filter { $0.kindRaw == "temperature" }.count, 49)
        let steps = try store.context.fetch(FetchDescriptor<StoredStepSample>())
        XCTAssertEqual(steps.count, 50)
        XCTAssertTrue(steps.allSatisfy { $0.delta == 5 && $0.end.timeIntervalSince($0.start) == 60 })
        // The strap's night, with its nightly skin temperature.
        let nights = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights.first?.asleepMin, 480)
        XCTAssertEqual(nights.first?.deepMin, 60)
        XCTAssertEqual(nights.first?.remMin, 60)
        // Each type's watermark, under the strap's timeline.
        let cursors = store.helioFetchCursors(device: timeline)
        XCTAssertNotNil(cursors[.activity])
        XCTAssertNotNil(cursors[.temperature])
        XCTAssertNotNil(cursors[.sleepSession])

        // The Health pass hands over the night and the timeline; HRV is a Health kind for it (decision 44).
        for _ in 0..<200 where results.isEmpty { await Task.yield() }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.nights.count, 1)
        let pending = try store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds())
        XCTAssertEqual(pending.filter { $0.kind == .hrvSDNN }.map(\.value).sorted(), [41, 47],
                       "decision 44: the strap's HRV (RMSSD) goes to Apple Health")
        XCTAssertTrue(pending.contains { $0.kind == .heartRate })
        XCTAssertTrue(pending.contains { $0.kind == .temperature })
        XCTAssertTrue(try store.pendingHealthSamples().isEmpty, "the ring's timeline is untouched")
    }

    // MARK: the night is scored on the phone (#246, decision 48)

    /// A whole real sync, through the sink: the night ends with OpenCircuit's own Sleep Score and
    /// overnight recovery, so Readiness has something to anchor on with the strap.
    ///
    /// The ordering is the point. `HelioFetchPlan.types` fetches sleep sessions before temperature
    /// and HRV, so the save that stores the night has neither; `finishSync` re-saves every stored
    /// night and that is what carries them on. Overnight recovery here is computed from the strap's
    /// HRV taken as RMSSD, a statistic that is still 🟡 (decision 44).
    func testTheStrapsNightIsScoredOnThePhone() throws {
        let plan = HelioFetchPlan.types
        let sleepAt = try XCTUnwrap(plan.firstIndex(of: .sleepSession))
        XCTAssertLessThan(sleepAt, try XCTUnwrap(plan.firstIndex(of: .hrv)))
        XCTAssertLessThan(sleepAt, try XCTUnwrap(plan.firstIndex(of: .temperature)))

        let store = try makeStore()
        _ = connect(makeStrap(), store: store)
        let night = try XCTUnwrap(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).first)
        XCTAssertGreaterThan(night.sleepScore, 0, "#246: the strap's night carries a Sleep Score")
        // The fixture's two HRV readings are 41 and 47 ms; the median is the night's RMSSD.
        XCTAssertEqual(night.stressScore, SleepStress.overnightScore(rmssd: [41, 47]))
        // Its first night has no same-device baseline yet (decision 29), so the temperature factor
        // drops out rather than being compared with nothing: the score is the composite without it.
        XCTAssertEqual(night.sleepScore,
                       StoredNightScore.scores(.init(
                           segments: SleepHypnogramCodec.decode(night.hypnogramData),
                           heartRate: try store.samples(kind: .heartRate, from: night.inBedStart, to: night.inBedEnd)
                               .map { HRSample(bpm: Int($0.value.rounded()), start: $0.start, end: $0.end) })).sleepScore)
        XCTAssertFalse(night.isManuallyEdited)
    }

    // MARK: the same history twice → no duplicate rows

    func testSyncingTheSameHistoryTwiceLeavesIdenticalRows() throws {
        let store = try makeStore()
        let device = makeStrap()
        _ = connect(device, store: store)
        let first = try rows(store)
        XCTAssertFalse(first.isEmpty)

        // A new connection re-delivers everything (the strap keeps what 03 09 acknowledged, §6.3).
        clock = clock.addingTimeInterval(600)
        _ = connect(device, store: store)
        XCTAssertEqual(try rows(store), first)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    // MARK: wrong key → key rejected, no retry loop

    func testAWrongKeyIsRejectedOnceAndNeverRetried() throws {
        let device = makeStrap(authKey: "ffeeddccbbaa99887766554433221100")
        let keys = MemoryKeyStore(keyHex)
        let rig = connect(device, store: try makeStore(), keyStore: keys)
        XCTAssertEqual(rig.session.phase, .keyRejected)
        XCTAssertTrue(keys.isRejected)
        XCTAssertFalse(device.authenticated)
        let authMessages = device.receivedEndpoints.filter { $0 == 0x0082 }.count
        XCTAssertEqual(authMessages, 2, "one 04 and one 05")

        // Time passes: nothing is re-sent on this connection.
        clock = clock.addingTimeInterval(3600)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, authMessages)

        // A later connection with the same (rejected) key doesn't authenticate at all.
        let again = connect(device, store: try makeStore(), keyStore: keys)
        XCTAssertEqual(again.session.phase, .keyRejected)
        XCTAssertFalse(again.transport.writes.contains { $0.characteristic == .chunkedWrite })
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, authMessages)
        XCTAssertFalse(again.session.capabilities.contains(.historySync))

        // Replacing the key clears the mark.
        XCTAssertTrue(try keys.save(pasted: "0x" + keyHex))
        XCTAssertFalse(keys.isRejected)
    }

    func testAStrapThatNeverAnswersIsReportedBusy() throws {
        let device = makeStrap()
        let transport = FakeStrapTransport(device: device)
        transport.silent = true
        let keys = MemoryKeyStore(keyHex)
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: nil, findState: HelioFindState(), clock: { [unowned self] in self.clock },
                                   autoTick: false)
        transport.session = session
        session.start()
        transport.drain()
        XCTAssertEqual(session.phase, .authenticating)
        clock = clock.addingTimeInterval(HelioSession.authTimeout + 1)
        session.tick(now: clock)
        XCTAssertEqual(session.phase, .strapBusy)
        XCTAssertFalse(keys.isRejected, "busy is not a wrong key")
    }

    func testWithoutAKeyOnlyStandardHeartRateIsShown() throws {
        let device = makeStrap()
        let rig = connect(device, store: try makeStore(), key: nil)
        XCTAssertEqual(rig.session.phase, .keyless)
        XCTAssertFalse(rig.transport.writes.contains { $0.characteristic == .chunkedWrite }, "nothing is sent without a key")
        XCTAssertTrue(rig.transport.notifyChanges.contains { $0 == (.heartRateMeasurement, true) })
        XCTAssertNil(rig.session.liveHR, "no data is made up")
        XCTAssertFalse(rig.session.capabilities.contains(.liveHeartRate))

        rig.transport.push([FakeZeppDevice.Notification(characteristic: .heartRateMeasurement, bytes: [0x00, 62])])
        rig.transport.drain()
        XCTAssertEqual(rig.session.liveHR, 62)
        XCTAssertTrue(rig.session.capabilities.contains(.liveHeartRate))
        XCTAssertFalse(rig.session.capabilities.contains(.historySync))
    }

    // MARK: find start → leaving the screen or backgrounding → stop 06

    func testFindStopsWhenTheAppBackgroundsOrTheScreenIsLeft() throws {
        let device = makeStrap()
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertTrue(rig.session.capabilities.contains(.findMyDevice))
        XCTAssertEqual(rig.session.findVersion, 2)

        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        rig.session.appDidEnterBackground()
        rig.transport.drain()
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(device.findOpcodes.suffix(2), [0x03, 0x06])

        // Leaving the Find My Strap screen calls `stopFind()`.
        XCTAssertNil(rig.session.startFind())
        rig.session.stopFind()
        rig.transport.drain()
        XCTAssertEqual(device.findOpcodes.suffix(2), [0x03, 0x06])
        XCTAssertFalse(device.isBuzzing)
    }

    func testFindStopsAfterSixtySecondsAndABuzzAfterTwo() throws {
        let device = makeStrap()
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        clock = clock.addingTimeInterval(59)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        clock = clock.addingTimeInterval(1)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertFalse(device.isBuzzing, "decision 18: 60 s at most")

        XCTAssertNil(rig.session.buzz())
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        clock = clock.addingTimeInterval(2)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertFalse(device.isBuzzing, "decision 19: a 2 s buzz")
        XCTAssertEqual(device.findOpcodes.filter { $0 == 0x03 }.count, device.findOpcodes.filter { $0 == 0x06 }.count)
    }

    func testALinkDropMidFindSendsTheStopOnTheNextConnection() throws {
        let device = makeStrap()
        let findState = HelioFindState()
        let rig = connect(device, store: nil, findState: findState, autoSync: false)
        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        rig.session.linkLost()
        XCTAssertTrue(device.isBuzzing, "the stop could not go out")

        let next = connect(device, store: nil, findState: findState, autoSync: false)
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(next.session.findPhase, .stopped(.linkLost))
        XCTAssertEqual(Array(device.findOpcodes.suffix(2)), [0x06, 0x01], "the owed stop, then the capabilities request")
    }

    func testAFindStopOwedSurvivesTheProcess() throws {
        let suite = "test.HelioSessionTests.findStop"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = makeStrap()
        let rig = connect(device, store: nil, findState: HelioFindState(defaults: defaults), autoSync: false)
        XCTAssertNil(rig.session.startFind())
        rig.transport.drain()
        XCTAssertTrue(device.isBuzzing)
        XCTAssertTrue(defaults.bool(forKey: HelioFindState.stopOwedKey))

        // The system ends the process with the strap still buzzing. The next process's first
        // connection sends the stop before anything else on the find endpoint.
        let next = connect(device, store: nil, findState: HelioFindState(defaults: defaults), autoSync: false)
        XCTAssertFalse(device.isBuzzing)
        XCTAssertEqual(Array(device.findOpcodes.suffix(2)), [0x06, 0x01])
        XCTAssertFalse(defaults.bool(forKey: HelioFindState.stopOwedKey))

        // A find stopped normally leaves nothing owed.
        XCTAssertNil(next.session.startFind())
        XCTAssertTrue(defaults.bool(forKey: HelioFindState.stopOwedKey))
        next.session.stopFind()
        next.transport.drain()
        XCTAssertFalse(defaults.bool(forKey: HelioFindState.stopOwedKey))
    }

    func testControlsTheStrapDoesNotListAreHidden() throws {
        let device = makeStrap()
        device.services = helioServices.filter { $0.endpoint != 0x001A && $0.endpoint != 0x000F }
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertFalse(rig.session.capabilities.contains(.findMyDevice))
        XCTAssertFalse(rig.session.capabilities.contains(.vibration))
        XCTAssertFalse(rig.session.capabilities.contains(.alarm))
        XCTAssertNotNil(rig.session.startFind(), "nothing is sent to an unlisted endpoint")
        XCTAssertEqual(device.findOpcodes, [])
        XCTAssertEqual(device.alarmCommands, [])
    }

    // MARK: an alarm edit writes exactly one slot, after a read

    func testAnAlarmEditWritesExactlyOneSlotAfterARead() throws {
        let device = makeStrap()
        // One alarm the person made in Zepp, in slot 3: 09:15, Sat + Sun, disabled.
        device.alarmRecords = [3: [0x00, 0x03, 0x09, 0x0f, 0x60, 0x00, 0x00, 0x00, 0x01, 0x00]]
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertEqual(device.alarmCommands, [[0x09]], "setup reads the list and writes nothing (§15.1)")
        XCTAssertEqual(rig.session.alarmEditor?.alarms?.map(\.slot), [3])
        XCTAssertTrue(rig.session.alarmEditor?.canEdit == true, "the clock was set on this connection")

        XCTAssertNil(rig.session.addAlarm(hour: 6, minute: 30, days: .weekdays))
        rig.transport.drain()
        XCTAssertEqual(device.alarmCommands, [
            [0x09],
            [0x03, 0x01, 0x04, 0x00, 0x06, 0x1e, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00],   // slot 0, the lowest free
            [0x09],                                                                      // re-read
        ])
        XCTAssertEqual(rig.session.alarmEditor?.alarms?.map(\.slot), [0, 3])
        XCTAssertEqual(rig.session.alarmNotice, "Saved on the strap.")

        // Enabling the Zepp alarm rewrites only its own slot.
        var zepp = try XCTUnwrap(rig.session.alarmEditor?.alarms?.first { $0.slot == 3 })
        zepp.isEnabled = true
        XCTAssertNil(rig.session.replaceAlarm(zepp))
        rig.transport.drain()
        let writes = device.alarmCommands.filter { $0.first == 0x03 || $0.first == 0x05 }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?[3], 3, "slot 3 only")
        XCTAssertEqual(device.alarmCommands.last, [0x09])
    }

    // MARK: identity and capabilities

    func testIdentityNamesTheStrapForAppleHealth() throws {
        let device = makeStrap()
        let rig = connect(device, store: nil, autoSync: false)
        let fields = try XCTUnwrap(HealthDeviceAttribution.fields(for: rig.session.identity, origin: .device))
        XCTAssertEqual(fields.name, "Helio Strap")
        XCTAssertEqual(fields.manufacturer, "Amazfit")
        XCTAssertEqual(fields.model, "Helio Strap")
        XCTAssertEqual(fields.hardwareVersion, "9.9.9.9")
        XCTAssertEqual(fields.firmwareVersion, "1.2.3.4", "from the device-info read (§5.3): the Helio has no DIS firmware")
        // The family rule (#222): a device's localIdentifier is its timeline, the strap's own zeppos:<id>.
        XCTAssertEqual(fields.localIdentifier, "zeppos:\(strapID)")
        XCTAssertNotEqual(fields.localIdentifier, SyncDeviceID.ringConn.rawValue)
        XCTAssertNil(HealthDeviceAttribution.fields(for: rig.session.identity, origin: .userEntered),
                     "manual entries carry no device (decision 11)")
        XCTAssertEqual(rig.session.deviceKind, .zeppOS(model: "Helio Strap"))
    }

    // MARK: review follow-ups

    /// Review-224 S1: the HEALTH read is the hardware-validated seven-argument request. The fake
    /// answers each exact payload differently, so the warnings reveal which bytes were sent.
    func testTheHealthReadIsTheHardwareValidatedRequest() throws {
        let seven: [UInt8] = [0x03, 0x00, 0x08, 0x07, 0x01, 0x04, 0x05, 0x11, 0x12, 0x13, 0x31]
        let six: [UInt8] = [0x03, 0x00, 0x08, 0x06, 0x01, 0x05, 0x11, 0x12, 0x13, 0x31]
        XCTAssertEqual(ZeppConfig.readRequest(group: ZeppConfig.healthGroup, arguments: ZeppConfig.healthReadArguments), seven)
        let device = makeStrap()
        device.configReply = [0x04, 0x01, 0x08, 0x03, 0x00, 0x01, 0x01, 0x10, 0xff]                      // any other read: all on
        device.configReplies[seven] = [0x04, 0x01, 0x08, 0x03, 0x00, 0x02, 0x01, 0x10, 0xff, 0x13, 0x0b, 0x00]  // stress off
        device.configReplies[six] = [0x04, 0x01, 0x08, 0x03, 0x00, 0x02, 0x01, 0x10, 0xff, 0x31, 0x0b, 0x00]    // SpO₂ off
        let rig = connect(device, store: nil, autoSync: false)
        XCTAssertEqual(rig.session.recordingWarnings, ["Stress monitoring is off, so stress will be empty."],
                       "the app sends healthReadArguments, the request proven on hardware")
    }

    func testActiveHRMonitoringIsNeverARecordingWarning() throws {
        // HEALTH read reply: all-day HR 00 (off), 0x04 (Active HR monitoring) off, stress off.
        let reply = try XCTUnwrap(ZeppConfig.parseReadReply(
            [0x04, 0x01, 0x08, 0x03, 0x00, 0x03, 0x01, 0x10, 0x00, 0x04, 0x0b, 0x00, 0x13, 0x0b, 0x00]))
        let warnings = HelioSession.recordingWarnings(ZeppHealthSettings(reply))
        XCTAssertEqual(warnings.count, 2, "all-day HR and stress; never 0x04")
        XCTAssertFalse(warnings.contains { $0.localizedCaseInsensitiveContains("activity") })
        XCTAssertTrue(HelioSession.recordingWarnings(ZeppHealthSettings(
            try XCTUnwrap(ZeppConfig.parseReadReply([0x04, 0x01, 0x08, 0x03, 0x00, 0x01, 0x04, 0x0b, 0x00])))).isEmpty)
    }

    func testADisconnectMidSyncAcksTheOpenRoundKeep() throws {
        let store = try makeStore()
        let device = makeStrap()
        let rig = connect(device, store: store, autoSync: false)
        rig.session.syncHistory(manual: true)
        // Enable notify, send the first start, and let its reply open a round, then stop draining.
        rig.transport.drainSteps(3)
        let acksBefore = rig.session.fetchAcksSent.count
        rig.session.abortSync()
        XCTAssertEqual(rig.session.fetchAcksSent.count, acksBefore + 1)
        XCTAssertEqual(rig.session.fetchAcksSent.last, 0x09)
    }

    // MARK: review-223 U1: a round the strap never answers after our 03 09

    func testARoundTheStrapNeverAnswersAfterOurKeepAckTripsTheStallTimeoutAndTheNextSyncWorks() throws {
        let store = try makeStore()
        let device = makeStrap()
        // A hostile announcement: 4 MiB of automatic stress (over the record limit, review-223 N1). The
        // app refuses it with 03 09 and no 02, and this strap then never answers (no 10 03).
        device.announcedLengths[.autoStress] = 4 << 20
        device.unansweredAckTypes = [.autoStress]
        var results: [HelioSyncResult] = []
        let rig = connect(device, store: store, finished: { results.append($0) })
        XCTAssertEqual(rig.session.phase, .syncing, "stuck waiting for the ack reply")
        XCTAssertEqual(device.fetchAcks.last, 0x09)
        let stressStart = try XCTUnwrap(device.fetchStarts.last)
        XCTAssertEqual(stressStart[1], ZeppFetchType.autoStress.rawValue)

        // No progress for the stall timeout: the sync ends cleanly, interrupted, nothing more is sent.
        let writesBefore = rig.transport.writes.count
        clock = clock.addingTimeInterval(HelioSession.syncStallTimeout - 1)
        rig.session.tick(now: clock)
        XCTAssertEqual(rig.session.phase, .syncing)
        clock = clock.addingTimeInterval(2)
        rig.session.tick(now: clock)
        rig.transport.drain()
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.lastSyncResult?.interrupted, true)
        XCTAssertEqual(rig.session.syncStatus, "Sync interrupted: what arrived is saved, the rest stays on the strap")
        XCTAssertFalse(rig.transport.writes[writesBefore...].contains { $0.characteristic == .activityControl && $0.bytes.first == 0x03 },
                       "the round already had its 03 09; the abort sends no second ack")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        let storedBefore = try store.context.fetch(FetchDescriptor<StoredSample>()).count
        XCTAssertGreaterThan(storedBefore, 0, "the rounds before it stay stored")

        // The strap answers again: the next sync on the same connection runs every type to the end.
        device.unansweredAckTypes = []
        device.announcedLengths = [:]
        let startsBefore = device.fetchStarts.count
        rig.session.syncHistory(manual: true)
        rig.transport.drain()
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.lastSyncResult?.interrupted, false)
        XCTAssertEqual(Set(device.fetchStarts[startsBefore...].compactMap { ZeppFetchType(rawValue: $0[1]) }),
                       Set(HelioFetchPlan.types))
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)
    }

    func testALateNotifyOffDoesNotStartTheNextFetch() throws {
        let store = try makeStore()
        let device = makeStrap()
        let rig = connect(device, store: store, autoSync: false)
        rig.session.syncHistory(manual: true)
        let startsBefore = device.fetchStarts.count
        // The previous sync's teardown lands after the new sync asked for notify-on.
        rig.session.notificationStateChanged(.activityControl, enabled: false, failed: false)
        rig.session.notificationStateChanged(.activityData, enabled: false, failed: false)
        XCTAssertEqual(device.fetchStarts.count, startsBefore, "no start before notify is back on")
        rig.transport.drain()
        XCTAssertGreaterThan(device.fetchStarts.count, startsBefore)
    }
    // MARK: #233: what the strap sends on its own

    /// Setup and sync replies are replies; the strap's own messages are reported with their endpoint and
    /// opcode bytes only, and the sleep events as events.
    func testTheStrapsOwnMessagesAreReportedWithTheirOpcodeOnlyAndRepliesAreNot() async throws {
        let store = try makeStore()
        var events: [HelioSessionEvent] = []
        let rig = connect(makeStrap(), store: store, onEvent: { events.append($0) })
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(events, [.syncStarted], "setup, fetch and battery replies are not the strap talking on its own")
        events = []
        clock = clock.addingTimeInterval(60)
        let device = rig.transport.device
        rig.transport.push(device.unsolicited(endpoint: 0x001D, [0x06, 0x01]))
        rig.transport.push(device.unsolicited(endpoint: 0x0015, [0x03]))
        rig.transport.push(device.unsolicited(endpoint: 0x0016, [0x07, 0x10, 0x27, 0x00, 0x00]))
        rig.transport.push(device.unsolicited(endpoint: 0x0029, [0x04, 0x00, 0x57]))
        rig.transport.push(device.unsolicited(endpoint: 0x001D, [0x06, 0x00]))
        rig.transport.drain()
        XCTAssertEqual(events, [
            .strapMessage(endpoint: 0x001D, opcode: [0x06, 0x01], length: 2), .fellAsleep,
            .strapMessage(endpoint: 0x0015, opcode: [0x03], length: 1),
            .strapMessage(endpoint: 0x0016, opcode: [0x07], length: 5),
            .strapMessage(endpoint: 0x0029, opcode: [0x04], length: 3),
            .strapMessage(endpoint: 0x001D, opcode: [0x06, 0x00], length: 2), .wokeUp,
        ], "a minute after the battery request, a battery message is the strap's own; only opcodes and lengths, never values")
        XCTAssertTrue(rig.session.ready, "nothing the strap sent on its own changed the session")
    }

    /// A reply on an endpoint this session just sent to is not reported; standard heart rate that
    /// nothing asked for is (without its bytes), and the stream this app starts is not.
    func testRepliesAndTheAppsOwnHeartRateStreamAreNotReported() async throws {
        var events: [HelioSessionEvent] = []
        let rig = connect(makeStrap(), store: nil, autoSync: false, onEvent: { events.append($0) })
        XCTAssertEqual(rig.session.phase, .ready)
        let device = rig.transport.device
        rig.transport.push(device.unsolicited(endpoint: 0x0029, [0x04, 0x00, 0x57]))
        rig.transport.drain()
        XCTAssertEqual(events, [], "within the reply window of the setup's battery request")
        clock = clock.addingTimeInterval(60)
        var sent: [ZeppWrite] { rig.transport.writes.filter { $0.characteristic == .chunkedWrite } }
        let writesBefore = sent.count
        rig.transport.push(.heartRateMeasurement, [0x00, 60])
        rig.transport.push(.heartRateMeasurement, [0x00, 60])
        rig.transport.drain()
        XCTAssertEqual(events, [.strapNotification(.heartRateMeasurement), .strapNotification(.heartRateMeasurement)])
        // §16.5's fail-safe, once: `04 00` on 0x001D and unsubscribe; nothing shown.
        XCTAssertEqual(sent.count, writesBefore + 1)
        XCTAssertEqual(device.receivedEndpoints.last, 0x001D)
        XCTAssertEqual(Array(sent.last?.bytes.suffix(2) ?? []), [0x04, 0x00])
        XCTAssertEqual(rig.transport.notifyChanges.last?.0, .heartRateMeasurement)
        XCTAssertEqual(rig.transport.notifyChanges.last?.1, false)
        XCTAssertNil(rig.session.liveHR, "an unasked frame isn't shown")
        events = []
        rig.session.startLiveHeartRate()
        rig.transport.push(.heartRateMeasurement, [0x00, 61])
        rig.transport.drain()
        XCTAssertEqual(events, [], "the stream the app started")
        XCTAssertEqual(rig.session.liveHR, 61)
    }

    /// §16.5's dispatch: the ping is answered `04`; an MTU announce sets the chunk size (the smaller of
    /// it and CoreBluetooth's); realtime steps flowing unasked get `05 00` once (never `05 01`); an
    /// unknown endpoint or opcode gets no reply at all.
    func testTheStrapsOwnMessagesGetOnlyTheRepliesSection16Allows() async throws {
        let strap = makeStrap()
        strap.services.append((0x0015, 0))   // the real strap lists the connection endpoint plaintext (§3.5)
        let rig = connect(strap, store: nil, autoSync: false)
        XCTAssertEqual(rig.session.phase, .ready)
        let device = rig.transport.device
        // Messages to the strap (on `…0016`); chunk acks on `…0017` are the transport's and allowed.
        var sent: [ZeppWrite] { rig.transport.writes.filter { $0.characteristic == .chunkedWrite } }
        clock = clock.addingTimeInterval(60)

        var writes = sent.count
        rig.transport.push(device.unsolicited(endpoint: 0x0015, [0x03]))
        rig.transport.drain()
        XCTAssertEqual(sent.count, writes + 1)
        XCTAssertEqual(device.receivedEndpoints.last, 0x0015)
        XCTAssertEqual(sent.last?.bytes.last, 0x04, "the ping's answer")

        XCTAssertEqual(rig.session.chunkWriteLength, 244)
        writes = sent.count
        rig.transport.push(device.unsolicited(endpoint: 0x0015, [0x02, 0x64, 0x00]))   // MTU − 3 = 100
        rig.transport.drain()
        XCTAssertEqual(rig.session.chunkWriteLength, 100)
        rig.transport.push(device.unsolicited(endpoint: 0x0015, [0x02, 0xf4, 0x01]))   // 500: CoreBluetooth's 244 wins
        rig.transport.drain()
        XCTAssertEqual(rig.session.chunkWriteLength, 244)
        XCTAssertEqual(sent.count, writes, "an MTU announce gets no reply")

        rig.transport.push(device.unsolicited(endpoint: 0x0016, [0x07, 0x10, 0x27, 0x00, 0x00]))
        rig.transport.push(device.unsolicited(endpoint: 0x0016, [0x07, 0x11, 0x27, 0x00, 0x00]))
        rig.transport.drain()
        XCTAssertEqual(sent.count, writes + 1, "05 00 once")
        XCTAssertEqual(device.receivedEndpoints.last, 0x0016)
        XCTAssertEqual(Array(sent.last?.bytes.suffix(2) ?? []), [0x05, 0x00])
        XCTAssertFalse(sent.contains { Array($0.bytes.suffix(2)) == [0x05, 0x01] }, "never 05 01")

        writes = sent.count
        rig.transport.push(device.unsolicited(endpoint: 0x0031, [0x07, 1, 2, 3]))
        rig.transport.push(device.unsolicited(endpoint: 0x001D, [0x06, 0x07]))
        rig.transport.push(device.unsolicited(endpoint: 0x0019, [0x11, 0x01]))
        rig.transport.drain()
        XCTAssertEqual(sent.count, writes, "nothing is sent back for an unknown or workout message")
        XCTAssertTrue(rig.session.ready)
    }

    /// §16.1/§16.5: `…0017` is subscribed before auth and stays on; `…0016`, subscribed for auth, is
    /// turned off once auth is done. A fresh connection re-runs auth with a fresh session.
    func testOnlyTheChunkedReadSubscriptionOutlivesAuth() async throws {
        let rig = connect(makeStrap(), store: nil, autoSync: false)
        XCTAssertEqual(rig.session.phase, .ready)
        let changes = rig.transport.notifyChanges.filter { $0.0 == .chunkedRead || $0.0 == .chunkedWrite }
        let lines = changes.map { "\($0.0.rawValue) \($0.1)" }
        XCTAssertEqual(Set(lines.prefix(2)), ["chunkedRead true", "chunkedWrite true"], "both subscribed for auth")
        XCTAssertEqual(Array(lines.dropFirst(2)), ["chunkedWrite false"], "only …0016 is turned off; …0017 stays on")
        let again = connect(makeStrap(), store: nil, autoSync: false)
        XCTAssertEqual(again.session.phase, .ready)
        XCTAssertTrue(again.transport.device.authenticated, "auth re-run on the new connection")
    }

    /// §16.5: nothing is subscribed for display in the background. A keyless session started in the
    /// background doesn't listen for standard heart rate until the app is in front.
    func testAKeylessSessionListensForHeartRateOnlyInFront() async throws {
        let transport = FakeStrapTransport(device: makeStrap())
        let session = HelioSession(transport: transport, identityID: strapID, key: nil, keyStore: MemoryKeyStore(nil),
                                   sink: nil, findState: HelioFindState(), clock: { [unowned self] in self.clock },
                                   autoTick: false)
        transport.session = session
        session.appInBackground = true
        session.start()
        transport.drain()
        XCTAssertEqual(session.phase, .keyless)
        XCTAssertFalse(transport.notifyChanges.contains { $0.0 == .heartRateMeasurement })
        session.appDidBecomeActive()
        XCTAssertEqual(transport.notifyChanges.last?.0, .heartRateMeasurement)
        XCTAssertEqual(transport.notifyChanges.last?.1, true)
        session.appDidEnterBackground()
        XCTAssertEqual(transport.notifyChanges.last?.1, false)
    }

    // MARK: review-236 S1: a strap sync that ends in the background gets its alert pass

    /// The sync ends with the app not active (it started in front, the person left): the connection's
    /// sync-end hook flushes and runs the body-alert pass, once. ContentView's foreground hook, if it
    /// fires for the same sync, finds the pass taken.
    func testASyncThatEndsWithTheAppInactiveGetsExactlyOneAlertPass() async throws {
        let rig = connect(makeStrap(), store: try makeStore())
        let result = try XCTUnwrap(rig.session.lastSyncResult)
        XCTAssertEqual(rig.session.syncsFinished, 1)
        var flushes = 0, passes = 0
        await HelioConnection.syncEnded(result, session: rig.session, appIsActive: false,
                                        flush: { flushes += 1 }, alertPass: { passes += 1 })
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(passes, 1)
        XCTAssertFalse(StrapSyncAlertPass.claim(rig.session), "the foreground hook skips this sync's pass")
        await HelioConnection.syncEnded(result, session: rig.session, appIsActive: false, flush: {}, alertPass: { passes += 1 })
        XCTAssertEqual(passes, 1, "never two for one sync")

        // The next sync on the same session gets its own pass.
        clock = clock.addingTimeInterval(600)
        rig.session.syncHistory(manual: true)
        rig.transport.drain()
        XCTAssertEqual(rig.session.syncsFinished, 2)
        await HelioConnection.syncEnded(try XCTUnwrap(rig.session.lastSyncResult), session: rig.session, appIsActive: false,
                                        flush: {}, alertPass: { passes += 1 })
        XCTAssertEqual(passes, 2)
    }

    /// Ending with the app active: the flush, and no pass from this path (ContentView's hook runs it).
    /// And when the foreground hook got there first, this path adds none.
    func testASyncThatEndsWithTheAppActiveGetsNoPassFromThisPath() async throws {
        let rig = connect(makeStrap(), store: try makeStore())
        let result = try XCTUnwrap(rig.session.lastSyncResult)
        var flushes = 0, passes = 0
        await HelioConnection.syncEnded(result, session: rig.session, appIsActive: true,
                                        flush: { flushes += 1 }, alertPass: { passes += 1 })
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(passes, 0)
        XCTAssertTrue(StrapSyncAlertPass.claim(rig.session), "the foreground hook runs this sync's pass")
        await HelioConnection.syncEnded(result, session: rig.session, appIsActive: false, flush: {}, alertPass: { passes += 1 })
        XCTAssertEqual(passes, 0, "the foreground hook already ran it")
    }

    /// Review-225f SF-1 (its probe P1, kept): a reconnect's new session usually lands at the address of
    /// the one that was freed, with `syncsFinished` back at 0. Its first sync must still get its alert
    /// pass. A claim keyed globally by `ObjectIdentifier` refused it every time; the claim now lives on
    /// the session, so a new one starts unclaimed.
    func testAReconnectsNewSessionIsNeverRefusedItsFirstAlertPass() async throws {
        let store = try makeStore()
        var sameAddress = 0
        for _ in 0..<20 {
            var old: Rig? = connect(makeStrap(), store: store)
            XCTAssertEqual(old?.session.syncsFinished, 1)
            XCTAssertTrue(StrapSyncAlertPass.claim(try XCTUnwrap(old?.session)), "the old session's sync got its pass")
            let oldAddress = ObjectIdentifier(try XCTUnwrap(old?.session))
            old = nil                                    // the link dropped; the session is freed
            for _ in 0..<50 { await Task.yield() }       // its sync-end task lets go of it
            let fresh = connect(makeStrap(), store: store)
            XCTAssertEqual(fresh.session.syncsFinished, 1)
            if ObjectIdentifier(fresh.session) == oldAddress { sameAddress += 1 }
            XCTAssertNil(fresh.session.alertPassClaimedSync, "a new session starts unclaimed")
            XCTAssertTrue(StrapSyncAlertPass.claim(fresh.session), "the new session's first sync gets its pass")
            XCTAssertFalse(StrapSyncAlertPass.claim(fresh.session), "and only one")
        }
        print("review-225f SF-1 test: new session at the freed address \(sameAddress)/20")
    }

    /// A sync a background run owns: nothing from this path; the run flushes and runs its own passes.
    func testASyncABackgroundRunOwnsGetsNothingFromThisPath() async throws {
        let rig = connect(makeStrap(), store: try makeStore())
        var result = try XCTUnwrap(rig.session.lastSyncResult)
        result.endedInBackgroundRun = true
        var flushes = 0, passes = 0
        for active in [false, true] {
            await HelioConnection.syncEnded(result, session: rig.session, appIsActive: active,
                                            flush: { flushes += 1 }, alertPass: { passes += 1 })
        }
        XCTAssertEqual(flushes, 0)
        XCTAssertEqual(passes, 0)
    }

    // MARK: review-225e SF-1: opening the app syncs a session that came up in the background

    /// Review-225e P2, as the regression test: a session made while the app was in the background
    /// (`autoSyncOnConnect: false`) is ready and idle; the app comes to the front → exactly one sync.
    func testABackgroundMadeSessionSyncsOnceWhenTheAppComesToTheFront() throws {
        let rig = connect(makeStrap(), store: try makeStore(), autoSync: false)
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.syncsFinished, 0)
        var gate = HelioActivationSync()
        HelioConnection.becameActive(rig.session, gate: &gate, lastCompletedSync: nil, now: clock)
        XCTAssertTrue(rig.session.syncing)
        rig.transport.drain()
        XCTAssertEqual(rig.session.syncsFinished, 1, "exactly one sync")
        XCTAssertEqual(rig.session.phase, .ready)
    }

    /// The last completed strap sync is 2 min old: no sync (the ring's 300 s throttle, one constant).
    func testNoActivationSyncWithinTheForegroundIntervalOfTheLastSync() throws {
        let rig = connect(makeStrap(), store: try makeStore(), autoSync: false)
        var gate = HelioActivationSync()
        HelioConnection.becameActive(rig.session, gate: &gate, lastCompletedSync: clock.addingTimeInterval(-120), now: clock)
        rig.transport.drain()
        XCTAssertEqual(rig.session.syncsFinished, 0)
        XCTAssertEqual(ForegroundAutoSync.interval, 300)
        HelioConnection.becameActive(rig.session, gate: &gate, lastCompletedSync: clock.addingTimeInterval(-300),
                                     now: clock)
        rig.transport.drain()
        XCTAssertEqual(rig.session.syncsFinished, 1, "at the interval, it syncs")
    }

    /// Control Center or a banner flapping `.inactive`/`.active`: two activations 1 s apart give one
    /// sync, whether the first is still running or already done.
    func testTwoActivationsOneSecondApartGiveOneSync() throws {
        for finishFirst in [false, true] {
            let rig = connect(makeStrap(), store: try makeStore(), autoSync: false)
            var gate = HelioActivationSync()
            HelioConnection.becameActive(rig.session, gate: &gate, lastCompletedSync: nil, now: clock)
            if finishFirst { rig.transport.drain() }
            HelioConnection.becameActive(rig.session, gate: &gate, lastCompletedSync: nil, now: clock.addingTimeInterval(1))
            rig.transport.drain()
            XCTAssertEqual(rig.session.syncsFinished, 1)
        }
    }

    /// A session that is syncing, finding, or streaming live heart rate gets no new sync on activation.
    func testNoActivationSyncWhileTheSessionIsBusy() throws {
        let syncing = connect(makeStrap(), store: try makeStore(), autoSync: false)
        syncing.session.syncHistory(manual: true)
        syncing.transport.drainSteps(2)
        XCTAssertTrue(syncing.session.syncing)
        var gate = HelioActivationSync()
        HelioConnection.becameActive(syncing.session, gate: &gate, lastCompletedSync: nil, now: clock)
        XCTAssertNil(gate.lastStarted, "nothing started")
        syncing.transport.drain()
        XCTAssertEqual(syncing.session.syncsFinished, 1, "only the sync already running")

        let finding = connect(makeStrap(), store: try makeStore(), autoSync: false)
        XCTAssertNil(finding.session.startFind())
        finding.transport.drain()
        XCTAssertTrue(finding.session.isFinding)
        var findGate = HelioActivationSync()
        HelioConnection.becameActive(finding.session, gate: &findGate, lastCompletedSync: nil, now: clock)
        XCTAssertFalse(finding.session.syncing)

        let live = connect(makeStrap(), store: try makeStore(), autoSync: false)
        live.session.startLiveHeartRate()
        XCTAssertTrue(live.session.liveHeartRateRunning)
        var liveGate = HelioActivationSync()
        HelioConnection.becameActive(live.session, gate: &liveGate, lastCompletedSync: nil, now: clock)
        XCTAssertFalse(live.session.syncing)
    }

    /// With review-236 S1's path: an activation sync, the app goes to the background mid-sync, the sync
    /// ends there → exactly one alert pass (the sync-end hook's), and ContentView's hook adds none.
    func testAnActivationSyncThatEndsInTheBackgroundGetsExactlyOneAlertPass() async throws {
        var results: [HelioSyncResult] = []
        let rig = connect(makeStrap(), store: try makeStore(), autoSync: false, finished: { results.append($0) })
        var gate = HelioActivationSync()
        HelioConnection.becameActive(rig.session, gate: &gate, lastCompletedSync: nil, now: clock)
        rig.transport.drainSteps(3)
        XCTAssertTrue(rig.session.syncing, "the app leaves here, mid-sync")
        rig.transport.drain()
        for _ in 0..<200 where results.isEmpty { await Task.yield() }
        let result = try XCTUnwrap(results.last)
        var passes = 0
        await HelioConnection.syncEnded(result, session: rig.session, appIsActive: false, flush: {}, alertPass: { passes += 1 })
        XCTAssertFalse(StrapSyncAlertPass.claim(rig.session), "ContentView's hook, if it fires later, skips it")
        XCTAssertEqual(passes, 1)
    }

    // MARK: review-225e SF-2: an expiry's teardown ends the fetch

    /// Review-225e P1, as the regression test: with a round open, the teardown acks `03 09` and the
    /// session no longer reads "syncing", so nothing defers the link cancel.
    func testTheExpiryTeardownAcksTheOpenRoundAndEndsTheSync() throws {
        let store = try makeStore()
        var probed = false
        for steps in 1...400 {
            let device = makeStrap()
            let rig = connect(device, store: store, autoSync: false)
            rig.session.syncHistory(manual: false)
            rig.transport.drainSteps(steps)
            guard rig.session.syncing else { continue }
            let acksBefore = device.fetchAcks.count
            rig.session.stopSyncForTeardown()
            guard device.fetchAcks.count > acksBefore else { continue }   // no round was open yet
            probed = true
            XCTAssertEqual(device.fetchAcks.last, 0x09, "keep on the strap")
            XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count, "the open round is acked")
            XCTAssertFalse(rig.session.syncing)
            XCTAssertEqual(rig.session.lastSyncResult?.interrupted, true)
            XCTAssertEqual(rig.session.syncsFinished, 1)
            break
        }
        XCTAssertTrue(probed, "found a step count with a round open")
    }
}

// MARK: - Key store, device choice

@MainActor
final class HelioKeyStoreTests: XCTestCase {
    private let suite = "test.HelioKeyStoreTests"
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
        super.tearDown()
    }

    func testTheKeychainRoundTripsAndForgets() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = HelioKeyStore(service: "com.standardsoftwaresolutions.opencircuit.tests.helio", account: "t", defaults: defaults)
        store.forget()
        // An unsigned test host (`CODE_SIGNING_ALLOWED=NO`) has no keychain entitlement, so every
        // SecItem call fails with errSecMissingEntitlement (-34018). That is the harness, not the
        // store: skip rather than fail. Any other status is a real failure.
        do {
            _ = try store.save(pasted: keyHex)
        } catch HelioKeyStoreError.keychain(let status) where status == -34018 {
            throw XCTSkip("Keychain unavailable in an unsigned test host (errSecMissingEntitlement)")
        }
        store.forget()
        XCTAssertNil(store.load())
        XCTAssertFalse(try store.save(pasted: "not a key"))
        XCTAssertNil(store.load(), "an invalid paste saves nothing")
        XCTAssertTrue(try store.save(pasted: "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"))
        XCTAssertEqual(store.load(), HelioKeyText.parse(keyHex))
        store.markRejected()
        XCTAssertTrue(store.isRejected)
        XCTAssertTrue(try store.save(pasted: keyHex))
        XCTAssertFalse(store.isRejected, "a replaced key starts fresh")
        store.forget()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.isRejected)
    }

    func testTheSavedKeyNeverAppearsInADescription() throws {
        let key = try XCTUnwrap(HelioKeyText.parse(keyHex))
        XCTAssertFalse(String(describing: key).contains("0011"))
        XCTAssertFalse(String(reflecting: key).contains("0011"))
    }

    func testTheRingIsTheDefaultDevice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(ActiveDeviceChoiceStore.persisted(defaults), .ringConn, "an existing ring user sees no change")
        let store = ActiveDeviceChoiceStore(defaults: defaults)
        XCTAssertTrue(store.isRing)
        store.set(.helioStrap)
        XCTAssertEqual(ActiveDeviceChoiceStore.persisted(defaults), .helioStrap)
        XCTAssertTrue(ActiveDeviceChoiceStore(defaults: defaults).isHelio)
    }

    func testTheStrapsStepsLandAsMinuteDeltasOnceOnly() throws {
        let container = try ModelContainer(for: StoredSample.self, StoredCursor.self, StoredDaily.self, StoredStepSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LocalStore(container.mainContext)
        let device = SyncDeviceID(rawValue: "zeppos:test")
        let t0 = Date(timeIntervalSince1970: midnight + 8 * 3600)
        let minutes = (0..<3).map { QuantitySample(kind: .steps, start: t0.addingTimeInterval(Double($0) * 60),
                                                   end: t0.addingTimeInterval(Double($0 + 1) * 60), value: 10) }
        XCTAssertEqual(try store.ingestHelioStepMinutes(minutes, device: device, now: testNow), 3)
        XCTAssertEqual(try store.ingestHelioStepMinutes(minutes, device: device, now: testNow), 0, "re-delivered minutes are skipped")
        XCTAssertEqual(try store.todaySteps(day: t0), 30)
        let pending = try store.pendingStepSamples()
        XCTAssertEqual(pending.map(\.delta), [10, 10, 10])
        XCTAssertEqual(pending.map { $0.end.timeIntervalSince($0.start) }, [60, 60, 60], "each over its real minute")
        withExtendedLifetime(container) {}
    }
}

// MARK: - Key states and Health attribution

@MainActor
final class HelioStatusTests: XCTestCase {

    func testTheKeyStatesOfDecisionSeven() {
        func status(_ state: HelioConnection.State, _ phase: HelioSession.Phase?, key: Bool = true,
                    rejected: Bool = false, saved: Bool = true) -> HelioStatus.Kind {
            HelioStatus.from(connection: state, phase: phase, hasKey: key, keyRejected: rejected, hasSavedStrap: saved).kind
        }
        XCTAssertEqual(status(.idle, nil, key: false, saved: false), .notSetUp)
        XCTAssertEqual(status(.idle, nil, key: false), .keyNeeded)
        XCTAssertEqual(status(.idle, nil, rejected: true), .keyRejected)
        XCTAssertEqual(status(.connected, .keyless, key: false), .keyNeeded)
        XCTAssertEqual(status(.connected, .keyRejected), .keyRejected)
        XCTAssertEqual(status(.connected, .strapBusy), .strapBusy)
        XCTAssertEqual(status(.connected, .syncing), .syncing)
        XCTAssertEqual(status(.connected, .ready), .ready)
        XCTAssertEqual(status(.searching, nil), .searching)
        XCTAssertEqual(status(.bluetoothOff, .ready), .bluetoothOff)
    }

    func testTheNoSkinTemperatureNoteNamesTheNightsOwnDevice() {
        // Review-225 N2: the ring's reason comes back for ring nights (every ring-only install);
        // a strap night gets the strap's own reason.
        XCTAssertEqual(SleepCardView.noSkinTempNote(nightOwner: .ringConn),
                       "No skin temperature for this night — it's only recorded while the ring stays connected, and there weren't enough readings to compare.")
        let strap = SleepCardView.noSkinTempNote(nightOwner: .zeppOS)
        XCTAssertTrue(strap.contains("strap"))
        XCTAssertNil(strap.range(of: "\\bring\\b", options: .regularExpression), "no ring wording for a strap night")
    }

    func testTheZeppCoexistenceCopyIsVerbatim() {
        XCTAssertEqual(HelioStatus.dontUnpairCopy,
                       "Don't unpair the strap in the Zepp app; unpairing makes the key stop working.")
        XCTAssertEqual(HelioStatus.zeppBluetoothCopy,
                       "To let OpenCircuit connect, turn off Bluetooth for Zepp (Settings ▸ Zepp ▸ Bluetooth) or delete the Zepp app.")
        let busy = HelioStatus.from(connection: .connected, phase: .strapBusy, hasKey: true, keyRejected: false, hasSavedStrap: true)
        XCTAssertTrue(busy.detail?.contains(HelioStatus.zeppBluetoothCopy) == true)
        XCTAssertTrue(HelioStatus.keyGuideURL.absoluteString.hasSuffix("docs/HELIO_KEY_EXTRACTION.md"))
    }

    func testHealthWritesNameTheStrapWhenItIsTheActiveDevice() throws {
        let suite = "test.HelioStatusTests.identity"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let device = makeStrap()
        let transport = FakeStrapTransport(device: device)
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000B2",
                                   key: HelioKeyText.parse(keyHex), keyStore: MemoryKeyStore(keyHex), sink: nil,
                                   findState: HelioFindState(), clock: { testNow }, autoTick: false, autoSyncOnConnect: false)
        transport.session = session
        session.start()
        transport.drain()
        let active = ActiveWearable(session: { session }, fallbackDeviceID: { nil },
                                    identityStore: WearableIdentityStore(defaults))
        let fields = try XCTUnwrap(HealthDeviceAttribution.fields(for: active.identityForHealthWrite(), origin: .device))
        XCTAssertEqual(fields.name, "Helio Strap")
        XCTAssertEqual(fields.manufacturer, "Amazfit")
        XCTAssertEqual(fields.hardwareVersion, "9.9.9.9")
        XCTAssertEqual(fields.firmwareVersion, "1.2.3.4",
                       "the first-write guard needs a firmware version: it is read before the first sync")
        XCTAssertEqual(fields.localIdentifier, "zeppos:5B1E4C2A-0000-4000-8000-0000000000B2")
        XCTAssertTrue(active.capabilities.contains(.historySync))
    }
}

// MARK: - Background sync (#215 phase 4)

/// `HelioBackgroundLink` over the simulated strap: what `HelioConnection` does for a background run,
/// minus CoreBluetooth. A connect builds a session over a `FakeStrapTransport`; events reach it only
/// when the test's `pause` drains them, as CoreBluetooth hands them over on later run-loop turns.
@MainActor
private final class FakeBackgroundLink: HelioBackgroundLink {
    let device: FakeZeppDevice
    let keyStore: MemoryKeyStore
    let store: LocalStore?
    let findState = HelioFindState()
    let clock: () -> Date
    var strapID: String? = "5B1E4C2A-0000-4000-8000-0000000000C3"
    /// false: a connect is armed but never completes (the strap is out of range).
    var inRange = true
    /// The strap never answers (another phone holds it).
    var silent = false
    /// Decision 78d: when the link ended busy (the fake's clock), nil when it didn't.
    var endedBusyAt: Date?
    /// Set from a test: busy now, or cleared (what a new launch used to do).
    var endedBusy: Bool {
        get { endedBusyAt != nil }
        set { endedBusyAt = newValue ? clock() : nil }
    }
    private(set) var busyClears = 0
    func clearBusyLatch() {
        busyClears += 1
        endedBusyAt = nil
    }
    var activeBackgroundRuns = 0
    var backgroundRunAdoptsNewSessions = false
    var pendingNightsFinalization: Date?
    var activeRun: HelioActiveRun?
    var handOver: HelioHandOver?
    private(set) var session: HelioSession?
    private(set) var transport: FakeStrapTransport?
    private(set) var connects = 0
    private(set) var disconnects = 0
    /// Standing connects armed again after a run's teardown (decision 33).
    private(set) var rearms = 0
    private(set) var runStarts: [Date] = []
    /// Where the sessions' events go (the app's `HelioConnection.handle`).
    var onEvent: (@MainActor (HelioSessionEvent) -> Void)?
    /// Flushes `HelioConnection`'s own post-sync hook would run: syncs no background run owns.
    private(set) var hookFlushes = 0
    /// Whether each of those hook flushes would skip the nights' margin: decision 31's check of the
    /// Focus end it carries, at the moment the flush starts (`SleepFocusFinalization`), in order.
    private(set) var hookFinalized: [Bool] = []
    /// What that hook's flush does, when a test needs it to write (`GuardedHealthWriter`).
    var hookAction: (@MainActor (HelioSyncResult) async -> Void)?

    init(device: FakeZeppDevice, keyStore: MemoryKeyStore, store: LocalStore?, clock: @escaping () -> Date) {
        self.device = device
        self.keyStore = keyStore
        self.store = store
        self.clock = clock
    }

    var strapTimeline: SyncDeviceID? {
        strapID.map { SyncDeviceID.timeline(for: .zeppOS(model: HelioSession.displayName), identityID: $0) }
    }

    func connectForBackground() -> Bool {
        connects += 1
        guard let strapID else { return false }
        guard inRange else { return true }
        let transport = FakeStrapTransport(device: device)
        transport.silent = silent
        let session = HelioSession(transport: transport, identityID: strapID, key: keyStore.load(), keyStore: keyStore,
                                   sink: store.map { HelioStoreSink(store: $0) }, findState: findState,
                                   onSyncFinished: { [weak self] result, _ in
                                       guard let self, !result.endedInBackgroundRun else { return }
                                       self.hookFlushes += 1
                                       self.hookFinalized.append(SleepFocusFinalization.applies(
                                           focusEndedAt: result.nightsFinalized, flushStartsAt: self.clock()))
                                       await self.hookAction?(result)
                                   },
                                   onEvent: { [weak self] event in self?.onEvent?(event) },
                                   clock: clock, autoTick: false)
        session.backgroundRunOwnsSyncs = backgroundRunAdoptsNewSessions
        transport.session = session
        self.transport = transport
        self.session = session
        session.start()
        return true
    }

    /// What each disconnect saw: asked to cancel now, whether the session still read "syncing" (which
    /// makes `HelioConnection.disconnect` defer its cancel 500 ms unless `cancelNow`), and how many
    /// transport writes had been queued before the cancel.
    private(set) var cancels: [(cancelNow: Bool, sessionSyncing: Bool, writesBefore: Int)] = []
    /// The transport of the link that was cancelled last (its writes, for ordering checks).
    private(set) var cancelledTransport: FakeStrapTransport?

    func disconnectForBackground(cancelNow: Bool) {
        disconnects += 1
        cancels.append((cancelNow, session?.syncing == true, transport?.writes.count ?? 0))
        cancelledTransport = transport
        if session?.phase == .strapBusy { endedBusy = true }
        session?.stopFind()
        session?.abortSync()
        session?.linkLost()
        session = nil
        transport = nil
    }

    func rearmAfterTeardown() { rearms += 1 }

    /// Where the run starts go for the wake rules (`HelioConnection` persists them the same way).
    var wakeState: HelioWakeState?

    func noteBackgroundRunStarted(at date: Date) {
        runStarts.append(date)
        wakeState?.lastBackgroundRunStart = date
    }
}

/// The Health writer's flush contract, over the real store (HealthKit itself is unavailable in the
/// simulator): one flush at a time, like `HealthKitWriter.flushToHealth`'s static `isFlushing` guard,
/// which makes an overlapping call return empty without touching anything; and the watermark is
/// advanced (`markHealthWritten`) only for what the save wrote, after it.
@MainActor
private final class GuardedHealthWriter {
    let store: LocalStore
    private(set) var isFlushing = false
    private(set) var written: [QuantitySample] = []
    private(set) var emptyBecauseBusy = 0
    /// Runs once, inside the next save's await (where another flush can start).
    var duringNextSave: (@MainActor () async -> Void)?

    init(store: LocalStore) { self.store = store }

    @discardableResult
    func flush(_ timeline: SyncDeviceID) async -> Int {
        guard !isFlushing else { emptyBecauseBusy += 1; return 0 }
        isFlushing = true
        defer { isFlushing = false }
        guard let pending = try? store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds()),
              !pending.isEmpty else { return 0 }
        if let step = duringNextSave {
            duringNextSave = nil
            await step()
        }
        written += pending
        try? store.markHealthWritten(pending, device: timeline)
        return pending.count
    }
}

@MainActor
final class HelioBackgroundSyncTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = testNow
    private var defaults: UserDefaults!
    private let suite = "test.HelioBackgroundSyncTests"
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        ownership.install(.strapOwnsAllTime)   // a strap-only install (decision 28's first entry)
    }

    override func tearDown() {
        ownership.restore()
        defaults.removePersistentDomain(forName: suite)
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private func rows(_ store: LocalStore) throws -> [String] {
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "\($0.deviceID) \($0.kindRaw) \($0.start.timeIntervalSince1970) \($0.value)" }
        let steps = try store.context.fetch(FetchDescriptor<StoredStepSample>(sortBy: [SortDescriptor(\.start)]))
            .map { "step \($0.start.timeIntervalSince1970) \($0.end.timeIntervalSince1970) \($0.delta)" }
        let dailies = try store.context.fetch(FetchDescriptor<StoredDaily>()).map { "daily \($0.day.timeIntervalSince1970) \($0.steps)" }
        let nights = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            .map { "night \($0.night.timeIntervalSince1970) asleep \($0.asleepMin) deep \($0.deepMin) rem \($0.remMin) temp \($0.skinTempC)" }
        return (samples + steps + dailies + nights).sorted()
    }

    /// What the service handed to Apple Health.
    private struct FlushCall {
        let timeline: SyncDeviceID
        let nights: Int
        let identity: WearableIdentity?
        /// The Sleep Focus end the flush received (decision 31's T), if any.
        let focusEndedAt: Date?
        /// Whether the flush would skip the nights' margin: decision 31's check of `focusEndedAt` at the
        /// moment the flush starts, the same check `HelioConnection.healthFlush` makes.
        let finalized: Bool
        let rowsAtFlush: Int
        /// Syncs finished on the link's session when the flush ran: which sync it flushed.
        let syncAtFlush: Int
    }

    /// The service over `link`. `pause` moves the simulated strap along (default: deliver everything
    /// queued, one second passes); the Health pass is recorded instead of written.
    private func service(_ link: FakeBackgroundLink, store: LocalStore, flushes: @escaping (FlushCall) -> Void = { _ in },
                         appIsActive: Bool = false,
                         pause: (@MainActor () -> Void)? = nil) -> HelioBackgroundSyncService {
        HelioBackgroundSyncService(
            link: link, keyStore: link.keyStore, observability: ObservabilityStore(defaults),
            flush: { [unowned self] timeline, nights, identity, focusEndedAt in
                let count = (try? self.rows(store).count) ?? 0
                let finalized = SleepFocusFinalization.applies(focusEndedAt: focusEndedAt, flushStartsAt: self.clock)
                flushes(FlushCall(timeline: timeline, nights: nights.count, identity: identity, focusEndedAt: focusEndedAt,
                                  finalized: finalized, rowsAtFlush: count, syncAtFlush: link.session?.syncsFinished ?? 0))
                var result = HealthKitWriter.FlushResult()
                result.samples = count
                return result
            },
            now: { [unowned self] in self.clock },
            pause: { [unowned self] in
                if let pause { pause() } else { link.transport?.drain() }
                self.clock = self.clock.addingTimeInterval(1)
                link.session?.tick(now: self.clock)
                await Task.yield()
            },
            grace: { link.transport?.drain() },
            appIsActive: { appIsActive })
    }

    private func lastRecord() -> TaskRecord? { ObservabilityStore(defaults).records().last }

    // MARK: a background run with the strap chosen: drain → store → Health → run log

    func testABackgroundRunDrainsTheStrapStoresRowsFlushesHealthAndLogsIt() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)

        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(run.result?.interrupted, false)
        XCTAssertTrue(run.success)
        XCTAssertEqual(link.connects, 1, "connect by identifier once")
        XCTAssertEqual(link.disconnects, 0, "a finished run leaves the idle link up")
        XCTAssertTrue(device.authenticated)
        XCTAssertEqual(device.timeSetCount, 1, "decision 9: the clock is set on the background connection too")
        XCTAssertEqual(Set(device.fetchAcks), [0x09], "decision 8: keep-on-strap for every round")
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)

        // Rows on the strap's timeline, as a foreground sync stores them.
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertTrue(samples.allSatisfy { $0.deviceID == "zeppos:5B1E4C2A-0000-4000-8000-0000000000C3" })
        XCTAssertEqual(samples.filter { $0.kindRaw == "heartRate" }.count, 50)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).count, 1)

        // Health: one flush, after the rows were committed, with the night; not finalized (BGTask).
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(flushes.first?.timeline, link.strapTimeline)
        XCTAssertEqual(flushes.first?.nights, 1)
        XCTAssertEqual(flushes.first?.finalized, false)
        XCTAssertEqual(flushes.first?.rowsAtFlush, try rows(store).count)
        XCTAssertNotNil(run.flushMS)

        // The run log: the ring's background log, labelled for the strap.
        let record = try XCTUnwrap(lastRecord())
        XCTAssertEqual(record.kind, .appRefresh)
        XCTAssertTrue(record.success)
        XCTAssertTrue(record.detail?.hasPrefix("helio strap: synced") == true, record.detail ?? "")
        XCTAssertTrue(ObservabilityStore(defaults).metricRecords().contains {
            $0.source == "bgphase" && $0.detail.hasPrefix("device=helio kind=appRefresh ending=synced")
        })
        XCTAssertNotNil(ObservabilityStore(defaults).bgLastRun)
        // One sync end: ContentView's sync-end passes (`HelioSyncEndStep`, reminders included) key on
        // the session's `syncing` going false, so they run once; the connection's own Health hook
        // skipped this sync because the run owned and flushed it (one flush, above).
        XCTAssertEqual(link.session?.syncsFinished, 1)
        XCTAssertEqual(link.hookFlushes, 0)
        // The session is handed back: a later foreground sync on it flushes by itself again.
        XCTAssertEqual(link.session?.backgroundRunOwnsSyncs, false)
        XCTAssertEqual(link.activeBackgroundRuns, 0)
    }

    func testTheSleepFocusRunFinalizesTheStrapsNights() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: self.clock)
        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [true])
        XCTAssertEqual(lastRecord()?.kind, .sleepFocus)
    }

    func testAnAlreadyConnectedStrapIsSyncedWithoutReconnecting() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        // A foreground connection that already synced and stayed up.
        _ = link.connectForBackground()
        link.transport?.drain()
        XCTAssertEqual(link.session?.syncsFinished, 1)
        let startsBefore = device.fetchStarts.count

        let run = await service(link, store: store).run(kind: .processing, timeout: RingBackgroundSyncService.processingTimeout)
        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(link.connects, 1, "no second connect")
        XCTAssertEqual(link.session?.syncsFinished, 2, "a fresh sync on the open link")
        XCTAssertGreaterThan(device.fetchStarts.count, startsBefore)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    /// Review-240 S1: a background run (#225) that adopts the live session while a settings change's
    /// pre-read is in flight. The run syncs as usual; the write never goes out during its fetch.
    func testABackgroundRunThatStartsMidChangeRefusesTheWriteAndSyncsNormally() async throws {
        let store = try makeStore()
        let device = makeStrap()
        // HEALTH v3 with constraints: stress monitoring on (made up).
        device.configReadHandler = { request in
            guard request.count >= 4, request[0] == 0x03, request[1] == 0x01, request[2] == 0x08 else { return nil }
            return [0x04, 0x01, 0x08, 0x03, 0x01, 0x01, 0x13, 0x0b, 0x01]
        }
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        _ = link.connectForBackground()
        link.transport?.drain()
        let session = try XCTUnwrap(link.session)
        XCTAssertEqual(session.phase, .ready)
        session.readStrapSettings(groups: [ZeppConfig.healthGroup])
        link.transport?.drain()
        // The tap: allowed now. Its pre-read reply is still queued when the run starts.
        XCTAssertNil(session.changeStrapSetting(.stressMonitoring, from: .bool(true), to: .bool(false)))

        let run = await service(link, store: store).run(kind: .processing, timeout: RingBackgroundSyncService.processingTimeout)
        XCTAssertEqual(run.ending, .synced, "the run itself syncs normally")
        XCTAssertEqual(session.syncsFinished, 2)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertEqual(device.configWrites, [], "no config write during the run's fetch")
        XCTAssertEqual(session.settingsNotice?.text, "Not saved: a sync started. Try again when it finishes.")
        XCTAssertEqual(session.settingsEditor?.isBusy, false)
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.stressMonitoring), .bool(true), "the strap's value stays shown")
    }

    // MARK: decision 28: the background run fetches and keeps only the strap's own time

    func testABackgroundRunStoresAndOffersHealthOnlyTheTimeTheStrapOwns() async throws {
        // The person switched to the strap at 23:30; before that the ring owned the time. The fake
        // strap still offers everything from 23:00 (activity, temperature, the night's session).
        let switchedAt = Date(timeIntervalSince1970: midnight - 1800)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchedAt)]))
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .synced)

        // The fetch never asks for anything before the switch: the foreground's own `notBefore` bound.
        XCTAssertFalse(device.fetchStarts.isEmpty)
        for start in device.fetchStarts {
            let since = try XCTUnwrap(ZeppFetchTimestamp.decode(start[2..<10]))
            XCTAssertGreaterThanOrEqual(since, switchedAt, "type 0x\(String(format: "%02x", start[1]))")
        }
        XCTAssertEqual(Set(device.fetchAcks), [0x09], "decision 8: what the strap delivered from before stays on it")
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)

        // Stored: only the strap's time. 23:30–23:59 of activity carries heart rate and steps.
        let timeline = try XCTUnwrap(link.strapTimeline)
        let samples = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.start >= switchedAt })
        XCTAssertEqual(samples.filter { $0.kindRaw == "heartRate" }.count, 30)
        let steps = try store.context.fetch(FetchDescriptor<StoredStepSample>())
        XCTAssertEqual(steps.count, 30)
        XCTAssertTrue(steps.allSatisfy { $0.start >= switchedAt })

        // Pending for Apple Health: the same, nothing from the ring's time.
        let pending = try store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds())
        XCTAssertFalse(pending.isEmpty)
        XCTAssertTrue(pending.allSatisfy { $0.start >= switchedAt })
        XCTAssertTrue(try store.pendingStepSamples().allSatisfy { $0.start >= switchedAt })

        // The flush is the shared one, for the strap's timeline and with the strap's own identity
        // (attribution from the row, not from the current choice).
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(flushes.first?.timeline, timeline)
        XCTAssertEqual(flushes.first?.identity?.id, "5B1E4C2A-0000-4000-8000-0000000000C3")
        XCTAssertEqual(flushes.first?.identity?.kind, .zeppOS(model: "Helio Strap"))
    }

    // MARK: expiration mid-round → 03 09, committed rows kept, next run resumes, no duplicates

    func testExpiryMidRoundAcksKeepKeepsCommittedRowsAndTheNextRunResumesWithoutDuplicates() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // One event per pause. iOS expires the task once the sleep-session round (the second type,
        // after activity's two rounds) has asked for its data: activity is committed, that round is open.
        var expired = false
        let operation = Task { @MainActor in
            await service(link, store: store, flushes: { flushes.append($0) }, pause: {
                link.transport?.drainSteps(1)
                let dataRequests = link.transport?.writes.filter { $0.characteristic == .activityControl && $0.bytes == [0x02] }.count ?? 0
                if !expired, dataRequests == 3, link.session?.fetchAcksSent.count == 2 {
                    expired = true
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }).run(kind: .appRefresh, timeout: 3600)
        }
        let run = await operation.value

        XCTAssertTrue(expired, "the test reached the open round")
        XCTAssertEqual(run.ending, .expired)
        XCTAssertFalse(run.success)
        XCTAssertEqual(link.disconnects, 1, "disconnected cleanly")
        XCTAssertNil(link.session)
        XCTAssertEqual(device.fetchStarts.count, 3)
        XCTAssertEqual(device.fetchAcks, [0x09, 0x09, 0x09], "the open round got its 03 09; nothing was deleted")
        XCTAssertEqual(run.result?.interrupted, true)
        XCTAssertTrue(flushes.isEmpty, "no Health flush once iOS has ended the task")
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: iOS ended the task; open round kept on the strap (03 09), disconnected") == true)

        // What was committed before the expiry stays: activity. The open round's night isn't stored.
        let timeline = try XCTUnwrap(link.strapTimeline)
        let afterFirst = try rows(store)
        XCTAssertTrue(afterFirst.contains { $0.contains(" heartRate ") })
        XCTAssertFalse(afterFirst.contains { $0.hasPrefix("night") })
        XCTAssertFalse(afterFirst.contains { $0.contains(" temperature ") })
        let cursors = store.helioFetchCursors(device: timeline)
        XCTAssertNotNil(cursors[.activity])
        XCTAssertNil(cursors[.sleepSession], "the open round's watermark never moved")

        // The next run resumes from the stored cursors and ends with exactly the rows one clean sync gives.
        clock = clock.addingTimeInterval(600)
        let plan = HelioFetchPlan.plan(cursors: cursors, now: clock)
        let startsBefore = device.fetchStarts.count
        let next = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(next.ending, .synced)
        var firstStarts: [[UInt8]] = []
        for start in device.fetchStarts[startsBefore...] where !firstStarts.contains(where: { $0[1] == start[1] }) {
            firstStarts.append(start)
        }
        XCTAssertEqual(firstStarts, plan.map { ZeppFetchCommand.start($0.type, since: $0.since, timeZone: .current) },
                       "every type's first round starts from its persisted cursor")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])

        let reference = try makeStore()
        let referenceLink = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: reference, clock: { [unowned self] in self.clock })
        _ = await service(referenceLink, store: reference).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(try rows(store), try rows(reference), "no duplicates, nothing missing")
        XCTAssertEqual(flushes.count, 1, "the second run flushed Health")
    }

    func testRunningOutOfBudgetAbandonsTheRoundFlushesWhatWasCommittedAndDisconnects() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // Two events a second: the ~20 s fetch window of an app-refresh task ends mid-sync.
        let run = await service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(2) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .outOfTime)
        XCTAssertEqual(link.disconnects, 1)
        XCTAssertFalse(device.fetchStarts.isEmpty, "the cut came during the fetch")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        // Every round the app saw opened was acked 03 09; a start whose reply hadn't arrived yet opened
        // nothing on the app's side (the strap keeps what it wasn't told to delete, §6.3).
        XCTAssertLessThanOrEqual(device.fetchStarts.count - device.fetchAcks.count, 1)
        XCTAssertEqual(flushes.count, 1, "what was committed still reaches Health inside the reserve")
        XCTAssertEqual(flushes.first?.rowsAtFlush, try rows(store).count)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: out of time") == true)
    }

    func testRunningOutOfBudgetWithTheAppInFrontHandsTheSyncToTheApp() async throws {
        // Review-225 S1: the person opens the app during a background run (the morning Sleep Focus
        // wake). The budget runs out mid-sync; the link and the sync are left to the app.
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) }, appIsActive: true,
                                pause: { link.transport?.drainSteps(2) })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: self.clock)
        XCTAssertEqual(run.ending, .handedToApp)
        XCTAssertFalse(run.success)
        XCTAssertEqual(link.disconnects, 0, "the open app keeps its link")
        XCTAssertTrue(flushes.isEmpty, "the run doesn't flush a sync it handed over")
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: handed to the app") == true)
        let session = try XCTUnwrap(link.session)
        XCTAssertTrue(session.syncing, "the sync is still running")
        XCTAssertFalse(session.backgroundRunOwnsSyncs)

        // The sync finishes in the app, and the connection's own hook flushes it exactly once. It is
        // one sync end (`syncsFinished == 1`, no restart), so ContentView's sync-end passes
        // (`HelioSyncEndStep`, the reminder evaluation included) also run once for it.
        link.transport?.drain()
        for _ in 0..<200 where link.hookFlushes == 0 { await Task.yield() }
        XCTAssertEqual(session.syncsFinished, 1)
        XCTAssertEqual(session.lastSyncResult?.interrupted, false)
        XCTAssertEqual(session.lastSyncResult?.endedInBackgroundRun, false)
        XCTAssertEqual(link.hookFlushes, 1)
        XCTAssertEqual(link.hookFinalized, [true], "review-225b S-B: the Focus run's finalization went with the sync")
        XCTAssertTrue(flushes.isEmpty)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)

        // A later foreground sync on the same session doesn't inherit it.
        session.syncHistory(manual: true)
        link.transport?.drain()
        for _ in 0..<200 where link.hookFlushes < 2 { await Task.yield() }
        XCTAssertEqual(session.syncsFinished, 2)
        XCTAssertEqual(link.hookFinalized, [true, false])
    }

    // MARK: review-225b S-A: a session made after the watch loop owns its own syncs

    /// `service(_:…)` with a changeable app state and a step that runs inside the run's Health flush
    /// (the reviewer's probe harness, review-225b).
    private func leakService(_ link: FakeBackgroundLink, store: LocalStore, flushes: @escaping (FlushCall) -> Void,
                             appActive: @escaping @MainActor () -> Bool, pause: @escaping @MainActor () -> Void,
                             duringFlush: @escaping @MainActor () async -> Void = {}) -> HelioBackgroundSyncService {
        let base = service(link, store: store, flushes: flushes, pause: pause)
        return HelioBackgroundSyncService(
            link: base.link, keyStore: base.keyStore, observability: base.observability,
            flush: { timeline, nights, identity, finalized in
                await duringFlush()
                return await base.flush(timeline, nights, identity, finalized)
            },
            now: base.now, pause: base.pause, grace: base.grace, appIsActive: appActive)
    }

    /// Move the link's current session along until `done` (radio events, one second a step).
    private func drive(_ link: FakeBackgroundLink, until done: @MainActor () -> Bool) async {
        for _ in 0..<400 where !done() {
            link.transport?.drain()
            clock = clock.addingTimeInterval(1)
            link.session?.tick(now: clock)
            await Task.yield()
        }
    }

    /// LEAK A (review-225b): the strap drops and the standing reconnect brings it back while a
    /// finished run is still in its Health flush. The fake link builds the new session synchronously
    /// on connect; in the app `makeSession` waits for connect + discovery, so the real window is the
    /// run's grace and Health flush. That session was marked run-owned and its syncs never reached
    /// Health; it must flush its own.
    func testASessionCreatedDuringARunsFlushFlushesItsOwnSync() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        var bounced = false
        let run = await leakService(link, store: store, flushes: { flushes.append($0) }, appActive: { false },
                                    pause: { link.transport?.drain() },
                                    duringFlush: {
                                        guard !bounced else { return }
                                        bounced = true
                                        link.disconnectForBackground()
                                        _ = link.connectForBackground()
                                    })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(link.activeBackgroundRuns, 0)
        let fresh = try XCTUnwrap(link.session)
        let markedAfterRun = fresh.backgroundRunOwnsSyncs
        await drive(link) { fresh.syncsFinished > 0 }
        for _ in 0..<200 where link.hookFlushes == 0 { await Task.yield() }
        XCTAssertEqual(fresh.syncsFinished, 1)
        XCTAssertFalse(markedAfterRun, "made after the watch loop: the session owns its own syncs")
        XCTAssertEqual(fresh.lastSyncResult?.endedInBackgroundRun, false)
        XCTAssertEqual(link.hookFlushes, 1, "the reconnected session's sync-on-connect reaches Health")
        XCTAssertEqual(flushes.count, 1, "the run flushed only its own sync")
    }

    /// LEAK B (review-225b), the S1 neighbourhood: the budget runs out while the app is not yet active
    /// (unlocking), so the run abandons; the person opens the app during the teardown and the
    /// foreground's `reconnectKnown()` reconnects while the run is in its grace and Health flush. The
    /// fake link builds that session synchronously (see LEAK A).
    func testOpeningTheAppDuringAnAbandonedRunsTeardownFlushesTheForegroundSync() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        var active = false
        var opened = false
        let run = await leakService(link, store: store, flushes: { flushes.append($0) }, appActive: { active },
                                    pause: { link.transport?.drainSteps(2) },
                                    duringFlush: {
                                        guard !opened else { return }
                                        opened = true
                                        active = true                       // scenePhase → .active
                                        _ = link.connectForBackground()     // handleForegroundActivation → reconnectKnown()
                                    })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: self.clock)
        XCTAssertEqual(run.ending, .outOfTime)
        XCTAssertEqual(flushes.count, 1, "the abandoned run's own flush")
        let fresh = try XCTUnwrap(link.session)
        let markedAfterRun = fresh.backgroundRunOwnsSyncs
        await drive(link) { fresh.syncsFinished > 0 }
        for _ in 0..<200 where link.hookFlushes == 0 { await Task.yield() }
        XCTAssertEqual(fresh.syncsFinished, 1)
        XCTAssertFalse(markedAfterRun, "the foreground's session belongs to the app")
        XCTAssertEqual(link.hookFlushes, 1, "the foreground sync reaches Health")
    }

    /// Review-225b S-A: the session made during the run's Health flush now flushes its own sync, so
    /// the two flushes can overlap. The later one returns empty (the writer's `isFlushing` guard) and
    /// its rows stay pending; the next flush writes them. Nothing is written twice; the rows are
    /// delayed until the next flush, which has no fixed bound in the app (the next sync's hook, the
    /// next background run, or a foreground flush). The writer here is a model of the guard, not
    /// `HealthKitWriter` itself (HealthKit is unavailable in the simulator).
    /// The fake link builds the new session synchronously (see LEAK A).
    func testOverlappingFlushesWriteNothingTwiceAndDelayTheRestToTheNextFlush() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let timeline = try XCTUnwrap(link.strapTimeline)
        let writer = GuardedHealthWriter(store: store)
        link.hookAction = { _ in await writer.flush(timeline) }
        // While the run's save is in flight, the strap drops and comes back with ten more minutes of
        // activity (heart rate), and the new session's own sync ends and flushes.
        writer.duringNextSave = { [unowned self] in
            device.fetchData[.activity] = (stamp(midnight - 3600), activityData() + (0..<10).flatMap { _ in [0x01, 0x08, 5, 60, 0, 0, 0, 0] as [UInt8] })
            link.disconnectForBackground()
            _ = link.connectForBackground()
            let fresh = link.session
            await self.drive(link) { fresh?.syncsFinished ?? 0 > 0 }
            for _ in 0..<200 where link.hookFlushes == 0 { await Task.yield() }
        }
        let base = service(link, store: store, pause: { link.transport?.drain() })
        let run = await HelioBackgroundSyncService(
            link: base.link, keyStore: base.keyStore, observability: base.observability,
            flush: { timeline, _, _, _ in
                var result = HealthKitWriter.FlushResult()
                result.samples = await writer.flush(timeline)
                return result
            },
            now: base.now, pause: base.pause, grace: base.grace, appIsActive: { false })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(link.hookFlushes, 1, "the new session flushed its own sync")
        XCTAssertEqual(writer.emptyBecauseBusy, 1, "…while the run's flush was saving, so it returned empty")

        // Its ten new heart-rate minutes are still pending; the next flush writes exactly them.
        let firstWrite = writer.written.count
        let stillPending = try store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds())
        XCTAssertEqual(stillPending.filter { $0.kind == .heartRate }.count, 10)
        let secondWrite = await writer.flush(timeline)
        XCTAssertEqual(secondWrite, stillPending.count)
        XCTAssertTrue(try store.pendingHealthSamples(device: timeline, kinds: HelioHealthPolicy.healthMirroredKinds()).isEmpty,
                      "delayed until the next flush, then written")
        let keys = writer.written.map { "\($0.kind.rawValue) \($0.start.timeIntervalSince1970)" }
        XCTAssertEqual(Set(keys).count, keys.count, "nothing written twice")
        XCTAssertEqual(writer.written.count, firstWrite + stillPending.count)
        let stored = try store.context.fetch(FetchDescriptor<StoredSample>())
            .filter { HelioHealthPolicy.healthMirroredKinds().map(\.rawValue).contains($0.kindRaw) && $0.value > 0 }
        XCTAssertEqual(writer.written.count, stored.count, "every mirrored row reached the writer once")
    }

    /// Review-225c SF-2, from the reviewer's re-adopt probe: the Focus run hands its sync to the app,
    /// the app goes back to the background, and the next app-refresh run adopts the still-running sync
    /// and flushes it itself. That flush keeps the Focus run's finalization (it rides on the result).
    func testAHandedOffFocusSyncThatTheNextRunAdoptsKeepsItsFinalization() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let focus = await service(link, store: store, flushes: { flushes.append($0) }, appIsActive: true,
                                  pause: { link.transport?.drainSteps(1) })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: self.clock)
        XCTAssertEqual(focus.ending, .handedToApp)
        let session = try XCTUnwrap(link.session)
        XCTAssertTrue(session.syncing, "handed over mid-sync")
        let refresh = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(refresh.ending, .synced)
        XCTAssertNotNil(refresh.result?.nightsFinalized)
        XCTAssertEqual(link.hookFlushes, 0, "the run adopted the sync, so the hook skipped it")
        XCTAssertEqual(flushes.count, 1, "one flush")
        XCTAssertEqual(flushes.first?.finalized, true, "the Focus run's finalization is kept")
        XCTAssertEqual(flushes.first?.nights, 1)
    }

    // MARK: #233: the strap wakes the app (decision 33)

    /// The woke-up event on an idle background link (left up by an earlier run, B.5) runs one bounded
    /// catch-up under a background assertion: it syncs on the live link (no reconnect), flushes Health
    /// once without finalizing the night, logs a Bluetooth-wake row, and ends the assertion.
    func testTheStrapsWokeUpEventOnAnIdleLinkRunsOneBoundedCatchUp() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let first = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(first.ending, .synced)
        clock = clock.addingTimeInterval(6 * 3600)
        var flushes: [FlushCall] = []
        var begun = 0, ended: [Int] = [], done = 0
        var catchUp: HelioBackgroundRun?
        let wake = HelioWakeCoordinator(.init(
            strapChosen: { true }, appIsActive: { false }, runActive: { link.activeBackgroundRuns > 0 },
            state: HelioWakeState(defaults), now: { [unowned self] in self.clock },
            syncInForeground: {},
            beginAssertion: { _ in begun += 1; return begun },
            endAssertion: { ended.append($0) },
            run: { [unowned self] wake in
                await self.service(link, store: store, flushes: { flushes.append($0) })
                    .run(kind: HelioWakePolicy.kind(for: wake), timeout: RingBackgroundSyncService.defaultTimeout, wake: wake)
            },
            expire: {}, afterRun: { catchUp = $0 }, note: { _, _ in }))
        link.onEvent = { event in if event == .wokeUp { wake.wake(.strapEvent) { done += 1 } } }
        link.transport?.push(link.device.unsolicited(endpoint: 0x001D, [0x06, 0x00]))
        link.transport?.drain()
        for _ in 0..<5000 where done == 0 { await Task.yield() }
        XCTAssertEqual(done, 1)
        XCTAssertEqual(begun, 1)
        XCTAssertEqual(ended, [1])
        XCTAssertEqual(link.connects, 1, "the link was up: no reconnect")
        XCTAssertEqual(link.session?.syncsFinished, 2)
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(flushes.first?.finalized, false, "a woke-up event is not a finalization: the night waits for its margin")
        let record = try XCTUnwrap(lastRecord())
        XCTAssertEqual(record.kind, .cbWake)
        XCTAssertTrue(record.detail?.hasPrefix("helio strap: synced") == true, record.detail ?? "")
        XCTAssertEqual(Set(link.device.fetchAcks), [0x09])
        XCTAssertEqual(link.runStarts.count, 2)
        // #233 item 5, §21.4: the night's record may be late after a woke-up event; look again later.
        let refreshAt = try XCTUnwrap(catchUp?.refreshAt)
        XCTAssertGreaterThanOrEqual(refreshAt.timeIntervalSince(clock), StrapNightRefresh.afterWokeUp - 60)
    }

    /// #233 item 5: a background run whose flush starts while the night is still inside its 20-minute
    /// margin holds it back, and asks for the next refresh at the margin's end.
    func testARunThatHoldsANightBackAimsTheNextRefreshAtItsMarginsEnd() async throws {
        let store = try makeStore()
        clock = Date(timeIntervalSince1970: midnight + 7 * 3600 + 5 * 60)   // 5 min after the fake night ends
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .synced)
        let end = try XCTUnwrap(run.result?.nights.first?.segments.map(\.end).max())
        XCTAssertEqual(flushes.first?.nights, 1)
        XCTAssertEqual(run.refreshAt, end.addingTimeInterval(SleepHealthGate.settleMargin))

        clock = end.addingTimeInterval(3 * 3600)
        let later = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertNil(later.refreshAt, "settled: nothing waiting")
    }

    /// Decision 57b (#262), the background run's half: a run stores the night inside its margin and
    /// asks for the margin refresh; the strap then stops re-delivering it. The next background run,
    /// still inside the margin, carries no night. Its own nights alone ask for nothing, and the app
    /// (`AppDelegate`'s `record(run.refreshAt)`) would have cleared the pending refresh. With the stored
    /// night read after its flush, it asks for the same refresh, which survives the app's `schedule()`.
    func testABackgroundRunThatNoLongerCarriesTheNightKeepsItsMarginRefresh() async throws {
        let store = try makeStore()
        clock = Date(timeIntervalSince1970: midnight + 7 * 3600 + 5 * 60)   // 5 min after the fake night ends
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        func wired() -> HelioBackgroundSyncService {
            var wired = service(link, store: store)
            wired.storedNightSettles = { timeline, now in store.newestStrapNightSettles(timeline: timeline, now: now) }
            return wired
        }
        let first = await wired().run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(first.ending, .synced)
        let end = try XCTUnwrap(first.result?.nights.first?.segments.map(\.end).max())
        let marginEnd = end.addingTimeInterval(SleepHealthGate.settleMargin)
        XCTAssertEqual(first.refreshAt, marginEnd)
        let key = try XCTUnwrap(try store.latestSleepSummary()).night
        clearMirror(key)
        defer { clearMirror(key) }

        let suite = "HelioSessionTests.margin.\(UUID().uuidString)"
        let refreshDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { refreshDefaults.removePersistentDomain(forName: suite) }
        let recorder = BackgroundMarginRecorder()
        let now = clock
        let scheduler = BackgroundRefreshScheduler(scheduler: recorder, now: { now }, window: { _ in nil })
        StrapNightRefresh.record(first.refreshAt, scheduler: scheduler, defaults: refreshDefaults)

        // The strap stops re-delivering the night; two minutes on, still inside the margin.
        device.fetchData[.sleepSession] = nil
        clock = clock.addingTimeInterval(2 * 60)
        let unwired = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(unwired.ending, .synced)
        XCTAssertEqual(unwired.result?.nights.count, 0, "the strap no longer re-delivers it")
        XCTAssertNil(unwired.refreshAt, "the run's own nights alone ask for nothing")

        let second = await wired().run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(second.ending, .synced)
        XCTAssertEqual(second.result?.nights.count, 0)
        XCTAssertEqual(second.refreshAt, marginEnd, "the stored night still asks for its margin refresh")
        StrapNightRefresh.record(second.refreshAt, scheduler: scheduler, defaults: refreshDefaults)
        XCTAssertEqual(StrapNightRefresh.pending(now: clock, defaults: refreshDefaults), marginEnd, "not cancelled")
        scheduler.schedule()
        XCTAssertTrue(StrapNightRefresh.resubmit(scheduler, strapChosen: true, now: now, defaults: refreshDefaults))
        XCTAssertTrue(recorder.submitted is BGAppRefreshTaskRequest)
        XCTAssertEqual(recorder.submitted?.identifier, BackgroundRefreshScheduler.identifier)
        XCTAssertEqual(recorder.submitted?.earliestBeginDate, marginEnd, "re-armed after the app's schedule()")

        // Settled, the stored night asks for nothing more (it waits for 57a's backstop).
        clock = marginEnd.addingTimeInterval(60)
        let settled = await wired().run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertNil(settled.refreshAt)
    }

    // MARK: steer 12: 28f stitching vs a night already written to Apple Health

    /// The night key the stored strap night files under, and its mirror record cleared afterwards
    /// (`MirroredNightOverlay` lives in the standard defaults).
    private func clearMirror(_ night: Date) {
        UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(Calendar.current.startOfDay(for: night).timeIntervalSince1970)")
    }

    /// Decision 58b (#274): a night already written to Apple Health is replaced only by a night that
    /// extends it. Back to bed 40 min after it ended, the next sync re-delivers both sessions and 28f
    /// stitches them into a night 90 min longer: it is stored and handed to the flush, whose writer
    /// replaces the written night (signature rewrite). Before the night is written, the same sessions
    /// stitch as before. A re-delivery of the written night alone changes nothing.
    func testANightAlreadyInHealthIsReplacedOnlyByALaterStitchableSessionThatExtendsIt() async throws {
        for written in [true, false] {
            let store = try makeStore()
            let device = makeStrap()
            let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
            var flushes: [FlushCall] = []
            let first = await service(link, store: store, flushes: { flushes.append($0) })
                .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
            XCTAssertEqual(first.ending, .synced)
            let night = try XCTUnwrap(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).first)
            let firstWindow = DateInterval(start: night.inBedStart, end: night.inBedEnd)
            defer { clearMirror(night.night) }
            if written {
                // What `mirrorSettledNight` records once the night is in Apple Health.
                store.setMirroredNight(night: night.night, signature: "written", spanStart: firstWindow.start, spanEnd: firstWindow.end)
                // The written night re-delivered alone: the same night, nothing new for Health.
                clock = clock.addingTimeInterval(1800)
                let again = await service(link, store: store, flushes: { flushes.append($0) })
                    .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
                XCTAssertEqual(again.ending, .synced)
                XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).first?.inBedEnd, firstWindow.end)
                XCTAssertEqual(store.mirroredNight(night: night.night)?.signature, "written")
            }
            // The back-to-bed session arrives; the strap re-delivers both on the overlapping fetch.
            device.fetchData[.sleepSession] = (stamp(midnight), sessionRecord() + laterSessionRecord())
            clock = clock.addingTimeInterval(3600)
            let second = await service(link, store: store, flushes: { flushes.append($0) })
                .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
            XCTAssertEqual(second.ending, .synced)
            let nights = try store.context.fetch(FetchDescriptor<StoredSleepSummary>())
            XCTAssertEqual(nights.count, 1, "one night per key")
            let stored = try XCTUnwrap(nights.first)
            XCTAssertEqual(stored.inBedStart, firstWindow.start)
            XCTAssertEqual(stored.inBedEnd, Date(timeIntervalSince1970: midnight + 8 * 3600 + 30 * 60), "stitched (28f)")
            XCTAssertEqual(second.result?.nights.map(\.window), [DateInterval(start: firstWindow.start, end: stored.inBedEnd)],
                           written ? "it extends the written night (58b)" : "not yet written")
            XCTAssertEqual(flushes.last?.nights, 1)
        }
    }

    // MARK: review-225e SF-2: the expiry's teardown happens inside the handler

    /// A catch-up expires mid-round. `tearDownForExpiry` (the expiry handler's teardown) queues the
    /// `03 09`, ends the fetch, cancels the link in the same call (never the 500 ms deferred cancel,
    /// which a suspended app wouldn't run) and arms the standing connect; the ack is queued before the
    /// cancel.
    func testAnExpiryMidRoundCancelsTheLinkAndReArmsInsideTheHandler() async throws {
        var probed = false
        for settle in 0..<60 where !probed {
            let store = try makeStore()
            let device = makeStrap()
            let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
            let run = Task { @MainActor [unowned self] in
                await self.service(link, store: store, pause: { link.transport?.drainSteps(1) })
                    .run(kind: .cbWake, timeout: 3600, wake: .strapEvent)
            }
            for _ in 0..<20_000 where !(link.session?.syncing == true && device.fetchStarts.count > device.fetchAcks.count) {
                await Task.yield()
            }
            for _ in 0..<settle { await Task.yield() }   // let the start reply land, so the round is open
            guard link.session?.syncing == true else { run.cancel(); _ = await run.value; continue }
            let acksBefore = device.fetchAcks.count
            link.tearDownForExpiry()
            run.cancel()   // what the expiry handler does next
            let ended = await run.value
            guard device.fetchAcks.count > acksBefore else { continue }   // no round was open yet
            probed = true
            let cancel = try XCTUnwrap(link.cancels.first)
            XCTAssertTrue(cancel.cancelNow, "cancelled in the handler")
            XCTAssertFalse(cancel.sessionSyncing, "the fetch ended first, so nothing would defer the cancel")
            let writes = try XCTUnwrap(link.cancelledTransport?.writes)
            let ack = try XCTUnwrap(writes.lastIndex { $0.bytes == [0x03, 0x09] })
            XCTAssertLessThan(ack, cancel.writesBefore, "the 03 09 is queued before the cancel")
            XCTAssertEqual(device.fetchAcks.last, 0x09)
            XCTAssertEqual(link.rearms, 1, "the standing connect is armed in the handler")
            XCTAssertEqual(ended.ending, .expired)
            XCTAssertEqual(link.disconnects, 1, "the run found the link already down")
        }
        XCTAssertTrue(probed, "found a moment with a round open")
    }

    // MARK: decision 35: the held, idle link's own traffic is a wake

    /// An idle night on a held link (B.5): connected, authenticated, never dropped, so no reconnect wake
    /// ever comes. What the strap sends on its own over that link goes through `HelioIdleTrafficGate`
    /// and `HelioWakePolicy` like a reconnect, so `HelioConnection`'s routing is reproduced here.
    private func idleNight(_ link: FakeBackgroundLink, store: LocalStore, state: HelioWakeState,
                           flushes: @escaping (FlushCall) -> Void, recordsCompletion: Bool = true)
        -> (coordinator: HelioWakeCoordinator, wakes: () -> [HelioWake]) {
        var wakes: [HelioWake] = []
        var gate = HelioIdleTrafficGate()
        link.wakeState = state
        let coordinator = HelioWakeCoordinator(.init(
            strapChosen: { true }, appIsActive: { false }, runActive: { link.activeBackgroundRuns > 0 },
            state: state, now: { [unowned self] in self.clock },
            syncInForeground: {},
            beginAssertion: { _ in 1 }, endAssertion: { _ in },
            run: { [unowned self] wake in
                wakes.append(wake)
                return await self.service(link, store: store, flushes: flushes)
                    .run(kind: HelioWakePolicy.kind(for: wake), timeout: RingBackgroundSyncService.defaultTimeout, wake: wake)
            },
            expire: {},
            afterRun: { [unowned self] run in
                // `HelioConnection`'s post-sync hook records a completed sync; `recordsCompletion: false`
                // models one that never completes (so only the cooldown holds the next one back).
                if recordsCompletion, run.ending == .synced, run.result?.interrupted == false { state.lastCompletedSync = self.clock }
            },
            note: { _, _ in }))
        link.onEvent = { [unowned self] event in
            switch event {
            case .strapMessage, .strapNotification:
                if gate.shouldCheck(now: self.clock, appIsActive: false, syncing: link.session?.syncing == true,
                                    runActive: link.activeBackgroundRuns > 0) {
                    coordinator.wake(.idleTraffic)
                }
            default: break
            }
        }
        return (coordinator, { wakes })
    }

    /// The steer's case: heart-rate notifications on a timer over a link that never drops. (On a real
    /// idle link these don't come: the strap streams `0x2A37` only while the phone keeps sending `04 02`,
    /// §7.1, and §16.5's fail-safe stops unasked frames. The routing is the same for any message the
    /// strap sends on its own.) A catch-up fires once the 4 h gate is crossed, and not again until the
    /// next one.
    func testHeartRateOnAHeldIdleLinkWakesACatchUpOnlyAfterFourHours() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let state = HelioWakeState(defaults)
        var flushes: [FlushCall] = []
        // The evening sync: the link stays up, idle and authenticated (B.5).
        let evening = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(evening.ending, .synced)
        let eveningSync = clock
        state.lastCompletedSync = eveningSync
        let night = idleNight(link, store: store, state: state, flushes: { flushes.append($0) })
        var catchUpsAt: [TimeInterval] = []
        for step in 1...54 {   // every 10 minutes for 9 hours
            clock = eveningSync.addingTimeInterval(TimeInterval(step * 600))
            let before = night.wakes().count
            link.transport?.push(.heartRateMeasurement, [0x00, 58])
            link.transport?.drain()
            for _ in 0..<3000 where night.coordinator.isRunning || link.activeBackgroundRuns > 0 { await Task.yield() }
            if night.wakes().count > before { catchUpsAt.append(TimeInterval(step * 600)) }
        }
        XCTAssertEqual(night.wakes(), [.idleTraffic, .idleTraffic])
        XCTAssertEqual(catchUpsAt.first, 4 * 3600, "the first message at or past the 4 h gate")
        XCTAssertEqual(catchUpsAt.count, 2)
        XCTAssertGreaterThanOrEqual((catchUpsAt.last ?? 0) - (catchUpsAt.first ?? 0), 4 * 3600, "not again until the next 4 h")
        XCTAssertEqual(link.connects, 1, "no reconnect all night")
        XCTAssertEqual(link.disconnects, 0)
        XCTAssertEqual(flushes.count, 3, "the evening sync and the two catch-ups, each flushed once")
        let records = ObservabilityStore(defaults).records().filter { $0.kind == .cbWake }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.detail?.hasPrefix("helio strap: synced") == true })
    }

    /// The cooldown: when a catch-up's sync never completes, the 4 h gate stays open, and only the
    /// 30-minute cooldown keeps the strap's pings from starting a run every few minutes.
    func testPingsOnAHeldIdleLinkCannotChainCatchUpsInsideTheCooldown() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let state = HelioWakeState(defaults)
        let evening = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(evening.ending, .synced)
        let start = clock
        state.lastCompletedSync = start.addingTimeInterval(-5 * 3600)
        let night = idleNight(link, store: store, state: state, flushes: { _ in }, recordsCompletion: false)
        var catchUpsAt: [TimeInterval] = []
        for step in 1...10 {   // a ping every 6 minutes for an hour
            clock = start.addingTimeInterval(TimeInterval(step * 360))
            let before = night.wakes().count
            link.transport?.push(link.device.unsolicited(endpoint: 0x0015, [0x03]))
            link.transport?.drain()
            for _ in 0..<3000 where night.coordinator.isRunning || link.activeBackgroundRuns > 0 { await Task.yield() }
            if night.wakes().count > before { catchUpsAt.append(TimeInterval(step * 360)) }
        }
        XCTAssertEqual(catchUpsAt.count, 2, "one at the first ping, the next only once the cooldown has passed")
        XCTAssertGreaterThanOrEqual((catchUpsAt.last ?? 0) - (catchUpsAt.first ?? 0), HelioWakePolicy.reconnectCooldown)
    }

    /// A run that tears the link down (out of time) arms a standing connect again, so the strap can
    /// wake the app later; a quiet ending (strap busy, decision 7) doesn't.
    func testATornDownRunReArmsAStandingConnectAndAQuietEndingDoesNot() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let short = await service(link, store: store, pause: { link.transport?.drainSteps(1) })
            .run(kind: .appRefresh, timeout: HelioBackgroundSyncService.flushReserve + 3)
        XCTAssertEqual(short.ending, .outOfTime)
        XCTAssertTrue(short.disconnected)
        XCTAssertEqual(link.rearms, 1)

        let busyLink = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        busyLink.silent = true
        let busy = await service(busyLink, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(busy.ending, .strapBusy)
        XCTAssertEqual(busyLink.rearms, 0)
    }

    // MARK: decision 31: "the night is over" expires 30 minutes after Sleep Focus ended

    /// The finalization a run receives for a Sleep Focus that ended at `t`: decision 31's T. (These tests
    /// were first run at `dced60f`, where this returned `true`, to show the stale paths finalized there.)
    private func focusEnded(at t: Date) -> Date? { t }

    /// Review-225d SF-A, the reviewer's probe: the watched sync ends in the run's last pause and iOS
    /// expires the task before the loop looks again, with the app in front. The hand-off must not
    /// leave a finalization on the now idle session for a plain app-refresh run hours later.
    func testAnExpiryHandOffAfterTheSyncEndedLeavesNoFinalizationForALaterRun() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let focusService = service(link, store: store, flushes: { flushes.append($0) }, appIsActive: true, pause: {
            link.transport?.drain()
            // The sync ended in this pause; iOS expires the task before the loop looks again.
            if link.session?.syncsFinished == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let focusEnd = clock
        let focus = await Task { @MainActor in
            await focusService.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout,
                                   nightsFinalized: self.focusEnded(at: focusEnd))
        }.value
        XCTAssertEqual(focus.ending, .handedToApp)
        let session = try XCTUnwrap(link.session)
        XCTAssertFalse(session.syncing, "the handed-over sync had already ended")
        XCTAssertNil(session.finalizeNightsOnHandOff, "SF-A: nothing is left on the idle session")
        clock = clock.addingTimeInterval(6 * 3600)   // hours later, an ordinary refresh on the kept link
        let later = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(later.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [false], "an app-refresh run 6 h later keeps the quiet margin")
    }

    /// A waiting Focus run's request, taken by a non-Focus run's hand-off to the app; the app's sync
    /// ends 31 minutes after Focus ended. Decision 31: that flush is not finalized.
    func testAWaitersRequestTakenByANonFocusHandOffIsStaleThirtyOneMinutesLater() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // The processing run holds the link with the app in front; one radio event a second, so it
        // runs out of its 52 s window mid-sync and hands off, taking the waiter's request.
        let processing = service(link, store: store, flushes: { flushes.append($0) }, appIsActive: true,
                                 pause: { link.transport?.drainSteps(1) })
        let focus = waitingService(link, store: store, flushes: { flushes.append($0) })
        let a = Task { @MainActor in await processing.run(kind: .processing, timeout: 60) }
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let focusEnd = clock
        let focusRun = await Task { @MainActor in
            await focus.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout,
                            nightsFinalized: self.focusEnded(at: focusEnd))
        }.value
        let first = await a.value
        XCTAssertEqual(focusRun.ending, .coalesced(into: .processing), "#233: it leaves its request at once")
        XCTAssertEqual(first.ending, .handedToApp)
        let session = try XCTUnwrap(link.session)
        XCTAssertTrue(session.syncing)
        // The app finishes that sync 31 minutes after Focus ended.
        clock = focusEnd.addingTimeInterval(31 * 60)
        link.transport?.drain()
        for _ in 0..<200 where link.hookFlushes == 0 { await Task.yield() }
        XCTAssertEqual(link.hookFlushes, 1)
        XCTAssertEqual(link.hookFinalized, [false], "decision 31: 31 minutes after Focus ended, the night waits for the margin")
        XCTAssertTrue(flushes.isEmpty)
    }

    /// Review-225d SF-A's third route: a Focus run started on an already-cancelled task, with the app in
    /// front and an idle session up, hands off at once. Nothing may be left on that idle session.
    func testARunOnAnAlreadyCancelledTaskLeavesNoFinalizationOnAnIdleSession() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // An idle, authenticated link left by an earlier foreground sync (flushed by the app's hook).
        _ = link.connectForBackground()
        link.transport?.drain()
        let idle = try XCTUnwrap(link.session)
        XCTAssertEqual(idle.syncsFinished, 1)
        XCTAssertFalse(idle.syncing)
        let focusEnd = clock
        let focusService = service(link, store: store, flushes: { flushes.append($0) }, appIsActive: true)
        let run = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await focusService.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout,
                                          nightsFinalized: self.focusEnded(at: focusEnd))
        }.value
        XCTAssertEqual(run.ending, .handedToApp)
        XCTAssertNil(idle.finalizeNightsOnHandOff, "SF-A: nothing is left on the idle session")
        clock = clock.addingTimeInterval(6 * 3600)
        let later = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(later.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [false], "an app-refresh run 6 h later keeps the quiet margin")
    }

    /// A Focus run hands its sync to the app, and the app's sync ends 31 minutes after Focus ended
    /// (a long stall). Decision 31: that flush is not finalized.
    func testAHandedOffFocusSyncThatEndsThirtyOneMinutesLaterIsNotFinalized() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let focusEnd = clock
        let focus = await service(link, store: store, appIsActive: true, pause: { link.transport?.drainSteps(2) })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: focusEnded(at: focusEnd))
        XCTAssertEqual(focus.ending, .handedToApp)
        let session = try XCTUnwrap(link.session)
        XCTAssertTrue(session.syncing)
        clock = focusEnd.addingTimeInterval(31 * 60)
        link.transport?.drain()
        for _ in 0..<200 where link.hookFlushes == 0 { await Task.yield() }
        XCTAssertEqual(link.hookFlushes, 1)
        XCTAssertEqual(link.hookFinalized, [false], "decision 31: 31 minutes after Focus ended, the night waits for the margin")
    }

    /// A Focus run whose own flush starts 31 minutes after Focus ended (T passed in 31 minutes old):
    /// not finalized (decision 31).
    func testTheFocusRunsOwnFlushStartingThirtyOneMinutesAfterFocusEndedIsNotFinalized() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout,
                 nightsFinalized: clock.addingTimeInterval(-31 * 60))
        XCTAssertEqual(run.ending, .synced)
        XCTAssertEqual(flushes.count, 1)
        XCTAssertNotNil(flushes.first?.focusEndedAt, "the Focus end reached the flush")
        XCTAssertEqual(flushes.first?.finalized, false, "…but more than 30 minutes after it, the night waits for the margin")
    }

    /// Decision 31's boundary: a flush that starts exactly 30 minutes after Focus ended is finalized; one
    /// a second later is not; no Focus end, never. And the latest of two Focus ends is the one kept.
    func testTheThirtyMinuteBoundaryAndTheLatestFocusEnd() {
        let t = Date(timeIntervalSince1970: midnight + 7 * 3600)
        XCTAssertEqual(SleepFocusFinalization.window, 30 * 60)
        XCTAssertTrue(SleepFocusFinalization.applies(focusEndedAt: t, flushStartsAt: t))
        XCTAssertTrue(SleepFocusFinalization.applies(focusEndedAt: t, flushStartsAt: t.addingTimeInterval(30 * 60)))
        XCTAssertFalse(SleepFocusFinalization.applies(focusEndedAt: t, flushStartsAt: t.addingTimeInterval(30 * 60 + 1)))
        XCTAssertFalse(SleepFocusFinalization.applies(focusEndedAt: nil, flushStartsAt: t))
        let later = t.addingTimeInterval(600)
        XCTAssertEqual(SleepFocusFinalization.latest(t, later), later)
        XCTAssertEqual(SleepFocusFinalization.latest(later, t), later)
        XCTAssertEqual(SleepFocusFinalization.latest(nil, t), t)
        XCTAssertNil(SleepFocusFinalization.latest(nil, nil))
    }

    /// The same boundary end to end, through a hand-off: the app's flush of the handed-over Focus sync
    /// starting exactly 30 minutes after Focus ended is finalized.
    func testAHandedOffFocusSyncThatEndsExactlyThirtyMinutesLaterIsFinalized() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let focusEnd = clock
        let focus = await service(link, store: store, appIsActive: true, pause: { link.transport?.drainSteps(2) })
            .run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: focusEnded(at: focusEnd))
        XCTAssertEqual(focus.ending, .handedToApp)
        clock = focusEnd.addingTimeInterval(30 * 60)
        link.transport?.drain()
        for _ in 0..<200 where link.hookFlushes == 0 { await Task.yield() }
        XCTAssertEqual(link.hookFinalized, [true])
    }

    // MARK: review-225c SF-1: a waiting Focus run's request lives only as long as the run it was left for

    /// A run that only waits for its turn: its pause yields without moving the shared fake clock or the
    /// radio, so the run holding the link alone sets the pace (review-225c F-1: a waiter that moved the
    /// clock itself made the active run's 10 s auth time out, depending on how the tasks interleaved).
    /// Capped, so a waiter that unexpectedly gets its own turn ends instead of spinning forever.
    private func waitingService(_ link: FakeBackgroundLink, store: LocalStore,
                                flushes: @escaping (FlushCall) -> Void = { _ in }) -> HelioBackgroundSyncService {
        let base = service(link, store: store, flushes: flushes)
        var spins = 0
        return HelioBackgroundSyncService(
            link: base.link, keyStore: base.keyStore, observability: base.observability, flush: base.flush,
            now: base.now,
            pause: {
                spins += 1
                if spins > 100_000 { withUnsafeCurrentTask { $0?.cancel() } }
                await Task.yield()
            },
            grace: base.grace, appIsActive: base.appIsActive)
    }

    /// Leak path (a): the Focus run coalesces into the processing run (#233; it used to wait and give
    /// up), then iOS expires that run (no flush, so the request is never taken). An unrelated
    /// app-refresh run hours later must flush normally.
    func testAFinalizationLeftForARunThatExpiresDoesNotReachALaterRun() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // One radio event a second: still syncing when the Focus run's 20 s window ends.
        let processing = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let focus = waitingService(link, store: store, flushes: { flushes.append($0) })
        let a = Task { @MainActor in await processing.run(kind: .processing, timeout: 3600) }
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let focusRun = await Task { @MainActor in
            await focus.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: self.clock)
        }.value
        XCTAssertEqual(focusRun.ending, .coalesced(into: .processing))
        a.cancel()   // iOS expires the processing task
        let first = await a.value
        XCTAssertEqual(first.ending, .expired)
        XCTAssertNil(link.pendingNightsFinalization, "cleared when the run it was left for returned")
        clock = clock.addingTimeInterval(6 * 3600)
        let later = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(later.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [false], "an app-refresh run hours later keeps the quiet margin")
    }

    /// Leak path (b): the run the Focus request was left for ends quietly (the strap turns out busy).
    func testAFinalizationLeftForARunThatEndsQuietlyDoesNotReachALaterRun() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // The strap comes into range only after the Focus run has given up, and then never answers.
        link.inRange = false
        link.silent = true
        let started = clock
        let processing = service(link, store: store, flushes: { flushes.append($0) }, pause: { [unowned self] in
            if link.session == nil, self.clock >= started.addingTimeInterval(25) {
                link.inRange = true
                _ = link.connectForBackground()
            }
            link.transport?.drain()
        })
        let focus = waitingService(link, store: store, flushes: { flushes.append($0) })
        let a = Task { @MainActor in await processing.run(kind: .processing, timeout: 3600) }
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let focusRun = await Task { @MainActor in
            await focus.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: self.clock)
        }.value
        let first = await a.value
        XCTAssertEqual(focusRun.ending, .coalesced(into: .processing))
        XCTAssertEqual(first.ending, .strapBusy)
        XCTAssertNil(link.pendingNightsFinalization, "cleared when the run it was left for returned")
        // Hours later, a new launch: the strap answers again.
        link.silent = false
        link.endedBusy = false
        clock = clock.addingTimeInterval(6 * 3600)
        let later = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(later.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [false], "an app-refresh run hours later keeps the quiet margin")
    }

    /// Leak path (c): the Focus run arrives while the run holding the link is already inside its
    /// Health flush (it took the link's request when it built the flush call, before the save). Since
    /// #233 it coalesces into that run at once; its request must still not reach a later run.
    func testAFinalizationLeftDuringTheActiveRunsFlushDoesNotReachALaterRun() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let focus = waitingService(link, store: store, flushes: { flushes.append($0) })
        var focusRun: HelioBackgroundRun?
        var started = false
        let processing = leakService(link, store: store, flushes: { flushes.append($0) }, appActive: { false },
                                     pause: { link.transport?.drain() },
                                     duringFlush: { [unowned self] in
                                         guard !started else { return }
                                         started = true
                                         // A slow Health save, and the Focus wake arrives during it.
                                         self.clock = self.clock.addingTimeInterval(5)
                                         focusRun = await focus.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout,
                                                                    nightsFinalized: self.clock)
                                     })
        let first = await processing.run(kind: .processing, timeout: RingBackgroundSyncService.processingTimeout)
        XCTAssertEqual(first.ending, .synced)
        XCTAssertEqual(focusRun?.ending, .coalesced(into: .processing), "its sync finished: its flush is the one flush")
        XCTAssertEqual(flushes.map(\.finalized), [false], "the request came after the active run's flush call")
        XCTAssertNil(link.pendingNightsFinalization, "cleared when the run it was left for returned")
        clock = clock.addingTimeInterval(6 * 3600)
        let later = await service(link, store: store, flushes: { flushes.append($0) })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(later.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [false, false], "an app-refresh run hours later keeps the quiet margin")
    }

    /// Leak path (d): a waiting Focus run that iOS expires leaves no request at all.
    func testAWaitingFocusRunThatExpiresLeavesNoFinalization() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let processing = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let focus = waitingService(link, store: store, flushes: { flushes.append($0) })
        let a = Task { @MainActor in await processing.run(kind: .processing, timeout: 3600) }
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let b = Task { @MainActor in await focus.run(kind: .sleepFocus, timeout: 3600, nightsFinalized: self.clock) }
        b.cancel()   // iOS expires the Focus intent before it gets its first look at the link
        let focusRun = await b.value
        XCTAssertEqual(focusRun.ending, .expired)
        XCTAssertNil(link.pendingNightsFinalization, "an expired waiter leaves nothing behind")
        let first = await a.value
        XCTAssertEqual(first.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [false], "the active run's flush isn't finalized by it")
    }

    // MARK: review-225 S2: overlapping runs take turns; #233 item 3: they coalesce

    /// The reviewer's probe (`testReview225TwoConcurrentRunsOnOneLinkBothFlushTheSameSync`), as a
    /// regression test: the Sleep Focus wake and a BGTask run the strap's drain at once. They used to
    /// adopt the same sync and both flush it (review-225 S2); then the later one waited and ran a second
    /// sync; since #233, with budgets alike, the later one coalesces at once. One sync, flushed once,
    /// with the Focus run's finalization whichever run holds the strap, and neither task fails.
    func testTwoOverlappingRunsOnOneLinkSyncAndFlushOnce() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        // One radio event per pause, so the second run is up while the first run's sync is in flight.
        let focus = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let refresh = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        // Long budgets: the simulated strap moves one event per pause, and neither run should run out.
        async let a = focus.run(kind: .sleepFocus, timeout: 3600, nightsFinalized: self.clock)
        async let b = refresh.run(kind: .processing, timeout: 3600)
        let (first, second) = await (a, b)
        let endings = [first.ending, second.ending]
        XCTAssertEqual(endings.filter { $0 == .synced }.count, 1)
        XCTAssertEqual(endings.filter(\.isCoalesced).count, 1)
        XCTAssertTrue(first.success && second.success, "nothing is recorded as a failure")
        XCTAssertEqual(link.connects, 1, "one link")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertEqual(link.session?.syncsFinished, 1, "one sync")
        XCTAssertEqual(flushes.map(\.syncAtFlush), [1], "one flush of that sync")
        XCTAssertEqual(flushes.first?.finalized, true, "the Focus run's finalization reached the one flush")
        XCTAssertEqual(flushes.first?.nights, 1)
        XCTAssertEqual(link.activeBackgroundRuns, 0, "neither run's exit cleared the other's mark early")
        XCTAssertNil(link.activeRun)
        XCTAssertNil(link.pendingNightsFinalization)
        let records = ObservabilityStore(defaults).records()
        XCTAssertEqual(records.filter { $0.detail?.hasPrefix("helio strap: synced") == true }.count, 1)
        XCTAssertEqual(records.filter { $0.detail?.hasPrefix("helio strap: coalesced into the") == true }.count, 1)
        XCTAssertTrue(records.allSatisfy(\.success))
    }

    /// Review-225 S2's side effect, kept under #233: when the Sleep Focus run overlaps a BGTask run, its
    /// "the night is over" still reaches Health with the night, whichever run goes first.
    func testTheSleepFocusRunStillFinalizesItsNightWhenItOverlapsABGTaskRun() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let refresh = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let focus = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        async let a = refresh.run(kind: .appRefresh, timeout: 3600)
        async let b = focus.run(kind: .sleepFocus, timeout: 3600, nightsFinalized: self.clock)
        let (bgTask, sleepFocus) = await (a, b)
        XCTAssertEqual([bgTask.ending, sleepFocus.ending].filter { $0 == .synced }.count, 1)
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(flushes.first?.finalized, true)
        XCTAssertEqual(flushes.first?.nights, 1, "the night is in the finalized flush")
    }

    /// The run under `kind` started now, with its start and return on the shared fake clock.
    private func timedRun(_ service: HelioBackgroundSyncService, kind: TaskRecord.Kind, timeout: TimeInterval)
        -> Task<(run: HelioBackgroundRun, seconds: TimeInterval), Never> {
        Task { @MainActor [unowned self] in
            let start = self.clock
            let run = await service.run(kind: kind, timeout: timeout)
            return (run, self.clock.timeIntervalSince(start))
        }
    }

    /// #233 item 3, build 59's morning: iOS grants the processing and app-refresh tasks in the same
    /// second. Processing first: the refresh task coalesces into it and completes at once; one sync,
    /// and nothing is recorded as a failure.
    func testBothTasksGrantedTogetherProcessingFirstGiveOneSync() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let processing = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let refresh = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let a = timedRun(processing, kind: .processing, timeout: RingBackgroundSyncService.processingTimeout)
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let b = timedRun(refresh, kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        let second = await b.value
        let first = await a.value
        XCTAssertEqual(second.run.ending, .coalesced(into: .processing))
        XCTAssertLessThanOrEqual(second.seconds, 5, "the second task completes within 5 s")
        XCTAssertEqual(second.run.detail, "helio strap: coalesced into the processing run")
        XCTAssertEqual(first.run.ending, .synced)
        XCTAssertEqual(link.session?.syncsFinished, 1, "one sync")
        XCTAssertEqual(flushes.count, 1)
        XCTAssertTrue(ObservabilityStore(defaults).records().allSatisfy(\.success), "nothing recorded as a failure")
        XCTAssertTrue(ObservabilityStore(defaults).metricRecords().contains {
            $0.source == "bgphase" && $0.detail.hasPrefix("device=helio kind=appRefresh ending=coalesced(processing)")
        })
    }

    /// Refresh first: the processing task's larger budget takes the sync over. The refresh task hands
    /// it over at its next turn (nothing torn down, nothing sent) and completes within 5 s; the
    /// processing run finishes that one sync and flushes it once.
    func testBothTasksGrantedTogetherRefreshFirstHandTheSyncToTheLargerBudget() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let refresh = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let processing = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let a = timedRun(refresh, kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let b = timedRun(processing, kind: .processing, timeout: RingBackgroundSyncService.processingTimeout)
        let first = await a.value
        let second = await b.value
        XCTAssertEqual(first.run.ending, .handedOver(to: .processing))
        XCTAssertLessThanOrEqual(first.seconds, 5, "the refresh task completes within 5 s")
        XCTAssertEqual(first.run.detail, "helio strap: handed its sync to the processing run (larger budget)")
        XCTAssertFalse(first.run.disconnected)
        XCTAssertEqual(second.run.ending, .synced)
        XCTAssertEqual(link.connects, 1, "the processing run adopted the refresh run's link")
        XCTAssertEqual(link.disconnects, 0)
        XCTAssertEqual(link.session?.syncsFinished, 1, "one sync")
        XCTAssertEqual(flushes.map(\.syncAtFlush), [1], "flushed once, by the processing run")
        XCTAssertEqual(link.hookFlushes, 0, "the handed-over sync stayed a run's")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertTrue(ObservabilityStore(defaults).records().allSatisfy(\.success), "nothing recorded as a failure")
        XCTAssertNil(link.handOver)
        XCTAssertNil(link.activeRun)
    }

    /// The take-over mid-sync: the refresh run is already fetching when the processing run arrives. The
    /// sync in flight is handed over, not restarted: the processing run flushes exactly that sync, and
    /// a Sleep Focus finalization the refresh run held goes with it.
    func testATakeOverMidSyncFlushesTheSyncInFlightOnce() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let focus = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let processing = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        let focusEnd = clock
        let a = Task { @MainActor in
            await focus.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: focusEnd)
        }
        for _ in 0..<5000 where link.session?.syncing != true { await Task.yield() }
        XCTAssertEqual(link.session?.syncing, true)
        let b = Task { @MainActor in await processing.run(kind: .processing, timeout: RingBackgroundSyncService.processingTimeout) }
        let first = await a.value
        let second = await b.value
        XCTAssertEqual(first.ending, .handedOver(to: .processing))
        XCTAssertEqual(second.ending, .synced)
        XCTAssertEqual(link.session?.syncsFinished, 1, "the sync in flight, not a new one")
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(flushes.first?.syncAtFlush, 1)
        XCTAssertEqual(flushes.first?.focusEndedAt, focusEnd, "the Focus run's finalization went with its sync")
        XCTAssertEqual(link.hookFlushes, 0)
        XCTAssertNil(link.pendingNightsFinalization, "cleared when the run that took it over returned")
    }

    /// A take-over asked for by a run that iOS then expires, before the active run's next turn, is
    /// withdrawn: the active run carries on and syncs. (The active run is held in its pause while the
    /// waiter asks and expires, so the order is fixed.)
    func testATakeOverAskedForByAnExpiredRunIsWithdrawn() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        var held = false
        let refresh = service(link, store: store, flushes: { flushes.append($0) }, pause: {
            link.transport?.drainSteps(1)
        })
        let gated = HelioBackgroundSyncService(
            link: refresh.link, keyStore: refresh.keyStore, observability: refresh.observability, flush: refresh.flush,
            now: refresh.now,
            pause: {
                for _ in 0..<100_000 where held { await Task.yield() }
                await refresh.pause()
            },
            grace: refresh.grace, appIsActive: refresh.appIsActive)
        let processing = waitingService(link, store: store, flushes: { flushes.append($0) })
        let a = Task { @MainActor in await gated.run(kind: .appRefresh, timeout: 3600) }
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        held = true
        let b = Task { @MainActor in await processing.run(kind: .processing, timeout: 7200) }
        for _ in 0..<2000 where link.activeRun?.handOverTo == nil { await Task.yield() }
        XCTAssertEqual(link.activeRun?.handOverTo, .processing)
        b.cancel()
        let waited = await b.value
        XCTAssertEqual(waited.ending, .expired)
        XCTAssertNil(link.activeRun?.handOverTo, "withdrawn")
        held = false
        let first = await a.value
        XCTAssertEqual(first.ending, .synced, "nobody to hand it to: the active run kept its sync")
        XCTAssertEqual(flushes.count, 1)
        XCTAssertEqual(link.hookFlushes, 0)
    }

    func testAnExpiryDuringTheTeardownGraceSkipsTheFlush() async throws {
        // Review-225 N4: the budget ran out (abandon + grace), and iOS expires the task inside the
        // grace. No Health flush may follow.
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let base = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(2) })
        let expiringInGrace = HelioBackgroundSyncService(
            link: base.link, keyStore: base.keyStore, observability: base.observability, flush: base.flush,
            now: base.now, pause: base.pause,
            grace: { withUnsafeCurrentTask { $0?.cancel() } },
            appIsActive: base.appIsActive)
        let run = await Task { @MainActor in
            await expiringInGrace.run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        }.value
        XCTAssertEqual(run.ending, .expired)
        XCTAssertEqual(link.disconnects, 1)
        XCTAssertTrue(flushes.isEmpty, "no flush after iOS ended the task")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    /// Review-225b N-a, from the reviewer's real-budget probe: the Sleep Focus run (28 s) arrives while a
    /// processing run (150 s) holds the strap. Since #233 it coalesces at once (it used to wait out its
    /// window) and leaves its finalization for the processing run's flush, which uses it once.
    func testAFocusRunThatNeverGetsATurnStillFinalizesTheNightWithRealBudgets() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let refresh = service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drainSteps(1) })
        // The Focus run only waits: it must not move the shared fake clock itself (review-225c F-1).
        let focus = waitingService(link, store: store, flushes: { flushes.append($0) })
        let a = Task { @MainActor in await refresh.run(kind: .processing, timeout: RingBackgroundSyncService.processingTimeout) }
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let b = Task { @MainActor in
            await focus.run(kind: .sleepFocus, timeout: RingBackgroundSyncService.defaultTimeout, nightsFinalized: self.clock)
        }
        let bgTask = await a.value
        let sleepFocus = await b.value
        XCTAssertEqual(bgTask.ending, .synced)
        XCTAssertEqual(sleepFocus.ending, .coalesced(into: .processing))
        XCTAssertTrue(sleepFocus.success, "a coalesced task is not a failure")
        XCTAssertEqual(flushes.count, 1, "only the processing run flushed")
        XCTAssertEqual(flushes.first?.finalized, true, "with the Focus run's finalization")
        XCTAssertEqual(flushes.first?.nights, 1)
        XCTAssertNil(link.pendingNightsFinalization, "used once")

        // A later run doesn't inherit it.
        let later = await service(link, store: store, flushes: { flushes.append($0) }, pause: { link.transport?.drain() })
            .run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(later.ending, .synced)
        XCTAssertEqual(flushes.map(\.finalized), [true, false])
    }

    /// Review-225b N-c: a run waiting for its turn that iOS expires is an expiry: logged as one, with no
    /// teardown claimed (it touched nothing), and the active run carries on.
    func testAWaitingRunThatIOSExpiresEndsAsExpiredAndTouchesNothing() async throws {
        let store = try makeStore()
        let device = makeStrap()
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let active = service(link, store: store, pause: { link.transport?.drainSteps(1) })
        // Only waits: it must not move the shared fake clock itself (review-225c F-1).
        let waiting = waitingService(link, store: store)
        let a = Task { @MainActor in await active.run(kind: .processing, timeout: 3600) }
        for _ in 0..<2000 where link.activeBackgroundRuns == 0 { await Task.yield() }
        let b = Task { @MainActor in await waiting.run(kind: .appRefresh, timeout: 3600) }
        b.cancel()   // since #233 a waiter decides at its first look, so iOS expires it before that
        let waited = await b.value
        XCTAssertEqual(waited.ending, .expired)
        XCTAssertFalse(waited.disconnected)
        XCTAssertEqual(waited.detail, "helio strap: iOS ended the task")
        XCTAssertEqual(link.disconnects, 0)
        let first = await a.value
        XCTAssertEqual(first.ending, .synced)
        XCTAssertEqual(link.activeBackgroundRuns, 0)
    }

    func testAStrapOutOfRangeKeepsThePendingConnectArmed() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        link.inRange = false
        let run = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(run.ending, .outOfTime)
        XCTAssertEqual(link.connects, 1, "one connect, no retry loop")
        XCTAssertEqual(link.disconnects, 0, "nothing to disconnect; the standing connect stays for restoration")
        XCTAssertTrue(try rows(store).isEmpty)
    }

    func testInTheBackgroundAStuckAckEndsWithTheBudgetAndTheNextRunSyncs() async throws {
        // review-223 U1 in a background task: the budget trips long before the 90 s stall timeout.
        let store = try makeStore()
        let device = makeStrap()
        device.announcedLengths[.autoStress] = 4 << 20
        device.unansweredAckTypes = [.autoStress]
        let link = FakeBackgroundLink(device: device, keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        let stuck = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(stuck.ending, .outOfTime)
        XCTAssertEqual(link.disconnects, 1, "disconnected cleanly")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
        XCTAssertGreaterThan(try rows(store).count, 0, "what was committed before the stuck round stays")

        device.unansweredAckTypes = []
        device.announcedLengths = [:]
        clock = clock.addingTimeInterval(600)
        let next = await service(link, store: store).run(kind: .appRefresh, timeout: RingBackgroundSyncService.defaultTimeout)
        XCTAssertEqual(next.ending, .synced)
        XCTAssertEqual(next.result?.interrupted, false)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    // MARK: rejected / missing key, busy strap → no retry, no writes, a logged reason

    func testAMissingOrRejectedKeyEndsTheRunBeforeAnyRadioWork() async throws {
        let store = try makeStore()
        var flushes: [FlushCall] = []

        let noKey = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(nil), store: store, clock: { [unowned self] in self.clock })
        let first = await service(noKey, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(first.ending, .keyNeeded)
        XCTAssertEqual(noKey.connects, 0, "no connect, so no central is created")
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: key needed") == true)
        XCTAssertEqual(lastRecord()?.success, false)

        let keys = MemoryKeyStore(keyHex)
        keys.markRejected()
        let rejected = FakeBackgroundLink(device: makeStrap(), keyStore: keys, store: store, clock: { [unowned self] in self.clock })
        let second = await service(rejected, store: store, flushes: { flushes.append($0) }).run(kind: .processing, timeout: 150)
        XCTAssertEqual(second.ending, .keyRejected)
        XCTAssertEqual(rejected.connects, 0)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: key rejected") == true)

        let noStrap = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        noStrap.strapID = nil
        let third = await service(noStrap, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(third.ending, .noSavedStrap)
        XCTAssertEqual(noStrap.connects, 0)

        XCTAssertTrue(flushes.isEmpty, "no Health writes")
        XCTAssertTrue(try rows(store).isEmpty, "no store writes")
    }

    func testAKeyTheStrapRejectsInTheBackgroundIsNotRetried() async throws {
        let store = try makeStore()
        let device = makeStrap(authKey: "ffeeddccbbaa99887766554433221100")
        let keys = MemoryKeyStore(keyHex)
        let link = FakeBackgroundLink(device: device, keyStore: keys, store: store, clock: { [unowned self] in self.clock })
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(run.ending, .keyRejected)
        XCTAssertTrue(keys.isRejected, "decision 7: marked, so no later run tries it")
        XCTAssertEqual(link.connects, 1)
        XCTAssertEqual(link.disconnects, 1, "the link is dropped, not left retrying")
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, 2, "one 04 and one 05, once")

        let again = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(again.ending, .keyRejected)
        XCTAssertEqual(link.connects, 1, "no retry")
        XCTAssertEqual(device.receivedEndpoints.filter { $0 == 0x0082 }.count, 2)
        XCTAssertTrue(flushes.isEmpty)
        XCTAssertTrue(try rows(store).isEmpty)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: key rejected") == true)
    }

    func testABusyStrapEndsTheRunAndIsNotRetried() async throws {
        let store = try makeStore()
        let link = FakeBackgroundLink(device: makeStrap(), keyStore: MemoryKeyStore(keyHex), store: store, clock: { [unowned self] in self.clock })
        link.silent = true
        var flushes: [FlushCall] = []
        let run = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(run.ending, .strapBusy, "no auth reply within 10 s")
        XCTAssertTrue(link.endedBusy)
        XCTAssertEqual(link.disconnects, 1)
        let again = await service(link, store: store, flushes: { flushes.append($0) }).run(kind: .appRefresh, timeout: 28)
        XCTAssertEqual(again.ending, .strapBusy)
        XCTAssertEqual(link.connects, 1, "no retry loop")
        XCTAssertTrue(flushes.isEmpty)
        XCTAssertTrue(lastRecord()?.detail?.hasPrefix("helio strap: strap busy") == true)
    }

    // MARK: one device at a time (decision 1)

    func testABackgroundWakeRunsOnlyTheChosenDevicesDrain() throws {
        XCTAssertEqual(BackgroundDrain(.ringConn), .ring)
        XCTAssertEqual(BackgroundDrain(.helioStrap), .strap)
        XCTAssertEqual(BackgroundDrain(ActiveDeviceChoiceStore.persisted(defaults)), .ring,
                       "nothing chosen: the ring, as for every existing user")
    }

    func testWithTheRingChosenTheStrapsConnectionCreatesNoCentral() throws {
        // The live connection reads the process-wide choice; this test sets it and restores it.
        let standard = UserDefaults.standard
        let savedChoice = standard.object(forKey: ActiveDeviceChoiceStore.key)
        let savedStrap = standard.object(forKey: HelioConnection.savedPeripheralKey)
        defer {
            standard.set(savedChoice, forKey: ActiveDeviceChoiceStore.key)
            standard.set(savedStrap, forKey: HelioConnection.savedPeripheralKey)
        }
        standard.set(ActiveDeviceChoice.ringConn.rawValue, forKey: ActiveDeviceChoiceStore.key)
        standard.set("5B1E4C2A-0000-4000-8000-0000000000D4", forKey: HelioConnection.savedPeripheralKey)

        let connection = HelioConnection(keyStore: MemoryKeyStore(keyHex))
        XCTAssertFalse(connection.connectForBackground(), "the strap isn't the chosen device")
        XCTAssertFalse(connection.hasCentral, "so its central is never created")
        XCTAssertNil(connection.session)
    }
}

/// What the app asked iOS for (decision 57b's margin refresh, background half).
private final class BackgroundMarginRecorder: BGTaskScheduling {
    private(set) var submitted: BGTaskRequest?
    func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool { true }
    func cancel(taskRequestWithIdentifier identifier: String) {}
    func submit(_ taskRequest: BGTaskRequest) throws { submitted = taskRequest }
}
