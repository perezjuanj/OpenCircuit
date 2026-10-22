// Possible-illness signals: a broader, earlier check than the fever flag.
//
// WHY THIS EXISTS. `VitalsBaseline.suspectedFever` needs a skin-temperature rise of at least 1 °C
// AND a resting-HR rise of at least 8 bpm against a 7-day resting-HR baseline. That is a FEVER
// detector, and most colds never reach it. On a real strap night with a confirmed cold
// (2026-10-21→22, Helio Strap on the wrist, see `IllnessSignalsTests`) the wearer got only the
// skin-temperature alert, even though every overnight vital moved the way it does early in an
// infection:
//
//     night        in-bed HR mean   RMSSD mean   resp. rate   nightly skin temp
//     usual (2)        65.5 bpm       67.1 ms      14.2 /min    34.04 °C (1 night)
//     cold night       73.3 bpm       50.9 ms      13.8 /min    35.15 °C
//
// The published wearable work points the same way: the earliest, most consistent overnight
// changes in a respiratory infection are a rise in sleeping HR, a fall in HRV and a rise in skin
// temperature, with respiratory rate following in some people (Mishra 2020, Nat Biomed Eng;
// Natarajan 2020, npj Digit Med; Mason 2022, Sci Rep). No single one of them is specific, so this
// check asks for TWO of the four against the person's own recent nights.
//
// WHAT IT CLAIMS. A measurement, never a diagnosis: "these overnight vitals moved away from your
// usual". Alcohol, a late heavy meal, a hot room or hard training can produce the same pattern,
// and the copy says so.
//
// BASELINES. Each vital is judged against the MEDIAN of up to 30 prior nights from the same
// device (decision 29), needing at least 3. A median, not a mean, so one earlier bad night does
// not drag "your usual" towards itself. Skin temperature is NOT re-derived here: the canonical
// offset comes from `SkinTempBaseline`, exactly as the fever flag takes it.
//
// Pure value-type math (no Apple frameworks) so it unit-tests on the CLI.

import Foundation

public enum IllnessSignals {

    // MARK: Signals

    /// One overnight vital that can move in an infection, in the direction that matters.
    public enum Signal: String, CaseIterable, Sendable {
        case skinTempRise
        case restingHRRise
        case hrvDrop
        case respiratoryRateRise
    }

    // MARK: Config

    /// Policy knobs, never a person's data. 🟡 Heuristic thresholds: each is the smallest change
    /// the repo already treats as meaningful for that vital, so the two checks agree on scale.
    public struct Config: Equatable, Sendable {
        /// Prior nights a vital needs before it has a baseline.
        public var minPriorNights: Int
        /// Trailing prior nights the baseline uses.
        public var maxPriorNights: Int
        /// Skin-temperature offset (°C, canonical `SkinTempBaseline` offset) that counts as a rise.
        /// Same as `VitalsBaseline.Config.tempMinorC` and `HeadacheSignals.Tuning.tempOnsetC`.
        public var tempRiseC: Double
        /// In-bed mean HR rise (bpm) over the baseline. Same as `VitalsBaseline.Config.minDeltaRestingHR`.
        public var restingHRRiseBpm: Double
        /// HRV fall as a fraction of the baseline, AND at least `hrvMinDropMs`.
        public var hrvDropFraction: Double
        /// Absolute HRV floor (ms). Same as `VitalsBaseline.Config.minDeltaHRV`.
        public var hrvMinDropMs: Double
        /// Respiratory-rate rise (breaths/min) over the baseline.
        public var respiratoryRiseBrpm: Double
        /// How many signals must move together.
        public var minSignals: Int

        public init(minPriorNights: Int = 3,
                    maxPriorNights: Int = 30,
                    tempRiseC: Double = 0.5,
                    restingHRRiseBpm: Double = 5,
                    hrvDropFraction: Double = 0.20,
                    hrvMinDropMs: Double = 8,
                    respiratoryRiseBrpm: Double = 1.0,
                    minSignals: Int = 2) {
            self.minPriorNights = minPriorNights
            self.maxPriorNights = maxPriorNights
            self.tempRiseC = tempRiseC
            self.restingHRRiseBpm = restingHRRiseBpm
            self.hrvDropFraction = hrvDropFraction
            self.hrvMinDropMs = hrvMinDropMs
            self.respiratoryRiseBrpm = respiratoryRiseBrpm
            self.minSignals = minSignals
        }
    }

    // MARK: Per-night vitals

    /// One night's in-bed window, keyed by the night's stable day key.
    public struct NightWindow: Equatable, Sendable {
        public let night: Date
        public let start: Date
        public let end: Date
        public init(night: Date, start: Date, end: Date) {
            self.night = night; self.start = start; self.end = end
        }
    }

    /// One night's overnight means. nil = too few readings to represent the night.
    public struct NightVitals: Equatable, Sendable {
        public let night: Date
        public let restingHR: Double?        // mean HR inside the in-bed window, bpm
        public let hrv: Double?              // mean of the `hrvSDNN` kind (RMSSD on both devices), ms
        public let respiratoryRate: Double?  // breaths/min
        public init(night: Date, restingHR: Double?, hrv: Double?, respiratoryRate: Double?) {
            self.night = night
            self.restingHR = restingHR
            self.hrv = hrv
            self.respiratoryRate = respiratoryRate
        }
    }

    /// Fewest readings inside a window before that night's mean counts. Mirrors
    /// `RestingHR.minSleepSamples` and `HeadacheEngine.minNightHRVSamples` (3).
    public static let minNightSamples = 3

    /// Per-night means of HR, HRV and respiratory rate inside each window. Other kinds are ignored.
    /// HR outside `LiveHR.validBPM` is dropped first, as `RestingHR.value` does.
    ///
    /// One forward pass per kind over sorted inputs (windows never overlap: one row per night), so
    /// a month of minute-level strap readings costs a sort, not a rescan per night.
    public static func nightlyVitals(samples: [QuantitySample], windows: [NightWindow],
                                     minSamples: Int = minNightSamples) -> [NightVitals] {
        let sortedWindows = windows.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        func means(_ kind: MetricKind, valid: (Double) -> Bool) -> [Date: Double] {
            let sorted = samples.filter { $0.kind == kind && valid($0.value) }.sorted { $0.start < $1.start }
            var totals: [Date: (sum: Double, count: Int)] = [:]
            var idx = 0
            for s in sorted {
                while idx < sortedWindows.count, sortedWindows[idx].end <= s.start { idx += 1 }
                guard idx < sortedWindows.count, s.start >= sortedWindows[idx].start else { continue }
                let key = sortedWindows[idx].night
                let running = totals[key] ?? (0, 0)
                totals[key] = (running.sum + s.value, running.count + 1)
            }
            return totals.compactMapValues { $0.count >= max(1, minSamples) ? $0.sum / Double($0.count) : nil }
        }
        let hr = means(.heartRate) { LiveHR.validBPM.contains(Int($0.rounded())) }
        let hrv = means(.hrvSDNN) { $0 > 0 }
        let rr = means(.respiratoryRate) { $0 > 0 }
        return sortedWindows.map {
            NightVitals(night: $0.night, restingHR: hr[$0.night], hrv: hrv[$0.night],
                        respiratoryRate: rr[$0.night])
        }
    }

    // MARK: Assessment

    /// One vital's comparison. `delta` is tonight − baseline in the vital's own unit (°C, bpm, ms,
    /// breaths/min); for skin temperature the baseline is implicit in the canonical offset.
    public struct Reading: Equatable, Sendable {
        public let signal: Signal
        public let delta: Double
        public let baseline: Double?
        public let isElevated: Bool
    }

    public struct Assessment: Equatable, Sendable {
        /// Every vital that could be judged tonight (had a value and a baseline), in `Signal` order.
        public let readings: [Reading]
        /// The vitals that moved past their threshold, in `Signal` order.
        public var signals: [Signal] { readings.filter(\.isElevated).map(\.signal) }
        public let isSuspected: Bool
    }

    /// Median of the trailing `config.maxPriorNights` values, nil below `config.minPriorNights`.
    static func baseline(_ prior: [Double], config: Config) -> Double? {
        let window = Array(prior.suffix(config.maxPriorNights))
        guard window.count >= max(1, config.minPriorNights) else { return nil }
        let s = window.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Judge `tonight` against `prior` (chronological, oldest first, EXCLUDING tonight, same device).
    /// `skinTempOffsetC` is the canonical `SkinTempBaseline` offset (nil when there is no baseline
    /// or no usable temperature). Missing inputs only remove a signal; they never invent one.
    public static func assess(tonight: NightVitals, prior: [NightVitals], skinTempOffsetC: Double?,
                              config: Config = Config()) -> Assessment {
        let ordered = prior.filter { $0.night < tonight.night }.sorted { $0.night < $1.night }
        var readings: [Reading] = []

        if let offset = skinTempOffsetC {
            readings.append(Reading(signal: .skinTempRise, delta: offset, baseline: nil,
                                    isElevated: offset >= config.tempRiseC))
        }
        if let today = tonight.restingHR,
           let base = baseline(ordered.compactMap(\.restingHR), config: config) {
            let d = today - base
            readings.append(Reading(signal: .restingHRRise, delta: d, baseline: base,
                                    isElevated: d >= config.restingHRRiseBpm))
        }
        if let today = tonight.hrv, let base = baseline(ordered.compactMap(\.hrv), config: config) {
            let d = today - base
            let needed = max(config.hrvMinDropMs, config.hrvDropFraction * base)
            readings.append(Reading(signal: .hrvDrop, delta: d, baseline: base, isElevated: -d >= needed))
        }
        if let today = tonight.respiratoryRate,
           let base = baseline(ordered.compactMap(\.respiratoryRate), config: config) {
            let d = today - base
            readings.append(Reading(signal: .respiratoryRateRise, delta: d, baseline: base,
                                    isElevated: d >= config.respiratoryRiseBrpm))
        }

        let elevated = readings.filter(\.isElevated).count
        return Assessment(readings: readings, isSuspected: elevated >= max(1, config.minSignals))
    }

    // MARK: Copy

    /// The notification text. Reports WHAT MOVED and by how much, offers the common non-illness
    /// explanations, and never names a disease. The shared medical disclaimer is appended by the app.
    ///
    /// SHORT ON PURPOSE: iOS shows about six lines of an expanded notification and cuts the rest, so
    /// the first version (a full sentence per vital, ~300 characters before the disclaimer) lost its
    /// own caveat on a real phone. Compact "vital +delta" items keep the numbers and the caveat
    /// inside the budget `HealthAlertCopyTests.testEveryVitalAlertFitsAnExpandedNotification` pins.
    /// `tempUnit` is the wearer's display unit; the skin-temperature delta follows it.
    public static func copy(for assessment: Assessment,
                            tempUnit: TemperatureUnit = .celsius) -> (title: String, body: String) {
        let parts = assessment.readings.filter(\.isElevated).map { phrase($0, tempUnit: tempUnit) }
        let list = parts.isEmpty ? "several overnight vitals moved" : parts.joined(separator: ", ")
        return ("Possible illness signs",
                "Vs your usual: " + list + ". Alcohol, a late meal or a hot room can do this too (estimate).")
    }

    static func phrase(_ r: Reading, tempUnit: TemperatureUnit = .celsius) -> String {
        switch r.signal {
        case .skinTempRise:
            return "skin temp +" + String(format: "%.1f", tempUnit.convertDelta(fromCelsius: r.delta))
                + " " + tempUnit.symbol
        case .restingHRRise:
            return "sleeping HR +" + String(Int(r.delta.rounded())) + " bpm"
        case .hrvDrop:
            let pct = r.baseline.map { $0 > 0 ? Int((-r.delta / $0 * 100).rounded()) : 0 } ?? 0
            return "HRV \u{2212}" + String(pct) + "%"
        case .respiratoryRateRise:
            return "breathing +" + String(format: "%.1f", r.delta) + "/min"
        }
    }
}
