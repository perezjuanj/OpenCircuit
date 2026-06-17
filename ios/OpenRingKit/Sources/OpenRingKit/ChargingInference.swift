// Charging-state inference from the battery % trend (#60).
//
// The ring's charging state is NOT on the wire in any confirmed byte (PROTOCOL.md §5).
// The closest 🟢 proxy is the battery % in the 0x10/0x87 descriptor: if a short window of
// consecutive readings is strictly rising the ring is *inferred* to be charging. This is
// deliberately conservative — "inferred" only fires when we hold ≥ 2 readings that are ALL
// strictly rising; a single-reading window or any non-monotone pattern returns false.
//
// Rule: never claim CERTAINTY from this signal. Callers label the result "inferred".

import Foundation

public enum ChargingInference {

    /// True when `trend` is a strictly rising sequence — every consecutive pair increases —
    /// suggesting the ring may be charging (🟢 proxy). Requires ≥ 2 readings.
    ///
    /// Examples:
    ///   - []          → false  (no data)
    ///   - [75]        → false  (single reading)
    ///   - [74, 76]    → true   (two rising readings)
    ///   - [74, 76, 78]→ true   (three rising readings)
    ///   - [75, 75]    → false  (flat — discharging or noise)
    ///   - [80, 78]    → false  (falling — discharging)
    ///   - [74, 76, 75]→ false  (not all rising)
    public static func inferred(from trend: [Int]) -> Bool {
        guard trend.count >= 2 else { return false }
        return zip(trend, trend.dropFirst()).allSatisfy { $0 < $1 }
    }
}
