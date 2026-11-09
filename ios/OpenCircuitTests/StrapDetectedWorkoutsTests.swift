import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The strap's own workout records in the app (#226, decision 91): the walk after every other type
// through the real `HelioSession` and `HelioStoreSink` against the simulated strap (`FakeZeppDevice`),
// what the inbox keeps and for how long, the review's Save and Discard through the strap's Health write
// path, and the one notification. Every time, reading and record is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let keyHex = "00112233445566778899aabbccddeeff"
private let strapID = "5B1E4C2A-0000-4000-8000-0000000000D4"
private let strapTimeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: strapID)
private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strap-detected-\(UUID().uuidString)")! }

// MARK: - Synthetic records (the spec's §22.2 / §22.3 layouts)

private enum Record {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
    static func field(_ n: UInt64, _ v: UInt64) -> [UInt8] { varint(n << 3) + varint(v) }
    static func message(_ n: UInt64, _ body: [UInt8]) -> [UInt8] { varint(n << 3 | 2) + varint(UInt64(body.count)) + body }

    static func summary(start: UInt64, duration: UInt64, kcal: UInt64, sport: UInt64) -> [UInt8] {
        [0x00, 0x80] + message(1, Array("2.1".utf8))
            + message(2, field(1, start) + field(3, 39) + field(13, sport == 0xdf ? 257 : 1))
            + message(3, field(1, sport)) + message(7, field(1, duration) + field(2, duration))
            + message(16, field(1, kcal)) + message(19, field(1, 118) + field(2, 151) + field(3, 92))
    }

    /// A 1 Hz track from a minute before `start` to a minute after the end, a block every 30 s.
    static func detail(start: UInt64, duration: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var t = start - 60
        while t < start + duration + 60 {
            let ms = t * 1000
            out += [0x01, 0x0c, 0x70, 0x73, 0x6d, 0x68] + (0..<6).map { UInt8((ms >> (8 * UInt64($0))) & 0xFF) } + [0, 0]
            for k in 0..<UInt64(30) where t + k < start + duration + 60 {
                let offset = UInt16(k * 1000)
                out += [0x08, 0x03, UInt8(offset & 0xFF), UInt8(offset >> 8), UInt8(110 + (t + k) % 30)]
            }
            t += 30
        }
        return out
    }

    static func strap(start: Date, minutes: Double, kcal: UInt64 = 150, sport: UInt64 = 0xdf) -> FakeZeppDevice.WorkoutRecord {
        let s = UInt64(start.timeIntervalSince1970)
        let d = UInt64(minutes * 60)
        return FakeZeppDevice.WorkoutRecord(start: UInt32(s), summary: summary(start: s, duration: d, kcal: kcal, sport: sport),
                                            detail: detail(start: s, duration: d))
    }

    static func parsed(start: Date, minutes: Double, kcal: UInt64 = 150, sport: UInt64 = 0xdf) throws -> ZeppWorkoutRecord {
        let r = strap(start: start, minutes: minutes, kcal: kcal, sport: sport)
        let summary = try ZeppWorkoutSummary.parse(r.summary)
        return ZeppWorkoutRecord(summary: summary, heartRate: try ZeppWorkoutDetail.parse(r.detail ?? [], window: summary.window).heartRate)
    }
}

// MARK: - Fakes

@MainActor
private final class DetectedTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }
    func write(_ write: ZeppWrite) {
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) { inbox.append((characteristic, nil, enabled)) }
    func read(_ characteristic: ZeppCharacteristic) {
        if characteristic == .batteryLevel { inbox.append((characteristic, [64], false)) }
    }
    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 1_000_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes { session?.received(characteristic, bytes) }
            else { session?.notificationStateChanged(characteristic, enabled: enabled, failed: false) }
        }
    }
}

@MainActor
private final class DetectedKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
private final class RecordingHealth: StrapWorkoutHealthWriting {
    var succeeds = true
    private(set) var writes: [StrapWorkoutWrite] = []
    func save(_ write: StrapWorkoutWrite) async -> Bool {
        writes.append(write)
        return succeeds
    }
}

@MainActor
private final class CreditBuilder: StrapWorkoutBuilding {
    private(set) var samples: [HKSample] = []
    private var start = Date()
    private var end = Date()
    func beginCollection(at date: Date) async throws { start = date }
    func addWorkoutEvents(_ events: [HKWorkoutEvent]) async throws {}
    func addSamples(_ samples: [HKSample]) async throws { self.samples += samples }
    func addMetadata(_ metadata: [String: Any]) async throws {}
    func endCollection(at date: Date) async throws { end = date }
    func finishWorkout() async throws -> HKWorkout? { HKWorkout(activityType: .other, start: start, end: end) }
}

// MARK: - Tests

@MainActor
final class StrapDetectedWorkoutsTests: XCTestCase {
    private var now = t0
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private var defaults = freshDefaults()
    private let health = RecordingHealth()
    private var notified: [Date] = []
    private var strapChosen = true

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeInbox() -> StrapDetectedWorkouts {
        StrapDetectedWorkouts(defaults: defaults, writer: health, historyWindows: { _ in [] },
                              notify: { [unowned self] item in self.notified.append(item.start); return true },
                              zones: { HeartRateZones(percentOfMax: 185) },
                              isStrapChosen: { [unowned self] in self.strapChosen },
                              clock: { [unowned self] in self.now })
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private func makeStrap() -> FakeZeppDevice {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x0082, 0)]
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        device.startReplyTrailingZero = true
        return device
    }

    /// One sync of `device` through a fresh session (a new connection), drained to the end.
    @discardableResult
    private func sync(_ device: FakeZeppDevice, store: LocalStore, inbox: StrapDetectedWorkouts) -> HelioSession {
        let transport = DetectedTransport(device: device)
        let keys = DetectedKeys()
        let session = HelioSession(transport: transport, identityID: strapID,
                                   key: keys.load(), keyStore: keys, sink: HelioStoreSink(store: store, workouts: inbox),
                                   findState: HelioFindState(), clock: { [unowned self] in self.now },
                                   autoTick: false, autoSyncOnConnect: false)
        session.orphanStop = StrapWorkoutOrphanStop(defaults)
        session.stepStreamFlag = StrapStepStreamFlag(defaults)
        transport.session = session
        session.start()
        transport.drain()
        XCTAssertTrue(session.ready)
        session.syncHistory(manual: true)
        transport.drain()
        XCTAssertFalse(session.syncing)
        return session
    }

    private func walkStarts(_ device: FakeZeppDevice) -> [[UInt8]] {
        device.fetchStarts.filter { $0.count == 10 && ($0[1] == 0x05 || $0[1] == 0x06) }
    }

    // MARK: The walk (91a)

    func testTheSyncWalksTheStrapsWorkoutsAfterEveryOtherTypeAndOffersOnlyTheKeptOnes() throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [
            Record.strap(start: at(-5 * 3600), minutes: 25),                  // kept
            Record.strap(start: at(-4 * 3600), minutes: 9.99),                // 599 s: too short
            Record.strap(start: at(-3 * 3600), minutes: 10, sport: 0xe3),     // exactly 10 min: kept
            Record.strap(start: at(-840), minutes: 10),                       // ended 4 min ago: not yet
        ]
        let session = sync(device, store: store, inbox: inbox)

        XCTAssertEqual(inbox.items.map(\.start), [at(-3 * 3600), at(-5 * 3600)], "newest first, nothing under 10 min, nothing unsettled")
        XCTAssertEqual(inbox.items.first?.suggestedSport, .pickleball)
        XCTAssertEqual(inbox.items.last?.suggestedSport, .other, "df is Other")
        XCTAssertEqual(inbox.items.last?.kilocalories, 150)
        XCTAssertEqual(inbox.items.last?.heartRate.count, 1500, "the readings outside the window are trimmed")

        // The existing types first, in their order and with their bytes unchanged; the walk after all of them.
        let starts = device.fetchStarts
        let firstWalk = try XCTUnwrap(starts.firstIndex { $0[1] == 0x05 })
        XCTAssertFalse(starts[firstWalk...].contains { ZeppFetchType(rawValue: $0[1]) != nil })
        let plan = HelioFetchPlan.plan(cursors: [:], now: now, notBefore: .distantPast)
        XCTAssertEqual(Array(starts[..<firstWalk]), plan.map { ZeppFetchCommand.start($0.type, since: $0.since, timeZone: .current) })
        // The walk: two days back the first time, seconds in every *since*.
        XCTAssertEqual(starts[firstWalk], ZeppWorkoutWalk.startCommand(.summary, since: at(-2 * 86_400), timeZone: .current))
        XCTAssertEqual(walkStarts(device).count, 4 * 2 + 1, "a pair per record, then the zero-length summary")
        XCTAssertEqual(Set(device.fetchAcks), [0x09], "decision 8 / 91a: 03 09 on every round")
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)
        XCTAssertEqual(Set(session.fetchAcksSent), [0x09])
        XCTAssertEqual(session.lastSyncResult?.interrupted, false)
        XCTAssertEqual(session.lastSyncResult?.roundsFailed, 0)
        // 91c: the cursor stops before the record that can still change.
        XCTAssertEqual(inbox.cursor(for: strapTimeline), at(-3 * 3600))
    }

    func testTheNextSyncStartsAtTheCursorAndARedeliveryNeverDuplicatesAndItSurvivesARelaunch() throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(-5 * 3600), minutes: 25), Record.strap(start: at(-3 * 3600), minutes: 30),
                                 Record.strap(start: at(-900), minutes: 20)]   // ends 5 min from now
        sync(device, store: store, inbox: inbox)
        XCTAssertEqual(inbox.items.count, 2)

        now = at(600)   // the last one has settled
        let before = device.fetchStarts.count
        sync(device, store: store, inbox: inbox)
        let second = Array(device.fetchStarts[before...]).filter { $0[1] == 0x05 || $0[1] == 0x06 }
        XCTAssertEqual(second.first, ZeppWorkoutWalk.startCommand(.summary, since: at(-3 * 3600), timeZone: .current),
                       "from the cursor: the newest record judged for good, to the second")
        XCTAssertEqual(inbox.items.map(\.start), [at(-900), at(-3 * 3600), at(-5 * 3600)])

        now = at(1200)
        sync(device, store: store, inbox: inbox)
        XCTAssertEqual(inbox.items.count, 3, "the re-delivered records are the same ones")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])

        let relaunched = makeInbox()
        XCTAssertEqual(relaunched.items, inbox.items, "the inbox survives a relaunch")
    }

    func testACRCMismatchOnADetailStoresNothingForItAndTheNextSyncFetchesItAgain() throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        let first = Record.strap(start: at(-5 * 3600), minutes: 25)
        device.workoutRecords = [first, Record.strap(start: at(-3 * 3600), minutes: 30)]
        device.corruptWorkoutRounds = [.init(type: 0x06, start: first.start)]
        let session = sync(device, store: store, inbox: inbox)
        XCTAssertEqual(inbox.items.map(\.start), [at(-3 * 3600)], "nothing for the bad record; the walk went on")
        XCTAssertEqual(session.lastSyncResult?.roundsFailed, 1)
        XCTAssertEqual(Set(device.fetchAcks), [0x09], "the bad round stays on the strap")
        let timeline = strapTimeline
        XCTAssertNil(inbox.cursor(for: timeline), "the cursor never passes a failed record")

        device.corruptWorkoutRounds = []
        now = at(600)
        let before = device.fetchStarts.count
        sync(device, store: store, inbox: inbox)
        XCTAssertEqual(device.fetchStarts[before...].first { $0[1] == 0x05 },
                       ZeppWorkoutWalk.startCommand(.summary, since: at(600 - 2 * 86_400), timeZone: .current))
        XCTAssertEqual(device.workoutRoundsServed.filter { $0 == .init(type: 0x06, start: first.start) }.count, 2, "fetched again")
        XCTAssertEqual(inbox.items.map(\.start), [at(-3 * 3600), at(-5 * 3600)])
        XCTAssertEqual(inbox.cursor(for: timeline), at(-3 * 3600))
    }

    func testTheWalkStopsAtFortyRecordsAndTheNextSyncGoesOn() throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = (0..<45).map { Record.strap(start: at(-3600 - TimeInterval(45 - $0) * 1800), minutes: 15) }
        sync(device, store: store, inbox: inbox)
        XCTAssertEqual(walkStarts(device).filter { $0[1] == 0x05 }.count, 40)
        XCTAssertEqual(inbox.items.count, 40)

        now = at(60)
        sync(device, store: store, inbox: inbox)
        XCTAssertEqual(inbox.items.count, 45)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    func testRingOnlyStateIssuesNoWorkoutFetchAndShowsNoStrapRecords() throws {
        ownership.install(DeviceOwnershipLog())   // the ring owns all time
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(-5 * 3600), minutes: 25)]
        sync(device, store: store, inbox: inbox)
        XCTAssertTrue(walkStarts(device).isEmpty, "no 0x05 / 0x06 fetch for time the ring owns")
        XCTAssertTrue(inbox.state.pending.isEmpty)

        // A record kept while the strap was chosen isn't offered once the ring is.
        ownership.install(.strapOwnsAllTime)
        inbox.judge(try Record.parsed(start: at(-5 * 3600), minutes: 25), timeline: strapTimeline, owned: true, now: now)
        XCTAssertEqual(inbox.items.count, 1)
        strapChosen = false
        XCTAssertTrue(inbox.items.isEmpty)
    }

    // MARK: Keep and persist (91c)

    func testTheWalkNeverStartsBeforeTheStrapsOwnership() throws {
        // The strap became the chosen device ten minutes into the first workout.
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-5 * 3600 + 600))]))
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(-5 * 3600), minutes: 25), Record.strap(start: at(-3 * 3600), minutes: 25)]
        sync(device, store: store, inbox: inbox)
        XCTAssertEqual(inbox.items.map(\.start), [at(-3 * 3600)])
        XCTAssertEqual(walkStarts(device).first, ZeppWorkoutWalk.startCommand(.summary, since: at(-5 * 3600 + 600), timeZone: .current))
    }

    /// Decision 28 in the sink: a delivered record whose window the strap owns only in part is dropped
    /// (the walk's start bound keeps one from arriving; this is the rule that would catch it).
    func testTheSinkDropsARecordTheStrapOwnsOnlyPartOf() throws {
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: at(-86_400)),
                                                       .init(family: .ringConn, since: at(-5 * 3600 + 600)),
                                                       .init(family: .zeppOS, since: at(-4 * 3600))]))
        let inbox = makeInbox()
        let sink = HelioStoreSink(store: try makeStore(), workouts: inbox)
        XCTAssertNotNil(sink.workoutWalkSince(timeline: strapTimeline, now: now))
        XCTAssertTrue(sink.persistWorkout(try Record.parsed(start: at(-5 * 3600), minutes: 25), timeline: strapTimeline, now: now))
        XCTAssertTrue(inbox.items.isEmpty, "a switch to the ring ten minutes in")
        XCTAssertTrue(sink.persistWorkout(try Record.parsed(start: at(-6 * 3600), minutes: 25), timeline: strapTimeline, now: now))
        XCTAssertEqual(inbox.items.map(\.start), [at(-6 * 3600)], "wholly the strap's")
        XCTAssertTrue(sink.persistWorkout(try Record.parsed(start: at(-3 * 3600), minutes: 25), timeline: strapTimeline, now: now))
        XCTAssertEqual(inbox.items.map(\.start), [at(-3 * 3600), at(-6 * 3600)])
        sink.finishWorkoutWalk(timeline: strapTimeline, now: now)
        XCTAssertEqual(inbox.cursor(for: strapTimeline), at(-3 * 3600))
    }

    func testARecordOverlappingADeletedWorkoutIsNotOffered() throws {
        WorkoutTombstones(defaults).record(start: at(-5 * 3600 + 300), end: at(-5 * 3600 + 900))
        let inbox = makeInbox()
        XCTAssertEqual(inbox.judge(try Record.parsed(start: at(-5 * 3600), minutes: 25), timeline: strapTimeline, owned: true, now: now),
                       .drop(.deleted))
        XCTAssertEqual(inbox.judge(try Record.parsed(start: at(-3 * 3600), minutes: 25), timeline: strapTimeline, owned: true, now: now), .keep)
        XCTAssertEqual(inbox.items.count, 1)
    }

    func testAKeptRecordIsPrunedAfterTwoDays() throws {
        let inbox = makeInbox()
        inbox.judge(try Record.parsed(start: at(-3600), minutes: 25), timeline: strapTimeline, owned: true, now: now)
        XCTAssertEqual(inbox.items.count, 1)
        now = at(2 * 86_400 - 3600 + 1500 - 1)
        XCTAssertEqual(inbox.items.count, 1, "still inside two days of its end")
        now = at(2 * 86_400 - 3600 + 1500 + 1)
        XCTAssertTrue(inbox.items.isEmpty)
        inbox.judge(try Record.parsed(start: now.addingTimeInterval(-3600), minutes: 25), timeline: strapTimeline, owned: true, now: now)
        XCTAssertEqual(makeInbox().state.pending.map(\.start), [now.addingTimeInterval(-3600)], "the next write prunes the stored copy")
    }

    // MARK: Review (91d)

    func testSavingWritesOneWorkoutThroughTheStrapsHealthPathAndTheRecordLeavesTheInbox() async throws {
        let inbox = makeInbox()
        var changed = 0
        inbox.onWorkoutsChanged = { changed += 1 }
        let record = try Record.parsed(start: at(-5 * 3600), minutes: 25, kcal: 212)
        inbox.judge(record, timeline: strapTimeline, owned: true, now: now)
        let item = try XCTUnwrap(inbox.items.first)

        let saved = await inbox.save(item, as: .tennis)
        XCTAssertTrue(saved)
        XCTAssertEqual(health.writes.count, 1, "one workout")
        let write = try XCTUnwrap(health.writes.first)
        XCTAssertEqual(write.summary.summary.sport, .tennis, "the sport chosen")
        XCTAssertEqual(write.summary.summary.startDate, at(-5 * 3600))
        XCTAssertEqual(write.summary.summary.endDate, at(-5 * 3600 + 1500))
        XCTAssertEqual(write.summary.summary.estimatedActiveKcal, 212, "the record's 16.1")
        XCTAssertEqual(write.summary.summary.avgHR, 118, "the record's 19.1")
        XCTAssertEqual(write.samples.count, 1500)
        XCTAssertTrue(write.samples.allSatisfy { $0.start >= at(-5 * 3600) && $0.end <= at(-5 * 3600 + 1500) },
                      "only the readings inside the workout")
        XCTAssertTrue(write.route.isEmpty)
        XCTAssertEqual(write.timeline, strapTimeline)
        XCTAssertTrue(write.summary.pauses.isEmpty)

        XCTAssertTrue(inbox.items.isEmpty, "the row is gone")
        XCTAssertEqual(changed, 1, "the history reloads")
        XCTAssertEqual(inbox.judge(record, timeline: strapTimeline, owned: true, now: now), .drop(.inHistory),
                       "a re-delivery of a saved record is in the history")
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testAFailedSaveKeepsTheRecordWithTheRingsCopy() async throws {
        health.succeeds = false
        let inbox = makeInbox()
        inbox.judge(try Record.parsed(start: at(-5 * 3600), minutes: 25), timeline: strapTimeline, owned: true, now: now)
        let item = try XCTUnwrap(inbox.items.first)
        let saved = await inbox.save(item, as: .other)
        XCTAssertFalse(saved)
        XCTAssertEqual(inbox.items, [item], "still there to try again")
        XCTAssertEqual(inbox.saveError, "Apple Health did not accept the detected workout. It was not removed, so you can try again.")
    }

    func testADiscardedRecordNeverComesBackWhenTheStrapDeliversItAgain() throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(-5 * 3600), minutes: 25), Record.strap(start: at(-3 * 3600), minutes: 30)]
        sync(device, store: store, inbox: inbox)
        // The newest is the cursor, so every later walk delivers it again.
        inbox.discard(try XCTUnwrap(inbox.items.first { $0.start == at(-3 * 3600) }))
        now = at(600)
        sync(device, store: store, inbox: inbox)
        XCTAssertTrue(device.workoutRoundsServed.filter { $0.start == UInt32(at(-3 * 3600).timeIntervalSince1970) }.count >= 4,
                      "delivered again")
        XCTAssertEqual(inbox.items.map(\.start), [at(-5 * 3600)])
        XCTAssertEqual(makeInbox().items.map(\.start), [at(-5 * 3600)], "and not after a relaunch either")
    }

    func testASavedRecordNeverComesBackWhenTheStrapDeliversItAgain() async throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(-3 * 3600), minutes: 30)]
        sync(device, store: store, inbox: inbox)
        let saved = await inbox.save(try XCTUnwrap(inbox.items.first), as: .strengthTraining)
        XCTAssertTrue(saved)
        now = at(600)
        sync(device, store: store, inbox: inbox)
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertEqual(health.writes.count, 1)
    }

    // MARK: The active-energy credit: today only, the strap's own rule (91d)

    func testTheActiveEnergyCreditIsTakenOnlyForARecordThatEndedToday() async throws {
        let keys = [HealthKitWriter.workoutActiveKcalKey, HealthKitWriter.workoutActiveKcalDayKey,
                    HealthKitWriter.workoutCreditedSpansKey, HealthKitWriter.workoutCreditedSpansDayKey]
        let standard = UserDefaults.standard
        let saved = keys.map { standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) } }
        keys.forEach { standard.removeObject(forKey: $0) }

        func save(endingAt end: Date) async throws -> CreditBuilder {
            let builder = CreditBuilder()
            let inbox = StrapDetectedWorkouts(defaults: freshDefaults(),
                                              writer: StrapWorkoutHealthWriter(isHealthDataAvailable: { true }, makeBuilder: { _, _ in builder }),
                                              historyWindows: { _ in [] }, notify: { _ in true },
                                              zones: { HeartRateZones(percentOfMax: 185) }, isStrapChosen: { true }, clock: { end })
            let item = StrapDetectedWorkout(try Record.parsed(start: end.addingTimeInterval(-1500), minutes: 25, kcal: 180),
                                            timeline: strapTimeline)
            let ok = await inbox.save(item, as: .other)
            XCTAssertTrue(ok)
            return builder
        }

        let yesterday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
        let old = try await save(endingAt: yesterday)
        XCTAssertEqual(old.samples.compactMap { $0 as? HKQuantitySample }.filter { $0.quantityType == HKQuantityType(.activeEnergyBurned) }
                        .map { $0.quantity.doubleValue(for: .kilocalorie()) }, [180], "the workout still carries its energy")
        XCTAssertEqual(standard.double(forKey: HealthKitWriter.workoutActiveKcalKey), 0, "no credit for a record that ended yesterday")

        let today = try await save(endingAt: Date())
        XCTAssertEqual(today.samples.compactMap { $0 as? HKQuantitySample }.filter { $0.quantityType == HKQuantityType(.heartRate) }.count, 1500)
        XCTAssertEqual(standard.double(forKey: HealthKitWriter.workoutActiveKcalKey), 180, "today's record is credited")
    }

    // MARK: The notification (91e)

    func testANewlyKeptRecordIsAnnouncedOnceAndNeverAfterADay() async throws {
        let inbox = makeInbox()
        inbox.judge(try Record.parsed(start: at(-3 * 3600), minutes: 30), timeline: strapTimeline, owned: true, now: now)
        inbox.judge(try Record.parsed(start: at(-26 * 3600), minutes: 30), timeline: strapTimeline, owned: true, now: now)   // ended 25.5 h ago
        await inbox.reconcile()
        XCTAssertEqual(notified, [at(-3 * 3600)], "once, and not for the one that ended over a day ago")
        await inbox.reconcile()
        XCTAssertEqual(notified.count, 1)
        await makeInbox().reconcile()
        XCTAssertEqual(notified.count, 1, "not again after a relaunch")
        XCTAssertEqual(makeInbox().items.count, 2, "both stay in the inbox")
    }

    func testTheSyncAnnouncesItsNewRecord() async throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(-3 * 3600), minutes: 30)]
        sync(device, store: store, inbox: inbox)
        for _ in 0..<50 where notified.isEmpty { await Task.yield() }
        XCTAssertEqual(notified, [at(-3 * 3600)])
        now = at(600)
        sync(device, store: store, inbox: inbox)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(notified.count, 1, "the re-delivered record isn't announced twice")
    }

    func testAReconcileDropsARecordTheHistoryNowCovers() async throws {
        let inbox = StrapDetectedWorkouts(defaults: defaults, writer: health,
                                          historyWindows: { _ in [DateInterval(start: at(-3 * 3600 + 60), duration: 600)] },
                                          notify: { [unowned self] item in self.notified.append(item.start); return true },
                                          zones: { HeartRateZones(percentOfMax: 185) }, isStrapChosen: { true },
                                          clock: { [unowned self] in self.now })
        inbox.judge(try Record.parsed(start: at(-3 * 3600), minutes: 30), timeline: strapTimeline, owned: true, now: now)
        XCTAssertEqual(inbox.items.count, 1)
        await inbox.reconcile()
        XCTAssertTrue(inbox.items.isEmpty, "a workout in Apple Health already covers it")
        XCTAssertTrue(notified.isEmpty)
    }

    func testTheCopyFitsTheNotificationBudget() {
        for minutes in [10.0, 25, 89, 90, 240] {
            for start in [now, now.addingTimeInterval(-86_400)] {
                let copy = StrapDetectedWorkouts.notificationCopy(duration: minutes * 60, start: start, now: now)
                XCTAssertTrue(NotificationBudget.fits(copy.body), copy.body)
            }
        }
    }
}
