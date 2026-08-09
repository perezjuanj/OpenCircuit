import XCTest
@testable import OpenCircuitKit

/// Synthetic regression for a device-observed failure shape: every primary `[10:15]` motion field
/// is a constant filler, but `[15:20]` still reports activity. No captured health data is committed.
final class MotionTailFallbackTests: XCTestCase {
    private let step = UInt32(BulkRecord.epochSeconds)

    private func record(_ counter: UInt32, hr: UInt8 = 55,
                        primary: [UInt8] = [1, 1, 1, 1, 1],
                        intensity: [UInt8] = [0, 0, 0, 0, 0]) -> BulkRecord {
        var bytes = [UInt8](repeating: 0, count: BulkRecord.length)
        bytes[0] = UInt8(counter >> 24)
        bytes[1] = UInt8((counter >> 16) & 0xff)
        bytes[2] = UInt8((counter >> 8) & 0xff)
        bytes[3] = UInt8(counter & 0xff)
        bytes[4] = hr
        bytes[5] = 45
        bytes[7] = 120
        bytes[8] = 96
        for index in 0..<5 {
            bytes[10 + index] = primary[index]
            bytes[15 + index] = intensity[index]
        }
        return BulkRecord(bytes)!
    }

    private func fillerNight(movingEpochs: [Int: [UInt8]] = [:]) -> [BulkRecord] {
        var counter: UInt32 = 0x0c4f_0000
        return (0..<120).map { index in
            defer { counter += step }
            return record(counter, intensity: movingEpochs[index] ?? [0, 0, 0, 0, 0])
        }
    }

    /// ⚠️ FIXTURE MAGNITUDES RESCALED BY #197, INTENT UNCHANGED. This used to pair a tail of 32 with
    /// one of 48 and expect 1 / 16. That only ever worked because the seam was a per-set RANK: with
    /// two positive epochs in the whole night the larger one is "the top 20 %" however small it is.
    /// Against the real corpus a sum of 48 is a trivial stir — positive tail sums run p10 = 25,
    /// p50 = 230, p90 = 547 — so the old pairing asserted the rank artefact, not a measurement.
    /// The distinction under test (small tail → light, real movement → active) is preserved, now
    /// against the absolute `motionIntensityActiveCut`.
    func testTimelineUsesRepeatedEpochIntensityWhenPrimaryRunIsEntirelyFiller() {
        let records = fillerNight(movingEpochs: [40: [0, 0, 32, 0, 0],          // a stir, well below the seam
                                                  41: [0, 200, 200, 0, 0]])     // 400 — real movement
        XCTAssertTrue(BulkSleep.usesMotionIntensityFallback(records))

        let timeline = BulkSleep.motionTimeline(from: records)
        XCTAssertEqual(Array(timeline[40 * 5..<(40 * 5 + 5)]).map(\.movement),
                       [1, 1, 1, 1, 1])
        XCTAssertEqual(Array(timeline[41 * 5..<(41 * 5 + 5)]).map(\.movement),
                       [16, 16, 16, 16, 16])
    }

    /// The rank artefact itself, now pinned as REMOVED (#197). A night whose only tail activity is a
    /// couple of small stirs must read as light movement, not as an awakening — under the legacy
    /// per-set rank the largest stir was promoted to `16` no matter how small it was.
    func testSmallStirsAloneAreLightNotActive() {
        let records = fillerNight(movingEpochs: [40: [0, 0, 32, 0, 0],
                                                  41: [0, 16, 32, 0, 0]])
        let timeline = BulkSleep.motionTimeline(from: records)
        XCTAssertEqual(Array(timeline[41 * 5..<(41 * 5 + 5)]).map(\.movement), [1, 1, 1, 1, 1],
                       "a 48-unit tail is a stir; only a per-set rank could call it an awakening")
        XCTAssertEqual(BulkSleep.motionIntensityFallbackMagnitudes(records, degenerate: false,
                                                                   absoluteActiveCut: 0)[41], 16,
                       "fixture sanity: the legacy rank DID promote it — this test would be vacuous "
                       + "if the fixture no longer reproduced the artefact")
    }

    func testMovementChartDoesNotReportAllZeroWhenIntensityStillHasMotion() {
        let records = fillerNight(movingEpochs: [20: [0, 0, 8, 0, 0],
                                                  50: [0, 16, 32, 0, 0],
                                                  90: [32, 64, 0, 0, 0]])
        let summary = SleepDetailMetrics.movementSummary(records: records)

        XCTAssertEqual(summary.total, records.count)
        XCTAssertEqual(summary.light + summary.active, 3)
        XCTAssertGreaterThan(summary.active, 0)
    }

    /// ⚠️ Magnitudes rescaled by #197 (64 → 400, i.e. above the absolute seam rather than merely the
    /// largest in a synthetic night); the assertions are untouched. See the note on
    /// `testTimelineUsesRepeatedEpochIntensityWhenPrimaryRunIsEntirelyFiller`.
    func testConsecutiveIntensityMovementProducesAnAwakeInterval() {
        let records = fillerNight(movingEpochs: [60: [0, 200, 200, 0, 0],
                                                  61: [0, 200, 200, 0, 0]])
        let summary = SleepStaging.summary(SleepStaging.classify(from: records)).minutes

        XCTAssertGreaterThan(summary.awake, 0,
                             "measured movement must prevent asleep == in-bed on a filler-motion night")
        XCTAssertLessThan(summary.asleep, summary.inBed)
    }

    func testZeroIntensityKeepsAQuietFillerNightOnPrimaryPath() {
        let records = fillerNight()
        XCTAssertFalse(BulkSleep.usesMotionIntensityFallback(records))
        XCTAssertTrue(SleepDetailMetrics.movement(records: records)
            .allSatisfy { $0.level == .still })
    }

    func testAnyRealPrimaryMotionKeepsNormalSignalAuthoritative() {
        var records = fillerNight(movingEpochs: [20: [0, 0, 64, 0, 0],
                                                  21: [0, 0, 64, 0, 0]])
        records[10] = record(records[10].counter,
                             primary: [1, 1, 8, 1, 1],
                             intensity: [0, 0, 0, 0, 0])
        XCTAssertFalse(BulkSleep.usesMotionIntensityFallback(records))
    }

}
