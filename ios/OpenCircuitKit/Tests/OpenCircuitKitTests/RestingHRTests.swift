import XCTest
@testable import OpenCircuitKit

// Resting-HR derivation (#18, #37). Pure value-type math; runs under `swift test`.
final class RestingHRTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // fixed anchor

    private func hr(_ bpm: Int, _ offset: TimeInterval) -> HRSample {
        HRSample(bpm: bpm, start: t0.addingTimeInterval(offset))
    }

    /// Assert an optional Double equals `expected` (the derivations return nil when there's
    /// no data, so unwrap before the accuracy comparison).
    private func assertEqual(_ value: Double?, _ expected: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let value else {
            XCTFail("expected \(expected), got nil", file: file, line: line); return
        }
        XCTAssertEqual(value, expected, accuracy: 0.001, file: file, line: line)
    }

    // MARK: Sleep mean (preferred tier)

    func testSleepMeanAveragesAsleepReadings() {
        let sleep = [SleepSegment(start: t0, end: t0.addingTimeInterval(600), stage: .asleepCore)]
        let samples = [hr(60, 0), hr(50, 100), hr(70, 200)]  // all inside the segment
        assertEqual(RestingHR.sleepMean(hr: samples, sleep: sleep, minSleepSamples: 3), 60)
    }

    func testSleepMeanExcludesAwakeAndOutOfWindow() {
        let sleep = [
            SleepSegment(start: t0, end: t0.addingTimeInterval(300), stage: .asleepDeep),
            SleepSegment(start: t0.addingTimeInterval(300), end: t0.addingTimeInterval(600), stage: .awake),
        ]
        // 3 asleep readings (mean 55) + a high awake reading + a reading after the window.
        let samples = [hr(50, 0), hr(55, 100), hr(60, 200), hr(120, 400), hr(120, 1000)]
        assertEqual(RestingHR.sleepMean(hr: samples, sleep: sleep, minSleepSamples: 3), 55)
    }

    func testSleepMeanNilWhenTooFewAsleepReadings() {
        let sleep = [SleepSegment(start: t0, end: t0.addingTimeInterval(600), stage: .asleepREM)]
        XCTAssertNil(RestingHR.sleepMean(hr: [hr(60, 0), hr(58, 100)], sleep: sleep, minSleepSamples: 3))
    }

    func testSleepMeanNilWhenNoAsleepSegments() {
        let sleep = [SleepSegment(start: t0, end: t0.addingTimeInterval(600), stage: .inBed)]
        XCTAssertNil(RestingHR.sleepMean(hr: [hr(60, 0), hr(58, 100), hr(59, 200)], sleep: sleep, minSleepSamples: 3))
    }

    // MARK: Lowest sustained (fallback tier)

    func testLowestSustainedFindsTheLowMinuteBlock() {
        // 5 high readings then 5 low readings, one per minute; the 5-min window over the low
        // block has the minimum mean (50).
        var samples: [HRSample] = []
        for i in 0..<5 { samples.append(hr(70, Double(i) * 60)) }
        for i in 5..<10 { samples.append(hr(50, Double(i) * 60)) }
        assertEqual(RestingHR.lowestSustained(hr: samples, window: 300), 50)
    }

    func testLowestSustainedSingleReadingFallsBackToThatReading() {
        assertEqual(RestingHR.lowestSustained(hr: [hr(55, 0)], window: 300), 55)
    }

    func testLowestSustainedAllIsolatedFallsBackToLowestSingle() {
        // Readings >5 min apart never co-occur in a window → fall back to the single lowest.
        let samples = [hr(60, 0), hr(50, 1000), hr(70, 2000)]
        assertEqual(RestingHR.lowestSustained(hr: samples, window: 300), 50)
    }

    func testLowestSustainedNilWhenEmpty() {
        XCTAssertNil(RestingHR.lowestSustained(hr: [], window: 300))
    }

    // MARK: Tier selection

    func testValuePrefersSleepMeanOverDaytimeLow() {
        let sleep = [SleepSegment(start: t0, end: t0.addingTimeInterval(300), stage: .asleepCore)]
        let asleep = [hr(55, 0), hr(55, 100), hr(55, 200)]          // sleep mean 55
        let daytime = [hr(45, 4000), hr(45, 4060), hr(45, 4120)]    // sustained low 45 (ignored)
        assertEqual(RestingHR.value(hr: asleep + daytime, sleep: sleep), 55)
    }

    func testValueFallsBackWhenNoSleep() {
        let daytime = [hr(45, 0), hr(45, 60), hr(45, 120)]
        assertEqual(RestingHR.value(hr: daytime), 45)
    }

    // MARK: Daily grouping

    func testDailyValuesGroupsByCalendarDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day1 = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let day2 = cal.date(byAdding: .day, value: 1, to: day1)!
        let samples = [
            HRSample(bpm: 60, start: day1.addingTimeInterval(3600)),
            HRSample(bpm: 50, start: day1.addingTimeInterval(3660)),
            HRSample(bpm: 70, start: day2.addingTimeInterval(3600)),
            HRSample(bpm: 72, start: day2.addingTimeInterval(3660)),
        ]
        let daily = RestingHR.dailyValues(hr: samples, calendar: cal)
        XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily[0].day, day1)
        XCTAssertEqual(daily[1].day, day2)
        XCTAssertEqual(daily[0].bpm, 55, accuracy: 0.001)   // (60+50)/2 sustained window
        XCTAssertEqual(daily[1].bpm, 71, accuracy: 0.001)   // (70+72)/2
    }

    func testDailyValuesEmptyForNoReadings() {
        XCTAssertEqual(RestingHR.dailyValues(hr: []), [])
    }

    // MARK: - lowestSustained O(m)→byte-identical regression (watchdog-hang fix)

    /// Inline copy of the ORIGINAL O(m²) algorithm — the reference the fast two-pointer version
    /// must reproduce bit-for-bit.
    private func referenceLowestSustained(_ hr: [HRSample], window: TimeInterval) -> Double? {
        guard !hr.isEmpty else { return nil }
        let sorted = hr.sorted { $0.start < $1.start }
        var best: Double?
        for i in sorted.indices {
            let cutoff = sorted[i].start.addingTimeInterval(window)
            var bucket: [HRSample] = []
            var j = i
            while j < sorted.count, sorted[j].start < cutoff { bucket.append(sorted[j]); j += 1 }
            guard bucket.count >= 2 || sorted.count == 1 else { continue }
            let m = bucket.reduce(0.0) { $0 + Double($1.bpm) } / Double(bucket.count)
            best = best.map { Swift.min($0, m) } ?? m
        }
        if best == nil { best = sorted.map { Double($0.bpm) }.min() }
        return best
    }

    private func assertIdentical(_ hr: [HRSample], _ file: StaticString = #filePath, _ line: UInt = #line) {
        let ref = referenceLowestSustained(hr, window: RestingHR.sustainedWindow)
        let got = RestingHR.lowestSustained(hr: hr, window: RestingHR.sustainedWindow)
        // Exact equality (bit-for-bit) — window sums are exact integers in Double, so no epsilon.
        XCTAssertEqual(got, ref, "fast lowestSustained diverged from the O(m²) reference", file: file, line: line)
    }

    func testLowestSustainedByteIdenticalAcrossShapes() {
        // Edge cases.
        assertIdentical([])
        assertIdentical([HRSample(bpm: 61, start: t0)])                                  // single reading
        assertIdentical([HRSample(bpm: 61, start: t0),                                    // isolated (>window apart)
                         HRSample(bpm: 70, start: t0.addingTimeInterval(3600))])
        assertIdentical([HRSample(bpm: 60, start: t0),                                    // exactly 2 in-window
                         HRSample(bpm: 50, start: t0.addingTimeInterval(60))])

        // Deterministic pseudo-random sets (seeded LCG) incl. a DENSE same-day cluster (the workout
        // worst case: hundreds of readings inside a few 5-min windows).
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
        for shape in 0..<8 {
            var samples: [HRSample] = []
            let count = [1, 2, 5, 50, 200, 600, 1000, 3][shape]
            // Dense shapes pack readings ~2 s apart (many per 5-min window); sparse ones ~2–8 min.
            let dense = shape >= 3 && shape != 7
            for k in 0..<count {
                let step = dense ? Double(next() % 4) : Double(120 + next() % 360)
                let t = t0.addingTimeInterval(Double(k) * (dense ? 2 : 1) + step)
                samples.append(HRSample(bpm: 40 + Int(next() % 130), start: t))   // 40…169 bpm
            }
            assertIdentical(samples)
        }
    }
}
