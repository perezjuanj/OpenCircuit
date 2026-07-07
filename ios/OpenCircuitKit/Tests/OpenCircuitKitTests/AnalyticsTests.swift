import XCTest
@testable import OpenCircuitKit

// Parity tests for the analytics ported from openwhoop-algos. The RR vectors and
// assertions mirror openwhoop's own Rust unit tests so the Swift port is provably
// equivalent. Runs under `swift test` once Xcode is the active toolchain.
final class AnalyticsTests: XCTestCase {

    // MARK: HRV / RMSSD (sleep.rs)

    func testRMSSD() {
        XCTAssertEqual(HRV.rmssd([800, 900, 1000]), 100)  // diffs 100,100 -> 100
        XCTAssertNil(HRV.rmssd([800]))
    }

    func testCleanRR() {
        XCTAssertEqual(HRV.cleanRR([[800, 900], [1000], []]), [800, 900, 1000])
        XCTAssertEqual(HRV.cleanRR([[0, 900], [0]]), [900])
    }

    // MARK: Stress — Baevsky index (stress.rs)

    func testStressConstantRRReturnsMax() {
        XCTAssertEqual(Stress.index(rr: Array(repeating: 750, count: 120)), 10.0)
    }

    func testStressModerateVariability() {
        let rr = [667, 674, 682, 690, 682, 652, 638, 632, 625, 619, 612, 619, 606, 594, 583,
                  577, 566, 561, 561, 556, 556, 550, 556, 556, 556, 556, 550, 550, 545, 541,
                  531, 531, 531, 531, 531, 536, 541, 545, 550, 556, 561, 566, 571, 577, 577,
                  583, 583, 583, 588, 594, 594, 600, 600, 600, 600, 594, 600, 612, 619, 625,
                  632, 632, 632, 625, 625, 619, 619, 619, 612, 606, 594, 600, 600, 600, 600,
                  606, 606, 606, 606, 600, 606, 612, 612, 612, 612, 612, 612, 612, 612, 619,
                  612, 612, 612, 619, 619, 625, 625, 625, 632, 638, 645, 645, 638, 638, 632,
                  625, 625, 625, 625, 632, 638, 632, 632, 625, 625, 625, 625, 625, 619, 612]
        let score = Stress.index(rr: rr)
        XCTAssertGreaterThan(score, 0.0)
        XCTAssertLessThanOrEqual(score, 10.0)
    }

    func testStressLowVariability() {
        let rr = [1000, 984, 1017, 1017, 1017, 1017, 1017, 1000, 1000, 1000, 1000, 1000, 984,
                  984, 984, 984, 984, 984, 984, 984, 952, 952, 952, 952, 938, 952, 952, 952,
                  968, 968, 968, 968, 984, 984, 984, 984, 968, 968, 968, 968, 968, 968, 968,
                  968, 968, 968, 968, 968, 968, 968, 968, 968, 968, 952, 952, 952, 952, 952,
                  952, 952, 938, 938, 938, 938, 938, 923, 923, 938, 938, 938, 938, 938, 938,
                  938, 938, 938, 938, 938, 938, 923, 923, 923, 938, 938, 952, 952, 952, 952,
                  968, 968, 968, 984, 984, 984, 984, 968, 968, 968, 984, 984, 984, 984, 968,
                  968, 968, 968, 968, 952, 952, 952, 952, 938, 952, 952, 952, 968, 968, 952,
                  952, 952]
        XCTAssertGreaterThan(Stress.index(rr: rr), 0.0)
    }

    // MARK: Strain — Edwards TRIMP (strain.rs)

    func testStrainTooFewReadingsIsNil() {
        XCTAssertNil(Strain(maxHR: 200, restingHR: 60).calculate(bpms: Array(repeating: 80, count: 500)))
    }

    func testStrainInvalidHRParamsIsNil() {
        XCTAssertNil(Strain(maxHR: 60, restingHR: 60).calculate(bpms: Array(repeating: 80, count: 600)))
        XCTAssertNil(Strain(maxHR: 50, restingHR: 60).calculate(bpms: Array(repeating: 80, count: 600)))
    }

    func testRestingHRProducesZeroStrain() {
        XCTAssertEqual(Strain(maxHR: 190, restingHR: 60).calculate(bpms: Array(repeating: 65, count: 600)), 0.0)
    }

    func testHighHRProducesHighStrain() {
        let s = Strain(maxHR: 190, restingHR: 60).calculate(bpms: Array(repeating: 170, count: 1800))
        XCTAssertGreaterThan(s ?? 0, 10.0)
    }

    func testStrainCappedAt21() {
        XCTAssertEqual(Strain(maxHR: 190, restingHR: 60).calculate(bpms: Array(repeating: 190, count: 86400)), 21.0)
    }

    // MARK: Calories — Mifflin-St Jeor + TRIMP

    func testMaleBMRMifflinStJeor() {
        let profile = UserProfile(age: 30, weightKg: 80, heightCm: 180, sex: .male)
        XCTAssertEqual(Calories.bmrKcalPerDay(profile: profile), 1780.0, accuracy: 0.001)
        XCTAssertEqual(Calories.bmrKcalPerHour(profile: profile), 74.166_666, accuracy: 0.001)
    }

    func testFemaleBMRMifflinStJeor() {
        let profile = UserProfile(age: 40, weightKg: 65, heightCm: 165, sex: .female)
        XCTAssertEqual(Calories.bmrKcalPerDay(profile: profile), 1320.25, accuracy: 0.001)
    }

    // MARK: Resting-HR–adjusted basal energy (#dynamic-resting-calories)

    private static let male30 = UserProfile(age: 30, weightKg: 80, heightCm: 180, sex: .male)

    func testRestingBaselineNilBelowMinDays() throws {
        // Two prior days is below the 3-day minimum → no trusted baseline.
        XCTAssertNil(Calories.restingBaselineBpm(prior: [60, 62]))
        // Three days → mean.
        XCTAssertEqual(try XCTUnwrap(Calories.restingBaselineBpm(prior: [58, 60, 62])), 60, accuracy: 1e-9)
    }

    func testRestingScaleNoChangeWithoutInputs() {
        // Missing RHR or baseline ⇒ neutral 1.0 (caller degrades to static BMR).
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: nil, baselineRestingHR: 60), 1.0)
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: 70, baselineRestingHR: nil), 1.0)
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: 70, baselineRestingHR: 0), 1.0)
        // On-baseline RHR ⇒ no change.
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: 60, baselineRestingHR: 60), 1.0, accuracy: 1e-9)
    }

    func testRestingScaleMovesWithDeviation() {
        // +8 bpm over baseline ⇒ +8% at 1%/bpm; −5 ⇒ −5%.
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: 68, baselineRestingHR: 60), 1.08, accuracy: 1e-9)
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: 55, baselineRestingHR: 60), 0.95, accuracy: 1e-9)
    }

    func testRestingScaleClampedBothWays() {
        // A garbage/extreme RHR can't push basal energy past ±20%.
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: 200, baselineRestingHR: 60), 1.20, accuracy: 1e-9)
        XCTAssertEqual(Calories.restingEnergyScale(restingHR: 10, baselineRestingHR: 60), 0.80, accuracy: 1e-9)
    }

    func testBasalKcalPerHourFallsBackToStatic() {
        // No RHR/baseline ⇒ exactly the static per-hour BMR (no regression, never zero).
        XCTAssertEqual(Calories.basalKcalPerHour(profile: Self.male30),
                       Calories.bmrKcalPerHour(profile: Self.male30), accuracy: 1e-9)
    }

    func testBasalKcalPerHourVariesWithMeasuredRHR() {
        let base = Calories.bmrKcalPerHour(profile: Self.male30)   // 74.1666…
        let elevated = Calories.basalKcalPerHour(profile: Self.male30, restingHR: 70, baselineRestingHR: 60)
        let lowered = Calories.basalKcalPerHour(profile: Self.male30, restingHR: 55, baselineRestingHR: 60)
        XCTAssertEqual(elevated, base * 1.10, accuracy: 1e-9)   // +10 bpm ⇒ +10%
        XCTAssertEqual(lowered, base * 0.95, accuracy: 1e-9)    // −5 bpm ⇒ −5%
        XCTAssertGreaterThan(elevated, base)
        XCTAssertLessThan(lowered, base)
    }

    func testActiveCaloriesFromEdwardsTRIMP() {
        let start = Date(timeIntervalSince1970: 0)
        let samples = (0..<600).map { offset in
            HRSample(
                bpm: 150,
                start: start.addingTimeInterval(Double(offset)),
                end: start.addingTimeInterval(Double(offset + 1))
            )
        }
        // maxHR 180, restingHR 60, bpm 150 => 75% HRR => zone weight 3.
        // 600 one-second samples = 10 min, TRIMP = 30, kcal = 150.
        XCTAssertEqual(Calories.activeKcal(hrSamples: samples, maxHR: 180), 150.0, accuracy: 0.001)
    }

    // Step/distance-derived active-energy ESTIMATE (the "0 active calories" fix): a day with
    // walking, or a workout whose HR never locked, still reports honest active calories instead
    // of 0 — derived (not a sensor reading), labeled an estimate at every write/display site.
    func testActiveKcalFromDistance() {
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 180, sex: .male)
        // 2 km × 70 kg × 0.5 kcal·kg⁻¹·km⁻¹ = 70 kcal.
        XCTAssertEqual(Calories.activeKcalFromDistance(meters: 2000, profile: profile), 70.0, accuracy: 0.001)
        XCTAssertEqual(Calories.activeKcalFromDistance(meters: 0, profile: profile), 0.0, accuracy: 0.001)
        XCTAssertEqual(Calories.activeKcalFromDistance(meters: -5, profile: profile), 0.0, accuracy: 0.001)
    }

    func testActiveKcalFromStepsNonZeroForWalk() {
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 180, sex: .male)
        let kcal = Calories.activeKcalFromSteps(steps: 5_000, profile: profile)
        let expectedKm = DistanceEstimate.meters(steps: 5_000) / 1000.0
        XCTAssertEqual(kcal, expectedKm * 70 * 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(kcal, 0, "a 5000-step walk must yield nonzero active calories")
        XCTAssertEqual(Calories.activeKcalFromSteps(steps: 0, profile: profile), 0.0, accuracy: 0.001)
    }

    // MARK: Trimmed-mean baseline robustness (#172 review, fix #4)

    func testRestingBaselineTrimmedMeanResistsOutlier() throws {
        // 10 days at ~60 bpm with one outlier at 100. Plain mean would be ~64; trimmed mean
        // drops the outlier and the lowest, yielding ~60.
        let prior: [Double] = [59, 60, 60, 61, 60, 59, 61, 60, 60, 100]
        let baseline = try XCTUnwrap(Calories.restingBaselineBpm(prior: prior))
        XCTAssertEqual(baseline, 60, accuracy: 1.0,
                       "trimmed mean resists a single outlier day")
    }

    func testRestingBaselineTrimmedMeanSmallWindow() throws {
        // Below minTrimmedBaselineDays (5) we do NOT trim: trimming a thin window collapses the
        // baseline toward a single median day (n=3 → the middle value alone), so we take the plain
        // mean of every prior day instead. These assertions pin the ACTUAL small-window behavior.

        // n=3, skewed: plain mean (72.33…), NOT the median (59). Proves it isn't collapsing to
        // sorted[1] the way the pre-fix 1-in/1-out trim did.
        XCTAssertEqual(try XCTUnwrap(Calories.restingBaselineBpm(prior: [58, 59, 100])),
                       (58 + 59 + 100) / 3.0, accuracy: 1e-9)
        // n=3, symmetric: mean == median here, both 60.
        XCTAssertEqual(try XCTUnwrap(Calories.restingBaselineBpm(prior: [58, 60, 62])),
                       60, accuracy: 1e-9)
        // n=4, skewed: plain mean of all four (65), NOT a trimmed-to-middle-two 60.
        XCTAssertEqual(try XCTUnwrap(Calories.restingBaselineBpm(prior: [50, 60, 60, 90])),
                       (50 + 60 + 60 + 90) / 4.0, accuracy: 1e-9)
        // n=5: trimming kicks in — drop one high + one low, mean the middle three.
        // [50, 59, 60, 61, 100] → drop 50 & 100 → mean(59, 60, 61) = 60, NOT the plain mean (66).
        XCTAssertEqual(try XCTUnwrap(Calories.restingBaselineBpm(prior: [50, 59, 60, 61, 100])),
                       60, accuracy: 1e-9)
    }

    // MARK: Integration — daily RHR → energy inputs → dynamic basal kcal (#172 review, fix #3)

    func testDailyRHRToBasalEnergyEndToEnd() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Synthesize 5 days of HR data: ~300 readings per day, each day at a different sustained
        // resting level. Day 0–3 baseline around 60 bpm; day 4 (today) elevated at 70 bpm.
        var allHR: [HRSample] = []
        for dayOffset in 0..<5 {
            guard let dayStart = cal.date(byAdding: .day, value: dayOffset - 4, to: today) else { continue }
            let bpm = dayOffset < 4 ? 60 : 70
            for minute in stride(from: 0, to: 300, by: 5) {
                let t = dayStart.addingTimeInterval(Double(minute * 60))
                allHR.append(HRSample(bpm: bpm, start: t, end: t.addingTimeInterval(60)))
            }
        }

        // Derive daily RHR WITHOUT sleep segments (the lowestSustained path for all days —
        // matches the fix for derivation parity, #172 review fix #1).
        let daily = RestingHR.dailyValues(hr: allHR, sleep: [], calendar: cal)
        XCTAssertEqual(daily.count, 5, "5 days of HR data → 5 daily RHR values")

        // All baseline days should be ~60 bpm (lowestSustained of constant 60).
        for d in daily.prefix(4) {
            XCTAssertEqual(d.bpm, 60, accuracy: 1,
                           "baseline day should derive ~60 bpm via lowestSustained")
        }
        // Today should be ~70 bpm.
        XCTAssertEqual(daily.last?.bpm ?? 0, 70, accuracy: 1,
                       "today should derive ~70 bpm via lowestSustained")

        // Verify the baseline uses the trimmed mean of prior days (all ~60 → trimmed mean ~60).
        let prior = daily.filter { $0.day < today }.map(\.bpm)
        let baseline = try XCTUnwrap(Calories.restingBaselineBpm(prior: prior))
        XCTAssertEqual(baseline, 60, accuracy: 1)

        // The scale factor for today: +10 bpm over 60 → +10%.
        let scale = Calories.restingEnergyScale(restingHR: 70, baselineRestingHR: baseline)
        XCTAssertEqual(scale, 1.10, accuracy: 0.02)

        // Dynamic basal energy should exceed static.
        let profile = Self.male30
        let dynamicKcal = Calories.basalKcalPerHour(profile: profile, restingHR: 70,
                                                     baselineRestingHR: baseline)
        let staticKcal = Calories.bmrKcalPerHour(profile: profile)
        XCTAssertGreaterThan(dynamicKcal, staticKcal,
                             "elevated RHR day should produce higher basal energy than static BMR")
    }

    func testDerivationParityWithoutSleep() {
        // Verify that omitting sleep segments gives ALL days the same derivation method
        // (lowestSustained), so the comparison today-vs-baseline is fair.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // Both days have the same HR pattern: readings at 60 bpm with a dip to 55.
        var hr: [HRSample] = []
        for dayStart in [yesterday, today] {
            for minute in stride(from: 0, to: 300, by: 5) {
                let t = dayStart.addingTimeInterval(Double(minute * 60))
                let bpm = minute < 30 ? 55 : 60
                hr.append(HRSample(bpm: bpm, start: t, end: t.addingTimeInterval(60)))
            }
        }

        // Sleep segments covering ONLY today's night.
        let sleepStart = today.addingTimeInterval(1 * 3600)
        let sleepEnd = today.addingTimeInterval(4 * 3600)
        let sleep = [SleepSegment(start: sleepStart, end: sleepEnd, stage: .asleepCore)]

        let withSleep = RestingHR.dailyValues(hr: hr, sleep: sleep, calendar: cal)
        let withoutSleep = RestingHR.dailyValues(hr: hr, sleep: [], calendar: cal)

        // Without sleep: both days should produce the same RHR (same HR pattern, same method).
        XCTAssertEqual(withoutSleep.count, 2)
        XCTAssertEqual(withoutSleep[0].bpm, withoutSleep[1].bpm, accuracy: 1e-9,
                       "without sleep, identical HR patterns yield identical daily RHR — no method offset")

        // With sleep: today may differ from yesterday (sleep-mean vs lowestSustained).
        // This is the bias the fix eliminates.
        if withSleep.count == 2 {
            let diff = abs(withSleep[0].bpm - withSleep[1].bpm)
            let noDiff = abs(withoutSleep[0].bpm - withoutSleep[1].bpm)
            XCTAssertLessThanOrEqual(noDiff, diff,
                                     "dropping sleep should not increase inter-day offset")
        }
    }

    // MARK: Sleep score (sleep.rs)

    func testSleepScore() {
        // #28: graded (floating-point ratio), not a 0-or-100 step function.
        XCTAssertEqual(SleepScore.score(durationSeconds: 8 * 3600), 100.0)
        XCTAssertEqual(SleepScore.score(durationSeconds: 6 * 3600), 75.0)
        XCTAssertEqual(SleepScore.score(durationSeconds: 4 * 3600), 50.0)
        XCTAssertEqual(SleepScore.score(durationSeconds: 0), 0.0)
        XCTAssertEqual(SleepScore.score(durationSeconds: 24 * 3600), 100.0)  // clamped at the ideal
    }
}
