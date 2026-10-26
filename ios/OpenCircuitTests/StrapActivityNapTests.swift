import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 76 (#327): a daytime nap the strap marks only in its activity minutes (kind `0x78`, no `0x48`
// record) is stored as a strap nap. Every sync here goes through the production path (`HelioSession` →
// `HelioStoreSink`) against the fake strap. Every key, id, minute and time is synthetic and rounded.

// MARK: - Fixtures

private let nMidnight: TimeInterval = 1_789_862_400          // 2026-09-20T00:00:00Z
private let nNow = Date(timeIntervalSince1970: nMidnight + 12 * 3600)
private let nKeyHex = "00112233445566778899aabbccddeeff"
/// Local hour `h` of the test day (fixed zone, `inFixedZone`); negative is the evening before.
private func hour(_ h: Double) -> Date { Calendar.current.startOfDay(for: nNow).addingTimeInterval(h * 3600) }
private func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: hour(from), end: hour(to)) }

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

private let light: UInt8 = 0x04
private let asleepKind = ZeppActivityMinute.kindSleep, upKind: UInt8 = 0x01

/// One strap sleep session record over local hours of `hour(0)`'s day (minute fields count from the
/// previous local midnight, `ZeppSleepSession.absolute`).
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

/// Last night's record, 23:00–07:00.
private let lastNight: [(Double, Double, UInt8)] = [(-1, 7, light)]

/// Contiguous activity minutes from local hour `from` until `until`: kind sleep over `asleep`, an
/// ordinary kind everywhere else.
private func minutes(asleep: [(Double, Double)], from: Double, until: Double) -> [(Double, Double, UInt8)] {
    var out: [(Double, Double, UInt8)] = []
    var t = from
    for s in asleep.sorted(by: { $0.0 < $1.0 }) where s.0 < until && s.1 > t {
        if s.0 > t { out.append((t, s.0, upKind)) }
        out.append((max(s.0, t), min(s.1, until), asleepKind))
        t = min(s.1, until)
    }
    if t < until { out.append((t, until, upKind)) }
    return out
}

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

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
    func load() -> ZeppAuthKey? { HelioKeyText.parse(nKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class StrapActivityNapTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = nNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D076"
    private var observabilitySuite = ""
    private var observability = ObservabilityStore()

    override func setUp() {
        super.setUp()
        observabilitySuite = "StrapActivityNapTests.observability.\(UUID().uuidString)"
        observability = ObservabilityStore(UserDefaults(suiteName: observabilitySuite)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: observabilitySuite)
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

    private var timeline: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }

    /// Runs `body` with local times in a fixed zone (New York), and clears the mirror records it may leave.
    private func inFixedZone(_ body: () throws -> Void) throws {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let nights = (-2...2).map { hour(Double($0) * 24) }
        func clear() {
            for night in nights {
                UserDefaults.standard.removeObject(forKey: "sleep.mirror.night.\(Calendar.current.startOfDay(for: night).timeIntervalSince1970)")
            }
        }
        clear()
        defer {
            clear()
            NSTimeZone.default = saved
        }
        try body()
    }

    /// One strap sync at local hour `now` delivering each of `sessions` as a session record and the
    /// activity minutes `activity`, through the production path. The sync's result.
    @discardableResult
    private func sync(_ sessions: [[(Double, Double, UInt8)]] = [lastNight], activity: [(Double, Double, UInt8)],
                      at now: Double, store: LocalStore) throws -> HelioSyncResult {
        clock = hour(now)
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(nKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = services
        device.deviceInfoReply = deviceInfoReply
        device.dataPacketLength = 200
        device.fetchData = [.sleepSession: (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(sessionRecord))]
        if let first = activity.first {
            let bytes = activity.flatMap { span in
                (0..<Int(((span.1 - span.0) * 60).rounded())).flatMap { _ in [span.2, 0x08, 0, 55, 0, 0, 0, 0] as [UInt8] }
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

    /// Last night (record and its sleep minutes from 23:00) and the day's sleep minutes `asleep`, up to `until`.
    private func day(asleep: [(Double, Double)], until: Double, from: Double = -1) -> [(Double, Double, UInt8)] {
        minutes(asleep: [(-1, 7)].filter { $0.1 > from } + asleep, from: from, until: until)
    }

    private func napRows(_ store: LocalStore) throws -> [StoredNap] {
        try store.context.fetch(FetchDescriptor<StoredNap>(sortBy: [SortDescriptor(\.start)]))
    }

    private func napWindows(_ store: LocalStore) throws -> [DateInterval] {
        try napRows(store).map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func nightWindows(_ store: LocalStore) throws -> [DateInterval] {
        try store.context.fetch(FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.inBedStart)]))
            .map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }
    }

    private func pendingNapWindows(_ store: LocalStore) throws -> [DateInterval] {
        try store.pendingNaps().map { DateInterval(start: $0.start, end: $0.end) }
    }

    // MARK: 76b/76c: a standalone daytime block is a nap

    /// A daytime block of 30, 45, 90 or 150 min, hours after the night: one nap row, the strap's, with
    /// one `.inBed` over the block and its minutes as generic sleep; it reaches the nap flush; later
    /// syncs that re-derive it leave that one row exactly as it is and store nothing again.
    func testADaytimeBlockAwayFromTheNightIsOneNapThatReachesTheFlushOnce() throws {
        for minutesLong in [30.0, 45, 90, 150] {
            try inFixedZone {
                let label = "\(Int(minutesLong)) min"
                ownership.install(.strapOwnsAllTime)
                let store = try makeStore()
                let nap = span(13, 13 + minutesLong / 60)
                let end = 13 + minutesLong / 60
                let first = try sync(activity: day(asleep: [(13, end)], until: end + 1.5), at: end + 1.5, store: store)
                XCTAssertEqual(try nightWindows(store), [span(-1, 7)], label)
                XCTAssertEqual(try napWindows(store), [nap], label)
                let row = try XCTUnwrap(try napRows(store).first)
                XCTAssertEqual(row.asleepMin, Int(minutesLong), label)
                XCTAssertFalse(row.isLongNap, label)
                XCTAssertEqual(row.stagedSegments?.map(\.stage), [.inBed, HelioSleepSelection.activityBlockStage], label)
                XCTAssertEqual(row.stagedSegments?.map { DateInterval(start: $0.start, end: $0.end) }, [nap, nap], label)
                XCTAssertEqual(try pendingNapWindows(store), [nap], "\(label): offered to the nap flush")
                XCTAssertEqual(first.sleepRound?.activityBlocksAlone, 1, label)
                XCTAssertEqual(first.sleepRound?.napsFromBlocks, 1, label)
                let firstUpdate = row.updatedAt
                try store.markNapWritten(start: nap.start)

                for later in [end + 2.5, end + 5] {
                    let again = try sync(activity: day(asleep: [(13, end)], until: later), at: later, store: store)
                    XCTAssertEqual(try napWindows(store), [nap], "\(label): one row")
                    XCTAssertEqual(try pendingNapWindows(store), [], "\(label): written once")
                    XCTAssertEqual(again.sleepRound?.napsFromBlocks, 0, "\(label): nothing stored again")
                    XCTAssertEqual(try napRows(store).first?.updatedAt, firstUpdate, "\(label): the row is left as it is")
                }
            }
        }
    }

    /// Decision 76c: an awake gap of up to 5 min inside the block stays a gap (no segment), inside the
    /// one `.inBed` envelope; the sleep minutes on either side are counted, the gap isn't.
    func testAShortAwakeGapInsideTheBlockStaysAGapInTheNap() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            try sync(activity: day(asleep: [(13, 13 + 40.0 / 60), (13 + 44.0 / 60, 14.5)], until: 16), at: 16, store: store)
            let row = try XCTUnwrap(try napRows(store).first)
            XCTAssertEqual(try napWindows(store), [span(13, 14.5)])
            XCTAssertEqual(row.stagedSegments?.map { DateInterval(start: $0.start, end: $0.end) },
                           [span(13, 14.5), span(13, 13 + 40.0 / 60), span(13 + 44.0 / 60, 14.5)])
            XCTAssertEqual(row.asleepMin, 40 + 46)
        }
    }

    /// The owner's day (decision 76's evidence): last night's record and a daytime block of sleep
    /// minutes. On master the line read `naps: stored=0`; now the nap is stored and said so.
    func testAnOwnerShapedDayStoresItsDaytimeNapAndSaysSo() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let result = try sync(activity: day(asleep: [(14, 14.75)], until: 17), at: 17, store: store)
            XCTAssertEqual(try napWindows(store), [span(14, 14.75)])
            let line = try XCTUnwrap(result.sleepRound?.text)
            XCTAssertTrue(line.contains("naps: stored=1 unsettled=0 tooShort=0 napsFromBlocks=1; "), line)
            XCTAssertTrue(line.hasSuffix("; activity blocks: joined=0 alone=1"), line)
            XCTAssertNil(line.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression), line)
        }
    }

    // MARK: 76b: what is no nap

    /// Under 20 minutes of sleep minutes is no block, so no nap and nothing counted.
    func testABlockUnderTwentyMinutesIsNoNap() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let result = try sync(activity: day(asleep: [(13, 13.25)], until: 15), at: 15, store: store)
            XCTAssertEqual(try napWindows(store), [])
            XCTAssertEqual(result.sleepRound?.activityBlocksAlone, 0)
        }
    }

    /// Decision 73d, then the nap's own settle: a block still going on is not used; one that ended less
    /// than an hour ago is an unsettled nap; a later sync stores it.
    func testABlockStillGoingOnOrEndedUnderAnHourAgoIsANapOnlyOnALaterSync() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let during = try sync(activity: day(asleep: [(13, 14 + 10.0 / 60)], until: 14 + 10.0 / 60), at: 14 + 10.0 / 60, store: store)
            XCTAssertEqual(try napWindows(store), [], "still going on")
            XCTAssertEqual(during.sleepRound?.activityBlocksAlone, 0)

            let justEnded = try sync(activity: day(asleep: [(13, 14)], until: 14.5), at: 14.5, store: store)
            XCTAssertEqual(try napWindows(store), [], "ended half an hour ago")
            XCTAssertEqual(justEnded.sleepRound?.napsUnsettled, 1)

            let settled = try sync(activity: day(asleep: [(13, 14)], until: 15 + 5.0 / 60), at: 15 + 5.0 / 60, store: store)
            XCTAssertEqual(try napWindows(store), [span(13, 14)])
            XCTAssertEqual(settled.sleepRound?.napsFromBlocks, 1)
        }
    }

    /// Decision 76e: a block within an hour after the night's last record joins the night (73, 28f), so a
    /// sleep-in after waking is the night's, not a nap.
    func testABlockWithinAnHourAfterTheNightJoinsItAndIsNoNap() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let result = try sync(activity: day(asleep: [(7.5, 8.5)], until: 10), at: 10, store: store)
            XCTAssertEqual(try napWindows(store), [])
            XCTAssertEqual(try nightWindows(store), [span(-1, 8.5)])
            XCTAssertEqual(result.sleepRound?.activityBlocksJoined, 1)
            XCTAssertEqual(result.sleepRound?.napsFromBlocks, 0)
        }
    }

    /// A block within an hour BEFORE the night's record (a doze 22:00–22:40) is never a lead-in (73f), so
    /// it stands alone; judged as a nap, it lies 20 min from the stored night and belongs to it (§21.5
    /// step 3): no nap, nothing stored for it.
    func testABlockWithinAnHourBeforeTheNightBelongsToItAndIsNoNap() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let result = try sync(activity: minutes(asleep: [(-2, -1 - 20.0 / 60), (-1, 7)], from: -2, until: 10), at: 10, store: store)
            XCTAssertEqual(try napWindows(store), [])
            XCTAssertEqual(try nightWindows(store), [span(-1, 7)])
            XCTAssertEqual(result.sleepRound?.activityBlocksAlone, 1)
            XCTAssertEqual(result.sleepRound?.napsFromBlocks, 0)
        }
    }

    /// 28f's stitch in the nap split: two blocks 40 min apart are one nap (both `.inBed` envelopes, the
    /// gap a gap); two 3 h apart are two.
    func testTwoBlocksFortyMinutesApartAreOneNapAndThreeHoursApartAreTwo() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let close = try sync(activity: day(asleep: [(13, 13.5), (14 + 10.0 / 60, 14 + 40.0 / 60)], until: 16), at: 16, store: store)
            XCTAssertEqual(try napWindows(store), [span(13, 14 + 40.0 / 60)])
            XCTAssertEqual(try napRows(store).first?.asleepMin, 60)
            XCTAssertEqual(close.sleepRound?.napsFromBlocks, 1)

            let apart = try makeStore()
            let far = try sync(activity: day(asleep: [(13, 13.5), (16.5, 17)], until: 18.5), at: 18.5, store: apart)
            XCTAssertEqual(try napWindows(apart), [span(13, 13.5), span(16.5, 17)])
            XCTAssertEqual(far.sleepRound?.napsFromBlocks, 2)
        }
    }

    /// Decision 76b: a block inside 00:00–08:00 on a night no stored night covers (the strap's only
    /// record is the next night's) is that night's provisional main sleep: no nap, no night, counted.
    func testABlockThatIsTheMainSleepOfANightWithNoRecordIsStoredNowhereAndCounted() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let result = try sync([[(23, 31, light)]], activity: minutes(asleep: [(-1, 6), (23, 31)], from: -1, until: 32),
                                  at: 32, store: store)
            XCTAssertEqual(try nightWindows(store), [span(23, 31)], "only the night with a record")
            XCTAssertEqual(try napWindows(store), [])
            XCTAssertEqual(result.sleepRound?.mainOnlyBlocks, 1)
            let line = try XCTUnwrap(result.sleepRound?.text)
            XCTAssertTrue(line.contains("naps: stored=0 unsettled=0 tooShort=0 mainOnlyBlocks=1; "), line)
        }
    }

    // MARK: 76h (review-327 B1): a nap waits while sleep follows it within the hour

    /// The review's repro: a doze 22:00–22:40, tonight's sleep minutes from 23:00. A sync at 23:50 sees
    /// the night still going on (73d keeps its minutes out of the blocks) and no record yet: the doze
    /// waits (unsettled), no nap. The morning sync stores the night, and the doze is 20 min before it:
    /// no nap. Control: the same minutes with the morning sync only give no nap either.
    func testADozeWithinAnHourBeforeTheNightIsNoNapWhenASyncRunsWhileTheNightGoesOn() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let doze = (22.0, 22 + 40.0 / 60)
            let store = try makeStore()
            let during = try sync(activity: day(asleep: [doze, (23, 23 + 50.0 / 60)], until: 23 + 50.0 / 60),
                                  at: 23 + 50.0 / 60, store: store)
            XCTAssertEqual(try napWindows(store), [], "the night goes on within the hour after the doze")
            XCTAssertEqual(during.sleepRound?.napsUnsettled, 1, "judged again later")
            XCTAssertEqual(during.sleepRound?.napsFromBlocks, 0)

            let morning = try sync([lastNight, [(23, 31, light)]], activity: day(asleep: [doze, (23, 31)], until: 31.5),
                                   at: 31.5, store: store)
            XCTAssertEqual(try nightWindows(store), [span(-1, 7), span(23, 31)])
            XCTAssertEqual(try napWindows(store), [], "the doze belongs to the night")
            XCTAssertEqual(morning.sleepRound?.napsFromBlocks, 0)

            let control = try makeStore()
            try sync([lastNight, [(23, 31, light)]], activity: day(asleep: [doze, (23, 31)], until: 31.5), at: 31.5, store: control)
            XCTAssertEqual(try nightWindows(control), [span(-1, 7), span(23, 31)])
            XCTAssertEqual(try napWindows(control), [])
        }
    }

    /// The mirror shape: sleep still going on MORE than an hour after a nap doesn't hold it. A nap
    /// 13:00–14:00 is stored by a 15:30 sync whose sleep minutes from 15:05 go on, and by a 22:30 sync
    /// with the evening's sleep from 22:00 going on.
    func testSleepGoingOnMoreThanAnHourAfterANapDoesNotHoldIt() throws {
        for (label, later, at) in [("sleep from 15:05", 15 + 5.0 / 60, 15.5), ("the evening's sleep from 22:00", 22.0, 22.5)] {
            try inFixedZone {
                ownership.install(.strapOwnsAllTime)
                let store = try makeStore()
                let result = try sync(activity: day(asleep: [(13, 14), (later, at)], until: at), at: at, store: store)
                XCTAssertEqual(try napWindows(store), [span(13, 14)], label)
                XCTAssertEqual(result.sleepRound?.napsFromBlocks, 1, label)
            }
        }
    }

    /// A doze 20:00–20:40 with 90 min awake before the night's sleep minutes (from 22:10): a nap, even
    /// while the night goes on; the morning's record (22:10–07:00) stores the night beside it.
    func testADozeNinetyMinutesBeforeTheNightsSleepIsANap() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            let doze = (20.0, 20 + 40.0 / 60), onset = 22 + 10.0 / 60
            let during = try sync(activity: day(asleep: [doze, (onset, 22.5)], until: 22.5), at: 22.5, store: store)
            XCTAssertEqual(try napWindows(store), [span(doze.0, doze.1)])
            XCTAssertEqual(during.sleepRound?.napsFromBlocks, 1)

            try sync([lastNight, [(onset, 31, light)]], activity: day(asleep: [doze, (onset, 31)], until: 31.5), at: 31.5, store: store)
            XCTAssertEqual(try nightWindows(store), [span(-1, 7), span(onset, 31)])
            XCTAssertEqual(try napWindows(store), [span(doze.0, doze.1)], "the nap stays beside the night")
        }
    }

    /// A nap held by sleep minutes that followed it within the hour (12:00–12:40, sleep from 13:20 still
    /// going on at 13:45) is stored once a later sync has no sleep minute within the hour after it (the
    /// strap's minutes for 13:20–13:45 now read awake). And when the sleep that followed finished as a
    /// block (13:20–14:00), the two are one nap, stored once settled.
    func testAHeldNapIsStoredOnceNoSleepFollowsItWithinTheHour() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let doze = (12.0, 12 + 40.0 / 60)
            let store = try makeStore()
            let held = try sync(activity: day(asleep: [doze, (13 + 20.0 / 60, 13.75)], until: 13.75), at: 13.75, store: store)
            XCTAssertEqual(try napWindows(store), [])
            XCTAssertEqual(held.sleepRound?.napsUnsettled, 1)
            let released = try sync(activity: day(asleep: [doze], until: 14.75), at: 14.75, store: store)
            XCTAssertEqual(try napWindows(store), [span(doze.0, doze.1)])
            XCTAssertEqual(released.sleepRound?.napsFromBlocks, 1)

            let finished = try makeStore()
            try sync(activity: day(asleep: [doze, (13 + 20.0 / 60, 14)], until: 15 + 10.0 / 60), at: 15 + 10.0 / 60, store: finished)
            XCTAssertEqual(try napWindows(finished), [span(12, 14)], "one nap over both")
        }
    }

    /// 76h as decided: ANY kind-sleep minute within the hour after the nap holds it, a blip under 20 min
    /// too (13:00–14:00, then 14:30–14:40 asleep), on every sync that fetches that blip. Known gap, in
    /// the report: once the next night's record moves the activity re-fetch past it, the nap is lost.
    func testAShortSleepWithinTheHourAfterANapHoldsItWhileItIsFetched() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            for at in [16.0, 20] {
                let result = try sync(activity: day(asleep: [(13, 14), (14.5, 14 + 40.0 / 60)], until: at), at: at, store: store)
                XCTAssertEqual(try napWindows(store), [], "at \(at)")
                XCTAssertEqual(result.sleepRound?.napsUnsettled, 1, "at \(at)")
            }
        }
    }

    // MARK: 76d: re-derivation

    /// A nap in Apple Health, re-derived by later syncs from fewer minutes (the end, or a fetch that
    /// starts inside it) or with its start a few minutes either way: still one row, as written, and
    /// nothing re-armed for the flush (whose clean would delete what was written).
    func testARederivedNapWithFewerMinutesOrAMovedStartLeavesTheWrittenNapAlone() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            try sync(activity: day(asleep: [(13, 14.5)], until: 16), at: 16, store: store)
            let nap = span(13, 14.5)
            XCTAssertEqual(try napWindows(store), [nap])
            try store.markNapWritten(start: nap.start)
            let shapes: [(String, [(Double, Double, UInt8)])] = [
                ("its last half hour no longer asleep", day(asleep: [(13, 14)], until: 17)),
                ("its start five minutes later", day(asleep: [(13 + 5.0 / 60, 14.5)], until: 17)),
                ("its start five minutes earlier", day(asleep: [(13 - 5.0 / 60, 14.5)], until: 17)),
                ("a fetch that starts inside it", minutes(asleep: [(13, 14.5)], from: 13 + 40.0 / 60, until: 17)),
                ("the same minutes", day(asleep: [(13, 14.5)], until: 17)),
            ]
            for (label, activity) in shapes {
                try sync(activity: activity, at: 17, store: store)
                XCTAssertEqual(try napWindows(store), [nap], label)
                XCTAssertEqual(try pendingNapWindows(store), [], label)
                let row = try XCTUnwrap(try napRows(store).first)
                XCTAssertTrue(row.healthWritten, label)
                XCTAssertEqual(DateInterval(start: row.healthWrittenStart, end: row.healthWrittenEnd), nap, label)
            }
        }
    }

    // MARK: 76e: a nap never displaces a night

    /// An evening doze (20:00–21:00) is stored as a nap at 22:30. The next morning's record starts at
    /// 20:30, overlapping it: the night is stored whole and prunes the nap; the doze's minutes before the
    /// record are no nap again.
    func testANightStoredLaterOverTheNapPrunesItAndKeepsItsWindow() throws {
        try inFixedZone {
            ownership.install(.strapOwnsAllTime)
            let store = try makeStore()
            try sync(activity: day(asleep: [(20, 21)], until: 22.5), at: 22.5, store: store)
            XCTAssertEqual(try napWindows(store), [span(20, 21)])

            try sync([lastNight, [(20.5, 31, light)]], activity: minutes(asleep: [(20, 31)], from: 20, until: 31.5), at: 31.5, store: store)
            XCTAssertEqual(try nightWindows(store), [span(-1, 7), span(20.5, 31)])
            XCTAssertEqual(try napWindows(store), [])
        }
    }

    // MARK: Decision 28: ownership

    /// The ring owns part of the block's time (the strap is chosen, or the ring re-chosen, inside it):
    /// no nap. The strap chosen after the night (the ring keeps the night) still stores the strap's
    /// own daytime nap.
    func testABlockPartlyInTheRingsTimeIsNoNap() throws {
        let cases: [(String, DeviceOwnershipLog, [DateInterval])] = [
            ("the ring re-chosen inside it", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast),
                                                                         .init(family: .ringConn, since: hour(13.75))]), []),
            ("the strap chosen inside it", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(13.5))]), []),
            ("the strap chosen after the night", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(10))]), [span(13, 14)]),
        ]
        for (label, log, naps) in cases {
            try inFixedZone {
                ownership.install(log)
                let store = try makeStore()
                try sync(activity: day(asleep: [(13, 14)], until: 15.5), at: 15.5, store: store)
                XCTAssertEqual(try napWindows(store), naps, label)
                XCTAssertEqual(try pendingNapWindows(store), naps, label)
            }
        }
    }

    /// A ring-only install (no ownership entry): the strap owns nothing, so its blocks are no nap, and
    /// the line is the one decision 72/73 shipped.
    func testOnARingOnlyInstallABlockIsNoNap() throws {
        try inFixedZone {
            ownership.install(DeviceOwnershipLog(entries: []))
            let store = try makeStore()
            let result = try sync(activity: day(asleep: [(13, 14)], until: 15.5), at: 15.5, store: store)
            XCTAssertEqual(try napWindows(store), [])
            XCTAssertEqual(try nightWindows(store), [])
            let line = result.sleepRound?.text ?? ""
            XCTAssertFalse(line.contains("napsFromBlocks"), line)
            XCTAssertFalse(line.contains("mainOnlyBlocks"), line)
        }
    }

    // MARK: 76f: the line

    /// The new counts appear only when non-zero, inside the naps group, digits only; with both zero the
    /// line is byte for byte the one shipped before.
    func testTheNewNapCountsAppearOnlyWhenNonZero() {
        var summary = StrapSleepRoundSummary()
        summary.records = 2
        summary.napsStored = 1
        let before = "sleep round: records=2 staged=0 nights=0 (joined 0) outcomes: inserted=0 updated=0 keptFuller=0 "
            + "ownedByOther=0 keyCollision=0 manualEdit=0 keptOut58b=0 other=0; naps: stored=1 unsettled=0 tooShort=0; "
            + "endsAfterNewestNight=0; activity sleep min outside sessions (24 h)=0"
        XCTAssertEqual(summary.text, before)
        summary.napsFromBlocks = 1
        summary.mainOnlyBlocks = 2
        XCTAssertTrue(summary.text.contains("naps: stored=1 unsettled=0 tooShort=0 napsFromBlocks=1 mainOnlyBlocks=2; "), summary.text)
    }
}
