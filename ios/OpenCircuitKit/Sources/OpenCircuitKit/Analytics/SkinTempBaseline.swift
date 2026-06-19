// Sleeping skin-temperature baseline + nightly deviation (Oura-style) — #69.
//
// The signature ring feature: each night's MEAN sleeping skin temperature, a signed
// DEVIATION from a rolling baseline (the app uses the previous 30 nights), and a
// normal/abnormal classification. The APK's own copy (pp.txt:47432) defines it exactly:
//   "the baseline represents the average sleeping skin temperature of the previous 30
//    days … Temperatures within 1°C (1.8°F) of the baseline are considered normal."
//
// Skin temp is decoded 🟢 (0.1 °C, descriptor 0x10/0x87 — PROTOCOL §5.4) but rides the
// LIVE descriptor, not the bulk 0x4c/0x47 drain — so a nightly value depends on the ring
// staying connected through the night (RingSession window-gates + persists those readings),
// OR on the temp/RR capture ticket (#87) for a connection-free fetch. Honor that caveat in
// the UI ("est." + connected-overnight note); this file is the pure math only.
//
// This computes the temperature INPUT (nightly mean, baseline, signed offset, raw anomaly
// flags). Fever (HR+temp cross-reference) is owned by the vitals-anomaly ticket (#72) and
// notifications by #85 — NOT here.

import Foundation

public enum SkinTempBaseline {

    /// Trailing nights the rolling baseline averages over (the app uses 30).
    public static let baselineWindowNights = 30
    /// Minimum prior nights before a baseline is considered meaningful. Below this the
    /// average swings too much night-to-night to call a deviation, so callers should show
    /// the nightly value without an offset until enough history accrues.
    public static let minBaselineNights = 3
    /// Deviation within ±this many °C of the baseline is "normal" (APK: 1 °C). Beyond it is
    /// an abnormal rise/drop. A signed, symmetric band — never a hardcoded temperature.
    public static let normalDeviationC = 1.0
    /// Night-to-night change beyond ±this °C is a "fluctuation" rise/drop (the 0x10/0x11
    /// flags). Distinct from the baseline deviation (0x12/0x13). Heuristic — labeled as such.
    public static let fluctuationC = 0.6

    /// One night's mean sleeping skin temperature, keyed by the night it belongs to.
    public struct NightlyTemp: Equatable, Sendable {
        public let night: Date     // start-of-day (or any stable per-night key)
        public let celsius: Double
        public init(night: Date, celsius: Double) {
            self.night = night
            self.celsius = celsius
        }
    }

    /// Mean of skin-temperature readings inside a sleep window. Pass the night's persisted
    /// `.temperature` samples (already worn- and window-gated by RingSession). nil when there
    /// are no readings — a connection-free night has none until #87 lands.
    public static func nightlyMean(_ celsius: [Double]) -> Double? {
        guard !celsius.isEmpty else { return nil }
        return celsius.reduce(0, +) / Double(celsius.count)
    }

    /// Convenience over `TemperatureSample`s, scoped to `[start, end]` (inclusive).
    public static func nightlyMean(samples: [TemperatureSample], in window: DateInterval) -> Double? {
        nightlyMean(samples.filter { window.contains($0.time) }.map(\.celsius))
    }

    /// Rolling baseline = mean of the most recent `windowNights` PRIOR nightly means. The
    /// caller passes prior nights only (exclude tonight); we additionally sort by night and
    /// take the trailing window so order/extra history can't skew it. nil below
    /// `minBaselineNights` (too little history to trust).
    public static func baseline(priorNights: [NightlyTemp],
                                windowNights: Int = baselineWindowNights,
                                minNights: Int = minBaselineNights) -> Double? {
        let trailing = priorNights.sorted { $0.night < $1.night }.suffix(windowNights)
        guard trailing.count >= minNights else { return nil }
        return trailing.map(\.celsius).reduce(0, +) / Double(trailing.count)
    }

    /// Signed nightly offset = tonight − baseline (°C). Positive = warmer than baseline.
    public static func offset(tonight: Double, baseline: Double) -> Double {
        tonight - baseline
    }

    /// Where tonight's deviation from the baseline falls. `.normal` within ±`normalC`,
    /// else a signed rise/drop. These map to the APK's `skinTempAbnormalRise` (0x12) /
    /// `skinTempAbnormalDrop` (0x13) flags — app-side only, NOT fever (0x14).
    public enum DeviationBand: String, Equatable, Sendable {
        case normal, abnormalRise, abnormalDrop
    }

    public static func deviationBand(offset: Double, normalC: Double = normalDeviationC) -> DeviationBand {
        if offset > normalC { return .abnormalRise }
        if offset < -normalC { return .abnormalDrop }
        return .normal
    }

    /// The five raw temperature anomaly flags the app exposes, computed app-side (#69 owns
    /// these; fever 0x14 does not live here). `abnormal*` compare tonight to the BASELINE;
    /// `fluctuation*` compare tonight to the PREVIOUS night. All are honest derivations of
    /// the decoded skin temp — none is fabricated.
    public struct AnomalyFlags: Equatable, Sendable {
        public var abnormalRise = false        // 0x12 — well above baseline
        public var abnormalDrop = false        // 0x13 — well below baseline
        public var fluctuationRise = false     // 0x10 — sharp jump vs last night
        public var fluctuationDrop = false     // 0x11 — sharp fall vs last night
        public init() {}
        public var any: Bool { abnormalRise || abnormalDrop || fluctuationRise || fluctuationDrop }
    }

    /// Classify tonight against an optional baseline and an optional previous night.
    public static func anomalyFlags(tonight: Double,
                                    baseline: Double?,
                                    previousNight: Double?,
                                    normalC: Double = normalDeviationC,
                                    fluctC: Double = fluctuationC) -> AnomalyFlags {
        var flags = AnomalyFlags()
        if let base = baseline {
            switch deviationBand(offset: tonight - base, normalC: normalC) {
            case .abnormalRise: flags.abnormalRise = true
            case .abnormalDrop: flags.abnormalDrop = true
            case .normal: break
            }
        }
        if let prev = previousNight {
            let d = tonight - prev
            if d > fluctC { flags.fluctuationRise = true }
            else if d < -fluctC { flags.fluctuationDrop = true }
        }
        return flags
    }

    /// Everything the UI needs for one night in a single value: nightly mean, baseline (if
    /// enough history), signed offset, band, and the raw anomaly flags.
    public struct NightReport: Equatable, Sendable {
        public let nightlyC: Double
        public let baselineC: Double?
        public let offsetC: Double?
        public let band: DeviationBand?
        public let flags: AnomalyFlags
    }

    /// Build a `NightReport` from tonight's mean and the prior nights' means.
    public static func report(tonight: Double,
                              priorNights: [NightlyTemp],
                              previousNight: Double? = nil,
                              windowNights: Int = baselineWindowNights,
                              normalC: Double = normalDeviationC,
                              fluctC: Double = fluctuationC) -> NightReport {
        let base = baseline(priorNights: priorNights, windowNights: windowNights)
        let off = base.map { offset(tonight: tonight, baseline: $0) }
        let band = off.map { deviationBand(offset: $0, normalC: normalC) }
        let flags = anomalyFlags(tonight: tonight, baseline: base,
                                 previousNight: previousNight, normalC: normalC, fluctC: fluctC)
        return NightReport(nightlyC: tonight, baselineC: base, offsetC: off, band: band, flags: flags)
    }
}
