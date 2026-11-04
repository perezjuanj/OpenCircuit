// Decision 89p (d): the strap's workout mode proved by an invariant sweep, not by single shapes. The
// machine runs against a simulated strap that behaves as §18.9 and 89p describe it: an accepted `02`
// starts the workout at the STRAP's own clock, and `03 01` then replaces the start with the phone's.
// A host stands in for `HelioSession` + the recorder: it merges markers as the session does
// (`ZeppWorkoutModeMarker.merged(over:)`), records the app's End in the persisted marker as the
// recorder does, gives the machine the current marker before every payload, and builds a new machine
// for every connection. Every combination of the parameters below runs; after End and every delivery
// (and the next connection, when a marker is left), the invariants must hold. Times are synthetic.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

private typealias Machine = ZeppWorkoutModeMachine

/// When the `02` reply reaches the phone.
private enum StartReply: CaseIterable { case onTime, late, lost }
/// When the strap's frames begin (only while it runs OUR workout).
private enum Frames: CaseIterable { case none, beforeTimeout, afterTimeout }
/// When the person taps End.
private enum EndAt: CaseIterable { case beforeTimeout, afterTimeout, afterStateQuery, duringReconnect }
/// What the strap's state is when the start times out, and so what `06 00` answers.
private enum StateReply: CaseIterable {
    /// Our `02` started the strap's workout: the reply is running, our sport, the strap's own start.
    case runningOurs
    /// Our `02` never reached the strap: idle.
    case idle
    /// Someone else's workout (another sport) began right after our idle read; our `02` was ignored.
    case foreign
    /// Our `02` started it, but the `06 00` replies of that moment are lost.
    case none
}

private struct Case: CustomStringConvertible {
    let startReply: StartReply
    let frames: Frames
    let endAt: EndAt
    let state: StateReply
    let reconnect: Bool
    var description: String { "02 \(startReply), frames \(frames), End \(endAt), 06 00 \(state), reconnect \(reconnect)" }
}

/// The strap (89p d). Times are milliseconds since our workout's start.
private struct SimStrap {
    let ourStart: UInt32
    let ourSport: UInt8
    let c: Case
    /// The strap's clock runs this far ahead of the phone's.
    let skewSeconds: UInt32 = 3
    var running: (start: UInt32, sport: UInt8, ours: Bool)?
    var ourWorkoutStarted = false
    /// `03 xx` that reached a workout that isn't ours.
    var controlsToForeign = 0
    /// `03 04` that ended our workout.
    var oursEnded = 0
    var framesFrom: Int?

    init(ourStart: UInt32, sport: UInt8, c: Case) {
        self.ourStart = ourStart
        ourSport = sport
        self.c = c
        switch c.frames {
        case .none: framesFrom = nil
        case .beforeTimeout: framesFrom = 3_500
        case .afterTimeout: framesFrom = 12_000
        }
    }

    private func phoneTime(_ ms: Int) -> UInt32 { ourStart + UInt32(ms / 1000) }

    /// One phone message arriving at `ms`; returns the replies with their arrival time at the phone.
    mutating func receive(_ p: [UInt8], at ms: Int) -> [(Int, [UInt8])] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        let soon = ms + 100
        switch p.first {
        case 0x01:
            return [(soon, [0x10, 0x01, 0x01, 0x03, 0x01, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00])]
        case 0x06:
            if c.state == .none, (8_000...20_000).contains(ms) { return [] }
            guard let running else { return [(soon, [0x10, 0x06, 0x01, 0x00, 0x00])] }
            return [(soon, [0x10, 0x06, 0x01, 0x00, 0x01] + le32(running.start) + [running.sport])]
        case 0x02:
            guard c.state == .runningOurs || c.state == .none, running == nil else { return [] }
            running = (phoneTime(ms) + skewSeconds, p[1], true)
            ourWorkoutStarted = true
            switch c.startReply {
            case .onTime: return [(soon, [0x10, 0x02, 0x01])]
            case .late: return [(max(soon, 12_000), [0x10, 0x02, 0x01])]
            case .lost: return []
            }
        case 0x03 where p.count >= 6:
            if let r = running, !r.ours { controlsToForeign += 1 }
            if let r = running, r.ours {
                switch p[1] {
                case 0x01 where p.count == 14:
                    running = (UInt32(p[6]) | UInt32(p[7]) << 8 | UInt32(p[8]) << 16 | UInt32(p[9]) << 24, r.sport, true)
                case 0x04, 0x05:
                    oursEnded += 1
                    running = nil
                default: break
                }
            }
            return [(soon, [0x10, 0x03, 0x01])]
        default:
            return []
        }
    }

    /// A frame due at `ms` (once a second while it runs ours).
    func frame(at ms: Int) -> [UInt8]? {
        guard let from = framesFrom, ms >= from, ms % 1000 == 0, let r = running, r.ours else { return nil }
        let active = UInt32(ms / 1000)
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        return [0x14, 0x00, 0x24, 0x01, 0x00, 0x06] + le32(active) + [120] + le32(active / 10) + [118, 125]
    }
}

final class WorkoutModeSweepTests: XCTestCase {

    private let start: UInt32 = 1_800_000_000
    private let tennis = ZeppWorkoutSport.forSport(.tennis)!

    private static var cases: [Case] {
        var out: [Case] = []
        for startReply in StartReply.allCases {
            for frames in Frames.allCases {
                for endAt in EndAt.allCases {
                    for state in StateReply.allCases {
                        for reconnect in [false, true] where !(endAt == .duringReconnect && !reconnect) {
                            out.append(Case(startReply: startReply, frames: frames, endAt: endAt, state: state, reconnect: reconnect))
                        }
                    }
                }
            }
        }
        return out
    }

    /// One case, from OpenCircuit's start to quiet. Returns the failures (empty when every invariant holds).
    private func run(_ c: Case) -> [String] {
        var failures: [String] = []
        let t0 = Date(timeIntervalSince1970: TimeInterval(start))
        func date(_ ms: Int) -> Date { t0.addingTimeInterval(TimeInterval(ms) / 1000) }
        var strap = SimStrap(ourStart: start, sport: tennis.code, c: c)
        var machine = Machine()
        var persisted: ZeppWorkoutModeMarker?
        var toStrap: [(Int, [UInt8])] = []
        var toPhone: [(Int, [UInt8])] = []
        var linkUp = true
        var appEnded = false
        var endsSent = 0
        /// After End, the phone heard the strap run ours (a frame, a `10 02 01`, or a `06 00` reply while
        /// ours ran) on a live connection: from then on the End can't be left to the next connection.
        var oursSeenAfterEnd = false
        var keepAlivesAfterEnd = 0
        let endMs: Int
        switch c.endAt {
        case .beforeTimeout: endMs = 4_000
        case .afterTimeout: endMs = 8_450      // the start timeout fires at 8.4 s; its 06 00 reply lands at 8.6 s
        case .afterStateQuery: endMs = 13_000
        case .duringReconnect: endMs = 30_150  // the reconnect's 06 00 goes out at 30 s
        }
        let dropMs = 20_000, reconnectMs = 30_000, nextConnectionMs = 200_000, quietMs = 260_000

        func owner(_ ms: Int) -> Machine.Owner? {
            appEnded ? nil : Machine.Owner(startTime: start, activeSeconds: UInt32(ms / 1000), paused: false)
        }
        func apply(_ out: Machine.Output, at ms: Int) {
            for event in out.events {
                switch event {
                case .setMarker(let m): persisted = m.merged(over: persisted)
                case .markStrapPaused(let paused): persisted?.strapPaused = paused
                case .clearMarker(let s):
                    if strap.running?.ours == true {
                        failures.append("marker cleared at \(ms) ms while our workout runs on the strap")
                    }
                    if persisted?.startTime == s { persisted = nil }
                default: break
                }
            }
            for m in out.messages {
                if m.starts(with: [0x03, 0x04]) || m.starts(with: [0x03, 0x05]) { endsSent += 1 }
                if appEnded, m == [0x05] { keepAlivesAfterEnd += 1 }
                if linkUp { toStrap.append((ms + 100, m)) }
            }
        }

        apply(machine.start(tennis, startTime: start, now: date(0)), at: 0)
        var ms = 0
        while ms <= quietMs {
            // Scheduled happenings.
            if ms == endMs {
                appEnded = true
                // The recorder: the persisted marker first, then the session if the link is up.
                if var marker = persisted, marker.startTime == start {
                    marker.appEnded = true
                    marker.activeSeconds = max(marker.activeSeconds, UInt32(ms / 1000))
                    persisted = marker
                }
                if linkUp { apply(machine.end(activeSeconds: UInt32(ms / 1000), now: date(ms)), at: ms) }
            }
            if c.reconnect, ms == dropMs {
                linkUp = false
                machine.linkLost()
                toStrap.removeAll()
                toPhone.removeAll()
            }
            if ms == nextConnectionMs - 50, appEnded, strap.running?.ours == true {
                if oursSeenAfterEnd {
                    failures.append("the phone saw the strap run ours after End, and the End waited for the next connection")
                } else if c.state != .none {
                    // 89p (a), no limbo: a strap that answers `06 00` settles the start on this connection.
                    failures.append("the strap answers, yet the End waited for the next connection")
                }
            }
            if (c.reconnect && ms == reconnectMs) || (ms == nextConnectionMs && persisted != nil) {
                linkUp = true
                machine = Machine()
                if let marker = persisted { apply(machine.reconcile(marker, owner: owner(ms), now: date(ms)), at: ms) }
            }
            if c.state == .foreign, ms == 350, strap.running == nil {
                strap.running = (start, 0x34, false)   // someone else's workout, another sport
            }
            // Deliveries due now.
            let dueStrap = toStrap.filter { $0.0 == ms }
            toStrap.removeAll { $0.0 == ms }
            for (_, payload) in dueStrap where linkUp { toPhone += strap.receive(payload, at: ms) }
            if linkUp, let frame = strap.frame(at: ms) { toPhone.append((ms + 50, frame)) }
            let duePhone = toPhone.filter { $0.0 == ms }
            toPhone.removeAll { $0.0 == ms }
            for (_, payload) in duePhone where linkUp {
                if appEnded, strap.running?.ours == true,
                   payload.first == 0x14 || payload.starts(with: [0x10, 0x02, 0x01]) || payload.starts(with: [0x10, 0x06]) {
                    oursSeenAfterEnd = true
                }
                machine.noteCurrent(marker: persisted, owner: owner(ms))
                apply(machine.receive(payload, now: date(ms)), at: ms)
            }
            if linkUp, let deadline = machine.nextDeadline, date(ms) >= deadline {
                apply(machine.tick(now: date(ms)), at: ms)
            }
            ms += 50
        }

        // The invariants.
        if strap.ourWorkoutStarted, strap.running?.ours == true { failures.append("a strap workout our 02 started is still running") }
        if strap.controlsToForeign > 0 { failures.append("a foreign workout received \(strap.controlsToForeign) 03 xx") }
        if strap.oursEnded > 1 { failures.append("03 04 reached our workout \(strap.oursEnded) times") }
        if endsSent > 1 { failures.append("\(endsSent) end sequences were sent") }
        if keepAlivesAfterEnd > 0 { failures.append("\(keepAlivesAfterEnd) keep-alives after End") }
        if persisted != nil { failures.append("a marker is left after the next connection: \(String(describing: persisted))") }
        return failures
    }

    func testEveryStartTimeoutAndEndCombinationKeepsTheInvariants() {
        let cases = Self.cases
        var failed: [String] = []
        for c in cases {
            let failures = run(c)
            if !failures.isEmpty { failed.append("\(c): \(failures.joined(separator: "; "))") }
        }
        print("WORKOUT-MODE SWEEP: \(cases.count) cases run, \(failed.count) failed")
        XCTAssertEqual(cases.count, 252)
        XCTAssertEqual(failed, [], failed.prefix(20).joined(separator: "\n"))
    }

    // MARK: The pieces the sweep relies on, pinned on their own

    func testTheMarkerMergeKeepsAPersistedEndAndTheLargerSeconds() {
        let persisted = ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, activeSeconds: 40, appEnded: true)
        let fromMachine = ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, activeSeconds: 0, startUnconfirmed: true)
        let merged = fromMachine.merged(over: persisted)
        XCTAssertTrue(merged.appEnded, "an End already persisted is never overwritten")
        XCTAssertEqual(merged.activeSeconds, 40)
        XCTAssertTrue(merged.startUnconfirmed, "the flag is the machine's")
        let other = ZeppWorkoutModeMarker(startTime: start + 3600, sportCode: 0x34, appEnded: true)
        XCTAssertEqual(fromMachine.merged(over: other), fromMachine, "another workout's marker is ignored")
        XCTAssertEqual(fromMachine.merged(over: nil), fromMachine)
    }

    func testOursIsTheExactStartOrTheUnconfirmedWindow() {
        func state(_ s: UInt32, _ sport: UInt8 = 0x11) -> ZeppWorkoutState { .running(startTime: s, sport: sport) }
        let confirmed = ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11)
        XCTAssertTrue(confirmed.isOurs(state(start)))
        XCTAssertFalse(confirmed.isOurs(state(start + 3)), "a confirmed start matches exactly only")
        let unconfirmed = ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, startUnconfirmed: true)
        XCTAssertTrue(unconfirmed.isOurs(state(start - 2)))
        XCTAssertTrue(unconfirmed.isOurs(state(start + 30)))
        XCTAssertFalse(unconfirmed.isOurs(state(start - 3)))
        XCTAssertFalse(unconfirmed.isOurs(state(start + 31)))
        XCTAssertFalse(unconfirmed.isOurs(state(start + 3, 0x34)), "the sport must match")
        XCTAssertFalse(unconfirmed.isOurs(.idle))
    }

    func testTheStartTimeoutAsksTheStrapAtOnce() {
        var m = Machine()
        _ = m.start(tennis, startTime: start, now: Date(timeIntervalSince1970: TimeInterval(start)))
        _ = m.receive([0x10, 0x01, 0x01], now: Date(timeIntervalSince1970: TimeInterval(start)))
        _ = m.receive([0x10, 0x06, 0x01, 0x00, 0x00], now: Date(timeIntervalSince1970: TimeInterval(start)))
        let out = m.tick(now: Date(timeIntervalSince1970: TimeInterval(start) + 8.1))
        XCTAssertEqual(out.messages, [[0x06, 0x00]], "89p (a): no limbo")
        XCTAssertEqual(out.events, [.setMarker(ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, startUnconfirmed: true))])
    }

    func testAPersistedMarkerFromBeforeTheFlagDecodes() throws {
        let old = #"{"startTime":1800000000,"sportCode":17,"activeSeconds":60,"strapPaused":false,"appEnded":true}"#
        let marker = try JSONDecoder().decode(ZeppWorkoutModeMarker.self, from: Data(old.utf8))
        XCTAssertEqual(marker, ZeppWorkoutModeMarker(startTime: start, sportCode: 0x11, activeSeconds: 60, appEnded: true))
    }
}
