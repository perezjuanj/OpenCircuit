import XCTest
@testable import OpenCircuitKit

/// A NO-REGRESSION LOCK on the four shipped notification families (#73 HR/SpO2, #85 temp/fever,
/// #84 reminders, #86 charging).
///
/// `NotificationGate.filter` returns survivors in `HealthNotification.allCases` DECLARATION ORDER,
/// and `HealthNotificationStore` persists the de-dupe ledgers keyed by `rawValue`. So the enum has
/// two silent-breakage modes that no other test would catch:
///
///  1. INSERTING a case rather than appending reorders delivery for every pair after it — a shipped
///     behaviour change with no compiler error and no visible diff at the call sites;
///  2. RENAMING a case without an explicit `rawValue` orphans that notification's persisted
///     `alerts.health.lastFired` / `alerts.health.lastNight` entries, re-arming an alert that had
///     already fired (for the per-night/per-day ledgers, that means a duplicate the user sees).
///
/// This file pins the first twelve rawValues, in order, as they shipped. It deliberately does NOT
/// pin `allCases.count`: appending a THIRTEENTH case is the safe operation, and the whole point is
/// to make appending easy and inserting loud.
final class HealthNotificationOrderTests: XCTestCase {

    /// The twelve shipped notifications, in declaration order, with their persisted rawValues.
    private let shipped = [
        // #73 — heart rate & blood oxygen
        "highHR",
        "lowSpO2",
        "elevatedHRInactive",
        // #85 — skin temperature + fever
        "skinTempRise",
        "skinTempDrop",
        "skinTempFluctuationRise",
        "skinTempFluctuationDrop",
        "fever",
        // #84 — app-side reminders
        "reminder.sedentary",
        "reminder.wear",
        "reminder.bedtime",
        // #86 — battery
        "battery.chargingComplete",
    ]

    func testShippedTwelveKeepTheirOrderAndRawValues() {
        XCTAssertEqual(Array(HealthNotification.allCases.prefix(12)).map(\.rawValue), shipped,
                       "A case was inserted or renamed. Append at the END and give it an explicit "
                       + "rawValue — see the file comment.")
    }

    func testHeadacheSignsIsAppendedAfterAllTwelve() throws {
        let index = try XCTUnwrap(HealthNotification.allCases.firstIndex(of: .headacheSigns))
        XCTAssertGreaterThanOrEqual(index, 12, "#183 must sit AFTER every shipped case")
        XCTAssertEqual(HealthNotification.headacheSigns.rawValue, "headache.signs")
    }

    /// The property the ordering actually protects: the gate emits survivors in declaration order
    /// regardless of the order the caller assembled its candidates in.
    func testGateFilterReturnsDeclarationOrderNotCallerOrder() {
        let now = Date(timeIntervalSince1970: 1_753_700_000)
        let scrambled: [HealthNotification] = [.chargingComplete, .fever, .highHR, .wearReminder]
        let out = NotificationGate().filter(scrambled, now: now, lastFired: [:],
                                            quietHours: QuietHours(enabled: false))
        XCTAssertEqual(out, [.highHR, .fever, .wearReminder, .chargingComplete])
    }

    /// Appending `.headacheSigns` must not have disturbed the relative order of any shipped pair.
    func testAppendingDidNotReorderAnyShippedPair() throws {
        let positions = Dictionary(uniqueKeysWithValues:
            HealthNotification.allCases.enumerated().map { ($0.element.rawValue, $0.offset) })
        for (i, earlier) in shipped.enumerated() {
            for later in shipped[(i + 1)...] {
                XCTAssertLessThan(try XCTUnwrap(positions[earlier]), try XCTUnwrap(positions[later]),
                                  "\(earlier) must still be delivered before \(later)")
            }
        }
    }
}
