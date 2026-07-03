// Estimate walking/running distance from decoded step count (#81).
//
// PROTOCOL.md §5.3.1: distance is NEVER on the wire — the official RingConn app
// computes it client-side as `steps × ~0.248 m` (`pp.txt` L102573, `distCal`), a
// FIXED per-step constant, not personalized by the wearer's height or sex. (The
// earlier height-based ACSM stride formula this file used was a reasonable guess
// before that decompile finding, but it doesn't match what the app itself shows.)
// This is still an ESTIMATE, not a decoded device value — just the same estimate
// the official app makes, instead of a generic anthropometric one.
//
// HealthKit target: `.distanceWalkingRunning` (written by HealthKitWriter, not
// stored as a ring sample in LocalStore).

import Foundation

public enum DistanceEstimate {

    /// RingConn's own per-step distance constant (🟢 confirmed via APK decompile,
    /// PROTOCOL.md §5.3.1) — fixed, not derived from the user's height or sex.
    public static let metersPerStep = 0.248

    /// Estimated distance in metres from step count. ESTIMATE — mirrors the
    /// official app's own derivation (steps × `metersPerStep`), not GPS or a
    /// decoded device value. Returns 0 for non-positive step counts.
    public static func meters(steps: Int) -> Double {
        guard steps > 0 else { return 0 }
        return Double(steps) * metersPerStep
    }
}
