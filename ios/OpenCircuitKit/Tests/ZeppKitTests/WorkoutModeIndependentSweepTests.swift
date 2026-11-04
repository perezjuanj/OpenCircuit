// Decision 89q (d): the third review's independent invariant sweep, ported as a permanent test next to
// `WorkoutModeSweepTests`. Event-driven, with parameters that differ from that sweep: the strap's own
// clock offset for an accepted `02` (−3, −2, 0, +1, +30, +31 s), reply arrival at and around the
// deadlines, frames at the timeout tick, tick-vs-delivery order, link drop BEFORE the timeout and with
// `03 01` in flight, pause/resume around the timeout, End twice, a second workout, foreign workouts.
//
// Out-of-window offsets (−3, +31 s) can leave our workout running when nothing the phone hears can
// show it is ours: 89p (c)'s documented limit. Those cases are counted apart ("limit": the strap never
// got our `03 01`), and every other failure is hard and must be zero. The NIT of 89q (f) (a same-sport
// workout someone else started inside the window is treated as ours) is counted apart too ("inherent").
import XCTest
import OpenCircuitKit
@testable import ZeppKit

private typealias M = ZeppWorkoutModeMachine
private let S: UInt32 = 1_800_000_000
private let tennis = ZeppWorkoutSport.forSport(.tennis)!
private func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
private func rd(_ p: [UInt8], _ i: Int) -> UInt32 { UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24 }

private enum PStartReply: CaseIterable { case fast, minus1s, exactDeadline, plus1s, lost, neverReached }
private enum PStateDelay: CaseIterable { case fast, minus1s, exactDeadline, plus1s, lost }
private enum PFrames: CaseIterable { case none, before, atTick, after }
private enum PDrop: CaseIterable { case none, during02Wait, with0301InFlight, afterTick }
private enum PForeign: CaseIterable { case none, otherSport, ourSportInWindow, ourSportOutOfWindow }

private struct PCase: CustomStringConvertible {
    var offset: Int64            // the strap's own start for an accepted 02, relative to S (s)
    var startReply: PStartReply
    var stateDelay: PStateDelay
    var frames: PFrames
    var endAt: Int               // ms
    var drop: PDrop
    var tickFirst = false
    var pause = 0                // 0 none, 1 pause at 6 s, 2 pause 6 s + resume 8.35 s
    var endTwice = false
    var framesBefore0301 = true
    var second = false
    var foreign: PForeign = .none
    var description: String {
        "off \(offset) 02 \(startReply) 0600 \(stateDelay) frames \(frames)/\(framesBefore0301 ? "pre" : "post") End \(endAt)\(endTwice ? "x2" : "") drop \(drop) tickFirst \(tickFirst) pause \(pause) second \(second) foreign \(foreign)"
    }
}

private struct RunResult { var hard: [String] = []; var deferred: [String] = []; var inherent: [String] = []; var limit: [String] = [] }

/// One workout started on the strap: who started it and whether it was ever ended.
private struct StrapWorkout { var start: UInt32; var sport: UInt8; var oursKey: Int? }  // oursKey: 0 = A, 1 = B, nil foreign

private final class Sim {
    let c: PCase
    var t = 0
    var seq = 0
    var toStrap: [(Int, Int, [UInt8])] = []
    var toPhone: [(Int, Int, [UInt8])] = []
    var running: StrapWorkout?
    var foreignControls = 0
    var ends: [Int: Int] = [:]            // workout key → 03 04 that reached it
    /// `03 04` that reached the strap while nothing of ours ran there: a second end of an ended workout.
    /// (The review's probe counted end sequences SENT; one lost with a dropped link must be sent again on
    /// the next connection (89f), so this port counts what reaches the strap: see `ends` too.)
    var strayEnds = 0
    var machine = M()
    var persisted: ZeppWorkoutModeMarker?
    var linkUp = true
    var adopted0301 = false
    var r = RunResult()
    // App side.
    var appA: (start: UInt32, ended: Bool, attached: Bool, paused: Bool) = (S, false, true, false)
    var appB: (start: UInt32, ended: Bool, attached: Bool, paused: Bool)?
    var oursSeenAfterEndOnLiveLink = false
    var keepAlivesAfterEnd = 0
    var startSent02At: Int?
    var stateQueriesAfterStart = 0

    init(_ c: PCase) { self.c = c }

    func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(S)).addingTimeInterval(TimeInterval(ms) / 1000) }
    func owner() -> M.Owner? {
        if let b = appB { return b.ended ? nil : .init(startTime: b.start, activeSeconds: UInt32(t / 1000) - 60, paused: b.paused) }
        return appA.ended ? nil : .init(startTime: S, activeSeconds: UInt32(t / 1000), paused: appA.paused)
    }
    func curKey() -> Int { appB == nil ? 0 : 1 }

    func apply(_ out: M.Output) {
        for e in out.events {
            switch e {
            case .setMarker(let m):
                if let p = persisted, p.startTime != m.startTime, let w = running, let k = w.oursKey, k == (p.startTime == S ? 0 : 1) {
                    r.hard.append("marker of a running workout of ours overwritten by another start at \(t) ms")
                }
                persisted = m.merged(over: persisted)
            case .markStrapPaused(let p): if let s = machine.marker?.startTime, persisted?.startTime == s { persisted?.strapPaused = p }
            case .clearMarker(let s):
                if persisted?.startTime == s {
                    let key = s == S ? 0 : 1
                    if let w = running, w.oursKey == key {
                        let msg = "marker cleared at \(t) ms while the strap runs ours (key \(key))"
                        if outsideWindowLimit(key) { r.limit.append(msg) } else { r.hard.append(msg) }
                    }
                    persisted = nil
                }
            case .reconciled(.idle), .reconciled(.foreign):
                // The recorder detaches: its End never reaches the machine or the marker again.
                if appB != nil { appB?.attached = false } else { appA.attached = false }
            default: break
            }
        }
        for m in out.messages {
            if m == [0x05], (appB.map { $0.ended } ?? appA.ended) { keepAlivesAfterEnd += 1 }
            if m == [0x02, tennis.code] || m.first == 0x02 { startSent02At = t }
            if m == [0x06, 0x00], startSent02At != nil { stateQueriesAfterStart += 1 }
            if linkUp { seq += 1; toStrap.append((t + 50, seq, m)) }
        }
    }

    func strapReceive(_ p: [UInt8]) {
        func reply(_ d: Int, _ b: [UInt8]) { seq += 1; toPhone.append((t + d, seq, b)) }
        switch p.first {
        case 0x01: reply(100, [0x10, 0x01, 0x01, 0x03, 0x01, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00])
        case 0x06:
            let isConfirm = startSent02At != nil && appB == nil && !confirmAnswered && t < 30_000
            var d = 100
            if isConfirm {
                confirmAnswered = true
                // The confirm query goes out at the 02 deadline (8300); its own deadline is 16300.
                switch c.stateDelay {
                case .fast: d = 100
                case .minus1s: d = 16_300 - 1_000 - t
                case .exactDeadline: d = 16_300 - t
                case .plus1s: d = 16_300 + 1_000 - t
                case .lost: return
                }
            }
            if let w = running { reply(d, [0x10, 0x06, 0x01, 0x00, 0x01] + le(w.start) + [w.sport]) }
            else { reply(d, [0x10, 0x06, 0x01, 0x00, 0x00]) }
        case 0x02:
            let isA = appB == nil
            if isA, c.startReply == .neverReached { return }
            guard running == nil else { return }         // a running workout: 02 ignored, no reply
            let start = isA ? UInt32(Int64(S) + c.offset) : S + 60 + 1
            running = StrapWorkout(start: start, sport: p[1], oursKey: isA ? 0 : 1)
            adopted0301 = false
            if !isA { reply(100, [0x10, 0x02, 0x01]); return }
            let deadline = (startSent02At ?? 300) + 8_000
            switch c.startReply {
            case .fast: reply(100, [0x10, 0x02, 0x01])
            case .minus1s: reply(deadline - 1_000 - t, [0x10, 0x02, 0x01])
            case .exactDeadline: reply(deadline - t, [0x10, 0x02, 0x01])
            case .plus1s: reply(deadline + 1_000 - t, [0x10, 0x02, 0x01])
            case .lost, .neverReached: break
            }
        case 0x03 where p.count >= 6:
            guard let w = running else {
                if p[1] == 0x04 || p[1] == 0x05 { strayEnds += 1 }
                reply(100, [0x10, 0x03, 0x01]); return
            }
            if w.oursKey == nil { foreignControls += 1; reply(100, [0x10, 0x03, 0x01]); return }
            switch p[1] {
            case 0x01 where p.count == 14: running?.start = rd(p, 6); adopted0301 = true
            case 0x04, 0x05: ends[w.oursKey!, default: 0] += 1; running = nil
            default: break
            }
            reply(100, [0x10, 0x03, 0x01])
        default: break
        }
    }
    var confirmAnswered = false

    func frameDue() -> Bool {
        guard linkUp, let w = running, w.oursKey != nil else { return false }
        if !c.framesBefore0301 && !adopted0301 { return false }
        let f0: Int
        switch c.frames {
        case .none: return false
        case .before: f0 = 3_000
        case .atTick: f0 = 8_300
        case .after: f0 = 8_800
        }
        return t >= f0 && (t - f0) % 1_000 == 0
    }

    func deliverPhone(_ p: [UInt8]) {
        if (appB.map { $0.ended } ?? appA.ended), let w = running, w.oursKey == curKey(),
           p.first == 0x14 || p.starts(with: [0x10, 0x02, 0x01]) || p.starts(with: [0x10, 0x06, 0x01, 0x00, 0x01]) {
            oursSeenAfterEndOnLiveLink = true
        }
        machine.noteCurrent(marker: persisted, owner: owner())
        apply(machine.receive(p, now: date(t)))
    }

    func appEnd(seconds: UInt32) {
        if appB != nil {
            guard appB!.attached else { appB!.ended = true; return }
            appB!.ended = true
            if var m = persisted, m.startTime == appB!.start { m.appEnded = true; m.activeSeconds = seconds; persisted = m }
        } else {
            let attached = appA.attached
            appA.ended = true
            guard attached else { return }
            if var m = persisted, m.startTime == S { m.appEnded = true; m.activeSeconds = seconds; persisted = m }
        }
        if linkUp { apply(machine.end(activeSeconds: seconds, now: date(t))) }
    }

    func reconnect() {
        linkUp = true
        machine = M()
        if let m = persisted { apply(machine.reconcile(m, owner: owner(), now: date(t))) }
    }

    func run() -> RunResult {
        if c.foreign != .none {
            // Appears after our idle read (strap at 200 ms), before our 02 arrives (350 ms).
            actions.append((320, { [self] in
                switch c.foreign {
                case .otherSport: running = StrapWorkout(start: S + 1, sport: 0x34, oursKey: nil)
                case .ourSportInWindow: running = StrapWorkout(start: S + 5, sport: tennis.code, oursKey: nil)
                case .ourSportOutOfWindow: running = StrapWorkout(start: S + 40, sport: tennis.code, oursKey: nil)
                case .none: break
                }
            }))
        }
        if c.pause >= 1 { actions.append((6_000, { [self] in if !appA.ended { appA.paused = true; if linkUp { apply(machine.pause(activeSeconds: 6, now: date(t))) } } })) }
        if c.pause == 2 { actions.append((8_350, { [self] in if !appA.ended { appA.paused = false; if linkUp { apply(machine.resume(activeSeconds: 6, now: date(t))) } } })) }
        actions.append((c.endAt, { [self] in appEnd(seconds: UInt32(c.endAt / 1000)) }))
        if c.endTwice { actions.append((c.endAt + 3_000, { [self] in if linkUp { apply(machine.end(activeSeconds: UInt32(c.endAt / 1000) + 3, now: date(t))) } })) }
        switch c.drop {
        case .none: break
        case .during02Wait: actions.append((3_000, { [self] in dropLink() }))
        case .with0301InFlight: actions.append((t0301Drop, { [self] in dropLink() }))
        case .afterTick: actions.append((8_400, { [self] in dropLink() }))
        }
        if c.drop != .none { actions.append((30_000, { [self] in reconnect() })) }
        if c.second {
            actions.append((60_000, { [self] in
                appB = (S + 60, false, true, false)
                if linkUp { apply(machine.start(tennis, startTime: S + 60, now: date(t))) }
            }))
            actions.append((120_000, { [self] in appEnd(seconds: 60) }))
        }
        actions.append((nextConnection - 100, { [self] in
            // End is in, every delivery done on this connection: is ours still running?
            if let w = running, w.oursKey != nil, oursSeenAfterEndOnLiveLink, !outsideWindowLimit(w.oursKey!) {
                r.deferred.append("after End the strap ran ours (key \(w.oursKey!)), the phone heard it on a live link, and the End waited for the next connection")
            }
        }))
        actions.append((nextConnection, { [self] in
            if persisted != nil { linkUp = false; machine.linkLost(); toStrap.removeAll(); toPhone.removeAll(); reconnect() }
        }))
        apply(machine.start(tennis, startTime: S, now: date(0)))
        var guardN = 0
        while t <= endOfSim, guardN < 200_000 {
            guardN += 1
            for a in actions where a.0 == t { a.1() }
            if c.tickFirst { tickIfDue() }
            let dueS = toStrap.filter { $0.0 == t }.sorted { $0.1 < $1.1 }
            toStrap.removeAll { $0.0 == t }
            for (_, _, p) in dueS where linkUp { strapReceive(p) }
            var dueP = toPhone.filter { $0.0 == t }.sorted { $0.1 < $1.1 }.map { $0.2 }
            toPhone.removeAll { $0.0 == t }
            if frameDue() {
                let a = UInt32(t / 1000)
                dueP.append([0x14, 0x00, 0x24, 0x01, 0x00, 0x0e] + le(a) + [120] + le(a / 10) + [118, 125, 4, 0])
            }
            for p in dueP where linkUp { deliverPhone(p) }
            if !c.tickFirst { tickIfDue() }
            // Next time something happens.
            var next = endOfSim + 1
            for a in actions where a.0 > t { next = min(next, a.0) }
            for d in toStrap { next = min(next, d.0) }
            for d in toPhone { next = min(next, d.0) }
            if linkUp, let dl = machine.nextDeadline {
                let ms = Int((dl.timeIntervalSince1970 - TimeInterval(S)) * 1000)
                next = min(next, max(ms, t + 1))
            }
            if linkUp, running?.oursKey != nil, c.frames != .none {
                let f0 = c.frames == .before ? 3_000 : (c.frames == .atTick ? 8_300 : 8_800)
                next = min(next, t < f0 ? f0 : f0 + ((t - f0) / 1_000 + 1) * 1_000)
            }
            if next <= t { next = t + 1 }
            t = next
        }
        // Invariants after everything.
        if let w = running, w.oursKey != nil {
            let msg = "a strap workout our 02 started is still running at the end (key \(w.oursKey!), start \(Int64(w.start) - Int64(S)))"
            // 89p (c)'s documented limit: the strap kept its own start outside the window and never got
            // our `03 01`, so no `06 00` can show it is ours.
            if outsideWindowLimit(w.oursKey!) { r.limit.append(msg) } else { r.hard.append(msg) }
        }
        if foreignControls > 0 {
            let msg = "a foreign workout received \(foreignControls) 03 xx"
            if c.foreign == .ourSportInWindow { r.inherent.append(msg) } else { r.hard.append(msg) }
        }
        for (k, n) in ends where n > 1 { r.hard.append("03 04 reached workout \(k) \(n) times") }
        if strayEnds > 0 { r.hard.append("\(strayEnds) end(s) reached a strap with nothing of ours running") }
        if keepAlivesAfterEnd > 0 { r.hard.append("\(keepAlivesAfterEnd) keep-alives after End") }
        return r
    }
    var actions: [(Int, () -> Void)] = []
    let nextConnection = 600_000, endOfSim = 700_000
    var t0301Drop: Int {
        // The 03 01 goes out when the 02 reply lands; drop 20 ms later (before its 50 ms flight ends).
        switch c.startReply {
        case .fast: return 300 + 50 + 100 + 20
        case .minus1s: return 8_300 - 1_000 + 20
        case .exactDeadline: return 8_300 + 20
        case .plus1s: return 8_300 + 1_000 + 20
        case .lost, .neverReached: return 3_000
        }
    }
    /// 89p (c)'s documented limit: our workout `key` 0 kept the strap's own start outside the window
    /// and never got our `03 01`, so no `06 00` can show it is ours.
    func outsideWindowLimit(_ key: Int) -> Bool {
        key == 0 && !ZeppWorkoutModeMarker.unconfirmedStartWindow.contains(c.offset) && !adopted0301
    }
    func dropLink() { linkUp = false; machine.linkLost(); toStrap.removeAll(); toPhone.removeAll() }
    func tickIfDue() {
        guard linkUp, let dl = machine.nextDeadline, date(t) >= dl else { return }
        apply(machine.tick(now: date(t)))
    }
}

final class WorkoutModeIndependentSweepTests: XCTestCase {
    private func run(_ cases: [PCase], label: String) -> (Int, [String], [String], [String], [String]) {
        var hard: [String] = [], deferred: [String] = [], inherent: [String] = [], limit: [String] = []
        for c in cases {
            let r = Sim(c).run()
            if !r.hard.isEmpty { hard.append("\(c): \(r.hard.joined(separator: "; "))") }
            if !r.deferred.isEmpty { deferred.append("\(c): \(r.deferred.joined(separator: "; "))") }
            if !r.inherent.isEmpty { inherent.append("\(c): \(r.inherent.joined(separator: "; "))") }
            if !r.limit.isEmpty { limit.append("\(c): \(r.limit.joined(separator: "; "))") }
        }
        print("INDEPENDENT SWEEP \(label): \(cases.count) cases, \(hard.count) hard failures, \(deferred.count) deferred-with-answer, \(inherent.count) inherent (89q f), \(limit.count) out-of-window limit (89p c)")
        for line in hard.prefix(25) { print("  HARD \(line)") }
        for line in deferred.prefix(10) { print("  DEFERRED \(line)") }
        return (cases.count, hard, deferred, inherent, limit)
    }

    func testCoreSweep() {
        var cases: [PCase] = []
        var i = 0
        for offset: Int64 in [-3, -2, 0, 1, 30, 31] {
            for sr in PStartReply.allCases {
                for sd in PStateDelay.allCases {
                    for fr in PFrames.allCases {
                        for endAt in [4_000, 8_300, 8_500, 20_000] {
                            for drop in PDrop.allCases {
                                // Secondary parameters spread deterministically over the core product.
                                var c = PCase(offset: offset, startReply: sr, stateDelay: sd, frames: fr, endAt: endAt, drop: drop)
                                c.tickFirst = i % 2 == 0
                                c.pause = (i / 2) % 3
                                c.endTwice = (i / 6) % 2 == 1
                                c.framesBefore0301 = (i / 12) % 2 == 0
                                c.second = (i / 24) % 3 == 1
                                cases.append(c)
                                i += 1
                            }
                        }
                    }
                }
            }
        }
        let (count, hard, deferred, _, limit) = run(cases, label: "core")
        XCTAssertEqual(count, 11_520)
        XCTAssertEqual(hard, [], hard.prefix(10).joined(separator: "\n"))
        XCTAssertEqual(deferred, [], deferred.prefix(10).joined(separator: "\n"))
        let window = ZeppWorkoutModeMarker.unconfirmedStartWindow
        XCTAssertTrue(cases.filter { window.contains($0.offset) }.allSatisfy { Sim($0).run().limit.isEmpty },
                      "inside the window nothing is left to the limit")
        XCTAssertEqual(limit.count, 1_680, "the documented limit, pinned: 840 cases each at −3 s and +31 s")
        print("INDEPENDENT SWEEP core by offset: " + [-3, -2, 0, 1, 30, 31].map { (o: Int64) in
            "\(o): \(limit.filter { $0.hasPrefix("off \(o) ") }.count) limit" }.joined(separator: ", "))
    }

    func testForeignSweep() {
        var cases: [PCase] = []
        for f in [PForeign.otherSport, .ourSportInWindow, .ourSportOutOfWindow] {
            for sd in PStateDelay.allCases {
                for endAt in [4_000, 8_300, 8_500, 20_000] {
                    for drop in [PDrop.none, .during02Wait, .afterTick] {
                        for tickFirst in [false, true] {
                            var c = PCase(offset: 1, startReply: .lost, stateDelay: sd, frames: .none, endAt: endAt, drop: drop)
                            c.foreign = f; c.tickFirst = tickFirst
                            cases.append(c)
                        }
                    }
                }
            }
        }
        let (count, hard, deferred, _, limit) = run(cases, label: "foreign")
        XCTAssertEqual(count, 360)
        XCTAssertEqual(hard, [], hard.prefix(10).joined(separator: "\n"))
        XCTAssertEqual(deferred, [], deferred.prefix(10).joined(separator: "\n"))
        XCTAssertEqual(limit, [], "offset +1 s is inside the window")
    }

    /// B4, directed: the link drops during the `02` wait (before the 8 s timeout). The strap accepted our
    /// `02` and started at its own clock (S + 1). 89q (a): the marker persisted before `02` is flagged,
    /// so the reconnect's `06 00` applies the window and finds ours.
    func testB4DropDuringStartWaitThenReconnect() {
        let t0 = Date(timeIntervalSince1970: TimeInterval(S))
        var m = M()
        var persisted: ZeppWorkoutModeMarker?
        func apply(_ o: M.Output) {
            for e in o.events {
                if case .setMarker(let mk) = e { persisted = mk.merged(over: persisted) }
                if case .clearMarker(let s) = e, persisted?.startTime == s { persisted = nil }
            }
        }
        apply(m.start(tennis, startTime: S, now: t0))
        apply(m.receive([0x10, 0x01, 0x01, 0x03, 0x01, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00], now: t0.addingTimeInterval(0.1)))
        let o = m.receive([0x10, 0x06, 0x01, 0x00, 0x00], now: t0.addingTimeInterval(0.2))
        apply(o)
        XCTAssertEqual(o.messages.first?.first, 0x02)
        XCTAssertEqual(persisted?.startUnconfirmed, true, "89q (a): flagged before 02 goes out")
        m.linkLost()                                             // drop at +3 s, before the timeout
        // Variant 1: the app's workout still runs at the reconnect.
        var next = M()
        let owner = M.Owner(startTime: S, activeSeconds: 30, paused: false)
        apply(next.reconcile(persisted!, owner: owner, now: t0.addingTimeInterval(30)))
        let reply = next.receive([0x10, 0x06, 0x01, 0x00, 0x01] + le(S + 1) + [tennis.code], now: t0.addingTimeInterval(30.2))
        apply(reply)
        let endOut = next.end(activeSeconds: 60, now: t0.addingTimeInterval(60))
        XCTAssertNotNil(persisted, "the marker must not be erased while the strap may still run ours")
        XCTAssertFalse(endOut.messages.isEmpty, "End must end the strap workout our 02 started")
        // Variant 2: End while the link was down (the recorder persisted appEnded), then reconnect.
        var p2 = ZeppWorkoutModeMarker(startTime: S, sportCode: tennis.code, startUnconfirmed: true)
        p2.appEnded = true; p2.activeSeconds = 10
        var m3 = M()
        _ = m3.reconcile(p2, owner: nil, now: t0.addingTimeInterval(30))
        let r3 = m3.receive([0x10, 0x06, 0x01, 0x00, 0x01] + le(S + 1) + [tennis.code], now: t0.addingTimeInterval(30.2))
        XCTAssertFalse(r3.messages.isEmpty, "an ended workout our 02 started must be ended at the reconnect")
    }
}
