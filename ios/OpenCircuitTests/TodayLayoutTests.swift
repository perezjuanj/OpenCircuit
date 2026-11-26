import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for Edit Today (#394, decision 94): how the four stored layout strings decode,
/// what can and can't be hidden, the feature gates, that hiding is display-only, Reset, and Done vs
/// Cancel. No real health values.
final class TodayLayoutTests: XCTestCase {

    private let allOn = TodayFeatureGates(womensHealth: true, headache: true)
    private let allOff = TodayFeatureGates(womensHealth: false, headache: false)

    private func layout(order: String = "", hidden: String = "", tiles: String = "",
                        hiddenTiles: String = "") -> TodayLayout {
        TodayLayout(stored: .init(sectionOrder: order, hiddenSections: hidden, tileOrder: tiles,
                                  hiddenTiles: hiddenTiles))
    }

    // MARK: Decode

    func testEmptyKeysGiveTheDefaultLayout() {
        let l = layout()
        XCTAssertEqual(l, .standard)
        XCTAssertEqual(l.sections, DashboardSection.allCases)
        XCTAssertEqual(l.tiles, TodayTileID.allCases)
        XCTAssertTrue(l.hiddenSections.isEmpty)
        XCTAssertTrue(l.hiddenTiles.isEmpty)
    }

    func testGarbageInEveryKeyNeverLosesACard() {
        let l = layout(order: ",,🙃,metrics;goals, sync ,", hidden: "x,,,,y,Calories, calories",
                       tiles: "nope,,,HRV", hiddenTiles: "%%%,STEPS")
        XCTAssertEqual(Set(l.sections), Set(DashboardSection.allCases))
        XCTAssertEqual(l.sections.count, DashboardSection.allCases.count)
        XCTAssertEqual(l.tiles, TodayTileID.allCases)
        XCTAssertTrue(l.hiddenSections.isEmpty, "ids are case- and space-exact, like dashboard.sectionOrder")
        XCTAssertTrue(l.hiddenTiles.isEmpty)
        XCTAssertEqual(l.shownSections(gates: allOn), DashboardSection.allCases)
    }

    func testDuplicateTileIdsAreDroppedInPlace() {
        let l = layout(tiles: "steps,hrv,steps,spo2,hrv")
        XCTAssertEqual(l.tiles, [.steps, .hrv, .spo2, .restingHR, .respiratoryRate, .skinTemp, .stress, .pai])
        XCTAssertEqual(l.tiles.count, Set(l.tiles).count)
    }

    func testDuplicateSectionIdsAreDroppedInPlace() {
        let l = layout(order: "goals,calories,goals,metrics,calories")
        XCTAssertEqual(Array(l.sections.prefix(3)), [.goals, .calories, .metrics])
        XCTAssertEqual(l.sections.count, Set(l.sections).count)
    }

    func testDuplicateHiddenIdsHideOnce() {
        let l = layout(hidden: "calories,calories", hiddenTiles: "pai,pai,pai")
        XCTAssertEqual(l.hiddenSections, [.calories])
        XCTAssertEqual(l.hiddenTiles, [.pai])
        XCTAssertEqual(l.stored.hiddenSections, "calories")
        XCTAssertEqual(l.stored.hiddenTiles, "pai")
    }

    func testUnknownIdsAreDroppedWithoutDisturbingTheRest() {
        let l = layout(order: "sync,readiness,goals", hidden: "readiness,vitals,goals",
                       tiles: "pai,strain,hrv", hiddenTiles: "strain,hrv")
        XCTAssertEqual(Array(l.sections.prefix(3)), [.metrics, .sync, .goals],
                       "a missing Your Numbers goes first, as dashboard.sectionOrder always did")
        XCTAssertEqual(l.hiddenSections, [.goals])
        XCTAssertEqual(Array(l.tiles.prefix(2)), [.pai, .hrv])
        XCTAssertEqual(l.hiddenTiles, [.hrv])
    }

    /// A build that ships a new tile or card: an older saved order and hidden set don't name it, so it
    /// appears, visible, after the saved ones.
    func testIdsMissingFromASavedLayoutAreAppendedVisible() {
        let l = layout(order: "sync,goals", hidden: "goals", tiles: "steps,hrv", hiddenTiles: "steps")
        XCTAssertEqual(l.tiles, [.steps, .hrv, .restingHR, .spo2, .respiratoryRate, .skinTemp, .stress, .pai])
        for t in TodayTileID.allCases where t != .steps { XCTAssertTrue(l.isShown(t), "\(t)") }
        XCTAssertEqual(l.sections.count, DashboardSection.allCases.count)
        for s in DashboardSection.allCases where s != .goals { XCTAssertTrue(l.isShown(s), "\(s)") }
    }

    func testEncodeRoundTripsAndWritesHiddenSetsInCanonicalOrder() {
        var l = TodayLayout.standard
        l.setShown(.sync, false)
        l.setShown(.headache, false)
        l.setShown(.metrics, false)
        l.setShown(TodayTileID.skinTemp, false)
        l.setShown(TodayTileID.hrv, false)
        l.moveTiles(from: [5], to: 0, available: .init(stress: true, pai: true))
        let stored = l.stored
        XCTAssertEqual(stored.hiddenSections, "metrics,headache")
        XCTAssertEqual(stored.hiddenTiles, "hrv,skinTemp")
        XCTAssertEqual(stored.tileOrder, "steps,hrv,restingHR,spo2,respiratoryRate,skinTemp,stress,pai")
        XCTAssertEqual(TodayLayout(stored: stored), l)
    }

    func testEveryTodayTileMetricHasItsOwnStableId() {
        for m in TodayTile.Metric.allCases {
            XCTAssertEqual(TodayTileID(m).metric, m)
            XCTAssertEqual(TodayTileID(m).rawValue, m.rawValue)
        }
        XCTAssertNil(TodayTileID.stress.metric)
        XCTAssertNil(TodayTileID.pai.metric)
    }

    // MARK: What can be hidden

    func testTheScoresCardCanNeverBeHidden() {
        XCTAssertFalse(TodayLayout.canHide(.scores))
        // It is not a section, so no stored value can name it.
        XCTAssertNil(DashboardSection(rawValue: "scores"))
        XCTAssertNil(DashboardSection(rawValue: "readiness"))
    }

    func testHistoryAndSyncCanNeverBeHidden() {
        XCTAssertFalse(TodayLayout.canHide(.sync))
        var l = layout(hidden: "sync")
        XCTAssertTrue(l.isShown(.sync), "a stored sync id is ignored")
        XCTAssertTrue(l.hiddenSections.isEmpty)
        l.setShown(.sync, false)
        XCTAssertTrue(l.isShown(.sync))
        XCTAssertEqual(l.stored.hiddenSections, "")
        XCTAssertTrue(l.shownSections(gates: allOff).contains(.sync))
    }

    func testEveryOtherCardCanBeHidden() {
        for s in DashboardSection.allCases where s != .sync {
            XCTAssertTrue(TodayLayout.canHide(s), "\(s)")
        }
    }

    func testHidingEverythingOptionalStillLeavesHistoryAndSync() {
        var l = TodayLayout.standard
        for s in DashboardSection.allCases { l.setShown(s, false) }
        for t in TodayTileID.allCases { l.setShown(t, false) }
        XCTAssertEqual(l.shownSections(gates: allOn), [.sync])
        XCTAssertEqual(l.shownSections(gates: allOff), [.sync])
        XCTAssertTrue(l.shownTiles.isEmpty)
        // The rows stay in the sheet, so each can be turned back on.
        XCTAssertEqual(l.editableSections(gates: allOn), DashboardSection.allCases)
        XCTAssertEqual(l.editableTiles(available: .init(stress: true, pai: true)), TodayTileID.allCases)
    }

    // MARK: Feature gates

    func testCycleAndHeadacheExistOnlyWhileTheirFeatureIsOn() {
        let l = TodayLayout.standard
        XCTAssertFalse(l.editableSections(gates: allOff).contains(.cycle))
        XCTAssertFalse(l.editableSections(gates: allOff).contains(.headache))
        XCTAssertFalse(l.shownSections(gates: allOff).contains(.cycle))
        XCTAssertFalse(l.shownSections(gates: allOff).contains(.headache))
        let cycleOnly = TodayFeatureGates(womensHealth: true, headache: false)
        XCTAssertTrue(l.editableSections(gates: cycleOnly).contains(.cycle))
        XCTAssertFalse(l.editableSections(gates: cycleOnly).contains(.headache))
        XCTAssertTrue(l.shownSections(gates: allOn).contains(.headache))
    }

    func testTheGateAndTheHiddenFlagBothApply() {
        let l = layout(hidden: "cycle")
        XCTAssertFalse(l.shownSections(gates: allOn).contains(.cycle), "on but hidden")
        XCTAssertTrue(l.editableSections(gates: allOn).contains(.cycle))
        let shownButGated = layout()
        XCTAssertFalse(shownButGated.shownSections(gates: allOff).contains(.cycle), "shown but feature off")
    }

    func testStrapTilesAreListedOnlyWhileTheyWouldShow() {
        let l = TodayLayout.standard
        XCTAssertEqual(l.editableTiles(available: .ringOnly), [.hrv, .restingHR, .spo2, .respiratoryRate, .skinTemp, .steps])
        XCTAssertEqual(l.editableTiles(available: .init(stress: true, pai: false)).last, .stress)
        XCTAssertEqual(l.editableTiles(available: .init(stress: false, pai: true)).last, .pai)
    }

    // MARK: Display-only

    /// Hiding tiles and the whole Your Numbers card never changes the sentence's input: it is built from
    /// every tile (decision 94c).
    func testHidingTilesNeverChangesTheSentence() {
        // The sentence judges staleness on the device calendar, so the fixture uses it too: local noon.
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        let points = (0..<6).map { i in
            TrendsEngine.DailyPoint(date: day(i - 5), skinTempC: i == 5 ? 33.9 : 33.5, sleepHRVAvg: i == 5 ? 40 : 50)
        }
        let rhr = (0..<6).map { RestingHR.DailyValue(day: day($0 - 5), bpm: $0 == 5 ? 61 : 58) }
        let all = TodayTiles.build(points: points, restingHR: rhr, tempUnit: .celsius, now: now, calendar: cal)
        var trends = TrendsData()
        trends.points = points
        trends.newestSampleAt = now.addingTimeInterval(-3600)
        func input(_ l: TodayLayout) -> TodaySynthesis.Input {
            TodaySynthesis.input(trends: trends, tiles: l.synthesisTiles(all), readiness: nil,
                                 lastSyncAt: now, now: now)
        }

        let baseline = input(.standard)
        XCTAssertEqual(baseline.hrv, .below, "the fixture must reach the sentence, or this test proves nothing")
        XCTAssertEqual(baseline.restingHR, .above)
        XCTAssertEqual(baseline.skinTemp, .above)

        var hidden = TodayLayout.standard
        for t in TodayTileID.allCases { hidden.setShown(t, false) }
        XCTAssertEqual(input(hidden), baseline)
        hidden.setShown(.metrics, false)
        hidden.setShown(.vitalsStatus, false)
        XCTAssertEqual(input(hidden), baseline)
        XCTAssertEqual(TodaySynthesis.sentence(input(hidden)), TodaySynthesis.sentence(baseline))
        XCTAssertEqual(hidden.synthesisTiles(all).map(\.metric), TodayTile.Metric.allCases)
    }

    /// The Vitals Status fever verdict is a sentence input, so its report keeps running while the card
    /// is hidden.
    func testAHiddenVitalsStatusStillReportsToTheSentence() {
        XCTAssertFalse(TodayLayout.standard.runsHiddenVitalsReport)
        XCTAssertTrue(layout(hidden: "vitalsStatus").runsHiddenVitalsReport)
        XCTAssertFalse(layout(hidden: "calories,goals,metrics").runsHiddenVitalsReport)
    }

    // MARK: Order

    func testTileOrderIsWhatTheGridDraws() {
        let l = layout(tiles: "steps,pai,hrv", hiddenTiles: "hrv")
        XCTAssertEqual(l.shownTiles, [.steps, .pai, .restingHR, .spo2, .respiratoryRate, .skinTemp, .stress])
    }

    func testMovingATileKeepsAnUnavailableStrapTileInItsPlace() {
        var l = layout(tiles: "hrv,stress,restingHR,spo2,respiratoryRate,skinTemp,steps,pai")
        // Ring only: the sheet lists six rows; drag Steps (row 5) to the top.
        l.moveTiles(from: [5], to: 0, available: .ringOnly)
        XCTAssertEqual(l.tiles, [.steps, .stress, .hrv, .restingHR, .spo2, .respiratoryRate, .skinTemp, .pai])
    }

    func testMovingACardInTheSheetKeepsAGatedCardInItsPlace() {
        var l = TodayLayout.standard   // metrics, vitalsStatus, calories, goals, cycle, headache, sync
        // Cycle and Headache off: the sheet lists metrics, vitalsStatus, calories, goals, sync.
        l.moveSections(from: [4], to: 0, gates: allOff)
        XCTAssertEqual(l.sections, [.sync, .metrics, .vitalsStatus, .calories, .cycle, .headache, .goals])
        XCTAssertEqual(l.stored.sectionOrder, "sync,metrics,vitalsStatus,calories,cycle,headache,goals")
    }

    /// The in-list long-press reorder moves among the SHOWN sections and writes dashboard.sectionOrder
    /// by the same rule as before: a hidden card is merged back at its prior position.
    func testTheInListReorderMovesShownCardsAndKeepsHiddenOnes() {
        let l = layout(hidden: "calories")
        let shown = l.shownSections(gates: allOff)
        XCTAssertEqual(shown, [.metrics, .vitalsStatus, .goals, .sync])
        let written = DashboardSectionOrder.encode(
            DashboardSectionOrder.reordered(full: l.sections, visible: shown, from: [2], to: 0))
        XCTAssertEqual(written, "goals,metrics,calories,vitalsStatus,cycle,headache,sync")
        XCTAssertEqual(TodayLayout.Keys.sectionOrder, "dashboard.sectionOrder")
    }

    // MARK: Reset, Done, Cancel

    func testResetRestoresOrderAndShowsEverything() {
        var l = layout(order: "sync,goals,calories", hidden: "goals,metrics", tiles: "pai,steps,hrv",
                       hiddenTiles: "steps,spo2")
        l.reset()
        XCTAssertEqual(l, .standard)
        XCTAssertEqual(l.sections, DashboardSection.allCases)
        XCTAssertEqual(l.tiles, TodayTileID.allCases)
        XCTAssertTrue(l.hiddenSections.isEmpty)
        XCTAssertTrue(l.hiddenTiles.isEmpty)
    }

    func testDoneAppliesTheDraftAndCancelDiscardsIt() {
        let saved = layout(order: "goals", hidden: "calories")
        var edit = TodayLayoutEdit(saved)
        edit.draft.setShown(.calories, true)
        edit.draft.setShown(.goals, false)
        edit.draft.setShown(TodayTileID.steps, false)
        edit.draft.moveTiles(from: [0], to: 3, available: .ringOnly)
        XCTAssertEqual(edit.result(.cancel), saved)
        XCTAssertEqual(edit.result(.done), edit.draft)
        XCTAssertNotEqual(edit.result(.done), saved)
        XCTAssertTrue(edit.result(.done).isShown(.calories))
        XCTAssertFalse(edit.result(.cancel).isShown(.calories))
    }

    func testResetIsADraftChangeUntilDone() {
        let saved = layout(hidden: "goals", tiles: "steps")
        var edit = TodayLayoutEdit(saved)
        edit.draft.reset()
        XCTAssertEqual(edit.result(.cancel), saved)
        XCTAssertEqual(edit.result(.done), .standard)
    }

    // MARK: Copy

    func testRowNamesAndSpokenNames() {
        XCTAssertEqual(DashboardSection.allCases.map(\.editTitle),
                       ["Your Numbers", "Vitals Status", "Calories", "Daily Goals", "Cycle", "Headache log",
                        "History & Sync"])
        XCTAssertEqual(TodayTileID.respiratoryRate.spokenTitle, "respiratory rate")
        for t in TodayTileID.allCases { XCTAssertFalse(t.title.isEmpty) }
    }
}
