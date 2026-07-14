import XCTest
@testable import OpenCircuitKit

/// Tests for the manual sleep-edit bounds + validation (#176), matching RingConn's ±3 h rule:
/// edits are limited to within 3 h before the recorded sleep onset and 3 h after the recorded wake.
final class SleepEditTests: XCTestCase {

    private let ref = Date(timeIntervalSince1970: 1_700_000_000)   // fixed anchor, no wall-clock
    private func at(_ hoursFromRef: Double) -> Date { ref.addingTimeInterval(hoursFromRef * 3600) }

    func testEditMarginIsThreeHours() {
        XCTAssertEqual(SleepEdit.editMargin, 3 * 3600, accuracy: 0.0001)
    }

    func testBoundsAreOnsetMinus3hToWakePlus3h() {
        // Recorded: onset 0h, wake 8h.
        let b = SleepEdit.bounds(recordedOnset: at(0), recordedWake: at(8))
        XCTAssertEqual(b.earliest, at(-3))
        XCTAssertEqual(b.latest, at(11))
    }

    func testClampPinsToBounds() {
        let b = SleepEdit.bounds(recordedOnset: at(0), recordedWake: at(8))
        XCTAssertEqual(SleepEdit.clamp(at(-5), to: b), at(-3))   // below → earliest
        XCTAssertEqual(SleepEdit.clamp(at(20), to: b), at(11))   // above → latest
        XCTAssertEqual(SleepEdit.clamp(at(2), to: b), at(2))     // inside → unchanged
    }

    func testPickerMinuteComparisonIgnoresHiddenSecondsOnly() {
        let calendar = Calendar(identifier: .gregorian)
        let minute = calendar.dateInterval(of: .minute, for: at(2))!.start
        XCTAssertTrue(SleepEdit.isSamePickerMinute(minute.addingTimeInterval(5),
                                                   minute.addingTimeInterval(55),
                                                   calendar: calendar))
        XCTAssertFalse(SleepEdit.isSamePickerMinute(minute.addingTimeInterval(55),
                                                    minute.addingTimeInterval(65),
                                                    calendar: calendar))
    }

    func testValidWindowInsideBounds() {
        // Extend a truncated morning: wake 8h → 9.5h (within +3h), bedtime 0h → −0.5h. Valid.
        let w = SleepEdit.Window(inBedStart: at(-0.5), inBedEnd: at(9.5))
        XCTAssertNil(SleepEdit.validate(w, recordedOnset: at(0), recordedWake: at(8)))
        XCTAssertTrue(SleepEdit.isValid(w, recordedOnset: at(0), recordedWake: at(8)))
    }

    func testExactBoundaryIsAllowed() {
        // Exactly onset−3h .. wake+3h is allowed (inclusive).
        let w = SleepEdit.Window(inBedStart: at(-3), inBedEnd: at(11))
        XCTAssertNil(SleepEdit.validate(w, recordedOnset: at(0), recordedWake: at(8)))
    }

    func testStartTooEarlyRejected() {
        let w = SleepEdit.Window(inBedStart: at(-3.5), inBedEnd: at(8))
        XCTAssertEqual(SleepEdit.validate(w, recordedOnset: at(0), recordedWake: at(8)), .startBeforeEarliest)
    }

    func testEndTooLateRejected() {
        let w = SleepEdit.Window(inBedStart: at(0), inBedEnd: at(11.5))
        XCTAssertEqual(SleepEdit.validate(w, recordedOnset: at(0), recordedWake: at(8)), .endAfterLatest)
    }

    func testEndNotAfterStartRejected() {
        let w = SleepEdit.Window(inBedStart: at(5), inBedEnd: at(5))
        XCTAssertEqual(SleepEdit.validate(w, recordedOnset: at(0), recordedWake: at(8)), .endNotAfterStart)
    }

    func testTooShortRejected() {
        // 20-min window with a 60-min floor.
        let w = SleepEdit.Window(inBedStart: at(1), inBedEnd: at(1.0 / 3.0 + 1))
        XCTAssertEqual(SleepEdit.validate(w, recordedOnset: at(0), recordedWake: at(8),
                                          minDuration: 60 * 60), .tooShort(minMinutes: 60))
    }

    func testWindowDuration() {
        XCTAssertEqual(SleepEdit.Window(inBedStart: at(0), inBedEnd: at(7.5)).duration, 7.5 * 3600, accuracy: 0.1)
        // Degenerate (end before start) is clamped to 0, never negative.
        XCTAssertEqual(SleepEdit.Window(inBedStart: at(5), inBedEnd: at(4)).duration, 0)
    }

    // MARK: recompute

    private func seg(_ a: Double, _ b: Double, _ stage: SleepStage) -> SleepSegment {
        SleepSegment(start: at(a), end: at(b), stage: stage)
    }

    func testRecomputeExtendsTailAsAsleep() {
        // Recorded 0–6.8h; user drags wake to 8.5h. The tail 6.8–8.5 is credited as asleep (core).
        let base = [seg(0, 6.8, .asleepCore)]
        let out = SleepEdit.recompute(baseSegments: base, window: .init(inBedStart: at(0), inBedEnd: at(8.5)))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last, seg(6.8, 8.5, .asleepCore))
        // Total asleep grew by the extension.
        let asleep = out.filter { $0.stage != .awake && $0.stage != .inBed }.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(asleep, 8.5 * 3600, accuracy: 0.1)
        XCTAssertEqual(SleepStaging.summary(out).efficiency, 1, accuracy: 0.0001)
    }

    func testRecomputeExtendsLeadAsAsleep() {
        // Recorded 1–8h; user pulls bedtime to −0.5h. The lead −0.5–1 is filled asleep.
        let base = [seg(1, 8, .asleepCore)]
        let out = SleepEdit.recompute(baseSegments: base, window: .init(inBedStart: at(-0.5), inBedEnd: at(8)))
        XCTAssertEqual(out.first, seg(-0.5, 1, .asleepCore))
        XCTAssertEqual(out.count, 2)
    }

    func testRecomputeExtendsInBedLayerWithStagedNight() {
        let base = [seg(0, 8, .inBed), seg(0, 8, .asleepCore)]
        let out = SleepEdit.recompute(baseSegments: base,
                                      window: .init(inBedStart: at(-1), inBedEnd: at(9)))
        let summary = SleepStaging.summary(out)
        XCTAssertEqual(summary.minutes.inBed, 10 * 60)
        XCTAssertEqual(summary.minutes.asleep, 10 * 60)
        XCTAssertEqual(summary.efficiency, 1, accuracy: 0.0001)
        XCTAssertEqual(out.filter { $0.stage == .inBed }.count, 3)
    }

    func testRecomputeTrimsToWindowWithoutFill() {
        // Trim to 1–7h: clip the single 0–8 segment, no fill added.
        let base = [seg(0, 8, .asleepCore)]
        let out = SleepEdit.recompute(baseSegments: base, window: .init(inBedStart: at(1), inBedEnd: at(7)))
        XCTAssertEqual(out, [seg(1, 7, .asleepCore)])
    }

    func testRecomputePreservesInteriorGap() {
        // A real mid-night awake gap (3–5h has no asleep segment) must NOT be back-filled.
        let base = [seg(0, 3, .asleepCore), seg(5, 8, .asleepDeep)]
        let out = SleepEdit.recompute(baseSegments: base, window: .init(inBedStart: at(0), inBedEnd: at(8)))
        XCTAssertEqual(out, base)   // interior gap untouched, no lead/tail extension
    }

    func testRecomputeDoesNotFillTrimmedInteriorGap() {
        let base = [seg(0, 3, .asleepCore), seg(5, 8, .asleepDeep)]
        let out = SleepEdit.recompute(baseSegments: base,
                                      window: .init(inBedStart: at(4), inBedEnd: at(6)))
        XCTAssertEqual(out, [seg(5, 6, .asleepDeep)],
                       "the 4–5 h interior gap must not be mistaken for a leading extension")
    }

    func testRecomputeWindowWhollyInsideInteriorGapStaysEmpty() {
        let base = [seg(0, 3, .asleepCore), seg(5, 8, .asleepDeep)]
        let out = SleepEdit.recompute(baseSegments: base,
                                      window: .init(inBedStart: at(3.5), inBedEnd: at(4.5)))
        XCTAssertTrue(out.isEmpty)
    }

    func testRecomputeEmptyBaseFillsWholeWindow() {
        let out = SleepEdit.recompute(baseSegments: [], window: .init(inBedStart: at(0), inBedEnd: at(7)))
        XCTAssertEqual(out, [seg(0, 7, .asleepCore)])
        XCTAssertEqual(SleepStaging.summary(out).minutes.inBed, 7 * 60)
    }

    func testRecomputeDropsSegmentsFullyOutsideWindow() {
        // A nap-fragment at 10–11h is outside a 0–8 window → dropped.
        let base = [seg(0, 8, .asleepCore), seg(10, 11, .asleepCore)]
        let out = SleepEdit.recompute(baseSegments: base, window: .init(inBedStart: at(0), inBedEnd: at(8)))
        XCTAssertEqual(out, [seg(0, 8, .asleepCore)])
    }
}
