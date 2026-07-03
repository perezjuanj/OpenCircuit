// Periodic history-drain cadence. The companion to KeepaliveCadence: that decides how often to keep
// the link warm; THIS decides how often, while connected+idle, to drain the ring's 0x4c history.
//
// WHY a cadence (not just foreground/manual). By DAY, each `0x02` drain hands off only the slice since
// the last one and self-advances the ring's resume pointer, so draining on a timer keeps recent
// activity fresh and the EpochArchive union re-stitches any multi-slice handoff into one block.
//
// ⚠️ HISTORY (2026-06-22 → 2026-06-30): overnight draining has flip-flopped as the root cause came
// into focus. (1) 06-22: SUPPRESSED overnight, blaming the drains' cursor≈now opens for advancing the
// shared resume pointer past the night. (2) 06-24: RE-ENABLED — the shredder of THAT night was shown
// to be the bare `0x07` `fetch` heartbeat (fired every ~60 s for skin-temp INSIDE the window), walking
// the pointer through the whole night and discarding each 0x4c page (device-confirmed: a 6.3 h hole,
// pointer parked at the last temp descriptor). With that heartbeat gone, cadenced drains were believed
// "safe and additive." (3) 06-30: that belief is now PARTLY DISPROVEN. Randy/@padawer2's build-16
// capture (#111/#119) drained every ~30 min ALL NIGHT with the heartbeat already gone, yet the ring
// still STOPPED handing off 0x4c sleep history at ~02:35 and never resumed (even the morning re-drain
// got nothing past 02:35) — the back ~3 h was lost. So the cadenced drains THEMSELVES (cursor≈now
// opens + the per-drain `0x07` fetch in `drainChannel`, ×2 channels) still contend the ring's single
// resume pointer. The resolution is the OVERNIGHT-QUIET gate (`shouldDrain` below): inside the sleep
// window we do NOT drain — the link is kept warm with `0xD0` statusQuery (no pointer walk) and the
// night accumulates UNTOUCHED on the ring (it buffers for DAYS — §3, a 19-day backlog drained in one
// shot; the scattered "~4.75 h drop-oldest" notes elsewhere are the stale, pre-§3 belief), then is
// pulled in ONE pass at wake. TRADEOFFS: overnight skin temp is ELIMINATED (statusQuery yields no
// descriptor) and the sleep wear-gate reverts to motion-only overnight; and a co-installed official app
// can win the whole night in the morning. Sleep-history integrity wins (it is the reported loss).
// Daytime cadence is unchanged. ⚠️ NEEDS ON-DEVICE VALIDATION (a full >5 h night must drain intact in
// one morning pass, early hours included) before this is trusted as the #111/#119 fix.
//
// Pure (no Apple frameworks) so it unit-tests on the CLI, matching KeepaliveCadence / ReconnectBackoff.

import Foundation

public enum HistoryDrainCadence {

    /// Minimum seconds between periodic drains while connected+idle.
    /// - `isNight`: inside the sleep window — tightened to 30–45 min so each drain also lands a
    ///   skin-temp reading (the 60 s `fetch` temp heartbeat no longer runs overnight; see header).
    ///   NOTE: with the overnight-quiet gate (`shouldDrain`) the night arm now only matters for
    ///   `isDue` bookkeeping — in-window drains are suppressed outright.
    /// - `batterySaver`: user opted into the battery-saver toggle — relax both arms.
    ///
    /// Day arm: 1 h (was 3–4 h). Background drains are now actually driven while the app is
    /// suspended (the 0x11 heartbeat wake evaluates this cadence, #119), and the point of that
    /// is all-day steps/HR/RR freshness in Apple Health — a 3 h staleness defeats it. Each drain
    /// hands off only the slice since the last, so a tighter cadence costs seconds of radio per
    /// hour, not a re-download.
    public static func interval(isNight: Bool, batterySaver: Bool) -> TimeInterval {
        if isNight { return (batterySaver ? 45 : 30) * 60 }    // 30–45 min: each drain also carries a temp read
        return (batterySaver ? 180 : 60) * 60                  // 1 h by day (3 h in battery saver)
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

    /// The OVERNIGHT-QUIET gate: whether to actually run a history drain right now.
    ///
    /// An AUTOMATIC drain inside the sleep window is SUPPRESSED (#111/#119): each drain's cursor≈now
    /// open + per-channel `0x07` fetch contends the ring's single resume pointer, which makes it stop
    /// handing off 0x4c sleep history mid-night (Randy 6/30: drained every ~30 min, ring went silent at
    /// ~02:35, the back ~3 h was lost for good). So inside the window we drain NOTHING and let the night
    /// accumulate untouched on the ring (it buffers for days); the whole night is then pulled in ONE
    /// pass once the window ends — `isDue` is true at wake because `lastDrainAt` is hours old.
    ///
    /// A user-initiated (`manual`) sync ALWAYS bypasses the gate — an explicit pull-to-refresh / Sync
    /// tap should drain even mid-window. Callers fold their own cadence into `isDue`; this only adds the
    /// window gate, so day-time behavior is unchanged (`shouldDrain == isDue`).
    public static func shouldDrain(manual: Bool, inSleepWindow: Bool, isDue: Bool) -> Bool {
        if manual { return true }            // user asked explicitly — never gated
        if inSleepWindow { return false }    // overnight-quiet: one drain at wake, not many through the night
        return isDue                         // daytime: the normal cadence
    }
}
