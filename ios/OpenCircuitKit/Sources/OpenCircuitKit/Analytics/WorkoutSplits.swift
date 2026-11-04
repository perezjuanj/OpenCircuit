// WorkoutSplits.swift — per-km / per-mile splits and fine-grained distance from a workout's GPS
// track (#365). Foundation-only: the ring's `WorkoutSessionManager` and the strap's
// `StrapWorkoutHealthWriter` build the same Apple Health detail from these, and the workout detail
// screen shows the same splits, so the devices and the screens can't disagree.
//
// The track is the fixes the workout ACCEPTED (the live filters already dropped stale and
// inaccurate ones), each with its distance from the fix before it as the live counter measured it.
// A pause ends a leg: the live counter adds nothing across a paused stretch (the first fix after a
// resume starts a new leg), so neither does anything here.
//
// NO-FABRICATION: a split exists only where the track actually crossed the boundary; a partial last
// split is reported as partial, never stretched to a whole unit.

import Foundation

/// One accepted GPS fix: when, and its distance in meters from the previous fix (any value for the
/// first fix of the workout; it is ignored at every leg start).
public struct WorkoutTrackFix: Equatable, Sendable {
    public let at: Date
    public let metersFromPrevious: Double
    public init(at: Date, metersFromPrevious: Double) {
        self.at = at
        self.metersFromPrevious = metersFromPrevious
    }
}

/// A workout's GPS track split into legs at its pauses.
public struct WorkoutTrack: Equatable, Sendable {
    /// One point of a leg: when, and the workout's cumulative distance then.
    public struct Point: Equatable, Sendable {
        public let at: Date
        public let cumulativeMeters: Double
    }

    /// Each leg's points in time order. A leg never spans a pause.
    public let legs: [[Point]]

    /// The track's total distance: the sum of every within-leg step.
    public var totalMeters: Double { legs.last?.last?.cumulativeMeters ?? 0 }

    /// `fixes` in the order they were accepted; `pauses` the workout's paused stretches. A fix
    /// starts a new leg when any pause overlaps the time since the previous fix — the same place the
    /// live counter reset its last fix — so its `metersFromPrevious` is dropped.
    public init(fixes: [WorkoutTrackFix], pauses: [DateInterval]) {
        var legs: [[Point]] = []
        var cumulative = 0.0
        var previous: Date?
        for fix in fixes {
            if let prev = previous, fix.at >= prev,
               !pauses.contains(where: { $0.start < fix.at && $0.end > prev }) {
                cumulative += max(0, fix.metersFromPrevious)
                legs[legs.count - 1].append(Point(at: fix.at, cumulativeMeters: cumulative))
            } else {
                legs.append([Point(at: fix.at, cumulativeMeters: cumulative)])
            }
            previous = fix.at
        }
        self.legs = legs
    }
}

public enum WorkoutSplits {
    public static let kilometerMeters: Double = 1_000
    public static let mileMeters: Double = 1_609.344
    /// The target span of one fine-grained distance sample.
    public static let intervalSeconds: TimeInterval = 15
    /// A partial last split shorter than this is GPS noise at the finish, not a split.
    public static let minimumPartialMeters: Double = 50

    /// A stretch of the track and the distance covered in it.
    public struct DistanceInterval: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let meters: Double
    }

    /// The track as distance samples about `targetSeconds` long. Each lies inside one leg (never
    /// across a pause), has a positive span and positive distance, and together they add up to the
    /// track's total (a same-instant last step is folded into the interval before it).
    public static func distanceIntervals(_ track: WorkoutTrack,
                                         targetSeconds: TimeInterval = intervalSeconds) -> [DistanceInterval] {
        var out: [DistanceInterval] = []
        for leg in track.legs {
            guard var chunkStart = leg.first else { continue }
            let legFirstIndex = out.count
            for point in leg.dropFirst() where point.at.timeIntervalSince(chunkStart.at) >= targetSeconds {
                let meters = point.cumulativeMeters - chunkStart.cumulativeMeters
                if meters > 0 { out.append(DistanceInterval(start: chunkStart.at, end: point.at, meters: meters)) }
                chunkStart = point
            }
            guard let last = leg.last else { continue }
            let rest = last.cumulativeMeters - chunkStart.cumulativeMeters
            guard rest > 0 else { continue }
            if last.at > chunkStart.at {
                out.append(DistanceInterval(start: chunkStart.at, end: last.at, meters: rest))
            } else if out.count > legFirstIndex, let prior = out.last {
                out[out.count - 1] = DistanceInterval(start: prior.start, end: prior.end, meters: prior.meters + rest)
            }
            // else: distance at a single instant with nothing in its leg to fold into. Dropped, so
            // the intervals fall short of the total and the caller's sum check takes over.
        }
        return out
    }

    /// When the track's cumulative distance reached each whole multiple of `unitMeters`, by linear
    /// interpolation between the two fixes either side. Only crossings inside a leg exist.
    public static func boundaries(_ track: WorkoutTrack, every unitMeters: Double) -> [Date] {
        guard unitMeters > 0 else { return [] }
        var out: [Date] = []
        var next = unitMeters
        for leg in track.legs {
            for (a, b) in zip(leg, leg.dropFirst()) where b.cumulativeMeters > a.cumulativeMeters {
                while next <= b.cumulativeMeters {
                    let fraction = max(0, (next - a.cumulativeMeters) / (b.cumulativeMeters - a.cumulativeMeters))
                    out.append(a.at.addingTimeInterval(fraction * b.at.timeIntervalSince(a.at)))
                    next += unitMeters
                }
            }
        }
        return out
    }

    /// One split of a workout.
    public struct Split: Equatable, Sendable, Identifiable {
        /// 1-based.
        public let index: Int
        public let start: Date
        public let end: Date
        /// `unitMeters` for a whole split; less for the partial last one.
        public let meters: Double
        /// The split's time minus any paused time inside it.
        public let movingSeconds: TimeInterval
        public let isPartial: Bool
        public var id: Int { index }

        /// Moving seconds per whole unit (the split's pace), scaled for a partial split.
        public func secondsPerUnit(_ unitMeters: Double) -> Double? {
            guard meters > 0, movingSeconds > 0 else { return nil }
            return movingSeconds / (meters / unitMeters)
        }
    }

    /// The workout's splits of `unitMeters`: the first from the workout's start, each next from the
    /// previous boundary, and a partial last one to the workout's end when it covered at least
    /// `minimumPartialMeters`. Empty when the track never reached one whole unit or a partial.
    public static func splits(_ track: WorkoutTrack, every unitMeters: Double,
                              start: Date, end: Date, pauses: [DateInterval]) -> [Split] {
        guard unitMeters > 0, end > start else { return [] }
        let marks = boundaries(track, every: unitMeters).filter { $0 > start && $0 <= end }
        var out: [Split] = []
        var from = start
        for (i, mark) in marks.enumerated() {
            out.append(Split(index: i + 1, start: from, end: mark, meters: unitMeters,
                             movingSeconds: moving(from, mark, pauses), isPartial: false))
            from = mark
        }
        let rest = track.totalMeters - Double(marks.count) * unitMeters
        if rest >= minimumPartialMeters, end > from {
            out.append(Split(index: marks.count + 1, start: from, end: end, meters: rest,
                             movingSeconds: moving(from, end, pauses), isPartial: true))
        }
        return out
    }

    /// The whole-unit splits only, as the date intervals Apple Health's segment events carry.
    public static func segmentIntervals(_ track: WorkoutTrack, every unitMeters: Double,
                                        start: Date, end: Date) -> [DateInterval] {
        splits(track, every: unitMeters, start: start, end: end, pauses: [])
            .filter { !$0.isPartial && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
    }

    private static func moving(_ from: Date, _ to: Date, _ pauses: [DateInterval]) -> TimeInterval {
        var seconds = to.timeIntervalSince(from)
        for pause in pauses {
            let overlap = min(to, pause.end).timeIntervalSince(max(from, pause.start))
            if overlap > 0 { seconds -= overlap }
        }
        return max(0, seconds)
    }
}
