// WorkoutRouteDetail.swift — the Apple Health detail an outdoor GPS workout carries beyond its
// totals (#365): fine-grained distance samples and per-km / per-mile split events. Both workout
// writers (the ring's `WorkoutSessionManager.writeWorkout`, the strap's `StrapWorkoutHealthWriter`)
// add their GPS distance through `addDistance` here, so every device writes the same shape and one
// test covers them all.
//
// The math is `OpenCircuitKit.WorkoutSplits`; this file only turns the route into its track and the
// results into HealthKit objects.

import CoreLocation
import HealthKit
import OpenCircuitKit

enum WorkoutRouteDetail {

    /// The route as a track. With `legStarts` (the indices the recorder noted where its live counter
    /// had no previous fix) the track replays the counter exactly; without them (a route read back
    /// from Health) legs are rebuilt from the pauses. Each step is `CLLocation.distance(from:)`, the
    /// counter's own call. Fix times are clamped into the workout (`start...end`): the first fix can
    /// be stamped a few seconds before Start, and clamping keeps every step, so the sum is unchanged.
    static func track(_ route: [CLLocation], legStarts: [Int]?, pauses: [DateInterval],
                      start: Date, end: Date) -> WorkoutTrack {
        var fixes: [WorkoutTrackFix] = []
        fixes.reserveCapacity(route.count)
        var previous: CLLocation?
        let last = max(start, end)
        for location in route {
            fixes.append(WorkoutTrackFix(at: min(max(location.timestamp, start), last),
                                         metersFromPrevious: previous.map { location.distance(from: $0) } ?? 0))
            previous = location
        }
        if let legStarts, !legStarts.isEmpty {
            return WorkoutTrack(fixes: fixes, legStarts: Set(legStarts))
        }
        return WorkoutTrack(fixes: fixes, pauses: pauses)
    }

    /// The fitted track as distance samples about 15 s each, none across a pause. nil when there are
    /// fewer than two (nothing finer than the whole workout) or they don't add up to the fitted total.
    static func distanceSamples(type: HKQuantityType, fitted: WorkoutTrack,
                                metadata: [String: Any]) -> [HKQuantitySample]? {
        let intervals = WorkoutSplits.distanceIntervals(fitted)
        let sum = intervals.reduce(0) { $0 + $1.meters }
        guard intervals.count >= 2, abs(sum - fitted.totalMeters) <= 1e-6 * max(1, fitted.totalMeters) else { return nil }
        return intervals.map {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: $0.meters),
                             start: $0.start, end: $0.end, metadata: metadata)
        }
    }

    /// One `.segment` event per whole kilometre and per whole mile of the fitted track, each from the
    /// previous boundary (the workout's start for the first) to the moment the track crossed it: the
    /// split shape Apple Watch running workouts carry. Kilometre and mile segments overlap by design;
    /// the list is in start order, then end order.
    static func splitEvents(fitted: WorkoutTrack, start: Date, end: Date) -> [HKWorkoutEvent] {
        [WorkoutSplits.kilometerMeters, WorkoutSplits.mileMeters]
            .flatMap { WorkoutSplits.segmentIntervals(fitted, every: $0, start: start, end: end) }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            .map { HKWorkoutEvent(type: .segment, dateInterval: $0, metadata: nil) }
    }

    /// Add a GPS workout's distance to its builder: the fine samples and the split events when the
    /// route can carry them, else the one whole-workout sample (the shape before #365). Returns
    /// whether a distance sample landed, so the caller credits the day only for distance that is
    /// actually in the workout.
    ///
    /// - The route's own total must be within `WorkoutSplits.tolerance` of `meters`, or it is
    ///   distrusted: one sample, no splits.
    /// - A refused fine batch falls back to the one sample, and then no splits are added (they'd
    ///   describe samples that aren't there).
    /// - The split events are their own call: a refusal costs only the splits, never the pause and
    ///   resume events the caller already added.
    ///
    /// The builder calls are closures so the ring's `HKWorkoutBuilder` and the strap's
    /// `StrapWorkoutBuilding` (and a test's recorder) all go through this one function.
    @discardableResult
    static func addDistance(meters: Double, type: HKQuantityType, route: [CLLocation], legStarts: [Int]?,
                            pauses: [DateInterval], start: Date, end: Date,
                            addSamples: ([HKSample]) async throws -> Void,
                            addEvents: ([HKWorkoutEvent]) async throws -> Void) async -> Bool {
        let metadata: [String: Any] = [HKMetadataKeyWasUserEntered: false]
        let fitted = WorkoutSplits.fitted(track(route, legStarts: legStarts, pauses: pauses, start: start, end: end),
                                          toMeters: meters)
        if let fitted, let detail = distanceSamples(type: type, fitted: fitted, metadata: metadata) {
            do {
                try await addSamples(detail)
                let splits = splitEvents(fitted: fitted, start: start, end: end)
                if !splits.isEmpty { try? await addEvents(splits) }
                return true
            } catch {
                // Fall through to the one sample.
            }
        }
        let wholeWorkout = HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: meters),
                                            start: start, end: end, metadata: metadata)
        do {
            try await addSamples([wholeWorkout])
            return true
        } catch {
            return false
        }
    }
}
