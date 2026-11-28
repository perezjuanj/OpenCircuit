import SwiftUI
import UIKit
import XCTest
@testable import OpenCircuit

/// Edit Today (#394, decision 94), hosted: the wiring the model tests can't reach. The Edit sheet is
/// driven only through its accessibility elements (what VoiceOver gets), at the default and the
/// largest accessibility text size, and the hidden Vitals Status runner is hosted over a probe view.
/// SYNTHETIC layouts only.
@MainActor
final class EditTodayHostedTests: XCTestCase {

    private let gates = TodayFeatureGates(womensHealth: false, headache: false)

    private func pump(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func host<V: View>(_ view: V, height: CGFloat = 1200) -> (UIWindow, UIHostingController<AnyView>) {
        AccessibilityTestSupport.enableAutomation()
        let vc = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        pump(1.5)
        vc.view.layoutIfNeeded()
        return (window, vc)
    }

    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    // MARK: Vitals Status report (review S-1, M7; since decision 95a one runner for every layout)

    // Amended in #396 fix round 1: the hidden-card runner (`HiddenVitalsReport`) is gone. Today computes
    // the report ONCE in `TodayVitalsRunner`, behind the whole tab, so a hidden card (and a shown one
    // below the fold) still feeds the sentence and Recovery, and the card itself only displays it. The
    // hosted proof over every layout is `TodayVitalsHostedTests`; these pin the ContentView wiring.

    func testTheVitalsReportRunsOnceBehindTheTabWhateverTheLayout() throws {
        let content = try contentView()
        XCTAssertEqual(content.components(separatedBy: "TodayVitalsRunner(").count, 2, "exactly one copy runs")
        XCTAssertFalse(content.contains("HiddenVitalsReport"))
        let tab = try XCTUnwrap(content.range(of: "private var todayTab: some View {"))
        let list = try XCTUnwrap(content.range(of: "private var todayList: some View {"))
        let runner = try XCTUnwrap(content.range(of: "TodayVitalsRunner("))
        XCTAssertTrue(runner.lowerBound > tab.upperBound && runner.lowerBound < list.lowerBound,
                      "the runner sits on todayTab, outside the lazy list, so it never depends on a row")
    }

    func testTodaysVitalsCardOnlyDisplaysTheRunnersReport() throws {
        let content = try contentView()
        let card = try XCTUnwrap(content.range(of: "private var vitalsStatusCard: some View {"))
        XCTAssertTrue(String(content[card.upperBound...].prefix(200)).contains("VitalsStatusCardView(report: todayVitals.report)"))
        XCTAssertFalse(content.contains("VitalsStatusCardView(onReport:"), "a second computation is back on Today")
    }

    // MARK: The sheet, through accessibility

    @MainActor private struct Sheet {
        let window: UIWindow
        let root: UIView
        let finished: Box<[TodayLayout]>

        func element(_ label: String) -> NSObject? {
            AccessibilityTestSupport.elements(in: root).first { $0.accessibilityLabel == label }
        }
    }

    private func sheet(_ layout: TodayLayout, size: DynamicTypeSize = .large) -> Sheet {
        let finished = Box<[TodayLayout]>([])
        let view = EditTodaySheet(layout: layout, gates: gates, tiles: .ringOnly) { finished.value.append($0) }
            .environment(\.dynamicTypeSize, size)
        let (window, vc) = host(view, height: size.isAccessibilitySize ? 9000 : 2400)
        return Sheet(window: window, root: vc.view, finished: finished)
    }

    private func perform(_ actionName: String, on element: NSObject) -> Bool {
        guard let action = element.accessibilityCustomActions?.first(where: { $0.name == actionName }) else {
            return false
        }
        if let handler = action.actionHandler { return handler(action) }
        if let target = action.target as? NSObject {
            target.perform(action.selector, with: action)
            return true
        }
        return false
    }

    private func checkRows(size: DynamicTypeSize) throws {
        let s = sheet(.standard, size: size)
        let labels = AccessibilityTestSupport.labels(in: s.root)
        let calories = try XCTUnwrap(s.element("Show Calories"), "no \"Show Calories\" element at \(size): \(labels)")
        let names = calories.accessibilityCustomActions?.map(\.name) ?? []
        XCTAssertTrue(names.contains("Move up") && names.contains("Move down"),
                      "the Move actions are not on the switch's element at \(size): \(names)")
        XCTAssertEqual(calories.accessibilityValue, "On")
        XCTAssertNotNil(s.element("Show respiratory rate"), "tiles use their spoken name: \(labels)")
        // One element per row: no bare title VoiceOver could land on without the switch and its actions,
        // and the List's own reorder control names the same row.
        XCTAssertFalse(labels.contains("Calories"), "a bare \"Calories\" element at \(size): \(labels)")
        XCTAssertTrue(labels.contains("Reorder Show Calories"), "no reorder control for the row: \(labels)")
        withExtendedLifetime(s.window) {}
    }

    func testEachSwitchRowIsOneElementWithItsMoveActions() throws {
        try checkRows(size: .large)
    }

    func testEachSwitchRowIsOneElementWithItsMoveActionsAtTheLargestTextSize() throws {
        try checkRows(size: .accessibility5)
    }

    /// Cancel hands back the layout the sheet opened on, after a change was made (review M6).
    func testCancelDiscardsAChangeMadeInTheSheet() throws {
        let s = sheet(.standard)
        let calories = try XCTUnwrap(s.element("Show Calories"))
        XCTAssertTrue(calories.accessibilityActivate(), "the switch row didn't take the activation")
        pump()
        XCTAssertEqual(s.element("Show Calories")?.accessibilityValue, "Off", "the activation didn't switch it")
        XCTAssertTrue(tap("Cancel", in: s.window), "no Cancel button")
        pump()
        XCTAssertEqual(s.finished.value, [.standard])
        withExtendedLifetime(s.window) {}
    }

    /// Done hands back the draft: a switch turned off and a row moved with VoiceOver's Move down.
    func testDoneAppliesASwitchAndAMoveMadeThroughAccessibility() throws {
        let s = sheet(.standard, size: .accessibility5)
        XCTAssertTrue(try XCTUnwrap(s.element("Show Calories")).accessibilityActivate())
        pump()
        XCTAssertTrue(perform("Move down", on: try XCTUnwrap(s.element("Show Your Numbers"))), "Move down failed")
        pump()
        XCTAssertTrue(tap("Done", in: s.window), "no Done button")
        pump()
        var expected = TodayLayout.standard
        expected.setShown(.calories, false)
        expected.moveSections(from: [0], to: 2, gates: gates)
        XCTAssertEqual(s.finished.value, [expected])
        XCTAssertEqual(s.finished.value.first?.sections.prefix(2), [.vitalsStatus, .metrics])
        withExtendedLifetime(s.window) {}
    }

    /// Taps a toolbar button the way VoiceOver does. Its label appears on more than one node (the bar
    /// item and its content), so every node with the exact label is tried until one takes it.
    private func tap(_ label: String, in root: UIView) -> Bool {
        AccessibilityTestSupport.elements(in: root)
            .filter { $0.accessibilityLabel == label }
            .contains { $0.accessibilityActivate() }
    }

    // MARK: Today's call sites (the same source check TodayScoresTests uses for todayList)

    private func contentView() throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenCircuit")
        return try String(contentsOf: app.appendingPathComponent("ContentView.swift"), encoding: .utf8)
    }

    /// Today builds its sentence through `sentenceInput` (tested in TodayLayoutTests), never from a tile
    /// list of its own. (Amended in #396 fix round 1: the runner half moved to the tests above.)
    func testTodayWiresTheRunnerAndTheSentenceThroughTheTestedSeams() throws {
        let content = try contentView()
        XCTAssertTrue(content.contains("feverSuspected: vitalsFeverSuspected"), "the sentence lost the runner's fever flag")
        XCTAssertTrue(content.contains("private var vitalsFeverSuspected: Bool { todayVitals.report?.feverSuspected == true }"))
        let sentence = try XCTUnwrap(content.range(of: "private func synthesisSentence("))
        let body = String(content[sentence.upperBound...].prefix(900))
        XCTAssertTrue(body.contains("todayLayout.sentenceInput("), "the sentence no longer goes through sentenceInput")
        XCTAssertFalse(body.contains("TodaySynthesis.input("), "the sentence builds its own input again")
    }

    func testTheToolbarButtonsMapToTheirOutcomes() {
        XCTAssertEqual(EditTodaySheet.outcome(for: .cancel), .cancel)
        XCTAssertEqual(EditTodaySheet.outcome(for: .done), .done)
    }
}
