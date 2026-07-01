// Aggregate-pattern decode-sanity check (firmware-drift risk, CLAUDE.md: protocol observations
// are pinned to one FW version). Per-field clamps (e.g. LiveHR.validBPM) already catch single
// implausible values; this is about PATTERNS across a whole drain/session that a single-value
// clamp can't see — the kind of thing a firmware update silently changing a byte's meaning would
// produce, and that would otherwise only surface as a user noticing "my numbers look wrong."
//
// Deliberately conservative: each check requires a STRUCTURAL signal (enough worn epochs, a
// SUSTAINED run of bad readings), not a single bad sample — a single implausible reading is
// already handled by the existing per-field guards and is not, on its own, evidence of format
// drift. Pure/testable; the app layer (RingSession) decides what to do with the result
// (currently: surface it in the activity log via ObservabilityStore).

import Foundation

public enum DecodeAnomaly: String, CaseIterable, Sendable {
    /// A drained night/session had enough WORN epochs to expect heart rate, but every single one
    /// decoded HR as nil (PROTOCOL.md §5.3's `[4]` field). Sparse/empty syncs (shared resume
    /// pointer contention, already-drained backlog) are NOT this — they have few or no records at
    /// all, which `minWornEpochs` guards against; this is "we got data, but the one field that
    /// should always be there on a worn epoch never decoded."
    case allZeroHRWhileWorn
    /// A SUSTAINED run of live skin-temperature readings outside a wide physical sanity band —
    /// not a single spike (the donning/charger transients documented in PROTOCOL.md §5.4 are
    /// real and expected), but enough consecutive readings to suggest the byte offset itself
    /// has shifted rather than a normal physical transient.
    case skinTempOutOfPhysicalRange

    /// Detect `.allZeroHRWhileWorn` over one drain's decoded records. `minWornEpochs` guards a
    /// near-empty/contended sync (few records is normal and NOT an anomaly) from a genuinely
    /// suspicious "got data, but none of it has HR" pattern.
    public static func detect(records: [BulkRecord], minWornEpochs: Int = 5) -> Set<DecodeAnomaly> {
        let worn = records.filter { $0.layout != .idle }
        guard worn.count >= minWornEpochs, worn.allSatisfy({ $0.heartRate == nil }) else { return [] }
        return [.allZeroHRWhileWorn]
    }

    /// Detect a SUSTAINED (not single-spike) implausible skin-temperature run in a sequence of
    /// live descriptor readings (°C). Requires `sustainedRun` consecutive out-of-band readings —
    /// a single bad sample resets the run rather than flagging immediately, so a normal
    /// donning/charger transient (one or two odd readings) never fires this.
    public static func hasSustainedTemperatureAnomaly(
        _ readingsC: [Double], minC: Double = 15, maxC: Double = 45, sustainedRun: Int = 5
    ) -> Bool {
        var run = 0
        for r in readingsC {
            if r < minC || r > maxC {
                run += 1
                if run >= sustainedRun { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}
