// Auto-measure wear gate (#56). The ring reports HR/SpO₂ only on demand, so the app
// periodically enters a brief live read to refresh them (RingSession.startAutoMeasure). On
// the charger / off the wrist the ring never locks a reading, so a fixed-cadence probe just
// times out every ~10 min and drains both the ring and the phone. This infers "not worn"
// from PROVEN proxies and backs the probe off exponentially, resuming the normal cadence the
// instant a reading locks (or the skin temperature reads warm) again.
//
// Proxies, honest about confidence:
//   • consecutive auto-measures that never lock a reading (🟢 — the absence of ANY lock over
//     several attempts is strong evidence the ring isn't on a finger).
//   • the raw skin-temperature descriptor (🟡 — a worn Gen-2 reads ≳28 °C; off-wrist it falls
//     toward room ambient ~20–24 °C). Used only to ACCELERATE the inference and to clear it
//     promptly on re-wear.
// It deliberately consults NO charging-flag byte — that descriptor field is undecoded
// (#61 / PROTOCOL.md §5.4 🔴), so we never CLAIM to know the ring is charging. Pure (no Apple
// frameworks) so it unit-tests on the CLI, mirroring ReconnectBackoff / KeepaliveCadence.

import Foundation

public enum AutoMeasureGate {
    /// Consecutive auto-measure cycles with no lock after which the ring is inferred NOT WORN
    /// when there's no temperature signal to lean on (🟢 fallback). With a cold reading a
    /// single miss already confirms it (see `appearsNotWorn`).
    public static let notWornAfterFailures = 2

    /// Hard ceiling on how many times the base interval is doubled while not worn (base ×2^n).
    public static let maxBackoffDoublings = 4

    /// Whether the ring appears NOT WORN, from the consecutive no-lock count and (optionally)
    /// the most recent raw skin temperature:
    ///   • a warm reading (≥ `wornMinC`) is direct evidence of wear → not-worn = false;
    ///   • a cold reading needs only ONE failed lock to confirm not-worn (we never declare it
    ///     on a cold reading alone — a worn-but-cool ring would have LOCKED that one probe);
    ///   • with no temperature signal we fall back to `notWornAfterFailures` consecutive misses.
    public static func appearsNotWorn(consecutiveNoLock: Int,
                                      rawSkinTempC: Double? = nil,
                                      wornMinC: Double = ActivityPeriod.wornMinTemperatureC) -> Bool {
        if let t = rawSkinTempC {
            if t >= wornMinC { return false }            // warm skin ⇒ worn (🟡, direct)
            return consecutiveNoLock >= 1                 // cold + a missed lock ⇒ not worn
        }
        return consecutiveNoLock >= notWornAfterFailures  // no temp ⇒ 🟢 failed-lock fallback
    }

    /// Next interval between auto-measure cycles. While worn (or not yet inferred not-worn) this
    /// is `base`; once not worn it doubles per additional consecutive miss, capped at both
    /// `base × 2^maxBackoffDoublings` and `cap`. A lock (consecutiveNoLock → 0) or a warm
    /// reading drops it straight back to `base`.
    public static func interval(base: TimeInterval,
                                cap: TimeInterval,
                                consecutiveNoLock: Int,
                                rawSkinTempC: Double? = nil,
                                wornMinC: Double = ActivityPeriod.wornMinTemperatureC) -> TimeInterval {
        guard appearsNotWorn(consecutiveNoLock: consecutiveNoLock,
                             rawSkinTempC: rawSkinTempC, wornMinC: wornMinC) else { return base }
        let doublings = min(max(consecutiveNoLock - 1, 0), maxBackoffDoublings)
        return min(base * pow(2, Double(doublings)), cap)
    }
}
