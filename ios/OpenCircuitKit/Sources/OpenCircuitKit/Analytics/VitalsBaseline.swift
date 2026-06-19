// Vitals baseline + acute anomaly detection (Vitals Status / fever) — #72.
//
// The app's "Vitals Status" engine compares each day's vitals to a PERSONAL rolling
// baseline (the APK uses a 7–30 day window, pp.txt:47810) and flags Minor / Significant
// outliers (pp.txt:47815), then cross-references HR + skin temperature for a suspected-fever
// flag (pp.txt:48241 "exhibiting suspected fever symptoms"; `keyWBVitalSignFever`;
// `feverAbnormal` = 0x14). This file holds the PURE detection math (no Apple frameworks) so
// it unit-tests on the CLI.
//
// All baselines are PERSONAL (derived from the user's own trailing history) — never a
// hardcoded "healthy" range. A value is only flagged relative to that person's own normal,
// so we never fabricate a medical value. Skin temperature is NOT recomputed here: the
// canonical nightly offset comes from `SkinTempBaseline` (#69) and is passed in, exactly as
// the ticket requires ("consumes the canonical skin-temp value … does not re-compute temp").
//
// This OWNS fever detection. The skin-temp ticket only supplies the temperature input; the
// notifications ticket (#85) only routes the resulting flags to local notifications.

import Foundation

public enum VitalsBaseline {

    // MARK: Vitals

    /// The per-metric vitals that carry a personal baseline. Skin temperature is folded into the
    /// status via its canonical offset (see `report`), not as a re-derived baseline here.
    public enum Vital: String, CaseIterable, Sendable {
        case restingHR
        case overnightSpO2     // percent (0…100)
        case overnightHRV      // RMSSD ms

        /// The direction that is CLINICALLY concerning for this vital — a deviation the other way
        /// (e.g. an unusually high HRV, an unusually low resting HR) is healthy, not an anomaly.
        public var concern: Concern {
            switch self {
            case .restingHR: return .high     // a rising resting HR is the concern
            case .overnightSpO2: return .low  // desaturation is the concern
            case .overnightHRV: return .low   // falling HRV (stress/illness) is the concern
            }
        }
    }

    public enum Concern: Sendable { case high, low, both }

    /// How far today's value sits from the personal baseline.
    public enum Severity: String, Sendable, Equatable, CaseIterable {
        case normal, minor, significant
    }

    public enum Direction: String, Sendable, Equatable { case rise, drop }

    // MARK: Config

    /// Window + threshold knobs. Defaults follow the APK's 7–30 day window; the z-score cut-offs
    /// and absolute noise floors are defensible heuristics (labeled estimates in the UI), and the
    /// caller may override them. Never a person's data — only policy.
    public struct Config: Equatable, Sendable {
        public var minBaselineDays: Int
        public var maxBaselineDays: Int
        /// |z| at/above this (and past the absolute floor) is a Minor outlier; …
        public var minorZ: Double
        /// … |z| at/above this is a Significant outlier.
        public var significantZ: Double
        /// Absolute deviation a vital must exceed before ANY flag — so a person with a very tight
        /// baseline (tiny SD) isn't flagged on trivially small, noise-level changes.
        public var minDeltaRestingHR: Double
        public var minDeltaSpO2: Double
        public var minDeltaHRV: Double
        /// Skin-temp offset bands (°C), using the canonical SkinTempBaseline offset. |offset|
        /// beyond `tempSignificantC` is Significant; beyond `tempMinorC` is Minor.
        public var tempMinorC: Double
        public var tempSignificantC: Double
        /// Suspected fever needs BOTH a skin-temp rise ≥ this AND a resting-HR rise ≥ the bpm below.
        public var feverTempRiseC: Double
        public var feverHRRiseBpm: Double

        public init(minBaselineDays: Int = 7,
                    maxBaselineDays: Int = 30,
                    minorZ: Double = 1.5,
                    significantZ: Double = 2.5,
                    minDeltaRestingHR: Double = 5,
                    minDeltaSpO2: Double = 2,
                    minDeltaHRV: Double = 8,
                    tempMinorC: Double = 0.5,
                    tempSignificantC: Double = SkinTempBaseline.normalDeviationC,
                    feverTempRiseC: Double = SkinTempBaseline.normalDeviationC,
                    feverHRRiseBpm: Double = 8) {
            self.minBaselineDays = minBaselineDays
            self.maxBaselineDays = maxBaselineDays
            self.minorZ = minorZ
            self.significantZ = significantZ
            self.minDeltaRestingHR = minDeltaRestingHR
            self.minDeltaSpO2 = minDeltaSpO2
            self.minDeltaHRV = minDeltaHRV
            self.tempMinorC = tempMinorC
            self.tempSignificantC = tempSignificantC
            self.feverTempRiseC = feverTempRiseC
            self.feverHRRiseBpm = feverHRRiseBpm
        }

        func minDelta(_ vital: Vital) -> Double {
            switch vital {
            case .restingHR: return minDeltaRestingHR
            case .overnightSpO2: return minDeltaSpO2
            case .overnightHRV: return minDeltaHRV
            }
        }
    }

    // MARK: Baseline statistics

    /// Mean / standard deviation over the trailing `maxBaselineDays` PRIOR daily values. `prior`
    /// is chronological (oldest→newest); we take the most-recent window. nil below
    /// `minBaselineDays` (too little history to call an outlier).
    public struct Stats: Equatable, Sendable {
        public let mean: Double
        public let sd: Double
        public let n: Int
    }

    public static func stats(_ prior: [Double], config: Config = Config()) -> Stats? {
        let window = Array(prior.suffix(config.maxBaselineDays))
        guard window.count >= config.minBaselineDays else { return nil }
        let mean = window.reduce(0, +) / Double(window.count)
        let variance = window.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)
        return Stats(mean: mean, sd: variance.squareRoot(), n: window.count)
    }

    // MARK: Per-vital classification

    /// One day's classification of a vital against its personal baseline.
    public struct Classification: Equatable, Sendable {
        public let severity: Severity
        public let baseline: Stats?
        public let delta: Double          // today − baseline mean (0 when no baseline)
        public let direction: Direction   // sign of `delta`
    }

    /// Classify today's value of `vital` against the prior daily series. Only deviations in the
    /// vital's `concern` direction, past both the z-score cut-off AND the absolute floor, are
    /// flagged — so a healthy swing (high HRV, low resting HR) stays `.normal`.
    public static func classify(today: Double, prior: [Double], vital: Vital,
                                config: Config = Config()) -> Classification {
        guard let stats = stats(prior, config: config) else {
            return Classification(severity: .normal, baseline: nil, delta: 0, direction: .rise)
        }
        let delta = today - stats.mean
        let direction: Direction = delta >= 0 ? .rise : .drop
        guard isConcerning(delta, vital.concern), abs(delta) >= config.minDelta(vital) else {
            return Classification(severity: .normal, baseline: stats, delta: delta, direction: direction)
        }
        let z = stats.sd > 1e-9 ? abs(delta) / stats.sd : .greatestFiniteMagnitude
        let severity: Severity = z >= config.significantZ ? .significant
            : z >= config.minorZ ? .minor : .normal
        return Classification(severity: severity, baseline: stats, delta: delta, direction: direction)
    }

    /// Severity of a skin-temperature deviation from the CANONICAL baseline offset (#69) — both
    /// directions are concerning (fever vs. illness/recovery drop), so it isn't direction-gated.
    public static func tempSeverity(offsetC: Double, config: Config = Config()) -> Severity {
        let a = abs(offsetC)
        if a >= config.tempSignificantC { return .significant }
        if a >= config.tempMinorC { return .minor }
        return .normal
    }

    private static func isConcerning(_ delta: Double, _ concern: Concern) -> Bool {
        switch concern {
        case .high: return delta > 0
        case .low: return delta < 0
        case .both: return delta != 0
        }
    }

    // MARK: Fever (HR + temperature cross-reference) — this ticket OWNS it.

    /// Suspected fever fires ONLY on COMBINED elevation: a skin-temp rise (the canonical offset
    /// from `SkinTempBaseline`, NOT recomputed here) AND a resting-HR rise above the personal HR
    /// baseline. Either alone is not enough — exactly the APK's HR+temp cross-reference. nil/insufficient
    /// inputs ⇒ false (never a false positive). This is the `feverAbnormal` (0x14) signal.
    public static func suspectedFever(restingHRToday: Double?, restingHRPrior: [Double],
                                      skinTempOffsetC: Double?, config: Config = Config()) -> Bool {
        guard let offset = skinTempOffsetC, offset >= config.feverTempRiseC else { return false }
        guard let hr = restingHRToday, let hrStats = stats(restingHRPrior, config: config) else { return false }
        return (hr - hrStats.mean) >= config.feverHRRiseBpm
    }

    // MARK: Vitals Status report

    /// One day's value of a vital plus the prior daily series it's judged against.
    public struct VitalInput: Equatable, Sendable {
        public let vital: Vital
        public let today: Double
        public let prior: [Double]
        public init(vital: Vital, today: Double, prior: [Double]) {
            self.vital = vital; self.today = today; self.prior = prior
        }
    }

    /// A single contributing signal in the Vitals Status panel.
    public struct Signal: Equatable, Sendable {
        public let vital: Vital?          // nil = skin-temperature (carried by `isTemperature`)
        public let isTemperature: Bool
        public let severity: Severity
        public let delta: Double
        public let direction: Direction
        public let baselineMean: Double?
    }

    /// Overall Vitals Status, mirroring the app's normal / watch / anomaly framing.
    public enum Status: String, Sendable, Equatable { case normal, watch, anomaly }

    public struct Report: Equatable, Sendable {
        public let status: Status
        public let signals: [Signal]      // only the non-normal contributors
        public let feverSuspected: Bool
    }

    /// Build the Vitals Status report. `skinTempOffsetC` is the canonical nightly offset from
    /// `SkinTempBaseline` (#69) — temperature is NOT re-derived here. Status escalates to
    /// `.anomaly` on any Significant outlier or a suspected fever, `.watch` on any Minor outlier.
    public static func report(_ inputs: [VitalInput], skinTempOffsetC: Double? = nil,
                              config: Config = Config()) -> Report {
        var signals: [Signal] = []

        for input in inputs {
            let c = classify(today: input.today, prior: input.prior, vital: input.vital, config: config)
            if c.severity != .normal {
                signals.append(Signal(vital: input.vital, isTemperature: false, severity: c.severity,
                                      delta: c.delta, direction: c.direction,
                                      baselineMean: c.baseline?.mean))
            }
        }

        if let offset = skinTempOffsetC {
            let sev = tempSeverity(offsetC: offset, config: config)
            if sev != .normal {
                signals.append(Signal(vital: nil, isTemperature: true, severity: sev, delta: offset,
                                      direction: offset >= 0 ? .rise : .drop, baselineMean: nil))
            }
        }

        let hr = inputs.first { $0.vital == .restingHR }
        let fever = suspectedFever(restingHRToday: hr?.today, restingHRPrior: hr?.prior ?? [],
                                   skinTempOffsetC: skinTempOffsetC, config: config)

        let status: Status
        if fever || signals.contains(where: { $0.severity == .significant }) {
            status = .anomaly
        } else if signals.contains(where: { $0.severity == .minor }) {
            status = .watch
        } else {
            status = .normal
        }
        return Report(status: status, signals: signals, feverSuspected: fever)
    }
}
