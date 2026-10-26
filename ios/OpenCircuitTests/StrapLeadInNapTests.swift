import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 77j (#328, at the merge with #329): nearness is measured from a strap night's SLEEP, never its
// in-bed lead-in. 76l's prune, `saveNap`'s overlap backstop and the nap judgement all use the night's
// window without the lead-in, and the lead-in stops at the end of every nap (77c), the same sync's
// block-nap candidates included. So a lead-in can end at a nap's end without pruning it, and the result
// doesn't depend on whether the nap or the night was stored first. Through the production path (the
// sink and a fake strap). Every key, reading and time is synthetic.

private let jMidnight: TimeInterval = 1_789_862_400          // 2026-09-20T00:00:00Z
private let jNow = Date(timeIntervalSince1970: jMidnight + 12 * 3600)
private let jKeyHex = "00112233445566778899aabbccddeeff"
/// Local hour `h` of the test day (fixed zone); negative is the evening before.
private func hour(_ h: Double) -> Date { Calendar.current.startOfDay(for: jNow).addingTimeInterval(h * 3600) }
private func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: hour(from), end: hour(to)) }

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

private let light: UInt8 = 0x04
private let asleepKind = ZeppActivityMinute.kindSleep, upKind: UInt8 = 0x01

/// One strap sleep session record over local hours of `hour(0)`'s day (stage end minutes inclusive).
private func sessionRecord(_ stages: [(Double, Double, UInt8)]) -> [UInt8] {
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

/// The evening nap's record, 19:30–20:30, and the night's, asleep from 22:00 to 07:00.
private let eveningNap: [(Double, Double, UInt8)] = [(-4.5, -3.5, light)]
private let nightRecord: [(Double, Double, UInt8)] = [(-2, 7, light)]
/// The night re-delivered `minutes` wider at its start.
private func widerNight(_ minutes: Double) -> [(Double, Double, UInt8)] { [(-2 - minutes / 60, 7, light)] }

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

@MainActor
private final class NapTransport: HelioTransport {
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
private final class NapKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(jKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
final class StrapLeadInNapTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = jNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D07A"
    private var savedZone = NSTimeZone.default

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        clearDefaults()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        clearDefaults()
        NSTimeZone.default = savedZone
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: LocalStore.prunedNapHealthSpansKey)
        for day in -3...2 {
            let key = Calendar.current.startOfDay(for: hour(Double(day) * 24))
            UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(key.timeIntervalSince1970)")
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

    /// One strap sync at local hour `now` delivering each of `sessions` as a record, and the activity
    /// minutes `activity` (spans of local hours: kind; heart rate 58, no steps), through the production path.
    @discardableResult
    private func sync(_ sessions: [[(Double, Double, UInt8)]], activity: [(Double, Double, UInt8)] = [],
                      at now: Double, store: LocalStore) throws -> HelioSyncResult {
        clock = hour(now)
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(jKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = services
        device.deviceInfoReply = deviceInfoReply
        device.dataPacketLength = 200
        device.fetchData = [.sleepSession: (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(sessionRecord))]
        if let first = activity.first {
            let bytes = activity.flatMap { span in
                (0..<Int(((span.1 - span.0) * 60).rounded())).flatMap { _ in [span.2, 0x08, 0, 58, 0, 0, 0, 0] as [UInt8] }
            }
            device.fetchData[.activity] = (stamp(hour(first.0).timeIntervalSince1970), bytes)
        }
        let transport = NapTransport(device: device)
        let keys = NapKeys()
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

    /// The strap's calm heart rate (58 bpm, a reading a minute) over local hours `from ..< to`, stored.
    private func storeHeartRate(_ from: Double, _ to: Double, store: LocalStore) throws {
        for t in stride(from: hour(from).timeIntervalSince1970, to: hour(to).timeIntervalSince1970, by: 60) {
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: Date(timeIntervalSince1970: t),
                                              end: Date(timeIntervalSince1970: t), value: 58, deviceID: timeline.rawValue))
        }
        try store.context.save()
    }

    private func naps(_ store: LocalStore) throws -> [DateInterval] {
        try store.context.fetch(FetchDescriptor<StoredNap>(sortBy: [SortDescriptor(\.start)])).map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func nights(_ store: LocalStore) throws -> [StoredSleepSummary] {
        try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.inBedStart)]))
    }

    private func leadIn(_ store: LocalStore) throws -> DateInterval? {
        HelioSleepSelection.leadIn(in: SleepHypnogramCodec.decode(try XCTUnwrap(try nights(store).first).hypnogramData))
    }

    private var scheduledCleans: [[Double]] {
        UserDefaults.standard.array(forKey: LocalStore.prunedNapHealthSpansKey) as? [[Double]] ?? []
    }

    // MARK: The evening nap

    /// The review's shape: a nap 19:30–20:30 stored (and written to Health) by an evening sync; the
    /// record, asleep from 22:00 (90 min after the nap), with calm heart rate from 20:30. After the
    /// record's sync the nap is still a nap, the lead-in starts at the nap's end, and no Health clean is
    /// scheduled.
    func testALeadInEndingAtAnEveningNapKeepsTheNapAndSchedulesNoClean() throws {
        let store = try makeStore()
        try storeHeartRate(-3.5, 7, store: store)
        try sync([eveningNap], at: -2.25, store: store)
        XCTAssertEqual(try naps(store), [span(-4.5, -3.5)], "stored by the evening sync")
        try store.markNapWritten(start: hour(-4.5))

        let morning = try sync([eveningNap, nightRecord], at: 7.5, store: store)
        XCTAssertEqual(morning.nights.map(\.windowWithoutLeadIn), [span(-2, 7)])
        XCTAssertEqual(try leadIn(store), span(-3.5, -2), "the lead-in starts at the nap's end")
        XCTAssertEqual(try naps(store), [span(-4.5, -3.5)], "still a nap: 90 min from the night's sleep")
        XCTAssertEqual(scheduledCleans, [], "no Health clean")
    }

    /// A nap that really is within 60 min of the night's SLEEP (20:30–21:20, 40 min before 22:00) is
    /// pruned when the record is stored, and its Health write is scheduled for the clean (76l, merged tree).
    func testANapWithinAnHourOfTheNightsSleepIsStillPruned() throws {
        let store = try makeStore()
        try storeHeartRate(-3.5, 7, store: store)
        try store.saveNap(start: hour(-3.5), end: hour(-2 - 40.0 / 60), asleepMin: 50, isLongNap: false, family: .zeppOS)
        try store.markNapWritten(start: hour(-3.5))
        try sync([nightRecord], at: 7.5, store: store)
        XCTAssertEqual(try naps(store), [], "pruned")
        XCTAssertEqual(scheduledCleans, [[hour(-3.5).timeIntervalSince1970, hour(-2 - 40.0 / 60).timeIntervalSince1970]],
                       "its written span is scheduled")
        XCTAssertEqual(try leadIn(store), span(-2 - 40.0 / 60, -2), "the lead-in stopped at its end before the prune")
    }

    // MARK: Order independence

    /// The same day, the nap delivered before the night and after it, then the night re-delivered 10,
    /// 30, 60 or 90 min wider at its start: the final state (the night's row and hypnogram, the naps)
    /// is identical. Wider by 30 min or more, the night's sleep starts 60 min or less after the nap and
    /// the nap is pruned in both orders; by 10 min it stays a nap and the lead-in stops at its end.
    func testTheFinalStateDoesNotDependOnWhetherTheNapOrTheNightCameFirst() throws {
        for wider in [10.0, 30, 60, 90] {
            func finalState(napFirst: Bool) throws -> (night: DateInterval, hypnogram: Data, naps: [DateInterval]) {
                clearDefaults()
                let store = try makeStore()
                try storeHeartRate(-5, 8, store: store)
                if napFirst {
                    try sync([eveningNap], at: -2.25, store: store)
                    try sync([eveningNap, nightRecord], at: 7.5, store: store)
                } else {
                    try sync([nightRecord], at: 7.5, store: store)
                    try sync([eveningNap, nightRecord], at: 7.75, store: store)
                }
                try sync([eveningNap, widerNight(wider)], at: 8, store: store)
                let row = try XCTUnwrap(try nights(store).first)
                return (DateInterval(start: row.inBedStart, end: row.inBedEnd), row.hypnogramData, try naps(store))
            }
            let first = try finalState(napFirst: true), after = try finalState(napFirst: false)
            XCTAssertEqual(first.night, after.night, "wider by \(wider) min")
            XCTAssertEqual(first.hypnogram, after.hypnogram, "wider by \(wider) min")
            XCTAssertEqual(first.naps, after.naps, "wider by \(wider) min")
            let sleepStart = hour(-2 - wider / 60)
            if sleepStart.timeIntervalSince(hour(-3.5)) > HelioSleepSelection.napGap {
                XCTAssertEqual(first.naps, [span(-4.5, -3.5)], "wider by \(wider) min: still a nap")
                XCTAssertEqual(first.night.start, hour(-3.5), "wider by \(wider) min: the lead-in starts at the nap's end")
            } else {
                XCTAssertEqual(first.naps, [], "wider by \(wider) min: within the hour of the sleep, pruned")
            }
        }
    }

    // MARK: A block nap in the same sync

    /// A doze the strap marks only in its activity minutes (19:30–20:30, a block nap candidate), awake
    /// with calm heart rate to 22:00, and the night's record in the SAME sync: the lead-in stops at the
    /// block's end and the block is stored as a nap, counted once.
    func testTheLeadInStopsAtABlockNapInTheSameSyncWhichIsStoredOnce() throws {
        let store = try makeStore()
        let activity: [(Double, Double, UInt8)] = [(-5, -4.5, upKind), (-4.5, -3.5, asleepKind), (-3.5, -2, upKind),
                                                   (-2, 7, asleepKind), (7, 7.5, upKind)]
        let result = try sync([nightRecord], activity: activity, at: 7.5, store: store)
        XCTAssertEqual(try leadIn(store), span(-3.5, -2), "the lead-in stops at the block's end")
        XCTAssertEqual(try naps(store), [span(-4.5, -3.5)])
        XCTAssertEqual(result.sleepRound?.napsFromBlocks, 1)
        let again = try sync([nightRecord], activity: activity, at: 8, store: store)
        XCTAssertEqual(again.sleepRound?.napsFromBlocks ?? 0, 0, "counted once")
        XCTAssertEqual(try naps(store), [span(-4.5, -3.5)])
        XCTAssertEqual(try leadIn(store), span(-3.5, -2))
    }

    // MARK: S3 (#329 review): 76l's prune on an UPDATE of a stored night

    /// A nap 19:50–20:50, 70 min before a stored night (22:00). The night re-delivered wider so its sleep
    /// starts 30 min after the nap's end (21:20): the UPDATE prunes the nap and schedules its written
    /// span. Re-delivered wider at the end only: the nap stays.
    func testANightUpdatedToStartWithinTheHourOfANapPrunesItAndWiderAtTheEndKeepsIt() throws {
        let cases: [(String, [(Double, Double, UInt8)], Bool)] = [("start 30 min after the nap", [(-2 - 40.0 / 60, 7, light)], true),
                                                                   ("wider at the end only", [(-2, 7.5, light)], false)]
        for (label, update, pruned) in cases {
            clearDefaults()
            let store = try makeStore()
            try sync([nightRecord], at: 7.25, store: store)
            try store.saveNap(start: hour(-4 - 10.0 / 60), end: hour(-3 - 10.0 / 60), asleepMin: 60, isLongNap: false,
                              family: .zeppOS)
            try store.markNapWritten(start: hour(-4 - 10.0 / 60))
            XCTAssertEqual(try naps(store).count, 1, "\(label): stored 70 min before the night")
            try sync([update], at: 8, store: store)
            XCTAssertEqual(try nights(store).count, 1, label)
            XCTAssertEqual(try XCTUnwrap(try nights(store).first).inBedEnd, hour(update[0].1), "\(label): the update was stored")
            if pruned {
                XCTAssertEqual(try naps(store), [], label)
                XCTAssertEqual(scheduledCleans, [[hour(-4 - 10.0 / 60).timeIntervalSince1970, hour(-3 - 10.0 / 60).timeIntervalSince1970]],
                               "\(label): its written span is scheduled")
            } else {
                XCTAssertEqual(try naps(store).count, 1, label)
                XCTAssertEqual(scheduledCleans, [], label)
            }
        }
    }
}
