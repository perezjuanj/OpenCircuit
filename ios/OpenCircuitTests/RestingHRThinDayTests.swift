import XCTest
import SwiftData
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for #298: a day whose resting HR would rest on a few awake readings has no
/// value on the Today tile, in Vitals Status, in the notifications' series and in the overnight
/// signals, while the Apple Health write and basal-energy derivations keep their values.
///
/// Shape: full ring days (150 s epochs, midnight to noon, a low block at 03:00) at a usual resting
/// HR, then a thin last day of five awake spot reads well above it.
@MainActor
final class RestingHRThinDayTests: XCTestCase {

    private var containers: [ModelContainer] = []
    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    // MARK: Fixtures

    private func fullDay(_ day: Date, usual: Int) -> [HRSample] {
        (0..<289).map { i in
            HRSample(bpm: (72...83).contains(i) ? usual : usual + 12, start: day.addingTimeInterval(Double(i) * 150))
        }
    }

    private func thinDay(_ day: Date) -> [HRSample] {
        (0..<5).map { HRSample(bpm: 80 + $0, start: day.addingTimeInterval(8 * 3600 + Double($0) * 600)) }
    }

    /// `fullDays` full days ending the day before `last`, then a thin `last` day.
    private func history(fullDays: Int, last: Date, calendar: Calendar, usual: Int = 58) -> [HRSample] {
        let full = (1...fullDays).reversed().flatMap { back in
            fullDay(calendar.date(byAdding: .day, value: -back, to: last)!, usual: usual)
        }
        return full + thinDay(last)
    }

    private func quantity(_ hr: [HRSample]) -> [QuantitySample] {
        hr.map { QuantitySample(kind: .heartRate, start: $0.start, value: Double($0.bpm)) }
    }

    // MARK: Today tile

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-09-30 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_762_400)
    private var today: Date { utc.startOfDay(for: now) }
    private func day(_ offset: Int) -> Date { utc.date(byAdding: .day, value: offset, to: today)! }

    private func restingTile(_ series: [RestingHR.DailyValue]) -> TodayTile {
        TodayTiles.build(.restingHR, points: [], restingHR: series, tempUnit: .celsius,
                         now: now, calendar: utc)
    }

    func testTheTileFallsBackToYesterdayWhenTodayIsThin() {
        let hr = history(fullDays: 6, last: today, calendar: utc)
        // Before the floor, today's five awake reads WERE today's resting HR.
        let unfloored = RestingHR.dailyValues(hr: hr, calendar: utc)
        XCTAssertEqual(restingTile(unfloored).valueText, "80")
        XCTAssertEqual(restingTile(unfloored).freshnessText(now: now, calendar: utc), "today")

        let tile = restingTile(TrendsData.restingHRDaily(quantity(hr), calendar: utc))
        XCTAssertEqual(tile.valueText, "58")
        XCTAssertEqual(tile.valueDate, day(-1))
        XCTAssertEqual(tile.freshnessText(now: now, calendar: utc), "yesterday")
        XCTAssertFalse(tile.isStale(now: now, calendar: utc))
    }

    func testTheTileLabelsAnOlderFullDayWithItsDate() {
        // Yesterday was thin too: the headline is the day before, labelled "as of <weekday day>".
        var hr = history(fullDays: 6, last: day(-1), calendar: utc)
        hr += thinDay(today)
        let tile = restingTile(TrendsData.restingHRDaily(quantity(hr), calendar: utc))
        XCTAssertEqual(tile.valueText, "58")
        XCTAssertEqual(tile.valueDate, day(-2))
        let label = tile.freshnessText(now: now, calendar: utc)
        XCTAssertEqual(label, "as of \(day(-2).formatted(.dateTime.weekday(.abbreviated).day()))")
        XCTAssertNotEqual(label, "today")
        XCTAssertTrue(tile.isStale(now: now, calendar: utc))
    }

    func testTheTileSaysNoDataWhenNoDayIsFull() {
        let tile = restingTile(TrendsData.restingHRDaily(quantity(thinDay(today)), calendar: utc))
        XCTAssertNil(tile.valueText)
        XCTAssertEqual(tile.rangeText, "No data yet")
    }

    // MARK: The strap's own resting HR (decision 92)

    private func reportedRows(_ records: [(bpm: Int, at: Date)]) -> [QuantitySample] {
        records.map { QuantitySample(kind: .restingHeartRate, start: $0.at, value: Double($0.bpm)) }
    }

    func testTheTileShowsTheStrapsOwnValueForADayItReported() {
        let hr = (1...6).reversed().flatMap { fullDay(day(-$0), usual: 58) }
        // Yesterday the strap revised its value overnight: 63 the evening before, then 55. 55 stands.
        let reported = reportedRows([(63, day(-2).addingTimeInterval(22 * 3600)),
                                     (55, day(-1).addingTimeInterval(4 * 3600))])
        let tile = restingTile(TrendsData.restingHRDaily(quantity(hr), reported: reported, calendar: utc))
        XCTAssertEqual(tile.valueText, "55")
        XCTAssertEqual(tile.valueDate, day(-1))
        // A day the strap didn't report keeps the derivation.
        let series = TrendsData.restingHRDaily(quantity(hr), reported: reported, calendar: utc)
        XCTAssertEqual(series.first { $0.day == day(-3) }?.bpm, 58)
    }

    func testTheTileShowsTheStrapsValueOnAThinToday() {
        // Today's derivation is thin (held back), but the strap has reported today's value.
        let hr = history(fullDays: 6, last: today, calendar: utc)
        let reported = reportedRows([(54, today.addingTimeInterval(3 * 3600))])
        let tile = restingTile(TrendsData.restingHRDaily(quantity(hr), reported: reported, calendar: utc))
        XCTAssertEqual(tile.valueText, "54")
        XCTAssertEqual(tile.freshnessText(now: now, calendar: utc), "today")
    }

    func testVitalsStatusJudgesTheStrapsOwnValue() {
        // Ten derived days at 58 and a full day today at 58: no signal. The strap says today was 75.
        let cal = Calendar.current
        let hr = (1...10).reversed().flatMap { fullDay(cal.date(byAdding: .day, value: -$0, to: localToday)!, usual: 58) }
            + fullDay(localToday, usual: 58)
        let quiet = VitalsStatusCardView.computeReport(
            hr: hr, spo2: [], hrv: [], nights: [], fallbackRestingHR: nil, fallbackSpO2: nil,
            fallbackHRV: nil, fallbackSkinTempOffsetC: nil)
        XCTAssertFalse(quiet?.signals.contains { $0.vital == .restingHR } ?? true)
        let reported = [HRSample(bpm: 75, start: localToday.addingTimeInterval(3 * 3600))]
        let report = VitalsStatusCardView.computeReport(
            hr: hr, restingReported: reported, spo2: [], hrv: [], nights: [], fallbackRestingHR: nil,
            fallbackSpO2: nil, fallbackHRV: nil, fallbackSkinTempOffsetC: nil)
        XCTAssertEqual(report?.signals.first { $0.vital == .restingHR }?.direction, .rise)
    }

    func testAFullTodayStillHeadlinesToday() {
        let hr = (1...6).reversed().flatMap { fullDay(day(-$0), usual: 58) } + fullDay(today, usual: 60)
        let tile = restingTile(TrendsData.restingHRDaily(quantity(hr), calendar: utc))
        XCTAssertEqual(tile.valueText, "60")
        XCTAssertEqual(tile.freshnessText(now: now, calendar: utc), "today")
    }

    // MARK: Vitals Status

    /// Vitals Status derives on `Calendar.current`, so these days are local.
    private var localToday: Date { Calendar.current.startOfDay(for: now) }

    func testVitalsStatusDoesNotJudgeAThinDay() {
        let hr = history(fullDays: 10, last: localToday, calendar: .current)
        let daily = VitalsStatusCardView.restingHRDaily(hr)
        XCTAssertEqual(daily.count, 10)
        XCTAssertEqual(daily.last?.day, Calendar.current.date(byAdding: .day, value: -1, to: localToday))

        let report = VitalsStatusCardView.computeReport(
            hr: hr, spo2: [], hrv: [], nights: [], fallbackRestingHR: nil, fallbackSpO2: nil,
            fallbackHRV: nil, fallbackSkinTempOffsetC: nil)
        XCTAssertNotNil(report, "ten full days are a baseline")
        XCTAssertFalse(report?.signals.contains { $0.vital == .restingHR } ?? true,
                       "the thin day's awake reads must not raise an elevated resting-HR signal")
    }

    func testVitalsStatusStillFlagsAFullElevatedDay() {
        // Control: the same baseline with a FULL day at the thin day's level is flagged.
        let cal = Calendar.current
        let hr = (1...10).reversed().flatMap { fullDay(cal.date(byAdding: .day, value: -$0, to: localToday)!, usual: 58) }
            + fullDay(localToday, usual: 80)
        let report = VitalsStatusCardView.computeReport(
            hr: hr, spo2: [], hrv: [], nights: [], fallbackRestingHR: nil, fallbackSpO2: nil,
            fallbackHRV: nil, fallbackSkinTempOffsetC: nil)
        let signal = report?.signals.first { $0.vital == .restingHR }
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.direction, .rise)
    }

    // MARK: Notifications (fever cross-check + overnight signals share this series)

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    func testTheNotificationSeriesSkipsAThinDay() async throws {
        // The series reads back ~32 days from the real clock, so the days sit in the recent past.
        let cal = Calendar.current
        let thin = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        let store = try makeStore()
        _ = try store.ingest(quantity(history(fullDays: 8, last: thin, calendar: cal)))

        let series = await HealthNotificationCenter().restingHRDailySeries(store: store)
        XCTAssertEqual(series.count, 8)
        XCTAssertEqual(series.last?.day, cal.date(byAdding: .day, value: -1, to: thin))
        XCTAssertEqual(series.last?.bpm, 58)
    }

    // MARK: Overnight signals (#183) deriving the series itself

    func testTheOvernightSignalsHaveNoRestingHRForAThinDay() {
        let hr = history(fullDays: 10, last: localToday, calendar: .current)
        let snapshot = HeadacheSnapshot(
            day: localToday, now: now, lastRingDataAt: nil, nights: [], tonight: nil,
            hr: hr, hrv: [], providedRestingHR: [], periods: [], womensHealthEnabled: false,
            scheduledBedtime: nil, headacheAlreadyLoggedToday: false, priorIndices: [])
        XCTAssertNil(HeadacheAssessmentBuilder.dayInput(snapshot).restingHR)
    }

    // MARK: What must NOT change

    func testTheBasalEnergyDerivationKeepsTheThinDay() {
        // `HealthKitWriter.dailyRestingHR` scales basal energy and stays on the unfloored derivation.
        let cal = Calendar.current
        let hr = history(fullDays: 3, last: localToday, calendar: cal)
        let daily = HealthKitWriter.dailyRestingHR(prefetchedHR: hr, now: now, calendar: cal)
        XCTAssertEqual(daily, RestingHR.dailyValues(hr: hr, sleep: [], calendar: cal))
        XCTAssertEqual(daily.map(\.bpm), [58, 58, 58, 80])
    }
}
