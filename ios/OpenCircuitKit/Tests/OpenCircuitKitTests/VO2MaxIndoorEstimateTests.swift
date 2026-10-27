// The indoor (treadmill) VO₂ max estimate (#339, decision 84g): per-minute speed = that minute's steps ×
// (typed distance ÷ total active steps), grade = typed incline ÷ 100, then the outdoor rules unchanged.
// And the outdoor estimate is untouched by it. Synthetic, rounded runs.

import XCTest
@testable import OpenCircuitKit

final class VO2MaxIndoorEstimateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A treadmill run: a step delta every 10 s at `cadence(minute)` spm, a heart-rate reading every
    /// 10 s, and a typed distance that makes the stride exactly `strideMeters`.
    private func treadmillRun(minutes: Int = 20, sport: WorkoutSportType = .runningIndoor,
                              cadence: (Int) -> Int = { _ in 160 }, heartRate: (Int) -> Int = { _ in 160 },
                              strideMeters: Double = 1.25, typed: Bool = true, incline: Double? = nil,
                              age: Int? = 40, restingHR: Double? = 60,
                              noStepsDuring: ClosedRange<Int>? = nil) -> VO2MaxEstimate.IndoorInput {
        let seconds = minutes * 60
        var steps: [WorkoutStepDelta] = []
        for s in stride(from: 10, through: seconds, by: 10) {
            let minute = (s - 1) / 60
            if let noStepsDuring, noStepsDuring.contains(minute) { continue }
            steps.append(WorkoutStepDelta(at: t0.addingTimeInterval(Double(s) - 0.5), steps: cadence(minute) / 6))
        }
        let total = steps.reduce(0) { $0 + $1.steps }
        let hr = stride(from: 0, to: seconds, by: 10).map {
            HRSample(bpm: heartRate($0 / 60), start: t0.addingTimeInterval(Double($0)))
        }
        return .init(sport: sport, start: t0, end: t0.addingTimeInterval(Double(seconds)),
                     activeSeconds: Double(seconds), heartRate: hr, steps: steps,
                     typedDistance: typed ? (total > 0 ? Double(total) * strideMeters : 3_000) : nil, inclinePercent: incline,
                     age: age, restingHR: restingHR)
    }

    private func skip(_ input: VO2MaxEstimate.IndoorInput) -> VO2MaxEstimate.SkipReason? {
        if case .skipped(let reason) = VO2MaxEstimate.estimateIndoor(input) { return reason }
        return nil
    }

    func testASteadyTreadmillRunGivesTheACSMAndSwainEstimateFromStepsTimesTheCalibratedStride() throws {
        // 156 spm (26 per 10 s) × 1.25 m = 195 m/min; HR 160, resting 60, Tanaka(40) = 180.
        let outcome = VO2MaxEstimate.estimateIndoor(treadmillRun(cadence: { _ in 156 }))
        guard case .estimate(let e) = outcome else { return XCTFail("expected an estimate, got \(outcome)") }
        XCTAssertEqual(e.speed, 195, accuracy: 0.001)
        XCTAssertEqual(e.grade, 0)
        XCTAssertFalse(e.gradeFromElevation)
        XCTAssertEqual(e.speedSource, .treadmillSteps)
        let cost = 0.2 * 195 + 3.5
        XCTAssertEqual(e.segmentVO2, cost, accuracy: 0.0001)
        XCTAssertEqual(e.vo2Max, 3.5 + (cost - 3.5) * (180 - 60) / (160 - 60), accuracy: 0.0001)
        XCTAssertEqual(e.maxHRSource, .ageFormula)
        XCTAssertEqual(e.segmentStart, t0.addingTimeInterval(4 * 60), "the outdoor warm-up rule applies")
    }

    func testTheTypedInclineIsTheGrade() throws {
        let outcome = VO2MaxEstimate.estimateIndoor(treadmillRun(cadence: { _ in 156 }, incline: 5))
        guard case .estimate(let e) = outcome else { return XCTFail("expected an estimate, got \(outcome)") }
        XCTAssertEqual(e.grade, 0.05, accuracy: 1e-12)
        let cost = 0.2 * 195 + 0.9 * 195 * 0.05 + 3.5
        XCTAssertEqual(e.segmentVO2, cost, accuracy: 0.0001)
        XCTAssertEqual(e.vo2Max, 3.5 + (cost - 3.5) * 120 / 100, accuracy: 0.0001)
    }

    func testEachRefusalIsItsReason() {
        XCTAssertEqual(skip(treadmillRun(typed: false)), .noTypedDistance)
        XCTAssertEqual(skip(treadmillRun(noStepsDuring: 0 ... 99)), .noStepData)
        XCTAssertEqual(skip(treadmillRun(typed: false, noStepsDuring: 0 ... 99)), .noStepData,
                       "with no steps, asking for the treadmill's distance would not help")
        XCTAssertEqual(skip(treadmillRun(sport: .walkingIndoor)), .notAnIndoorRun)
        XCTAssertEqual(skip(treadmillRun(sport: .runningOutdoor)), .notAnIndoorRun)
        XCTAssertEqual(skip(treadmillRun(minutes: 9)), .tooShort)
        XCTAssertEqual(skip(treadmillRun(age: nil)), .noAge)
        XCTAssertEqual(skip(treadmillRun(restingHR: nil)), .noRestingHR)
        XCTAssertEqual(skip(treadmillRun(incline: 20)), .implausible, "an incline outside 0–15 % is a bad input")
        // Intervals: the pace alternates every minute, so no 5-minute stretch is steady.
        XCTAssertEqual(skip(treadmillRun(cadence: { $0 % 2 == 0 ? 120 : 180 })), .noSteadySegment)
        // A walk-paced treadmill session: under 80 m/min, outside the running equation.
        XCTAssertEqual(skip(treadmillRun(cadence: { _ in 60 })), .noSteadySegment)
        XCTAssertEqual(skip(treadmillRun(heartRate: { _ in 100 })), .intensityTooLow)
    }

    func testAMinuteWithNoStepsIsNeverPartOfTheSteadySegment() throws {
        // Steps missing in minutes 4–9: the first steady 5 minutes start at minute 10.
        let outcome = VO2MaxEstimate.estimateIndoor(treadmillRun(minutes: 20, cadence: { _ in 156 }, noStepsDuring: 4 ... 9))
        guard case .estimate(let e) = outcome else { return XCTFail("expected an estimate, got \(outcome)") }
        XCTAssertEqual(e.segmentStart, t0.addingTimeInterval(10 * 60))
    }

    func testTheShortRunRuleCountsRunningTime() {
        var input = treadmillRun(minutes: 14)
        input = .init(sport: input.sport, start: input.start, end: input.end, activeSeconds: 8 * 60,
                      heartRate: input.heartRate, steps: input.steps, typedDistance: input.typedDistance,
                      inclinePercent: nil, age: 40, restingHR: 60)
        XCTAssertEqual(skip(input), .tooShort)
    }

    // MARK: Outdoor is unchanged

    func testTheOutdoorEstimateStillRefusesAnIndoorRunAndStillNamesTheRouteAsItsSpeed() throws {
        let indoor = VO2MaxEstimate.Input(sport: .runningIndoor, start: t0, end: t0.addingTimeInterval(1_200),
                                          heartRate: [], route: [], age: 40, restingHR: 60)
        XCTAssertEqual(VO2MaxEstimate.estimate(indoor), .skipped(.notAnOutdoorRun))
        // A steady outdoor run (fix every 5 s at 200 m/min, HR 160 every 10 s).
        let route = stride(from: 0, through: 1_200, by: 5).map {
            VO2MaxEstimate.RoutePoint(time: t0.addingTimeInterval(Double($0)), distance: Double($0) * 200 / 60)
        }
        let hr = stride(from: 0, to: 1_200, by: 10).map { HRSample(bpm: 160, start: t0.addingTimeInterval(Double($0))) }
        let outdoor = VO2MaxEstimate.Input(sport: .runningOutdoor, start: t0, end: t0.addingTimeInterval(1_200),
                                           heartRate: hr, route: route, age: 40, restingHR: 60)
        guard case .estimate(let e) = VO2MaxEstimate.estimate(outdoor) else { return XCTFail("expected an estimate") }
        XCTAssertEqual(e.speedSource, .gpsRoute)
        XCTAssertEqual(e.speed, 200, accuracy: 0.001)
        XCTAssertEqual(e.vo2Max, 3.5 + (0.2 * 200) * 120 / 100, accuracy: 0.0001)
    }
}
