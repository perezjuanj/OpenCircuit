// Steps during an indoor run or walk (#339, decision 84c, 84d): the counter-delta rule, cadence, the
// per-minute bins, and the stride. Synthetic, rounded counters and times.

import XCTest
@testable import OpenCircuitKit

final class WorkoutStepsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: Counter deltas (84c)

    func testCounterReadingsBecomeDeltasWithTheFirstAsABaseAndABackwardStepAsANewBase() {
        // (reading, counting, steps added, label)
        let table: [(Int, Bool, Int, String)] = [
            (1_000, true, 0, "first reading is a base"),
            (1_010, true, 10, "a rise counts"),
            (1_010, true, 0, "unchanged counts nothing"),
            (1_025, true, 15, "another rise"),
            (5, true, 0, "a reset (or a wrap) is a new base, never negative"),
            (20, true, 15, "counting resumes from the new base"),
            (65_535, true, 65_515, "a big rise is still a rise"),
            (3, true, 0, "a u16 wrap is a new base, not a guessed wrap-around"),
            (13, false, 0, "paused: the base moves, nothing counts"),
            (23, true, 10, "after the pause only the steps since its last reading count"),
        ]
        var deltas = StepCounterDeltas()
        for (reading, counting, expected, label) in table {
            XCTAssertEqual(deltas.observe(reading, counting: counting), expected, label)
        }
        XCTAssertEqual(deltas.resets, 2)
    }

    func testRebaseMakesTheNextReadingABaseSoAGapOrPauseIsNeverCredited() {
        var deltas = StepCounterDeltas()
        _ = deltas.observe(100, counting: true)
        deltas.rebase()
        XCTAssertEqual(deltas.observe(400, counting: true), 0, "300 steps taken while the stream was off are not counted")
        XCTAssertEqual(deltas.observe(410, counting: true), 10)
    }

    // MARK: The log

    func testTheLogTotalsOnlyPositiveStepsAndItsLiveCadenceIsTheLastSixtySeconds() {
        var log = WorkoutStepLog()
        log.add(0, at: at(5))
        log.add(-3, at: at(6))
        for s in stride(from: 10.0, through: 120, by: 10) { log.add(25, at: at(s)) }   // 150 spm
        XCTAssertEqual(log.total, 300)
        XCTAssertEqual(log.deltas.count, 12, "a zero or negative delta is never logged")
        XCTAssertEqual(log.liveCadence(now: at(120), countingSince: at(0)) ?? 0, 150, accuracy: 0.001)
        // Counting for only 30 s: the cadence is over those 30 s, not diluted over 60.
        XCTAssertEqual(log.liveCadence(now: at(120), countingSince: at(90)) ?? 0, 150, accuracy: 0.001)
        XCTAssertNil(log.liveCadence(now: at(120), countingSince: at(115)), "under 10 s of counting says nothing")
        XCTAssertEqual(log.averageCadence(activeSeconds: 120) ?? 0, 150, accuracy: 0.001)
        XCTAssertNil(WorkoutStepLog().averageCadence(activeSeconds: 600))
    }

    func testMinutesBinStepsByWholeMinuteAndMarkTheOnesAPauseTouches() {
        var log = WorkoutStepLog()
        log.add(100, at: at(30))
        log.add(50, at: at(59))
        log.add(80, at: at(60))
        log.add(90, at: at(170))
        // Running 0–90 s and 150–200 s (a pause 90–150 s); 200 s ends inside the fourth minute.
        let active = [DateInterval(start: at(0), end: at(90)), DateInterval(start: at(150), end: at(200))]
        let minutes = log.minutes(start: at(0), end: at(200), active: active)
        XCTAssertEqual(minutes.map(\.steps), [150, 80, 90])
        XCTAssertEqual(minutes.map(\.wholeInActiveTime), [true, false, false])
    }

    // MARK: Stride (84d, 84e)

    func testTheStrideComesFromACalibrationWhenStoredElseFromHeightTimesTheSportFactor() {
        XCTAssertEqual(IndoorStride.walkingHeightFactor, 0.415)
        XCTAssertEqual(IndoorStride.runningHeightFactor, 0.65)
        let run = IndoorStride.forWorkout(sport: .runningIndoor, heightCm: 180, calibrated: nil)
        XCTAssertEqual(run?.source, .height)
        XCTAssertEqual(run?.meters ?? 0, 1.17, accuracy: 0.0001)
        let walk = IndoorStride.forWorkout(sport: .walkingIndoor, heightCm: 180, calibrated: nil)
        XCTAssertEqual(walk?.meters ?? 0, 0.747, accuracy: 0.0001)
        let calibrated = IndoorStride.forWorkout(sport: .runningIndoor, heightCm: 180, calibrated: 1.05)
        XCTAssertEqual(calibrated, IndoorStride(meters: 1.05, source: .calibrated))
        XCTAssertNil(IndoorStride.forWorkout(sport: .runningIndoor, heightCm: nil, calibrated: nil))
        XCTAssertNil(IndoorStride.forWorkout(sport: .runningOutdoor, heightCm: 180, calibrated: nil))
        XCTAssertEqual(IndoorStride.forWorkout(sport: .runningIndoor, heightCm: 180, calibrated: 9)?.source, .height,
                       "an implausible stored calibration is ignored")
        XCTAssertEqual(run?.distance(steps: 1_000) ?? 0, 1_170, accuracy: 0.001)
    }

    func testATypedDistanceCalibratesTheStrideOnlyWithStepsAndAHumanResult() {
        XCTAssertEqual(IndoorStride.calibrate(typedMeters: 5_000, activeSteps: 5_000), IndoorStride(meters: 1, source: .typed))
        XCTAssertNil(IndoorStride.calibrate(typedMeters: 5_000, activeSteps: 0))
        XCTAssertNil(IndoorStride.calibrate(typedMeters: 0, activeSteps: 5_000))
        XCTAssertNil(IndoorStride.calibrate(typedMeters: 50_000, activeSteps: 5_000), "10 m a step is a typo")
    }

    func testOnlyIndoorRunsAndWalksUseStepsAndOnlyRunsWriteRunningMetrics() {
        XCTAssertEqual(WorkoutSportType.allCases.filter(IndoorStepWorkout.applies(to:)), [.walkingIndoor, .runningIndoor])
        XCTAssertEqual(WorkoutSportType.allCases.filter(IndoorStepWorkout.writesRunningMetrics), [.runningIndoor])
    }

    func testTheEntriesAcceptTheirRangesAndRefuseTheRest() {
        XCTAssertEqual(IndoorRunEntry.distanceMeters("5", metersPerUnit: 1_000), 5_000)
        XCTAssertEqual(IndoorRunEntry.distanceMeters(" 3,1 ", metersPerUnit: 1_000) ?? 0, 3_100, accuracy: 0.001)
        XCTAssertEqual(IndoorRunEntry.distanceMeters("2", metersPerUnit: 1_609.344) ?? 0, 3_218.688, accuracy: 0.001)
        for bad in ["", "0", "-1", "abc", "1000"] { XCTAssertNil(IndoorRunEntry.distanceMeters(bad, metersPerUnit: 1_000), bad) }
        XCTAssertEqual(IndoorRunEntry.incline("0"), 0)
        XCTAssertEqual(IndoorRunEntry.incline("15"), 15)
        XCTAssertEqual(IndoorRunEntry.incline("2,5"), 2.5)
        for bad in ["", "-1", "15.5", "x"] { XCTAssertNil(IndoorRunEntry.incline(bad), bad) }
    }
}
