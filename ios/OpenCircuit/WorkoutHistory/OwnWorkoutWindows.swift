// OwnWorkoutWindows.swift: the windows of the workouts OpenCircuit itself recorded, kept on the phone
// (decision 91h, #226).
//
// The strap keeps its own record of every workout it measured, including the ones OpenCircuit started
// in its workout mode (`ZEPP_PROTOCOL.md` §22). The strap's detected-workout inbox (`StrapDetectedWorkouts`)
// must never offer that record back: saving it would put the same workout, heart rate and energy in
// Apple Health twice, and offering one the person cancelled or discarded would bring it back with a
// notification. Reading Apple Health can't be what guarantees that (a locked phone, a failed query, or
// no read access all return nothing), so this list does. Where windows are written:
//   • a strap workout from the moment it STARTS (decision 91i; `StrapWorkoutRecorder.start`, once the
//     start is in the journal), its end refreshed at each journal heartbeat (~10 s) and at every exit:
//     End, Cancel, a new start parking an interrupted journal, and the recovery offer, Not now, Discard
//     and Save. So a workout the process dies in is covered too, before any relaunch decision;
//   • a ring workout, when it is saved (`WorkoutSessionManager.writeWorkout`, the detected-bout import
//     too). A ring workout whose save never committed adds nothing: the ring keeps no record of its own
//     for the strap's inbox to offer back;
//   • a strap record saved from the inbox (`StrapDetectedWorkouts.save`).
// A window is never removed: a Cancel or a recovery Discard throws the workout away, not the dedup.
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

    /// Remember that OpenCircuit recorded a workout over `[start, end]`. A window with the same start
    /// is the same workout: its end only ever moves later (a heartbeat or an exit), never back, and no
    /// call removes it. Entries past `retention` go.
    func record(start: Date, end: Date, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var all = entries.filter { $0.end >= cutoff }
        let end = max(start, end)
        if let i = all.firstIndex(where: { $0.start == start }) {
            guard end > all[i].end else { return }
            all[i] = Entry(start: start, end: end)
        } else {
            all.append(Entry(start: start, end: end))
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }
}
