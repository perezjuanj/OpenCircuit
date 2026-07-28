import XCTest
@testable import OpenCircuitKit

/// Time-attributed active energy (`Calories.dailyEstimate` with `stepWindows` + `dayStart`).
///
/// Regression origin: a tester's Apple Health showed active energy stop dead at 2pm and never
/// resume, while HR and steps kept arriving all afternoon. The legacy estimate is
/// `max(hrKcal, stepKcal)` over two WHOLE-DAY snapshots — once the last elevated-HR bout ends
/// `hrKcal` is exactly constant, and the step channel needs ~27-40k steps to overtake it, so the
/// day total froze and `flushActiveCalories` computed a delta of 0.000 on every later flush.
final class CaloriesAttributionTests: XCTestCase {

    private let profile = UserProfile(age: 35, weightKg: 72, heightCm: 178, sex: .male)
    private let day = Date(timeIntervalSince1970: 1_753_660_800)  // a local midnight

    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    /// A run of back-to-back 150 s epochs at one bpm — how the ring actually delivers a bout.
    private func bout(fromHour: Double, minutes: Double, bpm: Int) -> [HRSample] {
        let epochs = Int((minutes * 60 / 150).rounded())
        return (0 ..< epochs).map { i in
            HRSample(bpm: bpm, start: at(fromHour).addingTimeInterval(Double(i) * 150))
        }
    }

    private func steps(_ delta: Int, fromHour: Double, minutes: Double) -> StepWindow {
        StepWindow(start: at(fromHour),
                   end: at(fromHour).addingTimeInterval(minutes * 60),
                   delta: delta)
    }

    // MARK: The reported bug

    /// THE regression test. A morning bout freezes `hrKcal`; the afternoon is walking with heart
    /// rate below the 92 bpm gate. The legacy estimate pays the afternoon exactly nothing.
    func testAfternoonWalkingAccruesAfterTheLastElevatedBout() {
        let hr = bout(fromHour: 8, minutes: 20, bpm: 118)
        let windows = [steps(2_000, fromHour: 8, minutes: 20),      // during the bout
                       steps(2_100, fromHour: 15, minutes: 25)]     // the walk home, HR ~88

        let legacy = Calories.dailyEstimate(hrSamples: hr, steps: 4_100, profile: profile)
        let attributed = Calories.dailyEstimate(hrSamples: hr, steps: 4_100, profile: profile,
                                                stepWindows: windows, dayStart: day)

        // Legacy: the afternoon is worth zero, so the day total is just the morning bout.
        XCTAssertEqual(legacy.activeKcal,
                       Calories.workoutActiveKcal(avgHR: 118, durationSeconds: 20 * 60,
                                                  profile: profile),
                       accuracy: 0.5)

        let afternoon = attributed.buckets.filter { $0.start >= at(14) }
        XCTAssertFalse(afternoon.isEmpty, "the afternoon walk must produce buckets")
        XCTAssertGreaterThan(afternoon.reduce(0) { $0 + $1.activeKcal }, 15,
                             "2,100 steps of walking must be worth real kcal")
        XCTAssertGreaterThan(attributed.activeKcal, legacy.activeKcal)
    }

    /// The other half of the freeze: isolated elevated spot reads land in the qualifying-BPM
    /// average but earn zero exercise minutes, so under the legacy day-average pricing they DILUTE
    /// a morning bout. Per-piece pricing cannot be moved by them.
    func testIsolatedAfternoonSpotReadsDoNotLowerTheDayTotal() {
        let morning = bout(fromHour: 8, minutes: 30, bpm: 135)
        let spots = [11.0, 13.0, 15.0].map { HRSample(bpm: 95, start: at($0)) }
        let windows = [steps(3_000, fromHour: 8, minutes: 30)]

        let before = Calories.dailyEstimate(hrSamples: morning, steps: 3_000, profile: profile,
                                            stepWindows: windows, dayStart: day)
        let after = Calories.dailyEstimate(hrSamples: morning + spots, steps: 3_000,
                                           profile: profile,
                                           stepWindows: windows, dayStart: day)
        XCTAssertGreaterThanOrEqual(after.activeKcal, before.activeKcal - 0.000_001)

        // …and the legacy path is the thing that regresses, which is why this fix exists.
        let legacyBefore = Calories.dailyEstimate(hrSamples: morning, steps: 3_000, profile: profile)
        let legacyAfter = Calories.dailyEstimate(hrSamples: morning + spots, steps: 3_000,
                                                 profile: profile)
        XCTAssertLessThan(legacyAfter.activeKcal, legacyBefore.activeKcal)
    }

    // MARK: Invariants

    func testBucketsSumToTheDayTotal() {
        let hr = bout(fromHour: 7, minutes: 25, bpm: 128) + bout(fromHour: 18, minutes: 15, bpm: 104)
        let windows = [steps(1_800, fromHour: 7, minutes: 25),
                       steps(4_200, fromHour: 12, minutes: 90),
                       steps(1_500, fromHour: 18, minutes: 15)]
        let e = Calories.dailyEstimate(hrSamples: hr, steps: 7_500, profile: profile,
                                       stepWindows: windows, dayStart: day)
        XCTAssertEqual(e.buckets.reduce(0) { $0 + $1.activeKcal }, e.activeKcal, accuracy: 1e-9)
    }

    /// The bucket grid is PLACEMENT metadata. If the width moved the total, every user's Move ring
    /// would depend on a constant we picked.
    func testDayTotalIsInvariantToBucketWidth() {
        let hr = bout(fromHour: 9, minutes: 12, bpm: 130) + bout(fromHour: 17, minutes: 8, bpm: 96)
        let windows = [steps(900, fromHour: 9, minutes: 12),
                       steps(5_000, fromHour: 10, minutes: 300),
                       steps(700, fromHour: 17, minutes: 8)]

        let widths: [TimeInterval] = [5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60]
        let totals = widths.map { w in
            Calories.dailyEstimate(hrSamples: hr, steps: 6_600, profile: profile,
                                   stepWindows: windows, dayStart: day, bucketSeconds: w).activeKcal
        }
        for total in totals.dropFirst() {
            XCTAssertEqual(total, totals[0], accuracy: 1e-6)
        }
    }

    func testBucketsAreChronologicalAndNonOverlapping() {
        let hr = bout(fromHour: 6, minutes: 10, bpm: 120)
        let windows = [steps(3_000, fromHour: 6, minutes: 200)]
        let e = Calories.dailyEstimate(hrSamples: hr, steps: 3_000, profile: profile,
                                       stepWindows: windows, dayStart: day)
        XCTAssertFalse(e.buckets.isEmpty)
        for (a, b) in zip(e.buckets, e.buckets.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start)
        }
    }

    // MARK: Overlap netting

    /// A walk that raised heart rate must be paid ONCE — by whichever channel valued it higher,
    /// not by both.
    func testWalkInsideABoutIsPaidOnce() {
        let hr = bout(fromHour: 10, minutes: 20, bpm: 125)
        let windows = [steps(2_200, fromHour: 10, minutes: 20)]   // entirely inside the bout
        let e = Calories.dailyEstimate(hrSamples: hr, steps: 2_200, profile: profile,
                                       stepWindows: windows, dayStart: day)

        let hrOnly = Calories.workoutActiveKcal(avgHR: 125, durationSeconds: 20 * 60,
                                                profile: profile)
        let stepOnly = Calories.activeKcalFromSteps(steps: 2_200, profile: profile)
        XCTAssertGreaterThan(hrOnly, stepOnly, "precondition: HR is the richer channel here")
        XCTAssertEqual(e.activeKcal, hrOnly, accuracy: 0.001)
        XCTAssertEqual(e.buckets.reduce(0) { $0 + $1.stepKcal }, 0, accuracy: 0.001)
    }

    /// …and where the step channel values a slice higher, the excess IS credited.
    func testStepExcessOverElevatedTimeIsCredited() {
        let hr = bout(fromHour: 10, minutes: 5, bpm: 93)          // barely over the gate
        let windows = [steps(4_000, fromHour: 10, minutes: 5)]    // a lot of walking, 5 min
        let e = Calories.dailyEstimate(hrSamples: hr, steps: 4_000, profile: profile,
                                       stepWindows: windows, dayStart: day)

        let hrOnly = Calories.workoutActiveKcal(avgHR: 93, durationSeconds: 5 * 60, profile: profile)
        let stepOnly = Calories.activeKcalFromSteps(steps: 4_000, profile: profile)
        XCTAssertGreaterThan(stepOnly, hrOnly, "precondition: steps are the richer channel here")
        XCTAssertEqual(e.activeKcal, stepOnly, accuracy: 0.001)
    }

    // MARK: Byte-identical degrade

    func testDegradesToLegacyWithoutDayStart() {
        let hr = bout(fromHour: 8, minutes: 20, bpm: 118)
        let windows = [steps(2_000, fromHour: 8, minutes: 20)]
        let e = Calories.dailyEstimate(hrSamples: hr, steps: 2_000, profile: profile,
                                       stepWindows: windows)
        let legacy = Calories.legacyDailyEstimate(hrSamples: hr, steps: 2_000, profile: profile)
        XCTAssertTrue(e.buckets.isEmpty)
        XCTAssertEqual(e.activeKcal, legacy.activeKcal, accuracy: 1e-9)
    }

    /// A day with steps but no per-snapshot history (rows predating `StoredStepSample`) must NOT
    /// be attributed — otherwise it would silently under-report by the steps it cannot place.
    func testDegradesToLegacyWhenStepsExistWithoutWindows() {
        let hr = bout(fromHour: 8, minutes: 20, bpm: 118)
        let e = Calories.dailyEstimate(hrSamples: hr, steps: 9_000, profile: profile,
                                       stepWindows: [], dayStart: day)
        let legacy = Calories.legacyDailyEstimate(hrSamples: hr, steps: 9_000, profile: profile)
        XCTAssertTrue(e.buckets.isEmpty)
        XCTAssertEqual(e.activeKcal, legacy.activeKcal, accuracy: 1e-9)
    }

    /// Steps-only days keep their exact pre-attribution value — the existing
    /// `testDailyEstimateFallsBackToStepsWithoutQualifyingHR` contract, now via buckets.
    func testStepsOnlyDayMatchesLegacyExactly() {
        let low = [HRSample(bpm: 70, start: at(9))]
        let windows = [steps(5_000, fromHour: 9, minutes: 240)]
        let e = Calories.dailyEstimate(hrSamples: low, steps: 5_000, profile: profile,
                                       stepWindows: windows, dayStart: day)
        XCTAssertEqual(e.elevatedMinutes, 0)
        XCTAssertEqual(e.activeKcal,
                       Calories.activeKcalFromSteps(steps: 5_000, profile: profile),
                       accuracy: 1e-6)
    }

    // MARK: Accounting details

    /// Steps are prorated on METRES. Splitting the Int step count at a bucket edge would truncate
    /// and quietly lose steps on every boundary crossing.
    func testStepWindowSpanningManyBucketsLosesNoEnergy() {
        // 999 steps (odd, to expose Int truncation) over 2 hours = 8 fifteen-minute buckets.
        let windows = [steps(999, fromHour: 9, minutes: 120)]
        let e = Calories.dailyEstimate(hrSamples: [], steps: 999, profile: profile,
                                       stepWindows: windows, dayStart: day)
        XCTAssertEqual(e.activeKcal,
                       Calories.activeKcalFromSteps(steps: 999, profile: profile),
                       accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(e.buckets.count, 8)
    }

    /// Steps the daily counter reports but no snapshot placed in time still get credited — and
    /// NOT at midnight, which is the mis-placement this whole change exists to end.
    func testUnplacedStepsAreCreditedAtTheEarliestActivityNotMidnight() {
        let windows = [steps(1_000, fromHour: 16, minutes: 30)]
        let e = Calories.dailyEstimate(hrSamples: [], steps: 3_000, profile: profile,
                                       stepWindows: windows, dayStart: day)
        XCTAssertEqual(e.activeKcal,
                       Calories.activeKcalFromSteps(steps: 3_000, profile: profile),
                       accuracy: 1e-9)
        XCTAssertEqual(e.buckets.first?.start, at(16))
    }

    /// A snapshot whose window opened before midnight holds steps from BOTH days. Its delta is
    /// prorated by time, so only the in-day share is placed — and nothing lands before midnight.
    /// The day's own step counter (which resets at midnight) remains authoritative for the total.
    func testWindowStraddlingMidnightPlacesOnlyItsInDayShare() {
        let straddling = StepWindow(start: at(-1), end: at(1), delta: 600)  // half before midnight
        let e = Calories.dailyEstimate(hrSamples: [], steps: 300, profile: profile,
                                       stepWindows: [straddling], dayStart: day)
        XCTAssertEqual(e.activeKcal,
                       Calories.activeKcalFromSteps(steps: 300, profile: profile),
                       accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(e.buckets.first?.start ?? .distantPast, day)
    }

    /// The daily step counter is the source of truth for HOW MANY; the snapshots only say WHEN.
    /// If the ring's rollup reports more than the snapshots placed, the difference is still paid.
    func testDailyStepScalarRemainsAuthoritativeOverTheSnapshots() {
        let straddling = StepWindow(start: at(-1), end: at(1), delta: 600)
        let e = Calories.dailyEstimate(hrSamples: [], steps: 600, profile: profile,
                                       stepWindows: [straddling], dayStart: day)
        XCTAssertEqual(e.activeKcal,
                       Calories.activeKcalFromSteps(steps: 600, profile: profile),
                       accuracy: 0.01)
    }

    func testSleepWindowHRIsStillExcluded() {
        let asleep = bout(fromHour: 2, minutes: 20, bpm: 120)
        let sleep = DateInterval(start: at(0), end: at(6))
        let e = Calories.dailyEstimate(hrSamples: asleep, steps: 0, profile: profile,
                                       sleepWindow: sleep, dayStart: day)
        XCTAssertEqual(e.elevatedMinutes, 0)
        XCTAssertEqual(e.activeKcal, 0, accuracy: 1e-9)
    }
}

/// `ExerciseMinutes.elevatedPieces` — the per-slice decomposition `estimate` is now defined on.
/// The Apple Exercise ring reads `estimate`, so the anti-drift invariant here is load-bearing.
final class ElevatedPiecesTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_753_660_800)
    private func at(_ seconds: Double) -> Date { day.addingTimeInterval(seconds) }

    /// The invariant: total piece duration IS the exercise-minutes scalar. If these ever diverge,
    /// the energy model and the Exercise ring are pricing different days.
    func testPieceDurationAlwaysEqualsTheMinutesScalar() {
        let cases: [[HRSample]] = [
            [],
            [HRSample(bpm: 120, start: at(0))],                                   // isolated point
            (0 ..< 6).map { HRSample(bpm: 120, start: at(Double($0) * 150)) },    // a run
            [HRSample(bpm: 130, start: at(0), end: at(600)),                      // spans + points
             HRSample(bpm: 125, start: at(300)),
             HRSample(bpm: 118, start: at(450)),
             HRSample(bpm: 99, start: at(5_000))],
            [HRSample(bpm: 140, start: at(0), end: at(300)),                      // nested
             HRSample(bpm: 100, start: at(60), end: at(120))],
            [HRSample(bpm: 95, start: at(900), end: at(1_200)),                   // out of order
             HRSample(bpm: 145, start: at(0), end: at(600))],
        ]
        for samples in cases {
            let pieces = ExerciseMinutes.elevatedPieces(hrSamples: samples, maxHR: 185)
            let scalar = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 185)
            XCTAssertEqual(pieces.reduce(0) { $0 + $1.seconds } / 60.0, scalar, accuracy: 1e-9)
        }
    }

    func testPiecesAreDisjointAndOrdered() {
        let samples = [HRSample(bpm: 140, start: at(0), end: at(600)),
                       HRSample(bpm: 100, start: at(300), end: at(900)),
                       HRSample(bpm: 130, start: at(1_800), end: at(2_000))]
        let pieces = ExerciseMinutes.elevatedPieces(hrSamples: samples, maxHR: 185)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start)
        }
        // The overlap goes to the EARLIER sample, so nothing is double-counted.
        XCTAssertEqual(pieces.first?.bpm, 140)
        XCTAssertEqual(pieces[1].start, at(600))
    }

    func testIsolatedPointSampleStillEarnsNoTime() {
        let pieces = ExerciseMinutes.elevatedPieces(
            hrSamples: [HRSample(bpm: 150, start: at(0))], maxHR: 185)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.seconds }, 0)
    }

    func testConsecutivePointSamplesEachEarnAnEpoch() {
        let samples = (0 ..< 3).map { HRSample(bpm: 120, start: at(Double($0) * 150)) }
        let pieces = ExerciseMinutes.elevatedPieces(hrSamples: samples, maxHR: 185)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.seconds }, 450, accuracy: 1e-9)
        XCTAssertEqual(pieces.map(\.bpm), [120, 120, 120])
    }
}
