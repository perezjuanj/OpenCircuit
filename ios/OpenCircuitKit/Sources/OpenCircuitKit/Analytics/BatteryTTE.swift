// Battery time-to-empty estimate from a rolling discharge history (#86).
//
// Algorithm (pure, no BLE):
//   1. Sort samples by time and extract the strictly-DISCHARGING window (percent falls
//      monotonically). Any rising run (charging) resets the window — we want a clean
//      discharge slope. A flat run is skipped.
//   2. Require drop ≥ 2 pp across the window (below that it's noise from the sensor's
//      1 % granularity) and at least 2 samples.
//   3. Compute rate = drop / elapsed_hours.
//   4. Guard rate ≤ 50 %/hr — higher implies a charger was plugged/unplugged mid-window
//      and the slope is garbage.
//   5. TTE = last_percent / rate × 3600 seconds.
//
// All `now` parameters are explicit so tests are deterministic.

import Foundation

public enum BatteryTTE {

    // MARK: - Sample

    public struct Sample: Equatable, Sendable {
        public let percent: Int
        public let at: Date
        public init(percent: Int, at: Date) { self.percent = percent; self.at = at }
    }

    // MARK: - Core estimate

    /// Seconds until the battery reaches 0 %, or nil when the window is too noisy /
    /// too small / actively charging / implausible.
    public static func timeToEmpty(_ samples: [Sample], now: Date = Date()) -> TimeInterval? {
        guard samples.count >= 2 else { return nil }

        // Build the longest trailing strictly-discharging window.
        let sorted = samples.sorted { $0.at < $1.at }
        var window: [Sample] = []
        for s in sorted {
            if let prev = window.last {
                if s.percent < prev.percent {
                    window.append(s)
                } else if s.percent > prev.percent {
                    // Rising sample (charging) — reset the window; start fresh at this point.
                    window = [s]
                }
                // Flat (equal) — skip; neither confirms discharge nor resets.
            } else {
                window.append(s)
            }
        }

        guard window.count >= 2 else { return nil }
        let first = window.first!
        let last  = window.last!
        let drop    = Double(first.percent - last.percent)
        let elapsed = last.at.timeIntervalSince(first.at)   // seconds
        guard drop >= 2, elapsed > 0 else { return nil }

        let ratePerHour = drop / (elapsed / 3_600)
        guard ratePerHour <= 50 else { return nil }          // implausible — charger event

        let tte = Double(last.percent) / ratePerHour * 3_600
        return tte > 0 ? tte : nil
    }

    /// The estimated wall-clock time at which the battery reaches 0 %, or nil.
    public static func estimatedDepletionDate(_ samples: [Sample], now: Date = Date()) -> Date? {
        guard let tte = timeToEmpty(samples, now: now) else { return nil }
        return now.addingTimeInterval(tte)
    }

    /// True when the battery just crossed 100 % WHILE the ring is inferred to be on the
    /// charger AND we haven't already fired a "full" notification for this charge cycle.
    /// Callers set `wasFull = false` when percent drops below 100 to re-arm.
    public static func justReachedFull(percent: Int, inferredCharging: Bool, wasFull: Bool) -> Bool {
        percent >= 100 && inferredCharging && !wasFull
    }
}
