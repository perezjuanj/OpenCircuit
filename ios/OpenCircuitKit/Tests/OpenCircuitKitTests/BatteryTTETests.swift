import XCTest
@testable import OpenCircuitKit

final class BatteryTTETests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    private func sample(_ pct: Int, hours: Double) -> BatteryTTE.Sample {
        BatteryTTE.Sample(percent: pct, at: t0.addingTimeInterval(hours * 3_600))
    }

    // MARK: - timeToEmpty

    func testCleanDischarge() {
        // 10 % drop in 1 hour starting at 100 % → rate = 10 %/hr → TTE = 90% / 10%/hr = 9 h
        let samples = [sample(100, hours: 0), sample(90, hours: 1)]
        let tte = BatteryTTE.timeToEmpty(samples, now: t0.addingTimeInterval(1 * 3_600))
        XCTAssertNotNil(tte)
        // Expected: 90 % / 10 %/hr × 3600 = 32 400 s (9 h)
        XCTAssertEqual(tte!, 32_400, accuracy: 1)
    }

    func testNilOnRisingTrend() {
        // Strictly rising = charging → nil
        let samples = [sample(80, hours: 0), sample(85, hours: 1), sample(90, hours: 2)]
        XCTAssertNil(BatteryTTE.timeToEmpty(samples))
    }

    func testNilOnFewerThanTwoSamples() {
        XCTAssertNil(BatteryTTE.timeToEmpty([]))
        XCTAssertNil(BatteryTTE.timeToEmpty([sample(80, hours: 0)]))
    }

    func testNilOnImplausibleRate() {
        // 60 % drop in 1 hour → 60 %/hr > 50 %/hr threshold → nil
        let samples = [sample(80, hours: 0), sample(20, hours: 1)]
        XCTAssertNil(BatteryTTE.timeToEmpty(samples))
    }

    func testNilOnSmallDrop() {
        // 1 % drop — below the noise floor (< 2 pp)
        let samples = [sample(80, hours: 0), sample(79, hours: 1)]
        XCTAssertNil(BatteryTTE.timeToEmpty(samples))
    }

    func testRisingThenFallingResetsWindow() {
        // [70, 80, 75]: rises then falls. The window after the rise-reset is [80, 75].
        // Drop = 5 pp, elapsed = 1 h → rate = 5 %/hr → TTE = 75/5 × 3600 = 54 000 s
        let samples = [sample(70, hours: 0), sample(80, hours: 1), sample(75, hours: 2)]
        let tte = BatteryTTE.timeToEmpty(samples)
        XCTAssertNotNil(tte)
        XCTAssertEqual(tte!, 54_000, accuracy: 1)
    }

    func testFlatSamplesSkipped() {
        // [90, 90, 88]: flat then drop of 2 pp. The flat sample doesn't break the window,
        // but the effective discharging window is [90@t0, 88@t2].
        // Actually in the algorithm, flat is skipped so window = [90@t0, 88@t2]:
        // drop=2, elapsed=2h → rate=1%/hr → TTE = 88/1 × 3600 = 316 800 s
        let samples = [sample(90, hours: 0), sample(90, hours: 1), sample(88, hours: 2)]
        let tte = BatteryTTE.timeToEmpty(samples)
        XCTAssertNotNil(tte)
    }

    // MARK: - estimatedDepletionDate

    func testEstimatedDepletionDate() {
        let samples = [sample(100, hours: 0), sample(90, hours: 1)]
        let now = t0.addingTimeInterval(1 * 3_600)  // now = end of last sample
        let depletion = BatteryTTE.estimatedDepletionDate(samples, now: now)
        XCTAssertNotNil(depletion)
        // TTE = 9 h → depletion at now + 9 h
        XCTAssertEqual(depletion!.timeIntervalSince(now), 9 * 3_600, accuracy: 1)
    }

    func testEstimatedDepletionNilWhenNoTTE() {
        XCTAssertNil(BatteryTTE.estimatedDepletionDate([]))
    }

    // MARK: - justReachedFull

    func testJustReachedFullFires() {
        XCTAssertTrue(BatteryTTE.justReachedFull(percent: 100, inferredCharging: true, wasFull: false))
    }

    func testJustReachedFullDoesNotFireIfAlreadyFull() {
        XCTAssertFalse(BatteryTTE.justReachedFull(percent: 100, inferredCharging: true, wasFull: true))
    }

    func testJustReachedFullDoesNotFireIfNotCharging() {
        XCTAssertFalse(BatteryTTE.justReachedFull(percent: 100, inferredCharging: false, wasFull: false))
    }

    func testJustReachedFullDoesNotFireBelow100() {
        XCTAssertFalse(BatteryTTE.justReachedFull(percent: 99, inferredCharging: true, wasFull: false))
    }
}
