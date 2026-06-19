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

    public struct Sample: Equatable, Sendable, Codable {
        public let percent: Int
        public let at: Date
        public init(percent: Int, at: Date) { self.percent = percent; self.at = at }
    }

    // MARK: - Robust history accumulation (#86 robustness)

    /// Fold one battery reading into a persisted discharge history so the estimate survives
    /// reconnects/relaunches and stays clean (#86). Keeps the history a tidy, monotonically
    /// non-increasing discharge run by using the DECODED charging byte (#61) to disambiguate a
    /// real charge from sensor noise:
    ///   • `charging` true → a charge invalidates any discharge slope: reset the baseline to `percent`.
    ///   • lower `percent` → a genuine discharge step: append (first-seen time of each % = clean slope).
    ///   • higher by ≥ 3 pp while NOT charging → a charge we missed between frames: reset baseline.
    ///   • higher by 1–2 pp, or equal → sensor jitter at 1 % granularity: ignore (don't reset, don't grow).
    /// Then prune by age and cap (keep the most recent). Pure + deterministic for tests.
    public static func record(_ history: [Sample], percent: Int, at: Date, charging: Bool,
                              cap: Int = 60, maxAge: TimeInterval = 14 * 86_400) -> [Sample] {
        var h = history
        if charging {
            h = [Sample(percent: percent, at: at)]
        } else if let last = h.last {
            if percent < last.percent {
                h.append(Sample(percent: percent, at: at))
            } else if percent - last.percent >= 3 {
                h = [Sample(percent: percent, at: at)]
            }
            // small rise (1–2 pp) or equal while not charging → noise: leave history untouched.
        } else {
            h = [Sample(percent: percent, at: at)]
        }
        let cutoff = at.addingTimeInterval(-maxAge)
        h = h.filter { $0.at >= cutoff }
        if h.count > cap { h = Array(h.suffix(cap)) }
        return h
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

    // MARK: - Time to FULL (charging, #61-enabled)

    /// Seconds until the battery reaches `target` % (default 100), from a CHARGING history —
    /// the mirror of `timeToEmpty`. Builds the longest trailing strictly-RISING window (a falling
    /// sample resets it), requires a ≥ 2 pp rise over ≥ 2 samples, then extrapolates the slope.
    /// Returns 0 when already at/above target, or nil when too noisy / too small / implausibly
    /// fast (charging is quick — guard a generous 300 %/hr). Feed it the dedicated charge history
    /// from `recordCharge`, not the discharge history.
    public static func timeToFull(_ samples: [Sample], now: Date = Date(), target: Int = 100) -> TimeInterval? {
        guard samples.count >= 2 else { return nil }
        let sorted = samples.sorted { $0.at < $1.at }
        var window: [Sample] = []
        for s in sorted {
            if let prev = window.last {
                if s.percent > prev.percent { window.append(s) }
                else if s.percent < prev.percent { window = [s] }   // falling (unplugged) — reset
                // flat — skip
            } else {
                window.append(s)
            }
        }
        guard window.count >= 2 else { return nil }
        let first = window.first!
        let last  = window.last!
        if last.percent >= target { return 0 }
        let rise    = Double(last.percent - first.percent)
        let elapsed = last.at.timeIntervalSince(first.at)
        guard rise >= 2, elapsed > 0 else { return nil }
        let ratePerHour = rise / (elapsed / 3_600)
        guard ratePerHour <= 300 else { return nil }            // implausible — noise
        return Double(target - last.percent) / ratePerHour * 3_600
    }

    /// Fold one reading into the CHARGING history (mirror of `record`). Only meaningful while the
    /// decoded charging byte (#61) is set — when not charging it returns `[]`, so a stale charge
    /// slope can't linger past unplugging. Appends genuine rises; a ≥ 3 pp drop resets the baseline
    /// (brief contact loss); equal / tiny drops are ignored. Prunes by age (charges are short) + cap.
    public static func recordCharge(_ history: [Sample], percent: Int, at: Date, charging: Bool,
                                    cap: Int = 60, maxAge: TimeInterval = 6 * 3_600) -> [Sample] {
        guard charging else { return [] }
        var h = history
        if let last = h.last {
            if percent > last.percent {
                h.append(Sample(percent: percent, at: at))
            } else if last.percent - percent >= 3 {
                h = [Sample(percent: percent, at: at)]
            }
            // equal or tiny drop → ignore.
        } else {
            h = [Sample(percent: percent, at: at)]
        }
        let cutoff = at.addingTimeInterval(-maxAge)
        h = h.filter { $0.at >= cutoff }
        if h.count > cap { h = Array(h.suffix(cap)) }
        return h
    }

    /// True when the battery just crossed 100 % WHILE the ring is inferred to be on the
    /// charger AND we haven't already fired a "full" notification for this charge cycle.
    /// Callers set `wasFull = false` when percent drops below 100 to re-arm.
    public static func justReachedFull(percent: Int, inferredCharging: Bool, wasFull: Bool) -> Bool {
        percent >= 100 && inferredCharging && !wasFull
    }
}
