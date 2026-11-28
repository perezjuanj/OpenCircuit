import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for #399: a Today tile's comparison line is about the same day as the value
/// above it, or it names its day and carries that day's own figure. Steps headline today's running
/// total but judge yesterday, so their line must say "Yesterday <total> · <delta> vs usual"; every
/// other tile's value IS the judged day, so its line stays a bare "<delta> vs usual".
final class TodayTileDayTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-09-30 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_790_726_400)
    private func at(hour: Double) -> Date { midnight.addingTimeInterval(hour * 3_600) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: midnight)! }

    /// Ten complete days of 8,000 before yesterday, yesterday 7,375, and today's total if any.
    private func steps(today: Int?) -> [TrendsEngine.DailyPoint] {
        var pts = (-11 ... -2).map { TrendsEngine.DailyPoint(date: day($0), steps: 8_000) }
        pts.append(TrendsEngine.DailyPoint(date: day(-1), steps: 7_375))
        if let today { pts.append(TrendsEngine.DailyPoint(date: day(0), steps: today)) }
        return pts
    }

    private func tile(_ m: TodayTile.Metric, _ points: [TrendsEngine.DailyPoint],
                      restingHR: [RestingHR.DailyValue] = [], now: Date) -> TodayTile {
        TodayTiles.build(m, points: points, restingHR: restingHR, tempUnit: .celsius,
                         windowDays: 14, now: now, calendar: cal)
    }

    private var yesterdayLine: String {
        "Yesterday " + 7_375.formatted(.number) + " · −625 vs usual"
    }

    // MARK: The pure rule

    func testRuleBareWhenTheJudgedDayIsTheValuesDay() {
        XCTAssertEqual(TodayTile.comparisonLine(valueDay: day(0), judgedDay: day(0), judgedDayIsYesterday: false,
                                                judgedValue: "58 ms", delta: "+8 ms"), "+8 ms vs usual")
    }

    func testRuleNamesYesterdayAndItsFigureUnderTodaysValue() {
        XCTAssertEqual(TodayTile.comparisonLine(valueDay: day(0), judgedDay: day(-1), judgedDayIsYesterday: true,
                                                judgedValue: "7,375", delta: "−625"),
                       "Yesterday 7,375 · −625 vs usual")
    }

    func testRuleSaysNothingAboutAnUnnamedOlderDay() {
        XCTAssertNil(TodayTile.comparisonLine(valueDay: day(0), judgedDay: day(-2), judgedDayIsYesterday: false,
                                              judgedValue: "7,375", delta: "−625"))
    }

    // MARK: Steps

    func testEarlyInTheDayTheLineIsYesterdaysWithYesterdaysTotal() {
        let t = tile(.steps, steps(today: 300), now: at(hour: 7))
        XCTAssertEqual(t.valueText, "300")
        XCTAssertEqual(t.freshnessText(now: at(hour: 7), calendar: cal), "today")
        XCTAssertEqual(t.trend?.latest.date, day(-1))
        XCTAssertEqual(t.deltaText, yesterdayLine)
        XCTAssertTrue(t.accessibilityLabel.contains("Yesterday was " + 7_375.formatted(.number) + " steps, within"),
                      t.accessibilityLabel)
        XCTAssertFalse(t.accessibilityLabel.contains("That's"), t.accessibilityLabel)
    }

    func testANormalDayKeepsTheSameRule() {
        let t = tile(.steps, steps(today: 9_400), now: at(hour: 20))
        XCTAssertEqual(t.valueText, 9_400.formatted(.number))
        XCTAssertEqual(t.deltaText, yesterdayLine)
    }

    /// VoiceOver speaks YESTERDAY's total with yesterday's verdict, never today's running total:
    /// an evening where yesterday was above usual and today's total is a different number.
    func testVoiceOverSpeaksYesterdaysTotalNotTodays() {
        var pts = (-11 ... -2).map { TrendsEngine.DailyPoint(date: day($0), steps: 8_000) }
        pts.append(TrendsEngine.DailyPoint(date: day(-1), steps: 12_000))
        pts.append(TrendsEngine.DailyPoint(date: day(0), steps: 9_400))
        let t = tile(.steps, pts, now: at(hour: 20))
        let label = t.accessibilityLabel
        XCTAssertTrue(label.contains("Yesterday was " + 12_000.formatted(.number) + " steps, above"), label)
        XCTAssertFalse(label.contains("Yesterday was " + 9_400.formatted(.number)), label)
        XCTAssertEqual(t.deltaText, "Yesterday " + 12_000.formatted(.number) + " · +" + 4_000.formatted(.number) + " vs usual")
    }

    /// No step total today yet: the headline IS yesterday's total, so the line is about the value's
    /// own day and needs neither a day name nor a second copy of the figure.
    func testNoStepsYetTodayTheLineIsAboutTheValueAboveIt() {
        let t = tile(.steps, steps(today: nil), now: at(hour: 8))
        XCTAssertEqual(t.valueText, 7_375.formatted(.number))
        XCTAssertEqual(t.freshnessText(now: at(hour: 8), calendar: cal), "yesterday")
        XCTAssertEqual(t.valueDate, t.trend?.latest.date)
        XCTAssertEqual(t.deltaText, "−625 vs usual")
        XCTAssertTrue(t.accessibilityLabel.contains("Yesterday was within"), t.accessibilityLabel)
    }

    /// Just after midnight: the first few steps of the new day headline, and the line still names
    /// the day it judges (the one that just ended) with that day's total.
    func testJustAfterMidnightValueAndLineStayOnTheirOwnDays() {
        let now = at(hour: 0.1)
        let t = tile(.steps, steps(today: 40), now: now)
        XCTAssertEqual(t.valueText, "40")
        XCTAssertEqual(t.valueDate, day(0))
        XCTAssertEqual(t.freshnessText(now: now, calendar: cal), "today")
        XCTAssertEqual(t.deltaText, yesterdayLine)

        // The same store a few minutes earlier: that day is still today, it is the headline AND it is
        // not judged yet; the day before it is yesterday.
        let before = tile(.steps, Array(steps(today: nil)), now: at(hour: -0.1))
        XCTAssertEqual(before.valueText, 7_375.formatted(.number))
        XCTAssertEqual(before.freshnessText(now: at(hour: -0.1), calendar: cal), "today")
        XCTAssertEqual(before.deltaText, "Yesterday " + 8_000.formatted(.number) + " · ±0 vs usual")
    }

    func testAMissingBaselineRendersNoNumber() {
        let pts = [TrendsEngine.DailyPoint(date: day(-2), steps: 8_000),
                   TrendsEngine.DailyPoint(date: day(-1), steps: 7_375),
                   TrendsEngine.DailyPoint(date: day(0), steps: 300)]
        let t = tile(.steps, pts, now: at(hour: 7))
        XCTAssertNil(t.deltaText)
        XCTAssertTrue(t.rangeText.hasPrefix("Learning your usual"), t.rangeText)
        XCTAssertFalse(t.accessibilityLabel.contains("Yesterday was"), t.accessibilityLabel)
    }

    // MARK: The audited tiles: value and line are already about the same day

    private func nightly(_ pick: (Int, Double) -> TrendsEngine.DailyPoint, base: Double, last: Double,
                         endingOffset: Int) -> [TrendsEngine.DailyPoint] {
        (0..<8).map { i in pick(endingOffset - 7 + i, i == 7 ? last : base) }
    }

    private func assertSameDay(_ t: TodayTile, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(t.valueDate, file: file, line: line)
        XCTAssertEqual(t.valueDate, t.trend?.latest.date, "\(t.title): value and verdict on one day", file: file, line: line)
        XCTAssertEqual(t.deltaText, expected, file: file, line: line)
    }

    func testNightlyTilesJudgeTheNightTheyShow() {
        for offset in [0, -1, -3] {   // last night, a night that ended yesterday, an older one
            let now = at(hour: 9)
            assertSameDay(tile(.hrv, nightly({ TrendsEngine.DailyPoint(date: day($0), sleepHRVAvg: $1) },
                                             base: 50, last: 58, endingOffset: offset), now: now), "+8 ms vs usual")
            assertSameDay(tile(.spo2, nightly({ TrendsEngine.DailyPoint(date: day($0), sleepSpO2Avg: $1) },
                                              base: 0.96, last: 0.94, endingOffset: offset), now: now), "−2 % vs usual")
            assertSameDay(tile(.respiratoryRate, nightly({ TrendsEngine.DailyPoint(date: day($0), sleepRRAvg: $1) },
                                                         base: 14, last: 15, endingOffset: offset), now: now),
                          "+1.0 \(UnitsFormatter.respiratoryRateUnit) vs usual")
            assertSameDay(tile(.skinTemp, nightly({ TrendsEngine.DailyPoint(date: day($0), skinTempC: $1) },
                                                  base: 33.5, last: 34.0, endingOffset: offset), now: now), "+0.5 °C vs usual")
        }
    }

    func testRestingHRJudgesTheDayItShowsEvenWhenOlder() {
        for offset in [0, -1, -3] {
            let daily = (0..<8).map { i in
                RestingHR.DailyValue(day: day(offset - 7 + i), bpm: i == 7 ? 61 : 55)
            }
            let t = tile(.restingHR, [], restingHR: daily, now: at(hour: 9))
            XCTAssertEqual(t.valueDate, day(offset))
            assertSameDay(t, "+6 bpm vs usual")
        }
    }
}
