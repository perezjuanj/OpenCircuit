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

    // MARK: - record (robust history accumulation, #86)

    func testRecordAppendsDischargeStep() {
        let h = [sample(80, hours: 0)]
        let out = BatteryTTE.record(h, percent: 79, at: t0.addingTimeInterval(3_600), charging: false)
        XCTAssertEqual(out.map(\.percent), [80, 79])
    }

    func testRecordIgnoresEqualAndSmallNoiseRise() {
        var h = [sample(80, hours: 0), sample(79, hours: 1)]
        // equal reading → ignored (keeps first-seen time)
        h = BatteryTTE.record(h, percent: 79, at: t0.addingTimeInterval(2 * 3_600), charging: false)
        XCTAssertEqual(h.map(\.percent), [80, 79])
        // +1 pp jitter while NOT charging → ignored, slope preserved
        h = BatteryTTE.record(h, percent: 80, at: t0.addingTimeInterval(3 * 3_600), charging: false)
        XCTAssertEqual(h.map(\.percent), [80, 79])
        // discharge continues cleanly afterwards
        h = BatteryTTE.record(h, percent: 78, at: t0.addingTimeInterval(4 * 3_600), charging: false)
        XCTAssertEqual(h.map(\.percent), [80, 79, 78])
    }

    func testRecordResetsBaselineWhenCharging() {
        let h = [sample(80, hours: 0), sample(70, hours: 5)]
        let out = BatteryTTE.record(h, percent: 71, at: t0.addingTimeInterval(6 * 3_600), charging: true)
        XCTAssertEqual(out.map(\.percent), [71], "a charging frame invalidates the discharge slope")
    }

    func testRecordResetsOnMissedChargeJump() {
        let h = [sample(60, hours: 0), sample(55, hours: 5)]
        // +20 pp while the byte says not-charging → a charge we missed between frames → reset
        let out = BatteryTTE.record(h, percent: 75, at: t0.addingTimeInterval(6 * 3_600), charging: false)
        XCTAssertEqual(out.map(\.percent), [75])
    }

    func testRecordPersistsAcrossReconnectIntoUsableEstimate() {
        // Simulate readings folded over hours, then confirm a clean TTE comes out — the
        // "survives reconnect" guarantee is that the array itself is the persisted state.
        var h: [BatteryTTE.Sample] = []
        h = BatteryTTE.record(h, percent: 90, at: t0, charging: false)
        h = BatteryTTE.record(h, percent: 88, at: t0.addingTimeInterval(2 * 3_600), charging: false)
        let tte = BatteryTTE.timeToEmpty(h, now: t0.addingTimeInterval(2 * 3_600))
        XCTAssertNotNil(tte, "2 pp over 2 h → 1 %/hr → ~88 h left")
        XCTAssertEqual(tte!, 88.0 * 3_600, accuracy: 60)
    }

    func testRecordPrunesByCap() {
        var h: [BatteryTTE.Sample] = []
        for i in 0..<80 { h = BatteryTTE.record(h, percent: 100 - i, at: t0.addingTimeInterval(Double(i) * 60), charging: false, cap: 60) }
        XCTAssertEqual(h.count, 60)
        XCTAssertEqual(h.last?.percent, 21)   // most-recent retained
    }

    func testRecordPrunesByAge() {
        let old = [BatteryTTE.Sample(percent: 90, at: t0)]
        // a reading 15 days later → the 14-day-old sample is pruned
        let out = BatteryTTE.record(old, percent: 89, at: t0.addingTimeInterval(15 * 86_400), charging: false)
        XCTAssertEqual(out.map(\.percent), [89])
    }

    func testSampleCodableRoundTrip() throws {
        let h = [sample(80, hours: 0), sample(78, hours: 3)]
        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode([BatteryTTE.Sample].self, from: data)
        XCTAssertEqual(back, h)
    }

    // MARK: - timeToFull + recordCharge (time-to-full, #61)

    func testTimeToFullCleanCharge() {
        // 66→74 % over 6 min = 80 %/hr; 26 % left → 26/80 h = 0.325 h = 1170 s
        let s = [BatteryTTE.Sample(percent: 66, at: t0),
                 BatteryTTE.Sample(percent: 74, at: t0.addingTimeInterval(6 * 60))]
        let ttf = BatteryTTE.timeToFull(s, now: t0.addingTimeInterval(6 * 60))
        XCTAssertNotNil(ttf)
        XCTAssertEqual(ttf!, 1170, accuracy: 5)
    }

    func testTimeToFullZeroWhenAlreadyFull() {
        let s = [sample(98, hours: 0), sample(100, hours: 0.5)]
        XCTAssertEqual(BatteryTTE.timeToFull(s), 0)
    }

    func testTimeToFullNilOnFalling() {
        XCTAssertNil(BatteryTTE.timeToFull([sample(80, hours: 0), sample(78, hours: 1)]))
    }

    func testTimeToFullResetsWindowOnUnplug() {
        // rise, then a fall (unplug), then rise again → only the trailing rising run counts
        let s = [sample(50, hours: 0), sample(60, hours: 0.2),
                 sample(55, hours: 0.3),                       // unplug dip
                 sample(57, hours: 0.4), sample(65, hours: 0.5)]
        let ttf = BatteryTTE.timeToFull(s, now: t0.addingTimeInterval(0.5 * 3_600))
        XCTAssertNotNil(ttf)   // measured over 57→65 only
    }

    func testRecordChargeAccumulatesWhileChargingAndClearsWhenNot() {
        var h: [BatteryTTE.Sample] = []
        h = BatteryTTE.recordCharge(h, percent: 66, at: t0, charging: true)
        h = BatteryTTE.recordCharge(h, percent: 68, at: t0.addingTimeInterval(60), charging: true)
        h = BatteryTTE.recordCharge(h, percent: 70, at: t0.addingTimeInterval(120), charging: true)
        XCTAssertEqual(h.map(\.percent), [66, 68, 70])
        // Unplugged → charge history clears so a stale slope can't linger.
        h = BatteryTTE.recordCharge(h, percent: 70, at: t0.addingTimeInterval(180), charging: false)
        XCTAssertTrue(h.isEmpty)
    }

    func testRecordChargeIgnoresTinyDropResetsOnBigDrop() {
        var h = [BatteryTTE.Sample(percent: 80, at: t0)]
        h = BatteryTTE.recordCharge(h, percent: 79, at: t0.addingTimeInterval(30), charging: true) // tiny dip → ignore
        XCTAssertEqual(h.map(\.percent), [80])
        h = BatteryTTE.recordCharge(h, percent: 76, at: t0.addingTimeInterval(60), charging: true) // ≥3 drop → reset
        XCTAssertEqual(h.map(\.percent), [76])
    }
}
