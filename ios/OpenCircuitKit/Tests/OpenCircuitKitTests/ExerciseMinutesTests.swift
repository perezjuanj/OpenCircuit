import XCTest
@testable import OpenCircuitKit

final class ExerciseMinutesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    // MARK: Threshold

    func testThresholdHalf() {
        // maxHR 180 → threshold = 90 bpm
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 180), 90)
    }

    func testThresholdMinimumClamp() {
        // maxHR 60 → 50% = 30 < 60 → clamped to 60
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 60), 60)
    }

    func testThresholdAtAge35() {
        // maxHR = 220 - 35 = 185 → 50% = 92
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 185), 92)
    }

    // MARK: Heart-rate-reserve threshold

    /// The reported defect, as arithmetic. At age 35 the old model gives 92 bpm to everyone. Under
    /// HRR the person who rests at 78 gets 121 and the person who rests at 45 gets 101 — each 40 %
    /// of the way up their OWN range, which is what "moderate intensity" means.
    func testThresholdIsRelativeToRestingHR() {
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 185, restingHR: 78), 78 + Int(0.4 * 107))
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 185, restingHR: 45), 45 + Int(0.4 * 140))
        XCTAssertGreaterThan(ExerciseMinutes.threshold(maxHR: 185, restingHR: 78),
                             ExerciseMinutes.threshold(maxHR: 185, restingHR: 45),
                             "a faster resting pulse must demand a faster elevated pulse")
    }

    /// nil resting HR is the kill-switch: byte-identical to the pre-HRR model.
    func testThresholdWithoutRestingHRIsTheOriginalModel() {
        for maxHR in [60, 120, 180, 185, 200] {
            XCTAssertEqual(ExerciseMinutes.threshold(maxHR: maxHR, restingHR: nil),
                           max(Int(Double(maxHR) * 0.5), 60))
        }
    }

    /// An implausible or impossible resting HR must degrade to the %-of-max model rather than
    /// produce a threshold nobody can reach.
    func testThresholdRejectsImplausibleRestingHR() {
        let fallback = ExerciseMinutes.threshold(maxHR: 185)
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 185, restingHR: 20), fallback)
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 185, restingHR: 140), fallback)
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 100, restingHR: 120), fallback == 60 ? 60
                       : ExerciseMinutes.threshold(maxHR: 100),
                       "restingHR above maxHR is nonsense → fall back")
    }

    func testThresholdKeepsTheAbsoluteFloor() {
        // A very low max HR with a low resting HR still cannot drop the bar under 60 bpm.
        XCTAssertEqual(ExerciseMinutes.threshold(maxHR: 60, restingHR: 40), 60)
    }

    // MARK: Derived resting baseline

    /// A day's worth of readings with a genuine quiet stretch yields that stretch as the baseline.
    func testRestingBaselineFindsTheQuietStretch() {
        var samples: [HRSample] = []
        for i in 0 ..< 120 {                                   // 5 h of 2.5-min epochs
            let bpm = i < 60 ? 52 : 95                         // quiet first, active after
            samples.append(HRSample(bpm: bpm, start: t0.addingTimeInterval(Double(i) * 150)))
        }
        XCTAssertEqual(ExerciseMinutes.restingBaseline(samples)!, 52, accuracy: 1e-9)
    }

    /// The failure that a fixture caught when this landed: three readings taken during exertion
    /// have no rest in them, so `lowestSustained` would report ~100 as a "resting" HR and push the
    /// threshold to 134. Too few readings over too short a span ⇒ no baseline.
    func testRestingBaselineRefusesAThinOrShortSampleSet() {
        let workout = [HRSample(bpm: 140, start: t0),
                       HRSample(bpm: 100, start: t0.addingTimeInterval(300)),
                       HRSample(bpm: 130, start: t0.addingTimeInterval(1_800))]
        XCTAssertNil(ExerciseMinutes.restingBaseline(workout), "3 readings is not a day")

        // Enough readings, but packed into 30 minutes — still no evidence of rest.
        let dense = (0 ..< 20).map { HRSample(bpm: 120, start: t0.addingTimeInterval(Double($0) * 90)) }
        XCTAssertNil(ExerciseMinutes.restingBaseline(dense), "30 min span is not a day")
    }

    /// A long day that genuinely never rests must also decline rather than invent a high baseline.
    func testRestingBaselineRefusesAnImplausiblyHighQuietStretch() {
        let busy = (0 ..< 200).map {
            HRSample(bpm: 110, start: t0.addingTimeInterval(Double($0) * 150))   // 8 h, never quiet
        }
        XCTAssertNil(ExerciseMinutes.restingBaseline(busy))
    }

    // MARK: The reported symptom — the ring filling from ordinary morning activity

    /// A high-resting-HR wearer's morning: 6 h of night at 72 bpm, then 40 min of ordinary
    /// ambulation at 96 bpm. Under the old absolute 92-bpm bar every one of those epochs counted
    /// and the 30-min ring was full before breakfast; under HRR (72 → 117 bpm) none of it does.
    func testOrdinaryMorningActivityNoLongerFillsTheRingForAHighRestingHRWearer() {
        let sleepEnd = t0.addingTimeInterval(6 * 3600)
        var samples: [HRSample] = []
        for i in 0 ..< 144 {                                   // 6 h asleep
            samples.append(HRSample(bpm: 72, start: t0.addingTimeInterval(Double(i) * 150)))
        }
        for i in 1 ... 16 {                                    // 40 min pottering about
            samples.append(HRSample(bpm: 96, start: sleepEnd.addingTimeInterval(Double(i) * 150)))
        }
        let window = DateInterval(start: t0, end: sleepEnd)

        let old = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 185,
                                           sleepWindow: window, deriveRestingHR: false)
        XCTAssertEqual(old, 40, accuracy: 1e-9,
                       "the old absolute 92-bpm bar filled a 30-min goal from this alone")

        let new = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 185, sleepWindow: window)
        XCTAssertEqual(new, 0, accuracy: 1e-9,
                       "96 bpm is 22 bpm above a 72-bpm rest — not moderate exertion")
    }

    /// …and real exertion by the same wearer still counts, so the gate is not simply "off".
    func testRealExertionStillCountsForAHighRestingHRWearer() {
        let sleepEnd = t0.addingTimeInterval(6 * 3600)
        var samples: [HRSample] = []
        for i in 0 ..< 144 {
            samples.append(HRSample(bpm: 72, start: t0.addingTimeInterval(Double(i) * 150)))
        }
        for i in 1 ... 12 {                                    // 30 min of genuine effort
            samples.append(HRSample(bpm: 135, start: sleepEnd.addingTimeInterval(Double(i) * 150)))
        }
        let minutes = ExerciseMinutes.estimate(
            hrSamples: samples, maxHR: 185,
            sleepWindow: DateInterval(start: t0, end: sleepEnd))
        XCTAssertEqual(minutes, 30, accuracy: 1e-9)
    }

    /// The invariant the Goals footnote promises the user: whatever periods the minutes ring counts
    /// are exactly the periods the calorie estimate prices. `elevatedPieces` must derive the same
    /// baseline `Calories` re-derives from the same samples.
    func testMinutesAndCaloriesShareOneQualifyingSet() {
        let sleepEnd = t0.addingTimeInterval(6 * 3600)
        var samples: [HRSample] = []
        for i in 0 ..< 144 {
            samples.append(HRSample(bpm: 70, start: t0.addingTimeInterval(Double(i) * 150)))
        }
        for i in 0 ..< 24 {
            samples.append(HRSample(bpm: 130, start: sleepEnd.addingTimeInterval(Double(i) * 150)))
        }
        let derived = ExerciseMinutes.restingBaseline(samples)
        XCTAssertNotNil(derived)
        let thresh = ExerciseMinutes.threshold(maxHR: 185, restingHR: derived)
        let pieces = ExerciseMinutes.elevatedPieces(hrSamples: samples, maxHR: 185,
                                                    sleepWindow: DateInterval(start: t0, end: sleepEnd))
        XCTAssertFalse(pieces.isEmpty)
        for p in pieces {
            XCTAssertGreaterThanOrEqual(p.bpm, thresh,
                                        "a piece priced by calories must clear the same bar")
        }
    }

    // MARK: Empty / below threshold

    func testNoSamplesReturnsZero() {
        XCTAssertEqual(ExerciseMinutes.estimate(hrSamples: [], maxHR: 180), 0)
    }

    func testAllBelowThresholdReturnsZero() {
        let samples = [60, 70, 80].map { bpm in
            HRSample(bpm: bpm, start: t0, end: t0)
        }
        XCTAssertEqual(ExerciseMinutes.estimate(hrSamples: samples, maxHR: 180), 0)
    }

    // MARK: Basic elevated estimate

    func testSingleIsolatedPointSampleGivesNoFullEpoch() {
        // One ISOLATED elevated point read (e.g. a single live-HR spot read) must NOT be
        // credited a full 2.5-min epoch — a lone spot read isn't evidence of exercise (#82 fix).
        let s = HRSample(bpm: 100, start: t0, end: t0)
        let minutes = ExerciseMinutes.estimate(hrSamples: [s], maxHR: 180,
                                               epochSeconds: 150)
        XCTAssertEqual(minutes, 0, accuracy: 0.01)
    }

    func testIsolatedPointSampleHonorsCustomWidth() {
        // An isolated point read gets the caller-supplied small width, not a full epoch.
        let s = HRSample(bpm: 100, start: t0, end: t0)
        let minutes = ExerciseMinutes.estimate(hrSamples: [s], maxHR: 180,
                                               epochSeconds: 150, pointSampleWidth: 30)
        XCTAssertEqual(minutes, 0.5, accuracy: 0.01)   // 30 s
    }

    func testTwoConsecutivePointsCountAsSustained() {
        // Two point reads within one epoch ⇒ a sustained run ⇒ each gets a full epoch.
        let epoch: TimeInterval = 150
        let samples = [0, 150].map { offset in
            HRSample(bpm: 100, start: t0.addingTimeInterval(Double(offset)), end: t0.addingTimeInterval(Double(offset)))
        }
        let minutes = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 180, epochSeconds: epoch)
        // [0,150) + [150,300) → merged [0,300] = 5 min
        XCTAssertEqual(minutes, 5.0, accuracy: 0.01)
    }

    func testThreeConsecutiveEpochs() {
        // Three point samples at t=0, 150, 300 → consecutive run → merges to [0, 450s] = 7.5 min.
        // Bulk-epoch behavior is preserved: back-to-back elevated epochs still count in full.
        let epoch: TimeInterval = 150
        let samples = [0, 150, 300].map { offset in
            HRSample(bpm: 100, start: t0.addingTimeInterval(Double(offset)), end: t0.addingTimeInterval(Double(offset)))
        }
        let minutes = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 180, epochSeconds: epoch)
        // intervals: [0,150), [150,300), [300,450) → merged: [0, 450] = 7.5 min
        XCTAssertEqual(minutes, 7.5, accuracy: 0.01)
    }

    func testGapBetweenElevatedRuns() {
        // Two separate sustained runs (each ≥2 consecutive points) split by a 10-min gap stay
        // as two intervals; isolated reads within neither run do not inflate the total.
        let epoch: TimeInterval = 150
        func run(at base: Double) -> [HRSample] {
            [base, base + 150].map { HRSample(bpm: 100, start: t0.addingTimeInterval($0), end: t0.addingTimeInterval($0)) }
        }
        let samples = run(at: 0) + run(at: 1200)
        let minutes = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 180, epochSeconds: epoch)
        // Two separate [x, x+300] runs = 5 min + 5 min = 10 min
        XCTAssertEqual(minutes, 10.0, accuracy: 0.01)
    }

    func testSampleWithRealDurationIsUsed() {
        // A sample spanning 5 minutes — its real duration should be used, not epochSeconds
        let end = t0.addingTimeInterval(5 * 60)
        let s = HRSample(bpm: 100, start: t0, end: end)
        let minutes = ExerciseMinutes.estimate(hrSamples: [s], maxHR: 180, epochSeconds: 150)
        XCTAssertEqual(minutes, 5.0, accuracy: 0.01)
    }

    // MARK: Sleep-window exclusion

    func testSleepWindowExcludesElevatedHR() {
        // Elevated HR samples during sleep → excluded; a sustained awake run → counted.
        let epoch: TimeInterval = 150
        let sleep = DateInterval(start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(3600))
        // Inside sleep window (elevated but sleeping) — two consecutive, all excluded.
        let sleeping = [0.0, 150.0].map { HRSample(bpm: 100, start: t0.addingTimeInterval($0), end: t0.addingTimeInterval($0)) }
        // Outside sleep window (elevated and awake) — a sustained run of two.
        let awake = [7200.0, 7350.0].map { HRSample(bpm: 100, start: t0.addingTimeInterval($0), end: t0.addingTimeInterval($0)) }

        let minutes = ExerciseMinutes.estimate(hrSamples: sleeping + awake, maxHR: 180,
                                               sleepWindow: sleep, epochSeconds: epoch)
        // Only the awake run counted: [7200,7500] = 5 min
        XCTAssertEqual(minutes, 5.0, accuracy: 0.01)
    }

    func testNoExclusionWhenNoSleepWindow() {
        let epoch: TimeInterval = 150
        let samples = [0.0, 150.0].map { HRSample(bpm: 100, start: t0.addingTimeInterval($0), end: t0.addingTimeInterval($0)) }
        let minutes = ExerciseMinutes.estimate(hrSamples: samples, maxHR: 180,
                                               sleepWindow: nil, epochSeconds: epoch)
        XCTAssertEqual(minutes, 5.0, accuracy: 0.01)
    }

    // MARK: Interval merging

    func testOverlappingIntervalsAreMerged() {
        // Two overlapping real-duration samples → merged to one interval
        let s1 = HRSample(bpm: 100,
                          start: t0,
                          end: t0.addingTimeInterval(300))   // 5 min
        let s2 = HRSample(bpm: 110,
                          start: t0.addingTimeInterval(200), // overlaps
                          end: t0.addingTimeInterval(600))   // extends to 10 min
        let minutes = ExerciseMinutes.estimate(hrSamples: [s1, s2], maxHR: 180, epochSeconds: 150)
        // Merged: [0, 600s] = 10 min
        XCTAssertEqual(minutes, 10.0, accuracy: 0.01)
    }
}
