import XCTest
@testable import OpenCircuitKit

final class NotificationBudgetTests: XCTestCase {
    func testWrapCountsLikeALabel() {
        XCTAssertEqual(NotificationBudget.wrappedLines("abc def", width: 7), 1)
        XCTAssertEqual(NotificationBudget.wrappedLines("abc defg", width: 7), 2)
        XCTAssertEqual(NotificationBudget.wrappedLines("abc\ndef", width: 42), 2)
        XCTAssertEqual(NotificationBudget.wrappedLines("abc\n\ndef", width: 42), 3, "a blank line costs a line")
        XCTAssertEqual(NotificationBudget.wrappedLines("abcdefghij k", width: 5), 2, "a long word takes its own line")
        XCTAssertEqual(NotificationBudget.wrappedLines("", width: 42), 1)
    }

    func testTheBudgetIsFiveLinesAtFortyTwo() {
        let fiveLines = Array(repeating: String(repeating: "x", count: 42), count: 5).joined(separator: " ")
        XCTAssertTrue(NotificationBudget.fits(fiveLines))
        XCTAssertFalse(NotificationBudget.fits(fiveLines + " y"))
    }

    /// The body build 86 actually posted, which iOS cut on a real phone. It must fail the rule.
    func testTheBuild86IllnessBodyFails() {
        let posted = "Last night your skin temperature was 0.7 °C higher, sleeping heart rate was 11 bpm higher "
            + "and HRV was 20% lower compared with your usual. This pattern often shows up early in a cold "
            + "or other infection, though alcohol, a late meal, a hot room or hard training can cause it too "
            + "(estimate).\n\nNote: OpenCircuit is not a medical device. These reminders are based on your "
            + "device's sensor data only and are not a diagnosis. If you feel unwell, consult a qualified "
            + "medical professional."
        XCTAssertFalse(NotificationBudget.fits(posted))
        XCTAssertGreaterThan(NotificationBudget.wrappedLines(posted), 10)
    }
}
