// OwnWorkoutWindows.swift: the windows of the workouts OpenCircuit itself recorded, kept on the phone
// (decision 91h, #226).
//
// The strap keeps its own record of every workout it measured, including the ones OpenCircuit started
// in its workout mode (`ZEPP_PROTOCOL.md` §22). The strap's detected-workout inbox (`StrapDetectedWorkouts`)
// must never offer that record back: saving it would put the same workout, heart rate and energy in
// Apple Health twice. Reading Apple Health can't be what guarantees that (a locked phone, a failed
// query, or no read access all return nothing), so every workout the app records adds its window here:
//   • a strap workout at End (`StrapWorkoutRecorder.end`), before any deferred save (84j's indoor run
//     can wait up to 10 min for its distance prompt);
//   • a recovered strap workout, at its save (`StrapWorkoutRecorder.writeRecovered`);
//   • a ring workout, when it is saved (`WorkoutSessionManager.writeWorkout`, the detected-bout import too);
//   • a strap record saved from the inbox (`StrapDetectedWorkouts.save`).
// The inbox treats a record overlapping any of them as already in the history.
//
// UserDefaults, not SwiftData, like `WorkoutTombstones`: a few dozen bytes per entry, no schema version.

import Foundation
import OpenCircuitKit

struct OwnWorkoutWindows {
    nonisolated static let key = "workout.ownWindows.v1"
    /// Kept as long as the inbox's own bookkeeping: its two-day review window and a day more, so no
    /// record the inbox can still keep is ever compared with a list that already forgot its workout.
    static let retention: TimeInterval = AutomaticWorkoutInbox.retention + 86_400

    struct Entry: Codable, Equatable {
        let start: Date
        let end: Date
    }

    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    var entries: [Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    var windows: [DateInterval] { entries.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) } }

    /// Remember that OpenCircuit recorded a workout over `[start, end]`; entries past `retention` go.
    func record(start: Date, end: Date, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var all = entries.filter { $0.end >= cutoff }
        guard !all.contains(where: { $0.start == start && $0.end == end }) else { return }
        all.append(Entry(start: start, end: max(start, end)))
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }
}
