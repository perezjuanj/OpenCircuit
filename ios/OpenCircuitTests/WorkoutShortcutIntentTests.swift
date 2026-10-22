import AppIntents
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// "Start Workout" (WorkoutShortcutIntent.swift). The start rules themselves are pinned in the Kit
/// (`WorkoutShortcutStartTests`); this file pins the shortcut's own surface.
@MainActor
final class WorkoutShortcutIntentTests: XCTestCase {

    override func tearDown() {
        WorkoutShortcutInbox.shared.clear()
        super.tearDown()
    }

    /// Every type the app can record is offered, once, under the name the in-app picker uses.
    func testTheShortcutOffersEveryWorkoutTypeUnderItsInAppName() {
        XCTAssertEqual(WorkoutTypeChoice.allCases.count, WorkoutSportType.allCases.count)
        XCTAssertEqual(Set(WorkoutTypeChoice.allCases.map(\.sport)), Set(WorkoutSportType.allCases))
        for choice in WorkoutTypeChoice.allCases {
            let rep = try? XCTUnwrap(WorkoutTypeChoice.caseDisplayRepresentations[choice])
            XCTAssertEqual(rep.map { String(localized: $0.title) }, choice.sport.displayName, choice.rawValue)
            XCTAssertEqual(choice.rawValue, choice.sport.rawValue, "same identifiers, so neither list can drift")
        }
    }

    func testRunningTheShortcutHandsTheChosenTypeToTheApp() async throws {
        XCTAssertNil(WorkoutShortcutInbox.shared.pending)
        _ = try await StartWorkoutIntent(workoutType: .cyclingIndoor).perform()
        XCTAssertEqual(WorkoutShortcutInbox.shared.pending?.sport, .cyclingIndoor)
        // A second run before the first was applied: the newer choice wins.
        _ = try await StartWorkoutIntent(workoutType: .yoga).perform()
        XCTAssertEqual(WorkoutShortcutInbox.shared.pending?.sport, .yoga)
    }

    func testTheInboxStampsAndClears() {
        let t = Date(timeIntervalSince1970: 1_792_700_000)
        let inbox = WorkoutShortcutInbox(clock: { t })
        inbox.submit(.hiking)
        XCTAssertEqual(inbox.pending, WorkoutShortcutStart.Request(sport: .hiking, requestedAt: t))
        inbox.clear()
        XCTAssertNil(inbox.pending)
    }

    /// A workout is watched as it starts, so the shortcut opens the app.
    func testTheShortcutOpensTheApp() {
        XCTAssertTrue(StartWorkoutIntent.openAppWhenRun)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(StartWorkoutIntent.supportedModes, .foreground)
        }
    }

    /// Apple shows at most 10 App Shortcuts per app; past that the extra ones silently don't appear.
    /// (The exact list is pinned by `StrapWakeAlarmPlannerTests.testTheProviderListsEveryShortcutInOrder`.)
    func testTheAppShortcutsStayUnderApplesLimit() {
        XCTAssertLessThanOrEqual(OpenCircuitAppShortcuts.appShortcuts.count, 10)
    }
}
