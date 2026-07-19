// Sleep-detail metrics — per-stage average HR + a 2.5-min, 3-level body-movement chart (#70).
//
// These are the "detail" half of the composite-sleep-score ticket. Both are pure functions
// of the decoded 0x4c epochs (PROTOCOL §5.3): per-epoch HR `[4]` 🟢 and the `[10:15]` motion
// channel 🟢. The app surfaces `hrAvgPhaseDeep/Light/Rem/Awake` (pp.txt) and a movement chart
// with a "value every 2.5 minutes, three intensity levels" (pp.txt:544f0) — one level per
// 150 s epoch — which is exactly what one 0x4c record spans.

import Foundation

public enum SleepDetailMetrics {

    // MARK: - Per-stage average HR

    /// Average HR (bpm, rounded) within each sleep stage. A sleep-vitals epoch's HR is
    /// attributed to whichever segment contains its timestamp. Stages with no HR coverage are
    /// omitted. Pure over (time, hr) pairs + the night's segments.
    public static func averageHRByStage(records: [BulkRecord],
                                        segments: [SleepSegment],
                                        epoch: Int = Command.syncEpoch) -> [SleepStage: Int] {
        // Staged (non-inBed) segments only — inBed overlaps everything and would double-count.
        let staged = segments.filter { $0.stage != .inBed }
        guard !staged.isEmpty else { return [:] }

        var sums: [SleepStage: Int] = [:]
        var counts: [SleepStage: Int] = [:]
        for r in records where r.layout == .sleepVitals {
            guard let hr = r.heartRate else { continue }
            let t = r.date(epoch: epoch)
            // First containing segment wins (segments tile the night in order).
            guard let seg = staged.first(where: { $0.start <= t && t < $0.end })
                    ?? staged.first(where: { $0.start <= t && t <= $0.end }) else { continue }
            sums[seg.stage, default: 0] += hr
            counts[seg.stage, default: 0] += 1
        }
        var out: [SleepStage: Int] = [:]
        for (stage, count) in counts where count > 0 {
            out[stage] = Int((Double(sums[stage]!) / Double(count)).rounded())
        }
        return out
    }

    // MARK: - Movement timeline (2.5-min, 3 levels)

    /// Three intensity levels for one 2.5-min epoch, from the `[10:15]` motion counts.
    public enum MovementLevel: Int, Equatable, Sendable, CaseIterable {
        case still = 0    // baseline only — no movement
        case light = 1    // some movement
        case active = 2   // substantial movement (likely awake/arousal)
    }

    /// Fraction of the night's OWN moving epochs that read `.active` rather than `.light`. The
    /// still/moving split is absolute (zero intra-epoch motion = still); this only decides where,
    /// WITHIN the movement you actually had, "light" becomes "active" — a distribution split (like
    /// `SleepDetection.motionFloorPercentile`), NOT a physical motion baseline. Deriving it from the
    /// night's own energies means a calm night is never painted `.active` by an absolute cut (the bug
    /// this file used to have) while a genuinely restless night still surfaces its worst epochs.
    public static let activePercentile = 0.80

    public struct MovementEpoch: Equatable, Sendable {
        public let time: Date
        public let level: MovementLevel
        public let magnitude: Int   // summed non-baseline motion (for tooltips/debug)
        public init(time: Date, level: MovementLevel, magnitude: Int) {
            self.time = time; self.level = level; self.magnitude = magnitude
        }
    }

    /// Per-epoch movement levels across the records, optionally scoped to a window. One entry
    /// per 0x4c record (≈ every 2.5 min). Idle/unworn epochs read as `.still`.
    /// `activeThreshold`: optional absolute cut on the intra-epoch energy for `.active`. Pass `nil`
    /// (the default) to derive the cut from the night's own movement distribution — production always
    /// does, so there is no hardcoded motion baseline; an explicit value is for deterministic tests.
    public static func movement(records: [BulkRecord],
                                in window: DateInterval? = nil,
                                activeThreshold: Int? = nil,
                                epoch: Int = Command.syncEpoch) -> [MovementEpoch] {
        let scoped = records
            .sorted { $0.counter < $1.counter }
            .filter { r in window.map { $0.contains(r.date(epoch: epoch)) } ?? true }
        let useIntensityFallback = BulkSleep.usesMotionIntensityFallback(scoped)
        let mags = scoped.map { record in
            useIntensityFallback
                ? record.motionIntensityTail.reduce(0) { $0 + Int($1) }
                : epochMotionEnergy(record)
        }
        let cut = activeThreshold ?? derivedActiveCut(mags)
        return zip(scoped, mags).map { r, mag in
            let level: MovementLevel = mag == 0 ? .still : (mag >= cut ? .active : .light)
            return MovementEpoch(time: r.date(epoch: epoch), level: level, magnitude: mag)
        }
    }

    /// Intra-epoch movement energy: how far the five 30-s sub-samples rise above the epoch's OWN
    /// minimum. A constant run — the ring's still/placeholder filler at ANY device level (Gen-2 `01`,
    /// Gen-3 `0f`=15, or a drifted idle; see `BulkRecord.motionIsPlaceholder`) — has zero deviation →
    /// `0` (still). Real motion, whose counts always vary sample-to-sample, rises above its floor.
    /// This replaces the old `$1 == 1` absolute baseline, which read a Gen-3 `0f`=15 placeholder as
    /// maximal motion (5×15 = 75 > 15) and painted every core-sleep epoch `.active` — the "all-orange"
    /// bug. No device-specific baseline constant: the floor is the epoch's own minimum.
    static func epochMotionEnergy(_ r: BulkRecord) -> Int {
        let m = r.motion
        guard let base = m.min() else { return 0 }
        return m.reduce(0) { $0 + Int($1) - Int(base) }
    }

    /// Light/active boundary derived from the night's OWN movement — the `activePercentile` of the
    /// positive (moving) epoch energies. Returns `.max` when nothing moved, so an all-still night has
    /// no `.active` epochs. Fully data-derived; no absolute motion constant.
    static func derivedActiveCut(_ mags: [Int]) -> Int {
        let positive = mags.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return .max }
        let idx = Int((Double(positive.count - 1) * activePercentile).rounded())
        return positive[idx]
    }

    /// Compact movement summary for persistence/display: the per-epoch level series plus
    /// counts. The series is small (≈ a few hundred bytes/night) so it persists as-is, letting
    /// the chart redraw offline without re-fetching the records.
    public struct MovementSummary: Equatable, Sendable {
        public let levels: [Int]    // one MovementLevel.rawValue per epoch
        public let still: Int
        public let light: Int
        public let active: Int
        public var total: Int { still + light + active }
        /// Share of epochs with any movement (light or active), 0…1 — a one-glance "restlessness".
        public var movementFraction: Double {
            total > 0 ? Double(light + active) / Double(total) : 0
        }
    }

    public static func movementSummary(records: [BulkRecord],
                                       in window: DateInterval? = nil,
                                       activeThreshold: Int? = nil,
                                       epoch: Int = Command.syncEpoch) -> MovementSummary {
        let epochs = movement(records: records, in: window, activeThreshold: activeThreshold, epoch: epoch)
        var still = 0, light = 0, active = 0
        for e in epochs {
            switch e.level {
            case .still: still += 1
            case .light: light += 1
            case .active: active += 1
            }
        }
        return MovementSummary(levels: epochs.map { $0.level.rawValue },
                               still: still, light: light, active: active)
    }
}
