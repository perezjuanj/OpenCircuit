import XCTest
@testable import OpenCircuitKit

final class SleepCaptureCoverageTests: XCTestCase {
    private let h = 3600.0
    private typealias C = SleepCaptureCoverage

    /// Bedtime 22:30; build onset/wake relative to it.
    private func bedtime() -> Date { Date(timeIntervalSince1970: 1_780_000_000) }

    /// The reported bug shape: bed 22:30, real wake ~07:00, but only the last ~4.75 h drained, so the
    /// captured onset is ~02:15 (≈3.75 h after bedtime) — the front of the night is missing.
    func testMissingFrontIsTruncated() {
        let bed = bedtime()
        let onset = bed.addingTimeInterval(3.75 * h)
        XCTAssertEqual(C.classify(capturedOnset: onset, capturedInBed: 4.75 * h, scheduledBedtime: bed),
                       .likelyTruncated)
    }

    /// A short night that FIT in the buffer (onset at bedtime, woke early after 4.5 h) is complete, not
    /// truncated — this is the false positive duration-only flagging would have produced.
    func testShortNightThatFitTheBufferIsFull() {
        let bed = bedtime()
        XCTAssertEqual(C.classify(capturedOnset: bed, capturedInBed: 4.5 * h, scheduledBedtime: bed),
                       .full)
    }

    /// A full night (span beyond the buffer) is complete regardless of onset — it was drained overnight.
    func testOverBufferIsFull() {
        let bed = bedtime()
        let onset = bed.addingTimeInterval(4 * h)   // even a late onset
        XCTAssertEqual(C.classify(capturedOnset: onset, capturedInBed: 8 * h, scheduledBedtime: bed),
                       .full)
    }

    /// Onset only slightly after bedtime (< minMissingOnset) is not a missing front.
    func testOnsetNearBedtimeIsFull() {
        let bed = bedtime()
        let onset = bed.addingTimeInterval(30 * 60)
        XCTAssertEqual(C.classify(capturedOnset: onset, capturedInBed: 4.6 * h, scheduledBedtime: bed),
                       .full)
    }

    /// Onset BEFORE bedtime (went to bed early) is never truncated.
    func testOnsetBeforeBedtimeIsFull() {
        let bed = bedtime()
        let onset = bed.addingTimeInterval(-20 * 60)
        XCTAssertEqual(C.classify(capturedOnset: onset, capturedInBed: 4.5 * h, scheduledBedtime: bed),
                       .full)
    }

    /// No schedule ⇒ no bedtime reference ⇒ never flagged (avoids nagging when we can't tell).
    func testNoScheduleIsFull() {
        let onset = bedtime().addingTimeInterval(4 * h)
        XCTAssertEqual(C.classify(capturedOnset: onset, capturedInBed: 4.75 * h, scheduledBedtime: nil),
                       .full)
    }

    /// Degenerate / empty spans are treated as "can't tell" → full.
    func testZeroSpanIsFull() {
        let bed = bedtime()
        XCTAssertEqual(C.classify(capturedOnset: bed, capturedInBed: 0, scheduledBedtime: bed), .full)
        XCTAssertEqual(C.classify(capturedOnset: bed, capturedInBed: -10, scheduledBedtime: bed), .full)
    }

    /// Boundary: a span just past the buffer + slack is full even with a late onset.
    func testJustOverBufferPlusSlackIsFull() {
        let bed = bedtime()
        let onset = bed.addingTimeInterval(3 * h)
        XCTAssertEqual(C.classify(capturedOnset: onset,
                                  capturedInBed: C.ringBufferSeconds + C.bufferSlack + 60,
                                  scheduledBedtime: bed), .full)
    }

    /// Boundary: onset exactly minMissingOnset after bedtime, span within buffer ⇒ truncated.
    func testOnsetExactlyAtThresholdIsTruncated() {
        let bed = bedtime()
        let onset = bed.addingTimeInterval(C.minMissingOnset)
        XCTAssertEqual(C.classify(capturedOnset: onset, capturedInBed: 4.75 * h, scheduledBedtime: bed),
                       .likelyTruncated)
    }
}
