import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 79e (#331 item 1): a strap night stored BEFORE the sync that first sees a nap more than 60 min
// before its sleep onset was stored with a lead-in over that nap. While the night is not written to Apple
// Health, the next re-delivery with the same sleep window and a later lead-in start replaces the stored
// copy, so the lead-in stops at the nap (77c). A night already written keeps its lead-in (77f, forward-
// only): the documented limit. Through the production path (the sink and a fake strap). Every key,
// reading and time is synthetic.

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
final class StrapLeadInNapOrderTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = jNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D07E"
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

    /// The seconds the stored night's lead-in overlaps any stored nap.
    private func leadInOverNaps(_ store: LocalStore) throws -> TimeInterval {
        guard let lead = try leadIn(store) else { return 0 }
        return try naps(store).reduce(0) { $0 + max(0, min($1.end, lead.end).timeIntervalSince(max($1.start, lead.start))) }
    }

    /// Record the stored night as written to Apple Health, as `mirrorSettledNight` records a write.
    private func markWritten(_ store: LocalStore) throws {
        let row = try XCTUnwrap(try nights(store).first)
        store.setMirroredNight(night: row.night, signature: HealthKitWriter.sleepSignature(SleepHypnogramCodec.decode(row.hypnogramData)),
                               spanStart: row.inBedStart, spanEnd: row.inBedEnd)
    }

    // MARK: The night first, the nap in a later sync

    /// The reviewer's shapes. The night (asleep 22:00–07:00, calm heart rate from 17:00) is stored first,
    /// its lead-in at the cap (20:00–22:00). A later sync delivers a 60 min nap ending 90 or 61 min before
    /// the night's sleep, with the night re-delivered unchanged or 5 min longer at its end (too little to
    /// extend a written night, 58b). One more identical sync follows. The nap is stored in every case.
    /// Not written to Apple Health: the lead-in stops at the nap's end and nothing overlaps, after the
    /// nap's sync and after the next. Written: the stored lead-in stands, the overlap is the documented
    /// limit (30 min at 90, 59 min at 61), unchanged by the next sync.
    func testANightStoredBeforeTheNapLosesItsOverlapUnlessItIsAlreadyInHealth() throws {
        let deliveries: [(String, [(Double, Double, UInt8)])] = [("unchanged", nightRecord), ("5 min longer", [(-2, 7 + 5.0 / 60, light)])]
        for napEndsBeforeSleep in [90.0, 61] {
            let napEnd = -2 - napEndsBeforeSleep / 60
            let nap: [(Double, Double, UInt8)] = [(napEnd - 1, napEnd, light)]
            for written in [false, true] {
                for (label, night) in deliveries {
                    let context = "nap \(Int(napEndsBeforeSleep)) min before, \(written ? "written" : "not written"), \(label)"
                    clearDefaults()
                    let store = try makeStore()
                    try storeHeartRate(-5, 8, store: store)
                    try sync([nightRecord], at: 7.5, store: store)
                    XCTAssertEqual(try leadIn(store), span(-4, -2), "\(context): the night first, its lead-in at the cap")
                    if written { try markWritten(store) }

                    try sync([nap, night], at: 7.75, store: store)
                    XCTAssertEqual(try naps(store), [span(napEnd - 1, napEnd)], "\(context): the nap is stored")
                    XCTAssertEqual(try nights(store).count, 1, context)
                    let overlap = written ? (napEndsBeforeSleep == 90 ? 30.0 : 59) * 60 : 0
                    let lead = written ? span(-4, -2) : span(napEnd, -2)
                    XCTAssertEqual(try leadIn(store), lead, "\(context): the nap's sync")
                    XCTAssertEqual(try leadInOverNaps(store), overlap, "\(context): the nap's sync")

                    try sync([nap, night], at: 8.5, store: store)
                    XCTAssertEqual(try naps(store), [span(napEnd - 1, napEnd)], "\(context): one more identical sync")
                    XCTAssertEqual(try leadIn(store), lead, "\(context): one more identical sync")
                    XCTAssertEqual(try leadInOverNaps(store), overlap, "\(context): one more identical sync")
                    XCTAssertEqual(scheduledCleans, [], context)
                }
            }
        }
    }

    /// The replaced copy is the night the strap re-delivered, stored whole: the same sleep, the in-bed
    /// window from the nap's end, and the same row (the person's rating kept).
    func testTheReplacedNightIsTheReDeliveredOneOnTheSameRow() throws {
        let store = try makeStore()
        try storeHeartRate(-5, 8, store: store)
        try sync([nightRecord], at: 7.5, store: store)
        let row = try XCTUnwrap(try nights(store).first)
        let (asleep, wake) = (row.asleepMin, row.inBedEnd)
        try store.setFeelScore(7, night: row.night)

        let result = try sync([eveningNap, nightRecord], at: 7.75, store: store)
        XCTAssertEqual(result.nights.map(\.window), [span(-3.5, 7)], "handed to the flush with the clamped lead-in")
        let after = try XCTUnwrap(try nights(store).first)
        XCTAssertTrue(after === row, "the same row")
        XCTAssertEqual(try nights(store).count, 1)
        XCTAssertEqual(DateInterval(start: after.inBedStart, end: after.inBedEnd), span(-3.5, 7))
        XCTAssertEqual(after.asleepMin, asleep, "the same sleep")
        XCTAssertEqual(after.inBedEnd, wake)
        XCTAssertEqual(after.feelScore, 7, "the person's rating kept")
    }

    /// Only a STALE lead-in is replaced. The same night re-delivered with the same lead-in, or with no nap
    /// to clamp it, is kept as before (the merge's keep); a stored copy without a lead-in is widened by
    /// the merge as before; and a re-delivery whose sleep differs goes to the merge as before.
    func testOnlyAStoredLeadInThatStartsEarlierOverTheSameSleepIsReplaced() throws {
        let store = try makeStore()
        try storeHeartRate(-5, 8, store: store)
        try sync([nightRecord], at: 7.5, store: store)
        let row = try XCTUnwrap(try nights(store).first)
        let stored = HelioSleepSelection.Night(segments: SleepHypnogramCodec.decode(row.hypnogramData), window: span(-4, 7),
                                               strapScore: nil, recordedTimeZone: nil)
        XCTAssertEqual(stored.leadIn, span(-4, -2))
        XCTAssertFalse(store.helioStoredLeadInIsStale(for: stored), "the same lead-in")
        XCTAssertFalse(store.helioStoredLeadInIsStale(for: stored.withLeadIn(from: hour(-4.5))), "an earlier lead-in: the merge widens")
        XCTAssertTrue(store.helioStoredLeadInIsStale(for: stored.withLeadIn(from: hour(-3.5))), "a later lead-in")
        XCTAssertTrue(store.helioStoredLeadInIsStale(for: stored.withoutLeadIn), "no lead-in")
        let otherSleep = HelioSleepSelection.Night(segments: [SleepSegment(start: hour(-1.5), end: hour(7), stage: .inBed),
                                                              SleepSegment(start: hour(-1.5), end: hour(7), stage: .asleepCore)],
                                                   window: span(-1.5, 7), strapScore: nil, recordedTimeZone: nil)
        XCTAssertFalse(store.helioStoredLeadInIsStale(for: otherSleep), "another sleep window: the merge decides")
        row.isManuallyEdited = true
        XCTAssertFalse(store.helioStoredLeadInIsStale(for: stored.withoutLeadIn), "an edited night is the person's")
    }
}

extension StrapLeadInNapOrderTests {
    /// The decision itself: a stale stored lead-in is replaced only while the night is not in Apple Health.
    func testAStaleLeadInIsReplacedOnlyWhileTheNightIsNotWritten() throws {
        let store = try makeStore()
        try storeHeartRate(-5, 8, store: store)
        try sync([nightRecord], at: 7.5, store: store)
        let row = try XCTUnwrap(try nights(store).first)
        let stored = HelioSleepSelection.Night(segments: SleepHypnogramCodec.decode(row.hypnogramData), window: span(-4, 7),
                                               strapScore: nil, recordedTimeZone: nil)
        let incoming = stored.withLeadIn(from: hour(-3.5))
        XCTAssertTrue(store.helioReplacesStoredCopy(with: incoming, sleep: stored.withoutLeadIn), "not written")
        store.setMirroredNight(night: row.night, signature: HealthKitWriter.sleepSignature(stored.segments),
                               spanStart: row.inBedStart, spanEnd: row.inBedEnd)
        XCTAssertFalse(store.helioReplacesStoredCopy(with: incoming, sleep: stored.withoutLeadIn), "written: 77f, no rewrite path")
    }
}

extension StrapLeadInNapOrderTests {
    /// Only a STRAP row is read as having a stale lead-in (79b): a row of the same shape in time the ring
    /// owns (an empty log, or the strap chosen only after the night) is never replaced; the same row in
    /// time the strap owns is.
    func testAStaleLeadInIsNeverReadOnARingOrOtherDeviceRow() throws {
        var strapAfterTheNight = DeviceOwnershipLog()
        _ = strapAfterTheNight.record(.zeppOS, since: hour(12))
        for (label, log) in [("empty log", DeviceOwnershipLog()), ("the strap chosen after the night", strapAfterTheNight)] {
            ownership.install(log)
            let store = try makeStore()
            let base = [SleepSegment(start: hour(-2), end: hour(7), stage: .inBed), SleepSegment(start: hour(-2), end: hour(7), stage: .asleepCore)]
            let segments = HelioSleepSelection.withLeadIn(base, window: span(-2, 7), from: hour(-4))
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(-4), inBedEnd: hour(7)),
                                                      inBedStart: hour(-4), inBedEnd: hour(7), sleepOnset: hour(-2), sleepWake: hour(7),
                                                      extras: extras), .inserted, label)
            let stored = HelioSleepSelection.Night(segments: segments, window: span(-4, 7), strapScore: nil, recordedTimeZone: nil)
            let incoming = stored.withLeadIn(from: hour(-3.5))
            XCTAssertFalse(store.helioStoredLeadInIsStale(for: incoming), "\(label): not the strap's row")
            XCTAssertFalse(store.helioReplacesStoredCopy(with: incoming, sleep: stored.withoutLeadIn), label)
            ownership.install(.strapOwnsAllTime)
            XCTAssertTrue(store.helioStoredLeadInIsStale(for: incoming), "\(label): the same row, the strap's")
        }
    }
}
