// Is last night's reported DURATION likely over-counted because the night was very still?
//
// The ring detects wake from only two signals: motion (a coarse per-30 s count, PROTOCOL.md §5.3)
// and heart-rate elevation above the night's sleeping floor (SleepStaging). When the user lies
// STILL while AWAKE — reading in bed, resting before rising — at a heart rate near their own
// sleeping level, the ring sees NEITHER: no movement, and an HR that overlaps light sleep. That
// awake time is absorbed into light sleep, so efficiency (asleep / time-in-bed) pins implausibly
// near 100 % — only a handful of detected-wake minutes across a multi-hour night.
//
// This is NOT a fixable threshold: the discriminating signal isn't on the wire (validated 2026-06-29
// against a night where the ring read 9 h32 m vs a wrist tracker's 7 h43 m — the disputed periods sat
// at HR 56–62, inside this sleeper's own light/REM band, so no HR cut-off could separate awake from
// light without shredding real sleep). It is a HARDWARE CEILING shared with the official RingConn app,
// which stages from the same coarse signals; a wrist device's finer accelerometer catches the
// still-awake micro-movements the ring's resting hand never registers. So we cannot recover the lost
// wake — but we CAN stop presenting the inflated number as gospel.
//
// Healthy sleep efficiency tops out around 90–95 %; a FULL night reading above that is the signature
// of under-detected still wakefulness. Pure (no Apple frameworks) so it unit-tests on the CLI.
// Conservative by design: judged only on a multi-hour night (so naps / buffer-truncated fragments,
// where near-100 % efficiency is unremarkable, never flag) and only above a clearly-implausible
// efficiency — so it informs rather than nags.

import Foundation

public enum SleepConfidence {

    /// Minimum in-bed span before we judge efficiency at all. Below this the night is a nap or a
    /// buffer-truncated fragment (see `SleepCaptureCoverage`), where a near-100 % efficiency carries
    /// no information about still-wake under-detection — so we never flag it.
    public static let minNightForFlag: TimeInterval = 5 * 3600

    /// Efficiency above which a full night's reported duration is likely over-counted: a multi-hour
    /// night with essentially no detected wake (< ~5 % of time in bed). Healthy efficiency tops
    /// ~90–95 %; above this the ring almost certainly missed still wakefulness it cannot sense.
    public static let implausibleEfficiency: Double = 0.95

    public enum Level: Equatable, Sendable {
        /// Nothing unusual — efficiency is in a plausible range, or the night is too short to judge.
        case normal
        /// A very still night with near-zero detected wake. The reported duration likely reads high
        /// because still-but-awake time was absorbed into light sleep (a ring-sensor limitation).
        case durationLikelyHigh
    }

    /// Classify confidence in the reported sleep DURATION from the night's totals.
    ///
    /// - Parameters:
    ///   - asleep: total time asleep (Light + Deep + REM), seconds — i.e. `Summary.totalAsleep`.
    ///   - inBed:  the in-bed window, seconds — i.e. `Summary.inBed`.
    /// - Returns: `.durationLikelyHigh` only on a multi-hour night (`inBed ≥ minNightForFlag`) whose
    ///   efficiency exceeds `implausibleEfficiency`; `.normal` otherwise. A short night, a night with
    ///   realistic wake, or a degenerate `inBed ≤ 0` all return `.normal`.
    public static func classify(asleep: TimeInterval, inBed: TimeInterval) -> Level {
        guard inBed >= minNightForFlag, inBed > 0 else { return .normal }
        let efficiency = asleep / inBed
        return efficiency > implausibleEfficiency ? .durationLikelyHigh : .normal
    }

    /// Convenience overload for a staged-night `Summary`.
    public static func classify(_ summary: SleepStaging.Summary) -> Level {
        classify(asleep: summary.totalAsleep, inBed: summary.inBed)
    }
}
