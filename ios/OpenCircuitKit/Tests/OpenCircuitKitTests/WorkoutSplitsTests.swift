import XCTest
@testable import OpenCircuitKit

final class WorkoutSplitsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_789_862_400)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A fix every `step` seconds covering `meters` each, from `from` to `to` seconds.
    private func steady(from: TimeInterval, to: TimeInterval, step: TimeInterval, meters: Double) -> [WorkoutTrackFix] {
        stride(from: from, through: to, by: step).map { WorkoutTrackFix(at: at($0), metersFromPrevious: meters) }
    }

    // MARK: Track

    func testTrackSumsWithinLegAndIgnoresTheFirstFix() {
        let track = WorkoutTrack(fixes: [WorkoutTrackFix(at: at(0), metersFromPrevious: 999),
                                         WorkoutTrackFix(at: at(5), metersFromPrevious: 10),
                                         WorkoutTrackFix(at: at(10), metersFromPrevious: 12)], pauses: [])
        XCTAssertEqual(track.legs.count, 1)
        XCTAssertEqual(track.totalMeters, 22, accuracy: 1e-9)
    }

    func testAPauseStartsANewLegAndDropsTheStepAcrossIt() {
        let pause = DateInterval(start: at(12), end: at(60))
        let track = WorkoutTrack(fixes: [WorkoutTrackFix(at: at(0), metersFromPrevious: 0),
                                         WorkoutTrackFix(at: at(10), metersFromPrevious: 30),
                                         WorkoutTrackFix(at: at(65), metersFromPrevious: 400), // across the pause
                                         WorkoutTrackFix(at: at(70), metersFromPrevious: 15)], pauses: [pause])
        XCTAssertEqual(track.legs.count, 2)
        XCTAssertEqual(track.totalMeters, 45, accuracy: 1e-9, "the live counter reset at resume: nothing across the pause")
    }

    func testAPauseWhollyBetweenTwoFixesStillBreaksTheLeg() {
        let pause = DateInterval(start: at(11), end: at(13))
        let track = WorkoutTrack(fixes: [WorkoutTrackFix(at: at(10), metersFromPrevious: 0),
                                         WorkoutTrackFix(at: at(14), metersFromPrevious: 9)], pauses: [pause])
        XCTAssertEqual(track.legs.count, 2)
        XCTAssertEqual(track.totalMeters, 0)
    }

    // MARK: Distance intervals

    func testIntervalsAddUpToTheTotalAndNeverSpanAPause() {
        let pause = DateInterval(start: at(301), end: at(400))
        let fixes = steady(from: 0, to: 300, step: 2, meters: 6) + steady(from: 402, to: 900, step: 2, meters: 6)
        let track = WorkoutTrack(fixes: fixes, pauses: [pause])
        let intervals = WorkoutSplits.distanceIntervals(track)
        XCTAssertEqual(intervals.reduce(0) { $0 + $1.meters }, track.totalMeters, accuracy: 1e-6)
        XCTAssertTrue(intervals.allSatisfy { $0.end > $0.start && $0.meters > 0 })
        XCTAssertFalse(intervals.contains { $0.start < pause.end && $0.end > pause.start })
        XCTAssertTrue(intervals.allSatisfy { $0.end.timeIntervalSince($0.start) <= 16 })
        XCTAssertGreaterThan(intervals.count, 50)
    }

    func testStandingStillWritesNoZeroDistanceSamples() {
        let fixes = steady(from: 0, to: 60, step: 5, meters: 10) + steady(from: 65, to: 200, step: 5, meters: 0)
        let intervals = WorkoutSplits.distanceIntervals(WorkoutTrack(fixes: fixes, pauses: []))
        XCTAssertTrue(intervals.allSatisfy { $0.meters > 0 })
        XCTAssertEqual(intervals.reduce(0) { $0 + $1.meters }, 120, accuracy: 1e-9)
    }

    func testASameInstantLastStepFoldsIntoThePreviousInterval() {
        let fixes = steady(from: 0, to: 30, step: 15, meters: 50) + [WorkoutTrackFix(at: at(30), metersFromPrevious: 4)]
        let track = WorkoutTrack(fixes: fixes, pauses: [])
        let intervals = WorkoutSplits.distanceIntervals(track)
        XCTAssertEqual(intervals.reduce(0) { $0 + $1.meters }, track.totalMeters, accuracy: 1e-9)
        XCTAssertEqual(intervals.count, 2)
    }

    func testEmptyTrackHasNothing() {
        let track = WorkoutTrack(fixes: [], pauses: [])
        XCTAssertTrue(WorkoutSplits.distanceIntervals(track).isEmpty)
        XCTAssertTrue(WorkoutSplits.splits(track, every: 1_000, start: at(0), end: at(60), pauses: []).isEmpty)
    }

    // MARK: Splits

    func testBoundariesInterpolateBetweenFixes() {
        // 4 m/s, a fix every 10 s (40 m): 1 000 m is reached at exactly 250 s.
        let track = WorkoutTrack(fixes: steady(from: 0, to: 600, step: 10, meters: 40), pauses: [])
        let marks = WorkoutSplits.boundaries(track, every: 1_000)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0].timeIntervalSince(t0), 250, accuracy: 1e-6)
        XCTAssertEqual(marks[1].timeIntervalSince(t0), 500, accuracy: 1e-6)
    }

    func testKilometreSplitsWithPartialLast() {
        // 4 m/s for 600 s = 2 400 m: two whole kms (250 s each), then a 400 m partial.
        let track = WorkoutTrack(fixes: steady(from: 0, to: 600, step: 10, meters: 40), pauses: [])
        let splits = WorkoutSplits.splits(track, every: 1_000, start: at(0), end: at(600), pauses: [])
        XCTAssertEqual(splits.map(\.isPartial), [false, false, true])
        XCTAssertEqual(splits[0].secondsPerUnit(1_000) ?? 0, 250, accuracy: 1e-6)
        XCTAssertEqual(splits[1].secondsPerUnit(1_000) ?? 0, 250, accuracy: 1e-6)
        XCTAssertEqual(splits[2].meters, 400, accuracy: 1e-6)
        XCTAssertEqual(splits[2].secondsPerUnit(1_000) ?? 0, 250, accuracy: 1e-6, "partial pace is scaled, not stretched")
    }

    func testSplitPaceExcludesPausedTime() {
        // Run 4 m/s for 200 s (800 m), pause 300 s, run on: the km boundary is 50 s after the resume.
        let pause = DateInterval(start: at(200), end: at(500))
        let fixes = steady(from: 0, to: 200, step: 10, meters: 40) + steady(from: 500, to: 800, step: 10, meters: 40)
        let track = WorkoutTrack(fixes: fixes, pauses: [pause])
        let splits = WorkoutSplits.splits(track, every: 1_000, start: at(0), end: at(800), pauses: [pause])
        XCTAssertEqual(splits[0].end.timeIntervalSince(t0), 550, accuracy: 1e-6)
        XCTAssertEqual(splits[0].movingSeconds, 250, accuracy: 1e-6)
    }

    func testMileSplits() {
        let track = WorkoutTrack(fixes: steady(from: 0, to: 1_000, step: 10, meters: 40), pauses: [])
        let miles = WorkoutSplits.splits(track, every: WorkoutSplits.mileMeters, start: at(0), end: at(1_000), pauses: [])
        XCTAssertEqual(miles.filter { !$0.isPartial }.count, 2) // 4 000 m = 2.49 mi
        XCTAssertEqual(miles.last?.isPartial, true)
    }

    func testATinyTailIsNotAPartialSplit() {
        let track = WorkoutTrack(fixes: steady(from: 0, to: 260, step: 10, meters: 40), pauses: []) // 1 040 m
        let splits = WorkoutSplits.splits(track, every: 1_000, start: at(0), end: at(260), pauses: [])
        XCTAssertEqual(splits.count, 1)
        XCTAssertFalse(splits[0].isPartial)
    }

    func testSegmentIntervalsAreWholeSplitsOnly() {
        let track = WorkoutTrack(fixes: steady(from: 0, to: 600, step: 10, meters: 40), pauses: [])
        let segments = WorkoutSplits.segmentIntervals(track, every: 1_000, start: at(0), end: at(600))
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, at(0))
        XCTAssertEqual(segments[1].start, segments[0].end)
    }
}
