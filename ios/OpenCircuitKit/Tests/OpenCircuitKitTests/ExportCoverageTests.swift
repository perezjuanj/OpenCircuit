import XCTest
@testable import OpenCircuitKit

/// Coverage is a MEASUREMENT of what we hold. These tests exist mostly to stop it from
/// overstating: a fraction above 1.0, a gap that isn't there, or a duplicate row counted twice
/// would all turn "here is what we have" into a claim about what the ring recorded.
final class ExportCoverageTests: XCTestCase {

    private let cadence = TimeInterval(BulkRecord.epochSeconds)   // 150 s (🟢 PROTOCOL.md §5.3)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ epochs: Int) -> Date { t0.addingTimeInterval(Double(epochs) * 150) }

    // MARK: - Perfect coverage

    func testPerfectCoverage() {
        let times = (0 ..< 24).map { at($0) }
        let a = ExportCoverage.assess(sampleTimes: times, from: at(0), to: at(24))
        XCTAssertEqual(a.expectedSamples, 24)
        XCTAssertEqual(a.observedSamples, 24)
        XCTAssertEqual(a.coverageFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.gaps, [])
        XCTAssertEqual(a.longestGapSeconds, 0)
    }

    func testCoverageFractionNeverExceedsOne() {
        // Denser-than-cadence sampling (e.g. a live measurement burst) must not read as >100 %.
        let times = stride(from: 0.0, to: 3_600.0, by: 30.0).map { t0.addingTimeInterval($0) }
        let a = ExportCoverage.assess(sampleTimes: times, from: t0,
                                      to: t0.addingTimeInterval(3_600))
        XCTAssertGreaterThan(a.observedSamples, a.expectedSamples)
        XCTAssertEqual(a.coverageFraction, 1.0, accuracy: 1e-9)
    }

    // MARK: - Gaps

    func testSingleInteriorGap() {
        // Epochs 0…3 then 10…19: a 7-epoch hole in the middle.
        let times = (0 ... 3).map { at($0) } + (10 ..< 20).map { at($0) }
        let a = ExportCoverage.assess(sampleTimes: times, from: at(0), to: at(19))
        XCTAssertEqual(a.gaps.count, 1)
        XCTAssertEqual(a.gaps.first?.start, at(3))
        XCTAssertEqual(a.gaps.first?.end, at(10))
        XCTAssertEqual(a.gaps.first?.seconds, 7 * cadence)
        XCTAssertEqual(a.longestGapSeconds, 7 * cadence)
        XCTAssertEqual(a.observedSamples, 14)
        XCTAssertEqual(a.expectedSamples, 19)
    }

    func testLeadingAndTrailingGapsAreReported() {
        // Window spans epochs 0…20 but we only hold 8…12.
        let times = (8 ... 12).map { at($0) }
        let a = ExportCoverage.assess(sampleTimes: times, from: at(0), to: at(20))
        XCTAssertEqual(a.gaps.count, 2, "leading and trailing holes are both real gaps")
        XCTAssertEqual(a.gaps[0].start, at(0))
        XCTAssertEqual(a.gaps[0].end, at(8))
        XCTAssertEqual(a.gaps[1].start, at(12))
        XCTAssertEqual(a.gaps[1].end, at(20))
        XCTAssertEqual(a.longestGapSeconds, 8 * cadence)
    }

    func testLongestGapMatchesWidestReportedGap() {
        let times = [at(0), at(5), at(6), at(20), at(21)]
        let a = ExportCoverage.assess(sampleTimes: times, from: at(0), to: at(21))
        XCTAssertFalse(a.gaps.isEmpty)
        XCTAssertEqual(a.longestGapSeconds, a.gaps.map(\.seconds).max())
        XCTAssertEqual(a.longestGapSeconds, 14 * cadence)
    }

    func testSingleMissedEpochIsNotReportedAsAGap() {
        // minGap is two epochs: ordinary jitter must not bury the real holes.
        let times = [at(0), at(1), at(3), at(4)]
        let a = ExportCoverage.assess(sampleTimes: times, from: at(0), to: at(4))
        XCTAssertEqual(a.gaps, [], "a 2-epoch step is not STRICTLY longer than minGap")
    }

    func testGapsAreAscending() {
        let times = [at(10), at(11), at(30)]
        let a = ExportCoverage.assess(sampleTimes: times, from: at(0), to: at(40))
        XCTAssertEqual(a.gaps.count, 3)
        for (lhs, rhs) in zip(a.gaps, a.gaps.dropFirst()) {
            XCTAssertLessThanOrEqual(lhs.start, rhs.start)
        }
    }

    // MARK: - Degenerate + hostile input

    func testEmptyInputMakesTheWholeWindowOneGap() {
        let a = ExportCoverage.assess(sampleTimes: [], from: at(0), to: at(24))
        XCTAssertEqual(a.observedSamples, 0)
        XCTAssertEqual(a.expectedSamples, 24)
        XCTAssertEqual(a.coverageFraction, 0)
        XCTAssertEqual(a.gaps, [ExportCoverage.Gap(start: at(0), end: at(24))])
        XCTAssertEqual(a.longestGapSeconds, 24 * cadence)
    }

    func testInvertedWindowIsDegenerateAndInventsNoGap() {
        let a = ExportCoverage.assess(sampleTimes: [at(1)], from: at(10), to: at(0))
        XCTAssertEqual(a.expectedSamples, 0)
        XCTAssertEqual(a.observedSamples, 0)
        XCTAssertEqual(a.coverageFraction, 0)
        XCTAssertEqual(a.gaps, [], "an inverted window has no hole to report")
        XCTAssertEqual(a.longestGapSeconds, 0)
    }

    func testZeroLengthWindowIsDegenerate() {
        let a = ExportCoverage.assess(sampleTimes: [at(0)], from: at(0), to: at(0))
        XCTAssertEqual(a.expectedSamples, 0)
        XCTAssertEqual(a.coverageFraction, 0)
        XCTAssertEqual(a.gaps, [])
    }

    func testUnsortedAndDuplicateTimestamps() {
        let times = [at(3), at(0), at(1), at(1), at(2), at(3), at(0)]
        let a = ExportCoverage.assess(sampleTimes: times, from: at(0), to: at(4))
        XCTAssertEqual(a.observedSamples, 4, "duplicates cover the same epoch and count once")
        XCTAssertEqual(a.expectedSamples, 4)
        XCTAssertEqual(a.coverageFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.gaps, [])
    }

    func testSamplesOutsideTheWindowAreIgnored() {
        let inside = (10 ... 14).map { at($0) }
        let outside = [at(-50), at(-1), at(100), at(500)]
        let a = ExportCoverage.assess(sampleTimes: outside + inside, from: at(10), to: at(14))
        XCTAssertEqual(a.observedSamples, 5)
        XCTAssertEqual(a.expectedSamples, 4)
        XCTAssertEqual(a.coverageFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.gaps, [], "out-of-window samples must not create in-window gaps either")
    }

    func testWindowBoundsAreEchoedBack() {
        let a = ExportCoverage.assess(sampleTimes: [], from: at(2), to: at(9))
        XCTAssertEqual(a.windowStart, at(2))
        XCTAssertEqual(a.windowEnd, at(9))
    }

    func testExpectedSamplesFloorsPartialEpochs() {
        // 5.5 epochs of window → 5 whole epochs expected, never 6.
        let a = ExportCoverage.assess(sampleTimes: [], from: t0,
                                      to: t0.addingTimeInterval(5.5 * 150))
        XCTAssertEqual(a.expectedSamples, 5)
    }

    func testCustomCadenceAndMinGap() {
        let times = [t0, t0.addingTimeInterval(60)]
        let a = ExportCoverage.assess(sampleTimes: times, from: t0,
                                      to: t0.addingTimeInterval(600),
                                      cadence: 60, minGap: 120)
        XCTAssertEqual(a.expectedSamples, 10)
        XCTAssertEqual(a.observedSamples, 2)
        XCTAssertEqual(a.coverageFraction, 0.2, accuracy: 1e-9)
        XCTAssertEqual(a.gaps, [ExportCoverage.Gap(start: t0.addingTimeInterval(60),
                                                  end: t0.addingTimeInterval(600))])
    }

    func testNonPositiveCadenceIsDegenerateRatherThanDividingByZero() {
        let a = ExportCoverage.assess(sampleTimes: [t0], from: t0,
                                      to: t0.addingTimeInterval(600), cadence: 0)
        XCTAssertEqual(a.expectedSamples, 0)
        XCTAssertEqual(a.coverageFraction, 0)
    }

    func testGapSecondsIsEndMinusStart() {
        let gap = ExportCoverage.Gap(start: t0, end: t0.addingTimeInterval(450))
        XCTAssertEqual(gap.seconds, 450)
    }
}
