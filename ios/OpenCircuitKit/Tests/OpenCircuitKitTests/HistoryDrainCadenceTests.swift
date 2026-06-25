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
}
