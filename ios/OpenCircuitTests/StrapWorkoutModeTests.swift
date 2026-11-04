import CoreLocation
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The strap's own workout mode in the app (#359, decision 89): the recorder against a fake mode
// source (active seconds, extras, the note, Health energy unchanged), then the recorder and
// `HelioSession` against the simulated strap (`FakeZeppDevice`): the bytes on 0x0019 in order, every
// 89c fallback, 89f's reconnect reconciliation, and the Heart Rate Broadcast switch (89g). Every key,
// time and reading is synthetic and rounded.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
/// `t0` as the strap sees it, little-endian: 0x6b49d200.
private let startLE: [UInt8] = [0x00, 0xd2, 0x49, 0x6b]
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
private func control(_ op: UInt8, _ active: UInt32) -> [UInt8] { [0x03, op, 0x04, 0x00, 0x00, 0x00] + le32(active) }
private let startedMessage: [UInt8] = [0x03, 0x01, 0x06, 0x00, 0x00, 0x00] + startLE + [0x00, 0x00, 0x00, 0x00]
private let keyHex = "00112233445566778899aabbccddeeff"

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strap-workout-mode-\(UUID().uuidString)")! }

// MARK: - Fakes

/// A strap connection with the workout mode, recording every call.
@MainActor
private final class FakeModeSource: StrapWorkoutHeartRateSource, StrapWorkoutModeSource {
    let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-M")
    var isLinkConnected = true
    var ready = true
    var syncing = false
    var canStreamHeartRate = true
    var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    var rrIntervalsReceived = 0
    var workoutModeObserver: (@MainActor (ZeppWorkoutModeMachine.Event) -> Void)?
    var acceptsStart = true
    private(set) var starts: [(code: UInt8, start: UInt32)] = []
    private(set) var pauses: [UInt32] = []
    private(set) var resumes: [UInt32] = []
    private(set) var ends: [UInt32] = []

    func startWorkoutHeartRate() {}
    func stopWorkoutHeartRate() {}
    func sendOwedOrphanStop() {}
    func syncHistory(manual: Bool) {}
    func startWorkoutMode(_ sport: ZeppWorkoutSport, startTime: UInt32) -> Bool {
        guard acceptsStart else { return false }
        starts.append((sport.code, startTime))
        return true
    }
    func pauseWorkoutMode(activeSeconds: UInt32) { pauses.append(activeSeconds) }
    func resumeWorkoutMode(activeSeconds: UInt32) { resumes.append(activeSeconds) }
    func endWorkoutMode(activeSeconds: UInt32) { ends.append(activeSeconds) }

    func send(_ bpm: Int, at date: Date) { heartRateObserver?(bpm, date) }
    func emit(_ event: ZeppWorkoutModeMachine.Event) { workoutModeObserver?(event) }
    func frame(kcal: UInt32, swings: UInt16?) {
        emit(.frame(ZeppWorkoutLiveFrame(fields: swings == nil ? 0x06 : 0x0e, activeSeconds: 1, heartRate: 120,
                                         kilocalories: kcal, averageHeartRate: 120, maximumHeartRate: 130, swings: swings)))
    }
}

@MainActor
private final class Writes: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    func save(_ write: StrapWorkoutWrite) async -> Bool { writes.append(write); return true }
}

@MainActor
private final class Journal: StrapWorkoutJournalStoring {
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
private final class Location: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    func start(route: Bool) {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
}

@MainActor
private final class HRStore: StrapWorkoutHRStore {
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {}
}

// MARK: - The recorder against a fake mode source

@MainActor
final class StrapWorkoutModeRecorderTests: XCTestCase {
    private var now = t0
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)   // Zone 1 from 90 bpm
    private var marker = StrapWorkoutModeMarkerStore(freshDefaults())

    private func makeRecorder(_ source: FakeModeSource, journal: Journal? = nil) -> (StrapWorkoutRecorder, Writes) {
        let journal = journal ?? Journal()
        let writes = Writes()
        let profile = self.profile
        let defaults = freshDefaults()
        let recorder = StrapWorkoutRecorder(
            source: { source }, health: writes, journal: journal, hrStore: { HRStore() }, location: Location(),
            liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(defaults), tombstones: WorkoutTombstones(defaults),
            stepStreamFlag: StrapStepStreamFlag(defaults), workoutModeMarker: marker,
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        return (recorder, writes)
    }

    private func stream(_ recorder: StrapWorkoutRecorder, _ source: FakeModeSource, from: TimeInterval, to: TimeInterval,
                        bpm: Int) async {
        var s = from + 1
        while s <= to {
            now = at(s)
            source.send(bpm, at: now)
            await recorder.tick(now: now)
            s += 1
        }
    }

    func testStartSendsTheSportsCodeWithOpenCircuitsOwnStartTime() {
        let source = FakeModeSource()
        let (recorder, _) = makeRecorder(source)
        recorder.selectedSport = .pickleball
        recorder.start()
        XCTAssertEqual(source.starts.map(\.code), [0xe3])
        XCTAssertEqual(source.starts.map(\.start), [1_800_000_000], "the start OpenCircuit records (89a)")
        XCTAssertEqual(recorder.workoutModeStatus, .starting)
        XCTAssertEqual(StrapWorkoutRecorder.workoutModeOwner,
                       ZeppWorkoutModeMachine.Owner(startTime: 1_800_000_000, activeSeconds: 0, paused: false))
        recorder.cancel()
        XCTAssertNil(StrapWorkoutRecorder.workoutModeOwner, "a discarded workout no longer owns the strap's")
    }

    func testPauseResumeAndEndCarryOpenCircuitsActiveSeconds() async {
        let source = FakeModeSource()
        let (recorder, _) = makeRecorder(source)
        recorder.selectedSport = .strengthTraining
        recorder.start()
        source.emit(.running)
        await stream(recorder, source, from: 0, to: 300, bpm: 140)
        recorder.pause()
        await stream(recorder, source, from: 300, to: 420, bpm: 100)
        recorder.resume()
        await stream(recorder, source, from: 420, to: 600, bpm: 140)
        await recorder.end()
        XCTAssertEqual(source.pauses, [300])
        XCTAssertEqual(source.resumes, [300], "paused time doesn't count")
        XCTAssertEqual(source.ends, [480], "the final active seconds")
        XCTAssertNil(StrapWorkoutRecorder.workoutModeOwner)
    }

    func testEndWhilePausedEndsWithTheActiveSecondsAtThePause() async {
        let source = FakeModeSource()
        let (recorder, _) = makeRecorder(source)
        recorder.selectedSport = .tennis
        recorder.start()
        await stream(recorder, source, from: 0, to: 300, bpm: 140)
        recorder.pause()
        await stream(recorder, source, from: 300, to: 400, bpm: 100)
        XCTAssertEqual(StrapWorkoutRecorder.workoutModeOwner?.paused, true)
        await recorder.end()
        XCTAssertEqual(source.pauses, [300])
        XCTAssertEqual(source.ends, [300], "the session sends pause then end (89a); the seconds are the pause's")
    }

    func testANoCodeSportSendsNothingAndStaysPhoneSide() async throws {
        for sport in [WorkoutSportType.runningOutdoor, .walkingOutdoor, .cyclingOutdoor, .hiking] {
            let source = FakeModeSource()
            let (recorder, writes) = makeRecorder(source)
            recorder.selectedSport = sport
            recorder.start()
            XCTAssertNil(StrapWorkoutRecorder.workoutModeOwner, "\(sport): no strap workout to own")
            await stream(recorder, source, from: 0, to: 60, bpm: 120)
            recorder.pause()
            recorder.resume()
            await recorder.end()
            XCTAssertTrue(source.starts.isEmpty && source.pauses.isEmpty && source.resumes.isEmpty && source.ends.isEmpty,
                          "\(sport): nothing for 0x0019")
            XCTAssertEqual(recorder.workoutModeStatus, .none, "\(sport): no fallback line either: exactly as before")
            XCTAssertEqual(try XCTUnwrap(writes.writes.first).workoutMode, StrapWorkoutModeExtras())
        }
    }

    func testAConnectionWithoutTheModeShowsTheQuietLine() {
        let source = FakeModeSource()
        source.acceptsStart = false
        let (recorder, _) = makeRecorder(source)
        recorder.selectedSport = .tennis
        recorder.start()
        XCTAssertEqual(recorder.workoutModeStatus, .unavailable)
        XCTAssertEqual(StrapWorkoutCopy.workoutModeUnavailable,
                       "Strap workout mode unavailable for this sport; recording continues.", "89c, verbatim")
        recorder.cancel()
        XCTAssertTrue(source.ends.isEmpty, "nothing was started, so nothing is ended")
    }

    func testAFallbackShowsTheQuietLineAndKeepsRecording() async throws {
        let source = FakeModeSource()
        let (recorder, writes) = makeRecorder(source)
        recorder.selectedSport = .tennis
        recorder.start()
        source.emit(.unavailable(.noFrames))
        XCTAssertEqual(recorder.workoutModeStatus, .unavailable)
        await stream(recorder, source, from: 0, to: 60, bpm: 120)
        await recorder.end()
        XCTAssertEqual(try XCTUnwrap(writes.writes.first).samples.count, 60, "recording continues from 0x2A37")
        XCTAssertFalse(try XCTUnwrap(writes.writes.first).workoutMode.ranWithWorkoutMode)
    }

    func testARacketSportStoresItsSwingsAndTheStrapsKcal() async throws {
        let source = FakeModeSource()
        let (recorder, writes) = makeRecorder(source)
        recorder.selectedSport = .tennis
        recorder.start()
        source.emit(.running)
        source.frame(kcal: 10, swings: 12)
        XCTAssertEqual(recorder.strapSwings, 12, "live")
        XCTAssertEqual(recorder.strapKilocalories, 10)
        await stream(recorder, source, from: 0, to: 120, bpm: 140)
        source.frame(kcal: 30, swings: 42)
        await recorder.end()
        let write = try XCTUnwrap(writes.writes.first)
        XCTAssertEqual(write.workoutMode, StrapWorkoutModeExtras(ranWithWorkoutMode: true, swings: 42, strapKilocalories: 30))
        XCTAssertEqual(StrapWorkoutMetadata.metadata(write.workoutMode),
                       ["OCStrapWorkoutMode": 1, "OCStrapSwingCount": 42, "OCStrapActiveEnergyKcal": 30])
        XCTAssertEqual(recorder.strapSwings, 42, "on the summary")
        source.frame(kcal: 99, swings: 99)
        XCTAssertEqual(recorder.strapSwings, 42, "frames after End change nothing")
        recorder.reset()
        XCTAssertNil(recorder.strapSwings)
        XCTAssertNil(recorder.strapKilocalories)
    }

    func testANonRacketSportStoresNoSwings() async throws {
        let source = FakeModeSource()
        let (recorder, writes) = makeRecorder(source)
        recorder.selectedSport = .strengthTraining
        recorder.start()
        source.emit(.running)
        source.frame(kcal: 25, swings: nil)
        await stream(recorder, source, from: 0, to: 60, bpm: 140)
        await recorder.end()
        let metadata = StrapWorkoutMetadata.metadata(try XCTUnwrap(writes.writes.first).workoutMode)
        XCTAssertNil(metadata[StrapWorkoutMetadata.swingCountKey])
        XCTAssertEqual(metadata[StrapWorkoutMetadata.activeEnergyKey], 25)
    }

    func testTheEnergyWrittenToHealthIsTheSameWithAndWithoutFrames() async throws {
        func run(frames: Bool) async throws -> StrapWorkoutWrite {
            now = t0
            let source = FakeModeSource()
            let (recorder, writes) = makeRecorder(source)
            recorder.selectedSport = .other
            recorder.start()
            if frames {
                source.emit(.running)
                source.frame(kcal: 900, swings: nil)
            }
            await stream(recorder, source, from: 0, to: 900, bpm: 150)
            if frames { source.frame(kcal: 999, swings: nil) }
            await recorder.end()
            return try XCTUnwrap(writes.writes.first)
        }
        let without = try await run(frames: false)
        let with = try await run(frames: true)
        XCTAssertEqual(with.summary, without.summary, "89d: energy, heart rate and zones are OpenCircuit's own")
        XCTAssertEqual(with.samples, without.samples)
        XCTAssertNotNil(with.summary.summary.estimatedActiveKcal)
        XCTAssertNotEqual(with.summary.summary.estimatedActiveKcal.map { Int($0.rounded()) }, 999)
    }

    func testTheLowHeartRateNoteIsOnlyForAWorkoutWithoutTheMode() async {
        func endsWithNote(_ event: ZeppWorkoutModeMachine.Event?) async -> Bool {
            now = t0
            let source = FakeModeSource()
            let (recorder, _) = makeRecorder(source)
            recorder.selectedSport = .tennis
            recorder.start()
            if let event { source.emit(event) }
            await stream(recorder, source, from: 0, to: 1200, bpm: 80)
            await recorder.end()
            return recorder.showsLowHeartRateNote
        }
        let withMode = await endsWithNote(.running)
        let fellBack = await endsWithNote(.unavailable(.noReply(.start)))
        XCTAssertFalse(withMode, "89h: the mode ran")
        XCTAssertTrue(fellBack, "89h: a fallback is phone-side")
    }

    func testTheMarkerRecordsTheAppsActiveSecondsAndItsEnd() async {
        let source = FakeModeSource()
        let (recorder, _) = makeRecorder(source)
        recorder.selectedSport = .tennis
        recorder.start()
        // The session sets the marker before `02`; the recorder keeps its active seconds.
        marker.set(ZeppWorkoutModeMarker(startTime: 1_800_000_000, sportCode: 0x11))
        source.emit(.running)
        await stream(recorder, source, from: 0, to: 30, bpm: 140)
        XCTAssertEqual(marker.marker?.activeSeconds, 30, "the heartbeat's copy")
        XCTAssertEqual(marker.marker?.appEnded, false)
        await recorder.end()
        XCTAssertEqual(marker.marker?.activeSeconds, 30)
        XCTAssertEqual(marker.marker?.appEnded, true, "a later connection ends it on the strap if this one can't (89f)")
    }

    func testAKilledWorkoutKeepsWhatTheModeAdded() async throws {
        let source = FakeModeSource()
        let journal = Journal()
        let (recorder, _) = makeRecorder(source, journal: journal)
        recorder.selectedSport = .pickleball
        recorder.start()
        source.emit(.running)
        source.frame(kcal: 40, swings: 80)
        await stream(recorder, source, from: 0, to: 600, bpm: 140)
        XCTAssertEqual(journal.journal?.workoutMode, StrapWorkoutModeExtras(ranWithWorkoutMode: true, swings: 80, strapKilocalories: 40))
        // A new process finds the journal and saves the workout.
        let (next, writes) = makeRecorder(FakeModeSource(), journal: journal)
        next.resolveOrphan(now: at(700))
        let saved = await next.saveRecovered()
        XCTAssertTrue(saved)
        XCTAssertEqual(try XCTUnwrap(writes.writes.first).workoutMode.swings, 80)
        recorder.cancel()
    }
}

// MARK: - Against the simulated strap

@MainActor
private final class ModeTransport: HelioTransport {
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
private final class ModeKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
final class StrapWorkoutModeSessionTests: XCTestCase {
    private var now = t0
    private var marker = StrapWorkoutModeMarkerStore(freshDefaults())
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)
    private var current: HelioSession?

    private func makeStrap(workoutEndpoint: Bool = true) -> FakeZeppDevice {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x0082, 0)]
            + (workoutEndpoint ? [(0x0019, 1)] : [])
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        return device
    }

    private func connect(_ device: FakeZeppDevice) -> (HelioSession, ModeTransport) {
        let transport = ModeTransport(device: device)
        let keys = ModeKeys()
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

    private func makeRecorder() -> (StrapWorkoutRecorder, Writes) {
        let writes = Writes()
        let defaults = freshDefaults()
        let profile = self.profile
        let recorder = StrapWorkoutRecorder(
            source: { [unowned self] in self.current }, health: writes, journal: Journal(), hrStore: { HRStore() },
            location: Location(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(defaults), tombstones: WorkoutTombstones(defaults),
            stepStreamFlag: StrapStepStreamFlag(defaults), workoutModeMarker: marker,
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        return (recorder, writes)
    }

    /// A strap and a recorder whose workout of `sport` has just started, drained.
    private func started(_ sport: WorkoutSportType = .tennis, device: FakeZeppDevice? = nil)
        -> (StrapWorkoutRecorder, Writes, HelioSession, ModeTransport, FakeZeppDevice) {
        let device = device ?? makeStrap()
        let (session, transport) = connect(device)
        XCTAssertTrue(session.ready)
        let (recorder, writes) = makeRecorder()
        recorder.selectedSport = sport
        recorder.start()
        XCTAssertTrue(recorder.isRecording)
        transport.drain()
        return (recorder, writes, session, transport, device)
    }

    private func frame(_ transport: ModeTransport, _ device: FakeZeppDevice, kcal: UInt32 = 5, swings: UInt16? = 3) {
        transport.push(device.workoutFrame(active: 1, heartRate: 120, kcal: kcal, average: 120, maximum: 120, swings: swings))
        transport.drain()
    }

    private func tick(_ recorder: StrapWorkoutRecorder, _ session: HelioSession, to seconds: TimeInterval) async {
        now = at(seconds)
        session.tick(now: now)
        await recorder.tick(now: now)
    }

    // MARK: Happy path

    func testTheSequenceGoesOutInOrderAndTheMarkerLivesUntilTheEndsSecondAck() async throws {
        let (recorder, writes, session, transport, device) = started()
        XCTAssertEqual(device.workoutCommands, [[0x01], [0x06, 0x00], [0x02, 0x11, 0x00, 0x00, 0x01], startedMessage])
        XCTAssertEqual(marker.marker, ZeppWorkoutModeMarker(startTime: 1_800_000_000, sportCode: 0x11))
        XCTAssertEqual(recorder.workoutModeStatus, .starting)
        frame(transport, device, kcal: 8, swings: 20)
        XCTAssertEqual(recorder.workoutModeStatus, .running)
        XCTAssertEqual(recorder.strapSwings, 20)
        await tick(recorder, session, to: 5)
        XCTAssertEqual(device.workoutCommands.last, [0x05], "keep-alive every 5 s")
        await tick(recorder, session, to: 300)
        recorder.pause()
        transport.drain()
        XCTAssertEqual(device.workoutCommands.last, control(0x02, 300))
        await tick(recorder, session, to: 360)
        recorder.resume()
        transport.drain()
        XCTAssertEqual(device.workoutCommands.last, control(0x03, 300))
        await tick(recorder, session, to: 600)
        await recorder.end()
        XCTAssertEqual(Array(device.workoutCommands.suffix(2)), [control(0x02, 540), control(0x04, 540)],
                       "pause then end, with the final active seconds (89a, 89j)")
        XCTAssertNotNil(marker.marker, "until the strap confirms")
        transport.drain()
        XCTAssertNil(marker.marker, "cleared after the end's second 10 03 01")
        XCTAssertNil(device.workoutRunning)
        XCTAssertFalse(device.workoutCommands.contains { $0.starts(with: [0x03, 0x05]) }, "89j: never 03 05")
        XCTAssertEqual(try XCTUnwrap(writes.writes.first).workoutMode.ranWithWorkoutMode, true)
        XCTAssertFalse(device.failures.contains { $0.contains("workout") })
    }

    func testEndWhilePausedStillSendsPauseThenEnd() async {
        let (recorder, _, session, transport, device) = started(.strengthTraining)
        frame(transport, device, swings: nil)
        await tick(recorder, session, to: 120)
        recorder.pause()
        transport.drain()
        await tick(recorder, session, to: 200)
        await recorder.end()
        transport.drain()
        let commands = device.workoutCommands.filter { $0 != [0x05] }   // keep-alives go on while paused
        XCTAssertEqual(Array(commands.suffix(3)), [control(0x02, 120), control(0x02, 120), control(0x04, 120)],
                       "the pause, then End's own pause and end")
        XCTAssertNil(marker.marker)
    }

    // MARK: 89c fallbacks

    func testNoStartReplyFallsBackAfterEightSeconds() async {
        let device = makeStrap()
        device.workoutStartStatus = nil
        let (recorder, _, session, _, _) = started(device: device)
        XCTAssertEqual(device.workoutCommands, [[0x01], [0x06, 0x00], [0x02, 0x11, 0x00, 0x00, 0x01]])
        await tick(recorder, session, to: 7)
        XCTAssertEqual(recorder.workoutModeStatus, .starting)
        await tick(recorder, session, to: 9)
        XCTAssertEqual(recorder.workoutModeStatus, .unavailable)
        XCTAssertNotNil(marker.marker, "whether the strap started is unknown: the next connection settles it")
    }

    func testARefusedStartFallsBack() {
        let device = makeStrap()
        device.workoutStartStatus = 0x05
        let (recorder, _, _, _, _) = started(device: device)
        XCTAssertEqual(recorder.workoutModeStatus, .unavailable)
        XCTAssertNil(marker.marker)
        XCTAssertEqual(device.workoutCommands.count, 3, "nothing after the refusal")
    }

    func testAStrapThatIsNotIdleIsNeverStartedOrTouched() async {
        let device = makeStrap()
        device.workoutRunning = (1_799_990_000, 0x11)   // Zepp's workout
        let (recorder, _, session, transport, _) = started(device: device)
        XCTAssertEqual(device.workoutCommands, [[0x01], [0x06, 0x00]], "no 02 on top of someone else's workout")
        XCTAssertEqual(recorder.workoutModeStatus, .unavailable)
        XCTAssertNil(marker.marker)
        await tick(recorder, session, to: 300)
        await recorder.end()
        transport.drain()
        XCTAssertEqual(device.workoutCommands, [[0x01], [0x06, 0x00]], "and its end is never ours to send")
        XCTAssertNotNil(device.workoutRunning)
    }

    func testNoFramesInFifteenSecondsEndsTheStrapsWorkoutWithPauseThenEnd() async throws {
        let (recorder, writes, session, transport, device) = started(.other)
        await tick(recorder, session, to: 10)
        await tick(recorder, session, to: 15.5)
        transport.drain()
        XCTAssertEqual(recorder.workoutModeStatus, .unavailable)
        XCTAssertEqual(Array(device.workoutCommands.suffix(2)), [control(0x02, 15), control(0x04, 15)],
                       "89j: 03 02 + 03 04 at about 15 s, never 03 05")
        XCTAssertNil(marker.marker)
        await tick(recorder, session, to: 60)
        let before = device.workoutCommands.count
        await recorder.end()
        transport.drain()
        XCTAssertEqual(device.workoutCommands.count, before, "nothing more at the app's own End")
        XCTAssertFalse(try XCTUnwrap(writes.writes.first).workoutMode.ranWithWorkoutMode)
    }

    func testAStrapWithoutTheWorkoutEndpointGetsNothing() {
        let (recorder, _, _, _, device) = started(device: makeStrap(workoutEndpoint: false))
        XCTAssertEqual(device.workoutCommands, [])
        XCTAssertEqual(recorder.workoutModeStatus, .unavailable)
        recorder.cancel()
    }

    func testANoCodeSportSendsNothingOnTheWorkoutEndpoint() async {
        let (recorder, _, session, transport, device) = started(.runningOutdoor)
        await tick(recorder, session, to: 60)
        recorder.pause()
        recorder.resume()
        await recorder.end()
        transport.drain()
        XCTAssertEqual(device.workoutCommands, [])
        XCTAssertNil(marker.marker)
    }

    // MARK: 89f reconnect reconciliation

    func testAReconnectWhileTheWorkoutRunsInTheAppCarriesOn() async {
        let (recorder, _, session, transport, device) = started()
        frame(transport, device)
        await tick(recorder, session, to: 100)
        session.linkLost()
        await tick(recorder, session, to: 101)
        XCTAssertTrue(recorder.linkDown)
        let sent = device.workoutCommands.count
        now = at(130)
        let (next, nextTransport) = connect(device)
        XCTAssertEqual(Array(device.workoutCommands.dropFirst(sent)), [[0x06, 0x00]], "checked, then carried on")
        XCTAssertNotNil(marker.marker)
        await recorder.tick(now: now)
        XCTAssertFalse(recorder.linkDown, "adopted")
        frame(nextTransport, device, kcal: 50, swings: 70)
        XCTAssertEqual(recorder.strapSwings, 70, "the new connection's frames reach the workout")
        await tick(recorder, next, to: 200)
        await recorder.end()
        nextTransport.drain()
        XCTAssertEqual(Array(device.workoutCommands.suffix(2)), [control(0x02, 200), control(0x04, 200)],
                       "a link gap is running time, as OpenCircuit counts it")
        XCTAssertNil(marker.marker)
    }

    func testAReconnectAfterTheAppEndedTheWorkoutEndsItOnTheStrap() async {
        let (recorder, _, session, transport, device) = started()
        frame(transport, device)
        await tick(recorder, session, to: 100)
        session.linkLost()
        await tick(recorder, session, to: 101)
        await recorder.end()   // with the link down: the marker carries it
        XCTAssertEqual(marker.marker?.appEnded, true)
        XCTAssertEqual(marker.marker?.activeSeconds, 101)
        let sent = device.workoutCommands.count
        now = at(400)
        _ = connect(device)
        XCTAssertEqual(Array(device.workoutCommands.dropFirst(sent)), [[0x06, 0x00], control(0x02, 101), control(0x04, 101)])
        XCTAssertNil(marker.marker)
        XCTAssertNil(device.workoutRunning)
    }

    func testAReconnectInANewProcessEndsTheWorkoutTheKilledProcessStarted() {
        marker.set(ZeppWorkoutModeMarker(startTime: 1_800_000_000, sportCode: 0x11, activeSeconds: 900))
        let device = makeStrap()
        device.workoutRunning = (1_800_000_000, 0x11)
        _ = connect(device)
        XCTAssertEqual(device.workoutCommands, [[0x06, 0x00], control(0x02, 900), control(0x04, 900)],
                       "no OpenCircuit workout runs in this process: ended with the seconds it recorded")
        XCTAssertNil(marker.marker)
    }

    func testAReconnectToAForeignWorkoutNeverTouchesIt() {
        marker.set(ZeppWorkoutModeMarker(startTime: 1_800_000_000, sportCode: 0x11, activeSeconds: 900, appEnded: true))
        let device = makeStrap()
        device.workoutRunning = (1_800_000_060, 0x11)   // started by Zepp
        _ = connect(device)
        XCTAssertEqual(device.workoutCommands, [[0x06, 0x00]])
        XCTAssertNil(marker.marker)
        XCTAssertNotNil(device.workoutRunning)
    }

    func testAReconnectToAnIdleStrapClearsTheMarker() {
        marker.set(ZeppWorkoutModeMarker(startTime: 1_800_000_000, sportCode: 0x11, activeSeconds: 900))
        let device = makeStrap()
        _ = connect(device)
        XCTAssertEqual(device.workoutCommands, [[0x06, 0x00]])
        XCTAssertNil(marker.marker)
    }

    func testAMarkerForAStrapWithoutTheEndpointIsClearedWithNothingSent() {
        marker.set(ZeppWorkoutModeMarker(startTime: 1_800_000_000, sportCode: 0x11))
        let device = makeStrap(workoutEndpoint: false)
        _ = connect(device)
        XCTAssertEqual(device.workoutCommands, [])
        XCTAssertNil(marker.marker)
    }

    func testBreadcrumbsCarryControlBytesAndOutcomesOnly() {
        let lines = [ZeppWorkoutModeMachine.Event.running, .unavailable(.noFrames), .unavailable(.noReply(.start)),
                     .unavailable(.refused(.start, status: 5)), .unavailable(.notIdle), .ended, .endUnconfirmed,
                     .reconciled(.carriedOn), .reconciled(.endedForApp), .reconciled(.idle), .reconciled(.foreign)]
            .compactMap(HelioSession.workoutModeBreadcrumb)
        XCTAssertEqual(lines.count, 11)
        XCTAssertNil(HelioSession.workoutModeBreadcrumb(.frame(ZeppWorkoutLiveFrame(
            fields: 0x0e, activeSeconds: 60, heartRate: 140, kilocalories: 45, averageHeartRate: 130,
            maximumHeartRate: 150, swings: 42))), "never a value")
        XCTAssertFalse(lines.joined().contains("03 05"))
    }
}

// MARK: - Ring untouched, history, copy

@MainActor
final class StrapWorkoutModeAppTests: XCTestCase {

    func testTheRingsSportsAndTheirMappingsAreUnchanged() {
        XCTAssertEqual(WorkoutSportType.ringSports.map(\.rawValue),
                       ["walkingOutdoor", "walkingIndoor", "runningOutdoor", "runningIndoor", "cyclingOutdoor",
                        "cyclingIndoor", "rowing", "hiking", "strengthTraining", "yoga", "other"])
        XCTAssertEqual(WorkoutSportType.ringSports.map(WorkoutSessionManager.hkActivityType(for:)),
                       [.walking, .walking, .running, .running, .cycling, .cycling, .rowing, .hiking,
                        .traditionalStrengthTraining, .yoga, .other])
        XCTAssertEqual(WorkoutSportType.ringSports.map(\.firmwareByte), [0x02, 0x02, 0x01, 0x03, 0x04, 0x05, 0x06, 0x02, 0x07, 0x07, 0x07])
        XCTAssertEqual(WorkoutSessionManager.hkActivityType(for: .tennis), .tennis)
        XCTAssertEqual(WorkoutSessionManager.hkActivityType(for: .pickleball), .pickleball)
        XCTAssertEqual(WorkoutActivityDisplay.name(.pickleball), "Pickleball")
    }

    private func item(_ extras: StrapWorkoutModeExtras) -> WorkoutHistoryReader.Item {
        WorkoutHistoryReader.Item(id: UUID(), activityType: .tennis, start: t0, end: at(1800), activeKcal: 200,
                                  distanceMeters: nil, avgHR: 80, deviceName: "Helio Strap", deviceManufacturer: "Amazfit",
                                  strapExtras: extras)
    }

    func testTheHistoryDetailReadsTheFlagAndAMissingFlagIsPhoneSide() {
        let low = stride(from: 1.0, through: 1800, by: 1).map { HRSample(bpm: 80, start: at($0 - 1), end: at($0)) }
        let zones = HeartRateZones(percentOfMax: 180)
        XCTAssertTrue(WorkoutDetailContent.showsLowHeartRateNote(item(StrapWorkoutModeExtras()), hr: low, zones: zones,
                                                                 isStrapWorkout: true), "missing = phone-side")
        XCTAssertFalse(WorkoutDetailContent.showsLowHeartRateNote(item(StrapWorkoutModeExtras(ranWithWorkoutMode: true)),
                                                                  hr: low, zones: zones, isStrapWorkout: true))
    }

    func testTheHistoryDetailShowsSwingsAndTheStrapsEstimate() {
        let rows = WorkoutDetailContent.rows(item(StrapWorkoutModeExtras(ranWithWorkoutMode: true, swings: 420, strapKilocalories: 310)),
                                             hr: [], zones: HeartRateZones(percentOfMax: 180), unit: .metric,
                                             recordedWith: "Helio Strap")
        XCTAssertEqual(rows.first { $0.title == "Swings" }?.value, "420")
        XCTAssertEqual(rows.first { $0.title == "Strap estimate" }?.value, "310 kcal")
        XCTAssertEqual(rows.first { $0.title == "Active energy" }?.value, "200 kcal", "OpenCircuit's, unchanged")
        let plain = WorkoutDetailContent.rows(item(StrapWorkoutModeExtras()), hr: [], zones: HeartRateZones(percentOfMax: 180),
                                              unit: .metric, recordedWith: "Helio Strap")
        XCTAssertFalse(plain.contains { $0.title == "Swings" || $0.title == "Strap estimate" })
    }

    func testTheSummaryCopy() {
        XCTAssertEqual(StrapWorkoutCopy.strapEstimate(310), "Strap estimate · 310 kcal")
        XCTAssertTrue(StrapWorkoutCopy.totalsNote(hasRoute: false, workoutMode: .none).hasSuffix("The strap made no record of this workout."))
        XCTAssertFalse(StrapWorkoutCopy.totalsNote(hasRoute: false, workoutMode: .running).contains("no record"))
        XCTAssertFalse(StrapWorkoutCopy.totalsNote(hasRoute: false, workoutMode: .unavailable).contains("record"),
                       "after a fallback, whether the strap kept anything is not claimed")
        XCTAssertTrue(StrapWorkoutCopy.idleInfo(.runningOutdoor).contains("keeps no workout record"))
        XCTAssertTrue(StrapWorkoutCopy.idleInfo(.tennis).contains("workout mode"))
        XCTAssertEqual(StrapWorkoutLowHeartRateNote.text,
                       "Heart rate stayed below Zone 1 for most of this workout. If you worked harder than that, the strap may not have held a good reading: fast, repeated arm movement (racket sports, boxing) can make its live heart rate read low. This workout ran without the strap's workout mode, which reads better during hard effort. A snug fit helps.")
    }

    func testNothingNamesHealth05HeartRatePush() {
        let detail = HelioStatus.from(connection: .connected, phase: .keyless, hasKey: false, keyRejected: false,
                                      hasSavedStrap: true, endedBusy: false).detail ?? ""
        XCTAssertFalse(detail.contains("Heart Rate Push"))
        XCTAssertTrue(detail.contains("Heart Rate Broadcast"))
    }
}

// MARK: - Heart Rate Broadcast (89g)

@MainActor
final class HeartRateBroadcastAppTests: XCTestCase {
    private var now = t0
    private var broadcast: Bool? = false

    private func connect(ackStatus: UInt8 = 0x01) -> (HelioSession, ModeTransport, FakeZeppDevice) {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x0082, 0)]
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        device.configCapabilitiesReply = [0x02, 0x03, 0x05, 0x00, 0x0b, 0x08, 0x09, 0x0a]
        device.configWriteAckStatus = ackStatus
        device.configReadHandler = { [unowned self] request in
            guard request.count >= 4, request[0] == 0x03, request[1] == 0x01, request[2] == 0x08 else { return nil }
            var entries: [UInt8] = []
            var count: UInt8 = 0
            for arg in request.dropFirst(4) {
                if arg == 0x13 { entries += [0x13, 0x0b, 0x01]; count += 1 }
                if arg == 0x83, let on = self.broadcast { entries += [0x83, 0x0b, on ? 0x01 : 0x00]; count += 1 }
            }
            return [0x04, 0x01, 0x08, 0x03, 0x01, count] + entries
        }
        device.onConfigWrite = { [unowned self] write in
            if ackStatus == 0x01, write == [0x05, 0x08, 0x03, 0x00, 0x01, 0x83, 0x0b, 0x01] { self.broadcast = true }
            if ackStatus == 0x01, write == [0x05, 0x08, 0x03, 0x00, 0x01, 0x83, 0x0b, 0x00] { self.broadcast = false }
        }
        let transport = ModeTransport(device: device)
        let keys = ModeKeys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000C4",
                                   key: keys.load(), keyStore: keys, sink: nil, findState: HelioFindState(),
                                   clock: { [unowned self] in self.now }, autoTick: false, autoSyncOnConnect: false)
        session.workoutModeMarker = StrapWorkoutModeMarkerStore(freshDefaults())
        transport.session = session
        session.start()
        transport.drain()
        session.readStrapSettings(groups: [0x08])
        transport.drain()
        return (session, transport, device)
    }

    func testReadShowsTheSwitchAndTurningItOnWritesTheSpecBytesThenReReads() {
        let (session, transport, device) = connect()
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.heartRateBroadcast), .bool(false))
        XCTAssertNil(session.changeStrapSetting(.heartRateBroadcast, from: .bool(false), to: .bool(true)))
        transport.drain()
        XCTAssertEqual(device.configWrites, [[0x05, 0x08, 0x03, 0x00, 0x01, 0x83, 0x0b, 0x01]])
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.heartRateBroadcast), .bool(true), "the re-read value")
        XCTAssertEqual(session.settingsNotice?.text, "Saved on the strap.")
        XCTAssertNil(session.changeStrapSetting(.heartRateBroadcast, from: .bool(true), to: .bool(false)))
        transport.drain()
        XCTAssertEqual(device.configWrites.last, [0x05, 0x08, 0x03, 0x00, 0x01, 0x83, 0x0b, 0x00])
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.heartRateBroadcast), .bool(false))
    }

    func testANonOkAckRevertsTheSwitchWithTheSettingsErrorNotice() {
        let (session, transport, device) = connect(ackStatus: 0x02)
        XCTAssertNil(session.changeStrapSetting(.heartRateBroadcast, from: .bool(false), to: .bool(true)))
        transport.drain()
        XCTAssertEqual(device.configWrites.count, 1, "never retried")
        XCTAssertEqual(session.settingsEditor?.snapshot.value(.heartRateBroadcast), .bool(false), "back to the strap's value")
        XCTAssertEqual(session.settingsNotice?.text,
                       "The strap didn't take the change. Its current value is shown. Nothing was retried.")
    }

    func testHiddenWhenTheStrapDoesNotReportIt() {
        broadcast = nil
        let (session, _, device) = connect()
        XCTAssertEqual(session.settingsEditor?.snapshot.availability(.heartRateBroadcast), .notReported)
        XCTAssertNil(session.settingsEditor?.snapshot.value(.heartRateBroadcast), "the section filters on a reported value")
        XCTAssertNotNil(session.changeStrapSetting(.heartRateBroadcast, from: .bool(false), to: .bool(true)))
        XCTAssertEqual(device.configWrites, [])
    }

    func testTheSwitchsCopy() {
        XCTAssertEqual(HelioSettingsCopy.label(.heartRateBroadcast), "Heart Rate Broadcast")
        XCTAssertEqual(HelioSettingsCopy.broadcastFooter,
                       "Lets gym equipment, other apps and devices read your heart rate from the strap. Turning it on can use a little more battery.")
        XCTAssertEqual(ZeppSetting.broadcast, [.heartRateBroadcast])
        XCTAssertFalse(ZeppSetting.measurement.contains(.heartRateBroadcast), "its own section, with its own footer")
    }
}
