// Step accumulation (#34). The ring's onboard step field (0x10/0x87 descriptor `[4:6]`,
// 16-bit big-endian, DeviceStatus.steps) is the ring's CURRENT DAY count. Re-reading the
// descriptor while connected therefore must add only the SAME-DAY increment between successive
// observations, not the full raw count every time. But once the calendar day changes, the next
// raw value is already "steps so far TODAY" and must be credited in full — otherwise a first
// reconnect at noon would miss the steps taken earlier that morning.
//
// This type is the pure, unit-tested core of that fold. `RingSession` persists the last raw
// counter + its day across sessions (UserDefaults) and `LocalStore` upserts the resulting
// delta into the per-day rollup; both stay thin callers so the tricky reset/midnight cases
// live here where they can be tested without CoreBluetooth or SwiftData.
//
// Pure (no Apple frameworks beyond Foundation) so it runs on the SwiftPM CLI.

import Foundation

/// Outcome of folding one raw counter observation into the running daily total.
public struct StepUpdate: Equatable, Sendable {
    /// Steps to add to the SAMPLE day's running total. Always `>= 0` — never negative, so a
    /// caller can add it blindly without re-checking for a drop.
    public let deltaToAdd: Int
    /// The raw counter dropped below the last reading within the SAME day: reboot/firmware reset
    /// or a 16-bit wrap. When true, `newRaw` itself is taken as the post-reset count
    /// (`deltaToAdd == newRaw`), not `newRaw - previousRaw`.
    public let isReset: Bool
    /// A reset that is NOT explained by a day rollover — i.e. the counter dropped *mid-day*.
    /// A drop across midnight is the official app's expected daily reset; a drop within the
    /// same day is unexpected (handoff/reboot/wrap) and worth logging (#34). Always false when
    /// `isReset` is false.
    public let isAnomalousReset: Bool

    public init(deltaToAdd: Int, isReset: Bool, isAnomalousReset: Bool) {
        self.deltaToAdd = deltaToAdd
        self.isReset = isReset
        self.isAnomalousReset = isAnomalousReset
    }
}

public enum StepAccumulator {
    /// Fold a freshly observed raw counter against the last one we recorded.
    ///
    /// - Parameters:
    ///   - previousRaw: the last raw counter we persisted, or `nil` when there is no prior
    ///     reading (first run ever / fresh pairing / app reinstall wiped both the day-totals
    ///     and this baseline together). With no baseline the only honest thing we can do is
    ///     treat `newRaw` as "today so far" — crediting 0 would silently drop every step the
    ///     user already took before we first saw the ring that day.
    ///   - newRaw: the counter just observed (`DeviceStatus.steps`, 0…65535).
    ///   - dayChanged: the sample's calendar day differs from the day `previousRaw` was
    ///     observed. On a new day, `newRaw` is already that day's total and must be credited
    ///     in full; within the same day we only credit the increment over `previousRaw`.
    public static func update(previousRaw: Int?, newRaw: Int, dayChanged: Bool) -> StepUpdate {
        guard let previous = previousRaw else {
            // No baseline — recover today's already-accumulated count instead of dropping it.
            return StepUpdate(deltaToAdd: newRaw, isReset: false, isAnomalousReset: false)
        }
        if dayChanged {
            // New calendar day: the descriptor reports THIS day's count so far. Do not subtract
            // yesterday's baseline, even if today's raw has already climbed past it.
            return StepUpdate(deltaToAdd: newRaw, isReset: newRaw < previous, isAnomalousReset: false)
        }
        if newRaw >= previous {
            // Same-day monotonic climb: add only the newly-taken steps since the last reading.
            return StepUpdate(deltaToAdd: newRaw - previous, isReset: false, isAnomalousReset: false)
        }
        // Same-day drop: reboot/wrap/firmware reset. Preserve the new raw count but surface the
        // anomaly so the caller can log it.
        return StepUpdate(deltaToAdd: newRaw, isReset: true, isAnomalousReset: true)
    }
}
