// Step accumulation (#34). The ring's onboard step count (0x10/0x87 descriptor `[4:6]`,
// 16-bit big-endian, DeviceStatus.steps) is a SINCE-HANDOFF delta, not a daily total: the
// official app sums it in local memory and periodically RESETS the ring's counter. If the
// official app isn't running, the ring's counter just keeps climbing (it does NOT reset at
// midnight on its own). So a usable daily total has to be reconstructed by folding the
// incremental deltas between successive raw readings — reset-aware, and stamped to the day
// the reading was sampled.
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
    /// The raw counter dropped below the last reading: the official app reset / took over the
    /// since-handoff counter (or the ring rebooted, or the 16-bit counter wrapped). When true,
    /// `newRaw` itself is taken as the post-reset count (`deltaToAdd == newRaw`), not
    /// `newRaw - previousRaw`.
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
    ///     reading (first run ever / no persisted state). With no baseline we cannot know how
    ///     many of the raw steps are "ours" vs. taken before we ever connected, so we count
    ///     none and just adopt `newRaw` as the baseline (`deltaToAdd == 0`).
    ///   - newRaw: the counter just observed (`DeviceStatus.steps`, 0…65535).
    ///   - dayChanged: the sample's calendar day differs from the day `previousRaw` was
    ///     observed. Only affects whether a reset is flagged as anomalous — the delta math is
    ///     identical across midnight because the ring's counter is monotonic between resets, so
    ///     the incremental delta is always the correct amount to credit the new (sample) day.
    public static func update(previousRaw: Int?, newRaw: Int, dayChanged: Bool) -> StepUpdate {
        guard let previous = previousRaw else {
            // No baseline — adopt this reading as the baseline, count nothing.
            return StepUpdate(deltaToAdd: 0, isReset: false, isAnomalousReset: false)
        }
        if newRaw >= previous {
            // Monotonic climb (same day, or across midnight with the official app not running):
            // the incremental delta is the steps taken since the last reading.
            return StepUpdate(deltaToAdd: newRaw - previous, isReset: false, isAnomalousReset: false)
        }
        // Counter dropped: the official app reset/handed-off the since-handoff counter (or the
        // ring rebooted, or the 16-bit counter wrapped). `newRaw` is the post-reset count. A
        // mid-day drop is unexpected and surfaced as anomalous; a drop across midnight is the
        // official app's normal daily reset.
        return StepUpdate(deltaToAdd: newRaw, isReset: true, isAnomalousReset: !dayChanged)
    }
}
