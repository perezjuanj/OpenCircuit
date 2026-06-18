import XCTest
@testable import OpenRingKit

final class SleepSummaryMergeTests: XCTestCase {

    private let h = 3600.0

    /// The bug: a 4 h morning fragment must NOT overwrite a fuller (8 h) stored night.
    func testShorterSliceDoesNotReplaceFullerNight() {
        XCTAssertFalse(SleepSummaryMerge.shouldReplace(storedInBed: 8 * h, newInBed: 4 * h))
    }

    /// A fuller capture SHOULD supersede a smaller stored slice (e.g. the early-night partial gets
    /// replaced once the whole night is finally drained).
    func testLongerSliceReplacesSmallerNight() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(storedInBed: 4 * h, newInBed: 8 * h))
    }

    /// Equal spans replace — re-staging the SAME night (refined extras, identical window) must apply.
    func testEqualSpanReplaces() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(storedInBed: 7.5 * h, newInBed: 7.5 * h))
    }

    /// A legacy / first row with no valid window (span 0) is always replaced, so the first real
    /// capture of a night always lands.
    func testZeroStoredAlwaysReplaces() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(storedInBed: 0, newInBed: 1 * h))
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(storedInBed: 0, newInBed: 0))
    }

    /// A negative/degenerate stored span (defensive) is treated as "no window" → replace.
    func testNegativeStoredReplaces() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(storedInBed: -10, newInBed: 2 * h))
    }

    /// Last night's exact shape: a 4 h22m fragment can't clobber the (hypothetically already-saved)
    /// ~8 h night.
    func testRegressionLastNightFragment() {
        let fragment = 4 * h + 22 * 60
        let fullNight = 8 * h
        XCTAssertFalse(SleepSummaryMerge.shouldReplace(storedInBed: fullNight, newInBed: fragment))
    }
}
