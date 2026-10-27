import XCTest
@testable import OpenCircuitKit

/// Decision 83 (#338): one source of zone bounds, Zone 1…5 names, Automatic max HR unchanged.
final class HeartRateZonesTests: XCTestCase {

    private func zones(_ method: HeartRateZoneMethod = .percentOfMax, manual: Int? = nil,
                       custom: [Int] = HeartRateZoneSettings.defaultCustomLowerBounds,
                       age: Int = 30, resting: Double? = nil) -> HeartRateZones {
        HeartRateZones(settings: HeartRateZoneSettings(method: method, manualMaxHR: manual,
                                                        customLowerBounds: custom),
                       age: age, restingHR: resting)
    }

    // MARK: Bounds

    func testPercentOfMaxLowerBoundsAre50To90PercentRoundedUp() {
        XCTAssertEqual(zones(manual: 200).lowerBounds, [100, 120, 140, 160, 180])
        // 185: 92.5, 111, 129.5, 148, 166.5 round up
        XCTAssertEqual(zones(manual: 185).lowerBounds, [93, 111, 130, 148, 167])
    }

    func testPercentOfMaxIsTheDefaultMethodAndAutomaticMaxTheDefaultSource() {
        let z = HeartRateZones(settings: .standard, age: 30, restingHR: 50)
        XCTAssertEqual(z.method, .percentOfMax)
        XCTAssertEqual(z.maxHR, 190)
        XCTAssertTrue(z.maxHRIsAutomatic)
        XCTAssertEqual(z.lowerBounds, [95, 114, 133, 152, 171])
        XCTAssertNil(z.fallback)
    }

    func testPercentOfReserveLowerBoundsUseRestingHeartRate() {
        // max 190, rest 60, reserve 130: 60 + 65, 78, 91, 104, 117
        let z = zones(.percentOfReserve, manual: 190, resting: 60)
        XCTAssertEqual(z.lowerBounds, [125, 138, 151, 164, 177])
        XCTAssertEqual(z.method, .percentOfReserve)
        XCTAssertEqual(z.restingHR, 60)
        XCTAssertNil(z.fallback)
        XCTAssertNil(z.fallbackNote)
    }

    func testPercentOfReserveRoundsRestingToAWholeBpmAndBoundsUp() {
        // rest 60.4 -> 60; reserve 130 * 50 % = 65 -> 125 (no fractional carry)
        XCTAssertEqual(zones(.percentOfReserve, manual: 190, resting: 60.4).lowerBounds.first, 125)
        // max 185, rest 55, reserve 130: 55+65, 55+78, 55+91, 55+104, 55+117
        XCTAssertEqual(zones(.percentOfReserve, manual: 185, resting: 55).lowerBounds, [120, 133, 146, 159, 172])
        // reserve 131: 50 % = 65.5 -> 66
        XCTAssertEqual(zones(.percentOfReserve, manual: 191, resting: 60).lowerBounds.first, 126)
    }

    func testPercentOfReserveWithoutRestingHeartRateFallsBackToPercentOfMaxWithANote() {
        for resting in [nil, 0, -5, Double.nan, 190, 250] as [Double?] {
            let z = zones(.percentOfReserve, manual: 190, resting: resting)
            XCTAssertEqual(z.lowerBounds, [95, 114, 133, 152, 171], "resting \(String(describing: resting))")
            XCTAssertEqual(z.method, .percentOfMax)
            XCTAssertEqual(z.fallback, .noRestingHR)
            XCTAssertNil(z.restingHR)
            XCTAssertNotNil(z.fallbackNote)
        }
    }

    func testCustomBoundsAreUsedAsTyped() {
        let z = zones(.custom, custom: [100, 120, 140, 160, 180])
        XCTAssertEqual(z.lowerBounds, [100, 120, 140, 160, 180])
        XCTAssertEqual(z.method, .custom)
        XCTAssertNil(z.fallback)
    }

    func testAnInvalidCustomSetFallsBackToPercentOfMaxWithANote() {
        let bad: [[Int]] = [[100, 120, 140, 160], [100, 120, 140, 160, 180, 200], [100, 120, 120, 160, 180],
                            [100, 130, 120, 160, 180], [29, 120, 140, 160, 180], [100, 120, 140, 160, 231]]
        for custom in bad {
            let z = zones(.custom, custom: custom)
            XCTAssertEqual(z.lowerBounds, [95, 114, 133, 152, 171], "\(custom)")
            XCTAssertEqual(z.fallback, .invalidCustom)
            XCTAssertNotNil(z.fallbackNote)
        }
    }

    // MARK: Validation

    func testCustomBoundsMustBeFiveStrictlyIncreasingValuesInRange() {
        XCTAssertTrue(HeartRateZones.isValidCustom([100, 120, 140, 160, 180]))
        XCTAssertTrue(HeartRateZones.isValidCustom([30, 31, 32, 33, 230]))
        XCTAssertFalse(HeartRateZones.isValidCustom([100, 120, 140, 160]))
        XCTAssertFalse(HeartRateZones.isValidCustom([100, 120, 140, 140, 180]))
        XCTAssertFalse(HeartRateZones.isValidCustom([180, 160, 140, 120, 100]))
        XCTAssertFalse(HeartRateZones.isValidCustom([29, 120, 140, 160, 180]))
        XCTAssertFalse(HeartRateZones.isValidCustom([100, 120, 140, 160, 231]))
    }

    func testManualMaxHeartRateMustBeBetween100And230() {
        XCTAssertFalse(MaxHeartRate.isValidManual(99))
        XCTAssertTrue(MaxHeartRate.isValidManual(100))
        XCTAssertTrue(MaxHeartRate.isValidManual(230))
        XCTAssertFalse(MaxHeartRate.isValidManual(231))
    }

    func testAnOutOfRangeManualMaxIsIgnoredAndAutomaticUsed() {
        for bad in [0, 99, 231, 500, -190] {
            let z = zones(manual: bad, age: 30)
            XCTAssertEqual(z.maxHR, 190, "manual \(bad)")
            XCTAssertTrue(z.maxHRIsAutomatic)
        }
        XCTAssertEqual(MaxHeartRate.resolve(age: 30, manual: 99), 190)
    }

    func testAManualMaxReplacesTheFormulaForTheZones() {
        let z = zones(manual: 200, age: 30)
        XCTAssertEqual(z.maxHR, 200)
        XCTAssertFalse(z.maxHRIsAutomatic)
    }

    // MARK: Automatic max HR is exactly 220 - age

    func testAutomaticMaxHeartRateIsExactly220MinusAgeAtEveryAge() {
        for age in [-5, 0, 1, 30, 90, 219, 220, 400] {
            XCTAssertEqual(MaxHeartRate.automatic(age: age), max(220 - age, 1), "age \(age)")
            XCTAssertEqual(MaxHeartRate.resolve(age: age, manual: nil), max(220 - age, 1), "age \(age)")
            XCTAssertEqual(HeartRateZoneSettings.standard.maxHR(age: age), max(220 - age, 1), "age \(age)")
            XCTAssertEqual(UserProfile(age: age, weightKg: 70, heightCm: 170, sex: .male).maxHR,
                           max(220 - age, 1), "age \(age)")
        }
        XCTAssertEqual(MaxHeartRate.automatic(age: 1), 219)
        XCTAssertEqual(MaxHeartRate.automatic(age: 30), 190)
        XCTAssertEqual(MaxHeartRate.automatic(age: 90), 130)
    }

    func testTheClampedAgeSitesKeepTheirOldValue() {
        XCTAssertEqual(TrainingLoad.zoneMaxHR(age: 0), 219)
        XCTAssertEqual(TrainingLoad.zoneMaxHR(age: -3), 219)
        XCTAssertEqual(TrainingLoad.zoneMaxHR(age: 30), 190)
        XCTAssertEqual(TrainingLoad.zoneMaxHR(age: 400), 1)
    }

    func testAProfileWithAManualMaxUsesItAndAnInvalidOneIsIgnored() {
        XCTAssertEqual(UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male, manualMaxHR: 175).maxHR, 175)
        XCTAssertEqual(UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male, manualMaxHR: 50).maxHR, 190)
    }

    // MARK: Classifier

    func testEveryDefaultBoundaryClassifiesToItsZoneAndOneBelowToThePreviousOne() {
        for maxHR in [150, 185, 190, 200, 219] {
            let z = HeartRateZones(percentOfMax: maxHR)
            XCTAssertNil(HRZoneClassifier.zone(bpm: z.lowerBounds[0] - 1, zones: z), "max \(maxHR)")
            for (i, zone) in HRZone.allCases.enumerated() {
                XCTAssertEqual(HRZoneClassifier.zone(bpm: z.lowerBounds[i], zones: z), zone, "max \(maxHR) \(zone)")
                if i > 0 {
                    XCTAssertEqual(HRZoneClassifier.zone(bpm: z.lowerBounds[i] - 1, zones: z),
                                   HRZone.allCases[i - 1], "max \(maxHR) below \(zone)")
                }
            }
            XCTAssertEqual(HRZoneClassifier.zone(bpm: maxHR + 20, zones: z), .extreme)
        }
    }

    func testDefaultBoundsAre50_60_70_80_90PercentNotTheOldVendorSplit() {
        // 200 max: 122 was zone 2 under 61 %, is zone 2 under 60 % too; 120 is the NEW zone 2 start.
        let z = HeartRateZones(percentOfMax: 200)
        XCTAssertEqual(z.zone(bpm: 120), .fatBurn)
        XCTAssertEqual(z.zone(bpm: 140), .aerobic)
        XCTAssertEqual(z.zone(bpm: 160), .anaerobic)
        XCTAssertEqual(z.zone(bpm: 180), .extreme)
    }

    func testBelowZoneOneAndNonPositiveReadingsAreInNoZone() {
        let z = HeartRateZones(percentOfMax: 200)
        XCTAssertNil(z.zone(bpm: 99))
        XCTAssertNil(z.zone(bpm: 0))
        XCTAssertNil(z.zone(bpm: -1))
    }

    func testCustomAndReserveZonesClassifyOnTheirOwnBounds() {
        let custom = zones(.custom, custom: [90, 110, 130, 150, 170])
        XCTAssertNil(custom.zone(bpm: 89))
        XCTAssertEqual(custom.zone(bpm: 90), .warmUp)
        XCTAssertEqual(custom.zone(bpm: 149), .aerobic)
        XCTAssertEqual(custom.zone(bpm: 170), .extreme)
        let reserve = zones(.percentOfReserve, manual: 190, resting: 60)
        XCTAssertNil(reserve.zone(bpm: 124))
        XCTAssertEqual(reserve.zone(bpm: 125), .warmUp)
        XCTAssertEqual(reserve.zone(bpm: 176), .anaerobic)
        XCTAssertEqual(reserve.zone(bpm: 177), .extreme)
    }

    func testTimeInZonesFollowsTheUsersZones() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [HRSample(bpm: 100, start: t0, end: t0.addingTimeInterval(10)),
                       HRSample(bpm: 135, start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(20))]
        let end = t0.addingTimeInterval(20)
        let byDefault = HRZoneClassifier.timeInZonesHeld(hrSamples: samples, zones: HeartRateZones(percentOfMax: 200), sessionEnd: end)
        XCTAssertEqual(byDefault.warmUpSeconds, 10)
        XCTAssertEqual(byDefault.fatBurnSeconds, 10)
        let custom = zones(.custom, custom: [101, 110, 120, 130, 140])
        let byCustom = HRZoneClassifier.timeInZonesHeld(hrSamples: samples, zones: custom, sessionEnd: end)
        XCTAssertEqual(byCustom.warmUpSeconds, 0)
        XCTAssertEqual(byCustom.aerobicSeconds, 0)
        XCTAssertEqual(byCustom.anaerobicSeconds, 10)
        XCTAssertEqual(WorkoutPace.liveZone(bpm: 135, isStale: false, zones: custom), 4)
        XCTAssertNil(WorkoutPace.liveZone(bpm: 135, isStale: true, zones: custom))
    }

    func testAggregatorAndStrapSummaryUseTheZonesTheyAreGiven() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let custom = zones(.custom, custom: [101, 110, 120, 130, 140])
        let agg = WorkoutSessionAggregator(startDate: t0, userAge: 30, zones: custom)
        agg.add(sample: HRSample(bpm: 135, start: t0, end: t0.addingTimeInterval(10)))
        let summary = agg.finalize(sport: .runningOutdoor, endDate: t0.addingTimeInterval(10),
                                   distanceMeters: nil, hasRoute: false, profile: profile)
        XCTAssertEqual(summary.zoneBreakdown.anaerobicSeconds, 10)
        XCTAssertTrue(summary.usedFormulaMaxHR, "custom bounds do not change where the max HR came from")

        let manual = zones(manual: 200)
        let manualAgg = WorkoutSessionAggregator(startDate: t0, userAge: 30, zones: manual)
        XCTAssertFalse(manualAgg.finalize(sport: .runningOutdoor, endDate: t0.addingTimeInterval(10),
                                          distanceMeters: nil, hasRoute: false, profile: profile).usedFormulaMaxHR)
        XCTAssertTrue(WorkoutSessionAggregator(startDate: t0, userAge: 30)
            .finalize(sport: .runningOutdoor, endDate: t0.addingTimeInterval(10),
                      distanceMeters: nil, hasRoute: false, profile: profile).usedFormulaMaxHR)

        let ledger = WorkoutActivityLedger(start: t0)
        let strap = StrapWorkoutSummaryBuilder.summarize(
            sport: .runningOutdoor, ledger: ledger,
            samples: [HRSample(bpm: 135, start: t0, end: t0.addingTimeInterval(10))],
            end: t0.addingTimeInterval(10), distanceMeters: nil, hasRoute: false, profile: profile, zones: custom)
        XCTAssertEqual(strap.summary.zoneBreakdown.anaerobicSeconds, 10)
    }

    // MARK: Labels and ranges (83a)

    func testZonesAreNamedZone1To5WithNoVendorNames() {
        XCTAssertEqual(HRZone.allCases.map(\.displayName), ["Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5"])
    }

    func testRangeTextShowsEachZonesBpmRangeAndZone5IsOpenEnded() {
        let z = HeartRateZones(percentOfMax: 200)
        XCTAssertEqual(z.rangeText(of: .warmUp), "100–119 bpm")
        XCTAssertEqual(z.rangeText(of: .fatBurn), "120–139 bpm")
        XCTAssertEqual(z.rangeText(of: .aerobic), "140–159 bpm")
        XCTAssertEqual(z.rangeText(of: .anaerobic), "160–179 bpm")
        XCTAssertEqual(z.rangeText(of: .extreme), "180+ bpm")
        XCTAssertNil(z.upperBound(of: .extreme))
        XCTAssertEqual(z.upperBound(of: .warmUp), 119)
    }

    // MARK: Nothing but the zone split moves with Automatic (golden values from the pre-change code)

    private func fixture() -> (hr: [HRSample], day: DateInterval) {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var hr: [HRSample] = []
        for i in 0..<240 {
            let bpm = 62 + (i * 7) % 100
            let s = t0.addingTimeInterval(Double(i) * 60)
            hr.append(HRSample(bpm: bpm, start: s, end: s.addingTimeInterval(60)))
        }
        return (hr, DateInterval(start: t0, end: t0.addingTimeInterval(240 * 60)))
    }

    func testCaloriesStrainAndWorkoutKcalAreUnchangedWithAutomaticMaxHeartRate() {
        let golden: [(age: Int, kcal: Double, minutes: Double, strain: Double, strainMax: Int, workoutKcal: Double)] = [
            (1, 1176.6201123326964, 126.0, 10.27, 219, 1372.6381453154875),
            (30, 1565.0311238580841, 160.0, 12.29, 190, 1732.3287125557679),
            (90, 2439.418145182706, 233.0, 15.29, 130, 2476.5160930529)
        ]
        let (hr, day) = fixture()
        for g in golden {
            let p = UserProfile(age: g.age, weightKg: 70, heightCm: 170, sex: .male)
            let cal = Calories.dailyEstimate(hrSamples: hr, steps: 1200, profile: p, sleepWindow: nil,
                                             corroborateMotion: false)
            XCTAssertEqual(cal.activeKcal, g.kcal, "age \(g.age)")
            XCTAssertEqual(cal.elevatedMinutes, g.minutes, "age \(g.age)")
            let legacy = Calories.legacyDailyEstimate(hrSamples: hr, steps: 1200, profile: p, corroborateMotion: false)
            XCTAssertEqual(legacy.activeKcal, g.kcal, "age \(g.age)")
            XCTAssertEqual(legacy.elevatedMinutes, g.minutes, "age \(g.age)")
            let strain = DailyStrain.reading(hr: hr, window: day, age: g.age, restingHR: 55)
            XCTAssertEqual(strain.strain, g.strain, "age \(g.age)")
            XCTAssertEqual(strain.maxHR, g.strainMax, "age \(g.age)")
            let agg = WorkoutSessionAggregator(startDate: day.start, userAge: g.age)
            for s in hr { agg.add(sample: s) }
            let summary = agg.finalize(sport: .runningOutdoor, endDate: day.end, distanceMeters: nil,
                                       hasRoute: false, profile: p)
            XCTAssertEqual(summary.estimatedActiveKcal, g.workoutKcal, "age \(g.age)")
        }
    }

    func testAManualMaxHeartRateMovesCaloriesStrainAndExerciseMinutes() {
        let (hr, day) = fixture()
        let auto = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let manual = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male, manualMaxHR: 160)
        let a = Calories.dailyEstimate(hrSamples: hr, steps: 1200, profile: auto, corroborateMotion: false)
        let m = Calories.dailyEstimate(hrSamples: hr, steps: 1200, profile: manual, corroborateMotion: false)
        XCTAssertNotEqual(a.elevatedMinutes, m.elevatedMinutes)
        let s = DailyStrain.reading(hr: hr, window: day, age: 30, restingHR: 55, manualMaxHR: 160)
        XCTAssertEqual(s.maxHR, 160)
        XCTAssertNotEqual(s.strain, DailyStrain.reading(hr: hr, window: day, age: 30, restingHR: 55).strain)
        // A manual value equal to the formula's own gives the identical result.
        let same = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male, manualMaxHR: 190)
        XCTAssertEqual(Calories.dailyEstimate(hrSamples: hr, steps: 1200, profile: same, corroborateMotion: false), a)
    }

    // MARK: Training load (83a/83d: unchanged arithmetic over a fixed breakdown)

    func testTrainingLoadOverAFixedBreakdownIsUnchanged() {
        let breakdown = WorkoutZoneBreakdown(warmUpSeconds: 60, fatBurnSeconds: 120, aerobicSeconds: 180,
                                             anaerobicSeconds: 240, extremeSeconds: 300)
        XCTAssertEqual(TrainingLoad.edwardsTRIMP(breakdown), 55.0)
        XCTAssertEqual(TrainingLoad.workoutLoad(zones: breakdown, hrSampleCount: 5), 55.0)
        XCTAssertNil(TrainingLoad.workoutLoad(zones: breakdown, hrSampleCount: 0))
    }

    func testTrainingLoadFromSamplesFollowsTheUsersZones() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [HRSample(bpm: 135, start: t0, end: t0.addingTimeInterval(60))]
        let end = t0.addingTimeInterval(60)
        // 135 bpm: zone 2 on a 200 max (1 min x 2); zone 4 on these custom bounds (1 min x 4).
        XCTAssertEqual(TrainingLoad.workoutLoad(hrSamples: samples, zones: HeartRateZones(percentOfMax: 200),
                                                sessionEnd: end), 2.0 * 30 / 60)
        XCTAssertEqual(TrainingLoad.workoutLoad(hrSamples: samples, zones: zones(.custom, custom: [101, 110, 120, 130, 140]),
                                                sessionEnd: end), 4.0 * 30 / 60)
    }

    // MARK: Auto-detected workout (83g SF-1)

    func testADetectedWorkoutsSummaryUsesTheZonesItIsGiven() {
        let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)
        let samples = (1...60).map {
            HistoricalSportFrame.Sample(cursor: UInt32(1_000_000 + $0 * 10), heartRate: 152, steps: 0)
        }
        let candidate = AutomaticWorkoutDetector.Candidate(
            start: samples[0].endDate.addingTimeInterval(-10), end: samples.last!.endDate,
            samples: samples, suggestedKind: nil)
        // 152 bpm: Zone 4 on the default zones for a 180 max, Zone 5 on these.
        let custom = zones(.custom, custom: [100, 110, 120, 130, 140])
        let mine = AutomaticWorkoutConfirmation.prepare(candidate: candidate, sport: .yoga, profile: profile, zones: custom)
        XCTAssertGreaterThan(mine.summary.zoneBreakdown.extremeSeconds, 0)
        XCTAssertEqual(mine.summary.zoneBreakdown.anaerobicSeconds, 0)
        let manual = AutomaticWorkoutConfirmation.prepare(candidate: candidate, sport: .yoga, profile: profile,
                                                          zones: zones(manual: 200))
        XCTAssertFalse(manual.summary.usedFormulaMaxHR)
        let plain = AutomaticWorkoutConfirmation.prepare(candidate: candidate, sport: .yoga, profile: profile)
        XCTAssertGreaterThan(plain.summary.zoneBreakdown.anaerobicSeconds, 0)
        XCTAssertEqual(plain.summary.zoneBreakdown.extremeSeconds, 0)
    }
}
