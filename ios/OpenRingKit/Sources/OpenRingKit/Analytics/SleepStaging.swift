// Sleep-stage classifier — Awake / Light / Deep / REM from the 0x4c per-epoch
// signals (PROTOCOL.md §5.3). The ring does NOT transmit a hypnogram; the RingConn
// app computes stages on-device from the same vitals we decode, so we approximate
// that proprietary algorithm here with standard consumer-wearable heuristics.
//
// ⚠️ APPROXIMATION, NOT GROUND TRUTH. We have no PSG (or even per-epoch app) labels —
// only the app's NIGHT TOTALS to sanity-check against (see the night of 2026-06-14:
// asleep 7:37, awake 43m, REM 1:42, light 4:45, deep 1:10). So this is tuned to be
// physiologically principled and to roughly partition a night the way a wrist/ring
// tracker would; it is NOT validated to reproduce per-epoch stage timing, and the
// exact Deep/REM split should be read as approximate proportions, not a clinical
// hypnogram.
//
// Signals per 150 s epoch (forward-filled across epochs that drop a reading):
//   • HR  [4]  — the spine of the model. Stage bands are set from the NIGHT'S OWN HR
//                distribution (percentiles of the asleep HR), never absolute bpm, so
//                it generalises across people and nights.
//   • HRV [5]  — RMSSD; fused in as a secondary REM cue via its short-term variability.
//   • motion [10:15] — the awake signal (a moving sleeper is awake).
//
// Stage logic, per asleep epoch (Awake is decided first, from motion):
//   • Deep  — HR near the night's minimum (low percentile) AND low HR variability AND
//             no motion: the calm, consolidated low-HR troughs.
//   • REM   — HR elevated toward waking OR HR/HRV notably variable, but motion ~0
//             (muscle atonia). Variability — not absolute HR — is what separates REM
//             from Light, matching the physiology.
//   • Light — everything else asleep (the remainder).
// Stages persist in real sleep, so short Deep/REM runs are smoothed back to Light to
// avoid single-epoch flapping.

import Foundation

/// Stage-by-stage classifier over a night's `0x4c` `BulkRecord`s. Pure/testable:
/// it takes records, returns `[SleepSegment]`, and touches no I/O.
public enum SleepStaging {

    /// Tunable thresholds. All HR/variability cut-offs are PERCENTILES of the night's
    /// own asleep distribution (plus small absolute floors), so they adapt per night
    /// rather than baking in fixed bpm. Defaults are general heuristics, not fitted to
    /// any single night.
    public struct Tuning: Sendable, Equatable {
        /// Motion magnitude (sum of non-baseline `[10:15]` counts over the epoch) above
        /// which the epoch is Awake. Baseline `01` contributes 0.
        public var awakeMotion: Int
        /// Lower HR percentile (of asleep epochs) bounding Deep — near the night's floor.
        public var deepHRPercentile: Double
        /// Upper HR percentile bounding "HR elevated toward waking" → a REM cue.
        public var remHRPercentile: Double
        /// HR-variability percentile below which an epoch is "calm enough" for Deep.
        public var deepVarPercentile: Double
        /// HR-variability percentile above which an epoch is "variable" → a REM cue.
        public var remVarPercentile: Double
        /// Half-window (epochs each side) for the rolling HR/HRV variability estimate.
        public var variabilityHalfWindow: Int
        /// Non-degeneracy floor for the Deep variability gate, so a flat night still admits
        /// Deep. NOTE: this is on the *blended* variability scale (HR rolling-SD plus
        /// `hrvVarWeight`×HRV rolling-SD), not raw bpm — the threshold is `max(percentile, floor)`
        /// over that same blended pool, so the floor only binds on near-zero-variance nights.
        public var deepVarFloor: Double
        /// Non-degeneracy floor for the REM variability gate (blended scale; see deepVarFloor).
        public var remVarFloor: Double
        /// Minimum consolidated run length (epochs) for Deep; shorter → relabelled Light.
        public var minDeepRunEpochs: Int
        /// Minimum consolidated run length (epochs) for REM; shorter → relabelled Light.
        public var minREMRunEpochs: Int
        /// Minimum Awake run; shorter motion blips inside sleep → relabelled Light.
        public var minAwakeRunEpochs: Int
        /// Weight of HRV short-term variability fused into the variability score (0 = HR
        /// only). Only contributes on epochs where HRV is present.
        public var hrvVarWeight: Double

        public init(awakeMotion: Int = 15,
                    deepHRPercentile: Double = 0.20,
                    remHRPercentile: Double = 0.80,
                    deepVarPercentile: Double = 0.50,
                    remVarPercentile: Double = 0.75,
                    variabilityHalfWindow: Int = 2,
                    deepVarFloor: Double = 2.5,
                    remVarFloor: Double = 3.0,
                    minDeepRunEpochs: Int = 3,
                    minREMRunEpochs: Int = 2,
                    minAwakeRunEpochs: Int = 1,
                    hrvVarWeight: Double = 0.5) {
            self.awakeMotion = awakeMotion
            self.deepHRPercentile = deepHRPercentile
            self.remHRPercentile = remHRPercentile
            self.deepVarPercentile = deepVarPercentile
            self.remVarPercentile = remVarPercentile
            self.variabilityHalfWindow = variabilityHalfWindow
            self.deepVarFloor = deepVarFloor
            self.remVarFloor = remVarFloor
            self.minDeepRunEpochs = minDeepRunEpochs
            self.minREMRunEpochs = minREMRunEpochs
            self.minAwakeRunEpochs = minAwakeRunEpochs
            self.hrvVarWeight = hrvVarWeight
        }

        public static let `default` = Tuning()
    }

    /// Per-stage durations for a night, plus convenience totals. `inBed` is the whole
    /// detected window; `totalAsleep` excludes Awake (and the overlapping inBed span).
    public struct Summary: Equatable, Sendable {
        public let inBed: TimeInterval
        public let awake: TimeInterval
        public let light: TimeInterval
        public let deep: TimeInterval
        public let rem: TimeInterval

        public init(inBed: TimeInterval, awake: TimeInterval,
                    light: TimeInterval, deep: TimeInterval, rem: TimeInterval) {
            self.inBed = inBed; self.awake = awake
            self.light = light; self.deep = deep; self.rem = rem
        }

        /// Time actually asleep = Light + Deep + REM.
        public var totalAsleep: TimeInterval { light + deep + rem }
        /// Sleep efficiency = asleep / in-bed, 0…1 (0 if no in-bed window).
        public var efficiency: Double { inBed > 0 ? totalAsleep / inBed : 0 }

        /// The same numbers in whole minutes, handy for dashboards/sanity checks.
        public var minutes: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int) {
            func m(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
            return (m(inBed), m(awake), m(light), m(deep), m(rem), m(totalAsleep))
        }
    }

    /// Classify a night's records into `inBed` + Awake/Light(core)/Deep/REM segments.
    /// Returns `[]` when no sleep block (≥1 h still) is detected. The first element is
    /// always the `inBed` span; the rest tile the staged epochs in order.
    public static func classify(from records: [BulkRecord],
                                epoch: Int = Command.syncEpoch,
                                tuning: Tuning = .default) -> [SleepSegment] {
        guard let block = BulkSleep.mainSleep(from: records, epoch: epoch) else { return [] }

        // Epochs inside the in-bed window, forward-filling HR/HRV across dropped reads.
        let inBlock = records
            .filter { $0.date(epoch: epoch) >= block.start && $0.date(epoch: epoch) <= block.end }
            .sorted { $0.counter < $1.counter }
        var lastHR: Int?, lastHRV: Int?
        var rows: [(time: Date, hr: Int, hrv: Int?, motion: Int)] = []
        for r in inBlock {
            if let hr = r.heartRate { lastHR = hr }
            if let v = r.hrvRMSSD { lastHRV = v }
            guard let hr = lastHR else { continue }   // skip until the first HR reading
            let motion = r.motion.reduce(0) { $0 + ($1 == 1 ? 0 : Int($1)) }
            rows.append((r.date(epoch: epoch), hr, lastHRV, motion))
        }
        guard rows.count >= 2 else { return [] }

        // --- Variability (rolling SD of HR, optionally fused with HRV) -------------
        let hr = rows.map { Double($0.hr) }
        var variability = rollingSD(hr, half: tuning.variabilityHalfWindow)
        if tuning.hrvVarWeight > 0, rows.contains(where: { $0.hrv != nil }) {
            let hrv = filledForward(rows.map { $0.hrv }).map { Double($0 ?? 0) }
            let hrvVar = rollingSD(hrv, half: tuning.variabilityHalfWindow)
            for i in variability.indices { variability[i] += tuning.hrvVarWeight * hrvVar[i] }
        }

        // --- Night-relative bands from the ASLEEP (non-moving) distribution --------
        let asleep = rows.indices.filter { rows[$0].motion <= tuning.awakeMotion }
        let hrPool = (asleep.count >= 4 ? asleep.map { hr[$0] } : hr).sorted()
        let varPoolRaw = asleep.count >= 4 ? asleep.map { variability[$0] } : variability
        let varPool = varPoolRaw.sorted()

        let deepHR = percentile(hrPool, tuning.deepHRPercentile)
        let remHR = percentile(hrPool, tuning.remHRPercentile)
        let deepVar = max(percentile(varPool, tuning.deepVarPercentile), tuning.deepVarFloor)
        let remVar = max(percentile(varPool, tuning.remVarPercentile), tuning.remVarFloor)

        // --- Per-epoch decision ----------------------------------------------------
        var stages: [SleepStage] = rows.indices.map { i in
            let r = rows[i]
            if r.motion > tuning.awakeMotion { return .awake }
            if hr[i] <= deepHR && variability[i] <= deepVar { return .asleepDeep }
            if hr[i] >= remHR || variability[i] > remVar { return .asleepREM }
            return .asleepCore
        }
        smooth(&stages, tuning)

        // --- Merge consecutive same-stage epochs into segments ---------------------
        var segs = [SleepSegment(start: block.start, end: block.end, stage: .inBed)]
        var i = 0
        while i < rows.count {
            var j = i
            while j + 1 < rows.count && stages[j + 1] == stages[i] { j += 1 }
            // Fully tile [block.start, block.end] so staged segments partition the inBed
            // window (else efficiency is understated): clamp the first segment's start to
            // block.start and the last segment's end to block.end. (Reviewer MINOR fix.)
            let segStart = (i == 0) ? block.start : rows[i].time
            let segEnd = (j + 1 < rows.count) ? rows[j + 1].time : block.end
            segs.append(SleepSegment(start: segStart, end: min(segEnd, block.end), stage: stages[i]))
            i = j + 1
        }
        return segs
    }

    /// Total time spent in each stage across the night. The overlapping `inBed` span is
    /// excluded so the asleep stages sum to time-asleep.
    public static func stageTotals(_ segments: [SleepSegment]) -> [SleepStage: TimeInterval] {
        var out: [SleepStage: TimeInterval] = [:]
        for s in segments where s.stage != .inBed { out[s.stage, default: 0] += s.duration }
        return out
    }

    /// Roll the segments up into a `Summary` (per-stage durations + total asleep).
    public static func summary(_ segments: [SleepSegment]) -> Summary {
        let t = stageTotals(segments)
        let awake: TimeInterval = t[.awake] ?? 0
        let light: TimeInterval = t[.asleepCore] ?? 0
        let deep: TimeInterval = t[.asleepDeep] ?? 0
        let rem: TimeInterval = t[.asleepREM] ?? 0
        let staged = awake + light + deep + rem
        let inBed = segments.first { $0.stage == .inBed }?.duration ?? staged
        return Summary(inBed: inBed, awake: awake, light: light, deep: deep, rem: rem)
    }

    /// Convenience: total time asleep (Light + Deep + REM) for a set of segments.
    public static func totalAsleep(_ segments: [SleepSegment]) -> TimeInterval {
        let t = stageTotals(segments)
        return (t[.asleepCore] ?? 0) + (t[.asleepDeep] ?? 0) + (t[.asleepREM] ?? 0)
    }

    // MARK: - Helpers

    /// Relabel sub-minimum Deep/REM/Awake runs to Light, so stages don't flap epoch to
    /// epoch (real stages persist for minutes).
    private static func smooth(_ stages: inout [SleepStage], _ t: Tuning) {
        let n = stages.count
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && stages[j + 1] == stages[i] { j += 1 }
            let run = j - i + 1
            let minRun: Int?
            switch stages[i] {
            case .asleepDeep: minRun = t.minDeepRunEpochs
            case .asleepREM:  minRun = t.minREMRunEpochs
            case .awake:      minRun = t.minAwakeRunEpochs
            default:          minRun = nil
            }
            if let m = minRun, run < m {
                for k in i ... j { stages[k] = .asleepCore }
            }
            i = j + 1
        }
    }

    /// Centered rolling standard deviation over a ±`half`-epoch window.
    private static func rollingSD(_ xs: [Double], half: Int) -> [Double] {
        let n = xs.count
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let s = max(0, i - half), e = min(n - 1, i + half)
            let w = xs[s ... e]
            let mean = w.reduce(0, +) / Double(w.count)
            let varr = w.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(w.count)
            out[i] = varr.squareRoot()
        }
        return out
    }

    /// Forward-then-backward fill of nil gaps, so a sparse HRV channel has no artificial
    /// jumps where readings drop out.
    private static func filledForward(_ xs: [Int?]) -> [Int?] {
        var out = xs
        var last: Int?
        for i in out.indices { if let v = out[i] { last = v } else { out[i] = last } }
        var next: Int?
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            if let v = out[i] { next = v } else { out[i] = next }
        }
        return out
    }

    /// Value at quantile `q` (0…1) of a pre-sorted array (nearest-rank). 0 if empty.
    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((q * Double(sorted.count - 1)).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }
}
