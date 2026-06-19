// Strain — Edwards' zone-based TRIMP using Heart Rate Reserve, ported from
// openwhoop-algos/src/strain.rs. Device-agnostic: a function of a BPM series and
// the per-sample interval. Result is the WHOOP 0…21 strain scale.
//
//   1. HR Reserve = maxHR - restingHR
//   2. classify each BPM sample into zone 1-5 by %HRR (else 0)
//   3. TRIMP = sum(sampleMinutes × zoneWeight)
//   4. strain = 21 × ln(TRIMP + 1) / ln(7201)   (24h at max HR → 7200 → 21)

import Foundation

public struct Strain: Sendable {
    public let maxHR: Int
    public let restingHR: Int

    /// 10 minutes at 1 Hz — openwhoop's minimum before a strain score is meaningful.
    public static let minReadings = 600
    static let maxStrain = 21.0
    static let ln7201 = 8.882_643_961_783_384  // ln(7201)

    public init(maxHR: Int, restingHR: Int) {
        self.maxHR = maxHR
        self.restingHR = restingHR
    }

    /// Edwards zone weight (1-5) for one BPM sample, 0 below zone 1.
    static func zoneWeight(bpm: Int, restingHR: Int, hrReserve: Double) -> Int {
        let pct = (Double(bpm) - Double(restingHR)) / hrReserve * 100.0
        switch pct {
        case 90...: return 5
        case 80...: return 4
        case 70...: return 3
        case 60...: return 2
        case 50...: return 1
        default: return 0
        }
    }

    /// Strain for a BPM series sampled every `sampleSeconds`. nil if too few
    /// readings or maxHR ≤ restingHR. Mirrors `StrainCalculator::calculate`.
    public func calculate(bpms: [Int], sampleSeconds: Double = 1.0) -> Double? {
        guard let trimp = Self.edwardsTRIMP(
            bpms: bpms,
            maxHR: maxHR,
            restingHR: restingHR,
            sampleSeconds: sampleSeconds
        ) else { return nil }
        return Self.trimpToStrain(trimp)
    }

    /// Raw Edwards zone-weighted TRIMP for a BPM series.
    public static func edwardsTRIMP(
        bpms: [Int],
        maxHR: Int,
        restingHR: Int,
        sampleSeconds: Double = 1.0
    ) -> Double? {
        guard bpms.count >= minReadings, maxHR > restingHR else { return nil }
        let hrReserve = Double(maxHR) - Double(restingHR)
        let sampleMin = sampleSeconds <= 0 ? 1.0 / 60.0 : sampleSeconds / 60.0
        return bpms.reduce(0.0) { acc, bpm in
            acc + sampleMin * Double(zoneWeight(bpm: bpm, restingHR: restingHR, hrReserve: hrReserve))
        }
    }

    /// Raw Edwards zone-weighted TRIMP for timestamped HR samples.
    public static func edwardsTRIMP(hrSamples: [HRSample], maxHR: Int, restingHR: Int) -> Double? {
        guard hrSamples.count >= minReadings, maxHR > restingHR else { return nil }
        let hrReserve = Double(maxHR) - Double(restingHR)
        return hrSamples.reduce(0.0) { acc, sample in
            let duration = sample.end.timeIntervalSince(sample.start)
            let sampleMin = duration > 0 ? duration / 60.0 : 1.0 / 60.0
            return acc + sampleMin * Double(zoneWeight(
                bpm: sample.bpm,
                restingHR: restingHR,
                hrReserve: hrReserve
            ))
        }
    }

    static func trimpToStrain(_ trimp: Double) -> Double {
        guard trimp > 0 else { return 0.0 }
        let raw = maxStrain * (trimp + 1.0).log() / ln7201
        return (raw * 100.0).rounded() / 100.0
    }
}

private extension Double {
    func log() -> Double { Foundation.log(self) }
}
