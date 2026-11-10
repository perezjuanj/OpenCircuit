// `ZeppWorkoutWalk.stop()` (decision 91h): a BGTask run adopted the sync, the link stays up. Whatever
// the walk was waiting for, no round is asked for after the stop, every round the strap opened is
// acked `03 09`, and the walk ends with `.finished(.stopped)`. Synthetic records only.

import XCTest
import OpenCircuitKit
import ZeppKitTesting
@testable import ZeppKit

final class WorkoutWalkStopTests: XCTestCase {

    private let now = date(1_790_020_000)
    private let summary = WorkoutFixture.summary(start: 1_790_000_000, duration: 1500)
    private let stamp = hex("ea 07 09 15 0e 0d 14 00")   // 14:13:20 UTC

    private func walk() -> ZeppWorkoutWalk {
        ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
    }

    private func controls(_ actions: [ZeppWorkoutWalk.Action]) -> [[UInt8]] {
        actions.compactMap { if case .sendControl(let b) = $0 { return b } else { return nil } }
    }

    func testAStopWhileAStartReplyIsDueAcksThatRoundAndAsksForNothingMore() {
        var w = walk()
        XCTAssertEqual(controls(w.start()), [hex("01 05 ea 07 09 15 0e 00 00 00")])
        XCTAssertEqual(w.stop(), [], "nothing to ack before the strap answers")
        // The strap opens the round it was asked for: kept on the strap, no `02`.
        XCTAssertEqual(w.receiveControl([0x10, 0x01, 0x01] + le32(UInt32(summary.count)) + stamp + [0]),
                       [.sendControl([0x03, 0x09])])
        XCTAssertEqual(w.receiveControl(hex("10 03 01")), [.finished(.stopped)])
        XCTAssertEqual(w.phase, .finished)
    }

    func testAStopWhileAStartReplyIsDueEndsAtARefusal() {
        var w = walk()
        _ = w.start()
        _ = w.stop()
        XCTAssertEqual(w.receiveControl(hex("10 01 04")), [.finished(.stopped)])
    }

    func testAStopMidTransferAcksKeepAndEndsAfterTheAckReply() {
        var w = walk()
        _ = w.start()
        _ = w.receiveControl([0x10, 0x01, 0x01] + le32(UInt32(summary.count)) + stamp + [0])
        _ = w.receiveData([0x00] + Array(summary.prefix(10)))
        XCTAssertEqual(w.stop(), [.roundFailed(type: .summary, failure: .round(.aborted), recordStart: date(1_790_000_000)),
                                  .sendControl([0x03, 0x09])])
        XCTAssertEqual(w.receiveData([0x01] + Array(summary.dropFirst(10))), [], "no data is taken after the stop")
        XCTAssertEqual(w.receiveControl(hex("10 03 01")), [.finished(.stopped)])
    }

    func testAStopAfterAnAckWaitsForItsReplyAndAsksForNoDetail() {
        var w = walk()
        _ = w.start()
        _ = w.receiveControl([0x10, 0x01, 0x01] + le32(UInt32(summary.count)) + stamp + [0])
        _ = w.receiveData([0x00] + summary)
        XCTAssertEqual(w.receiveControl([0x10, 0x02, 0x01] + le32(ZeppCRC32.checksum(summary))), [.sendControl([0x03, 0x09])])
        XCTAssertEqual(w.stop(), [])
        XCTAssertEqual(w.receiveControl(hex("10 03 01")), [.finished(.stopped)], "no 01 06 after the stop")
    }

    func testAStopBeforeTheStartOrAfterTheEndFinishesAtOnce() {
        var idle = walk()
        XCTAssertEqual(idle.stop(), [.finished(.stopped)])
        XCTAssertEqual(idle.start(), [])
    }

    func testAStopAtAnyStepAgainstTheStrapNeverAsksForAnotherRoundAndAcksEveryOpenOne() {
        // Every step of a three-record walk: stop there, then let the strap answer what is outstanding.
        let records = [1_790_000_000, 1_790_003_600, 1_790_007_200].map { strapWorkoutRecord(start: UInt32($0)) }
        var probed = 0
        for stopAt in 0..<40 {
            let device = FakeZeppDevice(authKey: [UInt8](repeating: 0, count: 16), privateKey: SpecC.strapDrawnPrivate,
                                        random: SpecC.strapRandom)
            device.startReplyTrailingZero = true
            device.workoutRecords = records
            var w = walk()
            var queue: [ZeppWorkoutWalk.Action] = []
            var steps = 0, stopped = false, startsAfterStop = 0, ended: ZeppWorkoutWalk.End?
            // Every action the walk returns goes through here: once stopped, it may not ask for a round.
            func feed(_ actions: [ZeppWorkoutWalk.Action]) {
                for case .sendControl(let b) in actions where stopped && b.first == 0x01 { startsAfterStop += 1 }
                queue += actions
            }
            feed(w.start())
            while !queue.isEmpty {
                if steps == stopAt, !stopped {
                    stopped = true
                    feed(w.stop())
                }
                steps += 1
                switch queue.removeFirst() {
                case .sendControl(let bytes):
                    for n in device.phoneWrote(ZeppWrite(.activityControl, bytes)) {
                        feed(n.characteristic == .activityControl ? w.receiveControl(n.bytes) : w.receiveData(n.bytes))
                    }
                case .recordReady(let id, _):
                    feed(w.commit(recordID: id, stored: true))
                case .roundFailed:
                    break
                case .finished(let end):
                    ended = end
                }
            }
            guard stopped else { continue }
            probed += 1
            XCTAssertEqual(startsAfterStop, 0, "step \(stopAt): no round asked for after the stop")
            XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count, "step \(stopAt): every round acked")
            XCTAssertEqual(Set(device.fetchAcks), [0x09])
            XCTAssertTrue(ended == .stopped || ended == .noMoreRecords, "step \(stopAt): \(String(describing: ended))")
            XCTAssertEqual(w.phase, .finished)
        }
        XCTAssertGreaterThan(probed, 20)
    }
}
