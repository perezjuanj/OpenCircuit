import XCTest
@testable import OpenCircuitKit

/// #188 fallout — the sleep editor could not correct a badly truncated night.
///
/// THE REPORTED SYMPTOM (2026-08-04, real user): after the #188 loss staged an 8.6 h night as the
/// 07:30–08:55 tail, the edit sheet "won't let me select yesterday's date or any hour before 4 or
/// after 8". That is exactly `bounds` anchored on the recorded fragment:
///   earliest = 07:30 − 3 h = 04:30 · latest = 08:55 + 3 h = 11:55
///   "In bed" picker = earliest…onset = 04:30–07:30 → the real 00:15 bedtime was unreachable, and
///   so was the entire previous calendar day.
///
/// The fix lets the epochs we actually HOLD widen the bounds, capped at one plausible night.
final class SleepEditDataCoverageTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func d(_ day: Int, _ h: Int, _ m: Int) -> Date {
        DateComponents(calendar: cal, timeZone: TimeZone(identifier: "UTC"),
                       year: 2026, month: 8, day: day, hour: h, minute: m).date!
    }

    /// The user's night as the app recorded it after the loss.
    private var recordedOnset: Date { d(4, 7, 30) }
    private var recordedWake: Date { d(4, 8, 55) }

    // MARK: - the regression

    func testUnwidenedBoundsCannotReachTheRealBedtime() {
        // Documents the shipped behaviour that produced the report.
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        XCTAssertEqual(b.earliest, d(4, 4, 30))
        XCTAssertEqual(b.latest, d(4, 11, 55))
        XCTAssertGreaterThan(b.earliest, d(4, 0, 15), "00:15 bedtime is outside the ±3 h margin")
    }

    func testArchiveCoverageWidensBoundsToReachTheRealBedtime() {
        // The archive still holds the evening before + the morning tail.
        let coverage = d(3, 19, 45)...d(4, 8, 53)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: coverage)
        XCTAssertLessThanOrEqual(b.earliest, d(4, 0, 15),
                                 "the real 00:15 bedtime must now be selectable")
        XCTAssertGreaterThanOrEqual(b.latest, d(4, 8, 53))
    }

    func testWideningNeverGoesTighterThanTheParityFloor() {
        // A night whose data coverage is NARROWER than ±3 h must still offer the full RingConn
        // margin — widening may only ever add.
        let narrow = d(4, 7, 45)...d(4, 8, 30)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: narrow)
        XCTAssertEqual(b.earliest, d(4, 4, 30))
        XCTAssertEqual(b.latest, d(4, 11, 55))
    }

    func testSpanIsCappedAtOnePlausibleNight() {
        // The EpochArchive retains ~30 h (two nights). Coverage reaching back that far must not let
        // an edit reach into the previous night.
        let twoNights = d(3, 2, 53)...d(4, 8, 53)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: twoNights)
        XCTAssertLessThanOrEqual(b.latest.timeIntervalSince(b.earliest), SleepEdit.defaultMaxNightSpan)
        XCTAssertGreaterThan(b.earliest, d(3, 2, 53), "must not reach the neighbouring night")
        XCTAssertLessThanOrEqual(b.earliest, d(4, 0, 15), "…but still reaches this night's bedtime")
    }

    func testNilCoverageIsExactlyTheOldBehaviour() {
        let old = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        let new = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                   dataCoverage: nil)
        XCTAssertEqual(old, new)
    }

    // MARK: - dataCoverage itself

    func testCoverageIsScopedToTheNightNotTheWholeArchive() {
        // Records spanning two nights; only those within one night-span of the recorded anchors count.
        let dates = [d(2, 23, 0), d(3, 3, 0), d(3, 22, 0), d(4, 2, 0), d(4, 8, 53)]
        let c = SleepEdit.dataCoverage(recordDates: dates,
                                       recordedOnset: recordedOnset, recordedWake: recordedWake)
        let cov = try! XCTUnwrap(c)
        XCTAssertGreaterThanOrEqual(cov.lowerBound, d(3, 18, 55),
                                    "records older than wake − maxNightSpan are excluded")
        XCTAssertEqual(cov.upperBound, d(4, 8, 53))
    }

    func testCoverageIsNilWhenNoRecordsFallInTheWindow() {
        XCTAssertNil(SleepEdit.dataCoverage(recordDates: [d(1, 4, 0)],
                                            recordedOnset: recordedOnset, recordedWake: recordedWake))
        XCTAssertNil(SleepEdit.dataCoverage(recordDates: [],
                                            recordedOnset: recordedOnset, recordedWake: recordedWake))
    }

    // MARK: - the validator must agree with the picker

    func testValidatorAcceptsTheWidenedWindowThePickerNowOffers() {
        let coverage = d(3, 19, 45)...d(4, 8, 53)
        let times = SleepEdit.Times(inBedStart: d(4, 0, 15),
                                    sleepOnset: d(4, 0, 30),
                                    sleepWake: d(4, 8, 53))
        // Without coverage the server-side check rejects it — that mismatch is the bug class where
        // the picker offers a time Save then silently refuses.
        XCTAssertEqual(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                          recordedWake: recordedWake),
                       .startBeforeEarliest)
        XCTAssertNil(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                        recordedWake: recordedWake, dataCoverage: coverage))
    }

    func testWideningStillRejectsAnInventedNight() {
        // The guarantee that must survive: you cannot assert sleep in open space far from any data.
        let coverage = d(3, 19, 45)...d(4, 8, 53)
        let times = SleepEdit.Times(inBedStart: d(2, 21, 0),
                                    sleepOnset: d(2, 21, 30),
                                    sleepWake: d(3, 5, 0))
        XCTAssertNotNil(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                           recordedWake: recordedWake, dataCoverage: coverage))
    }
}
