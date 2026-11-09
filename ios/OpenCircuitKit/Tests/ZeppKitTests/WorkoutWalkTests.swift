// The walk over the strap's workout records (§22.1, decision 91a), against the simulated strap: exact
// start bytes with seconds, 03 09 on every round, the +1 s walk, the zero-length end, the 40-record
// cap, and a failed round delivering nothing. Synthetic records only (`WorkoutFixture`).

import XCTest
import OpenCircuitKit
import ZeppKitTesting
@testable import ZeppKit

/// One synthetic strap record: a summary and a 1 Hz detail track over its window plus a minute either side.
func strapWorkoutRecord(start: UInt32, duration: UInt32 = 1500, sport: UInt64 = 0xdf, kcal: UInt64 = 150,
                        bpm: UInt8 = 120, detail: Bool = true) -> FakeZeppDevice.WorkoutRecord {
    let s = UInt64(start)
    return FakeZeppDevice.WorkoutRecord(
        start: start,
        summary: WorkoutFixture.summary(start: s, duration: UInt64(duration), kcal: kcal, sport: sport),
        detail: detail ? WorkoutFixture.track(fromS: s - 60, toS: s + UInt64(duration) + 60) { _ in bpm } : nil)
}

struct WalkRun {
    var records: [ZeppWorkoutRecord] = []
    var failures: [(type: ZeppWorkoutFetchType, failure: ZeppWorkoutWalk.Failure, start: Date?)] = []
    var end: ZeppWorkoutWalk.End?
    var controls: [[UInt8]] = []
}

/// Runs `walk` against `device` until it finishes, storing each record with `store`.
func runWalk(_ walk: inout ZeppWorkoutWalk, _ device: FakeZeppDevice,
             store: (ZeppWorkoutRecord) -> Bool = { _ in true }) -> WalkRun {
    var run = WalkRun()
    var queue = walk.start()
    var steps = 0
    while !queue.isEmpty, steps < 100_000 {
        steps += 1
        let action = queue.removeFirst()
        switch action {
        case .sendControl(let bytes):
            run.controls.append(bytes)
            for n in device.phoneWrote(ZeppWrite(.activityControl, bytes)) {
                switch n.characteristic {
                case .activityControl: queue += walk.receiveControl(n.bytes)
                case .activityData: queue += walk.receiveData(n.bytes)
                default: break
                }
            }
        case .recordReady(let id, let record):
            run.records.append(record)
            queue += walk.commit(recordID: id, stored: store(record))
        case .roundFailed(let type, let failure, let start):
            run.failures.append((type, failure, start))
        case .finished(let end):
            run.end = end
        }
    }
    return run
}

final class WorkoutWalkTests: XCTestCase {

    private func strap() -> FakeZeppDevice {
        let device = FakeZeppDevice(authKey: [UInt8](repeating: 0, count: 16), privateKey: SpecC.strapDrawnPrivate,
                                    random: SpecC.strapRandom)
        device.startReplyTrailingZero = true   // the Helio's 16-byte form (§6.2)
        return device
    }

    /// 2026-09-21T14:13:20Z, then an hour and two hours later.
    private let starts: [UInt32] = [1_790_000_000, 1_790_003_600, 1_790_007_200]
    private let now = date(1_790_020_000)

    func testThreeRecordsWalkInOrderWithTheExactStartBytes() throws {
        let device = strap()
        device.workoutRecords = starts.map { strapWorkoutRecord(start: $0) }
        // Since 2026-09-21 14:00:00 UTC.
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device)

        XCTAssertEqual(run.records.map(\.start), starts.map { date(TimeInterval($0)) })
        XCTAssertEqual(device.fetchStarts, [
            hex("01 05 ea 07 09 15 0e 00 00 00"),   // the first since: 14:00:00
            hex("01 06 ea 07 09 15 0e 00 00 00"),   // the detail: the same since (§22.1 step 4)
            hex("01 05 ea 07 09 15 0e 0d 15 00"),   // record 1's start + 1 s: 14:13:21, seconds sent
            hex("01 06 ea 07 09 15 0e 0d 15 00"),
            hex("01 05 ea 07 09 15 0f 0d 15 00"),   // 15:13:21
            hex("01 06 ea 07 09 15 0f 0d 15 00"),
            hex("01 05 ea 07 09 15 10 0d 15 00"),   // 16:13:21: zero-length reply, the walk ends
        ])
        XCTAssertEqual(device.fetchAcks, [UInt8](repeating: 0x09, count: 7), "every round, empty or not, acked 03 09")
        XCTAssertEqual(run.end, .noMoreRecords)
        XCTAssertTrue(run.failures.isEmpty)
        let first = try XCTUnwrap(run.records.first)
        XCTAssertEqual(first.summary.durationSeconds, 1500)
        XCTAssertEqual(first.summary.kilocalories, 150)
        XCTAssertEqual(first.heartRate.count, 1500, "the minute either side of the window is trimmed")
        XCTAssertEqual(first.heartRate.first?.time, date(1_790_000_000))
        XCTAssertEqual(first.heartRate.last?.time, date(1_790_001_499))
    }

    func testTheSinceCarriesSecondsAndTheZonesQuarterHourOffset() {
        let plus2 = TimeZone(secondsFromGMT: 7200)!
        // 1790000001 = 16:13:21 at UTC+2.
        XCTAssertEqual(ZeppWorkoutWalk.startCommand(.summary, since: date(1_790_000_001), timeZone: plus2),
                       hex("01 05 ea 07 09 15 10 0d 15 08"))
        XCTAssertEqual(ZeppWorkoutWalk.startCommand(.detail, since: date(1_790_000_059), timeZone: plus2),
                       hex("01 06 ea 07 09 15 10 0e 13 08"))
        // The history fetch's own start stays minute precision (§6.2), unchanged.
        XCTAssertEqual(ZeppFetchCommand.start(.hrv, since: date(1_790_000_059), timeZone: plus2),
                       hex("01 49 ea 07 09 15 10 0e 00 08"))

        let device = strap()
        device.workoutRecords = [strapWorkoutRecord(start: starts[0])]
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: plus2))
        let run = runWalk(&walk, device)
        XCTAssertEqual(run.records.map(\.start), [date(1_790_000_000)], "the strap decoded the same instants")
        XCTAssertEqual(device.fetchStarts.last, hex("01 05 ea 07 09 15 10 0d 15 08"))
    }

    func testACRCMismatchOnADetailDeliversNothingForThatRecordAndTheWalkGoesOn() throws {
        let device = strap()
        device.workoutRecords = starts.map { strapWorkoutRecord(start: $0) }
        device.corruptWorkoutRounds = [.init(type: 0x06, start: starts[1])]
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device)

        XCTAssertEqual(run.records.map(\.start), [date(1_790_000_000), date(1_790_007_200)])
        XCTAssertEqual(run.failures.count, 1)
        let failure = try XCTUnwrap(run.failures.first)
        XCTAssertEqual(failure.type, .detail)
        XCTAssertEqual(failure.start, date(1_790_003_600))
        guard case .round(.crcMismatch) = failure.failure else { return XCTFail("\(failure.failure)") }
        XCTAssertEqual(Set(device.fetchAcks), [0x09], "the bad round is kept on the strap")
        XCTAssertEqual(device.fetchAcks.count, device.fetchStarts.count)
    }

    func testACRCMismatchOnASummaryNeverAsksForItsDetail() {
        let device = strap()
        device.workoutRecords = [strapWorkoutRecord(start: starts[0])]
        device.corruptWorkoutRounds = [.init(type: 0x05, start: starts[0])]
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device)
        XCTAssertTrue(run.records.isEmpty)
        XCTAssertEqual(device.fetchStarts.map { $0[1] }, [0x05, 0x05])
        XCTAssertEqual(device.workoutRoundsServed, [.init(type: 0x05, start: starts[0])])
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    func testARoundWithoutACRCIsNotTrusted() {
        let device = strap()
        device.includeCRC = false
        device.workoutRecords = [strapWorkoutRecord(start: starts[0])]
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device)
        XCTAssertTrue(run.records.isEmpty)
        XCTAssertEqual(run.failures.first?.failure, .noCRC)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    func testTheCapStopsTheWalkAtFortyRecords() {
        let device = strap()
        device.workoutRecords = (0..<45).map { strapWorkoutRecord(start: 1_790_000_000 + UInt32($0) * 1800, duration: 900) }
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: date(1_790_200_000), configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device)
        XCTAssertEqual(run.records.count, 40)
        XCTAssertEqual(run.end, .cap)
        XCTAssertEqual(device.fetchStarts.filter { $0[1] == 0x05 }.count, 40, "no 41st summary is asked for")
        XCTAssertEqual(device.fetchStarts.filter { $0[1] == 0x06 }.count, 40)
        XCTAssertEqual(walk.passes, 40)
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    func testAZeroLengthSummaryEndsTheWalkAtOnce() {
        let device = strap()
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device)
        XCTAssertEqual(device.fetchStarts.count, 1)
        XCTAssertEqual(device.fetchAcks, [0x09])
        XCTAssertEqual(run.end, .noMoreRecords)
    }

    func testASummaryWithoutADetailFailsItsRecordAndTheWalkGoesOn() {
        let device = strap()
        device.workoutRecords = [strapWorkoutRecord(start: starts[0], detail: false), strapWorkoutRecord(start: starts[1])]
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device)
        XCTAssertEqual(run.records.map(\.start), [date(1_790_003_600)])
        XCTAssertEqual(run.failures.map(\.failure), [.emptyDetail])
        XCTAssertEqual(Set(device.fetchAcks), [0x09])
    }

    func testARefusedSummaryEndsTheWalkWithoutAnAck() {
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        XCTAssertEqual(walk.start(), [.sendControl(hex("01 05 ea 07 09 15 0e 00 00 00"))])
        let out = walk.receiveControl(hex("10 01 04"))
        XCTAssertEqual(out.last, .finished(.refused))
        XCTAssertFalse(out.contains { if case .sendControl = $0 { return true } else { return false } })
    }

    func testADetailNamingAnotherRecordFailsThePair() {
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        _ = walk.start()
        let summary = WorkoutFixture.summary(start: 1_790_000_000, duration: 1500)
        let stamp = hex("ea 07 09 15 0e 0d 14 00")            // 14:13:20
        XCTAssertEqual(walk.receiveControl([0x10, 0x01, 0x01] + le32(UInt32(summary.count)) + stamp + [0]), [.sendControl([0x02])])
        _ = walk.receiveData([0x00] + summary)
        XCTAssertEqual(walk.receiveControl([0x10, 0x02, 0x01] + le32(ZeppCRC32.checksum(summary))), [.sendControl([0x03, 0x09])])
        XCTAssertEqual(walk.receiveControl(hex("10 03 01")), [.sendControl(hex("01 06 ea 07 09 15 0e 00 00 00"))])
        let other = hex("ea 07 09 15 0f 0d 14 00")            // 15:13:20: not this record's
        let out = walk.receiveControl([0x10, 0x01, 0x01, 0x10, 0, 0, 0] + other + [0])
        XCTAssertEqual(out, [.roundFailed(type: .detail, failure: .detailStartMismatch(summary: date(1_790_000_000), detail: date(1_790_003_600)),
                                          recordStart: date(1_790_000_000)),
                             .sendControl([0x03, 0x09])])
    }

    func testAStoreFailureEndsTheWalkAfterItsKeepAck() {
        let device = strap()
        device.workoutRecords = starts.map { strapWorkoutRecord(start: $0) }
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        let run = runWalk(&walk, device) { _ in false }
        XCTAssertEqual(run.records.count, 1)
        XCTAssertEqual(run.end, .storeFailed)
        XCTAssertEqual(device.fetchAcks, [0x09, 0x09])
    }

    func testAnAbortMidRoundAcksKeepOnceAndAnAckedRoundGetsNoSecondAck() {
        var walk = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        _ = walk.start()
        _ = walk.receiveControl([0x10, 0x01, 0x01, 0x20, 0, 0, 0] + hex("ea 07 09 15 0e 0d 14 00 00"))
        XCTAssertEqual(walk.phase, .receivingData)
        XCTAssertEqual(walk.abort(), [.roundFailed(type: .summary, failure: .round(.aborted), recordStart: date(1_790_000_000)),
                                      .sendControl([0x03, 0x09])])
        XCTAssertEqual(walk.abort(), [])

        var acked = ZeppWorkoutWalk(since: date(1_789_999_200), now: now, configuration: .init(timeZone: utc))
        _ = acked.start()
        _ = acked.receiveControl([0x10, 0x01, 0x01, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 9))
        XCTAssertEqual(acked.phase, .awaitingAckReply)
        XCTAssertEqual(acked.abort(), [], "its 03 09 already went out")
    }

    func testNoPassAsksForASinceAfterNow() {
        var walk = ZeppWorkoutWalk(since: date(1_790_000_000), now: date(1_789_999_000), configuration: .init(timeZone: utc))
        XCTAssertEqual(walk.start(), [.finished(.reachedNow)])
    }

    /// A strap that answers honestly, with mutations at random (CRC flips, missing details, lost and
    /// extra bytes, refusals, noise): whatever happens, every ack is `03 09` and nothing traps.
    func testEveryAckIsKeepWhateverTheStrapDoes() {
        var g = TestBytes(seed: 0x0226_0091)
        var acks = 0, delivered = 0, failed = 0
        for _ in 0..<1_500 {
            let device = strap()
            let n = g.int(0...6)
            device.workoutRecords = (0..<n).map { i in
                strapWorkoutRecord(start: 1_790_000_000 + UInt32(i * 3600), duration: UInt32(g.int(60...3000)),
                                   detail: g.int(0...5) != 0)
            }
            for record in device.workoutRecords where g.int(0...3) == 0 {
                device.corruptWorkoutRounds.insert(.init(type: g.int(0...1) == 0 ? 0x05 : 0x06, start: record.start))
            }
            device.includeCRC = g.int(0...9) != 0
            device.dataPacketLength = g.int(2...244)
            var walk = ZeppWorkoutWalk(since: date(TimeInterval(1_790_000_000 - g.int(0...7200))), now: now,
                                       configuration: .init(maxRecords: g.int(1...40), timeZone: utc))
            var queue = walk.start()
            var steps = 0
            while !queue.isEmpty, steps < 20_000 {
                steps += 1
                if g.int(0...49) == 0 { queue += walk.receiveControl(g.bytes(g.int(0...18))) }
                if g.int(0...49) == 0 { queue += walk.receiveData(g.bytes(g.int(0...30))) }
                if g.int(0...399) == 0 { queue += walk.abort() }
                switch queue.removeFirst() {
                case .sendControl(let bytes):
                    if bytes.first == 0x03 {
                        XCTAssertEqual(bytes, [0x03, 0x09])
                        acks += 1
                    }
                    for note in device.phoneWrote(ZeppWrite(.activityControl, bytes)) {
                        var packet = note.bytes
                        if note.characteristic == .activityData, g.int(0...59) == 0 { packet.append(0xEE) }
                        if note.characteristic == .activityData, g.int(0...59) == 0 { continue }
                        queue += note.characteristic == .activityControl ? walk.receiveControl(packet) : walk.receiveData(packet)
                    }
                case .recordReady(let id, _):
                    delivered += 1
                    queue += walk.commit(recordID: id, stored: g.int(0...9) != 0)
                case .roundFailed:
                    failed += 1
                case .finished:
                    break
                }
            }
            XCTAssertTrue(device.fetchAcks.allSatisfy { $0 == 0x09 })
        }
        XCTAssertGreaterThan(acks, 3_000)
        XCTAssertGreaterThan(delivered, 200)
        XCTAssertGreaterThan(failed, 300)
    }
}
