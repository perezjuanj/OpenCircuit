// Periodic history-drain cadence. The companion to KeepaliveCadence: that decides how often to
// poll the descriptor (steps/temp/battery); THIS decides how often, while connected+idle, to drain
// the ring's 0x4c history backlog.
//
// WHY. The ring's onboard history buffer holds only ~114 epochs (~4.75 h) and DROPS THE OLDEST when
// full. Today history is drained only on foreground/manual events, so a link held quietly overnight
// (or simply not foregrounded) lets the buffer overflow and the early, deep-sleep-rich hours are
// gone before the morning sync. Draining on a fixed cadence — comfortably more often than the buffer
// fills — keeps it emptied. Safe to do repeatedly only because the night is re-stitched from the
// EpochArchive union (a single drain returns just the slice since the last one).
//
// Pure (no Apple frameworks) so it unit-tests on the CLI, matching KeepaliveCadence / ReconnectBackoff.

import Foundation

public enum HistoryDrainCadence {

    /// Minimum seconds between periodic drains while connected+idle.
    /// - `isNight`: inside the sleep window — tighten so the buffer can't overflow across a night.
    /// - `batterySaver`: user opted into the battery-saver toggle — relax, but stay well under the
    ///   ~4.75 h buffer so even a missed drain doesn't lose data.
    public static func interval(isNight: Bool, batterySaver: Bool) -> TimeInterval {
        if isNight { return (batterySaver ? 120 : 90) * 60 }   // 1.5–2 h overnight (buffer ≈ 4.75 h)
        return (batterySaver ? 240 : 180) * 60                 // 3–4 h by day
    }

    /// Whether a periodic drain is due: nothing drained yet, or `interval` has elapsed since the
    /// last drain. `now`/`lastDrainAt` are injected so this stays pure and testable.
    public static func isDue(lastDrainAt: Date?,
                             now: Date,
                             isNight: Bool,
                             batterySaver: Bool) -> Bool {
        guard let last = lastDrainAt else { return true }
        return now.timeIntervalSince(last) >= interval(isNight: isNight, batterySaver: batterySaver)
    }
}
