import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY tests for which finalized days reach Apple Health as resting HR (#298, Juan
/// 2026-10-12): a day below `RestingHR.dayCoverage` is not written, every written value is the one
/// the derivation always produced, and the day-watermark neither blocks later days nor rewrites one.
/// Drives `HealthKitWriter.restingHRWritePlan` + `writeRestingHRDays` with a recording writer, so
/// no HealthKit is involved.
@MainActor
final class RestingHRHealthWriteTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-09-30 13:00 UTC: today is past the 12 h finalization delay.
    private let now = Date(timeIntervalSince1970: 1_790_773_200)
    private var today: Date { cal.startOfDay(for: now) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
    private let never = Date(timeIntervalSince1970: 0)

    // MARK: Fixtures

    /// Ring epochs (150 s) from midnight to noon: `usual` for half an hour at 03:00, `usual + 12` otherwise.
    private func fullDay(_ day: Date, usual: Int = 52) -> [HRSample] {
        (0..<289).map { i in
            HRSample(bpm: (72...83).contains(i) ? usual : usual + 12, start: day.addingTimeInterval(Double(i) * 150))
        }
    }

    /// Five awake spot reads ten minutes apart from 08:00.
    private func thinDay(_ day: Date) -> [HRSample] {
        (0..<5).map { HRSample(bpm: 80 + $0, start: day.addingTimeInterval(8 * 3600 + Double($0) * 600)) }
    }

    private func plan(_ hr: [HRSample], sleep: [SleepSegment] = [], lastWritten: Date? = nil,
                      now: Date? = nil) -> [HealthKitWriter.RestingHRPlanDay] {
        HealthKitWriter.restingHRWritePlan(hr: hr, sleepSegments: sleep, lastWritten: lastWritten ?? never,
                                           now: now ?? self.now, calendar: cal)
    }

    /// Runs one flush's write loop; returns what was written and the new watermark.
    private func flush(_ hr: [HRSample], sleep: [SleepSegment] = [], lastWritten: Date? = nil,
                       now: Date? = nil) async -> (writes: [(bpm: Double, day: Date)], watermark: Date) {
        let from = lastWritten ?? never
        var writes: [(bpm: Double, day: Date)] = []
        let outcome = await HealthKitWriter.writeRestingHRDays(
            plan(hr, sleep: sleep, lastWritten: from, now: now), lastWritten: from) { writes.append(($0, $1)) }
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(outcome.written, writes.count)
        return (writes, outcome.watermark)
    }

    // MARK: The floor on the write

    func testAThinFinalizedDayIsNotWritten() async {
        let r = await flush(thinDay(day(-1)))
        XCTAssertTrue(r.writes.isEmpty)
        XCTAssertEqual(r.watermark, never)
        XCTAssertEqual(plan(thinDay(day(-1))), [.init(day: day(-1), bpm: nil)])
    }

    func testAFullDaytimeOnlyDayIsStillWrittenWithTheSameValue() async {
        let hr = fullDay(day(-1))
        let r = await flush(hr)
        XCTAssertEqual(r.writes.map(\.day), [day(-1)])
        XCTAssertEqual(r.writes.map(\.bpm), [52])
        // The value the unfloored derivation (the write before #298) gives for the same readings.
        XCTAssertEqual(r.writes.map(\.bpm), RestingHR.dailyValues(hr: hr, sleep: [], calendar: cal).map(\.bpm))
    }

    func testASleepMeanDayIsUnchanged() async {
        // Three asleep readings and nothing else: thin by the daytime floor, answered by the sleep tier.
        let night = (0..<3).map { HRSample(bpm: 50, start: day(-1).addingTimeInterval(2 * 3600 + Double($0) * 600)) }
        let sleep = [SleepSegment(start: day(-1).addingTimeInterval(3600),
                                  end: day(-1).addingTimeInterval(4 * 3600), stage: .asleepCore)]
        let r = await flush(night, sleep: sleep)
        XCTAssertEqual(r.writes.map(\.bpm), [50])
        XCTAssertEqual(r.writes.map(\.bpm), RestingHR.dailyValues(hr: night, sleep: sleep, calendar: cal).map(\.bpm))
    }

    func testTodayIsWrittenOnlyOnceFullAfterTheDelay() async {
        // Past the delay with only a few awake readings (the night not synced yet): nothing.
        let early = await flush(fullDay(day(-1)) + thinDay(today), lastWritten: day(-1))
        XCTAssertTrue(early.writes.isEmpty)
        XCTAssertEqual(early.watermark, day(-1))
        // The night syncs later the same day: today is written with its full value.
        let later = await flush(fullDay(day(-1)) + fullDay(today, usual: 54) + thinDay(today), lastWritten: day(-1))
        XCTAssertEqual(later.writes.map(\.day), [today])
        XCTAssertEqual(later.writes.map(\.bpm), [54])
    }

    // MARK: The watermark

    func testAThinDayBetweenTwoFullDaysDoesNotBlockTheLaterOne() async {
        let r = await flush(fullDay(day(-3)) + thinDay(day(-2)) + fullDay(day(-1), usual: 56))
        XCTAssertEqual(r.writes.map(\.day), [day(-3), day(-1)])
        XCTAssertEqual(r.writes.map(\.bpm), [52, 56])
        XCTAssertEqual(r.watermark, day(-1), "past all three days")
    }

    func testASkippedDayBehindTheWatermarkIsNeverWrittenEvenIfItFillsIn() async {
        // After the run above the watermark is day −1; day −2's readings then fill in.
        let filled = fullDay(day(-3)) + thinDay(day(-2)) + fullDay(day(-2), usual: 60) + fullDay(day(-1), usual: 56)
        XCTAssertEqual(plan(filled, lastWritten: day(-1)), [])
        let r = await flush(filled, lastWritten: day(-1))
        XCTAssertTrue(r.writes.isEmpty)
        XCTAssertEqual(r.watermark, day(-1))
    }

    func testATrailingThinDayStaysEligibleAndIsWrittenFullWhenItsReadingsArrive() async {
        // Run 1: day −2 full, day −1 thin (finalized). Only day −2 is written.
        let first = await flush(fullDay(day(-2)) + thinDay(day(-1)))
        XCTAssertEqual(first.writes.map(\.day), [day(-2)])
        XCTAssertEqual(first.watermark, day(-2))
        // Run 2: day −1's night syncs late. Day −1 is written with its FULL value, never the thin one.
        let second = await flush(fullDay(day(-2)) + thinDay(day(-1)) + fullDay(day(-1), usual: 58),
                                 lastWritten: first.watermark)
        XCTAssertEqual(second.writes.map(\.day), [day(-1)])
        XCTAssertEqual(second.writes.map(\.bpm), [58])
        XCTAssertEqual(second.watermark, day(-1))
    }

    func testATrailingThinDayThatStaysThinIsNeverWrittenAndAgesOut() async {
        let hr = fullDay(day(-2)) + thinDay(day(-1))
        let again = await flush(hr, lastWritten: day(-2))
        XCTAssertTrue(again.writes.isEmpty)
        XCTAssertEqual(again.watermark, day(-2))
        // A week on, it is past the scan's lookback and no longer considered at all.
        let weekLater = cal.date(byAdding: .day, value: 8, to: now)!
        XCTAssertEqual(plan(hr, lastWritten: day(-2), now: weekLater), [])
    }

    // MARK: The device's own resting HR (decision 92)

    private func flushReported(_ hr: [HRSample], reported: [HRSample], lastWritten: Date? = nil,
                               now: Date? = nil) async -> (writes: [(bpm: Double, day: Date)], watermark: Date) {
        let from = lastWritten ?? never
        var writes: [(bpm: Double, day: Date)] = []
        let plan = HealthKitWriter.restingHRWritePlan(hr: hr, reported: reported, sleepSegments: [],
                                                      lastWritten: from, now: now ?? self.now, calendar: cal)
        let outcome = await HealthKitWriter.writeRestingHRDays(plan, lastWritten: from) { writes.append(($0, $1)) }
        XCTAssertFalse(outcome.failed)
        return (writes, outcome.watermark)
    }

    func testAStrapDayIsWrittenWithTheStrapsLatestValue() async {
        // The derivation says 52; the strap revised its own value overnight to 57, the latest record.
        let reported = [HRSample(bpm: 63, start: day(-2).addingTimeInterval(22 * 3600)),
                        HRSample(bpm: 59, start: day(-1).addingTimeInterval(2 * 3600)),
                        HRSample(bpm: 57, start: day(-1).addingTimeInterval(7 * 3600))]
        let r = await flushReported(fullDay(day(-1)), reported: reported)
        XCTAssertEqual(r.writes.map(\.day), [day(-1)])
        XCTAssertEqual(r.writes.map(\.bpm), [57])
        XCTAssertEqual(r.watermark, day(-1))
    }

    func testADayWithoutAStrapRecordFallsBackToTheDerivation() async {
        let reported = [HRSample(bpm: 57, start: day(-1).addingTimeInterval(3 * 3600))]
        let r = await flushReported(fullDay(day(-2), usual: 54) + fullDay(day(-1)), reported: reported)
        XCTAssertEqual(r.writes.map(\.day), [day(-2), day(-1)])
        XCTAssertEqual(r.writes.map(\.bpm), [54, 57])
    }

    func testAStrapValueIsWrittenOnAThinDay() async {
        // The derivation holds a thin day back (#298); the strap's own value is not an awake estimate.
        let reported = [HRSample(bpm: 55, start: day(-1).addingTimeInterval(4 * 3600))]
        let r = await flushReported(thinDay(day(-1)), reported: reported)
        XCTAssertEqual(r.writes.map(\.bpm), [55])
    }

    func testAStrapDayIsWrittenOnlyAfterTheDelay() async {
        // Today's record exists, but today isn't 12 h old yet at 08:00: nothing for today.
        let morning = today.addingTimeInterval(8 * 3600)
        let reported = [HRSample(bpm: 55, start: today.addingTimeInterval(3 * 3600))]
        let r = await flushReported([], reported: reported, lastWritten: day(-1), now: morning)
        XCTAssertTrue(r.writes.isEmpty)
        XCTAssertEqual(r.watermark, day(-1))
    }

    func testAnEveningBeforeRecordIsNotLostToTheWatermark() async {
        // Day −2 is written. Day −1's only record was stamped on day −2 at 23:00 (before the
        // watermark's day ended), and still belongs to day −1.
        let reported = [HRSample(bpm: 61, start: day(-2).addingTimeInterval(23 * 3600))]
        let r = await flushReported([], reported: reported, lastWritten: day(-2))
        XCTAssertEqual(r.writes.map(\.day), [day(-1)])
        XCTAssertEqual(r.writes.map(\.bpm), [61])
    }

    func testAWrittenDayIsNotRewrittenWhenAStrapRecordArrivesLater() async {
        let reported = [HRSample(bpm: 57, start: day(-1).addingTimeInterval(3 * 3600))]
        let r = await flushReported(fullDay(day(-1)), reported: reported, lastWritten: day(-1))
        XCTAssertTrue(r.writes.isEmpty)
    }

    func testAlreadyWrittenDaysAreNeverRewritten() async {
        let r = await flush(fullDay(day(-2)) + fullDay(day(-1), usual: 56), lastWritten: day(-1))
        XCTAssertTrue(r.writes.isEmpty)
        XCTAssertEqual(r.watermark, day(-1))
    }

    func testADayIsNotConsideredBeforeItsFinalizationDelay() {
        // 10:00: today is not finalized yet, full or thin.
        let morning = today.addingTimeInterval(10 * 3600)
        XCTAssertEqual(plan(fullDay(day(-1)) + fullDay(today), lastWritten: day(-1), now: morning), [])
    }

    func testAWriteFailureStopsAndKeepsTheWatermarkOnTheLastWrittenDay() async {
        let p = plan(fullDay(day(-3)) + thinDay(day(-2)) + fullDay(day(-1)))
        var calls = 0
        let outcome = await HealthKitWriter.writeRestingHRDays(p, lastWritten: never) { _, day in
            calls += 1
            if day == self.day(-1) { throw CancellationError() }
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.watermark, day(-3))
        XCTAssertTrue(outcome.failed)
    }
}
