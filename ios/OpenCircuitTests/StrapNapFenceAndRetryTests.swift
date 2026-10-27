import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 80 (#331 items 7 and 10), the strap nap follow-ups from the reviews of #329 and #330.
// 80a: a strap nap that only TOUCHES a stored night's in-bed window (the lead-in starts where the nap
// ends) is rewritten when its re-detection moves; one that overlaps it by a second is still skipped,
// and the stale clean still ends one second clear of the night. 80b: the 76l prune is idempotent and
// also runs for a strap night the merge keeps (`.keptFullerStoredNight`), so a prune whose save failed
// is retried. 80c: the retried prune still schedules the nap's written span, cleaned clear of the night
// and its lead-in. Through the production path (the sink and a fake strap) where a sync is involved.
// Every key, reading and time is synthetic.

private let fMidnight: TimeInterval = 1_789_862_400          // 2026-09-20T00:00:00Z
private let fNow = Date(timeIntervalSince1970: fMidnight + 12 * 3600)
private let fKeyHex = "00112233445566778899aabbccddeeff"
/// Local hour `h` of the test day (fixed zone); negative is the evening before.
private func hour(_ h: Double) -> Date { Calendar.current.startOfDay(for: fNow).addingTimeInterval(h * 3600) }
private func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: hour(from), end: hour(to)) }

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

private let light: UInt8 = 0x04

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

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

@MainActor
private final class FenceTransport: HelioTransport {
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
private final class FenceKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(fKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

private struct PruneSaveFailed: Error {}

/// A sleep sample in a stand-in for Apple Health: what wrote it, and its span.
private struct HealthSample: Equatable {
    let label: String
    let span: DateInterval
    var uuid: String { label }
}

@MainActor
final class StrapNapFenceAndRetryTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = fNow
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D07A"
    private var savedZone = NSTimeZone.default
    private var savedPruneSave: (@MainActor (ModelContext) throws -> Void)?

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        savedPruneSave = LocalStore.pruneAutoNapsSave
        clearDefaults()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        if let savedPruneSave { LocalStore.pruneAutoNapsSave = savedPruneSave }
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

    /// One strap sync at local hour `now` delivering each of `sessions` as a record, through the production path.
    @discardableResult
    private func sync(_ sessions: [[(Double, Double, UInt8)]], at now: Double, store: LocalStore) throws -> HelioSyncResult {
        clock = hour(now)
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(fKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = services
        device.deviceInfoReply = deviceInfoReply
        device.dataPacketLength = 200
        device.fetchData = [.sleepSession: (stamp(hour(0).timeIntervalSince1970 - 86_400), sessions.flatMap(sessionRecord))]
        let transport = FenceTransport(device: device)
        let keys = FenceKeys()
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

    private func napRows(_ store: LocalStore) throws -> [StoredNap] {
        try store.context.fetch(FetchDescriptor<StoredNap>(sortBy: [SortDescriptor(\.start)]))
    }

    private func naps(_ store: LocalStore) throws -> [DateInterval] {
        try napRows(store).map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func night(_ store: LocalStore) throws -> StoredSleepSummary {
        try XCTUnwrap(try store.context.fetch(FetchDescriptor<StoredSleepSummary>()).first)
    }

    private func leadIn(_ store: LocalStore) throws -> DateInterval? {
        HelioSleepSelection.leadIn(in: SleepHypnogramCodec.decode(try night(store).hypnogramData))
    }

    private var scheduledCleans: [[Double]] {
        UserDefaults.standard.array(forKey: LocalStore.prunedNapHealthSpansKey) as? [[Double]] ?? []
    }

    /// The samples of `health` a clean over `span` deletes: those overlapping it, edges included (the
    /// clean's HealthKit predicate is not strict at its edges), except the ones kept by UUID.
    private func deleted(by span: DateInterval, from health: [HealthSample], keeping: [String] = []) -> [HealthSample] {
        health.filter { $0.span.start <= span.end && $0.span.end >= span.start && !keeping.contains($0.uuid) }
    }

    /// The night's samples in Health, as its mirror writes them from the stored row: the in-bed envelope
    /// over the whole window, and the lead-in's awake span.
    private func nightSamples(_ store: LocalStore) throws -> [HealthSample] {
        let row = try night(store)
        var samples = [HealthSample(label: "night inBed", span: DateInterval(start: row.inBedStart, end: row.inBedEnd))]
        if let lead = try leadIn(store) { samples.append(HealthSample(label: "lead-in awake", span: lead)) }
        return samples
    }

    // MARK: 80a, the touching nap

    /// Item 7's shape, through the sync: a nap written to Health 19:30–20:27:30, then the sync that brings
    /// the night and the nap's re-detection 19:30–20:30 (150 s longer). The night is stored first, its
    /// lead-in stopping at the nap's new end (20:30), so the nap's re-detection only touches the night.
    /// It is rewritten: the row is re-armed with its old write as the written span, the flush writes the
    /// new window, and the clean deletes the nap's old samples and nothing of the night (it ends one
    /// second clear of the lead-in). Afterwards the card's nap and Health agree.
    func testANapReDetectedToEndWhereTheLeadInStartsIsRewrittenAndOnlyItsOldWriteIsCleaned() async throws {
        let store = try makeStore()
        try storeHeartRate(-5, 8, store: store)
        let oldEnd = hour(-3.5).addingTimeInterval(-150)
        try store.saveNap(start: hour(-4.5), end: oldEnd, asleepMin: 57, isLongNap: false, family: .zeppOS)
        try store.markNapWritten(start: hour(-4.5))

        try sync([eveningNap, nightRecord], at: 7.5, store: store)
        let lead = try XCTUnwrap(try leadIn(store))
        XCTAssertEqual(lead, span(-3.5, -2), "the lead-in starts at the nap's new end")
        let row = try XCTUnwrap(try napRows(store).first)
        XCTAssertEqual(try naps(store), [span(-4.5, -3.5)], "the card's nap is the re-detection")
        XCTAssertFalse(row.healthWritten, "re-armed: Health is rewritten, not left with the old write")
        XCTAssertEqual(DateInterval(start: row.healthWrittenStart, end: row.healthWrittenEnd),
                       DateInterval(start: hour(-4.5), end: oldEnd), "its old write is what the clean must remove")

        let stale = try XCTUnwrap(store.staleNapHealthSpan(start: hour(-4.5)))
        XCTAssertEqual(stale, DateInterval(start: hour(-4.5), end: lead.start.addingTimeInterval(-1)),
                       "the clean ends one second clear of the lead-in")

        // The nap flush's own mirror, against a stand-in for Health holding the old nap write and the night.
        let oldWrite = [HealthSample(label: "old nap inBed", span: DateInterval(start: hour(-4.5), end: oldEnd)),
                        HealthSample(label: "old nap asleep", span: DateInterval(start: hour(-4.5), end: oldEnd))]
        let health = oldWrite + (try nightSamples(store))
        var cleaned: [HealthSample] = []
        let pending = try XCTUnwrap(try store.pendingNaps().first)
        try await HealthKitWriter.mirrorNap(pending, segments: [], store: store,
                                            write: { _, _ in ["new nap"] },
                                            deleteStale: { span, keep, _ in cleaned += self.deleted(by: span, from: health, keeping: keep) })
        XCTAssertEqual(cleaned, oldWrite, "only the nap's own old write is deleted; the night's samples stay")
        let written = try XCTUnwrap(try napRows(store).first)
        XCTAssertTrue(written.healthWritten)
        XCTAssertEqual(DateInterval(start: written.healthWrittenStart, end: written.healthWrittenEnd), span(-4.5, -3.5),
                       "Health now holds the card's nap")
        XCTAssertEqual(try store.pendingNaps().count, 0)
    }

    /// The edges, probed after the night is stored (lead-in from 20:30) beside a nap written 19:30–20:30:
    /// the nap re-detected 150 s earlier at its start and ending 0, 1 or 59 s past the lead-in's start. Only
    /// the one that touches (0 s) is rewritten; the others overlap the lead-in and are skipped, Health
    /// keeping what it has (nothing pending, nothing cleaned). The same nap grown at its end by 1 or 59 s
    /// over the lead-in is updated in place and not rewritten either.
    func testOnlyANapThatTouchesTheLeadInIsRewrittenAndOneThatOverlapsItBySecondsIsSkipped() throws {
        for past in [0.0, 1, 59] {
            clearDefaults()
            let store = try makeStore()
            try storeHeartRate(-5, 8, store: store)
            try store.saveNap(start: hour(-4.5), end: hour(-3.5), asleepMin: 60, isLongNap: false, family: .zeppOS)
            try store.markNapWritten(start: hour(-4.5))
            try sync([eveningNap, nightRecord], at: 7.5, store: store)
            XCTAssertEqual(try leadIn(store), span(-3.5, -2), "\(past) s: the lead-in starts at the nap's end")
            XCTAssertEqual(try store.pendingNaps().count, 0, "\(past) s: an unmoved nap stays written")

            let earlier = hour(-4.5).addingTimeInterval(-150), end = hour(-3.5).addingTimeInterval(past)
            try store.saveNap(start: earlier, end: end, asleepMin: 62, isLongNap: false, family: .zeppOS)
            if past == 0 {
                XCTAssertEqual(try naps(store), [DateInterval(start: earlier, end: end)], "touching: the row moves")
                XCTAssertEqual(try store.pendingNaps().map(\.start), [earlier], "touching: rewritten")
                XCTAssertEqual(store.staleNapHealthSpan(start: earlier),
                               DateInterval(start: earlier, end: hour(-3.5).addingTimeInterval(-1)),
                               "touching: the clean ends one second clear of the lead-in")
            } else {
                XCTAssertEqual(try naps(store), [span(-4.5, -3.5)], "\(past) s over: the stored row stays as written")
                XCTAssertEqual(try store.pendingNaps().count, 0, "\(past) s over: skipped, nothing to clean")
            }

            if past > 0 {
                try store.saveNap(start: hour(-4.5), end: end, asleepMin: 61, isLongNap: false, family: .zeppOS)
                XCTAssertEqual(try naps(store), [DateInterval(start: hour(-4.5), end: end)], "\(past) s over, same start: in place")
                XCTAssertEqual(try store.pendingNaps().count, 0, "\(past) s over, same start: not rewritten")
            }
        }
    }

    /// 80a is the strap's: a ring nap written 20:30–22:00 that touches a ring night (in bed from 22:00),
    /// re-detected 150 s earlier at its start, is still skipped, exactly as before.
    func testARingNapTouchingARingNightIsStillSkipped() throws {
        ownership.install(DeviceOwnershipLog(entries: []))
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(-2), end: hour(7), stage: .inBed),
                        SleepSegment(start: hour(-2), end: hour(7), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        try store.saveSleepSummary(SleepStaging.summary(segments), night: hour(0), inBedStart: hour(-2), inBedEnd: hour(7),
                                   sleepOnset: hour(-2), sleepWake: hour(7), extras: extras, device: .ringConn)
        try store.saveNap(start: hour(-3.5), end: hour(-2), asleepMin: 90, isLongNap: true)
        try store.markNapWritten(start: hour(-3.5))
        try store.saveNap(start: hour(-3.5).addingTimeInterval(-150), end: hour(-2), asleepMin: 92, isLongNap: true)
        XCTAssertEqual(try naps(store), [span(-3.5, -2)], "the ring's touching nap stays as written")
        XCTAssertEqual(try store.pendingNaps().count, 0)
    }

    // MARK: 80b and 80c, the retried prune

    /// A nap written 20:30–21:20 (40 min before the night's sleep at 22:00). The night's sync prunes it
    /// (on the store and on the sync's end re-save), but every save of that prune fails during the sync:
    /// the nap stays and nothing is scheduled. The next re-delivery
    /// is a copy the merge refuses (it ends 30 min earlier: `.keptFullerStoredNight`). It prunes the nap,
    /// schedules its written span once, and leaves the stored night exactly as it was; one more
    /// re-delivery schedules nothing twice. The clean (80c) is clipped clear of the night and its
    /// lead-in (from 21:20), and deletes the nap's own samples only.
    func testAPruneWhoseSaveFailedIsRetriedByAReDeliveryTheMergeKeepsOutAndCleansClearOfTheNight() async throws {
        let store = try makeStore()
        try storeHeartRate(-3.5, 8, store: store)
        let napEnd = hour(-2 - 40.0 / 60)
        try store.saveNap(start: hour(-3.5), end: napEnd, asleepMin: 50, isLongNap: false, family: .zeppOS)
        try store.markNapWritten(start: hour(-3.5))

        var failing = true, failed = 0
        LocalStore.pruneAutoNapsSave = { context in
            if failing { failed += 1; throw PruneSaveFailed() }
            try context.save()
        }
        let first = try sync([nightRecord], at: 7.5, store: store)
        failing = false
        XCTAssertEqual(first.sleepRound?.outcomes[.inserted], 1)
        XCTAssertGreaterThan(failed, 0, "the prune ran and its save failed")
        XCTAssertEqual(try naps(store), [DateInterval(start: hour(-3.5), end: napEnd)], "rolled back: the nap stays")
        XCTAssertEqual(scheduledCleans, [], "nothing scheduled for a prune that was not saved")
        let lead = try XCTUnwrap(try leadIn(store))
        XCTAssertEqual(lead, DateInterval(start: napEnd, end: hour(-2)), "the lead-in stops at the nap's end")
        let stored = try night(store)
        let storedState = (stored.inBedStart, stored.inBedEnd, stored.asleepMin, stored.hypnogramData)

        let retry = try sync([[(-2, 6.5, light)]], at: 7.75, store: store)
        XCTAssertEqual(retry.sleepRound?.outcomes[.keptFullerStoredNight], 1, "the merge keeps the stored night")
        XCTAssertEqual(try naps(store), [], "the retry pruned the nap")
        let napSpan = [hour(-3.5).timeIntervalSince1970, napEnd.timeIntervalSince1970]
        XCTAssertEqual(scheduledCleans, [napSpan], "its written span is scheduled")
        let kept = try night(store)
        XCTAssertEqual(kept.inBedStart, storedState.0)
        XCTAssertEqual(kept.inBedEnd, storedState.1)
        XCTAssertEqual(kept.asleepMin, storedState.2)
        XCTAssertEqual(kept.hypnogramData, storedState.3, "what the merge keeps is unchanged")

        try sync([[(-2, 6.5, light)]], at: 8, store: store)
        XCTAssertEqual(scheduledCleans, [napSpan], "scheduled once")

        // 80c: the clean, against a stand-in for Health holding the nap's write and the night.
        let work = store.prunedNapHealthCleanWork(now: hour(8))
        XCTAssertEqual(work.map(\.pieces), [[DateInterval(start: hour(-3.5), end: lead.start.addingTimeInterval(-1))]],
                       "clipped one second clear of the lead-in, the night's in-bed start")
        let napWrite = [HealthSample(label: "nap inBed", span: DateInterval(start: hour(-3.5), end: napEnd)),
                        HealthSample(label: "nap asleep", span: DateInterval(start: hour(-3.5), end: napEnd))]
        let health = napWrite + (try nightSamples(store))
        var removed: [HealthSample] = []
        await HealthKitWriter.cleanPrunedNaps(store: store, now: hour(8), delete: { piece in
            removed += self.deleted(by: piece, from: health)
            return true
        })
        XCTAssertEqual(removed, napWrite, "only the pruned nap's own samples are deleted")
        XCTAssertEqual(scheduledCleans, [], "forgotten once its clean succeeded")
    }

    /// The same failed prunes, then a re-delivery identical to the stored night: the store takes it
    /// (`.updated`, the merge's same-coverage rule), and its prune removes the nap and schedules its
    /// written span once.
    func testAPruneWhoseSaveFailedIsRetriedByAnIdenticalReDelivery() throws {
        let store = try makeStore()
        try storeHeartRate(-3.5, 8, store: store)
        let napEnd = hour(-2 - 40.0 / 60)
        try store.saveNap(start: hour(-3.5), end: napEnd, asleepMin: 50, isLongNap: false, family: .zeppOS)
        try store.markNapWritten(start: hour(-3.5))
        var failing = true, failed = 0
        LocalStore.pruneAutoNapsSave = { context in
            if failing { failed += 1; throw PruneSaveFailed() }
            try context.save()
        }
        try sync([nightRecord], at: 7.5, store: store)
        failing = false
        XCTAssertGreaterThan(failed, 0, "the prune ran and its save failed")
        XCTAssertEqual(try naps(store).count, 1, "rolled back: the nap stays")
        XCTAssertEqual(scheduledCleans, [])

        let again = try sync([nightRecord], at: 7.75, store: store)
        XCTAssertEqual(again.sleepRound?.outcomes[.updated], 1)
        XCTAssertEqual(try naps(store), [], "the retry pruned the nap")
        XCTAssertEqual(scheduledCleans, [[hour(-3.5).timeIntervalSince1970, napEnd.timeIntervalSince1970]], "scheduled once")
    }
}
