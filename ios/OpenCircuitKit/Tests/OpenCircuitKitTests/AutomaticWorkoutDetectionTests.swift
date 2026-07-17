import XCTest
@testable import OpenCircuitKit

final class AutomaticWorkoutDetectionTests: XCTestCase {
    /// Real channel-0x02 frame from the 2026-07-11 official-app capture. The header countdown is
    /// 0x12 even though this page contains nine records, proving it is not a record-count byte.
    func testDecodesRealHistoricalSportPage() {
        let hex = "4d 00 12 0c 47 47 fb 57 00 03 6a c7 08 00 0c 47 48 05 59 00 02 1e c7 09 00 0c 47 48 0f 58 00 03 1d c7 06 00 0c 47 48 19 55 00 00 79 c6 04 00 0c 47 48 23 58 00 02 55 bf 04 00 0c 47 48 2d 55 00 01 07 bf 03 00 0c 47 48 37 59 00 01 c4 c7 05 00 0c 47 48 41 59 00 02 9d c7 00 00 0c 47 48 4b 58 00 02 b7 c7 00 00 b5"
        let frame = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        let samples = HistoricalSportFrame.decode(frame)

        XCTAssertEqual(samples?.count, 9)
        XCTAssertEqual(samples?.first?.cursor, 0x0c4747fb)
        XCTAssertEqual(samples?.first?.heartRate, 87)
        XCTAssertEqual(samples?.first?.steps, 0)
        XCTAssertEqual(samples?.last?.cursor, 0x0c47484b)
    }

    func testRejectsCorruptOrPartialPages() {
        XCTAssertNil(HistoricalSportFrame.decode([0x4d, 0x00, 0x00, 0x00]))

        var valid = makePage(samples: [sample(cursor: 100, bpm: 80, steps: 12)])
        valid[valid.count - 1] ^= 0xff
        XCTAssertNil(HistoricalSportFrame.decode(valid))
    }

    func testReconstructsTenMinuteRetroactivePeriod() {
        let samples = (0 ..< 60).map {
            sample(cursor: UInt32(1_000 + ($0 + 1) * 10), bpm: 90 + $0 % 5, steps: 17)
        }
        let candidates = AutomaticWorkoutDetector.detect(samples: samples)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].duration, 600, accuracy: 0.001)
        XCTAssertEqual(candidates[0].start.timeIntervalSince1970,
                       TimeInterval(Command.syncEpoch + 1_000), accuracy: 0.001)
        XCTAssertEqual(candidates[0].suggestedKind, .walking)
        XCTAssertEqual(candidates[0].steps, 1_020)
        XCTAssertEqual(candidates[0].maximumHeartRate, 94)
    }

    func testRejectsShortAndSparseFalsePeriods() {
        let short = (0 ..< 59).map {
            sample(cursor: UInt32(2_000 + ($0 + 1) * 10), bpm: 100, steps: 25)
        }
        XCTAssertTrue(AutomaticWorkoutDetector.detect(samples: short).isEmpty)

        let sparse = [sample(cursor: 3_010, bpm: 100, steps: 20),
                      sample(cursor: 3_600, bpm: 105, steps: 20)]
        XCTAssertTrue(AutomaticWorkoutDetector.detect(
            samples: sparse, maximumGap: 600
        ).isEmpty)
    }

    func testSplitsBoutsAndDeduplicatesRetransmits() {
        let first = (0 ..< 60).map {
            sample(cursor: UInt32(4_000 + ($0 + 1) * 10), bpm: 95, steps: 25)
        }
        let second = (0 ..< 60).map {
            sample(cursor: UInt32(5_000 + ($0 + 1) * 10), bpm: 150, steps: 28)
        }
        var retransmit = first[10]
        retransmit = .init(cursor: retransmit.cursor, heartRate: nil, steps: retransmit.steps)

        let candidates = AutomaticWorkoutDetector.detect(samples: first + [retransmit] + second)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].samples.count, 60)
        XCTAssertEqual(candidates[1].suggestedKind, .running)
    }

    func testHistoricalCommandConstants() {
        XCTAssertEqual(Command.syncChannelSport, 0x02)
        XCTAssertEqual(Command.pageAck4D, [0xcd, 0x00, 0x00])
        XCTAssertEqual(Command.automaticSportRecognition(enabled: true), [0x05, 0x23, 0x01, 0x00])
        XCTAssertEqual(Command.automaticSportRecognition(enabled: false), [0x05, 0x23, 0x00, 0x00])
    }

    /// Replay every channel-0x02 page from a single official-app drain. The capture contains a
    /// continuous 21:02 stationary workout followed 10:12 later by a 4:30 fragment. This proves the
    /// retroactive start/end reconstruction and minimum-duration rejection against real firmware
    /// bytes rather than the synthetic records used by the boundary-focused tests above.
    func testReplaysCompleteOfficialAppDrainIntoOneRetroactiveCandidate() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "automatic_workout_20260709", withExtension: "hex"
        ))
        let text = try String(contentsOf: url, encoding: .utf8)
        let frames = text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { line in line.split(separator: " ").compactMap { UInt8($0, radix: 16) } }

        XCTAssertEqual(frames.count, 17)
        let samples = try frames.flatMap { frame in
            try XCTUnwrap(HistoricalSportFrame.decode(frame))
        }
        XCTAssertEqual(samples.count, 153)

        let candidates = AutomaticWorkoutDetector.detect(samples: samples)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)       // the real 4:30 tail stays below the 10-min floor
        XCTAssertEqual(candidate.samples.count, 126)
        XCTAssertEqual(candidate.id, 0x0c421255)
        XCTAssertEqual(candidate.samples.last?.cursor, 0x0c421739)
        XCTAssertEqual(candidate.duration, 1_262, accuracy: 0.001)
        XCTAssertEqual(candidate.steps, 443)
        XCTAssertEqual(candidate.averageHeartRate ?? 0, 81.6746, accuracy: 0.001)
        XCTAssertEqual(candidate.maximumHeartRate, 120)
        XCTAssertNil(candidate.suggestedKind)     // stationary/yoga-like data must not become a walk
        XCTAssertEqual(candidate.start.timeIntervalSince1970,
                       TimeInterval(Command.syncEpoch + 0x0c421255 - 10), accuracy: 0.001)
        XCTAssertEqual(candidate.end.timeIntervalSince1970,
                       TimeInterval(Command.syncEpoch + 0x0c421739), accuracy: 0.001)

        let prepared = AutomaticWorkoutConfirmation.prepare(
            candidate: candidate,
            sport: .yoga,
            profile: UserProfile(age: 35, weightKg: 70, heightCm: 175, sex: .male)
        )
        XCTAssertEqual(prepared.summary.sport, .yoga)
        XCTAssertEqual(prepared.summary.startDate, candidate.start)
        XCTAssertEqual(prepared.summary.endDate, candidate.end)
        XCTAssertEqual(prepared.summary.hrSampleCount, 126)
        XCTAssertEqual(prepared.summary.avgHR, 81)
        XCTAssertEqual(prepared.summary.maxHR, 120)
        XCTAssertEqual(prepared.summary.steps, 443)
        XCTAssertNil(prepared.summary.distanceMeters)
        XCTAssertFalse(prepared.summary.hasRoute)
        XCTAssertEqual(prepared.heartRateSamples.first?.start, candidate.start)
        XCTAssertEqual(prepared.heartRateSamples.last?.end, candidate.end)
    }

    func testInboxPrunesDeduplicatesAndKeepsResolvedBoutSuppressedWhenItExtends() throws {
        let nowCursor: UInt32 = 1_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch) + TimeInterval(nowCursor))
        let firstCursor = nowCursor - 1_000
        let bout = (0 ..< 60).map {
            sample(cursor: firstCursor + UInt32($0 * 10), bpm: 90, steps: 12)
        }
        let expired = sample(
            cursor: nowCursor - UInt32(AutomaticWorkoutInbox.retention) - 1,
            bpm: 70,
            steps: 0
        )
        let invalidDuplicate = HistoricalSportFrame.Sample(
            cursor: firstCursor,
            heartRate: nil,
            steps: 12
        )

        let initial = AutomaticWorkoutInbox.rebuild(
            existing: [expired, invalidDuplicate],
            incoming: bout,
            resolvedStartCursors: [],
            now: now
        )
        XCTAssertEqual(initial.samples.count, 60)
        XCTAssertEqual(initial.samples.first?.heartRate, 90) // valid retransmission wins
        XCTAssertEqual(initial.candidates.map(\.id), [firstCursor])

        // Later pages extend the same bout. Its first cursor—and therefore durable review key—does
        // not change, so it remains gone after a reconnect instead of appearing as a duplicate.
        let extensionSamples = (60 ..< 66).map {
            sample(cursor: firstCursor + UInt32($0 * 10), bpm: 95, steps: 13)
        }
        let restored = AutomaticWorkoutInbox.rebuild(
            existing: initial.samples,
            incoming: extensionSamples,
            resolvedStartCursors: [firstCursor],
            now: now
        )
        XCTAssertEqual(restored.samples.count, 66)
        XCTAssertTrue(restored.candidates.isEmpty)
    }

    private func sample(cursor: UInt32, bpm: Int, steps: Int) -> HistoricalSportFrame.Sample {
        .init(cursor: cursor, heartRate: LiveHR.validBPM.contains(bpm) ? bpm : nil, steps: steps)
    }

    private func makePage(samples: [HistoricalSportFrame.Sample]) -> [UInt8] {
        var bytes: [UInt8] = [0x4d, 0x00, 0x00]
        for sample in samples {
            bytes += [UInt8(sample.cursor >> 24), UInt8((sample.cursor >> 16) & 0xff),
                      UInt8((sample.cursor >> 8) & 0xff), UInt8(sample.cursor & 0xff),
                      UInt8(sample.heartRate ?? 0), UInt8(sample.steps), 0, 0, 0, 0, 0]
        }
        bytes.append(bytes.reduce(0, ^))
        return bytes
    }
}
