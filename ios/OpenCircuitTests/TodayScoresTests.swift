import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Today's scores card (#391, decision 93): the pure model behind the Sleep, Recovery and Strain dials,
// and the invariants a reviewer probes (SCOPE §5):
//   I1  the Sleep dial and the Sleep tab's badge read one night by one rule;
//   I2  the Recovery dial, the Recovery detail and the sentence carry one number;
//   I3  the Strain dial is `trends.todayStrain`;
//   I4  no dial shows 0 for a missing input (pinned in TodayScoresCopyTests);
//   I5  copy names no device (TodayScoresCopyTests);
//   I6  only the no-night state advises a sync (TodayScoresCopyTests).
// Plus the removals: the Readiness section and the Strain tile are gone from Today.
//
// Every value is synthetic and every date is in the past.

final class TodayScoresTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-05-28 14:13 UTC: an early afternoon, wholly in the past.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var today: Date { cal.startOfDay(for: now) }

    /// A night whose wake is `wake` (in bed `asleep + 40` minutes before it).
    private func night(wake: Date, score: Int, stress: Int, asleep: Int = 437) -> TodayScores.Night {
        .init(nightKey: cal.startOfDay(for: wake), inBedStart: wake.addingTimeInterval(-Double(asleep + 40) * 60),
              inBedEnd: wake, sleepScore: score, stressScore: stress, asleepMin: asleep)
    }
    private var thisMorning: Date { today.addingTimeInterval(6.75 * 3600) }

    private func strain(_ value: Double?, seconds: Int, rhr: Int? = 54) -> DailyStrain.Reading {
        DailyStrain.Reading(strain: value, coveredSeconds: seconds, latestSampleAt: seconds > 0 ? now : nil,
                            maxHR: 185, restingHR: rhr)
    }

    private func build(_ n: TodayScores.Night?, strain s: DailyStrain.Reading? = nil,
                       loaded: Bool = true) -> TodayScores {
        TodayScores.build(night: n, strain: s, trendsLoaded: loaded, now: now, calendar: cal)
    }

    // MARK: Scored

    /// The SCOPE's worked night: sleep 85 and overnight recovery 0.76 (stress 33) give Recovery 82, Good.
    func testAScoredNightThatEndedTodayFillsAllThreeDials() throws {
        let reading = strain(8.4, seconds: 5_400)
        let s = build(night(wake: thisMorning, score: 85, stress: 33), strain: reading)

        XCTAssertEqual(s.sleep, .scored(score: 85, asleepMin: 437))
        let r = try XCTUnwrap(s.recovery.result)
        XCTAssertEqual(r.score, 82)
        XCTAssertEqual(r.tier, .good)
        XCTAssertFalse(s.recovery.isLowConfidence)
        XCTAssertEqual(s.strain, .scored(reading))
        XCTAssertEqual(s.report, ReadinessReport(readiness: .scored(score: 82, tier: .good, factorCount: 2),
                                                 lastNightAsleepMin: 437))
    }

    /// I2: the sentence is built from the card's own report, so it names the dial's number.
    func testTheSentenceNamesTheRecoveryTheDialShows() throws {
        let s = build(night(wake: thisMorning, score: 85, stress: 33))
        let sentence = TodaySynthesis.sentence(.init(readiness: s.report.readiness, hrv: .within, restingHR: .within,
                                                     lastNightSleepMinutes: s.report.lastNightAsleepMin,
                                                     newestDataAt: now, now: now))
        XCTAssertEqual(sentence, "Recovery is good at 82, with HRV and resting heart rate in your usual range.")
        XCTAssertEqual(TodayScoresCopy.recoveryValue(s.recovery), "82")
        XCTAssertFalse(sentence.contains("Readiness"))
    }

    /// D1: no activity term. Today's activity is not an input at all, so the morning number holds all day.
    func testRecoveryIsTheKitsRecoveryScoreWithNoActivity() throws {
        let s = build(night(wake: thisMorning, score: 85, stress: 33))
        XCTAssertEqual(s.recovery.result, WellnessBalance.recoveryScore(sleepScore: 85, overnightStress: 33))
        XCTAssertEqual(Set(try XCTUnwrap(s.recovery.result).factors.keys), [.sleep, .recovery])
    }

    func testSleepAloneScoresAtLowConfidence() throws {
        let s = build(night(wake: thisMorning, score: 52, stress: 0, asleep: 308))
        let r = try XCTUnwrap(s.recovery.result)
        XCTAssertEqual(r.score, 52)
        XCTAssertEqual(r.tier, .needsImprovement)
        XCTAssertTrue(s.recovery.isLowConfidence, "the dial's track is dashed")
        XCTAssertEqual(s.report.readiness, .scored(score: 52, tier: .needsImprovement, factorCount: 1))
    }

    // MARK: Gaps

    func testNoStoredNightIsNoNight() {
        let s = build(nil)
        XCTAssertEqual(s.sleep, .noNight)
        XCTAssertEqual(s.recovery, .noNight)
        XCTAssertEqual(s.report, ReadinessReport(readiness: .noNight, lastNightAsleepMin: nil))
    }

    func testAStoredNightWithoutAScoreIsNoScoreNotNoNight() {
        let s = build(night(wake: thisMorning, score: 0, stress: 30, asleep: 401))
        XCTAssertEqual(s.sleep, .noScore)
        XCTAssertEqual(s.recovery, .noScore)
        XCTAssertEqual(s.report, ReadinessReport(readiness: .noScore, lastNightAsleepMin: 401))
    }

    /// The off-by-one guard: a night that ended a minute before midnight is yesterday's, and one that
    /// ended a minute after is today's.
    func testOnlyANightThatEndedTodayCounts() {
        let lateYesterday = build(night(wake: today.addingTimeInterval(-60), score: 85, stress: 33))
        XCTAssertEqual(lateYesterday.sleep, .noNight)
        XCTAssertEqual(lateYesterday.recovery, .noNight)

        let justAfterMidnight = build(night(wake: today.addingTimeInterval(60), score: 85, stress: 33))
        XCTAssertEqual(justAfterMidnight.sleep, .scored(score: 85, asleepMin: 437))

        let twoDaysAgo = build(night(wake: thisMorning.addingTimeInterval(-2 * 86_400), score: 85, stress: 33))
        XCTAssertEqual(twoDaysAgo.sleep, .noNight)
    }

    /// A legacy rollup with no wake time is judged by its night key, as everywhere else.
    func testALegacyRowWithNoWakeIsJudgedByItsNightKey() {
        let legacy = TodayScores.Night(nightKey: today, inBedStart: .distantPast, inBedEnd: .distantPast,
                                       sleepScore: 80, stressScore: 0, asleepMin: 420)
        XCTAssertEqual(build(legacy).sleep, .scored(score: 80, asleepMin: 420))
        var old = legacy
        old.nightKey = today.addingTimeInterval(-86_400)
        XCTAssertEqual(build(old).sleep, .noNight)
    }

    // MARK: Midnight

    /// The card follows the calendar day (#297): the same stored night that is "last night" at 23:55
    /// is yesterday's two minutes after midnight, so Sleep and Recovery go back to "No night yet"
    /// without waiting for a sync or a relaunch.
    @MainActor
    func testTheCardReJudgesLastNightAfterMidnight() throws {
        let container = try ModelContainer(for: StoredSleepSummary.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let n = night(wake: thisMorning, score: 85, stress: 33)
        container.mainContext.insert(StoredSleepSummary(night: n.nightKey, asleepMin: n.asleepMin,
                                                        inBedStart: n.inBedStart, inBedEnd: n.inBedEnd,
                                                        sleepScore: n.sleepScore, stressScore: n.stressScore))
        try container.mainContext.save()

        final class Seen { var now: Date = .distantPast; var scores: [TodayScores] = [] }
        let seen = Seen()
        seen.now = today.addingTimeInterval(23 * 3600 + 55 * 60)
        let cal = self.cal
        let vc = UIHostingController(rootView: AnyView(
            TodayScoresSource(strain: nil, trendsLoaded: true) { scores in
                Color.clear
                    .onAppear { seen.scores.append(scores) }
                    .onChange(of: scores) { _, new in seen.scores.append(new) }
            }
            .environment(\.dayClock, DayClock(now: { seen.now }, calendar: { cal }))
            .modelContainer(container)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        XCTAssertEqual(seen.scores.last?.sleep, .scored(score: 85, asleepMin: 437), "23:55, same day")
        XCTAssertEqual(seen.scores.last?.recovery.result?.score, 82)

        seen.now = today.addingTimeInterval(86_400 + 120)
        NotificationCenter.default.post(name: .currentDayMayHaveChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        XCTAssertEqual(seen.scores.last?.sleep, .noNight, "00:02 the next day: \(seen.scores.map(\.sleep))")
        XCTAssertEqual(seen.scores.last?.recovery, .noNight)
        window.rootViewController = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    // MARK: I1 — one night, one rule

    /// The credit rule is the Kit's `MissedNight.endedToday`, the one the Goals Sleep ring and the
    /// Sleep card's missed-night banner use, across a sweep of wake times.
    func testTheCreditRuleIsTheSharedEndedTodayRule() {
        for hours in stride(from: -50.0, through: 13.0, by: 0.5) {
            let wake = today.addingTimeInterval(hours * 3600)
            let n = night(wake: wake, score: 70, stress: 40)
            let expected = MissedNight.endedToday(inBedEnd: wake, nightKey: n.nightKey, now: now, calendar: cal)
            XCTAssertEqual(LastNight.isCredited(nightKey: n.nightKey, inBedStart: n.inBedStart, inBedEnd: n.inBedEnd,
                                                now: now, calendar: cal), expected, "wake \(hours) h")
            XCTAssertEqual(build(n).sleep != .noNight, expected, "wake \(hours) h")
        }
    }

    /// The Sleep dial and the Sleep tab's badge read the score through one function, and the badge's
    /// call site, the Goals ring's and the card's go through `LastNight` rather than a copy of it.
    func testTheSleepDialAndTheSleepTabBadgeShareOneRule() throws {
        XCTAssertNil(LastNight.score(0), "0 is the never-scored sentinel")
        XCTAssertNil(LastNight.score(nil))
        XCTAssertEqual(LastNight.score(85), 85)
        for score in [0, 1, 52, 85, 100] {
            let dial = build(night(wake: thisMorning, score: score, stress: 33)).sleep
            if let badge = LastNight.score(score) {
                XCTAssertEqual(dial, .scored(score: badge, asleepMin: 437))
            } else {
                XCTAssertEqual(dial, .noScore)
            }
        }
        XCTAssertTrue(try source("SleepCardView.swift").contains("LastNight.score(latest?.sleepScore)"),
                      "the Sleep tab's badge must read the score through LastNight.score")
        XCTAssertTrue(try source("GoalsCardView.swift").contains("LastNight.isCredited("))
        let card = try source("Dashboard/TodayScoresCard.swift")
        XCTAssertTrue(card.contains("LastNight.isCredited(nightKey:"))
        XCTAssertTrue(card.contains("LastNight.score(night.sleepScore)"))
    }

    // MARK: I3 — Strain

    func testStrainStates() {
        let scored = strain(8.4, seconds: 5_400)
        XCTAssertEqual(build(nil, strain: scored).strain, .scored(scored), "the dial shows trends.todayStrain")
        XCTAssertEqual(build(nil, strain: scored, loaded: false).strain, .loading)
        XCTAssertEqual(build(nil, strain: nil).strain, .noHeartRate)
        XCTAssertEqual(build(nil, strain: strain(nil, seconds: 0)).strain, .noHeartRate)
        XCTAssertEqual(build(nil, strain: strain(nil, seconds: 240)).strain, .needsMinutes(soFar: 4))
        XCTAssertEqual(build(nil, strain: strain(nil, seconds: 3_600, rhr: nil)).strain, .needsRestingHR)
    }

    // MARK: What left Today

    func testReadinessIsNoLongerATodaySection() {
        XCTAssertNil(DashboardSection(rawValue: "readiness"))
        XCTAssertEqual(DashboardSection.allCases.first, .metrics)
        XCTAssertEqual(Array(DashboardSectionOrder.decode("readiness,goals,sync").prefix(3)), [.metrics, .goals, .sync],
                       "a saved order naming readiness loads with the tiles first")
    }

    /// A saved order naming a live section twice loads it once: the sections feed a `ForEach` of
    /// `Identifiable` cards, where a duplicate id is undefined behaviour.
    func testALiveDuplicateInASavedOrderIsDropped() {
        let order = DashboardSectionOrder.decode("goals,sync,goals,metrics,sync")
        XCTAssertEqual(Array(order.prefix(3)), [.goals, .sync, .metrics], "the first of each keeps its place")
        XCTAssertEqual(order.count, Set(order).count, "no section twice: \(order)")
        XCTAssertEqual(Set(order), Set(DashboardSection.allCases))
    }

    func testTheStrainTileIsGoneFromYourNumbers() throws {
        let grid = try source("Dashboard/MetricTilesSection.swift")
        XCTAssertFalse(grid.contains("StrainTileView"))
        XCTAssertFalse(grid.contains("todayStrain"))
        XCTAssertFalse(grid.contains("DailyStrain"))
    }

    /// Today's order: the date, the scores card, then the connection card. The old Readiness card is
    /// not built anywhere in the Today tab.
    func testTheScoresCardIsFirstOnToday() throws {
        let content = try source("ContentView.swift")
        let list = try XCTUnwrap(content.range(of: "private var todayList: some View {"))
        let body = String(content[list.upperBound...].prefix(2_000))
        let date = try XCTUnwrap(body.range(of: "TodayDateRow()")).lowerBound
        let scores = try XCTUnwrap(body.range(of: "todayScoresCard")).lowerBound
        let connection = try XCTUnwrap(body.range(of: "connectionCard")).lowerBound
        XCTAssertLessThan(date, scores)
        XCTAssertLessThan(scores, connection)
        XCTAssertFalse(content.contains("WellnessBalanceCardView("))
    }

    // MARK: Helpers

    private func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenCircuit")
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }
}
