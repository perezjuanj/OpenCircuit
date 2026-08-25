// Tests/OpenCircuitKitTests/CyclePeriodMirrorTests.swift — SYNTHETIC-ONLY tests for the Apple
// Health period-mirror bounds (open-period auto-extension cap + the "nothing new" gate).
//
// These cover the two defects a tester reported on 2026-08-24: an unended period kept being synced
// as period days after it had ended, and Apple Health received "several dozen entries per day"
// because every flush deleted and rewrote the whole span.
//
// Fixed dates and a fixed UTC calendar throughout: the rules are day-arithmetic, so a test that
// leans on `Date()` and `.current` would pass or fail depending on the hour it ran.

import XCTest
@testable import OpenCircuitKit

final class CyclePeriodMirrorTests: XCTestCase {

    // MARK: Helpers

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// 2025-07-11 00:00:00 UTC — the same anchor the app-target menstrual-flow tests use.
    private let start = Date(timeIntervalSince1970: 1_752_192_000)

    private func day(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: start)!
    }

    private func dayCount(end: Date?, today: Date) -> Int {
        CyclePredictor.periodMirrorDayCount(start: start, end: end, today: today, calendar: cal)
    }

    // MARK: The cap — an open period stops extending

    /// The tester's actual complaint: "once a period has started, the app keeps syncing the
    /// following days as period days even after it has ended". An open period must stop growing.
    func testOpenPeriodStopsExtendingAtTheCap() {
        // Day 1 through day 8 are the cap's own span, so each is still mirrored in full.
        XCTAssertEqual(dayCount(end: nil, today: day(0)), 1)
        XCTAssertEqual(dayCount(end: nil, today: day(6)), 7)
        XCTAssertEqual(dayCount(end: nil, today: day(7)), CyclePredictor.maxAutoExtendPeriodDays)

        // Past it, elapsed days no longer add samples — this is the unbounded growth being fixed.
        for elapsed in [8, 9, 20, 400] {
            XCTAssertEqual(dayCount(end: nil, today: day(elapsed)),
                           CyclePredictor.maxAutoExtendPeriodDays,
                           "an open period must not still be extending \(elapsed) days in")
        }
    }

    /// The cap is a bound on the LAST DAY, not a rolling window: it must never walk forward and
    /// start dropping early days that Apple Health already holds.
    func testCapNeverRetractsDaysAlreadyWritten() {
        var previous = 0
        for elapsed in 0...30 {
            let count = dayCount(end: nil, today: day(elapsed))
            XCTAssertGreaterThanOrEqual(count, previous, "day \(elapsed) lost an earlier day")
            previous = count
        }
        XCTAssertEqual(CyclePredictor.openPeriodAutoExtendLastDay(start: start, today: day(99),
                                                                  calendar: cal),
                       day(CyclePredictor.maxAutoExtendPeriodDays - 1))
    }

    /// A start date in the future asserts nothing at all.
    func testFutureStartMirrorsNothing() {
        XCTAssertEqual(dayCount(end: nil, today: day(-1)), 0)
        XCTAssertEqual(dayCount(end: day(3), today: day(-1)), 0)
    }

    // MARK: The cap must NOT touch an explicitly-ended period

    /// A logged end date is the user's own statement, so the cap may never shorten it — not even
    /// well past the prolonged-bleeding threshold the cap is derived from.
    func testExplicitlyEndedPeriodIsUntouchedByTheCap() {
        // 14 days, logged: nearly double the cap, and every day still mirrored.
        XCTAssertEqual(dayCount(end: day(13), today: day(30)), 14)
        // A 30-day logged period likewise survives intact.
        XCTAssertEqual(dayCount(end: day(29), today: day(60)), 30)
        // Ordinary lengths are unchanged too.
        XCTAssertEqual(dayCount(end: day(4), today: day(30)), 5)
    }

    /// Finalized behaviour is otherwise exactly what it was: through the logged end, clamped to
    /// today so a future end never asserts days that haven't happened.
    func testFinalizedPeriodStillClampsToToday() {
        XCTAssertEqual(dayCount(end: day(9), today: day(3)), 4)
        XCTAssertEqual(CyclePredictor.periodMirrorLastDay(start: start, end: day(9),
                                                          today: day(3), calendar: cal),
                       day(3))
    }

    /// The clamp-to-today above is the ONE case where a finalized entry legitimately has more to
    /// write later, so it must not be reported as up to date while it is still short.
    func testFinalizedPeriodWithFutureEndStaysUnsettledUntilItsDaysElapse() {
        XCTAssertTrue(upToDate(written: 4, end: day(9), today: day(3)),
                      "4 of the 4 elapsed days are written — nothing to do right now")
        XCTAssertFalse(upToDate(written: 4, end: day(9), today: day(4)),
                       "a fifth day has elapsed and must still be added")
        XCTAssertTrue(upToDate(written: 10, end: day(9), today: day(30)))
    }

    // MARK: The "nothing new" gate — a flush with nothing to say writes NOTHING

    private func upToDate(written: Int, end: Date?, today: Date) -> Bool {
        CyclePredictor.periodMirrorIsUpToDate(writtenSampleCount: written, start: start,
                                              end: end, today: today, calendar: cal)
    }

    /// The churn defect. Same day, same content, already written → the flush must skip. Before the
    /// fix this returned the entry on every foreground activation, sync completion, BLE wake-drain
    /// and BGTask, each one deleting and rewriting the whole span.
    func testAlreadyMirroredEntryReportsUpToDate() {
        XCTAssertTrue(upToDate(written: 3, end: nil, today: day(2)))
        XCTAssertTrue(upToDate(written: 5, end: day(4), today: day(9)))
    }

    /// ...and stays skipped indefinitely once the open period is capped, which is what stops the
    /// per-flush churn from simply resuming after day 8.
    func testCappedOpenPeriodStaysUpToDateForever() {
        let capped = CyclePredictor.maxAutoExtendPeriodDays
        for elapsed in [7, 8, 30, 365] {
            XCTAssertTrue(upToDate(written: capped, end: nil, today: day(elapsed)),
                          "a capped open period must never re-drive a write (day \(elapsed))")
        }
    }

    /// The gate must still let a genuinely new day through, or the fix would freeze the mirror.
    func testNewDayOnAnOpenPeriodIsNotUpToDate() {
        XCTAssertFalse(upToDate(written: 3, end: nil, today: day(3)))
        XCTAssertFalse(upToDate(written: 1, end: nil, today: day(7)))
    }

    /// A never-written entry is never "up to date", even though 0 == 0 would say so numerically.
    func testUnwrittenEntryIsNeverUpToDate() {
        XCTAssertFalse(upToDate(written: 0, end: nil, today: day(0)))
        XCTAssertFalse(upToDate(written: 0, end: day(4), today: day(9)))
    }

    /// A mid-flush crash leaves stale + fresh tracked together (2N for an N-day span). That count
    /// mismatch is what re-drives the entry and cleans the duplicate up, so it must NOT read as
    /// up to date.
    func testInterruptedFlushDuplicateStateIsNotUpToDate() {
        XCTAssertFalse(upToDate(written: 6, end: nil, today: day(2)),
                       "3 fresh + 3 stale must re-drive so the duplicate is removed")
    }

    /// The cap-reached signal that drives the UI copy.
    func testOpenPeriodCapReachedFlag() {
        XCTAssertFalse(CyclePredictor.openPeriodHasReachedAutoExtendCap(start: start,
                                                                        today: day(6), calendar: cal))
        XCTAssertTrue(CyclePredictor.openPeriodHasReachedAutoExtendCap(start: start,
                                                                       today: day(7), calendar: cal))
        XCTAssertTrue(CyclePredictor.openPeriodHasReachedAutoExtendCap(start: start,
                                                                       today: day(40), calendar: cal))
    }

    // MARK: Write-first / delete-after ordering

    /// A MODEL of `HealthKitWriter.flushMenstrualFlow`'s ordering, not a test of that method
    /// itself — it needs a live `HKHealthStore`, so the app target owns its behaviour. What is
    /// pinned here is the ORDERING INVARIANT the method was reshaped to satisfy, stepped through
    /// with a kill at every point:
    ///
    ///   every sample present in Health is always nameable by the row that wrote it,
    ///   and Health is never emptier than it started.
    ///
    /// The old delete-first order violates the second clause (the hazard documented on
    /// `flushHeadacheLog`). Recording the fresh UUIDs AFTER the save — which is what the headache
    /// path still does — violates the first: this test failed on exactly that ordering while it
    /// was being written, because a kill in the save→record gap strands real samples that no row
    /// names. `HKObject` assigns `uuid` at construction, so the fix is to record before saving.
    func testWriteFirstDeleteAfterLeavesNoUntrackedOrphan() {
        let stale = ["A", "B"]        // 2 days already in Health
        let fresh = ["C", "D", "E"]   // 3 days being written now

        // The production step order: record(stale+fresh) → save → delete(stale) → record(fresh).
        for killAfterStep in 0...4 {
            var inHealth = Set(stale)
            var tracked = Set(stale)

            if killAfterStep >= 1 { tracked = Set(stale + fresh) }            // record together
            if killAfterStep >= 2 { inHealth.formUnion(fresh) }               // save
            if killAfterStep >= 3 { inHealth.subtract(stale) }                // delete stale
            if killAfterStep >= 4 { tracked = Set(fresh) }                    // record fresh alone

            XCTAssertTrue(inHealth.isSubset(of: tracked),
                          "killed after step \(killAfterStep): \(inHealth.subtracting(tracked)) " +
                          "is in Health but named by nothing — the user could never delete it")
            XCTAssertGreaterThanOrEqual(inHealth.count, min(stale.count, fresh.count),
                                        "killed after step \(killAfterStep): Health went emptier")
            XCTAssertFalse(inHealth.isEmpty, "killed after step \(killAfterStep): Health emptied")
        }
    }

    /// Recording the fresh UUIDs BEFORE the save is what makes every written sample nameable, but
    /// it hands the failure path a leak: a save that throws (an ungranted Cycle Tracking
    /// authorization throws on every flush) leaves UUIDs tracked for samples that never existed,
    /// and the next attempt appends another generation on top. Unrolled back, the tracked array
    /// grows by a full span per flush forever — the same unbounded churn this branch is removing,
    /// just moved into the local store. The rollback bounds it at one generation.
    func testFailedSaveRollsTrackingBackInsteadOfGrowingUnbounded() {
        let stale = ["A", "B", "C"]
        var tracked = Set(stale)

        // Ten consecutive failed flushes, each recording ahead of a save that then throws.
        for _ in 0 ..< 10 {
            let fresh = (0 ..< 3).map { _ in UUID().uuidString }
            tracked = Set(Array(tracked) + fresh)   // record before save
            // save throws → roll back to the pre-attempt set
            tracked = Set(stale)
        }
        XCTAssertEqual(tracked, Set(stale), "a failing save must not accumulate tracked UUIDs")

        // Without the rollback the same ten flushes would track 33 UUIDs for 3 real samples.
        var unrolled = Set(stale)
        for _ in 0 ..< 10 {
            unrolled = Set(Array(unrolled) + (0 ..< 3).map { _ in UUID().uuidString })
        }
        XCTAssertEqual(unrolled.count, 33, "the leak this rollback closes is real, not theoretical")
    }

    /// The same walk over the OLD delete-first order, kept as the counter-example: it is here to
    /// prove the invariant above actually discriminates, rather than being true of any ordering.
    func testDeleteFirstOrderingWouldEmptyHealthMidFlush() {
        let stale = ["A", "B"]
        let fresh = ["C", "D", "E"]
        var inHealth = Set(stale)

        inHealth.subtract(stale)   // delete first — the window the reshape removes
        XCTAssertTrue(inHealth.isEmpty,
                      "delete-first genuinely empties Health before the replacement exists")
        inHealth.formUnion(fresh)
        XCTAssertEqual(inHealth, Set(fresh))
    }

    // MARK: The anti-retraction floor — the cap may STOP the app, never UNDO it

    /// ⚠️ THE BLOCKER THIS FLOOR EXISTS FOR, caught in adversarial review before it shipped.
    ///
    /// The cap was retroactive on the UPGRADE path. A period left open before this change arrives
    /// with `healthWritten == false` and N tracked UUIDs naming N real menstrual-flow samples in
    /// Apple Health (one per elapsed day, N ≫ 8, because the pre-fix mirror extended to today
    /// forever). The first flush after upgrade rebuilt only the capped 8, and the
    /// delete-the-stale step then removed all N — a net loss of N − 8 days from the wearer's
    /// medical record, irreversibly, with no action from her.
    ///
    /// Stopping the app from ADDING days it was never told about is the fix. Taking back days it
    /// already wrote is a different act entirely, and not one this app may perform.
    func testTheCapNeverRetractsADayAlreadyInHealth() {
        // 20 days elapsed, 20 already mirrored: every one survives.
        XCTAssertEqual(CyclePredictor.periodMirrorDayCount(start: start, end: nil, today: day(19),
                                                           alreadyCoveredDays: 20, calendar: cal), 20)
        // …and it still does not GROW past what is covered — day 21 is not added.
        XCTAssertEqual(CyclePredictor.periodMirrorDayCount(start: start, end: nil, today: day(25),
                                                           alreadyCoveredDays: 20, calendar: cal), 20)
        // A never-written period is capped normally: the floor is inert at 0.
        XCTAssertEqual(CyclePredictor.periodMirrorDayCount(start: start, end: nil, today: day(19),
                                                           alreadyCoveredDays: 0, calendar: cal),
                       CyclePredictor.maxAutoExtendPeriodDays)
    }

    /// The floor must never push the mirror into the FUTURE, which is the one thing neither the cap
    /// nor the floor may do. A stale/oversized tracking array is clamped to today.
    func testTheFloorNeverAssertsADayThatHasNotHappened() {
        XCTAssertEqual(CyclePredictor.periodMirrorDayCount(start: start, end: nil, today: day(2),
                                                           alreadyCoveredDays: 20, calendar: cal), 3)
    }

    /// The up-to-date gate must agree with the floor, or a legacy over-cap period would be judged
    /// "stale" on every flush and rewritten forever — the churn defect, resurrected by the fix.
    func testALegacyOverCapPeriodIsReportedUpToDateOnceWritten() {
        XCTAssertTrue(CyclePredictor.periodMirrorIsUpToDate(writtenSampleCount: 20, start: start,
                                                            end: nil, today: day(25), calendar: cal))
    }
}
