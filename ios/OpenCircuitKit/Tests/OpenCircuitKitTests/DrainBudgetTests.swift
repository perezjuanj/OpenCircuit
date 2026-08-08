import XCTest
@testable import OpenCircuitKit

final class DrainBudgetTests: XCTestCase {

    private let cap = 45
    private let ceiling = 180

    // MARK: the regression this type exists for

    /// 🔒 THE OFF-BY-ONE. A channel reaching the budget check has not taken the 3-quiet-tick exit, so
    /// quietTicks is 1 or 2. An earlier revision tested `quietTicks <= 1` and silently refused to
    /// extend the `2` case — about half of all bursts at the measured 2.26 s inter-page cadence.
    /// Both values mean "still streaming" and BOTH must extend.
    func testExtendsForEveryQuietTickValueBelowTheQuietExit() {
        for quietTicks in 1..<3 {
            XCTAssertTrue(
                DrainBudget.shouldExtend(tick: cap, cap: cap, ceiling: ceiling,
                                         sawPages: true, quietTicks: quietTicks),
                "quietTicks=\(quietTicks) is still a live stream and must extend")
        }
    }

    /// At or past the quiet-exit threshold the loop's own exit owns the decision — extending there
    /// would keep a dead channel alive.
    func testDoesNotExtendOnceTheQuietExitWouldFire() {
        for quietTicks in 3...6 {
            XCTAssertFalse(
                DrainBudget.shouldExtend(tick: cap, cap: cap, ceiling: ceiling,
                                         sawPages: true, quietTicks: quietTicks))
        }
    }

    // MARK: the other guards

    func testDoesNotExtendBeforeTheBudgetIsSpent() {
        XCTAssertFalse(DrainBudget.shouldExtend(tick: cap - 1, cap: cap, ceiling: ceiling,
                                                sawPages: true, quietTicks: 1))
    }

    func testDoesNotExtendAnIdleChannel() {
        XCTAssertFalse(DrainBudget.shouldExtend(tick: cap, cap: cap, ceiling: ceiling,
                                                sawPages: false, quietTicks: 1))
    }

    func testDoesNotExtendPastTheCeiling() {
        XCTAssertFalse(DrainBudget.shouldExtend(tick: ceiling, cap: ceiling, ceiling: ceiling,
                                                sawPages: true, quietTicks: 1))
    }

    func testCapIsClampedToTheCeiling() {
        XCTAssertEqual(DrainBudget.extendedCap(cap: 135, step: 45, ceiling: 180), 180)
        XCTAssertEqual(DrainBudget.extendedCap(cap: 170, step: 45, ceiling: 180), 180)
        XCTAssertEqual(DrainBudget.extendedCap(cap: 45, step: 45, ceiling: 180), 90)
    }

    /// The budget must be monotonically non-decreasing and must terminate: walking the real sequence
    /// a never-quiet ring produces, the cap reaches the ceiling and then stops extending.
    func testExtensionTerminatesAtTheCeiling() {
        var cap = self.cap
        var extensions = 0
        while DrainBudget.shouldExtend(tick: cap, cap: cap, ceiling: ceiling,
                                       sawPages: true, quietTicks: 1) {
            let next = DrainBudget.extendedCap(cap: cap, step: self.cap, ceiling: ceiling)
            XCTAssertGreaterThan(next, cap, "cap must strictly grow or the loop cannot terminate")
            cap = next
            extensions += 1
            XCTAssertLessThan(extensions, 10, "runaway extension")
        }
        XCTAssertEqual(cap, ceiling)
    }

    /// The whole point: a night that outruns the nominal budget still gets drained. The measured
    /// 2026-08-07 handoff was ~43 s of page flow; a 10 h night is ~88 s. Both must fit under the
    /// ceiling with the extension applied, and neither may fit in the un-extended cap.
    func testMeasuredAndLongNightHandoffsFitOnlyWithExtension() {
        let measuredHandoffTicks = 55      // 0x50 landed ~55 s after the open
        let tenHourNightTicks = 88         // ~240 records at the measured ~2.2 s/page x 6 records
        XCTAssertGreaterThan(tenHourNightTicks, cap, "premise: a long night outruns the nominal cap")
        for needed in [measuredHandoffTicks, tenHourNightTicks] {
            var cap = self.cap
            while cap < needed, DrainBudget.shouldExtend(tick: cap, cap: cap, ceiling: ceiling,
                                                         sawPages: true, quietTicks: 2) {
                cap = DrainBudget.extendedCap(cap: cap, step: self.cap, ceiling: ceiling)
            }
            XCTAssertGreaterThanOrEqual(cap, needed, "a \(needed)-tick handoff must not be cut")
        }
    }
}
