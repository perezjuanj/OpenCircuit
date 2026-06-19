import XCTest
@testable import OpenCircuitKit

final class CumulativeMetricAccumulatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)

    func testNormalDeltaAccumulationProducesRunningTotal() {
        let first = CumulativeMetricAccumulator.accumulate(
            QuantitySample(kind: .steps, start: t0, value: 100),
            state: CumulativeMetricState()
        )
        let second = CumulativeMetricAccumulator.accumulate(
            QuantitySample(kind: .steps, start: t1, value: 140),
            state: CumulativeMetricState(previousRawValue: first.rawValue, dailyTotal: first.dailyTotal)
        )

        XCTAssertEqual(first.deltaValue, 100)
        XCTAssertEqual(first.dailyTotal, 100)
        XCTAssertEqual(second.deltaValue, 40)
        XCTAssertEqual(second.dailyTotal, 140)
        XCTAssertEqual(second.sample.value, 140)
    }

    func testCounterRolloverTreatsRawValueAsDelta() {
        let result = CumulativeMetricAccumulator.accumulate(
            QuantitySample(kind: .steps, start: t1, value: 12),
            state: CumulativeMetricState(previousRawValue: 250, dailyTotal: 250)
        )

        XCTAssertEqual(result.deltaValue, 12)
        XCTAssertEqual(result.dailyTotal, 262)
        XCTAssertEqual(result.sample.value, 262)
    }

    func testMultiSessionAccumulationContinuesFromPersistedState() {
        let sessionOne = CumulativeMetricAccumulator.accumulate(
            QuantitySample(kind: .steps, start: t0, value: 75),
            state: CumulativeMetricState()
        )
        let persistedState = CumulativeMetricState(
            previousRawValue: sessionOne.rawValue,
            dailyTotal: sessionOne.dailyTotal
        )
        let sessionTwoFirst = CumulativeMetricAccumulator.accumulate(
            QuantitySample(kind: .steps, start: t1, value: 90),
            state: persistedState
        )
        let sessionTwoSecond = CumulativeMetricAccumulator.accumulate(
            QuantitySample(kind: .steps, start: t2, value: 125),
            state: CumulativeMetricState(
                previousRawValue: sessionTwoFirst.rawValue,
                dailyTotal: sessionTwoFirst.dailyTotal
            )
        )

        XCTAssertEqual(sessionTwoFirst.deltaValue, 15)
        XCTAssertEqual(sessionTwoFirst.dailyTotal, 90)
        XCTAssertEqual(sessionTwoSecond.deltaValue, 35)
        XCTAssertEqual(sessionTwoSecond.dailyTotal, 125)
    }
}
