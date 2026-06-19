import XCTest
@testable import OpenCircuitKit

final class TrendsEngineTests: XCTestCase {

    private static let cal = Calendar(identifier: .gregorian)
    private static let epoch = Date(timeIntervalSince1970: 0)

    private func day(_ offset: Int) -> Date {
        Self.cal.date(byAdding: .day, value: offset, to: Self.epoch)!
    }

    // MARK: Rolling averages — basic

    func testRollingAveragesSteps() {
        let points = (0..<7).map { i in
            TrendsEngine.DailyPoint(date: day(i), steps: (i + 1) * 1000)
        }
        let avgs = TrendsEngine.rollingAverages(points, window: 7)
        // steps: 1000+2000+...+7000 = 28000 / 7 = 4000
        XCTAssertEqual(avgs.steps ?? 0, 4000, accuracy: 0.01)
    }

    func testRollingAveragesSleepScore() {
        let scores = [80, 85, 90, 75, 0, 88, 82]  // 0 = not computed → excluded
        let points = scores.enumerated().map { (i, s) in
            TrendsEngine.DailyPoint(date: day(i), sleepScore: s)
        }
        let avgs = TrendsEngine.rollingAverages(points, window: 7)
        // Excluding 0: (80+85+90+75+88+82)/6 = 500/6 ≈ 83.33
        XCTAssertEqual(avgs.sleepScore ?? 0, 500.0 / 6.0, accuracy: 0.01)
    }

    func testRollingAveragesHRGuard() {
        // Values ≤ 29 bpm are excluded (the APK SQL guard)
        let hrs: [Double?] = [0, 29, 65, 72, nil, 68, 70]
        let points = hrs.enumerated().map { (i, hr) in
            TrendsEngine.DailyPoint(date: day(i), sleepHRAvg: hr)
        }
        let avgs = TrendsEngine.rollingAverages(points, window: 7)
        // Valid: 65, 72, 68, 70 → mean = 275/4 = 68.75
        XCTAssertEqual(avgs.sleepHRAvg ?? 0, 68.75, accuracy: 0.01)
    }

    func testRollingAveragesAllNilReturnsNil() {
        let points = (0..<7).map { i in TrendsEngine.DailyPoint(date: day(i)) }
        let avgs = TrendsEngine.rollingAverages(points, window: 7)
        XCTAssertNil(avgs.steps)
        XCTAssertNil(avgs.sleepHRAvg)
    }

    func testRollingWindowLimitedByAvailablePoints() {
        // Only 3 points available for a 7-day window → averages just those 3
        let points = [1000, 2000, 3000].enumerated().map { (i, s) in
            TrendsEngine.DailyPoint(date: day(i), steps: s)
        }
        let avgs = TrendsEngine.rollingAverages(points, window: 7)
        XCTAssertEqual(avgs.steps ?? 0, 2000, accuracy: 0.01)
    }

    // MARK: Trend direction

    func testTrendUp() {
        // Recent 7 days much higher than prior 7 days
        var points = (0..<7).map { i in TrendsEngine.DailyPoint(date: day(i), steps: 3000) }
        points += (7..<14).map { i in TrendsEngine.DailyPoint(date: day(i), steps: 7000) }
        let t = TrendsEngine.trend(for: points, window: 7) { $0.steps.map(Double.init) }
        XCTAssertEqual(t, .up)
    }

    func testTrendDown() {
        var points = (0..<7).map { i in TrendsEngine.DailyPoint(date: day(i), steps: 8000) }
        points += (7..<14).map { i in TrendsEngine.DailyPoint(date: day(i), steps: 3000) }
        let t = TrendsEngine.trend(for: points, window: 7) { $0.steps.map(Double.init) }
        XCTAssertEqual(t, .down)
    }

    func testTrendFlat() {
        // 14 days all equal → flat
        let points = (0..<14).map { i in TrendsEngine.DailyPoint(date: day(i), steps: 8000) }
        let t = TrendsEngine.trend(for: points, window: 7) { $0.steps.map(Double.init) }
        XCTAssertEqual(t, .flat)
    }

    func testTrendNilWithInsufficientData() {
        let points = [TrendsEngine.DailyPoint(date: day(0), steps: 5000)]
        let t = TrendsEngine.trend(for: points, window: 7) { $0.steps.map(Double.init) }
        XCTAssertNil(t)
    }

    // MARK: Sleep regularity

    func testSleepRegularityPerfect() {
        // Same bedtime every night → 0 variance → score = 100
        let same = Array(repeating: 22 * 60, count: 7) // 22:00 every night
        XCTAssertEqual(TrendsEngine.sleepRegularity(bedtimeMinutes: same), 100)
    }

    func testSleepRegularityHighVariance() {
        // Very different bedtimes → low score
        let varied = [22 * 60, 0 * 60, 23 * 60, 1 * 60, 22 * 60, 2 * 60, 23 * 60]
        let score = TrendsEngine.sleepRegularity(bedtimeMinutes: varied) ?? 100
        XCTAssertLessThan(score, 60)
    }

    func testSleepRegularityInsufficientData() {
        XCTAssertNil(TrendsEngine.sleepRegularity(bedtimeMinutes: [22 * 60]))
    }

    func testSleepRegularityTightClusterAroundMidnight() {
        // A very consistent near-midnight sleeper: [23:58, 00:02, 23:55, 00:05, 00:00, 23:57, 00:03]
        // → true spread ~10 min. Linear variance would treat these as ~1440 min apart and score 0;
        // circular statistics must score this near-perfect (≥ 90).
        let minutes = [1438, 2, 1435, 5, 0, 1437, 3]
        let score = TrendsEngine.sleepRegularity(bedtimeMinutes: minutes) ?? 0
        XCTAssertGreaterThanOrEqual(score, 90, "tight midnight-wrap cluster should be highly regular")
    }

    func testSleepRegularityWrapEquivalentToShifted() {
        // Same spread, once straddling midnight and once shifted to noon → identical score
        // (rotation-invariance is the whole point of circular statistics).
        let aroundMidnight = [1438, 2, 1435, 5, 0, 1437, 3]
        let aroundNoon = aroundMidnight.map { ($0 + 720) % 1440 }
        XCTAssertEqual(TrendsEngine.sleepRegularity(bedtimeMinutes: aroundMidnight),
                       TrendsEngine.sleepRegularity(bedtimeMinutes: aroundNoon))
    }
}
