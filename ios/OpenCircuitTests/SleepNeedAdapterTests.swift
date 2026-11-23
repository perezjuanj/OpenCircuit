// Sleep need on the Sleep card (#382): the adapter between the stored rows / settings and the pure Kit
// `SleepNeed`, and the card's words. Every value is synthetic; dates are fixed and in the past.

import XCTest
import OpenCircuitKit
@testable import OpenCircuit

final class SleepNeedAdapterTests: XCTestCase {

    private struct StubSchedule: SleepScheduleProviding {
        var window: DateInterval?
        func sleepWindow(forNightEndingNear date: Date) async -> DateInterval? { window }
    }

    private let cal = Calendar.current

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2025; c.month = 1; c.day = 6 + day; c.hour = hour; c.minute = minute
        return cal.date(from: c)!
    }

    private func suite() -> UserDefaults {
        let name = "SleepNeedAdapterTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        d.set(420, forKey: GoalDefaults.workdaySleepMin)
        d.set(420, forKey: GoalDefaults.weekendSleepMin)
        return d
    }

    private func row(_ day: Int, asleep: Int) -> StoredSleepSummary {
        StoredSleepSummary(night: at(day, 0), asleepMin: asleep,
                           inBedStart: at(day - 1, 23), inBedEnd: at(day, 7),
                           sleepOnset: at(day - 1, 23, 20), sleepWake: at(day, 6, 55))
    }

    private var shortWeek: [StoredSleepSummary] { [row(1, asleep: 360), row(2, asleep: 360), row(3, asleep: 360)] }

    // MARK: No schedule, no bedtime

    func testNoBedtimeWhenTheManualScheduleIsOffEvenThoughBedAndWakeDefaultsAreRegistered() async {
        let defaults = suite()
        SleepScheduleDefaults.register(defaults)                       // registers bed 22:30, wake 06:30
        XCTAssertEqual(defaults.integer(forKey: SleepScheduleDefaults.wakeMinutes), 6 * 60 + 30)
        XCTAssertFalse(defaults.bool(forKey: SleepScheduleDefaults.enabled))

        let result = await SleepNeedAdapter.compute(
            nights: shortWeek, naps: [], now: at(3, 12), defaults: defaults,
            healthKit: StubSchedule(window: nil))
        XCTAssertNil(result.nextWake)
        XCTAssertNil(result.bedtime)
        // Need and debt are still worked out.
        XCTAssertEqual(result.debtMin, 61)
        XCTAssertEqual(result.needMin, 481)
        XCTAssertFalse(SleepNeedText.line(result, now: at(3, 12)).contains("in bed by"))
    }

    func testNextWakeIsNilWithNoScheduleAtAll() async {
        let wake = await SleepNeedAdapter.nextWake(now: at(3, 12), healthKit: StubSchedule(window: nil),
                                                   manual: StubSchedule(window: nil))
        XCTAssertNil(wake)
    }

    func testAnEnabledManualScheduleGivesTheNextWakeAndABedtime() async {
        let defaults = suite()
        defaults.set(true, forKey: SleepScheduleDefaults.enabled)
        SleepScheduleDefaults.register(defaults)
        let result = await SleepNeedAdapter.compute(
            nights: shortWeek, naps: [], now: at(3, 12), defaults: defaults,
            healthKit: StubSchedule(window: nil))
        XCTAssertEqual(result.nextWake, at(4, 6, 30))
        // Need 481 + latency from the rows (onset 20 min after bed) = 501 min before 06:30.
        XCTAssertEqual(result.latencyMin, 20)
        XCTAssertEqual(result.bedtime, at(4, 6, 30).addingTimeInterval(-501 * 60))
    }

    func testTheHealthKitScheduleWinsOverTheManualOne() async {
        let healthWindow = DateInterval(start: at(2, 23, 30), end: at(3, 7, 15))
        let wake = await SleepNeedAdapter.nextWake(now: at(3, 12), healthKit: StubSchedule(window: healthWindow),
                                                   manual: ManualSleepSchedule(enabled: true, bedMinutes: 1350, wakeMinutes: 390))
        XCTAssertEqual(wake, at(4, 7, 15))
    }

    // MARK: Row mapping

    func testRowsMapToNightsWithTheRecordedWakeElseTheInBedEnd() {
        var legacy = row(2, asleep: 400)
        legacy.sleepWake = .distantPast
        legacy.sleepOnset = .distantPast
        let nights = SleepNeedAdapter.nights([row(1, asleep: 300), legacy])
        XCTAssertEqual(nights[0].wake, at(1, 6, 55))
        XCTAssertEqual(nights[0].sleepOnset, at(0, 23, 20))
        XCTAssertEqual(nights[1].wake, at(2, 7))
        XCTAssertNil(nights[1].sleepOnset)
        XCTAssertEqual(nights.map(\.asleepMin), [300, 400])
    }

    func testARowWithNoTimesIsDroppedNotInvented() {
        let bare = StoredSleepSummary(night: at(1, 0), asleepMin: 400)
        XCTAssertTrue(SleepNeedAdapter.nights([bare]).isEmpty)
    }

    func testAnEditedNapsWindowIsTheOneThatCounts() {
        let nap = StoredNap(start: at(2, 13), end: at(2, 14), asleepMin: 50)
        nap.editedStart = at(2, 15)
        XCTAssertEqual(SleepNeedAdapter.naps([nap]).first?.start, at(2, 15))
    }

    func testGoalsFallBackToTheAppDefaultsWhenNeverSet() {
        let d = UserDefaults(suiteName: "SleepNeedAdapterTests.empty.\(UUID().uuidString)")!
        let g = SleepNeedAdapter.goals(defaults: d)
        XCTAssertEqual(g.workday, GoalDefaults.defaultWorkdaySleepMin)
        XCTAssertEqual(g.weekend, GoalDefaults.defaultWeekendSleepMin)
    }

    // MARK: The words

    func testTheLineReadsLikeTheIssueExample() {
        var result = SleepNeed.compute(.init(
            nights: SleepNeedAdapter.nights(shortWeek), naps: [], now: at(3, 12), workdayGoalMin: 420,
            weekendGoalMin: 420, nextWake: at(4, 6, 30), calendar: cal))
        let line = SleepNeedText.line(result, now: at(3, 12))
        XCTAssertTrue(line.hasPrefix("Need tonight 8 h 1 m · debt 1 h 1 m · in bed by "), line)

        // Fewer than three known nights: say so rather than show 0.
        result = SleepNeed.compute(.init(
            nights: SleepNeedAdapter.nights([row(1, asleep: 300)]), naps: [], now: at(3, 12),
            workdayGoalMin: 420, weekendGoalMin: 420, nextWake: nil, calendar: cal))
        XCTAssertEqual(SleepNeedText.line(result, now: at(3, 12)), "Need tonight 7 h · debt: not enough nights yet")
    }

    func testABedtimeAlreadyPassedIsNotShown() {
        let result = SleepNeed.compute(.init(
            nights: SleepNeedAdapter.nights(shortWeek), naps: [], now: at(3, 12), workdayGoalMin: 420,
            weekendGoalMin: 420, nextWake: at(4, 6, 30), calendar: cal))
        XCTAssertNotNil(SleepNeedText.upcomingBedtime(result, now: at(3, 12)))
        XCTAssertNil(SleepNeedText.upcomingBedtime(result, now: at(4, 1)))
        XCTAssertFalse(SleepNeedText.line(result, now: at(4, 1)).contains("in bed by"))
    }

    func testDurationText() {
        XCTAssertEqual(SleepNeedText.duration(0), "0 m")
        XCTAssertEqual(SleepNeedText.duration(45), "45 m")
        XCTAssertEqual(SleepNeedText.duration(60), "1 h")
        XCTAssertEqual(SleepNeedText.duration(490), "8 h 10 m")
    }

    // MARK: Sources

    func testSleepNeedCitesBothResearchPapersAndTheGoalSources() {
        let urls = HealthSources.source(.sleepNeed).citations.map(\.url.absoluteString)
        XCTAssertTrue(urls.contains("https://doi.org/10.1093/sleep/26.2.117"))
        XCTAssertTrue(urls.contains("https://doi.org/10.1038/srep35812"))
        XCTAssertTrue(urls.contains("https://doi.org/10.1016/j.sleh.2014.12.010"))
        XCTAssertTrue(urls.contains("https://doi.org/10.5665/sleep.4716"))
        // The constants are OpenCircuit's own and the screen says so.
        XCTAssertTrue(HealthSources.source(.sleepNeed).method.contains("OpenCircuit's own"))
    }
}
