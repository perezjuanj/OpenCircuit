// Which of the strap's workout records are offered for review (decision 91c), where each walk starts
// (91a), the one notification (91e) and what a saved record becomes (91d). Pure rules, synthetic times.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

final class StrapWorkoutKeepTests: XCTestCase {

    private let now = date(1_790_100_000)
    /// A 25-minute record that ended an hour before `now`.
    private var window: DateInterval { DateInterval(start: now.addingTimeInterval(-3600 - 1500), duration: 1500) }

    private func verdict(_ window: DateInterval, owned: Bool = true, history: [DateInterval] = [],
                         deleted: [DateInterval] = [], discarded: [DateInterval] = [], now: Date? = nil) -> HelioStrapWorkoutKeep.Verdict {
        HelioStrapWorkoutKeep.verdict(window: window, owned: owned, history: history, deleted: deleted,
                                      discarded: discarded, now: now ?? self.now)
    }

    func testAnOwnedSettledRecordOfTenMinutesOrMoreIsKept() {
        XCTAssertEqual(verdict(window), .keep)
    }

    func testTheTenMinuteRuleOnBothSidesOfTheBoundary() {
        let start = now.addingTimeInterval(-3600)
        XCTAssertEqual(verdict(DateInterval(start: start, duration: 600)), .keep, "exactly 10 min is kept")
        XCTAssertEqual(verdict(DateInterval(start: start, duration: 599)), .drop(.tooShort), "a second less is not")
    }

    func testARecordIsJudgedOnlyFiveMinutesAfterItEnds() {
        let start = now.addingTimeInterval(-2000)
        XCTAssertEqual(verdict(DateInterval(start: start, end: now.addingTimeInterval(-300))), .keep, "ended exactly 5 min ago")
        XCTAssertEqual(verdict(DateInterval(start: start, end: now.addingTimeInterval(-299))), .notYet)
        XCTAssertEqual(verdict(DateInterval(start: start, end: now.addingTimeInterval(600))), .notYet, "ends in the future")
        XCTAssertFalse(HelioStrapWorkoutKeep.Verdict.notYet.isFinal)
        XCTAssertTrue(HelioStrapWorkoutKeep.Verdict.drop(.tooShort).isFinal)
    }

    func testARecordOlderThanTwoDaysIsDropped() {
        let twoDays: TimeInterval = 2 * 86_400
        XCTAssertEqual(verdict(DateInterval(start: now.addingTimeInterval(-twoDays - 1500), end: now.addingTimeInterval(-twoDays))), .keep,
                       "ended exactly two days ago")
        XCTAssertEqual(verdict(DateInterval(start: now.addingTimeInterval(-twoDays - 1501), end: now.addingTimeInterval(-twoDays - 1))),
                       .drop(.tooOld))
    }

    func testARecordTheStrapDoesNotWhollyOwnIsDropped() {
        XCTAssertEqual(verdict(window, owned: false), .drop(.notOwned))
    }

    func testAnOverlapWithHistoryDeletedOrDiscardedDrops() {
        let inside = DateInterval(start: window.start.addingTimeInterval(600), duration: 60)
        let touching = DateInterval(start: window.end, duration: 600)
        let apart = DateInterval(start: window.end.addingTimeInterval(1), duration: 600)
        XCTAssertEqual(verdict(window, history: [inside]), .drop(.inHistory))
        XCTAssertEqual(verdict(window, history: [touching]), .drop(.inHistory), "touching ends count, as the tombstones' do")
        XCTAssertEqual(verdict(window, history: [apart]), .keep)
        XCTAssertEqual(verdict(window, deleted: [inside]), .drop(.deleted))
        XCTAssertEqual(verdict(window, deleted: [apart]), .keep)
        XCTAssertEqual(verdict(window, discarded: [window]), .drop(.discarded))
        XCTAssertEqual(verdict(window, discarded: [apart]), .keep)
    }

    // MARK: Ownership (decision 28) through the real log

    func testOwnershipOfOnlyPartOfTheWindowDrops() {
        let family = DeviceOwnershipLog.Family.zeppOS
        let switchInside = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: window.start.addingTimeInterval(-86_400)),
                                                        .init(family: .ringConn, since: window.start.addingTimeInterval(600))])
        let strapLater = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: window.start.addingTimeInterval(60))])
        let strapBefore = DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: window.start)])
        XCTAssertEqual(verdict(window, owned: switchInside.ownsWholly(family, from: window.start, to: window.end)), .drop(.notOwned))
        XCTAssertEqual(verdict(window, owned: strapLater.ownsWholly(family, from: window.start, to: window.end)), .drop(.notOwned))
        XCTAssertEqual(verdict(window, owned: strapBefore.ownsWholly(family, from: window.start, to: window.end)), .keep)
    }

    // MARK: Where the walk starts and how its cursor moves

    func testTheFirstWalkStartsTwoDaysBackAndLaterOnesAtTheCursor() {
        XCTAssertEqual(HelioWorkoutWalkPlan.since(cursor: nil, now: now, notBefore: nil), now.addingTimeInterval(-2 * 86_400))
        let cursor = now.addingTimeInterval(-3600)
        XCTAssertEqual(HelioWorkoutWalkPlan.since(cursor: cursor, now: now, notBefore: nil), cursor)
        XCTAssertEqual(HelioWorkoutWalkPlan.since(cursor: now.addingTimeInterval(-9 * 86_400), now: now, notBefore: nil),
                       now.addingTimeInterval(-2 * 86_400), "never more than two days back")
        XCTAssertEqual(HelioWorkoutWalkPlan.since(cursor: nil, now: now, notBefore: now.addingTimeInterval(-600)),
                       now.addingTimeInterval(-600), "never before the strap's ownership start")
        XCTAssertEqual(HelioWorkoutWalkPlan.since(cursor: date(1_790_000_000.75), now: now, notBefore: nil), date(1_790_000_000),
                       "whole seconds")
    }

    func testTheCursorStopsBeforeAFailedOrUnsettledRecord() {
        var cursor = HelioWorkoutWalkCursor(previous: date(100))
        cursor.judged(start: date(200), final: true)
        cursor.judged(start: date(300), final: true)
        XCTAssertEqual(cursor.cursor, date(300))
        cursor.failed()
        cursor.judged(start: date(400), final: true)
        XCTAssertEqual(cursor.cursor, date(300), "a record after a failed round doesn't move it")

        var unsettled = HelioWorkoutWalkCursor(previous: nil)
        unsettled.judged(start: date(200), final: false)
        unsettled.judged(start: date(300), final: true)
        XCTAssertNil(unsettled.cursor)

        var never = HelioWorkoutWalkCursor(previous: date(500))
        never.judged(start: date(400), final: true)
        XCTAssertEqual(never.cursor, date(500), "never backwards")
    }

    // MARK: The notification

    func testANewRecordIsAnnouncedOnceAndNeverAfterADay() {
        let start = now.addingTimeInterval(-7200)
        let end = now.addingTimeInterval(-3600)
        XCTAssertTrue(HelioStrapWorkoutAnnouncement.shouldAnnounce(start: start, end: end, announced: [], now: now))
        XCTAssertFalse(HelioStrapWorkoutAnnouncement.shouldAnnounce(start: start, end: end, announced: [start], now: now))
        let dayOld = now.addingTimeInterval(-86_400)
        XCTAssertTrue(HelioStrapWorkoutAnnouncement.shouldAnnounce(start: dayOld.addingTimeInterval(-900), end: dayOld, announced: [], now: now))
        XCTAssertFalse(HelioStrapWorkoutAnnouncement.shouldAnnounce(start: dayOld.addingTimeInterval(-901), end: dayOld.addingTimeInterval(-1),
                                                                    announced: [], now: now))
    }

    // MARK: What a saved record becomes

    func testASavedRecordKeepsItsWindowKcalHeartRateAndSport() throws {
        let start = date(1_790_000_000)
        var readings = (0..<1500).map { ZeppWorkoutHeartRate(time: start.addingTimeInterval(TimeInterval($0)), bpm: 100 + $0 % 40) }
        readings.append(readings[10])   // a duplicate instant
        let record = ZeppWorkoutRecord(summary: try ZeppWorkoutSummary.parse(WorkoutRecordParserTests.exampleN), heartRate: readings)
        let zones = HeartRateZones(percentOfMax: 190)
        let summary = HelioStrapWorkoutImport.summary(record, sport: .pickleball, zones: zones)
        XCTAssertEqual(summary.summary.sport, .pickleball)
        XCTAssertEqual(summary.summary.startDate, start)
        XCTAssertEqual(summary.summary.endDate, start.addingTimeInterval(1500))
        XCTAssertEqual(summary.activeSeconds, 1500)
        XCTAssertEqual(summary.summary.estimatedActiveKcal, 150, "the strap's 16.1")
        XCTAssertEqual(summary.summary.avgHR, 110, "the strap's 19.1")
        XCTAssertEqual(summary.summary.maxHR, 130)
        XCTAssertEqual(summary.summary.hrSampleCount, 1500)
        XCTAssertNil(summary.summary.distanceMeters)
        XCTAssertFalse(summary.summary.hasRoute)
        XCTAssertTrue(summary.pauses.isEmpty)
        XCTAssertGreaterThan(summary.summary.zoneBreakdown.totalZoneSeconds, 0)

        let samples = HelioStrapWorkoutImport.samples(record)
        XCTAssertEqual(samples.count, 1500)
        XCTAssertEqual(samples.first, HRSample(bpm: 100, start: start, end: start.addingTimeInterval(1)))
        XCTAssertTrue(samples.allSatisfy { $0.end <= start.addingTimeInterval(1500) })
    }

    func testWithoutTheSummarysHeartRateTheReadingsGiveIt() throws {
        let start = date(1_790_000_000)
        let parsed = try ZeppWorkoutSummary.parse(WorkoutFixture.summary(start: 1_790_000_000, duration: 900, kcal: nil, hr: nil))
        let record = ZeppWorkoutRecord(summary: parsed, heartRate: [ZeppWorkoutHeartRate(time: start, bpm: 100),
                                                                    ZeppWorkoutHeartRate(time: start.addingTimeInterval(1), bpm: 110)])
        let summary = HelioStrapWorkoutImport.summary(record, sport: .other, zones: HeartRateZones(percentOfMax: 190))
        XCTAssertEqual(summary.summary.avgHR, 105)
        XCTAssertEqual(summary.summary.maxHR, 110)
        XCTAssertNil(summary.summary.estimatedActiveKcal, "no kcal is invented")
    }
}
