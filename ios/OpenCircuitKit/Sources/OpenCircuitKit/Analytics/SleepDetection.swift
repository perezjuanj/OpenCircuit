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
    public static let gravityMaxGap: TimeInterval = 20 * 60
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

    /// The main overnight sleep block as the CLUSTERED span of sleep periods: chain consecutive
    /// `.sleep` periods whose intervening gap is shorter than `maxPause` (a brief awakening or a
    /// posture shift, not a true wake), then return the longest cluster's `[firstStart, lastEnd]`
    /// when it spans at least `minSleepDuration`. Brief awakenings inside the span stay as `.active`
    /// periods so the caller still surfaces them as awake sub-segments. Without this, a night broken
    /// by a >15-min stir (Gen 2) or a posture-driven motion-floor step (Gen 3, where each step reads
    /// briefly "active" until the rolling floor catches up) collapses to just its longest fragment,
    /// badly under-counting the night. `maxSleepPause` was defined for exactly this but unused until
    /// now. A clean single-block night (every existing single-night test) returns that block verbatim.
    public static func mainSleepBlock(_ periods: [ActivityPeriod],
                                      maxPause: TimeInterval = maxSleepPause) -> ActivityPeriod? {
        let sleeps = periods.filter { $0.activity == .sleep }.sorted { $0.start < $1.start }
        guard !sleeps.isEmpty else { return nil }
        var clusters: [(start: Date, end: Date)] = []
        for s in sleeps {
            if let last = clusters.last, s.start.timeIntervalSince(last.end) < maxPause {
                clusters[clusters.count - 1].end = max(last.end, s.end)
            } else {
                clusters.append((s.start, s.end))
            }
        }
        guard let best = clusters.max(by: {
            $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
        }), best.end.timeIntervalSince(best.start) > minSleepDuration else { return nil }
        return ActivityPeriod(activity: .sleep, start: best.start, end: best.end)
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
    ///
    /// The motion channel has a device-dependent IDLE FLOOR: a still Gen-2 ring reads ~`1`,
    /// but a still Gen-3 ring (FR05.008, "RingConn Gen3-C384") reads a constant ~`15–16` even
    /// in deep sleep (🟢, confirmed on an overnight Gen-3 capture, 2026-06-23). An ABSOLUTE
    /// `motionStillThreshold` calibrated to Gen 2's `1` therefore classified EVERY Gen-3 epoch
    /// as movement → no sleep block detected → blank Sleep/HRV/Respiratory cards. So measure
    /// stillness RELATIVE to the night's OWN floor: subtract `motionBaseline` (a low percentile
    /// of the worn samples) so whatever the device idles at maps to ~0, then apply the same
    /// threshold. A constant-floor timeline (every existing test, an idle ring) maps to all-zero
    /// → still, exactly as before — so this is a no-op for Gen 2 while fixing Gen 3.
    public static func detectFromMotion(_ history: [MotionSample]) -> [ActivityPeriod] {
        guard history.count >= 2 else { return [] }
        // The rolling floor and `detect` both assume a time-ordered timeline; sort defensively so an
        // unsorted caller (e.g. the nap path feeds the concatenated 0x00+0x03 channels) is correct.
        let history = history.sorted { $0.time < $1.time }
        let relative = motionAboveLocalFloor(history)
        return detect(times: history.map(\.time), deltas: relative,
                      stillThreshold: motionStillThreshold)
    }

    /// Target span of the rolling idle-floor window for DETECTION (finding the in-bed block).
    /// Long enough that a brief movement burst never lifts its own local floor and that the block
    /// boundaries stay stable; drift between plateaus is handled by `maxSleepPause` bridging.
    static let motionFloorWindowSeconds: TimeInterval = 30 * 60
    /// Shorter floor window for per-epoch STAGING (awake-vs-asleep WITHIN the block). The block is
    /// already established, so here we want the floor to follow a posture-driven step QUICKLY —
    /// otherwise the ~15-min lag of the longer window reads each Gen-3 motion-floor step as a false
    /// awakening (validated against ground truth: a tester's night measured 55 min "awake" at the
    /// 30-min window vs ~20 min — matching the RingConn-app/Fitbit ~0 — at this shorter one).
    static let motionFloorWindowSecondsStaging: TimeInterval = 15 * 60
    /// Low percentile used as the "idle" estimate inside the window.
    static let motionFloorPercentile: Double = 0.10

    /// Movement magnitude measured ABOVE a LOCAL, rolling idle floor.
    ///
    /// The 0x4c motion channel idles at a device-dependent — and even time-varying — level: a
    /// still Gen-2 ring reads ~`1`, a still Gen-3 ring reads ~`15`, and a Gen-3 ring's idle reading
    /// DRIFTS across the night as sleeping posture changes (16→24→39 on the 2026-06-23 FR05.008
    /// capture). An absolute threshold can't serve all three, and a single per-night baseline still
    /// splits a drifting night into false "active" stretches. So at each sample we subtract a low
    /// percentile of the motion within a ~30-min window around it: a flat plateau at ANY level maps
    /// to ~0 (still), while a genuine burst — short relative to the window — rises above its local
    /// floor and stays active. A constant-floor timeline (Gen 2's flat `1`, every existing test, an
    /// idle ring) maps to all-zero exactly as the old absolute threshold did → no-op for Gen 2.
    static func motionAboveLocalFloor(_ history: [MotionSample]) -> [Float] {
        let mags = history.map(\.movement)
        let floor = rollingLowPercentile(mags, times: history.map(\.time),
                                         windowSeconds: motionFloorWindowSeconds,
                                         percentile: motionFloorPercentile)
        return zip(mags, floor).map { max(0, $0 - $1) }
    }

    /// Per-index low percentile over a centered time window. Unworn `.greatestFiniteMagnitude`
    /// sentinels are excluded from the percentile (they'd peg it high). A window with NO worn samples
    /// returns a `0` floor, so an unworn sentinel de-floors to itself (`max(0, GFM - 0)` = GFM →
    /// active) rather than collapsing to "still". O(n·w); n is one night of 30-s samples, so trivial.
    static func rollingLowPercentile(_ values: [Float], times: [Date],
                                     windowSeconds: TimeInterval, percentile: Double) -> [Float] {
        let n = values.count
        guard n > 0, times.count == n else { return values }
        let half = windowSeconds / 2
        var out = [Float](repeating: 0, count: n)
        // Window bounds advance monotonically with i (times are sorted), so this is ~O(n) amortized.
        var lo = 0, hi = 0
        for i in 0 ..< n {
            while lo < n && times[lo] < times[i].addingTimeInterval(-half) { lo += 1 }
            if hi < lo { hi = lo }
            while hi < n && times[hi] <= times[i].addingTimeInterval(half) { hi += 1 }
            let worn = values[lo ..< hi].filter { $0 < .greatestFiniteMagnitude }.sorted()
            out[i] = worn.isEmpty ? 0
                : worn[Int((Double(worn.count - 1) * percentile).rounded())]
        }
        return out
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
