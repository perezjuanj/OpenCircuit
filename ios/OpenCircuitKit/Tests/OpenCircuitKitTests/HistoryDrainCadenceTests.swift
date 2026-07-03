import XCTest
@testable import OpenCircuitKit

final class HistoryDrainCadenceTests: XCTestCase {

    func testNightIsTighterThanDay() {
        XCTAssertLessThan(HistoryDrainCadence.interval(isNight: true, batterySaver: false),
                          HistoryDrainCadence.interval(isNight: false, batterySaver: false))
    }

    func testBatterySaverRelaxesBothButStaysUnderBuffer() {
        let bufferSeconds: TimeInterval = 4.75 * 3600   // ~114 epochs × 150 s
        for night in [true, false] {
            let saver = HistoryDrainCadence.interval(isNight: night, batterySaver: true)
            let normal = HistoryDrainCadence.interval(isNight: night, batterySaver: false)
            XCTAssertGreaterThan(saver, normal)
            // Even relaxed, a single interval must leave headroom under the ring buffer so one
            // missed drain can't already overflow it.
            XCTAssertLessThan(saver, bufferSeconds)
        }
    }

    func testDueWhenNeverDrained() {
        XCTAssertTrue(HistoryDrainCadence.isDue(lastDrainAt: nil, now: Date(),
                                                isNight: true, batterySaver: false))
    }

    func testNotDueBeforeIntervalElapses() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let last = now.addingTimeInterval(-20 * 60)   // 20 min ago
        // Night interval is 30 min, so 20 min ago is NOT yet due.
        XCTAssertFalse(HistoryDrainCadence.isDue(lastDrainAt: last, now: now,
                                                 isNight: true, batterySaver: false))
    }

    func testDueAfterIntervalElapses() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let last = now.addingTimeInterval(-40 * 60)   // 40 min ago > 30 min night interval
        XCTAssertTrue(HistoryDrainCadence.isDue(lastDrainAt: last, now: now,
                                                isNight: true, batterySaver: false))
    }

    func testBoundaryExactlyAtIntervalIsDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let last = now.addingTimeInterval(-HistoryDrainCadence.interval(isNight: false, batterySaver: false))
        XCTAssertTrue(HistoryDrainCadence.isDue(lastDrainAt: last, now: now,
                                                isNight: false, batterySaver: false))
    }

    // MARK: - Overnight-quiet gate (#111/#119)

    /// Inside the sleep window an AUTOMATIC drain is suppressed regardless of how overdue it is — the
    /// night must accumulate untouched on the ring and be pulled in one pass at wake (Randy 6/30:
    /// cadenced overnight drains made the ring stop handing off 0x4c history mid-night).
    func testOvernightSuppressesAutomaticDrainEvenWhenDue() {
        XCTAssertFalse(HistoryDrainCadence.shouldDrain(manual: false, inSleepWindow: true, isDue: true),
                       "an automatic drain inside the sleep window must be suppressed")
    }

    /// A user-initiated sync ALWAYS drains — even mid-window, even if the cadence isn't due.
    func testManualSyncAlwaysDrains() {
        XCTAssertTrue(HistoryDrainCadence.shouldDrain(manual: true, inSleepWindow: true, isDue: false),
                      "a manual sync bypasses the overnight-quiet gate")
        XCTAssertTrue(HistoryDrainCadence.shouldDrain(manual: true, inSleepWindow: false, isDue: false))
    }

    /// Outside the window the gate is transparent: `shouldDrain` mirrors `isDue` exactly, so daytime
    /// cadence is unchanged — and the WAKE catch-up works because at wake `isDue` is true (lastDrainAt
    /// is hours old) and `inSleepWindow` is false.
    func testDaytimeIsUnchangedAndWakeCatchUpDrains() {
        XCTAssertTrue(HistoryDrainCadence.shouldDrain(manual: false, inSleepWindow: false, isDue: true),
                      "daytime / wake catch-up: due + out-of-window → drain")
        XCTAssertFalse(HistoryDrainCadence.shouldDrain(manual: false, inSleepWindow: false, isDue: false),
                       "daytime not-due → no drain (mirrors isDue)")
    }
}
