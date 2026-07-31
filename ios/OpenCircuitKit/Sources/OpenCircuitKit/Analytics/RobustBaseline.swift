import Foundation

// Robust (median / MAD) personal baselines for the headache-signals index (#183).
//
// A DELIBERATELY SEPARATE namespace from `VitalsBaseline`, not a new `VitalsBaseline.Config`
// knob. The byte-identical discipline is the reason: `VitalsBaselineTests`, `SkinTempBaselineTests`
// and `HealthAlertsTests` must keep passing UNMODIFIED and stay the proof that this feature shifted
// nothing. A shared config struct with a new field is one careless default away from moving a
// shipped alert threshold.
//
// WHY MEDIAN/MAD RATHER THAN MEAN/SD: the days this index exists to notice are themselves the
// outliers that inflate an SD, so a mean/SD baseline is partly defined by the very days it is
// supposed to flag. The archive also contains real artifact nights — see the 86 °F
// cold-object-held-while-asleep night documented at `SkinTempBaseline.swift:35-44` — which drag a
// mean far more than a median.
//
// Pure Foundation, no Apple frameworks, so it unit-tests on the CLI.
public enum RobustBaseline {

    /// A robust location + scale estimate over a trailing window.
    public struct Stats: Equatable, Sendable {
        public let median: Double
        /// Median absolute deviation, in the same units as `median`. NOT yet scaled by
        /// `madConsistency` — `z(today:stats:noiseFloor:)` applies that.
        public let mad: Double
        /// How many prior values the estimate was built from.
        public let n: Int

        public init(median: Double, mad: Double, n: Int) {
            self.median = median
            self.mad = mad
            self.n = n
        }
    }

    /// Minimum prior days before any baseline exists. 🟡 Matches `VitalsBaseline.Config()
    /// .minBaselineDays` so the two engines agree on when a person is "known" — a user should not
    /// see one feature call itself ready while the other still says it is learning.
    public static let minBaselineDays = 7

    /// Trailing window cap.
    ///
    /// 🟡 60 days. The obvious justification — "≈ a 30-day SD window" — is WRONG, and the corrected
    /// arithmetic belongs here so nobody re-derives the wrong one: the asymptotic relative
    /// efficiency of the MAD against the SD for Gaussian data is ≈ 0.368, so 60 MAD-days carry
    /// roughly the precision of **22** SD-days, not 30. Matching `VitalsBaseline`'s 30-day SD
    /// precision would need ~81 days. 60 is a deliberate trade of precision for outlier immunity,
    /// sized to the coverage this app actually achieves rather than to a statistical ideal.
    public static let maxBaselineDays = 60

    /// 🟢 The Gaussian consistency constant: for normally-distributed data, `1.4826 · MAD`
    /// estimates σ. Without it a MAD-based z-score is on a different scale to an SD-based one and
    /// every threshold copied from the vitals engine would silently mean something else.
    public static let madConsistency = 1.4826

    /// 🔴 PROVISIONAL. Caps |z| so one absurd reading (a decode artifact, a ring read through a
    /// glove) cannot dominate a weighted sum. Calibration plan: recompute the |z| distribution over
    /// real archives once ≥3 testers have 50+ scored days, and set this at their p99.9.
    public static let zClamp: Double = 4.0

    /// Median + MAD over the trailing window of `prior` (oldest → newest), or `nil` when there is
    /// not enough history. `prior` must NOT include today.
    ///
    /// Returns `nil` rather than a degenerate estimate below `minDays`: a baseline built from three
    /// days is not a baseline, and the caller must say "still learning" instead of scoring against
    /// noise.
    public static func stats(_ prior: [Double],
                             minDays: Int = minBaselineDays,
                             maxDays: Int = maxBaselineDays) -> Stats? {
        guard minDays > 0, maxDays >= minDays else { return nil }
        let window = prior.count > maxDays ? Array(prior.suffix(maxDays)) : prior
        guard window.count >= minDays else { return nil }
        guard let med = median(window) else { return nil }
        let deviations = window.map { abs($0 - med) }
        guard let mad = median(deviations) else { return nil }
        return Stats(median: med, mad: mad, n: window.count)
    }

    /// Robust z-score of `today` against `stats`, clamped to ±`clamp`.
    ///
    /// `noiseFloor` is the absolute deviation below which a difference is not worth calling a
    /// difference. It floors the SCALE, not the result, which handles the degenerate case that
    /// would otherwise be a divide-by-zero: a perfectly regular person has `mad == 0`, and without
    /// the floor every 1-LSB wobble would come back as an infinite z. With it, such a person simply
    /// needs a real, human-sized change before they score anything.
    public static func z(today: Double,
                         stats: Stats,
                         noiseFloor: Double,
                         clamp: Double = zClamp) -> Double {
        let scale = max(madConsistency * stats.mad, max(noiseFloor, .leastNormalMagnitude))
        let raw = (today - stats.median) / scale
        guard raw.isFinite else { return 0 }
        return min(max(raw, -clamp), clamp)
    }

    /// Circular median of clock times expressed as minutes since midnight, for quantities like
    /// habitual bedtime that WRAP: the plain median of 23:50 and 00:10 is midday, which would make
    /// a perfectly regular sleeper look maximally irregular.
    ///
    /// Same timezone-free minutes-since-midnight convention as `SleepWindow` and `QuietHours`.
    /// Implemented by rotating the samples to each candidate origin and choosing the rotation with
    /// the smallest sum of absolute circular deviations — exact for the small n (≤ 60) this sees,
    /// and free of the trigonometric-mean bias that misplaces bimodal schedules.
    public static func circularMedianMinutes(_ minutesSinceMidnight: [Int]) -> Int? {
        let day = 24 * 60
        let pts = minutesSinceMidnight.map { ((($0 % day) + day) % day) }
        guard !pts.isEmpty else { return nil }
        guard pts.count > 1 else { return pts[0] }

        var best = pts[0]
        var bestCost = Double.infinity
        for candidate in pts {
            // Unwrap every point into the half-open window starting at `candidate`, take the plain
            // median there, then map back. Cost is the total circular distance to that centre.
            let unwrapped = pts.map { p -> Double in
                let d = Double((p - candidate + day) % day)
                return d > Double(day) / 2 ? d - Double(day) : d
            }
            guard let m = median(unwrapped) else { continue }
            let cost = unwrapped.reduce(0.0) { $0 + abs($1 - m) }
            if cost < bestCost {
                bestCost = cost
                best = ((candidate + Int(m.rounded()) % day) + day) % day
            }
        }
        return best
    }

    /// Circular absolute difference between two clock times, in minutes (0 … 720).
    public static func circularDeltaMinutes(_ a: Int, _ b: Int) -> Int {
        let day = 24 * 60
        let d = abs((((a - b) % day) + day) % day)
        return min(d, day - d)
    }

    // MARK: - Internals

    /// Plain median. Even counts average the two central values.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }
}
