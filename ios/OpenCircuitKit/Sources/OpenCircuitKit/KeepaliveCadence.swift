// Adaptive idle-keepalive cadence (#31). The 0x10/0x87 descriptor (steps/temp/battery)
// is solicited by a `07 00 00` heartbeat; polling it every 30 s around the clock measurably
// drains both the ring and the phone. Freshness only matters in two windows — the nightly
// temp capture and an active live measurement — so this picks a slow daytime cadence and
// tightens only when it counts. Pure (no Apple frameworks) so it unit-tests on the CLI.

import Foundation

public enum KeepaliveCadence {
    /// Seconds between idle descriptor heartbeats.
    /// - `isNight`: inside the nightly sleep/temp window (skin temp streams then — keep it fresh).
    /// - `activeMeasurement`: a live HR/SpO₂ read (or its prep) is in flight — re-check often so
    ///   the keepalive resumes promptly when it ends (the heartbeat itself is suppressed meanwhile).
    /// - `batterySaver`: user opted into the battery-saver toggle — stretch the idle cadences.
    public static func interval(isNight: Bool,
                                activeMeasurement: Bool,
                                batterySaver: Bool) -> TimeInterval {
        if activeMeasurement { return 30 }              // a live read owns the link — re-check fast
        if isNight { return batterySaver ? 90 : 60 }    // overnight temp matters — tighten to ~1 min
        return batterySaver ? 300 : 180                 // daytime idle: 3 min (5 min in battery saver)
    }
}
