// Auto-reconnect backoff policy (#35). RingScanner re-issues `central.connect` on every
// disconnect; left unbounded, a ring on the charger (it accepts a connect then immediately
// drops it) keeps the radio armed in a tight reconnect loop for hours. This grows the delay
// between consecutive failed reconnects and tells the UI when to stop saying "Connecting…"
// and surface a calm "ring unreachable / charging" note instead. Pure (no CoreBluetooth) so
// it unit-tests on the CLI; the scanner owns the attempt counter and resets it on a real,
// frame-delivering connection.
//
// NOTE: the calm state is derived from elapsed *attempts*, NOT a decoded charging-flag byte —
// that descriptor bit is protocol-blocked (#41), so we never claim to know the ring is charging.

import Foundation

public enum ReconnectBackoff {
    /// Delay (seconds) before the next reconnect, indexed by consecutive failed attempts:
    /// 1 s → 5 s → 30 s, then capped at 30 s. Reset the attempt counter on a successful,
    /// frame-delivering connect.
    public static let delays: [TimeInterval] = [1, 5, 30]

    /// Backoff delay before reconnect attempt `attempt` (1-based). Attempt 0 (or less) means
    /// "no failures yet" → reconnect immediately. Past the table it stays at the cap.
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return delays[min(attempt - 1, delays.count - 1)]
    }

    /// Cap on the backoff delay while the app is BACKGROUNDED (#119). The full 30 s cap assumes
    /// the process stays alive to finish the wait — true in the foreground, false in the
    /// background, where iOS suspends us ~10 s after the disconnect event. A suspension
    /// mid-backoff leaves NO standing pending connect, so the ring coming back in range wakes
    /// nothing and the rest of the night is lost. 8 s fits inside a background-task assertion
    /// with margin, so the pending connect is always re-issued before suspension.
    public static let backgroundDelayCap: TimeInterval = 8

    /// Backoff delay for attempt `attempt`, capped at `backgroundDelayCap` when backgrounded —
    /// the #35 charger-flap damping is a foreground luxury; in the background, re-arming the
    /// wake path before suspension always wins.
    public static func delay(forAttempt attempt: Int, inBackground: Bool) -> TimeInterval {
        let d = delay(forAttempt: attempt)
        return inBackground ? min(d, backgroundDelayCap) : d
    }

    /// After this many consecutive failed reconnect attempts, the UI should swap the permanent
    /// "Connecting…" for a calm "ring unreachable / charging — will reconnect automatically".
    public static let calmStateAttemptThreshold = 3

    /// Whether enough reconnects have failed to surface the calm state (vs. "Connecting…").
    public static func shouldSurfaceCalmState(attempts: Int) -> Bool {
        attempts >= calmStateAttemptThreshold
    }
}
