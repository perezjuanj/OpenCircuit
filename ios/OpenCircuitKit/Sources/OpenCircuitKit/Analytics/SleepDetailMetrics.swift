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

    /// Motion threshold (summed non-baseline `[10:15]` counts) above which an epoch is `.active`
    /// rather than `.light`. `1` per sub-sample is the still baseline and contributes 0; this
    /// `.active` cut-off aligns with `SleepStaging`'s awake-motion default, so a movement spike
    /// the chart calls "active" is the same energy that drives an Awake classification.
    public static let activeThreshold = 15

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
    public static func movement(records: [BulkRecord],
                                in window: DateInterval? = nil,
                                activeThreshold: Int = activeThreshold,
                                epoch: Int = Command.syncEpoch) -> [MovementEpoch] {
        records
            .sorted { $0.counter < $1.counter }
            .compactMap { r in
                let t = r.date(epoch: epoch)
                if let w = window, !w.contains(t) { return nil }
                let mag = r.motion.reduce(0) { $0 + ($1 == 1 ? 0 : Int($1)) }
                let level: MovementLevel = mag == 0 ? .still : (mag > activeThreshold ? .active : .light)
                return MovementEpoch(time: t, level: level, magnitude: mag)
            }
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
                                       activeThreshold: Int = activeThreshold,
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
