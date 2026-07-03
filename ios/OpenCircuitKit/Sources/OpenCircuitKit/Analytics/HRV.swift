// HRV (RMSSD / SDNN) over per-beat inter-beat intervals (IBI, also called RR or
// NN intervals) in milliseconds.
//
// RingConn input status:
// - 0x4c[5] gives firmware-finished RMSSD on sleep-vitals epochs.
// - 0x13 gives raw pulse-resolution optical PPG windows, but Swift does not yet
//   contain a validated beat/foot detector or a periodic capture policy for #38.
// - 0x15 live HR is a windowed scalar, and 0x47 is a sparse optical trend; neither
//   is a valid source for IBI-derived HRV.
//
// Keep this file pure: feed it only validated IBI windows from a proven PPG/IBI
// extractor. Do not synthesize intervals from averaged HR.
//
// HealthKit note: OpenCircuit currently writes RMSSD values into
// `.heartRateVariabilitySDNN` with metadata `OpenCircuitHRVStatistic = "RMSSD"`
// (see HEALTHKIT_MAPPING.md). The adapter below follows that convention until the
// writer can distinguish true SDNN from RMSSD per sample.

import Foundation

public enum HRV {
    /// A quality-gated IBI window from an upstream beat detector. The initializer
    /// enforces only structural validity; signal quality, contact, ectopic-beat
    /// filtering, and PPG-vs-reference validation belong in the extractor.
    public struct ValidatedIBIWindow: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let intervalsMs: [Int]

        public init?(start: Date, end: Date, intervalsMs: [Int]) {
            guard end >= start,
                  intervalsMs.count >= 2,
                  intervalsMs.allSatisfy({ $0 > 0 })
            else { return nil }
            self.start = start
            self.end = end
            self.intervalsMs = intervalsMs
        }
    }

    public struct IBIWindowMetrics: Equatable, Sendable {
        public let rmssdMs: Int
        public let sdnnMs: Int

        public init(rmssdMs: Int, sdnnMs: Int) {
            self.rmssdMs = rmssdMs
            self.sdnnMs = sdnnMs
        }
    }

    /// RMSSD over one window of RR intervals (ms): sqrt(mean of squared successive
    /// differences). nil for windows shorter than 2. Integer result truncates
    /// toward zero to match openwhoop's `as u64`.
    public static func rmssd(_ window: [Int]) -> Int? {
        guard window.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<window.count {
            let d = Double(window[i] - window[i - 1])
            sumSq += d * d
        }
        let mean = sumSq / Double(window.count - 1)
        return Int(mean.squareRoot())
    }

    /// SDNN over one window of NN/IBI intervals (ms): population standard deviation
    /// of the intervals themselves. nil for windows shorter than 2.
    public static func sdnn(_ window: [Int]) -> Int? {
        guard window.count >= 2 else { return nil }
        let mean = Double(window.reduce(0, +)) / Double(window.count)
        let variance = window.reduce(0.0) { partial, value in
            let d = Double(value) - mean
            return partial + d * d
        } / Double(window.count)
        return Int(variance.squareRoot())
    }

    public static func metrics(from window: ValidatedIBIWindow) -> IBIWindowMetrics? {
        guard let rmssd = rmssd(window.intervalsMs),
              let sdnn = sdnn(window.intervalsMs)
        else { return nil }
        return IBIWindowMetrics(rmssdMs: rmssd, sdnnMs: sdnn)
    }

    /// Convert a validated IBI window into the HRV sample shape the app already
    /// persists and mirrors to HealthKit. The value is RMSSD, matching existing
    /// HealthKit metadata; `metrics(from:)` also exposes true SDNN for future writers.
    public static func rmssdSample(from window: ValidatedIBIWindow) -> QuantitySample? {
        guard let metrics = metrics(from: window) else { return nil }
        return QuantitySample(kind: .hrvSDNN,
                              start: window.start,
                              end: window.end,
                              value: Double(metrics.rmssdMs))
    }

    /// Rolling RMSSD over consecutive windows of `windowSize` (openwhoop uses 300).
    /// Returns one RMSSD per window position; empty if fewer than `windowSize` RRs.
    public static func rollingRMSSD(_ rr: [Int], windowSize: Int = 300) -> [Int] {
        guard windowSize >= 2, rr.count >= windowSize else { return [] }
        var out: [Int] = []
        out.reserveCapacity(rr.count - windowSize + 1)
        for start in 0...(rr.count - windowSize) {
            if let v = rmssd(Array(rr[start ..< start + windowSize])) { out.append(v) }
        }
        return out
    }

    /// Flatten per-reading RR sample groups and drop non-positive artifacts.
    /// Mirrors openwhoop `clean_rr`.
    public static func cleanRR(_ groups: [[Int]]) -> [Int] {
        groups.flatMap { $0 }.filter { $0 > 0 }
    }

    /// Summary of rolling HRV across a span (e.g. a night). nil if no windows.
    public struct Summary: Equatable, Sendable {
        public let min: Int
        public let max: Int
        public let avg: Int
    }

    public static func summary(_ rr: [Int], windowSize: Int = 300) -> Summary? {
        let series = rollingRMSSD(rr, windowSize: windowSize)
        guard let lo = series.min(), let hi = series.max(), !series.isEmpty else { return nil }
        let avg = series.reduce(0, +) / series.count   // integer mean, as openwhoop
        return Summary(min: lo, max: hi, avg: avg)
    }
}
