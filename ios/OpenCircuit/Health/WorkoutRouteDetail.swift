// WorkoutRouteDetail.swift — the Apple Health detail an outdoor GPS workout carries beyond its
// totals (#365): fine-grained distance samples and per-km / per-mile split events. Both workout
// writers (the ring's `WorkoutSessionManager.writeWorkout`, the strap's `StrapWorkoutHealthWriter`)
// build them here from the route they already save, so the two devices write the same shape.
//
// The math is `OpenCircuitKit.WorkoutSplits`; this file only turns the route into its track and the
// results into HealthKit objects.

import CoreLocation
import HealthKit
import OpenCircuitKit

enum WorkoutRouteDetail {

    /// The route as the live counter measured it: each fix's distance from the fix before it
    /// (`CLLocation.distance(from:)`, the call the counter used), split into legs at the pauses.
    /// Fix times are clamped into the workout (`start...end`): the first fix can be stamped a few
    /// seconds before Start, and a sample outside the workout is not the builder's to take. Clamping
    /// keeps every step, so the sum still matches the live counter.
    static func track(_ route: [CLLocation], pauses: [DateInterval], start: Date, end: Date) -> WorkoutTrack {
        var fixes: [WorkoutTrackFix] = []
        fixes.reserveCapacity(route.count)
        var previous: CLLocation?
        let last = max(start, end)
        for location in route {
            fixes.append(WorkoutTrackFix(at: min(max(location.timestamp, start), last),
                                         metersFromPrevious: previous.map { location.distance(from: $0) } ?? 0))
            previous = location
        }
        return WorkoutTrack(fixes: fixes, pauses: pauses)
    }

    /// How far the track's own sum may sit from the workout's distance before the detail is
    /// distrusted: 1 m, or 0.5 % on a long workout.
    static func tolerance(_ totalMeters: Double) -> Double { max(1, totalMeters * 0.005) }

    /// The workout's distance as samples about 15 s each (none across a pause), scaled to add up
    /// EXACTLY to `totalMeters` — the total the summary shows and the daily estimate nets out. nil
    /// when the track can't carry it (fewer than two intervals, or a sum outside `tolerance`): the
    /// caller then writes the one whole-workout sample it always has.
    static func distanceSamples(type: HKQuantityType, track: WorkoutTrack, totalMeters: Double,
                                metadata: [String: Any]) -> [HKQuantitySample]? {
        guard totalMeters > 0 else { return nil }
        let intervals = WorkoutSplits.distanceIntervals(track)
        let sum = intervals.reduce(0) { $0 + $1.meters }
        guard intervals.count >= 2, sum > 0, abs(sum - totalMeters) <= tolerance(totalMeters) else { return nil }
        let scale = totalMeters / sum
        return intervals.map {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: $0.meters * scale),
                             start: $0.start, end: $0.end, metadata: metadata)
        }
    }

    /// One `.segment` event per whole kilometre and per whole mile, each from the previous boundary
    /// (the workout's start for the first) to the moment the track crossed it — the split shape
    /// Apple Watch running workouts carry. Kilometre and mile segments overlap by design.
    static func splitEvents(track: WorkoutTrack, start: Date, end: Date) -> [HKWorkoutEvent] {
        [WorkoutSplits.kilometerMeters, WorkoutSplits.mileMeters].flatMap { unit in
            WorkoutSplits.segmentIntervals(track, every: unit, start: start, end: end).map {
                HKWorkoutEvent(type: .segment, dateInterval: $0, metadata: nil)
            }
        }
    }
}
