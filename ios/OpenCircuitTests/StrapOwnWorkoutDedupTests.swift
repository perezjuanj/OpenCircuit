import CoreLocation
import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 91h (review-strap-workouts B1, B2, S-1): OpenCircuit's own workouts are never offered back
// by the strap's inbox, whatever Apple Health answers, and a BGTask run that adopts a sync mid-walk stops
// the walk. Q1, Q1b and Q2 are the review's probes, kept with their parameters. Every time, reading and
// record is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let keyHex = "00112233445566778899aabbccddeeff"
private let strapID = "5B1E4C2A-0000-4000-8000-0000000000D4"
private let strapTimeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: strapID)
private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strap-own-\(UUID().uuidString)")! }

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
private final class OwnTransport: HelioTransport {
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
    var onWrite: (ZeppWrite) -> Void = { _ in }
    func write(_ write: ZeppWrite) {
        onWrite(write)
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
private final class OwnKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
private final class OwnHealth: StrapWorkoutHealthWriting {
    var succeeds = true
    private(set) var writes: [StrapWorkoutWrite] = []
    func save(_ write: StrapWorkoutWrite) async -> Bool {
        writes.append(write)
        return succeeds
    }
}

// MARK: - Recorder fakes (copied from IndoorRunRecorderTests)

@MainActor
private final class OwnStepSource: StrapWorkoutHeartRateSource, StrapWorkoutStepSource {
    let timeline: SyncDeviceID
    var isLinkConnected = true
    var ready = true
    var syncing = false
    var canStreamHeartRate = true
    var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    var rrIntervalsReceived = 0
    var stepCounterObserver: (@MainActor (Int, Date) -> Void)?
    /// What the source was asked, in order: "on", "off", "owed-off".
    private(set) var commands: [String] = []
    var hasSteps = true
    /// The stream is on, as the session's: frames reach the observer only then (unless forced).
    private(set) var on = false

    init(timeline: SyncDeviceID) { self.timeline = timeline }

    private(set) var syncRequests = 0
    var log: OwnEventLog?

    func startWorkoutHeartRate() {}
    func stopWorkoutHeartRate() {}
    func sendOwedOrphanStop() {}
    func syncHistory(manual: Bool) { syncRequests += 1; log?.add("sync") }
    func startWorkoutSteps() -> Bool {
        guard hasSteps else { return false }
        commands.append("on")
        on = true
        return true
    }
    func stopWorkoutSteps() { commands.append("off"); on = false }
    func sendOwedStepsOff() { commands.append("owed-off") }

    /// One frame. `force`: delivered even with the stream off (a frame already in flight at a pause).
    func counter(_ value: Int, at date: Date, force: Bool = false) {
        guard on || force else { return }
        stepCounterObserver?(value, date)
    }
    func heartRate(_ bpm: Int, at date: Date) { heartRateObserver?(bpm, date) }
}

/// The order things happened in, across the fakes.
@MainActor
private final class OwnEventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

@MainActor
private final class OwnWorkoutHealth: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    var accept = true
    var log: OwnEventLog?
    func save(_ write: StrapWorkoutWrite) async -> Bool {
        writes.append(write)
        log?.add("workout saved")
        return accept
    }
}

@MainActor
private final class OwnRecoveryWrites: HeartRateRecoveryHealthWriting {
    private(set) var readingWrites = 0
    private(set) var cardioWrites = 0
    var log: OwnEventLog?
    func saveRecoveryHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus {
        readingWrites += 1
        log?.add("recovery readings saved")
        return .saved
    }
    func saveCardioRecovery(_ bpm: Int, at date: Date, timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus {
        cardioWrites += 1
        log?.add("cardio recovery saved")
        return .saved
    }
}

@MainActor
private final class OwnIndoorHealth: IndoorRunHealthWriting {
    private(set) var metrics: [(minutes: [IndoorRunMinuteSample], estimated: Bool)] = []
    private(set) var replacements: [(workout: DateInterval, meters: Double)] = []
    private(set) var vo2: [(estimate: VO2MaxEstimate.Estimate, end: Date)] = []
    var replaceStatus: IndoorRunHealthStatus = .saved
    func saveRunningMetrics(_ minutes: [IndoorRunMinuteSample], estimated: Bool, timeline: SyncDeviceID) async -> IndoorRunHealthStatus {
        metrics.append((minutes, estimated))
        return .saved
    }
    func replaceEstimate(workout: DateInterval, typedMeters: Double, timeline: SyncDeviceID) async -> IndoorRunHealthStatus {
        replacements.append((workout, typedMeters))
        return replaceStatus
    }
    func saveVO2Max(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date, timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status {
        vo2.append((estimate, workoutEnd))
        return .saved
    }
}

@MainActor
private final class OwnJournal: StrapWorkoutJournalStoring {
    var journal: StrapWorkoutJournal?
    var samples: [HRSample] = []
    var landing: [StrapWorkoutLandingBatch] = []
    var parked: [StrapWorkoutParked] = []
    func loadJournal() -> StrapWorkoutJournal? { journal }
    func saveJournal(_ journal: StrapWorkoutJournal) { self.journal = journal }
    func appendSamples(_ samples: [HRSample]) { self.samples += samples }
    func loadSamples() -> [HRSample] { samples }
    func clearRunning() { journal = nil; samples = [] }
    func parkRunning() { clearRunning() }
    func loadParked() -> [StrapWorkoutParked] { parked }
    func saveParked(_ parked: [StrapWorkoutParked]) { self.parked = parked }
    func loadLanding() -> [StrapWorkoutLandingBatch] { landing }
    func saveLanding(_ batches: [StrapWorkoutLandingBatch]) { landing = batches }
}

@MainActor
private final class OwnTreadmill: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    func start(route: Bool) {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
}

@MainActor
private final class OwnHRStore: StrapWorkoutHRStore {
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {}
}

@MainActor
private final class OwnVO2Inputs: StrapVO2MaxProviding {
    func userSetAge() -> Int? { 40 }
    func restingHR(workoutStart: Date, workoutEnd: Date) -> Double? { 60 }
    func save(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date, timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status { .saved }
}

// MARK: - Tests

@MainActor
final class StrapOwnWorkoutDedupTests: XCTestCase {
    private var now = t0
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private var defaults = freshDefaults()
    private let health = OwnHealth()
    private var notified: [Date] = []
    /// What Apple Health returns to the inbox's history read (the probes' model: [] for the locked reads).
    private var healthHistory: [DateInterval] = []
    private var recorders: [StrapWorkoutRecorder] = []

    override func setUp() { super.setUp(); ownership.install(.strapOwnsAllTime) }
    override func tearDown() {
        for recorder in recorders where recorder.isRecording { recorder.cancel() }
        recorders.removeAll()
        ownership.restore()
        containers.removeAll()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "no test may leave the strap held")
        super.tearDown()
    }

    private func makeInbox(read: (@MainActor (DateInterval) async -> [DateInterval]?)? = nil) -> StrapDetectedWorkouts {
        StrapDetectedWorkouts(defaults: defaults, writer: health,
                              historyWindows: read ?? { [unowned self] _ in self.healthHistory },
                              notify: { [unowned self] item in self.notified.append(item.start); return true },
                              zones: { HeartRateZones(percentOfMax: 185) }, isStrapChosen: { true },
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
    private func connected(_ device: FakeZeppDevice, store: LocalStore, inbox: StrapDetectedWorkouts) -> (HelioSession, OwnTransport) {
        let transport = OwnTransport(device: device)
        let keys = OwnKeys()
        let session = HelioSession(transport: transport, identityID: strapID, key: keys.load(), keyStore: keys,
                                   sink: HelioStoreSink(store: store, workouts: inbox), findState: HelioFindState(),
                                   clock: { [unowned self] in self.now }, autoTick: false, autoSyncOnConnect: false)
        session.orphanStop = StrapWorkoutOrphanStop(defaults)
        session.stepStreamFlag = StrapStepStreamFlag(defaults)
        transport.session = session
        session.start()
        transport.drain()
        XCTAssertTrue(session.ready)
        return (session, transport)
    }
    private func sync(_ device: FakeZeppDevice, store: LocalStore, inbox: StrapDetectedWorkouts) async {
        let (session, transport) = connected(device, store: store, inbox: inbox)
        session.syncHistory(manual: true)
        transport.drain()
        XCTAssertFalse(session.syncing)
        for _ in 0..<100 { await Task.yield() }   // the reconcile task
    }
    private func walkStarts(_ device: FakeZeppDevice) -> [[UInt8]] {
        device.fetchStarts.filter { $0.count == 10 && ($0[1] == 0x05 || $0[1] == 0x06) }
    }

    // MARK: B1: the review's probes Q1 and Q1b

    /// Q1: the strap's record of a workout OpenCircuit itself recorded (workout mode, W) stays out of the
    /// inbox after Health reads that come back with nothing (a locked phone), because the app's own
    /// window list, not the Health cache, says W is ours.
    func testQ1ARecordOfTheAppsOwnWorkoutIsNeverOfferedWhateverHealthReturnsLater() async throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        let genuine = Record.strap(start: at(-6 * 3600), minutes: 25)          // a real auto-detected activity
        let mine = Record.strap(start: at(-2 * 3600), minutes: 45, sport: 0x34) // the strap's record of OUR workout W
        let w = DateInterval(start: at(-2 * 3600), duration: 45 * 60)
        device.workoutRecords = [genuine, mine]
        OwnWorkoutWindows(defaults).record(start: w.start, end: w.end, now: w.end)   // OpenCircuit recorded W (91h)

        healthHistory = [w]   // sync 1: Health readable, W is in it
        await sync(device, store: store, inbox: inbox)
        XCTAssertEqual(inbox.items.map(\.start), [at(-6 * 3600)], "sync 1: W's record correctly not offered")
        XCTAssertEqual(notified, [at(-6 * 3600)])

        healthHistory = []    // sync 2: background strap wake, phone locked: the read comes back empty
        now = at(600)
        await sync(device, store: store, inbox: inbox)

        now = at(1200)        // sync 3: still locked
        await sync(device, store: store, inbox: inbox)
        XCTAssertFalse(inbox.items.contains { $0.start == at(-2 * 3600) }, "W's own strap record is offered for review")
        XCTAssertFalse(notified.contains(at(-2 * 3600)), "and announced as a new strap workout")
        XCTAssertEqual(inbox.items.map(\.start), [at(-6 * 3600)])
    }

    /// Q1b: the first sync to see W's record runs while Health can't be read.
    func testQ1bFirstSightingWhileHealthUnreadable() async throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(-2 * 3600), minutes: 45, sport: 0x34)]
        OwnWorkoutWindows(defaults).record(start: at(-2 * 3600), end: at(-2 * 3600 + 45 * 60), now: at(-2 * 3600 + 45 * 60))
        healthHistory = []
        await sync(device, store: store, inbox: inbox)
        XCTAssertTrue(inbox.items.isEmpty, "the local list of OpenCircuit's own workouts backs the Health read")
        XCTAssertTrue(notified.isEmpty)
    }

    // MARK: B1: the read is fail-closed

    func testALockedOrFailedReadKeepsTheOldCacheAndAnnouncesNothing() async throws {
        var read: [DateInterval]? = []
        let inbox = makeInbox(read: { _ in read })
        let w = DateInterval(start: at(-2 * 3600), duration: 45 * 60)   // in Health, NOT in the local list
        read = [w]
        await inbox.reconcile()
        XCTAssertEqual(inbox.state.history.map(\.interval), [w])

        inbox.judge(try Record.parsed(start: at(-5 * 3600), minutes: 25), timeline: strapTimeline, owned: true, now: now)
        read = nil   // locked phone / query error
        await inbox.reconcile()
        XCTAssertEqual(inbox.state.history.map(\.interval), [w], "the previous cache is kept")
        XCTAssertTrue(notified.isEmpty, "a pass that couldn't read Health announces nothing")
        XCTAssertEqual(inbox.judge(try Record.parsed(start: at(-2 * 3600), minutes: 45, sport: 0x34), timeline: strapTimeline,
                                   owned: true, now: now), .drop(.inHistory), "the kept cache still covers W")
        XCTAssertEqual(makeInbox(read: { _ in nil }).state.history.map(\.interval), [w], "and survives a relaunch")

        read = []    // readable again
        await inbox.reconcile()
        XCTAssertEqual(notified, [at(-5 * 3600)], "announced once the read works")
    }

    func testAnEmptySuccessfulReadWithTheOwnWindowStillDropsOurWorkout() async throws {
        let w = DateInterval(start: at(-2 * 3600), duration: 45 * 60)
        let inbox = makeInbox(read: { _ in [] })   // Workouts read denied: a real, empty answer
        // Kept before the app's End was known (the strap's record arrived first), then W is recorded.
        XCTAssertEqual(inbox.judge(try Record.parsed(start: w.start, minutes: 45, sport: 0x34), timeline: strapTimeline,
                                   owned: true, now: now), .keep)
        OwnWorkoutWindows(defaults).record(start: w.start, end: w.end, now: now)
        await inbox.reconcile()
        XCTAssertTrue(inbox.items.isEmpty, "the reconcile drops it from the local list alone")
        XCTAssertTrue(notified.isEmpty)
        XCTAssertEqual(inbox.judge(try Record.parsed(start: w.start, minutes: 45, sport: 0x34), timeline: strapTimeline,
                                   owned: true, now: now), .drop(.inHistory))
    }

    func testEverySaveTheInboxMakesIsRecordedAsTheAppsOwn() async throws {
        let inbox = makeInbox()
        inbox.judge(try Record.parsed(start: at(-5 * 3600), minutes: 25), timeline: strapTimeline, owned: true, now: now)
        let saved = await inbox.save(try XCTUnwrap(inbox.items.first), as: .other)
        XCTAssertTrue(saved)
        XCTAssertEqual(OwnWorkoutWindows(defaults).windows, [DateInterval(start: at(-5 * 3600), duration: 1500)])
    }

    func testTheOwnWindowsArePrunedAfterTheInboxsBookkeeping() {
        let own = OwnWorkoutWindows(defaults)
        own.record(start: at(-3600), end: at(-1800), now: now)
        own.record(start: at(0), end: at(600), now: at(-1800 + OwnWorkoutWindows.retention))
        XCTAssertEqual(own.windows.count, 2, "exactly at the retention")
        own.record(start: at(1200), end: at(1800), now: at(-1800 + OwnWorkoutWindows.retention + 1))
        XCTAssertEqual(own.windows.map(\.start), [at(0), at(1200)])
    }

    // MARK: S-1: an indoor run's deferred save

    private final class Box { var value: OwnStepSource; init(_ v: OwnStepSource) { value = v } }

    /// A strap indoor run that ends and waits for its distance prompt (84j): its window is OpenCircuit's own
    /// from End, so a sync between End and the deferred Health save never offers the strap's record of it.
    func testAnIndoorRunWaitingForItsSaveIsNeverOfferedBySyncInBetween() async throws {
        let source = OwnStepSource(timeline: strapTimeline)
        let box = Box(source)
        let workoutHealth = OwnWorkoutHealth()
        let profile = UserProfile(age: 40, weightKg: 70, heightCm: 180, sex: .male)
        let recorder = StrapWorkoutRecorder(
            source: { box.value }, health: workoutHealth, journal: OwnJournal(), hrStore: { OwnHRStore() },
            location: OwnTreadmill(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(freshDefaults()), vo2: OwnVO2Inputs(),
            tombstones: WorkoutTombstones(defaults), ownWindows: OwnWorkoutWindows(defaults),
            recoveryWindows: WorkoutRecoveryWindows(freshDefaults()), indoorHealth: OwnIndoorHealth(),
            stepStreamFlag: StrapStepStreamFlag(freshDefaults()), strideCalibrations: IndoorStrideCalibrations(freshDefaults()),
            userHeightCm: { 180 }, clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = .runningIndoor
        recorders.append(recorder)

        // A 15-minute treadmill run from at(0), ended at at(900).
        now = at(0)
        recorder.start()
        source.counter(0, at: now)
        var counter = 0
        for s in stride(from: 10.0, through: 900, by: 10) {
            now = at(s)
            counter += 20
            source.counter(counter, at: now)
            source.heartRate(150, at: now)
            await recorder.tick(now: now)
        }
        await recorder.end()
        XCTAssertTrue(recorder.workoutSavePending, "waiting for the distance prompt")
        XCTAssertTrue(workoutHealth.writes.isEmpty, "nothing in Health yet")
        XCTAssertEqual(OwnWorkoutWindows(defaults).windows, [DateInterval(start: at(0), end: at(900))])

        // Six minutes later, still unsaved: a sync delivers the strap's own record of this run.
        now = at(900 + 360)
        healthHistory = []
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(0), minutes: 15, sport: 0x02)]
        await sync(device, store: store, inbox: inbox)
        XCTAssertEqual(walkStarts(device).count, 3, "the record was delivered")
        XCTAssertTrue(recorder.workoutSavePending)
        XCTAssertTrue(inbox.items.isEmpty, "the app's own run is not offered back")
        XCTAssertTrue(notified.isEmpty)

        // The same record on a phone that never recorded the run is offered: the list is what decided.
        defaults = freshDefaults()
        let other = makeInbox()
        await sync(device, store: try makeStore(), inbox: other)
        XCTAssertEqual(other.items.map(\.start), [at(0)])
        recorder.indoorRun?.skip()
        await recorder.workoutSaveTask?.value
    }

    func testARecoveredWorkoutsSaveIsRecordedAsTheAppsOwn() async {
        let workoutHealth = OwnWorkoutHealth()
        let recorder = StrapWorkoutRecorder(
            source: { nil }, health: workoutHealth, journal: OwnJournal(), hrStore: { OwnHRStore() },
            location: OwnTreadmill(), liveActivity: nil, profile: { UserProfile(age: 40, weightKg: 70, heightCm: 180, sex: .male) },
            indoorKeepAlive: { false }, orphanStop: StrapWorkoutOrphanStop(freshDefaults()),
            tombstones: WorkoutTombstones(defaults), ownWindows: OwnWorkoutWindows(defaults),
            recoveryWindows: WorkoutRecoveryWindows(freshDefaults()), stepStreamFlag: StrapStepStreamFlag(freshDefaults()),
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        let summary = WorkoutSummary(sport: .yoga, startDate: at(-4000), endDate: at(-1000), avgHR: nil, maxHR: nil,
                                     estimatedActiveKcal: nil, zoneBreakdown: WorkoutZoneBreakdown(), distanceMeters: nil,
                                     hasRoute: false, hrSampleCount: 0)
        let write = StrapWorkoutWrite(summary: StrapWorkoutSummary(summary: summary, activeSeconds: 3000, pauses: [], gaps: []),
                                      samples: [], route: [], timeline: strapTimeline)
        _ = await recorder.writeRecovered(write)
        XCTAssertEqual(workoutHealth.writes.count, 1)
        XCTAssertEqual(OwnWorkoutWindows(defaults).windows, [DateInterval(start: at(-4000), end: at(-1000))])
    }

    // MARK: B2: the review's probe Q2

    /// Q2: a BGTask run that adopts a session mid-walk (HelioBackgroundSyncService sets the flag on a session
    /// already syncing) stops the walk: no walk round is asked for after the adoption.
    func testQ2AnAdoptionMidWalkStopsTheWalk() throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = (0..<5).map { Record.strap(start: at(-10 * 3600 + TimeInterval($0) * 3600), minutes: 30) }
        let (session, transport) = connected(device, store: store, inbox: inbox)
        var walkStartsAfterAdoption = 0
        var adopted = false
        transport.onWrite = { [unowned session] w in
            let b = w.bytes
            guard b.count == 10, b[0] == 0x01 else { return }
            if adopted, b[1] == 0x05 || b[1] == 0x06 { walkStartsAfterAdoption += 1 }
            if !adopted, b[1] == 0x06 { adopted = true; session.backgroundRunOwnsSyncs = true }   // the run adopts here
        }
        session.syncHistory(manual: false)
        transport.drain()
        XCTAssertTrue(session.lastSyncResult?.endedInBackgroundRun == true)
        XCTAssertEqual(walkStartsAfterAdoption, 0, "the walk went on inside a BGTask-owned sync")
        XCTAssertFalse(session.syncing)
        XCTAssertEqual(session.lastSyncResult?.interrupted, false, "every history type had finished")
        XCTAssertEqual(session.lastSyncResult?.roundsFailed, 0)
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count, "the round opened at the adoption is acked")
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    func testAfterAnAdoptionStoppedTheWalkTheNextUnownedSyncResumesFromTheCursor() async throws {
        let store = try makeStore()
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = (0..<5).map { Record.strap(start: at(-10 * 3600 + TimeInterval($0) * 3600), minutes: 30) }
        let (session, transport) = connected(device, store: store, inbox: inbox)
        var details = 0
        transport.onWrite = { [unowned session] w in
            guard w.bytes.count == 10, w.bytes[0] == 0x01, w.bytes[1] == 0x06 else { return }
            details += 1
            if details == 3 { session.backgroundRunOwnsSyncs = true }   // adopted at the third record's detail
        }
        session.syncHistory(manual: false)
        transport.drain()
        XCTAssertEqual(inbox.items.count, 2, "the records judged before the adoption stay")
        XCTAssertEqual(inbox.cursor(for: strapTimeline), at(-9 * 3600))

        session.backgroundRunOwnsSyncs = false   // the run hands the session back
        transport.onWrite = { _ in }
        now = at(600)
        let before = device.fetchStarts.count
        session.syncHistory(manual: true)
        transport.drain()
        XCTAssertEqual(device.fetchStarts[before...].first { $0[1] == 0x05 },
                       ZeppWorkoutWalk.startCommand(.summary, since: at(-9 * 3600), timeZone: .current))
        XCTAssertEqual(inbox.items.count, 5)
    }
}
