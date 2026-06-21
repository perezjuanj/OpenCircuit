import XCTest
@testable import OpenCircuitKit

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

    // MARK: - Completeness judged on time ASLEEP, not just in-bed span

    /// The span-only proxy's blind spot: a WIDER in-bed window carrying LESS sleep (padded with
    /// awake/gaps) must NOT replace a fuller-asleep night — that shrank the displayed total.
    func testWiderSpanButLessAsleepDoesNotReplace() {
        XCTAssertFalse(SleepSummaryMerge.shouldReplace(
            storedInBed: 6 * h, newInBed: 8 * h, storedAsleep: 6 * h, newAsleep: 3 * h))
    }

    /// A capture that recovers MORE sleep (a stitched night) supersedes a thinner stored one, even at
    /// the same or smaller in-bed span.
    func testMoreAsleepReplaces() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: 5 * h, newInBed: 5 * h, storedAsleep: 3 * h, newAsleep: 7 * h))
    }

    /// Asleep dominates the span fallback: equal asleep ⇒ replace (idempotent re-stage) regardless of
    /// a narrower span.
    func testEqualAsleepReplacesDespiteNarrowerSpan() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: 8 * h, newInBed: 5 * h, storedAsleep: 5 * h, newAsleep: 5 * h))
    }

    /// With no asleep info on EITHER side (legacy rows), it falls back to the in-bed span comparison.
    func testFallsBackToSpanWhenAsleepUnknown() {
        XCTAssertFalse(SleepSummaryMerge.shouldReplace(
            storedInBed: 8 * h, newInBed: 4 * h, storedAsleep: 0, newAsleep: 0))
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: 4 * h, newInBed: 8 * h, storedAsleep: 0, newAsleep: 0))
    }

    /// A first real capture (nothing usable stored) always lands, even when its asleep is unknown.
    func testFirstCaptureLandsWhenNothingStored() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: 0, newInBed: 7 * h, storedAsleep: 0, newAsleep: 6 * h))
    }
}
