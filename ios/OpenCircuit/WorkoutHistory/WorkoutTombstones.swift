// WorkoutTombstones.swift: the record that a workout the user deleted from the history screen
// (#293) stays deleted.
//
// Nothing in the app writes an `HKWorkout` without the user asking for it: the Helio fetch imports no
// workouts (`HelioFetchPlan.types`), and the ring's detected bouts become workouts only through
// "Add to Apple Health". But three places OFFER a past workout back, and each is a way for a deleted
// one to return:
//   • the ring's detected-workout inbox (`RingSession.suppressedAutomaticWorkoutSpans`), whose own
//     resolved-span bookkeeping is skipped when the ring session was gone at the moment of the save;
//   • the ring's crash-recovery offer (`WorkoutSessionManager.recoveryDecision`);
//   • the strap's interrupted-workout offer (`StrapWorkoutRecorder.resolveOrphan`).
// Each consults this list and treats a window overlapping a deleted workout as already decided.
// Live recording is NOT gated: a live workout starts now, so it can never be a deleted past one,
// and dropping it would lose a real workout.
//
// UserDefaults, not SwiftData: a few dozen bytes per entry and no schema version (see the file
// header of `WorkoutHistoryView.swift` for why this feature adds no model).

import Foundation
import OpenCircuitKit

struct WorkoutTombstones {
    nonisolated static let key = "workout.deletedTombstones.v1"
    /// Newest kept. A deletion only has to outlive the offers above, and the longest of those (the
    /// detection inbox) looks back two days, so this is generous.
    static let capacity = 256

    struct Entry: Codable, Equatable {
        let start: Date
        let end: Date
        let deletedAt: Date
    }

    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    var entries: [Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Remember that the workout over `[start, end]` was deleted.
    func record(start: Date, end: Date, deletedAt: Date = Date()) {
        var all = entries
        guard !all.contains(where: { $0.start == start && $0.end == end }) else { return }
        all.append(Entry(start: start, end: max(start, end), deletedAt: deletedAt))
        if all.count > Self.capacity {
            all = Array(all.sorted { $0.end > $1.end }.prefix(Self.capacity))
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }

    /// True when `[start, end]` overlaps a deleted workout: the same stretch of exercise, whatever
    /// device or path would describe it again. Touching endpoints count, as `CursorSpan.overlaps` does.
    func suppresses(start: Date, end: Date) -> Bool {
        let e = max(start, end)
        return entries.contains { $0.start <= e && start <= $0.end }
    }

    /// The deleted windows as ring-cursor spans, for the detection inbox's overlap test.
    var cursorSpans: [CursorSpan] {
        entries.map { CursorSpan(window: DateInterval(start: $0.start, end: $0.end)) }
    }

    // MARK: Recovery offers

    /// The ring's crash-recovery decision with a deleted workout's window refused.
    func filter(_ decision: WorkoutRecoveryDecision) -> WorkoutRecoveryDecision {
        guard case .offer(let recovered) = decision,
              suppresses(start: recovered.start, end: recovered.end) else { return decision }
        return .discard(.deletedByUser)
    }

    /// The strap's interrupted-workout decision with a deleted workout's window refused.
    func filter(_ decision: StrapWorkoutRecovery.Decision) -> StrapWorkoutRecovery.Decision {
        guard case .offer(let recovered) = decision,
              suppresses(start: recovered.ledger.start, end: recovered.end) else { return decision }
        return .discard(.deletedByUser)
    }
}
