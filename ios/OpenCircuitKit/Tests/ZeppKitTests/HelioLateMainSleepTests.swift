// Decision 97 (#408): a strap sleep that starts in the night but ends late (a shifted schedule, or a
// night stitched to a lie-in that ends after noon) is a LATE MAIN SLEEP (97a), which the store offers
// as its day's night. Every sleep here is synthetic: spans on the minute, built in place.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// The zone the sleeps below are recorded in: a fixed +09:00 offset, the form the strap's own
/// local-midnight reference gives (`recordedTimeZone(midnight:)`).
private let recorded = TimeZone(secondsFromGMT: 9 * 3600)!
/// The phone's zone in the tests that put the phone elsewhere (28e): sixteen hours behind `recorded`
/// on the key day.
private let phoneElsewhere = TimeZone(identifier: "America/Los_Angeles")!

/// Wall-clock `hour:minute` in `zone` on the key day (2026-10-15) plus `day` days.
private func wall(_ hour: Int, _ minute: Int = 0, day: Int = 0, in zone: TimeZone = recorded,
                  year: Int = 2026, month: Int = 10, keyDay: Int = 15) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: keyDay + day, hour: hour, minute: minute))!
}

/// A sleep as `night(from:now:)` builds one: one `.inBed` over the window, asleep all of it.
private func sleep(_ start: Date, _ end: Date, zone: TimeZone = recorded) -> HelioSleepSelection.Night {
    HelioSleepSelection.Night(segments: [SleepSegment(start: start, end: end, stage: .inBed),
                                         SleepSegment(start: start, end: end, stage: .asleepCore)],
                              window: DateInterval(start: start, end: end), strapScore: 80, recordedTimeZone: zone)
}

/// An activity sleep block in place, as `activityBlocks` builds it (no score).
private func block(_ start: Date, _ end: Date) -> HelioSleepSelection.Night {
    HelioSleepSelection.Night(segments: [SleepSegment(start: start, end: end, stage: .inBed),
                                         SleepSegment(start: start, end: end, stage: HelioSleepSelection.activityBlockStage)],
                              window: DateInterval(start: start, end: end), strapScore: nil, recordedTimeZone: recorded)
}

final class HelioLateMainSleepTests: XCTestCase {
    private typealias Selection = HelioSleepSelection

    /// Runs `body` with the phone's zone set to `zone`, then puts it back.
    private func withPhoneZone(_ zone: TimeZone, _ body: () throws -> Void) rethrows {
        let saved = NSTimeZone.default
        NSTimeZone.default = zone
        defer { NSTimeZone.default = saved }
        XCTAssertEqual(Calendar.current.timeZone.secondsFromGMT(for: wall(12)), zone.secondsFromGMT(for: wall(12)),
                       "the phone's zone switched")
        try body()
    }

    /// The edge grid of 97a, as (label, start, end, expected). Every sleep that must be one is also no
    /// overnight sleep, so each pair differs only in the bound it tests.
    private var edgeGrid: [(String, Date, Date, Bool)] {
        [
            ("the reported shape, 05:00–15:00", wall(5), wall(15), true),
            ("start 20:59 the evening before", wall(20, 59, day: -1), wall(13), false),
            ("start 21:00 the evening before", wall(21, day: -1), wall(13), true),
            ("start 07:59", wall(7, 59), wall(15), true),
            ("start 08:00", wall(8), wall(15), false),
            ("2 h 59 min long", wall(7, 31), wall(10, 30), false),
            ("3 h long", wall(7, 30), wall(10, 30), true),
            ("maxNightLength long", wall(21, day: -1), wall(17), true),
            ("a minute over maxNightLength", wall(21, day: -1), wall(17, 1), false),
            ("end 17:59", wall(7), wall(17, 59), true),
            ("end 18:00", wall(7), wall(18), false),
            ("overnight 05:00–08:30", wall(5), wall(8, 30), false),
            ("overnight 23:00–07:00", wall(23, day: -1), wall(7), false),
            ("an evening doze 20:00–22:30", wall(20, day: -1), wall(22, 30, day: -1), false),
            ("an afternoon sleep 13:00–16:30", wall(13), wall(16, 30), false),
        ]
    }

    private func assertEdgeGrid(_ context: String) {
        for (label, start, end, expected) in edgeGrid {
            let night = sleep(start, end)
            XCTAssertEqual(Selection.isLateMainSleep(night), expected, "\(context): \(label)")
            if expected {
                XCTAssertFalse(Selection.isOvernightSleep(night), "\(context): \(label) is no overnight sleep")
                XCTAssertEqual(Selection.nightKey(of: night), wall(0), "\(context): \(label) files under the day it ends on")
            }
        }
    }

    // MARK: 97a: the predicate

    /// Every bound of 97a, judged in the recorded zone with the phone in that same zone.
    func testTheFourConditionsAtEachOfTheirEdges() {
        withPhoneZone(recorded) { assertEdgeGrid("phone in the recorded zone") }
    }

    /// 28e: the same grid with the phone sixteen hours away. The verdicts are the recorded zone's: the
    /// reported 05:00–15:00 is 13:00–23:00 the day before on the phone's clock, which would be no late
    /// main sleep there.
    func testTheFourConditionsAreJudgedInTheRecordedZoneNotThePhones() {
        withPhoneZone(phoneElsewhere) {
            assertEdgeGrid("phone elsewhere")
            let reported = sleep(wall(5), wall(15))
            let onThePhone = sleep(reported.window.start, reported.window.end, zone: phoneElsewhere)
            XCTAssertTrue(Selection.isLateMainSleep(reported))
            XCTAssertFalse(Selection.isLateMainSleep(onThePhone), "judged on the phone's clock it would not be one")
        }
    }

    /// 97a(1): an overnight sleep is never a late main sleep, whatever else holds.
    func testAnOvernightSleepIsNeverALateMainSleep() {
        for (start, end) in [(wall(5), wall(8, 30)), (wall(23, day: -1), wall(7)), (wall(0), wall(11, 59)), (wall(6), wall(11))] {
            let night = sleep(start, end)
            XCTAssertTrue(Selection.isOvernightSleep(night))
            XCTAssertFalse(Selection.isLateMainSleep(night))
        }
    }

    /// The constants are the decision's: 3 h, 21:00 the evening before, 08:00 and 18:00.
    func testTheBoundsAreTheDecisionsChoices() {
        XCTAssertEqual(Selection.lateMainSleepMinLength, 3 * 3600)
        XCTAssertEqual(Selection.lateMainSleepEarliestStartHour, 21)
        XCTAssertEqual(Selection.lateMainSleepStartBeforeHour, 8)
        XCTAssertEqual(Selection.lateMainSleepEndBeforeHour, 18)
    }

    // MARK: 97a on a daylight-saving day

    /// The hour bounds are WALL-CLOCK hours of the recorded calendar (the choice the brief asks to name),
    /// not the key plus a fixed number of elapsed hours. Spring forward (America/New_York, 2026-03-08,
    /// 02:00 → 03:00): 08:00 is the key + 7 elapsed hours and 18:00 the key + 17, so a start at 08:00 or
    /// an end at 18:00 is out even though fewer than 8 (18) hours have passed since midnight.
    func testOnASpringForwardDayTheBoundsAreTheClockReadings() {
        let ny = TimeZone(identifier: "America/New_York")!
        func at(_ h: Int, _ m: Int = 0, day: Int = 0) -> Date { wall(h, m, day: day, in: ny, month: 3, keyDay: 8) }
        let key = at(0)
        XCTAssertEqual(at(8).timeIntervalSince(key), 7 * 3600, "the clock skipped an hour")
        XCTAssertEqual(at(18).timeIntervalSince(key), 17 * 3600)
        XCTAssertTrue(Selection.isLateMainSleep(sleep(at(7, 30), at(15), zone: ny)))
        XCTAssertFalse(Selection.isLateMainSleep(sleep(at(8), at(15), zone: ny)), "starts at 08:00 on the clock")
        XCTAssertTrue(Selection.isLateMainSleep(sleep(at(5), at(17, 59), zone: ny)))
        XCTAssertFalse(Selection.isLateMainSleep(sleep(at(5), at(18), zone: ny)), "ends at 18:00 on the clock")
        XCTAssertTrue(Selection.isLateMainSleep(sleep(at(21, day: -1), at(13), zone: ny)))
        XCTAssertFalse(Selection.isLateMainSleep(sleep(at(20, 59, day: -1), at(13), zone: ny)))
        XCTAssertEqual(Selection.nightKey(of: sleep(at(5), at(15), zone: ny)), key)
    }

    /// Fall back (America/New_York, 2026-11-01, 02:00 → 01:00): 08:00 is the key + 9 elapsed hours and
    /// 18:00 the key + 19, so a start at 07:30 and an end at 17:30 are in even though more than 8 (18)
    /// hours have passed since midnight.
    func testOnAFallBackDayTheBoundsAreTheClockReadings() {
        let ny = TimeZone(identifier: "America/New_York")!
        func at(_ h: Int, _ m: Int = 0, day: Int = 0) -> Date { wall(h, m, day: day, in: ny, month: 11, keyDay: 1) }
        let key = at(0)
        XCTAssertEqual(at(8).timeIntervalSince(key), 9 * 3600, "the clock repeated an hour")
        XCTAssertEqual(at(18).timeIntervalSince(key), 19 * 3600)
        XCTAssertTrue(Selection.isLateMainSleep(sleep(at(7, 30), at(15), zone: ny)), "starts before 08:00 on the clock")
        XCTAssertFalse(Selection.isLateMainSleep(sleep(at(8), at(15), zone: ny)))
        XCTAssertTrue(Selection.isLateMainSleep(sleep(at(5), at(17, 30), zone: ny)), "ends before 18:00 on the clock")
        XCTAssertFalse(Selection.isLateMainSleep(sleep(at(5), at(18), zone: ny)))
        XCTAssertEqual(Selection.nightKey(of: sleep(at(5), at(15), zone: ny)), key)
    }

    // MARK: 97b: the joins stay overnight-only

    /// A late main sleep never joins an overnight sleep of its key across a gap over `stitchGap` (71b
    /// joins overnight sleeps only), so the two stay two sleeps for the store to judge (97c).
    func testALateMainSleepNeverJoinsAnOvernightSleepOfItsKeyAcrossAGap() {
        let early = sleep(wall(0), wall(2)), late = sleep(wall(7), wall(11, 30))
        XCTAssertTrue(Selection.isOvernightSleep(early))
        XCTAssertTrue(Selection.isLateMainSleep(late))
        XCTAssertEqual(Selection.nightKey(of: early), Selection.nightKey(of: late))
        XCTAssertFalse(Selection.areOneNight(early, late))
        XCTAssertFalse(Selection.areOneNight(late, early))
        XCTAssertEqual(Selection.stitch([early, late]).map(\.window), [early.window, late.window])
    }

    /// The lie-in: a night 23:00–06:00 and a sleep 06:30–13:00 stitch by 28f's 60 minutes, as before; the
    /// joined night ends after noon, so it is no overnight sleep, and is a late main sleep.
    func testANightStitchedToALieInThatEndsAfterNoonIsALateMainSleep() {
        let joined = Selection.stitch([sleep(wall(23, day: -1), wall(6)), sleep(wall(6, 30), wall(13))])
        XCTAssertEqual(joined.map(\.window), [DateInterval(start: wall(23, day: -1), end: wall(13))])
        XCTAssertEqual(joined.first.map(Selection.overnightVerdict), .endsOutsideWakeWindow)
        XCTAssertEqual(joined.first.map(Selection.isLateMainSleep), true)
    }

    // MARK: 97f: activity blocks never cost a records-only late main sleep

    /// Records 05:00–15:00 and sleep minutes 15:30–18:30: joined by 28f, the night would end at 18:30 and
    /// be neither shape, so nothing would be stored. The records' own late main sleep is kept and the
    /// block is counted alone (and handed back for the nap judgement).
    func testABlockThatWouldPushALateMainSleepPastItsEndBoundFallsBackToTheRecords() {
        let records = sleep(wall(5), wall(15)), after = block(wall(15, 30), wall(18, 30))
        let joinedByStitch = Selection.stitch([records, after])
        XCTAssertEqual(joinedByStitch.count, 1)
        XCTAssertFalse(joinedByStitch.contains(where: Selection.isLateMainSleep), "joined, it is neither shape")
        let join = Selection.nights(sessions: [records], activityBlocks: [after])
        XCTAssertEqual(join.nights, [records])
        XCTAssertEqual(join.joinedBlocks, 0)
        XCTAssertEqual(join.aloneBlocks, 1)
        XCTAssertEqual(join.aloneNights, [after])
    }

    /// 97f's first guard is unchanged: a block never EXTENDS a records-only late main sleep either, even
    /// when the joined night (05:00–16:30) would still be one.
    func testABlockNeverExtendsARecordsOnlyLateMainSleep() {
        let records = sleep(wall(5), wall(15)), after = block(wall(15, 30), wall(16, 30))
        XCTAssertEqual(Selection.stitch([records, after]).map(Selection.isLateMainSleep), [true])
        let join = Selection.nights(sessions: [records], activityBlocks: [after])
        XCTAssertEqual(join.nights, [records])
        XCTAssertEqual(join.aloneBlocks, 1)
    }

    /// 73g's lie-in fallback is unchanged: records 23:00–07:00 and sleep minutes 07:30–13:00 would join
    /// into a late main sleep (23:00–13:00), but the records' own overnight night is kept, as before.
    func testTheLieInFallbackOf73gStillKeepsTheRecordsOvernightNight() {
        let records = sleep(wall(23, day: -1), wall(7)), lieIn = block(wall(7, 30), wall(13))
        XCTAssertEqual(Selection.stitch([records, lieIn]).map(Selection.isLateMainSleep), [true])
        let join = Selection.nights(sessions: [records], activityBlocks: [lieIn])
        XCTAssertEqual(join.nights, [records])
        XCTAssertEqual(join.joinedBlocks, 0)
        XCTAssertEqual(join.aloneBlocks, 1)
    }

    /// A block that still joins a night: records 23:00–07:00 and minutes 07:30–09:00 stay one overnight
    /// night, exactly as before decision 97.
    func testABlockStillJoinsAnOvernightNightItKeepsOvernight() {
        let records = sleep(wall(23, day: -1), wall(7)), after = block(wall(7, 30), wall(9))
        let join = Selection.nights(sessions: [records], activityBlocks: [after])
        XCTAssertEqual(join.nights.map(\.window), [DateInterval(start: wall(23, day: -1), end: wall(9))])
        XCTAssertEqual(join.joinedBlocks, 1)
    }
}
