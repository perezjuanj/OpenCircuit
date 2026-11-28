import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 97 (#408): a strap sleep that starts in the night but ends late (05:00–15:00 while ill, or a
// night stitched to a lie-in that ends after noon) is stored as that day's night, but never on a key
// another night holds (97c). Production path: `FakeZeppDevice` → `HelioSession` → `HelioStoreSink` →
// the store → the strap flush (`HelioConnection.strapNights`, `mirrorSettledNight`). Every key, reading
// and time is synthetic, and every fixture day lies in the past behind an injected clock.
//
// The writer can't write in the simulator (no Health access), so a write is shown as the other strap
// night suites show it: the night is in the flush input, ready, and `mirrorSettledNight` gets past every
// bail to its write step; the test then leaves the record a successful write leaves.

// MARK: - Fixtures

private let lMidnight: TimeInterval = 1_790_208_000          // 2026-09-24T00:00:00Z
private let lKeyHex = "00112233445566778899aabbccddeeff"
/// Hour `h` of the fixture day, local (negative: the evening before; 24 and on: the next day).
private func hour(_ h: Double) -> Date {
    Calendar.current.startOfDay(for: Date(timeIntervalSince1970: lMidnight + 12 * 3600)).addingTimeInterval(h * 3600)
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
private func stamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// Stage bytes (ZEPP_PROTOCOL.md §6.6): light, deep, REM.
private let light: UInt8 = 0x04, deep: UInt8 = 0x05, rem: UInt8 = 0x08

/// One strap sleep session record over hours of the fixture day, recorded on the local midnight
/// `hour(midnight)` (0 for the fixture day, 24 for the next one; the minute fields count from the
/// midnight before it, `ZeppSleepSession.absolute`).
private func sleepRecord(_ stages: [(Double, Double, UInt8)], midnight: Double = 0) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    func minute(_ h: Double) -> UInt16 { UInt16(((h - midnight + 24) * 60).rounded()) }
    let reference = UInt32(hour(midnight).timeIntervalSince1970)
    put(le32(reference), at: 0x000)
    put(le32(reference), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(minute(stages.first!.0)), at: 0x00A)
    put(le16(minute(stages.last!.1)), at: 0x00C)
    r[0x016] = 78
    r[0x054] = UInt8(stages.count)
    // §6.6 (decision 70e): a stage's end minute is inclusive, so a stage ending at `end` is written as `end − 1`.
    for (i, stage) in stages.enumerated() { put(le16(minute(stage.0)) + le16(minute(stage.1) - 1) + [stage.2], at: 0x056 + 5 * i) }
    return r
}

/// A sleep `from`–`to` (hours of the fixture day), staged in hour-long blocks of light, deep and REM.
private func asleep(_ from: Double, _ to: Double) -> [(Double, Double, UInt8)] {
    var stages: [(Double, Double, UInt8)] = []
    var t = from
    let kinds = [light, deep, light, rem]
    while t < to {
        stages.append((t, min(t + 1, to), kinds[stages.count % kinds.count]))
        t += 1
    }
    return stages
}

/// The reported shape: asleep 05:00–15:00.
private let reported = asleep(5, 15)

/// The reported record as the strap shows it while the sleep is still going on, up to `end`.
private func inProgress(until end: Double) -> [(Double, Double, UInt8)] {
    reported.compactMap { stage in stage.0 < end ? (stage.0, min(stage.1, end), stage.2) : nil }
}

private let services: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let deviceInfoReply: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func makeStrap(_ records: [[UInt8]]) -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(lKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
    device.services = services
    device.deviceInfoReply = deviceInfoReply
    device.dataPacketLength = 200
    if !records.isEmpty {
        device.fetchData = [.sleepSession: (stamp(hour(0).timeIntervalSince1970 - 86_400), records.flatMap { $0 })]
    }
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

/// A stub key store, so no test reaches the keychain (unsigned runs fail every `SecItem` call).
@MainActor
private final class Keys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(lKeyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

// MARK: - Tests

@MainActor
final class StrapLateMainSleepTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = hour(12)
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-00000000D097"
    /// Night keys whose mirror record a test may write (`MirroredNightOverlay` lives in the standard
    /// defaults), cleared before and after each test.
    private var touchedNights: [Date] = []
    private var observabilitySuite = ""
    private var observability = ObservabilityStore()

    override func setUp() {
        super.setUp()
        touchedNights = (-3...3).map { hour(Double($0) * 24) }
        touchedNights.forEach(clearMirror)
        observabilitySuite = "StrapLateMainSleepTests.observability.\(UUID().uuidString)"
        observability = ObservabilityStore(UserDefaults(suiteName: observabilitySuite)!)
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        touchedNights.forEach(clearMirror)
        UserDefaults().removePersistentDomain(forName: observabilitySuite)
        ownership.restore()
        containers.removeAll()
        super.tearDown()
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

    /// One strap sync at `now` delivering `records` (none: no sleep round), through the production path.
    private func sync(_ records: [[UInt8]], at now: Date, store: LocalStore) throws -> HelioSyncResult {
        clock = now
        let transport = Transport(device: makeStrap(records))
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

    private func nightWindows(_ store: LocalStore) throws -> [DateInterval] {
        try rows(store).map { DateInterval(start: $0.inBedStart, end: $0.inBedEnd) }
    }

    private func napWindows(_ store: LocalStore) throws -> [DateInterval] {
        try store.context.fetch(FetchDescriptor<StoredNap>(sortBy: [SortDescriptor(\.start)]))
            .map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: hour(from), end: hour(to)) }

    private func span(_ segments: [SleepSegment]) -> DateInterval {
        DateInterval(start: segments.map(\.start).min()!, end: segments.map(\.end).max()!)
    }

    private func isUnchanged(_ outcome: HealthKitWriter.MirrorOutcome) -> Bool {
        switch outcome {
        case .unchanged, .declined: return true
        case .wrote, .failed: return false
        }
    }

    /// What `mirrorSettledNight` records once its write of `segments` succeeded, computed as the writer
    /// does: the key of the stored row the night overlaps, the signature, and the union of the night's
    /// span, the last record's and the stored row's (the span its delete covered).
    private func recordWrite(_ segments: [SleepSegment], store: LocalStore) throws {
        let night = span(segments)
        let row = try store.sleepSummaryOverlapping(start: night.start, end: night.end)
        let key = row?.night ?? SleepNightKey.night(inBedStart: night.start, inBedEnd: night.end)
        let last = store.mirroredNight(night: key)
        let start = min(night.start, last?.spanStart ?? night.start, row?.inBedStart ?? night.start)
        let end = max(night.end, last?.spanEnd ?? night.end, row?.inBedEnd ?? night.end)
        store.setMirroredNight(night: key, signature: HealthKitWriter.sleepSignature(segments), spanStart: start, spanEnd: end)
    }

    /// One strap flush at `now`: what `HelioConnection.strapNights` hands the writer (the sync's nights,
    /// then the backstop's), through the margin gate, each ready night to `mirrorSettledNight`; a night
    /// that reaches the write step is recorded as written. The spans written.
    private func flush(_ nights: [[SleepSegment]], at now: Date, store: LocalStore) async throws -> [DateInterval] {
        var written: [DateInterval] = []
        for night in HelioConnection.strapNights(nights, store: store, timeline: timeline, now: now)
        where SleepHealthGate.isReadyToWrite(latestSegmentEnd: night.map(\.end).max(), now: now, finalized: false) {
            let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: night)
            if case .declined = outcome { store.noteStrapNightDeclined(night) }
            guard !isUnchanged(outcome) else { continue }
            try recordWrite(night, store: store)
            written.append(span(night))
        }
        return written
    }

    /// A sync at `now` delivering `records`, then its own flush at the same instant.
    private func syncAndFlush(_ records: [[UInt8]], at now: Date,
                              store: LocalStore) async throws -> (result: HelioSyncResult, written: [DateInterval]) {
        let result = try sync(records, at: now, store: store)
        return (result, try await flush(result.nights.map(\.segments), at: now, store: store))
    }

    private func mirrorSpan(_ store: LocalStore, key: Date) -> DateInterval? {
        store.mirroredNight(night: key).map { DateInterval(start: $0.spanStart, end: $0.spanEnd) }
    }

    private func extensionBreadcrumbs() -> [String] {
        observability.metricRecords().filter { $0.source == "sleep-extend" }.map(\.detail)
    }

    // MARK: The reported shape

    /// #408: one record 05:00–15:00, synced at 16:00. One night, filed under that day, handed to the
    /// flush and written once (an hour after its end, past the settle margin); no nap.
    func testASleepFromFiveToThreeIsStoredAsThatDaysNightAndReachesHealth() async throws {
        let store = try makeStore()
        let (result, written) = try await syncAndFlush([sleepRecord(reported)], at: hour(16), store: store)
        XCTAssertEqual(result.nights.map(\.window), [span(5, 15)], "handed to the flush")
        XCTAssertEqual(try nightWindows(store), [span(5, 15)])
        XCTAssertEqual(try rows(store).first?.night, hour(0), "filed under the day it ends on")
        XCTAssertEqual(try napWindows(store), [], "a night, never a nap")
        XCTAssertEqual(written, [span(5, 15)], "written once, after the margin")
        XCTAssertEqual(mirrorSpan(store, key: hour(0)), span(5, 15))

        let again = try await syncAndFlush([sleepRecord(reported)], at: hour(16.5), store: store)
        XCTAssertEqual(again.written, [], "the same night again writes nothing")
        XCTAssertEqual(try nightWindows(store), [span(5, 15)])
    }

    /// The same record, synced inside the settle margin: stored, not written until the margin has passed.
    func testTheLateMainSleepWaitsForTheSettleMarginLikeAnyStrapNight() async throws {
        let store = try makeStore()
        let early = try await syncAndFlush([sleepRecord(reported)], at: hour(15 + 10.0 / 60), store: store)
        XCTAssertEqual(try nightWindows(store), [span(5, 15)])
        XCTAssertEqual(early.written, [], "inside its margin")
        let later = try await syncAndFlush([sleepRecord(reported)], at: hour(15.5), store: store)
        XCTAssertEqual(later.written, [span(5, 15)])
    }

    // MARK: Another night on the key

    /// A normal night 23:00–07:00, then a separate record 09:00–15:00: the night stays the night, and the
    /// later sleep, starting after 08:00, is a nap (97a(3)), never a night.
    func testANormalNightStaysAndASleepStartingAfterEightIsANap() throws {
        let store = try makeStore()
        _ = try sync([sleepRecord(asleep(-1, 7)), sleepRecord(asleep(9, 15))], at: hour(16.5), store: store)
        XCTAssertEqual(try nightWindows(store), [span(-1, 7)])
        XCTAssertEqual(try napWindows(store), [span(9, 15)])
    }

    /// 97c(ii): a night 00:00–02:00 is stored, then a record 07:00–11:30 of the same key arrives (a late
    /// main sleep: it is no overnight sleep). It is kept out of the key and stored as a nap; the stored
    /// row is untouched.
    func testAStoredNightOnTheKeyKeepsALaterMorningSleepOutAndItIsANap() throws {
        let store = try makeStore()
        _ = try sync([sleepRecord(asleep(0, 2))], at: hour(2.5), store: store)
        let before = try XCTUnwrap(try rows(store).first)
        let (hypnogram, asleepMin) = (before.hypnogramData, before.asleepMin)

        let result = try sync([sleepRecord(asleep(7, 11.5))], at: hour(12.75), store: store)
        XCTAssertEqual(try nightWindows(store), [span(0, 2)], "the stored night keeps its key")
        let after = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(after.hypnogramData, hypnogram)
        XCTAssertEqual(after.asleepMin, asleepMin)
        XCTAssertEqual(try napWindows(store), [span(7, 11.5)])
        XCTAssertEqual(result.nights.count, 0, "nothing handed to the flush")
        XCTAssertEqual(result.sleepRound?.lateMainSleepsKeptOut, 1)
        XCTAssertEqual(result.sleepRound?.lateMainSleepsOffered, 0)
    }

    /// 97c(i): the same two sleeps in one sync, nothing stored before. The overnight sleep is the night;
    /// the late main sleep is kept out of its key and is a nap. Stored as a night, the completeness merge
    /// would have replaced the shorter 00:00–02:00 night.
    func testAnOvernightSleepOfTheSameSyncKeepsALaterMorningSleepOutAndItIsANap() throws {
        let store = try makeStore()
        let result = try sync([sleepRecord(asleep(0, 2)), sleepRecord(asleep(7, 11.5))], at: hour(12.75), store: store)
        XCTAssertEqual(try nightWindows(store), [span(0, 2)])
        XCTAssertEqual(try napWindows(store), [span(7, 11.5)])
        XCTAssertEqual(result.nights.map(\.window), [span(0, 2)])
        XCTAssertEqual(result.sleepRound?.lateMainSleepsKeptOut, 1)
    }

    /// 97c(ii): a stored night 00:00–04:00, then a record 06:00–15:00: kept out, stored as a (long) nap.
    func testAStoredNightToFourKeepsASleepFromSixToThreeOutAndItIsALongNap() throws {
        let store = try makeStore()
        _ = try sync([sleepRecord(asleep(0, 4))], at: hour(4.5), store: store)
        _ = try sync([sleepRecord(asleep(6, 15))], at: hour(16.5), store: store)
        XCTAssertEqual(try nightWindows(store), [span(0, 4)])
        XCTAssertEqual(try napWindows(store), [span(6, 15)])
    }

    /// 97c(ii), either device: the ring's night 00:00–02:00 on the key, the strap owning the morning
    /// after a switch at 06:00. The strap's 07:00–11:30 is no night and never touches the ring's row.
    func testTheRingsNightOnTheKeyKeepsTheStrapsLaterMorningSleepOut() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(6))]))
        let store = try makeStore()
        let segments = [SleepSegment(start: hour(0), end: hour(2), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: hour(0), inBedEnd: hour(2)),
                                                  inBedStart: hour(0), inBedEnd: hour(2), sleepOnset: hour(0), sleepWake: hour(2),
                                                  extras: extras), .inserted)
        let result = try sync([sleepRecord(asleep(7, 11.5))], at: hour(12.75), store: store)
        XCTAssertEqual(try nightWindows(store), [span(0, 2)])
        XCTAssertEqual(try rows(store).first?.asleepMin, 120, "the ring's night is untouched")
        XCTAssertEqual(result.nights.count, 0)
        XCTAssertEqual(result.sleepRound?.lateMainSleepsKeptOut, 1)
    }

    // MARK: The lie-in

    /// A night 23:00–06:00 already in Apple Health, then a sleep 06:30–13:00 within the stitch gap: one
    /// night 23:00–13:00 (a late main sleep), rewritten once as a 58b extension; no second row, no nap.
    func testANightStitchedToALieInEndingAfterNoonExtendsTheWrittenNightOnce() async throws {
        let store = try makeStore()
        let first = try await syncAndFlush([sleepRecord(asleep(-1, 6))], at: hour(6 + 40.0 / 60), store: store)
        XCTAssertEqual(first.written, [span(-1, 6)], "the night is in Health")

        let lieIn = [sleepRecord(asleep(-1, 6)), sleepRecord(asleep(6.5, 13))]
        var written = try await syncAndFlush(lieIn, at: hour(13.5), store: store).written
        XCTAssertEqual(try nightWindows(store), [span(-1, 13)], "one row, the joined night")
        XCTAssertEqual(try napWindows(store), [])
        XCTAssertEqual(written, [span(-1, 13)], "rewritten once")
        XCTAssertEqual(mirrorSpan(store, key: hour(0)), span(-1, 13))
        XCTAssertEqual(extensionBreadcrumbs().count, 1)

        written = try await syncAndFlush(lieIn, at: hour(14), store: store).written
        XCTAssertEqual(written, [], "not again")
        XCTAssertEqual(try nightWindows(store), [span(-1, 13)])
    }

    // MARK: In progress

    /// The strap lets the phone read the record while the sleep goes on (decision 58): syncs every 30 min
    /// from 05:30 to 16:30, each reading the record as it is about 3 min before the sync. After every
    /// sync: one row at most on the key, no nap over it, at most one Health span on the key, and nothing
    /// written while the record still grows. At the end the row and the Health span are 05:00–15:00.
    func testASleepSyncedWhileItGrowsIsStoredAsOneNightAndWrittenOnceInFull() async throws {
        let store = try makeStore()
        var written: [DateInterval] = []
        for step in 0...22 {
            let at = 5.5 + Double(step) * 0.5
            let end = min(at - 3.0 / 60, 15)
            let label = "sync at \(at)"
            let round = try await syncAndFlush([sleepRecord(inProgress(until: end))], at: hour(at), store: store)
            written += round.written
            let onKey = try rows(store).filter { $0.night == hour(0) }
            XCTAssertLessThanOrEqual(onKey.count, 1, label)
            XCTAssertEqual(try rows(store).count, onKey.count, "\(label): no other row")
            if let row = onKey.first {
                let night = DateInterval(start: row.inBedStart, end: row.inBedEnd)
                XCTAssertFalse(try napWindows(store).contains { $0.start < night.end && night.start < $0.end }, "\(label): no nap over it")
            }
            XCTAssertLessThanOrEqual(written.count, 1, "\(label): one Health span at most")
            if end < 15 { XCTAssertEqual(written, [], "\(label): nothing written while it grows") }
        }
        XCTAssertEqual(try nightWindows(store), [span(5, 15)])
        XCTAssertEqual(try napWindows(store), [])
        XCTAssertEqual(written, [span(5, 15)])
        XCTAssertEqual(mirrorSpan(store, key: hour(0)), span(5, 15))
    }

    // MARK: Ownership

    /// 28a: the ring went to bed with the sleep (the strap was chosen at 06:00, inside it), so the strap
    /// stores nothing: no night, no nap.
    func testTheRingsTimeIsNeverAStrapLateMainSleep() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: hour(6))]))
        let store = try makeStore()
        let result = try sync([sleepRecord(reported)], at: hour(16), store: store)
        XCTAssertEqual(try nightWindows(store), [])
        XCTAssertEqual(try napWindows(store), [])
        XCTAssertEqual(result.nights.count, 0)
    }

    // MARK: Two days

    /// A late main sleep of one day and the next night (23:00 → 07:00 the day after) are both stored, each
    /// under its own key.
    func testALateMainSleepAndTheNextNightAreBothStoredUnderTheirOwnKeys() throws {
        let store = try makeStore()
        _ = try sync([sleepRecord(reported), sleepRecord(asleep(23, 31), midnight: 24)], at: hour(32), store: store)
        XCTAssertEqual(try nightWindows(store), [span(5, 15), span(23, 31)])
        XCTAssertEqual(try rows(store).map(\.night), [hour(0), hour(24)])
        XCTAssertEqual(try napWindows(store), [])
    }

    // MARK: 97g: the counts

    /// The `sleep round:` line counts late main sleeps offered as nights, those kept out by 97c and the
    /// sleeps that are neither shape, digits only.
    func testTheSleepRoundLineCountsLateMainSleepsWithNoClockTime() throws {
        let offered = try sync([sleepRecord(reported)], at: hour(16), store: try makeStore())
        let offeredLine = try XCTUnwrap(offered.sleepRound?.text)
        XCTAssertTrue(offeredLine.contains("; late main sleeps: offered=1 keptOut=0 neither=0; "), offeredLine)

        let store = try makeStore()
        _ = try sync([sleepRecord(asleep(0, 2))], at: hour(2.5), store: store)
        let keptOut = try sync([sleepRecord(asleep(7, 11.5)), sleepRecord(asleep(13, 16.5))], at: hour(18), store: store)
        let keptOutLine = try XCTUnwrap(keptOut.sleepRound?.text)
        XCTAssertTrue(keptOutLine.contains("; late main sleeps: offered=0 keptOut=1 neither=1; "), keptOutLine)
        XCTAssertEqual(keptOut.sleepRound?.neitherOvernightNorLateMainSleep, 1, "the afternoon sleep")
        for line in [offeredLine, keptOutLine] {
            XCTAssertNil(line.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression), "no clock time: \(line)")
        }
    }

    /// With none of the three, the line is byte for byte the one shipped before decision 97.
    func testTheLateMainSleepCountsAppearOnlyWhenNonZero() {
        var summary = StrapSleepRoundSummary()
        summary.records = 1
        let before = "sleep round: records=1 staged=0 nights=0 (joined 0) outcomes: inserted=0 updated=0 keptFuller=0 "
            + "ownedByOther=0 keyCollision=0 manualEdit=0 keptOut58b=0 other=0; naps: stored=0 unsettled=0 tooShort=0; "
            + "endsAfterNewestNight=0; activity sleep min outside sessions (24 h)=0"
        XCTAssertEqual(summary.text, before)
        summary.neitherOvernightNorLateMainSleep = 2
        XCTAssertTrue(summary.text.contains("naps: stored=0 unsettled=0 tooShort=0; late main sleeps: offered=0 keptOut=0 neither=2; "
            + "endsAfterNewestNight=0"), summary.text)
    }
}
