// Sleep/active period detection — ported from openwhoop-algos/src/activity.rs.
// Classifies a timeline of stillness readings into Sleep/Active periods, then
// `findSleep` extracts the main sleep block. Device-agnostic.
//
// Two front-ends feed the same core pipeline:
//   • detectFromGravity — a 3-axis gravity vector (openwhoop's original input).
//   • detectFromMotion  — RingConn's 0x4c [10:15] per-30 s motion counts (🟢,
//     PROTOCOL.md §5.3). On the 2026-06-13 night this recovers the in-bed window
//     00:33→09:34 vs the app's ~00:32→09:30 (time-in-bed). This is the real wiring.
// Finer Awake/Light/Deep/REM staging needs an HR-based model (see BulkSleep) and
// is not part of openwhoop's stillness detection.

import Foundation

/// One reading on the activity timeline. `gravity == nil` means no gravity data,
/// which the algorithm treats as movement (active), matching openwhoop.
public struct GravitySample: Sendable, Equatable {
    public let time: Date
    public let gravity: SIMD3<Float>?
    public init(time: Date, gravity: SIMD3<Float>?) {
        self.time = time
        self.gravity = gravity
    }
}

/// One reading on the motion timeline: a per-30 s movement magnitude (the 0x4c
/// [10:15] motion count). Unworn/no-measurement samples carry `.greatestFiniteMagnitude`.
public struct MotionSample: Sendable, Equatable {
    public let time: Date
    public let movement: Float
    public init(time: Date, movement: Float) {
        self.time = time
        self.movement = movement
    }
}

/// One skin-temperature reading on the wear-detection timeline (#41). Skin temp rides
/// the 0x10/0x87 descriptor (PROTOCOL.md §5.4), not the 0x4c sleep records, so callers
/// thread the night's persisted temperature samples in alongside the motion timeline.
public struct TemperatureSample: Sendable, Equatable {
    public let time: Date
    public let celsius: Double
    public init(time: Date, celsius: Double) {
        self.time = time
        self.celsius = celsius
    }
}

public enum Activity: Equatable, Sendable { case sleep, active }

public struct ActivityPeriod: Equatable, Sendable {
    public let activity: Activity
    public let start: Date
    public let end: Date

    public init(activity: Activity, start: Date, end: Date) {
        self.activity = activity
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var isActive: Bool { activity == .active }

    // Thresholds (from openwhoop, "notebook analysis").
    static let activityChangeThreshold: TimeInterval = 15 * 60
    static let minSleepDuration: TimeInterval = 60 * 60
    public static let maxSleepPause: TimeInterval = 60 * 60
    static let gravityStillThreshold: Float = 0.01     // g
    static let gravityWindowMinutes = 15
    static let gravityStillFraction: Float = 0.70
    static let gravityMaxGap: TimeInterval = 20 * 60
    /// Motion-count stillness threshold for the 0x4c [10:15] channel (🟢 grounded:
    /// recovers the captured night's in-bed window). Baseline `01` = still.
    static let motionStillThreshold: Float = 2

    /// Minimum skin temperature for the ring to count as WORN (🟡 heuristic, NOT yet
    /// ground-truthed — validate against a known charging-night capture). A worn Gen-2
    /// reads ~30–34 °C; off-wrist / on the charger it falls toward room ambient (~20–24 °C).
    /// 28 °C is a conservative midpoint. Used ONLY to exclude cold "still" blocks from
    /// sleep (#41), never to add sleep — so a miss costs at worst an unfiltered charger block.
    public static let wornMinTemperatureC: Double = 28.0

    private struct Temp { var activity: Activity; var start: Date; var end: Date }

    /// First Sleep period longer than `minSleepDuration`, removed from `events`.
    public static func findSleep(_ events: inout [ActivityPeriod]) -> ActivityPeriod? {
        while !events.isEmpty {
            let event = events.removeFirst()
            if event.activity == .sleep && event.duration > minSleepDuration { return event }
        }
        return nil
    }

    /// Detect Sleep/Active periods from a gravity-vector timeline.
    public static func detectFromGravity(_ history: [GravitySample]) -> [ActivityPeriod] {
        guard history.count >= 2 else { return [] }
        // Magnitude of change between consecutive gravity vectors (first = 0).
        // Missing gravity -> treat as max movement (active).
        var deltas: [Float] = [0]
        deltas.reserveCapacity(history.count)
        for i in 1 ..< history.count {
            if let a = history[i - 1].gravity, let b = history[i].gravity {
                let d = a - b
                deltas.append((d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
            } else {
                deltas.append(.greatestFiniteMagnitude)
            }
        }
        return detect(times: history.map(\.time), deltas: deltas,
                      stillThreshold: gravityStillThreshold)
    }

    /// Detect Sleep/Active periods from RingConn's per-30 s motion counts (the
    /// 0x4c [10:15] channel; PROTOCOL.md §5.3). `movement` is the motion count
    /// directly — it already IS a movement magnitude, so it feeds the same core
    /// as the gravity deltas. Unworn/no-measurement samples should be passed as a
    /// large value (active) by the caller.
    public static func detectFromMotion(_ history: [MotionSample]) -> [ActivityPeriod] {
        guard history.count >= 2 else { return [] }
        return detect(times: history.map(\.time), deltas: history.map(\.movement),
                      stillThreshold: motionStillThreshold)
    }

    /// Sleep/Active detection (motion) with a WEAR GATE (#41): any detected `.sleep` block
    /// whose median skin temperature indicates the ring was off-wrist / on the charger is
    /// reclassified `.active`, so a perfectly still ring on the nightstand can't masquerade
    /// as a night of sleep. A `.sleep` block with no temperature coverage is left as
    /// detected — absence of data is not evidence of being unworn. `temperatureSamples`
    /// may be unordered and sparse; only readings inside a block are considered.
    public static func detectFromMotion(_ history: [MotionSample],
                                        temperatureSamples: [TemperatureSample],
                                        wornMinC: Double = wornMinTemperatureC) -> [ActivityPeriod] {
        let periods = detectFromMotion(history)
        guard !temperatureSamples.isEmpty else { return periods }
        return periods.map { p in
            guard p.activity == .sleep else { return p }
            let inside = temperatureSamples
                .filter { $0.time >= p.start && $0.time <= p.end }
                .map(\.celsius)
                .sorted()
            guard !inside.isEmpty else { return p }   // no coverage → trust the motion verdict
            let median = inside[inside.count / 2]
            return median < wornMinC
                ? ActivityPeriod(activity: .active, start: p.start, end: p.end)
                : p
        }
    }

    /// Shared core: classify a stillness-magnitude timeline into Sleep/Active runs.
    /// `deltas[i]` < `stillThreshold` => still at sample i. Faithful to activity.rs.
    private static func detect(times: [Date], deltas: [Float],
                               stillThreshold: Float) -> [ActivityPeriod] {
        guard times.count == deltas.count, times.count >= 2 else { return [] }

        // Median sample interval (seconds), bounded like openwhoop.
        var diffs: [Int] = []
        for i in 1 ..< times.count {
            let d = Int(times[i].timeIntervalSince(times[i - 1]))
            if d > 0 && d < 300 { diffs.append(d) }
        }
        diffs.sort()
        let avgIntervalSecs = max(1, diffs.isEmpty ? 60 : diffs[diffs.count / 2])
        let windowSize = max((gravityWindowMinutes * 60) / avgIntervalSecs, 3)

        // Rolling stillness classification (centered window).
        let n = deltas.count
        var isSleep = [Bool](repeating: false, count: n)
        let half = windowSize / 2
        for i in 0 ..< n {
            let start = i >= half ? i - half : 0
            let end = min(i + half + 1, n)
            let window = deltas[start ..< end]
            let still = window.filter { $0 < stillThreshold }.count
            isSleep[i] = Float(still) / Float(window.count) >= gravityStillFraction
        }

        // Segment into runs; break on class change or a data gap > maxGap.
        var temps: [Temp] = []
        var runStart = 0
        for i in 1 ... n {
            let endOfData = (i == n)
            let classChange = !endOfData && isSleep[i] != isSleep[runStart]
            let gapBreak = !endOfData &&
                times[i].timeIntervalSince(times[i - 1]) > gravityMaxGap
            if endOfData || classChange || gapBreak {
                temps.append(Temp(activity: isSleep[runStart] ? .sleep : .active,
                                  start: times[runStart], end: times[i - 1]))
                if !endOfData { runStart = i }
            }
        }

        return filterMerge(temps).map {
            ActivityPeriod(activity: $0.activity, start: $0.start, end: $0.end)
        }
    }

    /// Merge sub-`activityChangeThreshold` segments into neighbors (openwhoop logic).
    private static func filterMerge(_ input: [Temp]) -> [Temp] {
        guard !input.isEmpty else { return [] }
        var activities = input
        var merged: [Temp] = []
        var i = 0
        while i < activities.count {
            let current = activities[i]
            if current.end.timeIntervalSince(current.start) < activityChangeThreshold {
                if i > 0, i + 1 < activities.count,
                   activities[i - 1].activity == activities[i + 1].activity, !merged.isEmpty {
                    let prev = merged.removeLast()
                    merged.append(Temp(activity: prev.activity, start: prev.start, end: activities[i + 1].end))
                    i += 1 // skip the next; it's merged
                } else if i + 1 < activities.count {
                    activities[i + 1] = Temp(activity: activities[i + 1].activity,
                                             start: current.start, end: activities[i + 1].end)
                } else if !merged.isEmpty {
                    let prev = merged.removeLast()
                    merged.append(Temp(activity: prev.activity, start: prev.start, end: current.end))
                }
            } else {
                merged.append(current)
            }
            i += 1
        }
        return merged
    }
}
