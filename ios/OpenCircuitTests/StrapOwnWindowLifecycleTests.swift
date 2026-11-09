import CoreLocation
import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 91i (review-strap-workouts-b B3, B4): a strap workout's own window is written when it starts,
// refreshed at every journal heartbeat and at every exit, and never removed, so the strap's record of a
// workout OpenCircuit recorded is never offered back, however that workout ended: cancelled, killed,
// recovered later, discarded or put off. The two P2 tests are the review's probes, kept with their
// parameters. Every time, reading and record is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let keyHex = "00112233445566778899aabbccddeeff"
private let strapID = "5B1E4C2A-0000-4000-8000-0000000000D4"
private let strapTimeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: strapID)
private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strap-own-life-\(UUID().uuidString)")! }

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

// MARK: - Reviewer probes (review-strap-workouts-b, not for merge)

@MainActor
final class StrapOwnWindowLifecycleTests: XCTestCase {
    private var now = t0
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private var defaults = freshDefaults()
    private let health = OwnHealth()
    private var notified: [Date] = []
    /// nil = a failed / locked read (91h); [] = a genuine empty read.
    private var healthHistory: [DateInterval]? = []
    private var recorders: [StrapWorkoutRecorder] = []

    override func setUp() { super.setUp(); ownership.install(.strapOwnsAllTime) }
    override func tearDown() {
        for recorder in recorders where recorder.isRecording { recorder.cancel() }
        recorders.removeAll()
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeInbox() -> StrapDetectedWorkouts {
        StrapDetectedWorkouts(defaults: defaults, writer: health,
                              historyWindows: { [unowned self] _ in self.healthHistory },
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
    private func sync(_ device: FakeZeppDevice, store: LocalStore, inbox: StrapDetectedWorkouts) async {
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
        session.syncHistory(manual: true)
        transport.drain()
        XCTAssertFalse(session.syncing)
        for _ in 0..<100 { await Task.yield() }
    }
    private func walkStarts(_ device: FakeZeppDevice) -> Int {
        device.fetchStarts.filter { $0.count == 10 && ($0[1] == 0x05 || $0[1] == 0x06) }.count
    }

    private func makeRecorder(source: OwnStepSource?, health: OwnWorkoutHealth, journal: OwnJournal) -> StrapWorkoutRecorder {
        let profile = UserProfile(age: 40, weightKg: 70, heightCm: 180, sex: .male)
        return StrapWorkoutRecorder(
            source: { source }, health: health, journal: journal, hrStore: { OwnHRStore() },
            location: OwnTreadmill(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(freshDefaults()), vo2: OwnVO2Inputs(),
            tombstones: WorkoutTombstones(defaults), ownWindows: OwnWorkoutWindows(defaults),
            recoveryWindows: WorkoutRecoveryWindows(freshDefaults()), indoorHealth: OwnIndoorHealth(),
            stepStreamFlag: StrapStepStreamFlag(freshDefaults()), strideCalibrations: IndoorStrideCalibrations(freshDefaults()),
            userHeightCm: { 180 }, clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
    }

    /// Runs a strap workout from `from` to `to` seconds (1 reading / 10 s) through the REAL recorder.
    private func record(_ recorder: StrapWorkoutRecorder, _ source: OwnStepSource, from: TimeInterval, to: TimeInterval) async {
        now = at(from)
        recorder.start()
        XCTAssertTrue(recorder.isRecording)
        for s in stride(from: from + 10, through: to, by: 10) {
            now = at(s)
            source.heartRate(140, at: now)
            await recorder.tick(now: now)
        }
    }

    /// A strap workout the process dies in, from `from` to `to`; its journal is left behind.
    private func killed(_ journal: OwnJournal, _ source: OwnStepSource, from: TimeInterval, to: TimeInterval) async {
        let first = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: journal)
        first.selectedSport = .yoga
        await record(first, source, from: from, to: to)
    }

    private func syncWith(_ record: FakeZeppDevice.WorkoutRecord, at time: Date) async throws -> StrapDetectedWorkouts {
        healthHistory = []
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [record]
        now = time
        await sync(device, store: try makeStore(), inbox: inbox)
        XCTAssertEqual(walkStarts(device), 3, "the strap's record was delivered")
        return inbox
    }

    // MARK: The review's probes (P2)

    /// Cancel (discard) of a running strap workout: 89n says the strap still keeps its record (`03 02` + `03 04`).
    func testP2CancelledWorkoutIsNotOfferedBack() async throws {
        let source = OwnStepSource(timeline: strapTimeline)
        source.hasSteps = false
        let recorder = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: OwnJournal())
        recorder.selectedSport = .yoga
        recorders.append(recorder)
        await record(recorder, source, from: 0, to: 1800)
        recorder.cancel()

        now = at(1800 + 600)
        healthHistory = []
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(0), minutes: 30, sport: 0x34)]
        await sync(device, store: try makeStore(), inbox: inbox)
        XCTAssertTrue(inbox.items.isEmpty, "the workout the person discarded in OpenCircuit is offered back as a strap detection")
        XCTAssertTrue(notified.isEmpty)
        XCTAssertEqual(OwnWorkoutWindows(defaults).windows, [DateInterval(start: at(0), end: at(1800))], "kept, not removed")
    }

    /// A strap workout the process died in (relaunch → recovery offer → "Not now"): a sync in between, then the
    /// recovered Save. Two HKWorkouts over the same window if the person also saved the detection.
    func testP2InterruptedWorkoutBeforeItsRecoveredSave() async throws {
        let journal = OwnJournal()
        let source = OwnStepSource(timeline: strapTimeline)
        source.hasSteps = false
        do {
            let first = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: journal)
            first.selectedSport = .yoga
            await record(first, source, from: 0, to: 1805)   // then the process dies
        }
        XCTAssertNotNil(journal.journal)

        now = at(1805 + 900)    // relaunch
        let wHealth = OwnWorkoutHealth()
        let second = makeRecorder(source: source, health: wHealth, journal: journal)
        second.resolveOrphan()
        XCTAssertNotNil(second.recoverable)
        second.postponeRecovered()   // "Not now"

        healthHistory = []
        let inbox = makeInbox()
        let device = makeStrap()
        device.workoutRecords = [Record.strap(start: at(0), minutes: 31, sport: 0x34)]   // the strap ended it at the reconnect
        now = at(1805 + 900 + 600)
        await sync(device, store: try makeStore(), inbox: inbox)
        let offeredItem = inbox.items.first
        XCTAssertTrue(inbox.items.isEmpty, "OpenCircuit's interrupted workout is offered as a strap detection")
        XCTAssertTrue(notified.isEmpty)

        if let offeredItem {
            _ = await inbox.save(offeredItem, as: .yoga)
            let third = makeRecorder(source: source, health: wHealth, journal: journal)
            third.resolveOrphan()
            _ = await third.saveRecovered()
            XCTAssertFalse(health.writes.count + wHealth.writes.count > 1, "two HKWorkouts over one workout")
        }
        // The recovered Save still works, once, after the sync.
        let third = makeRecorder(source: source, health: wHealth, journal: journal)
        third.resolveOrphan()
        let savedRecovered = await third.saveRecovered()
        XCTAssertTrue(savedRecovered)
        XCTAssertEqual(health.writes.count + wHealth.writes.count, 1, "one HKWorkout")
    }

    // MARK: Decision 91i: every exit

    func testTheWindowIsWrittenWhenTheWorkoutStartsAndGrowsAtEachHeartbeat() async {
        let source = OwnStepSource(timeline: strapTimeline)
        source.hasSteps = false
        let recorder = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: OwnJournal())
        recorder.selectedSport = .yoga
        recorders.append(recorder)
        now = at(0)
        recorder.start()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(OwnWorkoutWindows(defaults).entries.map(\.start), [at(0)], "written at the start")
        for s in stride(from: 10.0, through: 600, by: 10) {
            now = at(s)
            source.heartRate(140, at: now)
            await recorder.tick(now: now)
        }
        let end = try? XCTUnwrap(OwnWorkoutWindows(defaults).entries.first?.end)
        XCTAssertGreaterThanOrEqual(end ?? .distantPast, at(590), "refreshed by the heartbeat")
        XCTAssertEqual(OwnWorkoutWindows(defaults).entries.count, 1, "one window per workout")
        recorder.cancel()
    }

    func testAKillMidWorkoutThenASyncBeforeAnyRelaunchDecisionDoesNotOfferIt() async throws {
        let journal = OwnJournal()
        let source = OwnStepSource(timeline: strapTimeline)
        source.hasSteps = false
        await killed(journal, source, from: 0, to: 1805)   // nothing in this process answers anything after this
        XCTAssertNotNil(journal.journal)
        let inbox = try await syncWith(Record.strap(start: at(0), minutes: 31, sport: 0x34), at: at(1805 + 900))
        XCTAssertTrue(inbox.items.isEmpty, "the heartbeat's window covers the workout the process died in")
        XCTAssertTrue(notified.isEmpty)
    }

    func testNotNowThenASyncDoesNotOfferItAndTheOfferComesBack() async throws {
        let journal = OwnJournal()
        let source = OwnStepSource(timeline: strapTimeline)
        source.hasSteps = false
        await killed(journal, source, from: 0, to: 1805)
        now = at(1805 + 900)
        let second = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: journal)
        second.resolveOrphan()
        XCTAssertNotNil(second.recoverable)
        second.postponeRecovered()
        let inbox = try await syncWith(Record.strap(start: at(0), minutes: 31, sport: 0x34), at: at(1805 + 1500))
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertTrue(notified.isEmpty)
        let next = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: journal)
        next.resolveOrphan()
        XCTAssertNotNil(next.recoverable, "Not now still asks again at the next launch")
    }

    func testARecoveryDiscardThenASyncDoesNotOfferIt() async throws {
        let journal = OwnJournal()
        let source = OwnStepSource(timeline: strapTimeline)
        source.hasSteps = false
        await killed(journal, source, from: 0, to: 1805)
        now = at(1805 + 900)
        let second = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: journal)
        second.resolveOrphan()
        XCTAssertNotNil(second.recoverable)
        second.discardRecovered()
        XCTAssertNil(journal.journal, "discarded")
        let inbox = try await syncWith(Record.strap(start: at(0), minutes: 31, sport: 0x34), at: at(1805 + 1500))
        XCTAssertTrue(inbox.items.isEmpty, "the person discarded the workout, not the dedup")
        XCTAssertTrue(notified.isEmpty)
        XCTAssertEqual(OwnWorkoutWindows(defaults).entries.map(\.start), [at(0)])
    }

    func testANewStartThatParksAnInterruptedWorkoutKeepsItsWindow() async throws {
        let journal = OwnJournal()
        let source = OwnStepSource(timeline: strapTimeline)
        source.hasSteps = false
        await killed(journal, source, from: 0, to: 1805)
        now = at(1805 + 900)
        let second = makeRecorder(source: source, health: OwnWorkoutHealth(), journal: journal)
        second.selectedSport = .yoga
        recorders.append(second)
        second.start()   // no recovery answer: the interrupted journal is set aside (`parkRunning`)
        XCTAssertEqual(OwnWorkoutWindows(defaults).entries.map(\.start), [at(0), at(1805 + 900)])
        XCTAssertGreaterThanOrEqual(OwnWorkoutWindows(defaults).entries.first?.end ?? .distantPast, at(1800))
        second.cancel()
    }
}
