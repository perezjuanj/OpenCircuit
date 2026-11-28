import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for the Today metric tiles (#216): which day's value a tile shows, how it
/// labels freshness, that steps compare the last COMPLETE day, that the labelled usual range is the
/// same band the verdict uses, and that missing data reads as missing. No real health values.
final class TodayTilesTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-09-30 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_762_400)
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
    }

    private func tile(_ m: TodayTile.Metric, _ points: [TrendsEngine.DailyPoint],
                      restingHR: [RestingHR.DailyValue] = [], window: Int = 14) -> TodayTile {
        TodayTiles.build(m, points: points, restingHR: restingHR, tempUnit: .celsius,
                         windowDays: window, now: now, calendar: cal)
    }

    /// Nights keyed on their WAKE day (`SleepNightKey`), last night = today's key.
    private func nights(_ hrv: [Double], endingOffset: Int = 0) -> [TrendsEngine.DailyPoint] {
        hrv.enumerated().map { i, v in
            TrendsEngine.DailyPoint(date: day(endingOffset - (hrv.count - 1 - i)), sleepHRVAvg: v)
        }
    }

    func testNoDataSaysSo() {
        let t = tile(.hrv, [])
        XCTAssertNil(t.valueText)
        XCTAssertEqual(t.rangeText, "No data yet")
        XCTAssertNil(t.deltaText)
        XCTAssertNil(t.freshnessText(now: now, calendar: cal))
        XCTAssertEqual(t.values.count, 14)
        XCTAssertTrue(t.values.allSatisfy { $0 == nil })
    }

    func testLastNightIsFreshAndBandMatchesVerdict() {
        let t = tile(.hrv, nights([50, 50, 50, 50, 50, 58]))
        XCTAssertEqual(t.valueText, "58")
        XCTAssertEqual(t.freshnessText(now: now, calendar: cal), "last night")
        XCTAssertFalse(t.isStale(now: now, calendar: cal))
        XCTAssertEqual(t.trend?.direction, .above)
        XCTAssertEqual(t.deltaText, "+8 ms vs usual")
        // Floor 3 ms, flat baseline → the band is exactly 47–53, the range the label names.
        XCTAssertEqual(t.rangeText, "Usual 47–53 ms")
        XCTAssertEqual(t.values.last!, 58)
    }

    func testANightThatEndedYesterdayIsStale() {
        let t = tile(.hrv, nights([50, 50, 50, 50, 50], endingOffset: -1))
        XCTAssertTrue(t.isStale(now: now, calendar: cal))
        XCTAssertTrue(t.freshnessText(now: now, calendar: cal)?.hasPrefix("night to") == true)
        XCTAssertNil(t.values.last!, "no value for today's key")
    }

    func testThinBaselineIsLearning() {
        let t = tile(.hrv, nights([50, 52, 58]))
        XCTAssertNil(t.trend?.direction)
        XCTAssertNil(t.deltaText)
        XCTAssertEqual(t.rangeText, "Learning your usual · 2/4 days")
    }

    func testGapsStayGaps() {
        var pts = nights([50, 50, 50, 50, 50, 50])
        pts.remove(at: 2)
        let t = tile(.hrv, pts)
        XCTAssertEqual(t.values.suffix(6).filter { $0 == nil }.count, 1)
    }

    func testStepsHeadlineIsTodayButTrendIsYesterday() {
        let pts = (0..<8).map { i -> TrendsEngine.DailyPoint in
            let offset = i - 7   // −7 … 0 (today)
            return TrendsEngine.DailyPoint(date: day(offset), steps: offset == 0 ? 1_200 : (offset == -1 ? 12_000 : 8_000))
        }
        let t = tile(.steps, pts)
        XCTAssertEqual(t.valueText, 1_200.formatted(.number))
        XCTAssertEqual(t.freshnessText(now: now, calendar: cal), "today")
        XCTAssertTrue(t.trendIsYesterday)
        XCTAssertEqual(t.trend?.direction, .above)
        XCTAssertEqual(t.deltaText, "Yesterday " + 12_000.formatted(.number) + " · +" + 4_000.formatted(.number) + " vs usual")
        XCTAssertNil(t.values.last!, "today's partial total is not plotted")
        XCTAssertEqual(t.values[t.values.count - 2], 12_000)
    }

    /// Review #220 S2 (the reviewer's probe, asserting the fix). Yesterday has no step total (the
    /// ring was charging), so the last complete day the trend judges is the day BEFORE yesterday.
    /// Under today's partial 1,200 the tile printed "+4,000 vs usual" with an up arrow, and VoiceOver
    /// said 1,200 steps was "above your usual range". Now: no delta, no arrow, no verdict; the usual
    /// range is still shown and spoken.
    func testStepsStateNoVerdictWhenYesterdayIsMissing() {
        var pts = (-8 ... -3).map { TrendsEngine.DailyPoint(date: day($0), steps: 8_000) }
        pts.append(TrendsEngine.DailyPoint(date: day(-2), steps: 12_000))
        pts.append(TrendsEngine.DailyPoint(date: day(0), steps: 1_200))
        let t = tile(.steps, pts)
        XCTAssertEqual(t.valueText, 1_200.formatted(.number))
        XCTAssertEqual(t.qualifier, "so far today")
        XCTAssertEqual(t.trend?.latest.date, day(-2))
        XCTAssertFalse(t.trendIsYesterday)
        XCTAssertNil(t.statedTrend)
        XCTAssertNil(t.deltaText, "no delta, and so no arrow, under today's number")
        XCTAssertTrue(t.rangeText.hasPrefix("Usual "), "the band and its label still show")
        XCTAssertFalse(t.accessibilityLabel.contains("above"), t.accessibilityLabel)
        XCTAssertFalse(t.accessibilityLabel.contains("That's"), t.accessibilityLabel)
        XCTAssertTrue(t.accessibilityLabel.contains("Your usual range is"), t.accessibilityLabel)
        XCTAssertFalse(t.accessibilityLabel.contains("still learning"), t.accessibilityLabel)

        // The same with no step total today either: the headline is the day before yesterday's, and
        // the rule is the same — a steps verdict is stated about yesterday or not at all.
        let stale = tile(.steps, Array(pts.dropLast()))
        XCTAssertEqual(stale.qualifier, "latest day")
        XCTAssertNil(stale.deltaText)
    }

    func testRestingHRUsesTheDerivedSeries() {
        let rhr = (0..<6).map { RestingHR.DailyValue(day: day($0 - 5), bpm: $0 == 5 ? 58 : 52) }
        let t = tile(.restingHR, [], restingHR: rhr)
        XCTAssertEqual(t.valueText, "58")
        XCTAssertEqual(t.freshnessText(now: now, calendar: cal), "today")
        XCTAssertEqual(t.trend?.direction, .above)
    }

    /// Review #220 F2. The detail screen said resting HR was "the day's lowest 5-minute average";
    /// on a day of spot reads 10 minutes apart (the auto-measure cadence) no 5-minute window holds
    /// two readings, so the value is the single lowest READING. The copy now says exactly that.
    func testTheRestingHRCopyDescribesTheSparseReadingFallback() {
        let bpms = [64, 61, 48, 63, 62, 60]
        let hr = bpms.enumerated().map { i, b in
            HRSample(bpm: b, start: now.addingTimeInterval(Double(i) * 600),
                     end: now.addingTimeInterval(Double(i) * 600 + 60))
        }
        XCTAssertEqual(RestingHR.dailyValues(hr: hr, calendar: cal).map(\.bpm), [48])
        let copy = MetricDetailView.what(.restingHR)
        XCTAssertTrue(copy.contains("lowest reading when readings are sparse"), copy)
        XCTAssertFalse(copy.contains("5-minute average"), copy)
    }

    func testThirtyDayWindow() {
        let t = tile(.hrv, nights(Array(repeating: 50, count: 30)), window: 30)
        XCTAssertEqual(t.values.count, 30)
        XCTAssertEqual(t.values.compactMap { $0 }.count, 30)
        XCTAssertEqual(t.trend?.baselineDays, 29)
    }

    func testSynthesisIgnoresStaleTiles() {
        let tiles = [tile(.hrv, nights([50, 50, 50, 50, 50, 40], endingOffset: -2))]
        var trends = TrendsData()
        trends.newestSampleAt = now.addingTimeInterval(-3600)
        let input = TodaySynthesis.input(trends: trends, tiles: tiles, readiness: nil, lastSyncAt: nil, now: now)
        XCTAssertNil(input.hrv, "a two-day-old night must not be reported as today's HRV")
    }

    /// Review #220 S3: the fever pairing is Vitals Status's verdict, passed through untouched — never
    /// derived from the tiles. Two tiles above their usual, no Vitals Status fever: no pairing.
    func testSynthesisTakesFeverSignsFromVitalsStatusOnly() {
        let hot = [33.5, 33.5, 33.5, 33.5, 33.5, 33.9].enumerated().map { i, v in
            TrendsEngine.DailyPoint(date: day(i - 5), skinTempC: v)
        }
        let rhr = (0..<6).map { RestingHR.DailyValue(day: day($0 - 5), bpm: $0 == 5 ? 61 : 58) }
        let tiles = [tile(.skinTemp, hot), tile(.restingHR, [], restingHR: rhr)]
        XCTAssertEqual(tiles.map { $0.trend?.direction }, [.above, .above])
        var trends = TrendsData()
        trends.newestSampleAt = now.addingTimeInterval(-3600)

        let quiet = TodaySynthesis.input(trends: trends, tiles: tiles, readiness: nil, lastSyncAt: now, now: now)
        XCTAssertFalse(quiet.feverSuspected)
        XCTAssertFalse(TodaySynthesis.sentence(quiet).contains("gently"))

        let flagged = TodaySynthesis.input(trends: trends, tiles: tiles, readiness: nil, feverSuspected: true,
                                           lastSyncAt: now, now: now)
        XCTAssertTrue(flagged.feverSuspected)
        XCTAssertEqual(TodaySynthesis.sentence(flagged),
                       "Skin temperature and resting heart rate are both above your usual, so take today gently.")
    }

    func testSynthesisNeverClaimsNoDataAfterASync() {
        let input = TodaySynthesis.input(trends: TrendsData(), tiles: [], readiness: nil,
                                         lastSyncAt: now.addingTimeInterval(-86_400 * 20), now: now)
        XCTAssertEqual(TodaySynthesis.sentence(input),
                       "Your newest data is more than two weeks old, so sync your device to bring today's summary up to date.")
    }
}
