import CoreLocation
import HealthKit
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Heart rate recovery follow-ups (#337, decision 85): the stop owed to a strap while the recovery
// window runs (85a), no negative Cardio Recovery (85b), the detail's peak (85c) and the delete of the
// Cardio Recovery sample (85d). Every reading, time and key is synthetic and rounded.

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let keyHex = "00112233445566778899aabbccddeeff"

// MARK: - Fakes

@MainActor
private final class FakeSource: StrapWorkoutHeartRateSource {
    let timeline: SyncDeviceID
    var isLinkConnected = true
    var ready = true
    var syncing = false
    var canStreamHeartRate = true
    var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    var rrIntervalsReceived = 0
    func startWorkoutHeartRate() {}
    func stopWorkoutHeartRate() {}
    func sendOwedOrphanStop() {}
    func syncHistory(manual: Bool) {}
    init(timeline: SyncDeviceID) { self.timeline = timeline }
}

@MainActor
private final class AcceptingHealth: StrapWorkoutHealthWriting {
    func save(_ write: StrapWorkoutWrite) async -> Bool { true }
}

@MainActor
private final class RecoveryHealth: HeartRateRecoveryHealthWriting {
    private(set) var cardioWrites: [(bpm: Int, at: Date)] = []
    func saveRecoveryHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus { .saved }
    func saveCardioRecovery(_ bpm: Int, at date: Date, timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus {
        cardioWrites.append((bpm, date))
        return .saved
    }
}

@MainActor
private final class MemoryJournal: StrapWorkoutJournalStoring {
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
private final class StillLocation: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    func start(route: Bool) { gpsActive = true }
    func setPaused(_ paused: Bool) {}
    func stop() { gpsActive = false }
}

@MainActor
private final class DiscardingHRStore: StrapWorkoutHRStore {
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {}
}

@MainActor
private final class StrapTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    private(set) var writes: [ZeppWrite] = []
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }
    func write(_ write: ZeppWrite) {
        writes.append(write)
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) {
        inbox.append((characteristic, nil, enabled))
    }
    func read(_ characteristic: ZeppCharacteristic) {
        switch characteristic {
        case .hardwareRevision: inbox.append((characteristic, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((characteristic, [64], false))
        default: break
        }
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

    /// Plaintext single-chunk commands the phone sent to the heart-rate endpoint (`0x001D`).
    var heartRateCommands: [[UInt8]] {
        writes.filter { $0.characteristic == .chunkedWrite }.compactMap { w in
            let b = w.bytes
            guard b.count > 11, b[0] == 0x03, b[1] & 0x01 != 0, b[1] & 0x08 == 0,
                  UInt16(b[9]) | (UInt16(b[10]) << 8) == ZeppEndpoint.heartRate else { return nil }
            return Array(b[11...])
        }
    }
}

@MainActor
private final class Keys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

// MARK: - 85a, 85b: the recorder

@MainActor
final class HeartRateRecoveryFollowUpRecorderTests: XCTestCase {
    private var now = t0
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-FU")
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)   // max HR 180
    private var recorders: [StrapWorkoutRecorder] = []
    /// The session holds its transport weakly: keep every one alive for the test.
    private var transports: [StrapTransport] = []

    override func tearDown() {
        for recorder in recorders {
            if recorder.isRecording { recorder.cancel() }
            recorder.skipRecovery()
        }
        recorders.removeAll()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "no test may leave the strap held")
        transports.removeAll()
        super.tearDown()
    }

    private func freshOrphanStop() -> StrapWorkoutOrphanStop {
        StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-hrr-fu-orphan-\(UUID().uuidString)")!)
    }

    private func makeRecorder(source: StrapWorkoutHeartRateSource?, journal: MemoryJournal? = nil,
                              orphanStop: StrapWorkoutOrphanStop, recovery: RecoveryHealth? = nil)
        -> StrapWorkoutRecorder {
        let journal = journal ?? MemoryJournal()
        let recovery = recovery ?? RecoveryHealth()
        let profile = self.profile
        let recorder = StrapWorkoutRecorder(
            source: { source }, health: AcceptingHealth(), journal: journal, hrStore: { DiscardingHRStore() },
            location: StillLocation(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: orphanStop,
            tombstones: WorkoutTombstones(UserDefaults(suiteName: "strap-hrr-fu-tomb-\(UUID().uuidString)")!),
            recoveryHealth: recovery,
            recoveryWindows: WorkoutRecoveryWindows(UserDefaults(suiteName: "strap-hrr-fu-win-\(UUID().uuidString)")!),
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = .runningIndoor
        recorders.append(recorder)
        return recorder
    }

    /// A real session against the simulated strap, authenticated and ready.
    private func connect(orphanStop: StrapWorkoutOrphanStop) -> (HelioSession, StrapTransport) {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0),
                           (0x0043, 0), (0x0047, 0), (0x004B, 0), (0x0082, 0)]
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        let transport = StrapTransport(device: device)
        let keys = Keys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000B7",
                                   key: keys.load(), keyStore: keys, sink: nil, findState: HelioFindState(),
                                   clock: { [unowned self] in self.now }, autoTick: false, autoSyncOnConnect: false,
                                   workoutHoldsLink: { false })
        transport.session = session
        session.orphanStop = orphanStop
        session.start()
        transport.drain()
        transports.append(transport)
        return (session, transport)
    }

    /// One reading a second over `(from, to]`, from the strap through the session, ticking the recorder.
    private func stream(_ session: HelioSession, _ recorder: StrapWorkoutRecorder, from: TimeInterval,
                        to: TimeInterval, bpm: (TimeInterval) -> Int) async {
        var s = from + 1
        while s <= to {
            now = at(s)
            session.received(.heartRateMeasurement, [0x00, UInt8(bpm(s))])
            await recorder.tick(now: now)
            s += 1
        }
    }

    // MARK: 85a — a kill in the window leaves the strap an owed 04 00

    /// A 10-minute run peaking at 170 bpm, ended at +600, with the window open.
    private func runAndEnd(_ session: HelioSession, _ recorder: StrapWorkoutRecorder) async {
        recorder.start()
        await stream(session, recorder, from: 0, to: 600) { $0 > 540 ? 170 : 150 }
        await recorder.end()
    }

    func testAKillInTheWindowLeavesTheStrapAnOwedStopSentOnceAtItsNextReady() async {
        let owed = freshOrphanStop()
        let journal = MemoryJournal()
        let (session, _) = connect(orphanStop: freshOrphanStop())
        let recorder = makeRecorder(source: session, journal: journal, orphanStop: owed)
        await runAndEnd(session, recorder)
        await stream(session, recorder, from: 600, to: 640) { _ in 150 }   // +40 s: killed here
        XCTAssertTrue(recorder.isMeasuringRecovery)
        XCTAssertNil(journal.loadJournal(), "End cleared the journal: nothing on disk says a stream is running")
        XCTAssertTrue(owed.owed, "so the stop is owed while the window keeps the stream")

        // Relaunch: a recorder over the same journal and flag, and no strap connected yet.
        now = at(900)
        let relaunched = makeRecorder(source: nil, journal: journal, orphanStop: owed)
        relaunched.resolveOrphan()
        XCTAssertTrue(owed.owed, "no strap to tell: still owed")
        let (next, nextTransport) = connect(orphanStop: owed)
        XCTAssertTrue(next.ready)
        XCTAssertEqual(nextTransport.heartRateCommands, [ZeppHeartRateControl.stop], "exactly one 04 00, at ready")
        XCTAssertFalse(owed.owed)
        let (_, later) = connect(orphanStop: owed)
        XCTAssertEqual(later.heartRateCommands, [], "and never again")
    }

    func testAKillInTheWindowOnAReadyStrapSendsTheStopFromTheLaunchRecovery() async {
        let owed = freshOrphanStop()
        let journal = MemoryJournal()
        let (session, _) = connect(orphanStop: freshOrphanStop())
        let recorder = makeRecorder(source: session, journal: journal, orphanStop: owed)
        await runAndEnd(session, recorder)
        await stream(session, recorder, from: 600, to: 640) { _ in 150 }

        now = at(900)
        let (next, nextTransport) = connect(orphanStop: freshOrphanStop())   // ready before the recovery looks
        next.orphanStop = owed
        let relaunched = makeRecorder(source: next, journal: journal, orphanStop: owed)
        relaunched.resolveOrphan()
        XCTAssertEqual(nextTransport.heartRateCommands, [ZeppHeartRateControl.stop], "04 00 once")
        XCTAssertFalse(owed.owed)
        relaunched.resolveOrphan()
        XCTAssertEqual(nextTransport.heartRateCommands, [ZeppHeartRateControl.stop], "and not again")
    }

    func testAWindowThatClosesNormallyLeavesNothingOwed() async {
        let owed = freshOrphanStop()
        let (session, transport) = connect(orphanStop: freshOrphanStop())
        let recorder = makeRecorder(source: session, orphanStop: owed)
        await runAndEnd(session, recorder)
        XCTAssertTrue(owed.owed)
        await stream(session, recorder, from: 600, to: 720) { _ in 150 }
        XCTAssertFalse(recorder.isMeasuringRecovery)
        XCTAssertEqual(recorder.recoveryClosedBy, .complete)
        XCTAssertFalse(owed.owed, "the window stopped the stream itself")
        XCTAssertEqual(transport.heartRateCommands.last, ZeppHeartRateControl.stop)

        now = at(900)
        let (_, later) = connect(orphanStop: owed)
        XCTAssertEqual(later.heartRateCommands, [], "the next connection has no stop to send")
    }

    func testSkippingTheWindowLeavesNothingOwed() async {
        let owed = freshOrphanStop()
        let (session, _) = connect(orphanStop: freshOrphanStop())
        let recorder = makeRecorder(source: session, orphanStop: owed)
        await runAndEnd(session, recorder)
        XCTAssertTrue(owed.owed)
        recorder.skipRecovery()
        XCTAssertEqual(recorder.recoveryClosedBy, .skipped)
        XCTAssertFalse(owed.owed)
    }

    func testAnEndWithoutAWindowOwesNothing() async {
        let owed = freshOrphanStop()
        let (session, _) = connect(orphanStop: freshOrphanStop())
        let profile = self.profile
        let recorder = StrapWorkoutRecorder(
            source: { session }, health: AcceptingHealth(), journal: MemoryJournal(), hrStore: { DiscardingHRStore() },
            location: StillLocation(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: owed, clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = .runningIndoor
        recorders.append(recorder)
        await runAndEnd(session, recorder)
        XCTAssertFalse(recorder.isMeasuringRecovery)
        XCTAssertFalse(owed.owed)
    }

    func testAWindowEndedByALostLinkStaysOwedForTheNextReady() async {
        let owed = freshOrphanStop()
        let source = FakeSource(timeline: timeline)
        let recorder = makeRecorder(source: source, orphanStop: owed)
        recorder.start()
        for s in 1...600 {
            now = at(TimeInterval(s))
            source.heartRateObserver?(s > 540 ? 170 : 150, now)
            await recorder.tick(now: now)
        }
        await recorder.end()
        XCTAssertTrue(owed.owed)
        source.isLinkConnected = false
        now = at(630)
        await recorder.tick(now: now)
        XCTAssertEqual(recorder.recoveryClosedBy, .linkLost)
        XCTAssertTrue(owed.owed, "nothing could be sent down a dropped link: the next ready sends it")
    }

    func testAWindowClosedByTheTickAtTenSecondsPastTheMarkLeavesNothingOwed() async {
        let owed = freshOrphanStop()
        let (session, transport) = connect(orphanStop: freshOrphanStop())
        let recorder = makeRecorder(source: session, orphanStop: owed)
        await runAndEnd(session, recorder)
        await stream(session, recorder, from: 600, to: 700) { _ in 150 }
        XCTAssertTrue(recorder.isMeasuringRecovery)
        XCTAssertTrue(owed.owed)
        now = at(729)
        await recorder.tick(now: now)
        XCTAssertTrue(recorder.isMeasuringRecovery, "up to 10 s to catch the +120 s reading")
        now = at(730)
        await recorder.tick(now: now)
        XCTAssertEqual(recorder.recoveryClosedBy, .complete)
        XCTAssertFalse(owed.owed, "the window stopped the stream itself")
        XCTAssertEqual(transport.heartRateCommands.last, ZeppHeartRateControl.stop)
    }

    func testAWindowClosedByANewWorkoutLeavesNothingOwed() async {
        let owed = freshOrphanStop()
        let (session, transport) = connect(orphanStop: freshOrphanStop())
        let recorder = makeRecorder(source: session, orphanStop: owed)
        await runAndEnd(session, recorder)
        await stream(session, recorder, from: 600, to: 640) { _ in 150 }
        XCTAssertTrue(owed.owed)
        recorder.endRecoveryForNewWorkout()
        XCTAssertEqual(recorder.recoveryClosedBy, .newWorkout)
        XCTAssertFalse(owed.owed)
        XCTAssertEqual(transport.heartRateCommands.last, ZeppHeartRateControl.stop)
    }

    // MARK: 85b — no negative Cardio Recovery

    /// A 10-minute run peaking at 170 bpm (zone 5 at 40), then `after` bpm for the whole window.
    private func cardioWrites(after: Int) async -> (writes: [(bpm: Int, at: Date)], outcome: HeartRateRecovery.Outcome?) {
        let source = FakeSource(timeline: timeline)
        let recovery = RecoveryHealth()
        let recorder = makeRecorder(source: source, orphanStop: freshOrphanStop(), recovery: recovery)
        recorder.start()
        for s in 1...720 {
            now = at(TimeInterval(s))
            source.heartRateObserver?(s <= 600 ? (s > 540 ? 170 : 150) : after, now)
            await recorder.tick(now: now)
            if s == 600 { await recorder.end() }
        }
        await recorder.recoveryWriteTask?.value
        XCTAssertFalse(recorder.isMeasuringRecovery)
        return (recovery.cardioWrites, recorder.heartRateRecovery)
    }

    func testAHeartRateThatRoseIsShownAndNotWrittenToHealth() async {
        let (writes, outcome) = await cardioWrites(after: 172)
        XCTAssertEqual(outcome?.oneMinute.drop, -2, "the summary still has the measured value")
        XCTAssertEqual(HeartRateRecoveryText.values(outcome!), "1 min heart rate rose, 2 min +2 bpm")
        XCTAssertEqual(writes.count, 0, "Cardio Recovery is a drop, not a rise")
    }

    func testAHeartRateThatDidNotMoveIsNotWrittenToHealth() async {
        let (writes, outcome) = await cardioWrites(after: 170)
        XCTAssertEqual(outcome?.oneMinute.drop, 0)
        XCTAssertEqual(writes.count, 0)
    }

    func testAOneBeatDropIsWrittenToHealth() async {
        let (writes, outcome) = await cardioWrites(after: 169)
        XCTAssertEqual(outcome?.oneMinute.drop, 1)
        XCTAssertEqual(writes.map(\.bpm), [1])
        XCTAssertEqual(writes.first?.at, at(660))
    }
}

// MARK: - 85c, 85d: the detail's peak and the delete

@MainActor
final class HeartRateRecoveryFollowUpHistoryTests: XCTestCase {
    private func reading(_ bpm: Int, _ s: TimeInterval) -> HRSample { HRSample(bpm: bpm, start: at(s - 1), end: at(s)) }

    func testAnInstantInsideTheWorkoutIsNotThePeak() throws {
        var workout = (1...600).map { reading($0 > 540 ? 170 : 150, Double($0)) }
        workout.append(HRSample(bpm: 195, start: at(300)))   // an all-day history instant in the workout's span
        let window = DateInterval(start: at(600), end: at(730))
        let rows = [reading(130, 661)]
        let outcome = try XCTUnwrap(WorkoutDetailContent.recovery(workoutHR: workout, storedRows: rows,
                                                                  window: window, age: 40))
        XCTAssertEqual(outcome.peak, 170)
        XCTAssertEqual(outcome.oneMinute.drop, 40, "from the workout's peak, not the instant")
    }

    func testAWorkoutOfOnlyInstantsHasNoPeakToMeasureFrom() throws {
        let workout = [HRSample(bpm: 170, start: at(300)), HRSample(bpm: 168, start: at(310))]
        let window = DateInterval(start: at(600), end: at(730))
        let outcome = try XCTUnwrap(WorkoutDetailContent.recovery(workoutHR: workout, storedRows: [reading(130, 661)],
                                                                  window: window, age: 40))
        XCTAssertEqual(outcome.oneMinute, .notMeasured(.noWorkoutHeartRate))
    }

    // 85e N1: the words for a heart rate that did not fall

    private func outcome(oneMinute: Int, twoMinutes: Int) -> HeartRateRecovery.Outcome {
        HeartRateRecovery.Outcome(peak: 170, oneMinute: .measured(drop: oneMinute, reading: 170 - oneMinute, at: at(60)),
                                  twoMinutes: .measured(drop: twoMinutes, reading: 170 - twoMinutes, at: at(120)))
    }

    func testAOneMinuteValueThatDidNotFallSaysHeartRateRoseNeverMinusZero() {
        for drop in [-4, 0] {
            let o = outcome(oneMinute: drop, twoMinutes: 10)
            XCTAssertEqual(HeartRateRecoveryText.values(o), "1 min heart rate rose, 2 min -10 bpm")
            XCTAssertEqual(HeartRateRecoveryText.headline(o), "Heart rate recovery: 1 min heart rate rose, 2 min -10 bpm")
            XCTAssertEqual(HeartRateRecoveryText.reasons(o),
                           ["1 min: heart rate rose, so it isn't saved to Apple Health as Cardio Recovery."])
            let rows = WorkoutDetailContent.recoveryRow(o)
            XCTAssertEqual(rows.value, "1 min heart rate rose, 2 min -10 bpm", "the detail says it too")
            XCTAssertNotNil(rows.caption)
        }
        XCTAssertFalse(HeartRateRecoveryText.values(outcome(oneMinute: 0, twoMinutes: 0)).contains("-0"))
    }

    func testAOneMinuteDropKeepsItsNumberAndNeedsNoExplanation() {
        let o = outcome(oneMinute: 1, twoMinutes: 20)
        XCTAssertEqual(HeartRateRecoveryText.values(o), "1 min -1 bpm, 2 min -20 bpm")
        XCTAssertEqual(HeartRateRecoveryText.reasons(o), [])
    }

    // 85e S1: a delete never asks Health about a type it was never granted

    func testADeleteAsksAboutCardioRecoveryOnlyWhenSharingIsGranted() {
        let cardio = HKQuantityType(.heartRateRecoveryOneMinute)
        for status in [HKAuthorizationStatus.notDetermined, .sharingDenied] {
            let types = HealthKitWorkoutStore.ownedTypesToQuery(cardioRecoveryStatus: status)
            XCTAssertFalse(types.contains(cardio), "\(status.rawValue): nothing of ours can exist")
            XCTAssertEqual(types.count, HealthKitWorkoutStore.ownedSampleTypes.count - 1,
                           "every other owned type is still asked")
        }
        let granted = HealthKitWorkoutStore.ownedTypesToQuery(cardioRecoveryStatus: .sharingAuthorized)
        XCTAssertEqual(granted, HealthKitWorkoutStore.ownedSampleTypes)
        XCTAssertTrue(granted.contains(cardio))
    }

    // 85d

    private func workout(end s: TimeInterval) -> HKWorkout {
        HKWorkout(activityType: .running, start: at(s - 600), end: at(s))
    }

    func testCardioRecoveryGoesWithTheWorkout() {
        let owned = HealthKitWorkoutStore.ownedSampleTypes
        XCTAssertTrue(owned.contains(HKQuantityType(.heartRateRecoveryOneMinute)))
        XCTAssertFalse(HealthKitWorkoutStore.keptSampleTypes.contains(HKQuantityType(.heartRateRecoveryOneMinute)))
    }

    func testCardioRecoveryIsMatchedByItsOwnDateAndOurSourceNotByTheWorkout() throws {
        let ourSource = NSPredicate(format: "sourceStandIn == 1")
        let w = workout(end: 600)
        let predicate = HealthKitWorkoutStore.ownedPredicate(
            for: HKQuantityType(.heartRateRecoveryOneMinute), workout: w, ourSource: ourSource)
        let compound = try XCTUnwrap(predicate as? NSCompoundPredicate)
        XCTAssertEqual(compound.compoundPredicateType, .and)
        let parts = compound.subpredicates.compactMap { $0 as? NSPredicate }.map(\.predicateFormat)
        let dated = HKQuery.predicateForSamples(withStart: at(659.5), end: at(660.5),
                                                options: [.strictStartDate, .strictEndDate]).predicateFormat
        XCTAssertEqual(parts, [dated, ourSource.predicateFormat], "our source, dated end + 60 s of THIS workout")
        let other = HealthKitWorkoutStore.ownedPredicate(
            for: HKQuantityType(.heartRateRecoveryOneMinute), workout: workout(end: 900), ourSource: ourSource)
        XCTAssertNotEqual(other.predicateFormat, predicate.predicateFormat, "another workout's sample is not caught")
    }

    func testEveryOtherOwnedTypeIsStillMatchedBySavedWithTheWorkout() {
        let ourSource = NSPredicate(format: "sourceStandIn == 1")
        let w = workout(end: 600)
        for type in HealthKitWorkoutStore.ownedSampleTypes where type != HKQuantityType(.heartRateRecoveryOneMinute) {
            XCTAssertEqual(HealthKitWorkoutStore.ownedPredicate(for: type, workout: w, ourSource: ourSource).predicateFormat,
                           HealthKitWorkoutStore.savedWith(w, ourSource: ourSource).predicateFormat)
        }
    }
}
