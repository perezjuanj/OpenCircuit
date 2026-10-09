import XCTest
@testable import OpenCircuitKit

/// Unit checks for the Keytel (2005) HR→energy workout-calorie model (`Calories.workoutActiveKcal`),
/// the fix for workouts showing "-- kcal" (Edwards-TRIMP needed 600 samples and zeroed below 50% HRR).
final class CaloriesKeytelTests: XCTestCase {

    private let male   = UserProfile(age: 35, weightKg: 75, heightCm: 178, sex: .male)
    private let female = UserProfile(age: 30, weightKg: 60, heightCm: 165, sex: .female)

    /// Exact Keytel value, male 75 kg / 35 y / 101 bpm:
    /// (−55.0969 + 0.6309·101 + 0.1988·75 + 0.2017·35) / 4.184 = 7.3120 kcal/min.
    func testMaleRateMatchesFormula() {
        XCTAssertEqual(Calories.keytelGrossKcalPerMinute(avgHR: 101, profile: male), 7.3120, accuracy: 0.001)
    }

    /// Exact Keytel value, female 60 kg / 30 y / 140 bpm:
    /// (−20.4022 + 0.4472·140 − 0.1263·60 + 0.074·30) / 4.184 = 8.8069 kcal/min.
    func testFemaleRateMatchesFormula() {
        XCTAssertEqual(Calories.keytelGrossKcalPerMinute(avgHR: 140, profile: female), 8.8069, accuracy: 0.001)
    }

    /// Active energy is the gross Keytel rate minus resting (Mifflin-St Jeor / 1440), because the resting
    /// part is already written hourly as Resting Energy. Male: BMR 1692.5 kcal/day → 1.17535 kcal/min, so
    /// 7.3120 − 1.1753 = 6.1367 kcal/min.
    func testActiveRateIsNetOfResting() {
        XCTAssertEqual(Calories.restingKcalPerMinute(profile: male), 1692.5 / 1440, accuracy: 1e-9)
        let oneMinute = Calories.workoutActiveKcal(avgHR: 101, durationSeconds: 60, profile: male)
        XCTAssertEqual(oneMinute, 6.1367, accuracy: 0.001)
    }

    /// Female 60 kg / 165 cm / 30 y: BMR 1320.25 kcal/day → 0.91684 kcal/min; 8.8069 − 0.9168 = 7.8901.
    func testFemaleActiveRateIsNetOfResting() {
        let oneMinute = Calories.workoutActiveKcal(avgHR: 140, durationSeconds: 60, profile: female)
        XCTAssertEqual(oneMinute, 7.8901, accuracy: 0.001)
    }

    /// A heart rate whose gross rate is at or just above resting earns no active energy.
    func testRestingLevelHeartRateEarnsNothing() {
        // Gross male rate at 60 bpm ≈ 1.130 kcal/min, below the 1.175 resting rate → 0.
        XCTAssertEqual(Calories.workoutActiveKcal(avgHR: 60, durationSeconds: 600, profile: male), 0, accuracy: 1e-9)
    }

    /// The reported case: 5m05s indoor cycle at avg 101 bpm → ≈ 31 kcal active (37 gross; not "--").
    func testReportedIndoorCycleScenario() {
        let kcal = Calories.workoutActiveKcal(avgHR: 101, durationSeconds: 305, profile: male)
        XCTAssertEqual(kcal, 31.2, accuracy: 0.5)
    }

    /// Energy scales linearly with duration (Keytel rate is per-minute).
    func testDurationScalesLinearly() {
        let five = Calories.workoutActiveKcal(avgHR: 120, durationSeconds: 300, profile: male)
        let ten  = Calories.workoutActiveKcal(avgHR: 120, durationSeconds: 600, profile: male)
        XCTAssertEqual(ten, five * 2, accuracy: 0.001)
    }

    /// Higher HR ⇒ more calories for the same duration/profile.
    func testMonotonicInHR() {
        let lo = Calories.workoutActiveKcal(avgHR: 100, durationSeconds: 300, profile: male)
        let hi = Calories.workoutActiveKcal(avgHR: 140, durationSeconds: 300, profile: male)
        XCTAssertGreaterThan(hi, lo)
    }

    /// A very low HR yields a negative raw Keytel rate — it must clamp to 0, never negative kcal.
    func testLowHRClampsToZero() {
        XCTAssertEqual(Calories.workoutActiveKcal(avgHR: 40, durationSeconds: 600, profile: male), 0, accuracy: 1e-9)
    }

    /// Guards: non-positive HR or duration → 0.
    func testNonPositiveInputsReturnZero() {
        XCTAssertEqual(Calories.workoutActiveKcal(avgHR: 0, durationSeconds: 300, profile: male), 0)
        XCTAssertEqual(Calories.workoutActiveKcal(avgHR: 120, durationSeconds: 0, profile: male), 0)
        XCTAssertEqual(Calories.workoutActiveKcal(avgHR: 120, durationSeconds: -5, profile: male), 0)
    }
}
