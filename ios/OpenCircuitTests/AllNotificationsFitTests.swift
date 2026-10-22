import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// THE RULE (`NotificationBudget`): every notification the app posts must read in full when pressed
/// and held. iOS shows about six lines and cuts the rest; build 86's illness alert lost its caveat
/// and its disclaimer that way on a real phone. Each posting site keeps its copy in a pure function,
/// and this file holds each one's WORST-CASE posted body to the budget.
///
/// The source scan at the bottom is what keeps the rule true for notifications that don't exist yet:
/// a new `UNMutableNotificationContent()` anywhere in the app fails it until the new site's copy is
/// added here.
@MainActor
final class AllNotificationsFitTests: XCTestCase {

    private func assertFits(_ body: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NotificationBudget.fits(body),
                      "\(what) wraps to \(NotificationBudget.wrappedLines(body)) lines (max "
                      + "\(NotificationBudget.maxLines) at \(NotificationBudget.lineWidth)): \(body)",
                      file: file, line: line)
    }

    // MARK: Health alerts and reminders (HealthNotificationCenter), as posted

    private func healthBodies(_ n: HealthNotification) -> [String] {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 9))!
        let older = cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 23, minute: 59))!
        switch n {
        case .headacheSigns:
            let f = HeadacheSignals.Feature.allCases
            var picks: [[HeadacheSignals.Feature]] = [[]] + f.map { [$0] }
            for a in f { for b in f where b != a { picks.append([a, b]); picks.append([a, b, a]) } }
            return picks.map { HealthNotificationCenter.copy(for: n, hit: nil, signals: $0).body }
        case .illnessSigns:
            let prior = (0..<5).map {
                IllnessSignals.NightVitals(night: Date(timeIntervalSince1970: Double($0) * 86_400),
                                           restingHR: 52, hrv: 80, respiratoryRate: 13)
            }
            let tonight = IllnessSignals.NightVitals(night: Date(timeIntervalSince1970: 9 * 86_400),
                                                     restingHR: 99, hrv: 11, respiratoryRate: 23.75)
            let all = IllnessSignals.assess(tonight: tonight, prior: prior, skinTempOffsetC: 3.45)
            XCTAssertEqual(all.signals.count, 4, "the worst case names every vital")
            return TemperatureUnit.allCases.map {
                HealthNotificationCenter.copy(for: n, hit: nil, illness: all, tempUnit: $0).body
            } + [HealthNotificationCenter.copy(for: n, hit: nil).body]
        default:
            let hit = HealthAlertHit(notification: n, value: 199, time: older)
            return [HealthNotificationCenter.copy(for: n, hit: hit, now: now, calendar: cal).body]
        }
    }

    func testEveryHealthAlertAndReminderFits() {
        for n in HealthNotification.allCases {
            for body in healthBodies(n) {
                assertFits(HealthNotificationCenter.postedBody(for: n, copy: body), n.rawValue)
            }
        }
    }

    // MARK: Sync and device alerts (LocalAlertCenter)

    func testEverySyncAlertFits() {
        for alert in SyncAlert.allCases {
            assertFits(LocalAlertCenter.copy(for: alert).body, "sync alert \(alert.rawValue)")
        }
    }

    // MARK: Ring alarm backup, detected workout, morning sleep summary

    func testTheAlarmBackupFits() {
        assertFits(RingAlarmController.backupCopy.body, "alarm backup")
    }

    func testEveryDetectedWorkoutFits() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 12, day: 30, hour: 23, minute: 59))!
        let starts = [now.addingTimeInterval(-60), cal.date(from: DateComponents(year: 2026, month: 12, day: 28,
                                                                                  hour: 23, minute: 58))!]
        let kinds: [AutomaticWorkoutDetector.SuggestedKind?] = [.walking, .running, nil]
        for kind in kinds {
            for start in starts {
                for duration: TimeInterval in [30, 89 * 60, 23 * 3600 + 59 * 60] {
                    let copy = RingSession.workoutDetectedCopy(kind: kind, duration: duration, start: start,
                                                               now: now, calendar: cal)
                    assertFits(copy.body, "workout detected")
                }
            }
        }
    }

    func testTheMorningSummaryFits() {
        assertFits(RingSession.morningSummaryCopy(asleepMin: 23 * 60 + 59).body, "morning summary")
    }

    // MARK: No posting site escapes the rule

    /// Every file that builds a notification, and how many times. A new site fails this until its copy
    /// is covered above and the count is updated here.
    static let knownPostingSites: [String: Int] = [
        "OpenCircuit/HealthNotificationCenter.swift": 1,
        "OpenCircuit/Observability/ObservabilityStore.swift": 1,
        "OpenCircuit/RingAlarmController.swift": 1,
        "OpenCircuit/BLE/RingSession.swift": 2,
    ]

    func testEveryNotificationPostingSiteIsCovered() throws {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var found: [String: Int] = [:]
        for dir in ["OpenCircuit", "OpenCircuitKit/Sources", "WorkoutWidget", "Shared"] {
            let root = ios.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let count = text.components(separatedBy: "UNMutableNotificationContent(").count - 1
                if count > 0 {
                    found[String(url.path.dropFirst(ios.path.count + 1)), default: 0] += count
                }
            }
        }
        XCTAssertFalse(found.isEmpty, "the scan must find the app's sources at \(ios.path)")
        XCTAssertEqual(found, Self.knownPostingSites,
                       "a notification is posted from a site this file doesn't check; add its copy above")
    }
}
