// Daily strain (#216) — today's heart-rate samples, as stored, turned into one `Strain` score.
//
// `Strain.calculate(bpms:sampleSeconds:)` wants an evenly sampled series (openwhoop feeds it 1 Hz
// WHOOP data). Our stored heart rate is not that: the ring writes one POINT reading per 150 s epoch
// (`BulkRecord.epochSeconds`), the Helio Strap one per minute, and either may have gaps (not worn,
// not synced). So this expands the day's readings into a 1 Hz series first, and then hands that to
// `Strain.calculate` unchanged, with `sampleSeconds` 1 — so the minimum-data gate
// (`Strain.minReadings`, 600 readings) keeps its openwhoop meaning: 10 minutes of heart rate.
//
// How a reading becomes seconds (nothing is invented):
//   - a reading with a real span (end > start) covers exactly that span;
//   - a point reading holds until the next reading, but never longer than `maxPointSpan` (one ring
//     epoch). A gap longer than that counts as NO data, not as the last bpm carried forward;
//   - where two readings cover the same instant, the earlier one keeps it, so a live spot read
//     inside an epoch cannot add time (the same rule as `ExerciseMinutes.elevatedPieces`);
//   - readings outside `LiveHR.validBPM` are dropped, as `RestingHR` does.
//
// Inputs, and why:
//   maxHR     — `220 − age` (or the max HR the user typed), the convention every other HR-zone estimate here uses
//               (`Calories.dailyEstimate`, the workout recorder).
//   restingHR — the day's `RestingHR` value, the same number the Resting HR tile shows, so the two
//               tiles never disagree about the person's floor.
//
// Pure value-type math (no HealthKit / device / SwiftUI types) so it unit-tests on macOS.

import Foundation

public enum DailyStrain {

    /// The longest a single point reading stands for: one ring epoch (150 s). Longer gaps are gaps.
    public static let maxPointSpan: TimeInterval = TimeInterval(BulkRecord.epochSeconds)

    /// Top of the strain scale (the WHOOP 0…21 scale `Strain` computes on).
    public static let scaleMax = 21.0

    /// Seconds of heart rate `Strain` needs before it will score (`Strain.minReadings` at 1 Hz).
    public static var minCoveredSeconds: Int { Strain.minReadings }

    /// One day's strain, or why there isn't one.
    public struct Reading: Equatable, Sendable {
        /// 0…21, or nil when the day can't be scored yet (see `coveredSeconds` and `restingHR`).
        public let strain: Double?
        /// Seconds of the day the readings cover, after the expansion above.
        public let coveredSeconds: Int
        /// The newest reading used, or nil when there were none.
        public let latestSampleAt: Date?
        /// The inputs the score was computed against (nil resting HR = none known for the day).
        public let maxHR: Int
        public let restingHR: Int?

        public init(strain: Double?, coveredSeconds: Int, latestSampleAt: Date?, maxHR: Int, restingHR: Int?) {
            self.strain = strain
            self.coveredSeconds = coveredSeconds
            self.latestSampleAt = latestSampleAt
            self.maxHR = maxHR
            self.restingHR = restingHR
        }

        /// True when there was no heart rate at all in the window.
        public var hasNoData: Bool { coveredSeconds == 0 }

        /// Where the score sits on the 0…21 scale, 0…1, for a gauge. nil when there's no score.
        public var gaugeFraction: Double? {
            strain.map { min(max($0 / DailyStrain.scaleMax, 0), 1) }
        }

        /// The score's band (WHOOP's published bands for the same 0…21 scale). nil when there's no score.
        public var band: Band? { strain.map(Band.init(strain:)) }
    }

    /// WHOOP's published bands for the 0…21 strain scale: light below 10, moderate below 14,
    /// high below 18, all out at 18 and above.
    public enum Band: String, CaseIterable, Sendable {
        case light, moderate, high, allOut

        public init(strain: Double) {
            switch strain {
            case ..<10: self = .light
            case ..<14: self = .moderate
            case ..<18: self = .high
            default:    self = .allOut
            }
        }

        public var label: String {
            switch self {
            case .light:    return "Light"
            case .moderate: return "Moderate"
            case .high:     return "High"
            case .allOut:   return "All out"
            }
        }
    }

    /// The 1 Hz bpm series `samples` imply inside `window` (rules in the header). Ordered by time;
    /// uncovered seconds are simply absent, so `count` is the covered time in seconds.
    public static func perSecondBPMs(_ samples: [HRSample], window: DateInterval,
                                     maxPointSpan: TimeInterval = maxPointSpan) -> [Int] {
        let sorted = samples
            .filter { LiveHR.validBPM.contains($0.bpm) && $0.start < window.end && $0.end >= window.start }
            .sorted { $0.start < $1.start }
        var out: [Int] = []
        var cursor = window.start
        for (i, s) in sorted.enumerated() {
            let end: Date
            if s.end > s.start {
                end = s.end
            } else {
                let cap = s.start.addingTimeInterval(maxPointSpan)
                let next = sorted[(i + 1)...].first { $0.start > s.start }?.start
                end = next.map { min($0, cap) } ?? cap
            }
            let from = max(s.start, cursor)
            let to = min(end, window.end)
            guard to > from else { continue }
            let seconds = Int(to.timeIntervalSince(from).rounded())
            if seconds > 0 { out.append(contentsOf: repeatElement(s.bpm, count: seconds)) }
            cursor = to
        }
        return out
    }

    /// Strain for `window` (normally today so far) from that window's heart rate.
    ///
    /// - Parameters:
    ///   - hr: heart-rate readings; anything outside `window` is ignored.
    ///   - age: for `maxHR = 220 − age` (Automatic).
    ///   - manualMaxHR: the max HR the user typed, replacing the formula (decision 83c).
    ///   - restingHR: the day's resting HR in bpm, or nil when none is known (then there's no score).
    public static func reading(hr: [HRSample], window: DateInterval, age: Int, restingHR: Double?,
                               manualMaxHR: Int? = nil) -> Reading {
        let maxHR = MaxHeartRate.resolve(age: age, manual: manualMaxHR)
        let rhr = restingHR.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
        let bpms = perSecondBPMs(hr, window: window)
        let latest = hr
            .filter { LiveHR.validBPM.contains($0.bpm) && window.contains($0.start) }
            .map(\.start).max()
        let strain = rhr.flatMap { Strain(maxHR: maxHR, restingHR: $0).calculate(bpms: bpms, sampleSeconds: 1) }
        return Reading(strain: strain, coveredSeconds: bpms.count, latestSampleAt: latest,
                       maxHR: maxHR, restingHR: rhr)
    }
}
