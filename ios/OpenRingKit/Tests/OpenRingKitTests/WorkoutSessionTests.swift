import XCTest
@testable import OpenRingKit

// Tests for WorkoutSession.swift — zone classification, time-in-zone, session aggregation.
// Zone boundaries from the APK (pp.txt:0x515c0):
//   warmUp 50–60%, fatBurn 61–70%, aerobic 71–80%, anaerobic 81–90%, extreme 91–100%
//   Below 50% of maxHR → not counted (nil zone).
// maxHR formula: 220 - age.
final class WorkoutSessionTests: XCTestCase {

    // MARK: - HRZoneClassifier.zone(bpm:maxHR:)

    func testZoneBelowHalfMaxHRIsNil() {
        // 49% of 200 = 98 bpm — below 50%, not counted per APK
        XCTAssertNil(HRZoneClassifier.zone(bpm: 98, maxHR: 200))
    }

    func testZoneExactly50PercentIsWarmUp() {
        // 50% of 200 = 100 bpm → warm-up (lower bound inclusive)
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 100, maxHR: 200), .warmUp)
    }

    func testZoneWarmUpUpperBound() {
        // 60% of 200 = 120 bpm → still warm-up
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 120, maxHR: 200), .warmUp)
    }

    func testZoneFatBurnLower() {
        // 61% of 200 = 122 bpm → fat burn
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 122, maxHR: 200), .fatBurn)
    }

    func testZoneFatBurnUpper() {
        // 70% of 200 = 140 bpm → fat burn
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 140, maxHR: 200), .fatBurn)
    }

    func testZoneAerobicLower() {
        // 71% of 200 = 142 bpm → aerobic
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 142, maxHR: 200), .aerobic)
    }

    func testZoneAerobicUpper() {
        // 80% of 200 = 160 bpm → aerobic
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 160, maxHR: 200), .aerobic)
    }

    func testZoneAnaerobicLower() {
        // 81% of 200 = 162 bpm → anaerobic
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 162, maxHR: 200), .anaerobic)
    }

    func testZoneAnaerobicUpper() {
        // 90% of 200 = 180 bpm → anaerobic
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 180, maxHR: 200), .anaerobic)
    }

    func testZoneExtremeLower() {
        // 91% of 200 = 182 bpm → extreme
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 182, maxHR: 200), .extreme)
    }

    func testZoneExtremeAtMaxHR() {
        // 100% of 200 = 200 bpm → extreme
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 200, maxHR: 200), .extreme)
    }

    func testZoneZeroBpmIsNil() {
        XCTAssertNil(HRZoneClassifier.zone(bpm: 0, maxHR: 200))
    }

    func testZoneZeroMaxHRIsNil() {
        XCTAssertNil(HRZoneClassifier.zone(bpm: 100, maxHR: 0))
    }

    // MARK: - HRZoneClassifier.timeInZones

    func testTimeInZonesEmptySamplesAllZero() {
        let breakdown = HRZoneClassifier.timeInZones(hrSamples: [], maxHR: 200)
        for zone in HRZone.allCases {
            XCTAssertEqual(breakdown.seconds(in: zone), 0)
        }
        XCTAssertEqual(breakdown.totalZoneSeconds, 0)
    }

    func testTimeInZonesInstantaneousSamplesContributeZeroSeconds() {
        // Instantaneous reading (end == start): classified by BPM but 0 s zone duration.
        let t = Date(timeIntervalSince1970: 0)
        let sample = HRSample(bpm: 150, start: t, end: t)
        let breakdown = HRZoneClassifier.timeInZones(hrSamples: [sample], maxHR: 200)
        // 150/200 = 75% → aerobic, but 0 duration → 0 s
        XCTAssertEqual(breakdown.seconds(in: .aerobic), 0)
        XCTAssertEqual(breakdown.totalZoneSeconds, 0)
    }

    func testTimeInZones60SecAerobicSample() {
        // One 60-second sample at 75% maxHR → aerobic zone 60 s
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = t0.addingTimeInterval(60)
        let sample = HRSample(bpm: 150, start: t0, end: t1)   // 150/200 = 75% → aerobic
        let breakdown = HRZoneClassifier.timeInZones(hrSamples: [sample], maxHR: 200)
        XCTAssertEqual(breakdown.seconds(in: .aerobic), 60, accuracy: 0.001)
        XCTAssertEqual(breakdown.seconds(in: .warmUp), 0)
        XCTAssertEqual(breakdown.totalZoneSeconds, 60, accuracy: 0.001)
    }

    func testTimeInZonesMultipleZones() {
        let t0 = Date(timeIntervalSince1970: 0)
        // 30 s in warm-up (100 bpm = 50% of 200)
        let warmUp = HRSample(bpm: 100, start: t0, end: t0.addingTimeInterval(30))
        // 60 s in aerobic (150 bpm = 75% of 200)
        let aerobic = HRSample(bpm: 150, start: t0.addingTimeInterval(30), end: t0.addingTimeInterval(90))
        // 10 s below zone (90 bpm = 45% of 200 — not counted)
        let below = HRSample(bpm: 90, start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(100))

        let breakdown = HRZoneClassifier.timeInZones(hrSamples: [warmUp, aerobic, below], maxHR: 200)
        XCTAssertEqual(breakdown.seconds(in: .warmUp), 30, accuracy: 0.001)
        XCTAssertEqual(breakdown.seconds(in: .aerobic), 60, accuracy: 0.001)
        XCTAssertEqual(breakdown.totalZoneSeconds, 90, accuracy: 0.001)  // below-zone not counted
    }

    func testFractionWithTotalZeroReturnsZero() {
        let breakdown = HRZoneClassifier.timeInZones(hrSamples: [], maxHR: 200)
        XCTAssertEqual(breakdown.fraction(in: .aerobic), 0)
    }

    func testFractionSumsToOne() {
        let t0 = Date(timeIntervalSince1970: 0)
        let s1 = HRSample(bpm: 100, start: t0, end: t0.addingTimeInterval(30))  // warmUp 30 s
        let s2 = HRSample(bpm: 150, start: t0.addingTimeInterval(30), end: t0.addingTimeInterval(70)) // aerobic 40 s
        let breakdown = HRZoneClassifier.timeInZones(hrSamples: [s1, s2], maxHR: 200)
        let total = HRZone.allCases.map { breakdown.fraction(in: $0) }.reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 0.001)
    }

    // MARK: - WorkoutSessionAggregator

    func testAggregatorEmptySessionProducesNilHR() {
        let agg = WorkoutSessionAggregator(startDate: .distantPast, userAge: 30)
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let summary = agg.finalize(
            sport: .runningOutdoor,
            endDate: Date(),
            distanceMeters: nil,
            hasRoute: false,
            profile: profile
        )
        XCTAssertNil(summary.avgHR)
        XCTAssertNil(summary.maxHR)
        XCTAssertNil(summary.estimatedActiveKcal)
        XCTAssertEqual(summary.hrSampleCount, 0)
    }

    func testAggregatorComputesAvgAndMaxHR() {
        let t0 = Date(timeIntervalSince1970: 0)
        let agg = WorkoutSessionAggregator(startDate: t0, userAge: 30)
        agg.add(sample: HRSample(bpm: 100, start: t0, end: t0.addingTimeInterval(30)))
        agg.add(sample: HRSample(bpm: 150, start: t0.addingTimeInterval(30), end: t0.addingTimeInterval(60)))
        agg.add(sample: HRSample(bpm: 200, start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(90)))

        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let summary = agg.finalize(
            sport: .runningOutdoor,
            endDate: t0.addingTimeInterval(90),
            distanceMeters: 500,
            hasRoute: false,
            profile: profile
        )
        XCTAssertEqual(summary.avgHR, 150)   // (100+150+200)/3 = 150
        XCTAssertEqual(summary.maxHR, 200)
        XCTAssertEqual(summary.hrSampleCount, 3)
        XCTAssertEqual(summary.distanceMeters, 500)
    }

    // MARK: - HR backfill (workout window) + distance-based active-energy fallback

    func testBackfillMergesInWindowStoredHRDedupedByTimestamp() {
        let t0 = Date(timeIntervalSince1970: 0)
        let win = DateInterval(start: t0, end: t0.addingTimeInterval(600))
        let captured = [HRSample(bpm: 120, start: t0.addingTimeInterval(100), end: t0.addingTimeInterval(102))]
        let stored = [
            HRSample(bpm: 80,  start: t0.addingTimeInterval(100)),  // same start as captured → captured wins
            HRSample(bpm: 130, start: t0.addingTimeInterval(300)),  // in-window, new → added
            HRSample(bpm: 60,  start: t0.addingTimeInterval(900)),  // out-of-window → ignored
        ]
        let merged = WorkoutHRBackfill.merge(captured: captured, stored: stored, window: win)
        XCTAssertEqual(merged.map(\.bpm), [120, 130], "sorted by start; tie kept live 120; out-of-window dropped")
    }

    func testBackfillEmptyStoredLeavesCapturedUntouched() {
        let t0 = Date(timeIntervalSince1970: 0)
        let win = DateInterval(start: t0, end: t0.addingTimeInterval(600))
        let captured = [HRSample(bpm: 120, start: t0.addingTimeInterval(100))]
        XCTAssertEqual(WorkoutHRBackfill.merge(captured: captured, stored: [], window: win).map(\.bpm), [120])
        XCTAssertTrue(WorkoutHRBackfill.merge(captured: [], stored: [], window: win).isEmpty,
                      "empty stays empty — never fabricated")
    }

    func testAggregatorBackfillFeedsFinalize() {
        let t0 = Date(timeIntervalSince1970: 0)
        let agg = WorkoutSessionAggregator(startDate: t0, userAge: 30)
        let win = DateInterval(start: t0, end: t0.addingTimeInterval(600))
        agg.backfill([HRSample(bpm: 100, start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(12)),
                      HRSample(bpm: 140, start: t0.addingTimeInterval(20), end: t0.addingTimeInterval(22))],
                     window: win)
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let summary = agg.finalize(sport: .walkingOutdoor, endDate: t0.addingTimeInterval(600),
                                   distanceMeters: nil, hasRoute: false, profile: profile)
        XCTAssertEqual(summary.hrSampleCount, 2)
        XCTAssertEqual(summary.avgHR, 120)   // (100+140)/2
        XCTAssertEqual(summary.maxHR, 140)
    }

    func testDistanceFallbackActiveKcalWhenNoHR() {
        let t0 = Date(timeIntervalSince1970: 0)
        let agg = WorkoutSessionAggregator(startDate: t0, userAge: 30)   // no HR captured
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let summary = agg.finalize(sport: .walkingOutdoor, endDate: t0.addingTimeInterval(1800),
                                   distanceMeters: 2000, hasRoute: true, profile: profile)
        XCTAssertNil(summary.avgHR, "no HR was captured")
        // 2 km × 70 kg × 0.5 = 70 kcal — an honest distance estimate instead of nil/--.
        XCTAssertEqual(summary.estimatedActiveKcal!, 70.0, accuracy: 0.001)
    }

    func testAggregatorSportTypeAndDatePassThrough() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end   = Date(timeIntervalSince1970: 1_003_600)
        let agg = WorkoutSessionAggregator(startDate: start, userAge: 35)
        let profile = UserProfile(age: 35, weightKg: 80, heightCm: 175, sex: .male)
        let summary = agg.finalize(
            sport: .yoga,
            endDate: end,
            distanceMeters: nil,
            hasRoute: false,
            profile: profile
        )
        XCTAssertEqual(summary.sport, .yoga)
        XCTAssertEqual(summary.startDate, start)
        XCTAssertEqual(summary.endDate, end)
        XCTAssertEqual(summary.durationSeconds, 3600, accuracy: 0.001)
        XCTAssertFalse(summary.hasRoute)
    }

    func testAggregatorSufficientSamplesProducesCalorieEstimate() {
        // Strain.minReadings = 600 — need 600 samples with duration for a TRIMP estimate.
        let t0 = Date(timeIntervalSince1970: 0)
        let agg = WorkoutSessionAggregator(startDate: t0, userAge: 30)
        // maxHR for age 30 = 220 - 30 = 190. 150 bpm = ~84% → anaerobic zone.
        for i in 0..<600 {
            let s = t0.addingTimeInterval(Double(i))
            let e = t0.addingTimeInterval(Double(i) + 1.0)
            agg.add(sample: HRSample(bpm: 150, start: s, end: e))
        }
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let summary = agg.finalize(
            sport: .runningOutdoor,
            endDate: t0.addingTimeInterval(600),
            distanceMeters: 1000,
            hasRoute: false,
            profile: profile
        )
        XCTAssertNotNil(summary.estimatedActiveKcal)
        XCTAssertGreaterThan(summary.estimatedActiveKcal ?? 0, 0)
    }

    func testAggregatorInsufficientSamplesNilCalories() {
        let t0 = Date(timeIntervalSince1970: 0)
        let agg = WorkoutSessionAggregator(startDate: t0, userAge: 30)
        // Only 10 samples — far below Strain.minReadings (600)
        for i in 0..<10 {
            let s = t0.addingTimeInterval(Double(i))
            agg.add(sample: HRSample(bpm: 150, start: s, end: s.addingTimeInterval(1)))
        }
        let profile = UserProfile(age: 30, weightKg: 70, heightCm: 170, sex: .male)
        let summary = agg.finalize(
            sport: .walking, // will use fallback
            endDate: t0.addingTimeInterval(10),
            distanceMeters: nil,
            hasRoute: false,
            profile: profile
        )
        XCTAssertNil(summary.estimatedActiveKcal)
    }

    // MARK: - WorkoutSportType

    func testOutdoorTypesAreOutdoor() {
        XCTAssertTrue(WorkoutSportType.walkingOutdoor.isOutdoor)
        XCTAssertTrue(WorkoutSportType.runningOutdoor.isOutdoor)
        XCTAssertTrue(WorkoutSportType.cyclingOutdoor.isOutdoor)
        XCTAssertTrue(WorkoutSportType.hiking.isOutdoor)
    }

    func testIndoorTypesAreNotOutdoor() {
        XCTAssertFalse(WorkoutSportType.strengthTraining.isOutdoor)
        XCTAssertFalse(WorkoutSportType.yoga.isOutdoor)
        XCTAssertFalse(WorkoutSportType.other.isOutdoor)
    }

    // MARK: - maxHR formula (220 - age)

    func testFormulaMaxHRAge30() {
        // Indirect test: age 30 → maxHR = 190; 190 bpm at maxHR = 100% → extreme zone.
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 190, maxHR: 190), .extreme)
        // 50% of 190 = 95 → warm-up lower bound
        XCTAssertEqual(HRZoneClassifier.zone(bpm: 95, maxHR: 190), .warmUp)
        // 94 → below 50% of 190 → nil
        XCTAssertNil(HRZoneClassifier.zone(bpm: 94, maxHR: 190))
    }
}

// Extension to allow using `.walking` without the full qualified name in the test
// (mirrors the app side where `WorkoutSportType.walkingOutdoor` is used).
private extension WorkoutSportType {
    static var walking: WorkoutSportType { .walkingOutdoor }
}
