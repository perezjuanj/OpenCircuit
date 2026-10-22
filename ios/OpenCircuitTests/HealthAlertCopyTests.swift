import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The elevated-HR-while-inactive alert used to word its body around the sample that COMPLETED the
/// 10-minute run ("stayed elevated (above 143 bpm)"), which read as if 143 were the trigger threshold.
/// It must instead cite the user's CONFIGURED threshold. (UX sweep #159)
@MainActor
final class HealthAlertCopyTests: XCTestCase {
    func testElevatedHRCopyCitesConfiguredThresholdNotCompletingSample() {
        let threshold = HealthAlertDefaults.thresholds().elevatedHRBpm   // default 100
        // hit.value is the completing reading (e.g. 143), deliberately different from the threshold.
        let hit = HealthAlertHit(notification: .elevatedHRInactive, value: 143, time: Date())
        let (_, body) = HealthNotificationCenter.copy(for: .elevatedHRInactive, hit: hit)

        XCTAssertTrue(body.contains("\(threshold) bpm threshold"),
                      "copy must cite the configured threshold; got: \(body)")
        XCTAssertFalse(body.contains("143"),
                       "copy must NOT present the completing sample (143) as the threshold; got: \(body)")
    }

    // MARK: The time named must be on the right day

    /// Instant alerts only cite a reading from the last 90 minutes (decisions 32 and 37, #234), so
    /// the live case that crosses a day is a late-evening reading notified after midnight: a 23:10
    /// reading at 00:20, 70 minutes old. A bare "11:10 PM" would read as tonight.
    func testCopyNamesTheDayForAReadingFromAPreviousDay() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 0, minute: 20))!
        let beforeMidnight = cal.date(from: DateComponents(year: 2026, month: 8, day: 11,
                                                          hour: 23, minute: 10))!
        let hit = HealthAlertHit(notification: .highHR, value: 128, time: beforeMidnight)
        let (_, body) = HealthNotificationCenter.copy(for: .highHR, hit: hit, now: now)
        XCTAssertTrue(body.contains("yesterday at"),
                      "a previous-day reading must say so; got: \(body)")
    }

    /// …and the common same-day case keeps the exact wording it always had.
    func testCopyKeepsTheBareClockTimeForATodayReading() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 9, minute: 0))!
        let earlier = cal.date(from: DateComponents(year: 2026, month: 8, day: 12,
                                                   hour: 7, minute: 4))!
        let hit = HealthAlertHit(notification: .lowSpO2, value: 88, time: earlier)
        let (_, body) = HealthNotificationCenter.copy(for: .lowSpO2, hit: hit, now: now)
        XCTAssertFalse(body.contains("yesterday"), "same-day must not gain a day; got: \(body)")
        XCTAssertFalse(body.contains(" on "), "same-day must not gain a weekday; got: \(body)")
        XCTAssertTrue(body.contains(" at "), "the preposition must survive; got: \(body)")
        XCTAssertFalse(body.contains("at at"), "the phrase carries its own preposition; got: \(body)")
    }

    /// An older-than-yesterday reading names its weekday rather than silently reading as today.
    func testCopyNamesTheWeekdayForAnOlderReading() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 9, minute: 0))!
        let older = cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 15, minute: 0))!
        let hit = HealthAlertHit(notification: .highHR, value: 130, time: older)
        let (_, body) = HealthNotificationCenter.copy(for: .highHR, hit: hit, now: now)
        XCTAssertTrue(body.contains(" on "), "an older reading must name its day; got: \(body)")
        XCTAssertFalse(body.contains("at at"))
    }

    // The length rule for every notification lives in `AllNotificationsFitTests` (`NotificationBudget`).

    /// The body-vital alerts still carry the disclaimer, on its own line, after the copy.
    func testVitalAlertsStillCarryTheDisclaimer() {
        for n in [HealthNotification.highHR, .lowSpO2, .elevatedHRInactive, .skinTempRise, .fever,
                  .illnessSigns, .headacheSigns] {
            XCTAssertEqual(HealthNotificationCenter.postedBody(for: n, copy: "Body."),
                           "Body.\nNot a medical device or a diagnosis.", n.rawValue)
        }
        XCTAssertEqual(HealthNotificationCenter.postedBody(for: .bedtimeReminder, copy: "Body."), "Body.")
    }

    func testTheIllnessCopyFollowsTheProfileTemperatureUnit() {
        let suite = "HealthAlertCopyTests.units"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TemperatureUnit.fahrenheit.rawValue, forKey: "units.temperature")
        XCTAssertEqual(HealthNotificationCenter.displayTempUnit(defaults), .fahrenheit)
        defaults.set(TemperatureUnit.celsius.rawValue, forKey: "units.temperature")
        XCTAssertEqual(HealthNotificationCenter.displayTempUnit(defaults), .celsius)
        defaults.removeObject(forKey: "units.temperature")
        XCTAssertEqual(HealthNotificationCenter.displayTempUnit(defaults), .localeDefault)
    }
}
