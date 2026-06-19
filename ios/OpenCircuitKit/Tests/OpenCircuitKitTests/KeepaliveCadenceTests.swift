import XCTest
@testable import OpenCircuitKit

// Adaptive keepalive cadence (#31): slow by day, tighter at night / during a live read,
// and stretched further in battery-saver. Asserts the ordering so a regression that, say,
// reverts to a 30 s day poll is caught.
final class KeepaliveCadenceTests: XCTestCase {

    func testDaytimeIsSlow() {
        XCTAssertEqual(KeepaliveCadence.interval(isNight: false, activeMeasurement: false, batterySaver: false), 180)
    }

    func testNightTightens() {
        XCTAssertEqual(KeepaliveCadence.interval(isNight: true, activeMeasurement: false, batterySaver: false), 60)
    }

    func testBatterySaverStretchesIdleCadences() {
        XCTAssertEqual(KeepaliveCadence.interval(isNight: false, activeMeasurement: false, batterySaver: true), 300)
        XCTAssertEqual(KeepaliveCadence.interval(isNight: true, activeMeasurement: false, batterySaver: true), 90)
    }

    func testActiveMeasurementOverridesEverything() {
        // A live read suppresses the heartbeat but wants fast re-checks regardless of night/saver.
        for night in [true, false] {
            for saver in [true, false] {
                XCTAssertEqual(KeepaliveCadence.interval(isNight: night, activeMeasurement: true, batterySaver: saver), 30)
            }
        }
    }

    func testNightIsAlwaysTighterThanDay() {
        let day = KeepaliveCadence.interval(isNight: false, activeMeasurement: false, batterySaver: false)
        let night = KeepaliveCadence.interval(isNight: true, activeMeasurement: false, batterySaver: false)
        XCTAssertLessThan(night, day)
    }
}
