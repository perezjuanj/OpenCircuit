// Sleep need on the Sleep card (#382): the adapter between the stored rows / settings and the pure Kit
// `SleepNeed`, and the card's words. Every value is synthetic; dates are fixed and in the past.

import XCTest
import OpenCircuitKit
@testable import OpenCircuit

final class SleepNeedAdapterTests: XCTestCase {

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

    func testNoBedtimeWhenTheManualScheduleIsOffEvenThoughBedAndWakeDefaultsAreRegistered() {
        let defaults = suite()
        SleepScheduleDefaults.register(defaults)                       // registers bed 22:30, wake 06:30
        XCTAssertEqual(defaults.integer(forKey: SleepScheduleDefaults.wakeMinutes), 6 * 60 + 30)
        XCTAssertFalse(defaults.bool(forKey: SleepScheduleDefaults.enabled))

        let result = SleepNeedAdapter.compute(nights: shortWeek, naps: [], now: at(3, 12), defaults: defaults)
        XCTAssertNil(result.nextWake)
        XCTAssertNil(result.bedtime)
        // Need and debt are still worked out.
        XCTAssertEqual(result.debtMin, 61)
        XCTAssertEqual(result.needMin, 481)
        XCTAssertFalse(SleepNeedText.line(result, now: at(3, 12)).contains("in bed by"))
    }

    func testNextWakeIsNilWithTheScheduleOffWhateverBedAndWakeAreSet() {
        let off = ManualSleepSchedule(enabled: false, bedMinutes: 1350, wakeMinutes: 390)
        XCTAssertNil(SleepNeedAdapter.nextWake(now: at(3, 12), schedule: off))
        let on = ManualSleepSchedule(enabled: true, bedMinutes: 1350, wakeMinutes: 390)
        XCTAssertEqual(SleepNeedAdapter.nextWake(now: at(3, 12), schedule: on), at(4, 6, 30))
        // Asked after this morning's wake time passes, and just before it: the next occurrence either way.
        XCTAssertEqual(SleepNeedAdapter.nextWake(now: at(3, 6, 29), schedule: on), at(3, 6, 30))
        XCTAssertEqual(SleepNeedAdapter.nextWake(now: at(3, 6, 30), schedule: on), at(4, 6, 30))
    }

    func testAnEnabledManualScheduleGivesTheNextWakeAndABedtime() {
        let defaults = suite()
        defaults.set(true, forKey: SleepScheduleDefaults.enabled)
        SleepScheduleDefaults.register(defaults)
        let result = SleepNeedAdapter.compute(nights: shortWeek, naps: [], now: at(3, 12), defaults: defaults)
        XCTAssertEqual(result.nextWake, at(4, 6, 30))
        // Need 481 + latency from the rows (onset 20 min after bed) = 501 min before 06:30.
        XCTAssertEqual(result.latencyMin, 20)
        XCTAssertEqual(result.bedtime, at(4, 6, 30).addingTimeInterval(-501 * 60))
    }

    func testAnEnabledScheduleWithRecordedSleepAroundUsesTheManualWakeOnly() {
        // The recorded rows (a mirrored nap window included) never decide the wake: only the manual schedule.
        let defaults = suite()
        defaults.set(true, forKey: SleepScheduleDefaults.enabled)
        defaults.set(23 * 60, forKey: SleepScheduleDefaults.bedMinutes)
        defaults.set(7 * 60 + 15, forKey: SleepScheduleDefaults.wakeMinutes)
        let nap = StoredNap(start: at(3, 14), end: at(3, 14, 45), asleepMin: 40)
        let result = SleepNeedAdapter.compute(nights: shortWeek, naps: [nap], now: at(3, 21), defaults: defaults)
        XCTAssertEqual(result.nextWake, at(4, 7, 15))
    }

    /// The adapter must not reach the recorded-sleep reader: `SleepSchedule.current` prefers a HealthKit
    /// branch that reads sleep samples from ANY source (this app's own mirrored nights and naps too), which
    /// is not a schedule (decision 92k). The adapter has no seam for it, and its code never names it.
    func testTheAdapterNeverNamesTheRecordedSleepReaders() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OpenCircuit/SleepNeedAdapter.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for forbidden in ["SleepSchedule.current", "HealthKitSleepSchedule", "SleepScheduleProviding",
                          "scheduledWakeMinutes", "import HealthKit"] {
            XCTAssertFalse(code.contains(forbidden), "SleepNeedAdapter must not use \(forbidden)")
        }
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

// Round 2 (decision 92k): the review probes' parameters (fixed dates in March 2024, local time zone),
// inverted to assert the fixed behaviour.
final class SleepNeedAdapterRound2Tests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2024; c.month = 3; c.day = 4 + d; c.hour = h; c.minute = m
        return cal.date(from: c)!
    }
    private func row(_ d: Int, _ a: Int) -> StoredSleepSummary {
        StoredSleepSummary(night: at(d, 0), asleepMin: a, inBedStart: at(d - 1, 23, 10), inBedEnd: at(d, 7, 5),
                           sleepOnset: at(d - 1, 23, 30), sleepWake: at(d, 7))
    }
    private func suite(_ tag: String) -> (UserDefaults, String) {
        let name = "SleepNeedRound2.\(tag).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return (d, name)
    }
    private var rows: [StoredSleepSummary] { [row(1, 400), row(2, 380), row(3, 390)] }

    /// The probe: a 14:00-14:45 nap (what Health holds as the only recent in-bed sample at 21:00) must not
    /// become the wake time. With no manual schedule there is no bedtime at all.
    func testANapWindowNeverBecomesTheWakeTime() {
        let (d, _) = suite("nap")
        let nap = StoredNap(start: at(3, 14), end: at(3, 14, 45), asleepMin: 40)
        let now = at(3, 21)
        let r = SleepNeedAdapter.compute(nights: rows, naps: [nap], now: now, calendar: cal, defaults: d)
        XCTAssertNil(r.nextWake)
        XCTAssertNil(r.bedtime)
        XCTAssertFalse(SleepNeedText.line(r, now: now).contains("in bed by"))
    }

    func testDisabledButSetScheduleGivesNoBedtime() {
        let (d, _) = suite("set")
        d.set(false, forKey: SleepScheduleDefaults.enabled)
        d.set(23 * 60, forKey: SleepScheduleDefaults.bedMinutes)
        d.set(7 * 60, forKey: SleepScheduleDefaults.wakeMinutes)
        let r = SleepNeedAdapter.compute(nights: rows, naps: [], now: at(3, 15), calendar: cal, defaults: d)
        XCTAssertNil(r.nextWake)
        XCTAssertNil(r.bedtime)
        XCTAssertFalse(SleepNeedText.line(r, now: at(3, 15)).contains("in bed by"))
    }

    func testComputeWritesNoUserDefaultsKey() {
        let (d, name) = suite("empty")
        _ = SleepNeedAdapter.compute(nights: rows, naps: [], now: at(3, 15), calendar: cal, defaults: d)
        let keys = UserDefaults.standard.persistentDomain(forName: name)?.keys.sorted() ?? []
        XCTAssertEqual(keys, [], "keys written: \(keys)")
    }

    func testZeroDebtReadsNoneInBothPlaces() {
        // One wording for zero debt, shared by the line and the sheet.
        let flat = SleepNeed.compute(.init(
            nights: SleepNeedAdapter.nights([row(1, 420), row(2, 420), row(3, 420)]), naps: [], now: at(3, 15),
            workdayGoalMin: 420, weekendGoalMin: 420, nextWake: nil, calendar: cal))
        XCTAssertEqual(SleepNeedText.debtValue(flat), "none")
        XCTAssertEqual(SleepNeedText.line(flat, now: at(3, 15)), "Need tonight 7 h · debt none")
    }
}
