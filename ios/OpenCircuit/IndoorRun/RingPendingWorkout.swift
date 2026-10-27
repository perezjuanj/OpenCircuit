import Foundation
import OpenCircuitKit

// A ring indoor run or walk that ENDED and waits for its distance prompt before its `HKWorkout` is saved
// (#339, decision 84j). Its crash-recovery snapshot (`WorkoutSessionSnapshot`, UserDefaults) carries the
// span and the totals; this file carries what the snapshot can't: the heart-rate readings and the pauses
// (decision 84l, review-indoor-run-b B1). So a kill at any point after End loses none of the readings the
// save at End would have kept: the recovered save writes them with the workout and lands them in
// `LocalStore`, exactly as a normal save does. Removed when the workout is saved (either way).
//
// A file, not UserDefaults and not SwiftData: the strap's journal does the same (`StrapWorkoutFileJournal`),
// with the same protection class (readable after the first unlock, so a background relaunch can read it).

/// The readings and pauses of one ended ring workout, keyed by its start.
struct RingPendingWorkout: Codable, Equatable {
    let start: Date
    let hrSamples: [HRSample]
    let pauses: [DateInterval]
}

@MainActor
protocol RingPendingWorkoutStoring: AnyObject {
    func save(_ pending: RingPendingWorkout)
    func load() -> RingPendingWorkout?
    func clear()
}

extension RingPendingWorkoutStoring {
    /// The readings of the workout that started at `start` (within a second: the snapshot stores the same
    /// date), removed as they are taken, so they can be written and landed once. A file left by another
    /// workout is removed too: nothing else can claim it.
    func take(start: Date) -> RingPendingWorkout? {
        let pending = load()
        clear()
        guard let pending, abs(pending.start.timeIntervalSince(start)) < 1 else { return nil }
        return pending
    }
}

/// Application Support/RingWorkout/pending.json. Nothing is created until a ring indoor run waits.
final class RingPendingWorkoutFile: RingPendingWorkoutStoring {
    private let url: URL

    init(folder: URL? = nil) {
        let folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RingWorkout", isDirectory: true)
        url = folder.appendingPathComponent("pending.json")
    }

    func save(_ pending: RingPendingWorkout) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load() -> RingPendingWorkout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RingPendingWorkout.self, from: data)
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}
