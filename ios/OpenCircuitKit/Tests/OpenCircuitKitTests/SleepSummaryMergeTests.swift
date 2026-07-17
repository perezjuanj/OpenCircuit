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

    /// A classifier update may reduce time asleep while retaining the exact same raw-epoch coverage
    /// (quiet wake is reclassified as awake-in-bed). That corrected result must replace the stale one.
    func testSameCoverageAllowsLowerAsleepReclassification() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: 9.25 * h, newInBed: 9.25 * h,
            storedAsleep: 9.2 * h, newAsleep: 7.6 * h,
            sameCoverage: true))
    }

    /// A capture that recovers MORE sleep (a stitched night) supersedes a thinner stored one, even at
    /// the same or smaller in-bed span.
    func testMoreAsleepReplaces() {
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: 5 * h, newInBed: 5 * h, storedAsleep: 3 * h, newAsleep: 7 * h))
    }

    /// On an EQUAL-asleep tie the WIDER in-bed span wins. An idempotent re-stage (equal span) still
    /// replaces; a NARROWER-span slice does NOT — that's the lead-in-less drain that must not clobber a
    /// bedtime-widened row.
    func testEqualAsleepKeepsWiderInBed() {
        // Same night re-staged identically → replace (idempotent).
        XCTAssertTrue(SleepSummaryMerge.shouldReplace(
            storedInBed: 5 * h, newInBed: 5 * h, storedAsleep: 5 * h, newAsleep: 5 * h))
        // Equal asleep but NARROWER new span → keep the fuller stored night.
        XCTAssertFalse(SleepSummaryMerge.shouldReplace(
            storedInBed: 8 * h, newInBed: 5 * h, storedAsleep: 5 * h, newAsleep: 5 * h))
    }

    /// Bedtime-widen durability: a morning drain widens in-bed back over the awake-in-bed lead-in
    /// (inBed 8.5 h, asleep 7.5 h, eff 0.88); a LATER same-night slice lands the same sleep core WITHOUT
    /// the lead-in (inBed 7.5 h == asleep, eff 1.0). Time-asleep ties, so the old asleep-only rule would
    /// clobber the widened row back to 100 %. The tie-break must KEEP the widened (wider in-bed) row.
    func testLeadInLessSliceDoesNotClobberWidenedRow() {
        XCTAssertFalse(SleepSummaryMerge.shouldReplace(
            storedInBed: 8.5 * h, newInBed: 7.5 * h, storedAsleep: 7.5 * h, newAsleep: 7.5 * h),
            "a lead-in-less later slice must not collapse a bedtime-widened night to 100 % efficiency")
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
