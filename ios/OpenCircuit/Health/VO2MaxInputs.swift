// VO2MaxInputs.swift — the app-side inputs `VO2MaxEstimate` needs (#232), gathered the same way for
// a ring workout (`WorkoutSessionManager`) and a strap workout (`StrapWorkoutRecorder`). Every rule
// here is device-agnostic: the GPS route is the phone's, the age is the profile's, and the resting
// heart rate is the app's daily series over whatever wearable recorded it.

import CoreLocation
import Foundation
import OpenCircuitKit

enum VO2MaxInputs {
    /// The GPS fixes as cumulative distance (the same running sum the workout shows as its
    /// distance), with altitude only where CoreLocation says it is valid.
    static func routePoints(_ route: [CLLocation]) -> [VO2MaxEstimate.RoutePoint] {
        var points: [VO2MaxEstimate.RoutePoint] = []
        var cumulative = 0.0
        var previous: CLLocation?
        for location in route {
            if let previous { cumulative += location.distance(from: previous) }
            previous = location
            let hasAltitude = location.verticalAccuracy > 0
            points.append(VO2MaxEstimate.RoutePoint(
                time: location.timestamp, distance: cumulative,
                altitude: hasAltitude ? location.altitude : nil,
                verticalAccuracy: hasAltitude ? location.verticalAccuracy : nil))
        }
        return points
    }

    /// The age only if the user set one: the profile's 35 placeholder is not an age.
    static func userSetAge(_ defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: "userProfile.age") as? Int
    }

    /// The daily resting HR from the stored history of the 9 days before the workout, its own
    /// window left out (`VO2MaxEstimate.restingHR` takes the median of the last 7 days).
    @MainActor
    static func restingHR(store: LocalStore, workoutStart: Date, workoutEnd: Date) -> Double? {
        let since = workoutStart.addingTimeInterval(-9 * 86_400)
        let window = workoutStart ... max(workoutEnd, workoutStart)
        let history = ((try? store.recentSamples(kind: .heartRate, since: since)) ?? [])
            .filter { !window.contains($0.start) }
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        // Decision 92: the device's own resting-HR records win their day.
        let reported = ((try? store.ownedSamples(kind: .restingHeartRate, from: since, to: workoutStart)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        return VO2MaxEstimate.restingHR(daily: RestingHR.dailyValues(hr: history, reported: reported),
                                        runStart: workoutStart)
    }
}
