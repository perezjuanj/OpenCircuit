import XCTest
@testable import OpenCircuit

final class SleepFocusSyncFilterTests: XCTestCase {
    func testConfiguredActiveFocusOnlyArmsTheTrigger() {
        XCTAssertFalse(SleepFocusSyncFilter.shouldSync(focusIsActive: true))
    }

    func testDefaultParametersAtFocusEndTriggerSync() {
        XCTAssertTrue(SleepFocusSyncFilter.shouldSync(focusIsActive: false))
    }
}
