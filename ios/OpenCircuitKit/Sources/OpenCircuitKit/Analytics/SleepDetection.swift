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

/// One heart-rate reading on the HR-gate timeline. HR rides the 0x4c epoch head (byte[4], 🟢
/// ALL-DAY HR; PROTOCOL.md §5.3), so callers build this from the SAME records that feed the
/// motion timeline — no extra channel is needed. Used to reject an awake-but-still block from sleep.
public struct HeartRateSample: Sendable, Equatable {
    public let time: Date
    public let bpm: Int
    public init(time: Date, bpm: Int) {
        self.time = time
        self.bpm = bpm
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

    /// HR gate (awake-but-still detection). A still `.sleep` block whose MEDIAN heart rate exceeds
    /// the night's resting floor by more than `awakeHRMarginBPM` is reclassified `.active`. The
    /// motion detector is blind to a still-but-AWAKE period — sitting out late, a long sedentary
    /// evening — because the hand isn't moving, and the wear gate can't catch it (the ring is worn).
    /// HR can: a real sleep block settles near the night's own resting floor, while an awake-still
    /// block runs well above it. 🟢 grounded on the 2026-06-23 night, where the app staged a
    /// 22:22–23:34 "sleep" block whose HR was 97–120 bpm (~35 bpm over the night's ~71 bpm floor)
    /// while the user was out. Conservative margin so genuine light/REM elevations are never
    /// rejected; like the wear gate, the HR gate only REMOVES sleep, never adds it.
    public static let awakeHRMarginBPM = 25
    /// Low percentile of the night's worn HR used as the resting-floor estimate — self-calibrating
    /// per person, and robust to a mostly-awake night because it picks the low tail.
    static let sleepHRFloorPercentile: Double = 0.10
    /// Minimum HR readings (globally, and inside a block) before the gate will act, so a single
    /// stray reading can neither set a bogus floor nor flip a block.
    static let minHRSamplesForGate = 3

    /// Sleep-vitals rescue (the SYMMETRIC counterpart to the HR gate). The motion detector is blind
    /// to a still-but-AWAKE period (→ HR gate). It is EQUALLY blind the other way: a MOVING-but-ASLEEP
    /// stretch — a restless pre-wake morning of posture shifts and limb movement — reads as motion and
    /// is classified `.active`, truncating the night at the first stir even though the sleeper is still
    /// down. The `motionAboveLocalFloor` normaliser makes this worse: a night that is dead-still for
    /// hours then moves more before waking has a very low floor, so the morning plateau is measured as
    /// large motion. HR/HRV catch what motion can't — during that stretch the ring keeps emitting
    /// sleep-vitals epochs (HRV present, PROTOCOL §5.3) at a heart rate still near the night's resting
    /// floor, whereas true wake shows the sleep-vitals stream thin out AND HR climb. 🟢 grounded on the
    /// 2026-07-04 night (Gen 2): the ring recorded continuous sleep-vitals 06:49→08:30 (HR ~53, HRV on
    /// ~half the epochs) that motion mis-scored as 1h40m of "active", cutting a real 7h32m night to
    /// 5h44m. So we EXTEND the detected night's tail forward one epoch at a time while the trailing
    /// window still looks like sleep-vitals sleep, and stop at the first sustained wake. Like the wear
    /// and HR gates this is conservative and one-directional — it only ever grows the night's TAIL from
    /// where motion already found sleep; it never seeds a new block, never touches the pre-onset
    /// evening, and is gated by HR so it cannot rescue a genuine (elevated-HR) wake.
    ///
    /// Trailing window over which the tail-extension tests "still sleeping": short enough to stop
    /// promptly at true wake, long enough to bridge the ~2.5-min activity/sleep-vitals epoch interleave.
    static let rescueWindow: TimeInterval = 15 * 60
    /// Minimum sleep-vitals (HRV-bearing) epochs required inside the trailing window for the tail to
    /// keep extending. Below this the ring is no longer measuring sleep vitals at cadence → treat as
    /// awake and stop. Two epochs ≈ the sleep-vitals cadence across a 15-min window.
    static let rescueMinHRVInWindow = 2
    /// Nominal epoch cadence used to step the tail extension. Kept local so this detector stays
    /// device-agnostic (openwhoop port); the RingConn 0x4c step is 150 s (BulkRecord.epochSeconds).
    static let rescueEpochStep: TimeInterval = 150

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

    /// Sleep/Active detection (motion) with two post-filters that only ever REMOVE sleep, never add it:
    ///   • WEAR GATE (#41): a `.sleep` block whose median skin temperature reads off-wrist / on the
    ///     charger is reclassified `.active`, so a perfectly still ring on the nightstand can't
    ///     masquerade as a night. A block with no temperature coverage is left as detected — absence
    ///     of data is not evidence of being unworn.
    ///   • HR GATE: a still block whose median HR runs well above the night's resting floor (an
    ///     awake-but-still period — sitting out late, a long sedentary evening) is reclassified
    ///     `.active`. The ring is WORN here, so the wear gate can't catch it; HR is the discriminator.
    /// `temperatureSamples` / `heartRateSamples` may be unordered and sparse; only readings inside a
    /// block are considered, and an empty set makes that gate a no-op.
    public static func detectFromMotion(_ history: [MotionSample],
                                        temperatureSamples: [TemperatureSample],
                                        heartRateSamples: [HeartRateSample] = [],
                                        sleepVitalTimes: [Date] = [],
                                        wornMinC: Double = wornMinTemperatureC,
                                        awakeHRMargin: Int = awakeHRMarginBPM) -> [ActivityPeriod] {
        let base = detectFromMotion(history)
        let wearGated = wearGate(base, temperatureSamples, wornMinC: wornMinC)
        let hrGated = heartRateGate(wearGated, heartRateSamples, marginBPM: awakeHRMargin)
        return sleepVitalsRescue(hrGated, heartRateSamples, sleepVitalTimes, marginBPM: awakeHRMargin)
    }

    /// The night's resting-floor HR estimate: `sleepHRFloorPercentile` over the DISTINCT HR levels
    /// seen tonight (deduped so a long high-HR stretch can't drag the floor up by sheer count — see
    /// `heartRateGate`). `nil` when there aren't enough readings to judge.
    static func sleepHRFloor(_ hr: [HeartRateSample]) -> Int? {
        guard hr.count >= minHRSamplesForGate else { return nil }
        let levels = Array(Set(hr.map(\.bpm))).sorted()
        guard !levels.isEmpty else { return nil }
        return levels[Int((Double(levels.count - 1) * sleepHRFloorPercentile).rounded())]
    }

    /// Reclassify a `.sleep` block whose median skin temperature reads unworn (< `wornMinC`) as
    /// `.active` (#41). A block with no temperature coverage is left as detected.
    private static func wearGate(_ periods: [ActivityPeriod], _ temperatureSamples: [TemperatureSample],
                                 wornMinC: Double) -> [ActivityPeriod] {
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

    /// Reclassify an awake-but-still `.sleep` block (median HR ≫ the night's resting floor) as
    /// `.active`. The floor is `sleepHRFloorPercentile` of ALL worn HR in the timeline (byte[4] from
    /// every 0x4c epoch, 🟢). A block with fewer than `minHRSamplesForGate` readings inside it is
    /// left as detected — too little HR to judge — mirroring the wear gate's "absence ≠ awake". No
    /// HR at all → no-op (motion-only result unchanged), so this never regresses a night the ring
    /// reported with sparse/zero HR.
    private static func heartRateGate(_ periods: [ActivityPeriod], _ hr: [HeartRateSample],
                                      marginBPM: Int) -> [ActivityPeriod] {
        // Resting-floor estimate over the DISTINCT HR levels seen tonight, NOT the raw samples: a long
        // awake-still stretch contributes many high readings that would drag a count-weighted percentile
        // up and so hide itself. Deduping to levels gives the night's few low readings equal weight, so
        // the floor tracks the body's lowest sustained level even when highs dominate by count. (On the
        // 2026-06-23 night this yields ~74 bpm vs ~102 for a raw p10 — the difference between catching
        // the 108 bpm evening block and missing it.) Block medians below stay count-weighted: "typical
        // HR in this block" is the right question there, "lowest level reached tonight" the right one here.
        guard let floor = sleepHRFloor(hr) else { return periods }
        let threshold = floor + marginBPM
        return periods.map { p in
            guard p.activity == .sleep else { return p }
            let inside = hr.filter { $0.time >= p.start && $0.time <= p.end }.map(\.bpm).sorted()
            guard inside.count >= minHRSamplesForGate else { return p }
            let median = inside[inside.count / 2]
            return median > threshold
                ? ActivityPeriod(activity: .active, start: p.start, end: p.end)
                : p
        }
    }

    /// Extend the detected night's TAIL forward through a moving-but-asleep morning (see `rescueWindow`
    /// doc). Grows the main sleep block's end epoch-by-epoch across the `.active` period that abuts it,
    /// for as long as the trailing `rescueWindow` still looks like sleep-vitals sleep — HR at/near the
    /// night's resting floor AND the ring still emitting ≥ `rescueMinHRVInWindow` sleep-vitals epochs —
    /// then stops at the first sustained wake. One-directional and HR-gated: it only ever converts
    /// `.active`→`.sleep` starting from where motion already found the night, so it can neither seed a
    /// spurious block nor rescue a genuine elevated-HR wake. No HR or no sleep-vitals coverage → no-op.
    private static func sleepVitalsRescue(_ periods: [ActivityPeriod], _ hr: [HeartRateSample],
                                          _ sleepVitalTimes: [Date], marginBPM: Int) -> [ActivityPeriod] {
        guard !sleepVitalTimes.isEmpty, let floor = sleepHRFloor(hr),
              let block = mainSleepBlock(periods) else { return periods }
        let threshold = floor + marginBPM
        let hrv = sleepVitalTimes.sorted()

        // The active period that begins (within one epoch step) at the main block's end — the morning
        // stretch right after detected sleep. Nothing else is eligible: not the pre-onset evening, not a
        // disconnected daytime block.
        let step = rescueEpochStep
        guard let tail = periods.first(where: {
            $0.activity == .active && $0.end > block.end
                && abs($0.start.timeIntervalSince(block.end)) <= step * 2
        }) else { return periods }

        // Walk the tail one epoch at a time; keep extending while the trailing window is sleep-like.
        func windowIsSleeplike(endingAt t: Date) -> Bool {
            let lo = t.addingTimeInterval(-rescueWindow)
            let hrInWin = hr.filter { $0.time > lo && $0.time <= t }.map(\.bpm).sorted()
            guard hrInWin.count >= minHRSamplesForGate else { return false }
            let median = hrInWin[hrInWin.count / 2]
            let hrvInWin = hrv.filter { $0 > lo && $0 <= t }.count
            return median <= threshold && hrvInWin >= rescueMinHRVInWindow
        }
        var wakeEnd = block.end
        var t = block.end.addingTimeInterval(step)
        while t <= tail.end {
            if windowIsSleeplike(endingAt: t) { wakeEnd = t; t = t.addingTimeInterval(step) }
            else { break }
        }
        guard wakeEnd > block.end else { return periods }

        // Rewrite the tail: [tail.start, wakeEnd] becomes sleep; any remainder stays active.
        var out: [ActivityPeriod] = []
        for p in periods {
            if p == tail {
                out.append(ActivityPeriod(activity: .sleep, start: p.start, end: wakeEnd))
                if p.end > wakeEnd {
                    out.append(ActivityPeriod(activity: .active, start: wakeEnd, end: p.end))
                }
            } else {
                out.append(p)
            }
        }
        return out
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
