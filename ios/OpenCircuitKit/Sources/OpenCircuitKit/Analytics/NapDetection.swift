// Automatic nap detection — #76.
//
// The ring auto-recognises naps longer than 15 minutes and folds them into daily sleep totals
// (APK: pp.txt:47434 "automatically recognize and record your naps that are longer than 15
// minutes"; `SleepNapModel(start,end,isLongNap,sleepPhases,isEdited)` pp.txt:b3458). We detect
// the same daytime sleep from the SAME motion signal `SleepDetection` already uses — reusing
// `ActivityPeriod.detectFromMotion` over the day's 0x4c `[10:15]` motion 🟢 — then keep only
// stillness blocks that are (a) ≥ 15 min, (b) NOT the main overnight sleep, and (c) daytime
// (a non-overnight midpoint, via `SleepWindow.isOvernightBlock`). That last gate is what keeps
// naps from double-counting against the main night.

import Foundation

public enum NapDetection {

    /// Minimum length for a stillness block to count as a nap (APK: 15 min).
    public static let minNapDuration: TimeInterval = 15 * 60
    /// A daytime block longer than this is more likely a long sedentary period (a movie, a long
    /// meeting) than a nap; still recorded, but flagged `isLongNap` for the UI to caveat. The app
    /// carries the same `isLongNap` distinction.
    public static let longNapDuration: TimeInterval = 3 * 60 * 60

    public struct Nap: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let segments: [SleepSegment]    // inBed + asleep/awake sub-segments for HealthKit
        public init(start: Date, end: Date, segments: [SleepSegment]) {
            self.start = start; self.end = end; self.segments = segments
        }
        public var duration: TimeInterval { end.timeIntervalSince(start) }
        public var isLongNap: Bool { duration >= NapDetection.longNapDuration }
        /// Time actually asleep within the nap (asleep sub-segments only).
        public var asleep: TimeInterval {
            segments.filter { $0.stage == .asleepCore || $0.stage == .asleepDeep || $0.stage == .asleepREM }
                .reduce(0) { $0 + $1.duration }
        }
    }

    /// Detect daytime naps from a day's records, excluding whatever overlaps the main overnight
    /// sleep block. Pass the already-detected `mainSleep` (e.g. `BulkSleep.mainSleep`) so a nap
    /// can never overlap it; pass `temperatures` to apply the same off-wrist/charging wear gate
    /// the night uses (#41). Naps are returned in chronological order.
    public static func naps(from records: [BulkRecord],
                            mainSleep: ActivityPeriod?,
                            temperatures: [TemperatureSample] = [],
                            epoch: Int = Command.syncEpoch) -> [Nap] {
        let timeline = BulkSleep.motionTimeline(from: records, epoch: epoch)
        let periods = ActivityPeriod.detectFromMotion(timeline, temperatureSamples: temperatures)

        return periods.compactMap { p -> Nap? in
            guard p.activity == .sleep else { return nil }
            guard p.duration >= minNapDuration else { return nil }
            // Exclude the main overnight sleep (and anything overlapping it) — no double-count.
            if let main = mainSleep, p.start < main.end && p.end > main.start { return nil }
            // Daytime only: a block whose MIDPOINT is at night is (another) night/long sleep,
            // not a nap — reuse the overnight-block test (inverted) so the rule matches the
            // main-night gate exactly.
            if SleepWindow.isOvernightBlock(start: p.start, end: p.end) { return nil }

            let segs = napSegments(from: records, period: p, epoch: epoch)
            return Nap(start: p.start, end: p.end, segments: segs)
        }
        .sorted { $0.start < $1.start }
    }

    /// Coarse HealthKit segments for a nap: an `inBed` span plus the asleep/awake sub-blocks
    /// detected inside it (same shape as `BulkSleep.sleepSegments`, scoped to the nap window).
    private static func napSegments(from records: [BulkRecord],
                                    period: ActivityPeriod,
                                    epoch: Int) -> [SleepSegment] {
        let inWindow = records.filter {
            let t = $0.date(epoch: epoch)
            return t >= period.start && t <= period.end
        }
        let timeline = BulkSleep.motionTimeline(from: inWindow, epoch: epoch)
        let periods = ActivityPeriod.detectFromMotion(timeline)
        var segs = [SleepSegment(start: period.start, end: period.end, stage: .inBed)]
        for p in periods where p.start < period.end && p.end > period.start {
            let s = max(p.start, period.start), e = min(p.end, period.end)
            if e <= s { continue }
            segs.append(SleepSegment(start: s, end: e,
                                     stage: p.activity == .sleep ? .asleepCore : .awake))
        }
        // No interior detection (e.g. a short uniform nap) → treat the whole window as asleep.
        if segs.count == 1 {
            segs.append(SleepSegment(start: period.start, end: period.end, stage: .asleepCore))
        }
        return segs
    }
}
