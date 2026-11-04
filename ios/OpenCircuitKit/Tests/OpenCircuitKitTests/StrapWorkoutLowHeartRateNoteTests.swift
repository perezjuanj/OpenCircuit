import XCTest
@testable import OpenCircuitKit

// When a strap workout gets the "heart rate stayed below Zone 1" note (#355, decision 88a), one
// boundary per condition. Every time and reading is synthetic.
final class StrapWorkoutLowHeartRateNoteTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    /// % of max on 180 bpm: Zone 1 starts at 90 bpm.
    private let zones = HeartRateZones(percentOfMax: 180)

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// One reading per second over `[from, to)`, each spanning the second before it.
    private func readings(_ from: TimeInterval, _ to: TimeInterval, bpm: Int) -> [HRSample] {
        stride(from: from + 1, through: to, by: 1).map { HRSample(bpm: bpm, start: at($0 - 1), end: at($0)) }
    }

    private func applies(sport: WorkoutSportType = .other, activeSeconds: TimeInterval,
                         _ readings: [HRSample], zones: HeartRateZones? = nil,
                         isStrapWorkout: Bool = true) -> Bool {
        StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: isStrapWorkout, sport: sport,
                                             activeSeconds: activeSeconds, activeReadings: readings,
                                             zones: zones ?? self.zones)
    }

    func testZoneOneFloorOfTheFixtureIs90() {
        XCTAssertEqual(zones.lowerBounds[0], 90)
    }

    func testLongWorkoutWhollyBelowZoneOneShowsTheNote() {
        XCTAssertTrue(applies(activeSeconds: 4200, readings(0, 4200, bpm: 80)))
    }

    func testWorkoutInZonesShowsNoNote() {
        XCTAssertFalse(applies(activeSeconds: 4200, readings(0, 4200, bpm: 150)))
    }

    func testRingWorkoutShowsNoNote() {
        XCTAssertFalse(applies(activeSeconds: 4200, readings(0, 4200, bpm: 80), isStrapWorkout: false))
    }

    // MARK: Active time

    func testTwentyMinutesExactlyQualifies() {
        XCTAssertTrue(applies(activeSeconds: 1200, readings(0, 1200, bpm: 80)))
    }

    func testOneSecondUnderTwentyMinutesShowsNoNote() {
        XCTAssertFalse(applies(activeSeconds: 1199, readings(0, 1199, bpm: 80)))
    }

    // MARK: Coverage

    func testReadingsCoveringHalfTheActiveSecondsExactlyQualify() {
        XCTAssertTrue(applies(activeSeconds: 1200, readings(0, 600, bpm: 80)))
    }

    func testReadingsCoveringUnderHalfTheActiveSecondsShowNoNote() {
        XCTAssertFalse(applies(activeSeconds: 1200, readings(0, 599, bpm: 80)))
    }

    func testNoReadingsShowNoNote() {
        XCTAssertFalse(applies(activeSeconds: 4200, []))
    }

    // MARK: Share below Zone 1

    func testThreeQuartersBelowZoneOneExactlyQualifies() {
        let samples = readings(0, 900, bpm: 80) + readings(900, 1200, bpm: 150)
        XCTAssertTrue(applies(activeSeconds: 1200, samples))
    }

    func testOneReadingUnderThreeQuartersBelowZoneOneShowsNoNote() {
        let samples = readings(0, 899, bpm: 80) + readings(899, 1200, bpm: 150)
        XCTAssertFalse(applies(activeSeconds: 1200, samples))
    }

    func testReadingOnTheZoneOneFloorCountsAsInZoneOne() {
        // 899 of 1200 below, 301 exactly on the floor: under 75 % below.
        let samples = readings(0, 899, bpm: 89) + readings(899, 1200, bpm: 90)
        XCTAssertFalse(applies(activeSeconds: 1200, samples))
        XCTAssertFalse(applies(activeSeconds: 1200, readings(0, 1200, bpm: 90)))
        XCTAssertTrue(applies(activeSeconds: 1200, readings(0, 1200, bpm: 89)))
    }

    // MARK: Sport

    func testEachExcludedSportShowsNoNote() {
        for sport: WorkoutSportType in [.walkingOutdoor, .walkingIndoor, .hiking, .yoga] {
            XCTAssertFalse(applies(sport: sport, activeSeconds: 4200, readings(0, 4200, bpm: 80)), "\(sport)")
        }
    }

    func testEveryOtherSportShowsTheNote() {
        let excluded: Set<WorkoutSportType> = [.walkingOutdoor, .walkingIndoor, .hiking, .yoga]
        XCTAssertEqual(StrapWorkoutLowHeartRateNote.excludedSports, excluded)
        for sport in WorkoutSportType.allCases where !excluded.contains(sport) {
            XCTAssertTrue(applies(sport: sport, activeSeconds: 4200, readings(0, 4200, bpm: 80)), "\(sport)")
        }
    }

    // MARK: Zones in use

    func testCustomZonesSetTheFloor() {
        let custom = HeartRateZones(settings: HeartRateZoneSettings(method: .custom, customLowerBounds: [100, 120, 140, 160, 180]),
                                    age: 40, restingHR: nil)
        XCTAssertEqual(custom.lowerBounds[0], 100)
        XCTAssertTrue(applies(activeSeconds: 1200, readings(0, 1200, bpm: 99), zones: custom))
        XCTAssertFalse(applies(activeSeconds: 1200, readings(0, 1200, bpm: 100), zones: custom))
        // The same readings over the % of max fixture are in Zone 1.
        XCTAssertFalse(applies(activeSeconds: 1200, readings(0, 1200, bpm: 99)))
    }

    func testHeartRateReserveZonesSetTheFloor() {
        // 60 + ceil(50 % × (190 − 60)) = 125.
        let reserve = HeartRateZones(settings: HeartRateZoneSettings(method: .percentOfReserve, manualMaxHR: 190),
                                     age: 40, restingHR: 60)
        XCTAssertEqual(reserve.method, .percentOfReserve)
        XCTAssertEqual(reserve.lowerBounds[0], 125)
        XCTAssertTrue(applies(activeSeconds: 1200, readings(0, 1200, bpm: 124), zones: reserve))
        XCTAssertFalse(applies(activeSeconds: 1200, readings(0, 1200, bpm: 125), zones: reserve))
    }

    // MARK: Over a recording (the summary's readings)

    func testPausedTimeDoesNotCountTowardTwentyMinutes() {
        // 25 min on the clock, 10 of them paused: 15 min active.
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(600))
        ledger.resume(at: at(1200))
        let samples = readings(0, 1500, bpm: 80)
        XCTAssertFalse(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, sport: .other, ledger: ledger,
                                                            samples: samples, end: at(1500), zones: zones))
    }

    func testTwentyActiveMinutesAroundAPauseQualify() {
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(600))
        ledger.resume(at: at(1200))
        XCTAssertTrue(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, sport: .other, ledger: ledger,
                                                           samples: readings(0, 1800, bpm: 80), end: at(1800), zones: zones))
    }

    func testReadingsDuringAPauseAreNotCounted() {
        // Active 0–600 and 1200–1800. Counted: 600 low + 300 in Zone 3 (67 % below, no note). The 600
        // low readings during the pause would make it 80 % if they counted.
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(600))
        ledger.resume(at: at(1200))
        let samples = readings(0, 1200, bpm: 80) + readings(1200, 1500, bpm: 130)
        XCTAssertFalse(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, sport: .other, ledger: ledger,
                                                            samples: samples, end: at(1800), zones: zones))
    }

    func testDuplicateReadingsCountOnceAsInTheSummary() {
        // 599 distinct readings sent twice over 20 active minutes: under half the seconds.
        let ledger = WorkoutActivityLedger(start: t0)
        let once = readings(0, 599, bpm: 80)
        let summary = StrapWorkoutSummaryBuilder.summarize(sport: .other, ledger: ledger, samples: once + once,
                                                           end: at(1200), distanceMeters: nil, hasRoute: false,
                                                           profile: UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male),
                                                           zones: zones)
        XCTAssertEqual(summary.summary.hrSampleCount, 599)
        XCTAssertFalse(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, sport: .other, ledger: ledger,
                                                            samples: once + once, end: at(1200), zones: zones))
    }

    // MARK: Copy

    func testCopyIsDecision88bVerbatim() {
        XCTAssertEqual(StrapWorkoutLowHeartRateNote.text,
                       "Heart rate stayed below Zone 1 for most of this workout. If you worked harder than that, the strap may not have held a good reading: fast, repeated arm movement (racket sports, boxing) can make its live heart rate read low. OpenCircuit reads the strap's everyday heart rate, not Zepp's workout mode. A snug fit helps.")
    }
}
