import CoreLocation
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 90e/90g: the wrist the person chose is never part of who owns a strap workout. Ownership is
// the start time and the sport CODE (89f/89p), so flipping the wrist between a start and a reconnect
// must never make our own workout foreign. Every case runs the real `HelioSession` and the real recorder
// against the simulated strap (`FakeZeppDevice`), the same path as `StrapWorkoutModeSessionTests`. Every
// key, time and reading is synthetic and rounded.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
private func control(_ op: UInt8, _ active: UInt32) -> [UInt8] { [0x03, op, 0x04, 0x00, 0x00, 0x00] + le32(active) }
private let keyHex = "00112233445566778899aabbccddeeff"

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strap-wrist-ownership-\(UUID().uuidString)")! }

// MARK: - Fakes

@MainActor
private final class OwnershipTransport: HelioTransport {
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
    func push(_ notifications: [FakeZeppDevice.Notification]) {
        for n in notifications { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 100_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes { session?.received(characteristic, bytes) }
            else { session?.notificationStateChanged(characteristic, enabled: enabled, failed: false) }
        }
    }
}

@MainActor
private final class OwnershipKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
private final class OwnershipWrites: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    func save(_ write: StrapWorkoutWrite) async -> Bool { writes.append(write); return true }
}

@MainActor
private final class OwnershipJournal: StrapWorkoutJournalStoring {
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
private final class OwnershipLocation: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    func start(route: Bool) {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
}

@MainActor
private final class OwnershipHRStore: StrapWorkoutHRStore {
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {}
}

// MARK: - Tests

@MainActor
final class StrapWorkoutWristOwnershipTests: XCTestCase {
    private var now = t0
    private var marker = StrapWorkoutModeMarkerStore(freshDefaults())
    private let wristDefaults = freshDefaults()
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)
    private var current: HelioSession?

    private func makeStrap() -> FakeZeppDevice {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x0082, 0), (0x0019, 1)]
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        // 89p (d): the strap's own clock runs 2 s ahead of the phone's; an accepted `02` starts there.
        device.strapClock = { [unowned self] in UInt32(self.now.timeIntervalSince1970) + 2 }
        return device
    }

    private func connect(_ device: FakeZeppDevice) -> (HelioSession, OwnershipTransport) {
        let transport = OwnershipTransport(device: device)
        let keys = OwnershipKeys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000C3",
                                   key: keys.load(), keyStore: keys, sink: nil, findState: HelioFindState(),
                                   clock: { [unowned self] in self.now }, autoTick: false, autoSyncOnConnect: false,
                                   workoutHoldsLink: { StrapWorkoutRecorder.holdsStrapLink },
                                   workoutModeOwner: { StrapWorkoutRecorder.workoutModeOwner })
        let defaults = freshDefaults()
        session.workoutModeMarker = marker
        session.orphanStop = StrapWorkoutOrphanStop(defaults)
        session.stepStreamFlag = StrapStepStreamFlag(defaults)
        transport.session = session
        current = session
        session.start()
        transport.drain()
        return (session, transport)
    }

    private func makeRecorder() -> (StrapWorkoutRecorder, OwnershipWrites) {
        let writes = OwnershipWrites()
        let defaults = freshDefaults()
        let profile = self.profile
        let recorder = StrapWorkoutRecorder(
            source: { [unowned self] in self.current }, health: writes, journal: OwnershipJournal(), hrStore: { OwnershipHRStore() },
            location: OwnershipLocation(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(defaults), tombstones: WorkoutTombstones(defaults),
            stepStreamFlag: StrapStepStreamFlag(defaults), workoutModeMarker: marker,
            wristStore: StrapWristStore(wristDefaults),
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        return (recorder, writes)
    }

    /// A strap and a recorder whose workout of `sport` has just started, drained.
    private func started(_ sport: WorkoutSportType)
        -> (StrapWorkoutRecorder, OwnershipWrites, HelioSession, OwnershipTransport, FakeZeppDevice) {
        let device = makeStrap()
        let (session, transport) = connect(device)
        XCTAssertTrue(session.ready)
        let (recorder, writes) = makeRecorder()
        recorder.selectedSport = sport
        recorder.start()
        XCTAssertTrue(recorder.isRecording)
        transport.drain()
        return (recorder, writes, session, transport, device)
    }

    private func frame(_ transport: OwnershipTransport, _ device: FakeZeppDevice, kcal: UInt32 = 5, swings: UInt16? = 3) {
        transport.push(device.workoutFrame(active: 1, heartRate: 120, kcal: kcal, average: 120, maximum: 120, swings: swings))
        transport.drain()
    }

    private func tick(_ recorder: StrapWorkoutRecorder, _ session: HelioSession, to seconds: TimeInterval) async {
        now = at(seconds)
        session.tick(now: now)
        await recorder.tick(now: now)
    }

    /// Start on `from`, lose the link, flip the control to `to`, reconnect: still ours, carried on, ended as ours.
    private func assertAWristChangeBetweenStartAndReconnectStaysOurs(_ sport: WorkoutSportType, code: UInt8,
                                                                      from: StrapWrist, to: StrapWrist) async {
        StrapWristStore(wristDefaults).wrist = from
        let (recorder, _, session, transport, device) = started(sport)
        XCTAssertEqual(device.workoutCommands[2].last, from.rawValue, "\(sport): started with \(from)")
        frame(transport, device)
        await tick(recorder, session, to: 100)
        session.linkLost()
        await tick(recorder, session, to: 101)
        recorder.strapWrist = to   // the person flips the control / persisted wrist before the reconnect
        XCTAssertEqual(StrapWristStore(wristDefaults).wrist, to)
        XCTAssertEqual(device.workoutRunning?.1, code, "the strap reads running \(sport)")
        let sent = device.workoutCommands.count
        now = at(130)
        let (next, nextTransport) = connect(device)
        XCTAssertEqual(Array(device.workoutCommands.dropFirst(sent)), [[0x06, 0x00]], "\(sport): checked, then carried on (ours)")
        XCTAssertNotNil(marker.marker, "still ours")
        await recorder.tick(now: now)
        XCTAssertFalse(recorder.linkDown, "adopted")
        await tick(recorder, next, to: 200)
        await recorder.end()
        nextTransport.drain()
        XCTAssertEqual(Array(device.workoutCommands.filter { $0 != [0x05] }.suffix(2)), [control(0x02, 200), control(0x04, 200)],
                       "\(sport): ended as ours after a wrist change")
        XCTAssertNil(device.workoutRunning, "not left running")
        XCTAssertNil(marker.marker)
    }

    func testATennisWorkoutStartedOnTheLeftWristIsStillOursAfterTheWristIsSwitchedToRightAndTheLinkReconnects() async {
        await assertAWristChangeBetweenStartAndReconnectStaysOurs(.tennis, code: 0x11, from: .left, to: .right)
    }

    func testATennisWorkoutStartedOnTheRightWristIsStillOursAfterTheWristIsSwitchedToLeftAndTheLinkReconnects() async {
        await assertAWristChangeBetweenStartAndReconnectStaysOurs(.tennis, code: 0x11, from: .right, to: .left)
    }

    func testAPickleballWorkoutStartedOnTheLeftWristIsStillOursAfterTheWristIsSwitchedToRightAndTheLinkReconnects() async {
        await assertAWristChangeBetweenStartAndReconnectStaysOurs(.pickleball, code: 0xe3, from: .left, to: .right)
    }

    /// A killed process: the new recorder sees the other wrist; the marker alone decides.
    func testANewProcessWithTheOtherWristPersistedStillEndsTheTennisWorkoutItsMarkerOwns() {
        StrapWristStore(wristDefaults).wrist = .right
        marker.set(ZeppWorkoutModeMarker(startTime: 1_800_000_000, sportCode: 0x11, activeSeconds: 900))
        let device = makeStrap()
        device.workoutRunning = (1_800_000_000, 0x11)
        _ = connect(device)
        XCTAssertEqual(device.workoutCommands, [[0x06, 0x00], control(0x02, 900), control(0x04, 900)])
        XCTAssertNil(device.workoutRunning)
    }

    /// Lost start reply (89p/89q window) with the wrist flipped before the reconnect.
    func testALostStartReplyThenAWristSwitchThenAReconnectStillAdoptsAndEndsTheWorkoutAsOurs() async {
        StrapWristStore(wristDefaults).wrist = .left
        let device = makeStrap()
        device.dropsStartReply = true
        device.strapClock = { 1_800_000_001 }
        let (session, transport) = connect(device)
        let (recorder, _) = makeRecorder()
        recorder.selectedSport = .tennis
        recorder.start()
        transport.drain()
        await tick(recorder, session, to: 3)
        session.linkLost()
        await tick(recorder, session, to: 4)
        recorder.strapWrist = .right
        now = at(30)
        let (next, nextTransport) = connect(device)
        nextTransport.drain()
        await recorder.tick(now: now)
        XCTAssertFalse(recorder.linkDown, "adopted")
        await tick(recorder, next, to: 60)
        await recorder.end()
        nextTransport.drain()
        XCTAssertEqual(Array(device.workoutCommands.filter { $0 != [0x05] }.suffix(2)), [control(0x02, 60), control(0x04, 60)])
        XCTAssertNil(device.workoutRunning)
        XCTAssertNil(marker.marker)
    }
}
