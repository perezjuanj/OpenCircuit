// The strap's workout mode on 0x0019 (ZEPP_PROTOCOL.md §18.9, #359, decision 89): every byte string
// §18.9 gives, built and parsed exactly; truncated and unknown input never traps; the 89b sport
// table; the sequence machine's happy path, every 89c fallback and every 89f reconciliation; and the
// Heart Rate Broadcast setting (89g). Every timestamp and value is made up and rounded.

import XCTest
import OpenCircuitKit
@testable import ZeppKit
import ZeppKitTesting

/// A made-up, rounded start time: 1 800 000 000 = 0x6b49d200 = `00 d2 49 6b` little-endian.
private let start: UInt32 = 1_800_000_000
private let startLE = "00 d2 49 6b"
private let t0 = date(1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private typealias Machine = ZeppWorkoutModeMachine
private let ok03 = hex("10 03 01")
private let idleState = hex("10 06 01 00 00")
private func runningState(_ start: UInt32, sport: UInt8) -> [UInt8] { hex("10 06 01 00 01") + le32(start) + [sport] }

/// A live frame, fields `0e` (swings) or `06` (none).
private func liveFrame(active: UInt32, hr: UInt8, kcal: UInt32, avg: UInt8, max: UInt8, swings: UInt16?) -> [UInt8] {
    var out = hex("14 00 24 01 00") + [swings == nil ? 0x06 : 0x0e] + le32(active) + [hr] + le32(kcal) + [avg, max]
    if let swings { out += le16(swings) }
    return out
}

final class WorkoutModeCodecTests: XCTestCase {

    // MARK: Every §18.9 byte string, phone → strap

    func testEveryPhoneMessageIsTheSpecsBytes() {
        XCTAssertEqual(ZeppEndpoint.workout, 0x0019)
        XCTAssertEqual(ZeppEndpoint.defaultEncryption[ZeppEndpoint.workout], true, "§3.5: 0x0019 is encrypted")
        XCTAssertEqual(ZeppWorkoutCommand.capabilityQuery, hex("01"))
        XCTAssertEqual(ZeppWorkoutCommand.stateQuery, hex("06 00"))
        XCTAssertEqual(ZeppWorkoutCommand.keepAlive, hex("05"))
        XCTAssertEqual(ZeppWorkoutCommand.started(startTime: start), hex("03 01 06 00 00 00 \(startLE) 00 00 00 00"))
        XCTAssertEqual(ZeppWorkoutCommand.control(.pause, activeSeconds: 600), hex("03 02 04 00 00 00 58 02 00 00"))
        XCTAssertEqual(ZeppWorkoutCommand.control(.resume, activeSeconds: 600), hex("03 03 04 00 00 00 58 02 00 00"))
        XCTAssertEqual(ZeppWorkoutCommand.control(.end, activeSeconds: 1800), hex("03 04 04 00 00 00 08 07 00 00"))
        XCTAssertNil(ZeppWorkoutCommand.Control(rawValue: 0x05), "89j: 03 05 saved too on our strap; the app never sends it")
        XCTAssertEqual(ZeppWorkoutCommand.end(activeSeconds: 1800),
                       [hex("03 02 04 00 00 00 08 07 00 00"), hex("03 04 04 00 00 00 08 07 00 00")],
                       "every end is pause, then end (89a)")
        XCTAssertEqual(ZeppWorkoutCommand.end(activeSeconds: 10),
                       [hex("03 02 04 00 00 00 0a 00 00 00"), hex("03 04 04 00 00 00 0a 00 00 00")])
    }

    // MARK: The 89b sport table

    func testTheSportTableIsDecision89b() {
        func start(_ sport: WorkoutSportType) -> [UInt8]? { ZeppWorkoutSport.forSport(sport)?.startRequest }
        XCTAssertEqual(start(.runningIndoor), hex("02 02 00 00 01"))
        XCTAssertEqual(start(.strengthTraining), hex("02 34 00 00 01"))
        XCTAssertEqual(start(.cyclingIndoor), hex("02 08 00 00 01"))
        XCTAssertEqual(start(.rowing), hex("02 17 00 00 01"))
        XCTAssertEqual(start(.yoga), hex("02 3c 00 00 01"))
        XCTAssertEqual(start(.walkingIndoor), hex("02 28 00 00 01"))
        XCTAssertEqual(start(.other), hex("02 05 00 00 01"))
        XCTAssertEqual(start(.tennis), hex("02 11 00 00 01"))
        XCTAssertEqual(start(.pickleball), hex("02 e3 00 01 01 02 00 00 00 02"), "Zepp's racket form, byte for byte")
        for sport in [WorkoutSportType.walkingOutdoor, .runningOutdoor, .cyclingOutdoor, .hiking] {
            XCTAssertNil(ZeppWorkoutSport.forSport(sport), "\(sport): no strap mode for outdoor GPS sports (89b)")
        }
        let tested = WorkoutSportType.allCases.compactMap(ZeppWorkoutSport.forSport).filter(\.isHardwareTested).map(\.code)
        XCTAssertEqual(Set(tested), [0x02, 0x34, 0x11, 0xe3], "the codes tested on hardware (§18.9)")
        for sport in WorkoutSportType.allCases {
            XCTAssertEqual(ZeppWorkoutSport.forSport(sport)?.startRequest.prefix(2), ZeppWorkoutSport.forSport(sport).map { [0x02, $0.code] }.map { ArraySlice($0) })
        }
    }

    func testTheNewSportsAreStrapOnlyAndTheRingKeepsItsList() {
        XCTAssertTrue(WorkoutSportType.tennis.isStrapOnly)
        XCTAssertTrue(WorkoutSportType.pickleball.isStrapOnly)
        XCTAssertEqual(WorkoutSportType.ringSports, [.walkingOutdoor, .walkingIndoor, .runningOutdoor, .runningIndoor,
                                                    .cyclingOutdoor, .cyclingIndoor, .rowing, .hiking,
                                                    .strengthTraining, .yoga, .other],
                       "89i: the ring's pickers are exactly as before")
        XCTAssertFalse(WorkoutSportType.tennis.isOutdoor)
        XCTAssertFalse(WorkoutSportType.pickleball.isOutdoor)
    }

    // MARK: Strap → phone

    func testRepliesAndTheStateReply() {
        let capability = ZeppWorkoutReply.parse(hex("10 01 01 03 01 01 01 03 00 00 00"))
        XCTAssertEqual(capability?.opcode, 0x01)
        XCTAssertEqual(capability?.isAccepted, true)
        XCTAssertEqual(capability?.body, hex("03 01 01 01 03 00 00 00"))
        XCTAssertEqual(ZeppWorkoutReply.parse(hex("10 02 01")), ZeppWorkoutReply(opcode: 0x02, status: 0x01, body: []))
        XCTAssertEqual(ZeppWorkoutReply.parse(hex("10 03 01"))?.isAccepted, true)
        XCTAssertEqual(ZeppWorkoutReply.parse(hex("10 02 05"))?.isAccepted, false)

        XCTAssertEqual(ZeppWorkoutState.parse(idleState), .idle)
        XCTAssertEqual(ZeppWorkoutState.parse(hex("10 06 01 00 01 \(startLE) e3")), .running(startTime: start, sport: 0xe3))
        XCTAssertEqual(ZeppWorkoutState.parse(hex("10 06 02 00 00")), .unknown, "another status is never idle")
        XCTAssertEqual(ZeppWorkoutState.parse(hex("10 06 01 00 02")), .unknown, "an unknown state byte is never idle")
        XCTAssertEqual(ZeppWorkoutState.parse(hex("10 06 01 00 01 00 08")), .unknown, "truncated running")
        XCTAssertEqual(ZeppWorkoutState.parse(hex("10 06 01 00 00 00")), .unknown, "idle with extra bytes is not the idle reply")
        XCTAssertNil(ZeppWorkoutState.parse(hex("10 02 01")))
        XCTAssertNil(ZeppWorkoutState.parse(hex("14 00 24")))
    }

    func testFramesBothShapesAndTheFirstFrame() {
        // Pickleball/tennis shape: fields 0e, 19 bytes, swings present.
        let racket = hex("14 00 24 01 00 0e 3c 00 00 00 8c 2d 00 00 00 82 96 2a 00")
        XCTAssertEqual(racket.count, 19)
        XCTAssertEqual(ZeppWorkoutFrame.parse(racket), .live(ZeppWorkoutLiveFrame(
            fields: 0x0e, activeSeconds: 60, heartRate: 140, kilocalories: 45, averageHeartRate: 130,
            maximumHeartRate: 150, swings: 42)))
        // Strength shape: fields 06, 17 bytes, no swings.
        let strength = hex("14 00 24 01 00 06 3c 00 00 00 8c 2d 00 00 00 82 96")
        XCTAssertEqual(ZeppWorkoutFrame.parse(strength), .live(ZeppWorkoutLiveFrame(
            fields: 0x06, activeSeconds: 60, heartRate: 140, kilocalories: 45, averageHeartRate: 130,
            maximumHeartRate: 150, swings: nil)))
        XCTAssertEqual(ZeppWorkoutFrame.parse(liveFrame(active: 600, hr: 120, kcal: 80, avg: 110, max: 160, swings: 300)),
                       .live(ZeppWorkoutLiveFrame(fields: 0x0e, activeSeconds: 600, heartRate: 120, kilocalories: 80,
                                                  averageHeartRate: 110, maximumHeartRate: 160, swings: 300)))
        // First frame: start time, then zeros.
        XCTAssertEqual(ZeppWorkoutFrame.parse(hex("14 00 26 01 00 0e \(startLE) 00 00 00 00 00 00 00 00 00 00 00")),
                       .first(startTime: start))
        XCTAssertNil(ZeppWorkoutFrame.parse(hex("10 03 01")))
    }

    func testAnUnknownFieldsValueKeepsWhatItCanPlaceAndNeverFails() {
        // A higher bit on top of the strength shape: the base fields are placed, extras ignored.
        var extra = hex("14 00 24 01 00 16 3c 00 00 00 8c 2d 00 00 00 82 96") + hex("aa bb cc")
        guard case .live(let frame)? = ZeppWorkoutFrame.parse(extra) else { return XCTFail("base not placed") }
        XCTAssertEqual(frame.kilocalories, 45)
        XCTAssertNil(frame.swings)
        // Swings bit with a higher bit: swings placed too.
        extra = hex("14 00 24 01 00 1e 3c 00 00 00 8c 2d 00 00 00 82 96 2a 00 ff")
        guard case .live(let racket)? = ZeppWorkoutFrame.parse(extra) else { return XCTFail("base not placed") }
        XCTAssertEqual(racket.swings, 42)
        // Low bits unlike anything seen: nothing is placed.
        XCTAssertEqual(ZeppWorkoutFrame.parse(hex("14 00 24 01 00 07 3c 00 00 00 8c 2d 00 00 00 82 96")), .unknown)
        XCTAssertEqual(ZeppWorkoutFrame.parse(hex("14 00 24 01 00 0a 3c 00 00 00 8c 2d 00 00 00 82 96 2a 00")), .unknown)
        XCTAssertEqual(ZeppWorkoutFrame.parse(hex("14 00 25 01 00 06")), .unknown, "an unknown length class")
        XCTAssertEqual(ZeppWorkoutFrame.parse(hex("14 01 24 01 00 06 3c 00 00 00 8c 2d 00 00 00 82 96")), .unknown)
    }

    func testEveryTruncationAndRandomInputParsesWithoutTrapping() {
        let samples = [
            hex("10 01 01 03 01 01 01 03 00 00 00"), hex("10 06 01 00 01 \(startLE) e3"), idleState,
            liveFrame(active: 60, hr: 140, kcal: 45, avg: 130, max: 150, swings: 42),
            liveFrame(active: 60, hr: 140, kcal: 45, avg: 130, max: 150, swings: nil),
            hex("14 00 26 01 00 0e \(startLE) 00 00 00 00"),
        ]
        for sample in samples {
            for length in 0..<sample.count {
                let cut = Array(sample.prefix(length))
                _ = ZeppWorkoutReply.parse(cut)
                _ = ZeppWorkoutState.parse(cut)
                if let frame = ZeppWorkoutFrame.parse(cut), case .live(let live) = frame {
                    // A truncated racket frame keeps its base fields only if the base is whole.
                    XCTAssertGreaterThanOrEqual(cut.count, 17)
                    if cut.count < 19 { XCTAssertNil(live.swings) }
                }
            }
        }
        var random = TestBytes(seed: 359)
        var machine = Machine()
        _ = machine.start(ZeppWorkoutSport.forSport(.tennis)!, startTime: start, now: t0)
        for _ in 0..<5_000 {
            var bytes = random.bytes(random.int(0...24))
            if !bytes.isEmpty, random.int(0...1) == 0 { bytes[0] = [0x10, 0x14][random.int(0...1)] }
            _ = ZeppWorkoutReply.parse(bytes)
            _ = ZeppWorkoutState.parse(bytes)
            _ = ZeppWorkoutFrame.parse(bytes)
            _ = machine.receive(bytes, now: t0)
        }
    }
}

// MARK: - The sequence

final class WorkoutModeMachineTests: XCTestCase {

    private let tennis = ZeppWorkoutSport.forSport(.tennis)!
    private let pickleball = ZeppWorkoutSport.forSport(.pickleball)!

    /// A machine through `01` → idle → `02` → `10 02 01` → `03 01`, every message collected in order.
    private func started(_ sport: ZeppWorkoutSport? = nil, sent: inout [[UInt8]], events: inout [Machine.Event]) -> Machine {
        var m = Machine()
        for out in [m.start(sport ?? tennis, startTime: start, now: t0),
                    m.receive(hex("10 01 01 03 01 01 01 03 00 00 00"), now: at(0.2)),
                    m.receive(idleState, now: at(0.4)),
                    m.receive(hex("10 02 01"), now: at(0.6))] {
            sent += out.messages
            events += out.events
        }
        return m
    }

    func testHappyPathSendsTheSequenceInOrderAndSetsTheMarkerBeforeTheStart() {
        var sent: [[UInt8]] = []
        var events: [Machine.Event] = []
        var m = Machine()
        var out = m.start(pickleball, startTime: start, now: t0)
        XCTAssertEqual(out.messages, [hex("01")])
        XCTAssertEqual(out.events, [], "no marker before the strap read idle")
        out = m.receive(hex("10 01 01 03 01 01 01 03 00 00 00"), now: at(1))
        XCTAssertEqual(out.messages, [hex("06 00")])
        out = m.receive(idleState, now: at(2))
        XCTAssertEqual(out.messages, [hex("02 e3 00 01 01 02 00 00 00 02")])
        XCTAssertEqual(out.events, [.setMarker(ZeppWorkoutModeMarker(startTime: start, sportCode: 0xe3))],
                       "89f: set in the same output as 02, for the host to persist before sending")
        out = m.receive(hex("10 02 01"), now: at(3))
        XCTAssertEqual(out.messages, [hex("03 01 06 00 00 00 \(startLE) 00 00 00 00")],
                       "the started message carries OpenCircuit's own start time")
        XCTAssertEqual(m.receive(ok03, now: at(3.2)), Machine.Output())
        XCTAssertTrue(m.isActive)

        // Keep-alive every 5 s (from 10 02 01).
        XCTAssertEqual(m.tick(now: at(7.9)).messages, [])
        XCTAssertEqual(m.tick(now: at(8)).messages, [hex("05")])
        XCTAssertEqual(m.tick(now: at(13)).messages, [hex("05")])

        // The first frame confirms it, then every live frame is handed on.
        out = m.receive(hex("14 00 26 01 00 0e \(startLE) 00 00 00 00 00 00 00 00 00 00 00"), now: at(4))
        XCTAssertEqual(out.events, [.running])
        out = m.receive(liveFrame(active: 1, hr: 100, kcal: 0, avg: 100, max: 100, swings: 0), now: at(5))
        XCTAssertEqual(out.events, [.frame(ZeppWorkoutLiveFrame(fields: 0x0e, activeSeconds: 1, heartRate: 100,
                                                                 kilocalories: 0, averageHeartRate: 100,
                                                                 maximumHeartRate: 100, swings: 0))])
        // The frame watchdog never fires once a frame came.
        XCTAssertEqual(m.tick(now: at(20)).events, [])
        _ = (sent, events)
    }

    func testPauseResumeAndEndCarryOpenCircuitsActiveSecondsAndEndClearsOnTheSecondAck() {
        var sent: [[UInt8]] = []
        var events: [Machine.Event] = []
        var m = started(sent: &sent, events: &events)
        _ = m.receive(ok03, now: at(1))
        _ = m.receive(liveFrame(active: 1, hr: 100, kcal: 0, avg: 100, max: 100, swings: 0), now: at(2))
        var out = m.pause(activeSeconds: 600, now: at(600))
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 58 02 00 00")])
        XCTAssertEqual(out.events, [.markStrapPaused(true)])
        XCTAssertEqual(m.pause(activeSeconds: 600, now: at(601)).messages, [], "already paused on the strap")
        out = m.resume(activeSeconds: 600, now: at(700))
        XCTAssertEqual(out.messages, [hex("03 03 04 00 00 00 58 02 00 00")])
        XCTAssertEqual(out.events, [.markStrapPaused(false)])
        _ = m.receive(ok03, now: at(600.5))
        _ = m.receive(ok03, now: at(700.5))
        out = m.end(activeSeconds: 1800, now: at(1900))
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 08 07 00 00"), hex("03 04 04 00 00 00 08 07 00 00")])
        XCTAssertEqual(m.tick(now: at(1905)).messages, [], "no keep-alive once the end went out")
        XCTAssertEqual(m.receive(ok03, now: at(1900.2)).events, [], "the pause's ack does not clear the marker")
        XCTAssertEqual(m.receive(ok03, now: at(1900.4)).events, [.ended, .clearMarker(startTime: start)])
        XCTAssertFalse(m.isActive)
    }

    func testEndWhilePausedStillSendsPauseThenEnd() {
        var sent: [[UInt8]] = []
        var events: [Machine.Event] = []
        var m = started(sent: &sent, events: &events)
        _ = m.receive(liveFrame(active: 1, hr: 100, kcal: 0, avg: 100, max: 100, swings: nil), now: at(2))
        _ = m.pause(activeSeconds: 300, now: at(300))
        let out = m.end(activeSeconds: 300, now: at(400))
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 2c 01 00 00"), hex("03 04 04 00 00 00 2c 01 00 00")])
    }

    func testAPauseBeforeTheStartIsConfirmedGoesOutRightAfterStarted() {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        XCTAssertEqual(m.pause(activeSeconds: 2, now: at(2)).messages, [], "nothing is running on the strap yet")
        _ = m.receive(hex("10 01 01"), now: at(3))
        _ = m.receive(idleState, now: at(3))
        let out = m.receive(hex("10 02 01"), now: at(4))
        XCTAssertEqual(out.messages, [hex("03 01 06 00 00 00 \(startLE) 00 00 00 00"), hex("03 02 04 00 00 00 02 00 00 00")])
    }

    func testAnEndBeforeTheStartReplyEndsTheWorkoutOnceTheStrapAcceptsIt() {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        _ = m.receive(hex("10 01 01"), now: at(1))
        _ = m.receive(idleState, now: at(1))
        XCTAssertEqual(m.end(activeSeconds: 3, now: at(3)).messages, [])
        let out = m.receive(hex("10 02 01"), now: at(4))
        XCTAssertEqual(out.messages, [hex("03 01 06 00 00 00 \(startLE) 00 00 00 00"),
                                      hex("03 02 04 00 00 00 03 00 00 00"), hex("03 04 04 00 00 00 03 00 00 00")])
        _ = m.receive(ok03, now: at(4.1))
        _ = m.receive(ok03, now: at(4.2))
        XCTAssertEqual(m.receive(ok03, now: at(4.3)).events, [.ended, .clearMarker(startTime: start)])
    }

    func testAnEndBeforeTheStrapReadIdleSendsNothing() {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        XCTAssertEqual(m.end(activeSeconds: 1, now: at(1)), Machine.Output())
        XCTAssertEqual(m.receive(idleState, now: at(2)), Machine.Output(), "the late reply starts nothing")
    }

    // MARK: 89c fallbacks

    func testNoReplyAtAnyStepFallsBackAndNeverSendsMore() {
        for step in [Machine.Step.capability, .state, .start] {
            var m = Machine()
            _ = m.start(tennis, startTime: start, now: t0)
            if step != .capability { _ = m.receive(hex("10 01 01"), now: at(1)) }
            if step == .start { _ = m.receive(idleState, now: at(1)) }
            let sentAt: TimeInterval = step == .capability ? 0 : 1
            XCTAssertEqual(m.tick(now: at(sentAt + 7.9)), Machine.Output(), "\(step): within 8 s")
            let out = m.tick(now: at(sentAt + 8.1))
            XCTAssertEqual(out.events, [.unavailable(.noReply(step))])
            XCTAssertEqual(out.messages, [])
            XCTAssertFalse(m.isActive)
            XCTAssertEqual(m.tick(now: at(30)).messages, [], "\(step): no keep-alive, nothing else")
            XCTAssertEqual(m.pause(activeSeconds: 30, now: at(30)).messages, [])
            // 89o (b): after an unanswered `02` the strap may run ours, so End asks; before it, nothing.
            XCTAssertEqual(m.end(activeSeconds: 30, now: at(40)).messages, step == .start ? [hex("06 00")] : [])
        }
    }

    func testABadStatusFallsBack() {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        XCTAssertEqual(m.receive(hex("10 01 02"), now: at(1)).events, [.unavailable(.refused(.capability, status: 0x02))])

        m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        _ = m.receive(hex("10 01 01"), now: at(1))
        _ = m.receive(idleState, now: at(1))
        let out = m.receive(hex("10 02 07"), now: at(2))
        XCTAssertEqual(out.events, [.unavailable(.refused(.start, status: 0x07)), .clearMarker(startTime: start)],
                       "the strap refused: nothing of ours is running")
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(m.end(activeSeconds: 30, now: at(40)).messages, [])
    }

    func testANonIdleStateNeverStartsOrTouchesTheWorkout() {
        for state in [runningState(1_799_990_000, sport: 0x11), hex("10 06 01 00 07"), hex("10 06 03")] {
            var m = Machine()
            _ = m.start(tennis, startTime: start, now: t0)
            _ = m.receive(hex("10 01 01"), now: at(1))
            let out = m.receive(state, now: at(2))
            XCTAssertEqual(out.events, [.unavailable(.notIdle)])
            XCTAssertEqual(out.messages, [], "no 02, and nothing sent to someone else's workout")
            XCTAssertEqual(m.end(activeSeconds: 10, now: at(10)).messages, [])
        }
    }

    func testNoFramesWithinFifteenSecondsEndsItAtOnceWithPauseThenEnd() {
        var sent: [[UInt8]] = []
        var events: [Machine.Event] = []
        var m = started(sent: &sent, events: &events)
        _ = m.receive(ok03, now: at(1))
        m.noteActiveSeconds(15)
        XCTAssertEqual(m.tick(now: at(15.5)).events, [], "15 s from 03 01 (sent at 0.6 s)")
        let out = m.tick(now: at(15.7))
        XCTAssertEqual(out.events, [.unavailable(.noFrames)])
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 0f 00 00 00"), hex("03 04 04 00 00 00 0f 00 00 00")],
                       "89c with 89j: ended at about 15 s with 03 02 + 03 04, never 03 05")
        _ = m.receive(ok03, now: at(16))
        XCTAssertEqual(m.receive(ok03, now: at(16.1)).events, [.ended, .clearMarker(startTime: start)])
        XCTAssertEqual(m.end(activeSeconds: 100, now: at(100)).messages, [], "the app's own End sends nothing more")
    }

    func testALateStartReplyIsEndedAtOnce() {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        _ = m.receive(hex("10 01 01"), now: at(1))
        _ = m.receive(idleState, now: at(1))
        XCTAssertEqual(m.tick(now: at(9.5)).events, [.unavailable(.noReply(.start))], "the marker is not cleared")
        m.noteActiveSeconds(12)
        let out = m.receive(hex("10 02 01"), now: at(12))
        XCTAssertEqual(out.messages, [hex("03 01 06 00 00 00 \(startLE) 00 00 00 00"),
                                      hex("03 02 04 00 00 00 0c 00 00 00"), hex("03 04 04 00 00 00 0c 00 00 00")])
        _ = m.receive(ok03, now: at(12.1))
        _ = m.receive(ok03, now: at(12.2))
        XCTAssertEqual(m.receive(ok03, now: at(12.3)).events, [.ended, .clearMarker(startTime: start)])
    }

    func testAnUnconfirmedEndKeepsTheMarker() {
        var sent: [[UInt8]] = []
        var events: [Machine.Event] = []
        var m = started(sent: &sent, events: &events)
        _ = m.receive(ok03, now: at(1))
        _ = m.receive(liveFrame(active: 1, hr: 100, kcal: 0, avg: 100, max: 100, swings: nil), now: at(2))
        _ = m.end(activeSeconds: 60, now: at(60))
        XCTAssertEqual(m.tick(now: at(68.5)).events, [.endUnconfirmed])

        m = started(sent: &sent, events: &events)
        _ = m.receive(ok03, now: at(1))
        _ = m.end(activeSeconds: 60, now: at(60))
        _ = m.receive(ok03, now: at(60.1))
        XCTAssertEqual(m.receive(hex("10 03 02"), now: at(60.2)).events, [.endUnconfirmed], "a refused end clears nothing")
    }

    func testFramesForAWorkoutThisConnectionDoesNotDriveAreNotHandedOn() {
        var m = Machine()
        XCTAssertEqual(m.receive(liveFrame(active: 1, hr: 100, kcal: 1, avg: 100, max: 100, swings: 5), now: t0).events, [])
        _ = m.start(tennis, startTime: start, now: t0)
        _ = m.receive(hex("10 01 01"), now: at(1))
        _ = m.receive(runningState(1_799_990_000, sport: 0x11), now: at(1))
        XCTAssertEqual(m.receive(liveFrame(active: 1, hr: 100, kcal: 1, avg: 100, max: 100, swings: 5), now: at(2)).events, [],
                       "someone else's workout's frames are not ours")
    }

    func testAnotherStartOnTheSameConnectionAfterAFallbackRunsTheSequenceAgain() {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        _ = m.tick(now: at(9))
        XCTAssertEqual(m.start(tennis, startTime: start + 3600, now: at(3600)).messages, [hex("01")])
    }

    // MARK: 89f reconciliation at connect

    private func marker(appEnded: Bool = false, paused: Bool = false, active: UInt32 = 900) -> ZeppWorkoutModeMarker {
        ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, activeSeconds: active, strapPaused: paused, appEnded: appEnded)
    }

    func testReconnectWithTheWorkoutStillRunningInTheAppCarriesOn() {
        var m = Machine()
        let owner = Machine.Owner(startTime: start, activeSeconds: 950, paused: false)
        XCTAssertEqual(m.reconcile(marker(), owner: owner, now: t0).messages, [hex("06 00")])
        let out = m.receive(runningState(start, sport: 0x11), now: at(1))
        XCTAssertEqual(out.events, [.reconciled(.carriedOn)])
        XCTAssertEqual(out.messages, [], "the strap's pause state already matches")
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.tick(now: at(6)).messages, [hex("05")], "keep-alive re-armed")
        XCTAssertEqual(m.receive(liveFrame(active: 951, hr: 120, kcal: 90, avg: 120, max: 150, swings: 300), now: at(2)).events.count, 1)
        XCTAssertEqual(m.end(activeSeconds: 1000, now: at(50)).messages,
                       [hex("03 02 04 00 00 00 e8 03 00 00"), hex("03 04 04 00 00 00 e8 03 00 00")])
    }

    func testReconnectBringsTheStrapsPauseStateToTheApps() {
        var m = Machine()
        _ = m.reconcile(marker(paused: false), owner: Machine.Owner(startTime: start, activeSeconds: 950, paused: true), now: t0)
        let out = m.receive(runningState(start, sport: 0x11), now: at(1))
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 b6 03 00 00")], "paused while the link was down")
        XCTAssertEqual(out.events, [.reconciled(.carriedOn), .markStrapPaused(true)])
    }

    func testReconnectAfterTheAppEndedTheWorkoutEndsItWithTheRecordedActiveSeconds() {
        for (owner, appEnded) in [(nil as Machine.Owner?, true), (nil, false),
                                  (Machine.Owner(startTime: start + 7200, activeSeconds: 5, paused: false), false)] {
            var m = Machine()
            _ = m.reconcile(marker(appEnded: appEnded, active: 900), owner: owner, now: t0)
            let out = m.receive(runningState(start, sport: 0x11), now: at(1))
            XCTAssertEqual(out.events, [.reconciled(.endedForApp)])
            XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 84 03 00 00"), hex("03 04 04 00 00 00 84 03 00 00")],
                           "89f: 03 02 + 03 04 with the active seconds OpenCircuit recorded")
            _ = m.receive(ok03, now: at(1.1))
            XCTAssertEqual(m.receive(ok03, now: at(1.2)).events, [.ended, .clearMarker(startTime: start)])
        }
    }

    func testReconnectToAForeignWorkoutNeverTouchesIt() {
        for state in [runningState(start + 60, sport: 0x11), runningState(start, sport: 0x34)] {
            var m = Machine()
            _ = m.reconcile(marker(appEnded: true), owner: nil, now: t0)
            let out = m.receive(state, now: at(1))
            XCTAssertEqual(out.events, [.reconciled(.foreign), .clearMarker(startTime: start)])
            XCTAssertEqual(out.messages, [], "a workout whose start time or sport isn't ours is never touched")
            XCTAssertEqual(m.tick(now: at(30)).messages, [])
        }
    }

    func testReconnectToAnIdleStrapClearsTheMarker() {
        var m = Machine()
        _ = m.reconcile(marker(), owner: Machine.Owner(startTime: start, activeSeconds: 950, paused: false), now: t0)
        let out = m.receive(idleState, now: at(1))
        XCTAssertEqual(out.events, [.reconciled(.idle), .clearMarker(startTime: start)])
        XCTAssertEqual(out.messages, [])
        XCTAssertFalse(m.isActive, "the app's workout continues phone-side")
    }

    func testReconnectWithoutAnAnswerKeepsTheMarker() {
        var m = Machine()
        _ = m.reconcile(marker(), owner: nil, now: t0)
        XCTAssertEqual(m.tick(now: at(9)).events, [.reconciled(.noReply)])
        m = Machine()
        _ = m.reconcile(marker(), owner: nil, now: t0)
        XCTAssertEqual(m.receive(hex("10 06 01 00 05"), now: at(1)).events, [.reconciled(.noReply)])
    }

    func testAStartDuringReconciliationStaysPhoneSide() {
        var m = Machine()
        _ = m.reconcile(marker(), owner: nil, now: t0)
        let out = m.start(tennis, startTime: start + 7200, now: at(1))
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events, [.unavailable(.unavailable)])
    }
}

// MARK: - 89o: requests during the reconnect's `06 00`, and End after a lost start reply

final class WorkoutModeRound3Tests: XCTestCase {

    private let tennis = ZeppWorkoutSport.forSport(.tennis)!
    private let oursRunning = runningState(1_800_000_000, sport: 0x11)

    private func reconciling(active: UInt32 = 900, paused: Bool = false,
                             owner: Machine.Owner? = Machine.Owner(startTime: 1_800_000_000, activeSeconds: 950, paused: false)) -> Machine {
        var m = Machine()
        let marker = ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, activeSeconds: active, strapPaused: paused)
        XCTAssertEqual(m.reconcile(marker, owner: owner, now: t0).messages, [hex("06 00")])
        return m
    }

    func testAnEndDuringTheReconnectQueryEndsWithTheRecordedSecondsThenNothingMore() {
        var m = reconciling()
        XCTAssertEqual(m.end(activeSeconds: 960, now: at(0.3)), Machine.Output(), "kept for the reply, nothing sent yet")
        let out = m.receive(oursRunning, now: at(0.5))
        XCTAssertEqual(out.events, [.reconciled(.endedForApp)])
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 c0 03 00 00"), hex("03 04 04 00 00 00 c0 03 00 00")])
        _ = m.receive(ok03, now: at(0.6))
        XCTAssertEqual(m.receive(ok03, now: at(0.7)).events, [.ended, .clearMarker(startTime: start)])
        var later: [[UInt8]] = []
        for s in stride(from: 1.0, through: 600.0, by: 1.0) { later += m.tick(now: at(s)).messages }
        XCTAssertEqual(later, [], "no keep-alive for a workout that ended")
    }

    func testTheReplyIsDecidedOnTheMarkerAsItIsWhenTheReplyArrives() {
        // The app ended while 06 00 was in flight, with no session to tell: only the persisted marker knows.
        var m = reconciling()
        m.noteCurrent(marker: ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, activeSeconds: 970, appEnded: true), owner: nil)
        let out = m.receive(oursRunning, now: at(0.5))
        XCTAssertEqual(out.events, [.reconciled(.endedForApp)])
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 ca 03 00 00"), hex("03 04 04 00 00 00 ca 03 00 00")])
    }

    func testAMarkerOfAnotherStartTimeNeverReplacesTheOneBeingReconciled() {
        var m = reconciling()
        m.noteCurrent(marker: ZeppWorkoutModeMarker(startTime: start + 3600, sportCode: 0x34, appEnded: true),
                      owner: Machine.Owner(startTime: start, activeSeconds: 950, paused: false))
        XCTAssertEqual(m.receive(oursRunning, now: at(0.5)).events, [.reconciled(.carriedOn)])
    }

    func testAPauseDuringTheReconnectQueryIsAppliedAfterCarryingOn() {
        var m = reconciling()
        XCTAssertEqual(m.pause(activeSeconds: 955, now: at(0.3)), Machine.Output())
        m.noteCurrent(marker: nil, owner: Machine.Owner(startTime: start, activeSeconds: 955, paused: true))
        let out = m.receive(oursRunning, now: at(0.5))
        XCTAssertEqual(out.events, [.reconciled(.carriedOn), .markStrapPaused(true)])
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 bb 03 00 00")])
        XCTAssertEqual(m.tick(now: at(5.5)).messages, [hex("05")], "carried on")
    }

    func testAResumeDuringTheReconnectQueryIsAppliedAfterCarryingOn() {
        var m = reconciling(paused: true, owner: Machine.Owner(startTime: start, activeSeconds: 950, paused: true))
        XCTAssertEqual(m.resume(activeSeconds: 950, now: at(0.3)), Machine.Output())
        m.noteCurrent(marker: nil, owner: Machine.Owner(startTime: start, activeSeconds: 950, paused: false))
        let out = m.receive(oursRunning, now: at(0.5))
        XCTAssertEqual(out.events, [.reconciled(.carriedOn), .markStrapPaused(false)])
        XCTAssertEqual(out.messages, [hex("03 03 04 00 00 00 b6 03 00 00")])
    }

    func testAPauseThenResumeDuringTheQueryGoOutInOrder() {
        var m = reconciling()
        _ = m.pause(activeSeconds: 955, now: at(0.2))
        _ = m.resume(activeSeconds: 955, now: at(0.4))
        let out = m.receive(oursRunning, now: at(0.5))
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 bb 03 00 00"), hex("03 03 04 00 00 00 bb 03 00 00")])
    }

    func testAnEndDuringTheQueryWithAForeignReplyTouchesNothing() {
        var m = reconciling()
        _ = m.end(activeSeconds: 960, now: at(0.3))
        let out = m.receive(runningState(start + 60, sport: 0x11), now: at(0.5))
        XCTAssertEqual(out.messages, [], "89f unchanged: a workout that isn't ours is never touched")
        XCTAssertEqual(out.events, [.reconciled(.foreign), .clearMarker(startTime: start)])
        XCTAssertEqual(m.tick(now: at(30)).messages, [])
    }

    /// A machine whose `02` went unanswered.
    private func startTimedOut() -> Machine {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: t0)
        _ = m.receive(hex("10 01 01"), now: at(1))
        _ = m.receive(idleState, now: at(1))
        XCTAssertEqual(m.tick(now: at(9.5)).events, [.unavailable(.noReply(.start))])
        return m
    }

    func testAFrameAfterALostStartReplyMeansTheStrapStartedOurs() {
        var m = startTimedOut()
        let out = m.receive(liveFrame(active: 12, hr: 120, kcal: 2, avg: 118, max: 125, swings: 4), now: at(12))
        XCTAssertEqual(out.events.first, .setMarker(ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11)))
        XCTAssertEqual(out.events.dropFirst().first, .running)
        XCTAssertEqual(out.events.count, 3, "and the frame itself")
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.tick(now: at(17)).messages, [hex("05")])
        XCTAssertEqual(m.end(activeSeconds: 60, now: at(60)).messages,
                       [hex("03 02 04 00 00 00 3c 00 00 00"), hex("03 04 04 00 00 00 3c 00 00 00")])
    }

    func testEndAfterALostStartReplyEndsTheStrapsWorkoutOnlyIfItIsOurs() {
        var m = startTimedOut()
        XCTAssertEqual(m.end(activeSeconds: 40, now: at(40)).messages, [hex("06 00")])
        var out = m.receive(oursRunning, now: at(40.5))
        XCTAssertEqual(out.messages, [hex("03 02 04 00 00 00 28 00 00 00"), hex("03 04 04 00 00 00 28 00 00 00")])

        m = startTimedOut()
        _ = m.end(activeSeconds: 40, now: at(40))
        out = m.receive(idleState, now: at(40.5))
        XCTAssertEqual(out.messages, [])
        XCTAssertEqual(out.events, [.reconciled(.idle), .clearMarker(startTime: start)])

        m = startTimedOut()
        _ = m.end(activeSeconds: 40, now: at(40))
        out = m.receive(runningState(start - 600, sport: 0x11), now: at(40.5))
        XCTAssertEqual(out.messages, [], "not ours: never touched")
        XCTAssertEqual(out.events, [.reconciled(.foreign), .clearMarker(startTime: start)])
    }
}

// MARK: - Heart Rate Broadcast (89g)

final class HeartRateBroadcastSettingTests: XCTestCase {

    private let caps = ZeppConfigCapabilities(serviceVersion: 3, groups: [0x00, 0x0b, 0x08, 0x09, 0x0a])

    private func readEditor(broadcast: Bool?) throws -> ZeppSettingsEditor {
        var e = ZeppSettingsEditor(capabilities: ControlsFixtures.strapCapabilities(), configCapabilities: caps)
        _ = try e.read(groups: [0x08], now: t0)
        // Only the broadcast entry (and a stress switch): the rest aren't needed here.
        var entries: [UInt8] = [0x13, 0x0b, 0x01]
        var count: UInt8 = 1
        if let broadcast { entries += [0x83, 0x0b, broadcast ? 0x01 : 0x00]; count += 1 }
        _ = e.receive([0x04, 0x01, 0x08, 0x03, 0x01, count] + entries, now: t0)
        return e
    }

    func testTheArgAndItsSpecReadAndWrite() {
        XCTAssertEqual(ZeppConfig.HealthArgument.heartRateBroadcast, 0x83)
        XCTAssertEqual(ZeppSetting.heartRateBroadcast.group, 0x08)
        XCTAssertEqual(ZeppSetting.heartRateBroadcast.argument, 0x83)
        XCTAssertTrue(ZeppSetting.heartRateBroadcast.isSwitch)
        XCTAssertNil(ZeppSetting.heartRateBroadcast.requirement)
        XCTAssertTrue(ZeppSettingsEditor.groupArguments(0x08).contains(0x83), "read with the HEALTH group's read")
        XCTAssertEqual(ZeppSettingsEditor.familyRequest(.heartRateBroadcast), hex("03 01 08 01 83"))
        // Zepp's read reply (no constraints, trailing bytes) parses to the bool (§18.9).
        let reply = ZeppConfig.parseReadReply(hex("04 01 08 03 00 01 83 0b 01 00 00"))
        XCTAssertEqual(reply?.entries, [ZeppConfigEntry(argument: 0x83, value: .bool(true))])
    }

    func testReadShowsItAndHidesItWhenAbsent() throws {
        XCTAssertEqual(try readEditor(broadcast: true).snapshot.isOn(.heartRateBroadcast), true)
        XCTAssertEqual(try readEditor(broadcast: false).snapshot.availability(.heartRateBroadcast), .available)
        let absent = try readEditor(broadcast: nil)
        XCTAssertEqual(absent.snapshot.availability(.heartRateBroadcast), .notReported, "hidden when the strap doesn't report it")
        var e = absent
        XCTAssertThrowsError(try e.change(.init(setting: .heartRateBroadcast, from: .bool(false), to: .bool(true)), now: t0))
    }

    func testTurningItOnAndOffWritesTheSpecBytesThenReReads() throws {
        for (from, to, write) in [(false, true, "05 08 03 00 01 83 0b 01"), (true, false, "05 08 03 00 01 83 0b 00")] {
            var e = try readEditor(broadcast: from)
            let change = ZeppSettingsEditor.Change(setting: .heartRateBroadcast, from: .bool(from), to: .bool(to))
            XCTAssertEqual(try e.change(change, now: t0).messages.map(\.payload), [hex("03 01 08 01 83")])
            let pre = hex("04 01 08 03 01 01 83 0b") + [from ? 0x01 : 0x00]
            XCTAssertEqual(e.receive(pre, now: t0).messages.map(\.payload), [hex(write)])
            let ack = e.receive(hex("06 01"), now: t0)
            XCTAssertEqual(ack.messages.map(\.payload), [hex("03 01 08 01 83")], "re-read after the write")
            let reread = e.receive(hex("04 01 08 03 01 01 83 0b") + [to ? 0x01 : 0x00], now: t0)
            guard case .writeChecked(let check)? = reread.events.first else { return XCTFail("\(reread.events)") }
            XCTAssertTrue(check.tookChange)
            XCTAssertEqual(e.snapshot.isOn(.heartRateBroadcast), to)
        }
    }

    func testANonOkAckRevertsToTheStrapsValue() throws {
        var e = try readEditor(broadcast: false)
        let change = ZeppSettingsEditor.Change(setting: .heartRateBroadcast, from: .bool(false), to: .bool(true))
        _ = try e.change(change, now: t0)
        _ = e.receive(hex("04 01 08 03 01 01 83 0b 00"), now: t0)
        let refused = e.receive(hex("06 02"), now: t0)
        XCTAssertEqual(refused.events, [.writeNotAcknowledged(change, .status(0x02))])
        XCTAssertEqual(refused.messages.map(\.payload), [hex("03 01 08 01 83")])
        let reread = e.receive(hex("04 01 08 03 01 01 83 0b 00"), now: t0)
        guard case .writeChecked(let check)? = reread.events.first else { return XCTFail("\(reread.events)") }
        XCTAssertFalse(check.tookChange)
        XCTAssertEqual(e.snapshot.isOn(.heartRateBroadcast), false, "the switch shows the strap's value again")
    }

    func testNothingCallsHealth05HeartRatePush() {
        let reply = ZeppConfigReadReply(group: 0x08, groupVersion: 3,
                                        entries: [ZeppConfigEntry(argument: 0x05, value: .bool(false))], isPartial: false)
        let warning = ZeppHealthSettings(reply).warnings.joined()
        XCTAssertFalse(warning.contains("Heart Rate Push"))
        XCTAssertTrue(warning.contains("not Heart Rate Broadcast"))
    }
}
