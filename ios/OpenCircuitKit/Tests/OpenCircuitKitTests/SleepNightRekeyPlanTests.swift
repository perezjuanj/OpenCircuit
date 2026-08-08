import XCTest
@testable import OpenCircuitKit

/// Tests for the DECISION half of the one-shot night-key migration. These exist because the
/// migration rewrites a uniquely-indexed primary key on the user's only copy of their sleep
/// history, behind a one-way latch — and the original version of it shipped a defect (year-0
/// relocation of legacy rows) that 1231 passing tests did not catch, because nothing exercised
/// this path.
final class SleepNightRekeyPlanTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func day(_ y: Int, _ mo: Int, _ d: Int) -> Date { at(y, mo, d, 0, 0) }

    /// A row keyed the OLD way (start-of-day of bedtime), which is what a pre-migration store holds.
    private func legacyRow(bed: Date, wake: Date) -> SleepNightRekeyPlan.Row {
        SleepNightRekeyPlan.Row(night: cal.startOfDay(for: bed), inBedStart: bed, inBedEnd: wake)
    }

    // MARK: the degenerate-row BLOCKER

    /// 🔒 `inBedStart`/`inBedEnd` are DEFAULTED to `.distantPast` for rows written before those
    /// columns existed. Judging such a row sends it to `startOfDay(.distantPast)` — year 0 — where
    /// it falls outside every date-ranged query, permanently and un-reversibly. It must not move.
    func testLegacyRowWithNoInBedTimesIsNeverMoved() {
        let rows = [SleepNightRekeyPlan.Row(night: day(2026, 3, 1),
                                            inBedStart: .distantPast, inBedEnd: .distantPast)]
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertTrue(plan.moves.isEmpty, "a row with no in-bed window must keep the key it has")
        XCTAssertTrue(plan.refused.isEmpty, "and must not be reported as a collision either")
    }

    /// Several legacy rows must ALL stay put — the original defect moved the first one to year 0 and
    /// then reported every subsequent one as "destination occupied".
    func testManyLegacyRowsAllStayPut() {
        let rows = (1...4).map {
            SleepNightRekeyPlan.Row(night: day(2026, 3, $0), inBedStart: .distantPast, inBedEnd: .distantPast)
        }
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertTrue(plan.refused.isEmpty)
    }

    func testInvertedWindowIsNeverMoved() {
        let rows = [SleepNightRekeyPlan.Row(night: day(2026, 8, 7),
                                            inBedStart: at(2026, 8, 7, 23, 56),
                                            inBedEnd: at(2026, 8, 7, 20, 0))]
        XCTAssertTrue(SleepNightRekeyPlan.plan(rows: rows, calendar: cal).moves.isEmpty)
    }

    // MARK: ordering

    /// 🔒 THE ORDERING CLAIM. Every move is +1 day, so a run of consecutive pre-midnight-bedtime
    /// nights forms a chain where each row wants the slot of the row above it. Newest-first frees
    /// each destination in time; oldest-first would refuse all but the last.
    func testChainOfConsecutiveNightsAllMove() {
        let rows = [
            legacyRow(bed: at(2026, 8, 4, 22, 26), wake: at(2026, 8, 5, 8, 59)),   // 08-04 -> 08-05
            legacyRow(bed: at(2026, 8, 5, 23, 39), wake: at(2026, 8, 6, 9, 13)),   // 08-05 -> 08-06
            legacyRow(bed: at(2026, 8, 6, 22, 10), wake: at(2026, 8, 7, 7, 5)),    // 08-06 -> 08-07
        ]
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertTrue(plan.refused.isEmpty, "a consecutive chain must not report false collisions")
        XCTAssertEqual(plan.moves, [
            SleepNightRekeyPlan.Move(from: day(2026, 8, 6), to: day(2026, 8, 7)),
            SleepNightRekeyPlan.Move(from: day(2026, 8, 5), to: day(2026, 8, 6)),
            SleepNightRekeyPlan.Move(from: day(2026, 8, 4), to: day(2026, 8, 5)),
        ], "moves must be emitted newest-first so each destination is free when applied")
    }

    /// Input order must not matter — the plan sorts internally.
    func testPlanIsIndependentOfInputOrder() {
        let a = legacyRow(bed: at(2026, 8, 4, 22, 26), wake: at(2026, 8, 5, 8, 59))
        let b = legacyRow(bed: at(2026, 8, 5, 23, 39), wake: at(2026, 8, 6, 9, 13))
        XCTAssertEqual(SleepNightRekeyPlan.plan(rows: [a, b], calendar: cal),
                       SleepNightRekeyPlan.plan(rows: [b, a], calendar: cal))
    }

    // MARK: refusal

    /// Two sleeps ending on the SAME calendar day (biphasic sleep). The one that would have to move
    /// is refused, not forced — `night` is uniquely indexed, and a stale key beats a deleted night.
    func testCollisionWithANonMovingRowIsRefusedNotForced() {
        let rows = [
            // ends 08-08 02:00, keyed 08-07 the old way -> wants 08-08
            legacyRow(bed: at(2026, 8, 7, 22, 0), wake: at(2026, 8, 8, 2, 0)),
            // bed 03:00 wake 08:00 both on 08-08 -> already correct, does not move, holds 08-08
            legacyRow(bed: at(2026, 8, 8, 3, 0), wake: at(2026, 8, 8, 8, 0)),
        ]
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.refused, [SleepNightRekeyPlan.Move(from: day(2026, 8, 7), to: day(2026, 8, 8))])
    }

    // MARK: idempotence

    /// 🔒 The caller latches a done-flag, but a failed save retries next launch — so a second pass
    /// over ALREADY-MIGRATED rows must plan nothing.
    func testSecondPassOverMigratedRowsPlansNothing() {
        let rows = [
            SleepNightRekeyPlan.Row(night: day(2026, 8, 5),
                                    inBedStart: at(2026, 8, 4, 22, 26), inBedEnd: at(2026, 8, 5, 8, 59)),
            SleepNightRekeyPlan.Row(night: day(2026, 8, 6),
                                    inBedStart: at(2026, 8, 5, 23, 39), inBedEnd: at(2026, 8, 6, 9, 13)),
        ]
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertTrue(plan.refused.isEmpty)
    }

    /// A PARTIALLY applied migration (save threw after some rows were mutated) must complete on the
    /// retry, not deadlock on the rows that already moved.
    func testPartiallyMigratedStoreCompletesOnRetry() {
        let rows = [
            SleepNightRekeyPlan.Row(night: day(2026, 8, 7),          // already moved
                                    inBedStart: at(2026, 8, 6, 22, 10), inBedEnd: at(2026, 8, 7, 7, 5)),
            legacyRow(bed: at(2026, 8, 5, 23, 39), wake: at(2026, 8, 6, 9, 13)),   // still 08-05
        ]
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertEqual(plan.moves, [SleepNightRekeyPlan.Move(from: day(2026, 8, 5), to: day(2026, 8, 6))])
        XCTAssertTrue(plan.refused.isEmpty)
    }

    // MARK: mixed / no-op

    func testRowsAlreadyCorrectAreLeftAlone() {
        let rows = [legacyRow(bed: at(2026, 8, 3, 1, 34), wake: at(2026, 8, 3, 8, 50))]
        XCTAssertTrue(SleepNightRekeyPlan.plan(rows: rows, calendar: cal).moves.isEmpty)
    }

    func testEmptyStorePlansNothing() {
        let plan = SleepNightRekeyPlan.plan(rows: [], calendar: cal)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertTrue(plan.refused.isEmpty)
    }

    /// DST: the device zone observes it. A night spanning the spring-forward transition still moves
    /// exactly one calendar day, because `startOfDay` is calendar arithmetic, not ±86400.
    func testSpringForwardNightStillMovesOneCalendarDay() {
        // US spring-forward 2026: 2026-03-08. Bed 23:00 on 03-07, wake 07:00 on 03-08 (23 h day).
        let rows = [legacyRow(bed: at(2026, 3, 7, 23, 0), wake: at(2026, 3, 8, 7, 0))]
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertEqual(plan.moves, [SleepNightRekeyPlan.Move(from: day(2026, 3, 7), to: day(2026, 3, 8))])
    }

    /// Fall-back (25 h day) likewise.
    func testFallBackNightStillMovesOneCalendarDay() {
        // US fall-back 2026: 2026-11-01.
        let rows = [legacyRow(bed: at(2026, 10, 31, 23, 0), wake: at(2026, 11, 1, 7, 0))]
        let plan = SleepNightRekeyPlan.plan(rows: rows, calendar: cal)
        XCTAssertEqual(plan.moves, [SleepNightRekeyPlan.Move(from: day(2026, 10, 31), to: day(2026, 11, 1))])
    }
}
