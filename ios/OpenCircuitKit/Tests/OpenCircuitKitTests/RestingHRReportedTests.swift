import XCTest
@testable import OpenCircuitKit

// Decision 92: a device-reported resting HR (the Helio Strap's `0x3a`) is the day's value; the
// derivation is the fallback. SYNTHETIC readings only (round bpm values, UTC calendar).
final class RestingHRReportedTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// A UTC midnight.
    private let day0 = Date(timeIntervalSince1970: 1_790_726_400)
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
    private func at(_ dayOffset: Int, _ hour: Double) -> Date { day(dayOffset).addingTimeInterval(hour * 3600) }
    private func rec(_ bpm: Int, _ dayOffset: Int, _ hour: Double) -> HRSample {
        HRSample(bpm: bpm, start: at(dayOffset, hour))
    }

    /// A strap day from midnight to noon on 60 s minutes: 70 bpm, a 30-minute 52 bpm block at 03:00.
    private func fullDay(_ dayOffset: Int, low: Int = 52) -> [HRSample] {
        (0..<720).map { i in HRSample(bpm: (180..<210).contains(i) ? low : 70, start: at(dayOffset, Double(i) / 60)) }
    }

    // MARK: Which day a record belongs to

    func testARecordBeforeNoonBelongsToItsOwnDay() {
        XCTAssertEqual(RestingHR.reportedDay(of: at(0, 2), calendar: cal), day(0))
        XCTAssertEqual(RestingHR.reportedDay(of: at(0, 11.99), calendar: cal), day(0))
    }

    func testARecordFromNoonOnBelongsToTheNextDay() {
        // The strap stamps some records the evening before the morning they describe (22:00–23:59).
        XCTAssertEqual(RestingHR.reportedDay(of: at(0, 12), calendar: cal), day(1))
        XCTAssertEqual(RestingHR.reportedDay(of: at(0, 22.75), calendar: cal), day(1))
    }

    // MARK: The day's value

    func testTheDaysLatestRecordIsItsValue() {
        // Revised overnight: the evening-before record, then two after midnight. The latest wins.
        let records = [rec(74, -1, 22.5), rec(65, 0, 2), rec(61, 0, 7.5)]
        XCTAssertEqual(RestingHR.reportedDailyValues(records, calendar: cal),
                       [.init(day: day(0), bpm: 61)])
    }

    func testOrderOfTheInputDoesNotMatter() {
        let records = [rec(61, 0, 7.5), rec(74, -1, 22.5), rec(65, 0, 2)]
        XCTAssertEqual(RestingHR.reportedDailyValues(records, calendar: cal).map(\.bpm), [61])
    }

    func testImplausibleRecordsAreDropped() {
        // A later 0 or 255 must not replace a real value.
        let records = [rec(58, 0, 2), rec(0, 0, 5), rec(255, 0, 6)]
        XCTAssertEqual(RestingHR.reportedDailyValues(records, calendar: cal).map(\.bpm), [58])
        XCTAssertEqual(RestingHR.reportedDailyValues([rec(0, 0, 5)], calendar: cal), [])
    }

    // MARK: Preferring reported over derived

    func testAReportedDayReplacesTheDerivedValue() {
        let hr = fullDay(0) + fullDay(1)
        XCTAssertEqual(RestingHR.dailyValues(hr: hr, calendar: cal).map(\.bpm), [52, 52])
        let mixed = RestingHR.dailyValues(hr: hr, calendar: cal, reported: [rec(57, 1, 3)])
        XCTAssertEqual(mixed, [.init(day: day(0), bpm: 52), .init(day: day(1), bpm: 57)])
    }

    func testWithNoReportedRecordsTheDerivationIsUnchanged() {
        let hr = fullDay(0) + fullDay(1, low: 55)
        XCTAssertEqual(RestingHR.dailyValues(hr: hr, calendar: cal, reported: []),
                       RestingHR.dailyValues(hr: hr, calendar: cal))
    }

    func testAReportedDayIsNotHeldBackByTheCoverageFloor() {
        // Five awake reads: thin by the floor, so the derivation gives nothing. The strap's own value stands.
        let thin = (0..<5).map { HRSample(bpm: 80, start: at(0, 8 + Double($0) / 6)) }
        XCTAssertEqual(RestingHR.dailyValues(hr: thin, calendar: cal, daytimeCoverage: RestingHR.dayCoverage), [])
        XCTAssertEqual(RestingHR.dailyValues(hr: thin, calendar: cal, daytimeCoverage: RestingHR.dayCoverage,
                                             reported: [rec(54, 0, 4)]),
                       [.init(day: day(0), bpm: 54)])
    }

    func testAReportedDayWithNoHeartRateIsStillADay() {
        XCTAssertEqual(RestingHR.dailyValues(hr: [], calendar: cal, reported: [rec(54, 0, 4)]),
                       [.init(day: day(0), bpm: 54)])
    }

    func testDaysStayAscending() {
        let derived = [RestingHR.DailyValue(day: day(0), bpm: 52), .init(day: day(2), bpm: 53)]
        let merged = RestingHR.preferringReported(derived, reported: [.init(day: day(1), bpm: 60)])
        XCTAssertEqual(merged.map(\.day), [day(0), day(1), day(2)])
        XCTAssertEqual(merged.map(\.bpm), [52, 60, 53])
    }
}
