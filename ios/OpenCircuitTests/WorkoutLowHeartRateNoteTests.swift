import HealthKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// The "heart rate stayed below Zone 1" note (#355, decision 88) on the workout history detail: which
// workouts are the strap's, which readings and seconds count, and the zones in use. The thresholds
// themselves are tested in OpenCircuitKit (`StrapWorkoutLowHeartRateNoteTests`). Every value is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

@MainActor
final class WorkoutDetailLowHeartRateNoteTests: XCTestCase {
    /// % of max on 180 bpm: Zone 1 starts at 90 bpm.
    private let zones = HeartRateZones(percentOfMax: 180)

    private func item(_ activity: HKWorkoutActivityType = .other, seconds: TimeInterval = 1200,
                      pauses: [DateInterval] = []) -> WorkoutHistoryReader.Item {
        WorkoutHistoryReader.Item(id: UUID(), activityType: activity, start: t0, end: at(seconds),
                                  activeKcal: nil, distanceMeters: nil, avgHR: nil, pauses: pauses)
    }

    /// One workout-shaped reading a second over `[from, to)`, each spanning the second before it, as
    /// the strap's workout saves them with the `HKWorkout`.
    private func readings(_ from: TimeInterval, _ to: TimeInterval, bpm: Int) -> [HRSample] {
        stride(from: from + 1, through: to, by: 1).map { HRSample(bpm: bpm, start: at($0 - 1), end: at($0)) }
    }

    private func shows(_ item: WorkoutHistoryReader.Item, _ hr: [HRSample], zones: HeartRateZones? = nil,
                       strap: Bool = true) -> Bool {
        WorkoutDetailContent.showsLowHeartRateNote(item, hr: hr, zones: zones ?? self.zones, isStrapWorkout: strap)
    }

    func testAStrapWorkoutBelowZoneOneShowsTheNote() {
        XCTAssertTrue(shows(item(), readings(0, 1200, bpm: 80)))
    }

    func testARingWorkoutBelowZoneOneShowsNoNote() {
        XCTAssertFalse(shows(item(), readings(0, 1200, bpm: 80), strap: false))
    }

    func testAStrapWorkoutInZonesShowsNoNote() {
        XCTAssertFalse(shows(item(), readings(0, 1200, bpm: 150)))
    }

    func testWalkingHikingAndYogaShowNoNote() {
        for activity: HKWorkoutActivityType in [.walking, .hiking, .yoga] {
            XCTAssertFalse(shows(item(activity), readings(0, 1200, bpm: 80)), "\(activity.rawValue)")
        }
    }

    func testEveryOtherSportTheAppWritesShowsTheNote() {
        for activity: HKWorkoutActivityType in [.running, .cycling, .rowing, .traditionalStrengthTraining, .other] {
            XCTAssertTrue(shows(item(activity), readings(0, 1200, bpm: 80)), "\(activity.rawValue)")
        }
    }

    func testAnActivityTypeNoSportWritesShowsNoNote() {
        XCTAssertFalse(shows(item(.tennis), readings(0, 1200, bpm: 80)))
    }

    func testPausedTimeIsNotActiveTime() {
        // 25 min on the clock, 10 of them paused: 15 min moving.
        let paused = item(seconds: 1500, pauses: [DateInterval(start: at(600), end: at(1200))])
        XCTAssertFalse(shows(paused, readings(0, 1500, bpm: 80)))
        // 30 min on the clock, 20 moving.
        let longer = item(seconds: 1800, pauses: [DateInterval(start: at(600), end: at(1200))])
        XCTAssertTrue(shows(longer, readings(0, 600, bpm: 80) + readings(1200, 1800, bpm: 80)))
    }

    func testReadingsDuringAPauseAreNotCounted() {
        // Moving 0–600 and 1200–1800: 600 low + 300 in Zone 3 count (67 % below). The 600 low ones
        // inside the pause would make it 80 %.
        let paused = item(seconds: 1800, pauses: [DateInterval(start: at(600), end: at(1200))])
        XCTAssertFalse(shows(paused, readings(0, 1200, bpm: 80) + readings(1200, 1500, bpm: 130)))
    }

    func testAllDayInstantsInTheWindowAreNotWorkoutReadings() {
        // 599 workout readings (under half of 20 min) plus everyday instants in the same window.
        let instants = stride(from: 0.5, to: 1200, by: 2).map { HRSample(bpm: 80, start: at($0), end: at($0)) }
        XCTAssertFalse(shows(item(), readings(0, 599, bpm: 80) + instants))
        XCTAssertTrue(shows(item(), readings(0, 600, bpm: 80) + instants))
    }

    func testTheDetailsZonesSetTheFloor() {
        let custom = HeartRateZones(settings: HeartRateZoneSettings(method: .custom, customLowerBounds: [100, 120, 140, 160, 180]),
                                    age: 40, restingHR: nil)
        XCTAssertTrue(shows(item(), readings(0, 1200, bpm: 99), zones: custom))
        XCTAssertFalse(shows(item(), readings(0, 1200, bpm: 99)))
    }

    // MARK: Which workouts are the strap's

    func testTheStrapsWorkoutsAreTheOnesItNamesOrOwnsTheTimeOf() {
        XCTAssertTrue(WorkoutDetailContent.isStrapWorkout(deviceName: "Helio Strap", deviceManufacturer: "Amazfit",
                                                          owner: .ringConn))
        XCTAssertTrue(WorkoutDetailContent.isStrapWorkout(deviceName: "iPhone", deviceManufacturer: "Apple Inc.",
                                                          owner: .zeppOS))
        XCTAssertTrue(WorkoutDetailContent.isStrapWorkout(deviceName: nil, deviceManufacturer: nil, owner: .zeppOS))
        XCTAssertFalse(WorkoutDetailContent.isStrapWorkout(deviceName: "iPhone", deviceManufacturer: "Apple Inc.",
                                                           owner: .ringConn))
        XCTAssertFalse(WorkoutDetailContent.isStrapWorkout(deviceName: nil, deviceManufacturer: nil, owner: .ringConn))
        XCTAssertFalse(WorkoutDetailContent.isStrapWorkout(deviceName: "RingConn Gen2", deviceManufacturer: "RingConn",
                                                           owner: .zeppOS), "a workout the ring names is the ring's")
    }
}
