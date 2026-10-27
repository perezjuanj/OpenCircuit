import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The strap's realtime step stream for indoor workouts (#339, decision 84b, 84c), end to end against
// the simulated strap (`FakeZeppDevice`) through `HelioSession`: when `05 01` may go out, every path
// that sends `05 00`, the persisted flag across a killed process, and the breadcrumb's counts. Every
// key, counter and time is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private let keyHex = "00112233445566778899aabbccddeeff"
/// The Helio's list plus `0x0016` (plaintext), the endpoint decision 84a needs.
private let servicesWithSteps: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x0016, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0),
    (0x0043, 0), (0x0047, 0), (0x004B, 0), (0x0082, 0),
]
private let servicesWithoutSteps = servicesWithSteps.filter { $0.endpoint != 0x0016 }

@MainActor
private final class StepStrapTransport: HelioTransport {
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
        switch characteristic {
        case .hardwareRevision: inbox.append((characteristic, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((characteristic, [64], false))
        default: break
        }
    }
    func push(_ notifications: [FakeZeppDevice.Notification]) {
        for n in notifications { inbox.append((n.characteristic, n.bytes, false)) }
        drain()
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
private final class StepKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
final class IndoorRunStepStreamTests: XCTestCase {
    private var clock = t0
    private var suites: [String] = []
    private var holds = false
    private var events: [HelioSessionEvent] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        let name = "indoor-steps-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeDevice(steps: Bool = true) -> FakeZeppDevice {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = steps ? servicesWithSteps : servicesWithoutSteps
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        return device
    }

    private func connect(_ device: FakeZeppDevice, flag: StrapStepStreamFlag) -> (HelioSession, StepStrapTransport) {
        let transport = StepStrapTransport(device: device)
        let keys = StepKeys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000C9",
                                   key: keys.load(), keyStore: keys, sink: nil, findState: HelioFindState(),
                                   onEvent: { [unowned self] in self.events.append($0) },
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: false,
                                   workoutHoldsLink: { [unowned self] in self.holds })
        transport.session = session
        session.orphanStop = StrapWorkoutOrphanStop(freshDefaults())
        session.stepStreamFlag = flag
        session.start()
        transport.drain()
        return (session, transport)
    }

    private var stepReports: [StrapStepStreamReport] {
        events.compactMap { if case .stepStream(let report) = $0 { return report } else { return nil } }
    }

    // MARK: When `05 01` may go out

    func testTheStreamTurnsOnOnlyWhileAWorkoutHoldsTheLinkOnAStrapThatListsTheEndpoint() {
        let flag = StrapStepStreamFlag(freshDefaults())
        let device = makeDevice()
        let (session, transport) = connect(device, flag: flag)
        XCTAssertTrue(session.ready)
        XCTAssertTrue(session.canStreamSteps)

        holds = false
        XCTAssertFalse(session.startWorkoutSteps(), "no workout holds the link: never `05 01`")
        XCTAssertEqual(device.realtimeStepsCommands, [])
        XCTAssertFalse(flag.turnedOn)

        holds = true
        XCTAssertTrue(session.startWorkoutSteps())
        transport.drain()
        XCTAssertEqual(device.realtimeStepsCommands, [[0x05, 0x01]])
        XCTAssertTrue(flag.turnedOn, "set before the write, so a kill right after still owes the off")
        XCTAssertFalse(session.startWorkoutSteps(), "already on: not sent twice")
        XCTAssertEqual(device.realtimeStepsCommands, [[0x05, 0x01]])
    }

    func testAStrapWithoutTheEndpointIsSentNothingEvenDuringAWorkout() {
        let flag = StrapStepStreamFlag(freshDefaults())
        let device = makeDevice(steps: false)
        let (session, transport) = connect(device, flag: flag)
        holds = true
        XCTAssertFalse(session.canStreamSteps)
        XCTAssertFalse(session.startWorkoutSteps())
        session.stopWorkoutSteps()
        transport.drain()
        XCTAssertEqual(device.realtimeStepsCommands, [])
        XCTAssertFalse(device.receivedEndpoints.contains(ZeppEndpoint.realtimeSteps))
        XCTAssertFalse(flag.turnedOn)
    }

    // MARK: Frames and the off

    func testOurFramesReachTheObserverAndTheOffClearsTheFlagAndReportsCountsOnly() {
        let flag = StrapStepStreamFlag(freshDefaults())
        let device = makeDevice()
        let (session, transport) = connect(device, flag: flag)
        var counters: [Int] = []
        session.stepCounterObserver = { counter, _ in counters.append(counter) }
        holds = true
        session.startWorkoutSteps()
        transport.drain()
        clock = t0.addingTimeInterval(3)
        transport.push(device.stepFrame(1_200))
        clock = t0.addingTimeInterval(5)
        transport.push(device.stepFrame(1_230))
        XCTAssertEqual(counters, [1_200, 1_230])
        XCTAssertFalse(events.contains { if case .strapMessage(let endpoint, _, _) = $0 { return endpoint == 0x0016 } else { return false } },
                       "our own frames are not strap-initiated traffic (no idle-link wake)")

        session.stopWorkoutSteps()
        transport.drain()
        XCTAssertEqual(device.realtimeStepsCommands, [[0x05, 0x01], [0x05, 0x00]])
        XCTAssertFalse(device.realtimeStepsOn)
        XCTAssertFalse(flag.owesOff)
        XCTAssertEqual(stepReports.count, 1)
        let report = stepReports[0]
        XCTAssertEqual(report.frames, 2)
        XCTAssertEqual(report.firstFrameDelay ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(report.ackStatus, 0x01)
        XCTAssertEqual(HelioBreadcrumbs.stepStreamText(report), "realtime steps: 2 frame(s), first after 3 s, ack 06 01 01")

        // A frame after our off is unasked again: §16.5's one `05 00`, and it never reaches the observer.
        transport.push(device.stepFrame(1_240))
        XCTAssertEqual(counters, [1_200, 1_230])
        XCTAssertEqual(device.realtimeStepsCommands.last, [0x05, 0x00])
        XCTAssertFalse(device.realtimeStepsCommands.dropFirst().contains([0x05, 0x01]), "never `05 01` again")
    }

    func testUnaskedFramesOutsideAWorkoutStillGetTheOneOffAndNeverAnOn() {
        let flag = StrapStepStreamFlag(freshDefaults())
        let device = makeDevice()
        let (session, transport) = connect(device, flag: flag)
        var counters: [Int] = []
        session.stepCounterObserver = { counter, _ in counters.append(counter) }
        transport.push(device.stepFrame(10))
        transport.push(device.stepFrame(11))
        XCTAssertEqual(device.realtimeStepsCommands, [[0x05, 0x00]], "once per connection")
        XCTAssertEqual(counters, [])
    }

    // MARK: The owed off across a link drop and a killed process

    func testALinkDropKeepsTheOffOwedAndTheReconnectSendsItAtSetupWithoutTurningItBackOn() {
        let flag = StrapStepStreamFlag(freshDefaults())
        let device = makeDevice()
        let (session, transport) = connect(device, flag: flag)
        holds = true
        session.startWorkoutSteps()
        transport.drain()
        session.linkLost()
        session.stopWorkoutSteps()   // End on a dead link: nothing can be sent
        XCTAssertTrue(flag.turnedOn, "the off is still owed")
        XCTAssertEqual(stepReports.count, 1, "the connection's counts are reported when it ends")

        // The strap comes back (a new session; the strap kept the stream on, §16.2 row 5).
        let (_, again) = connect(device, flag: flag)
        again.drain()
        XCTAssertEqual(device.realtimeStepsCommands, [[0x05, 0x01], [0x05, 0x00]], "`05 00` at the reconnect's setup")
        XCTAssertFalse(device.realtimeStepsOn)
        XCTAssertFalse(flag.owesOff)
    }

    func testAKilledProcessLeavesTheNextConnectionAnOwedOff() {
        let defaults = freshDefaults()
        let device = makeDevice()
        do {
            let (session, transport) = connect(device, flag: StrapStepStreamFlag(defaults))
            holds = true
            session.startWorkoutSteps()
            transport.drain()
            // The process dies here: no stop, no linkLost.
        }
        holds = false
        // Relaunch: a fresh flag over the same persisted defaults, a fresh session.
        let relaunched = StrapStepStreamFlag(defaults)
        XCTAssertTrue(relaunched.turnedOn)
        _ = connect(device, flag: relaunched)
        XCTAssertEqual(device.realtimeStepsCommands, [[0x05, 0x01], [0x05, 0x00]])
        XCTAssertFalse(relaunched.owesOff)
        // And the connection after that owes nothing.
        _ = connect(device, flag: relaunched)
        XCTAssertEqual(device.realtimeStepsCommands.count, 2)
    }

    func testAJournalOwedOffIsSentAtConnectAndClearedEvenWhenTheStrapNeverListedTheEndpoint() {
        let flag = StrapStepStreamFlag(freshDefaults())
        flag.offOwed = true
        let listed = makeDevice()
        _ = connect(listed, flag: flag)
        XCTAssertEqual(listed.realtimeStepsCommands, [[0x05, 0x00]])
        XCTAssertFalse(flag.owesOff)

        flag.offOwed = true
        let unlisted = makeDevice(steps: false)
        _ = connect(unlisted, flag: flag)
        XCTAssertEqual(unlisted.realtimeStepsCommands, [], "a strap without `0x0016` never got a `05 01`")
        XCTAssertFalse(flag.owesOff)
    }
}
