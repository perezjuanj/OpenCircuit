// Periodic history-drain cadence. The companion to KeepaliveCadence: that decides how often to keep
// the link warm; THIS decides how often, while connected+idle, to drain the ring's 0x4c history.
//
// WHY a cadence (not just foreground/manual). Each `0x02` drain hands off only the slice since the
// last one and self-advances the ring's resume pointer, so draining on a timer keeps the night
// captured as a series of slices that the EpochArchive union re-stitches into one night. Safe to
// repeat precisely because of that stitch.
//
// ⚠️ HISTORY (2026-06-22 → 2026-06-24): draining overnight was briefly SUPPRESSED, on the theory that
// the drains' cursor≈now opens advanced the shared resume pointer past the night (~12 epochs/night,
// every sync sleepSegs=0). That was the wrong culprit. The real shredder was the bare `0x07` `fetch`
// heartbeat — "fetch NEXT history record" — which `RingSession`'s keepalive fired every ~60 s for
// skin-temp INSIDE the window, walking the pointer through the whole night and discarding each 0x4c
// page (device-confirmed 2026-06-24: a 6.3 h EpochArchive hole, pointer parked at the last temp
// descriptor). With the overnight `fetch` removed (statusQuery keeps the link warm instead), nothing
// walks the pointer between drains, so this cadence drives the night again — tighter at night so each
// drain also yields a skin-temp reading now that the 60 s temp heartbeat is gone. (The ring buffers
// for DAYS — §3, a 19-day backlog drained in one shot — so the cadence is about temp resolution and
// freshness, not the old "~4.75 h buffer overflow" fear, which was wrong for the sleep channel.)
//
// Pure (no Apple frameworks) so it unit-tests on the CLI, matching KeepaliveCadence / ReconnectBackoff.

import Foundation

public enum HistoryDrainCadence {

    /// Minimum seconds between periodic drains while connected+idle.
    /// - `isNight`: inside the sleep window — tightened to 30–45 min so each drain also lands a
    ///   skin-temp reading (the 60 s `fetch` temp heartbeat no longer runs overnight; see header).
    /// - `batterySaver`: user opted into the battery-saver toggle — relax both arms.
    public static func interval(isNight: Bool, batterySaver: Bool) -> TimeInterval {
        if isNight { return (batterySaver ? 45 : 30) * 60 }    // 30–45 min: each drain also carries a temp read
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
