import Foundation

public extension MetricKind {
    /// Metrics emitted by the ring as monotonic counters rather than per-epoch values.
    var isCumulativeCounter: Bool {
        switch self {
        case .steps, .activeEnergy:
            return true
        case .heartRate, .restingHeartRate, .hrvSDNN, .spo2, .temperature, .respiratoryRate, .sleep,
             .distance, .exerciseMinutes:
            // distance + exerciseMinutes are derived values written directly by HealthKitWriter,
            // NOT raw ring samples — they never flow through the cumulative-counter ingest path.
            return false
        }
    }
}

public struct CumulativeMetricState: Equatable, Sendable {
    public var previousRawValue: Double?
    public var dailyTotal: Double

    public init(previousRawValue: Double? = nil, dailyTotal: Double = 0) {
        self.previousRawValue = previousRawValue
        self.dailyTotal = dailyTotal
    }
}

public struct CumulativeMetricResult: Equatable, Sendable {
    public let sample: QuantitySample
    public let rawValue: Double
    public let deltaValue: Double
    public let dailyTotal: Double
}

public enum CumulativeMetricAccumulator {
    public static func accumulate(
        _ sample: QuantitySample,
        state: CumulativeMetricState
    ) -> CumulativeMetricResult {
        let raw = sample.value
        let delta: Double
        if let previous = state.previousRawValue {
            delta = raw >= previous ? raw - previous : raw
        } else {
            delta = raw
        }

        let dailyTotal = state.dailyTotal + delta
        let accumulated = QuantitySample(
            kind: sample.kind,
            start: sample.start,
            end: sample.end,
            value: dailyTotal
        )
        return CumulativeMetricResult(
            sample: accumulated,
            rawValue: raw,
            deltaValue: delta,
            dailyTotal: dailyTotal
        )
    }
}
