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
//
// #41 — wear / charging detection (analytics part):
// Both detectFromMotion overloads accept optional `temperatureSamples`. Any "sleep"
// period where skin temperature indicates the ring is off-wrist / on the charger is
// reclassified as `.active`. BulkSleep.mainSleep / BulkSleep.sleepSegments thread
// the temperature samples through the MotionSample path (the real ring data path).
//
// TODO(#41 protocol): also gate on the charging-flag byte from the 0x10/0x87
// descriptor once the BLE RingSession lane investigates PROTOCOL.md §5.4 [2].
// That investigation is protocol-blocked — do NOT edit RingSession here.

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

    // MARK: - Temperature-gated entry points (#41)

    /// Classify Sleep/Active periods from gravity + optional skin-temperature samples.
    ///
    /// #41 analytics entry point for the openwhoop gravity path. Any "sleep" period
    /// where the ring was not worn (skin temperature below the worn threshold) is
    /// reclassified as `.active` so charger / nightstand epochs do not inflate the
    /// sleep score or pollute HealthKit.
    ///
    /// If `temperatureSamples` is empty the result is identical to `detectFromGravity`.
    public static func detectFromMotion(
        _ history: [GravitySample],
        temperatureSamples: [TemperatureSample]
    ) -> [ActivityPeriod] {
        var periods = detectFromGravity(history)
        guard !temperatureSamples.isEmpty else { return periods }
        periods = periods.map { period in
            guard period.activity == .sleep else { return period }
            if WearDetection.wornState(during: period, from: temperatureSamples) == .notWorn {
                return ActivityPeriod(activity: .active, start: period.start, end: period.end)
            }
            return period
        }
        return periods
    }

    /// Classify Sleep/Active periods from RingConn's per-30 s motion counts +
    /// optional skin-temperature samples.
    ///
    /// #41 analytics entry point for the real ring data path (called by
    /// `BulkSleep.mainSleep` and `BulkSleep.sleepSegments`). Any "sleep" period
    /// where the ring was not worn (skin temperature below the worn threshold) is
    /// reclassified as `.active` so charger / nightstand epochs do not inflate the
    /// sleep score or pollute HealthKit.
    ///
    /// When `temperatureSamples` is empty the result is identical to
    /// `detectFromMotion(_ history: [MotionSample])`.
    public static func detectFromMotion(
        _ history: [MotionSample],
        temperatureSamples: [TemperatureSample]
    ) -> [ActivityPeriod] {
        var periods = detectFromMotion(history)
        guard !temperatureSamples.isEmpty else { return periods }
        periods = periods.map { period in
            guard period.activity == .sleep else { return period }
            if WearDetection.wornState(during: period, from: temperatureSamples) == .notWorn {
                return ActivityPeriod(activity: .active, start: period.start, end: period.end)
            }
            return period
        }
        return periods
    }
}

// MARK: - Wear detection (#41)

/// Whether the ring is in skin contact with the wearer.
public enum WornState: Equatable, Sendable {
    case worn
    case notWorn    // off-wrist or on the charger
}

/// One skin-temperature reading from the ring.
/// The source is the temperature bytes in the 0x4c records (🔴 positions unconfirmed,
/// pending PROTOCOL.md §6 item 2 capture). The struct is device-agnostic; callers
/// supply whichever temperature they decode from the ring.
public struct TemperatureSample: Equatable, Sendable {
    public let time: Date
    public let tempCelsius: Double

    public init(time: Date, tempCelsius: Double) {
        self.time = time
        self.tempCelsius = tempCelsius
    }
}

/// Temperature-based ring-wear heuristic (#41).
///
/// A worn ring sits against the skin and reads ~30–34 °C (🟡 heuristic; no
/// ground-truth capture yet). Off-wrist or on the charger it drifts toward
/// ambient (~18–26 °C indoors). The minimum worn threshold of 30 °C is
/// deliberately conservative: a cold-room wrist might hit 29 °C briefly, but
/// a charger will always be well below 30 °C after the first few minutes.
///
/// TODO(#41 protocol): once the 0x10/0x87 descriptor's charging-flag byte ([2]
/// state enum, PROTOCOL.md §5.4 🟡) is confirmed, prefer that signal over
/// temperature for instant detection without warm-up lag. That investigation
/// belongs to the BLE RingSession lane — do not modify RingSession here.
public enum WearDetection {

    /// Below this, the ring is assumed off-wrist / charging (🟡 heuristic).
    public static let minWornTempC: Double = 30.0

    /// Worn state for a single temperature reading.
    public static func state(tempCelsius: Double) -> WornState {
        tempCelsius >= minWornTempC ? .worn : .notWorn
    }

    /// Worn state inferred from temperature samples covering an ActivityPeriod.
    ///
    /// Average temperature across samples whose timestamp falls within the period.
    /// Returns `.worn` if there are no samples in the window (fail-open: do not
    /// discard data we cannot confirm is bogus).
    public static func wornState(
        during period: ActivityPeriod,
        from samples: [TemperatureSample]
    ) -> WornState {
        let inWindow = samples.filter { $0.time >= period.start && $0.time <= period.end }
        guard !inWindow.isEmpty else { return .worn }
        let avg = inWindow.map { $0.tempCelsius }.reduce(0.0, +) / Double(inWindow.count)
        return state(tempCelsius: avg)
    }
}
