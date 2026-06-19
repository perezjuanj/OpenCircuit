// Gate for mirroring a night's sleep to Apple Health.
//
// WHY. With periodic overnight draining (HistoryDrainCadence) the staged night GROWS as epochs
// arrive, and the HealthKit sleep watermark (`LocalStore.pendingHealthSleep`) keys off the latest
// segment end — so writing a still-in-progress night on each drain would lay down OVERLAPPING sleep
// samples in Apple Health. Defer the write until the night is "settled": its latest segment ended
// far enough in the past that it won't advance again (the sleeper is up). The watermark then blocks
// any re-write of that same settled night, so it lands exactly once.
//
// Pure (no Apple frameworks / no HealthKit) so it unit-tests on the CLI.

import Foundation

public enum SleepHealthGate {

    /// How long after the last staged epoch a night is considered done growing. One epoch is 150 s,
    /// and a drain can lag a few minutes, so 20 min comfortably clears "the block might still extend"
    /// without holding a finished night back into the next day.
    public static let settleMargin: TimeInterval = 20 * 60

    /// Whether the night ending at `latestSegmentEnd` is settled enough to mirror to Health.
    /// `nil` (no segments) is never settled. `now`/`margin` injected for testability.
    public static func isSettled(latestSegmentEnd: Date?,
                                 now: Date,
                                 margin: TimeInterval = settleMargin) -> Bool {
        guard let end = latestSegmentEnd else { return false }
        return end <= now.addingTimeInterval(-margin)
    }
}
