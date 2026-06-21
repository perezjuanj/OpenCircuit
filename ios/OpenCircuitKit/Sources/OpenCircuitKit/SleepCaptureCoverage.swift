// Was last night's sleep FULLY captured, or limited by the ring's onboard memory?
//
// The RingConn Gen-2 history buffer holds only ~4.75 h of epochs and DROPS THE OLDEST when full
// (PROTOCOL.md §5.3). If nothing drains the ring overnight, the early hours are overwritten before
// the morning sync, so only the last ~4.75 h survive — the user sees ~5 h for a real ~9 h night.
// Overnight draining depends on iOS background tasks, which run far more reliably while the phone is
// CHARGING. This pure helper recognises the buffer-limited signature so the UI can nudge the user to
// keep the phone charging nearby (the one lever that actually moves overnight capture). Pure (no Apple
// frameworks) so it unit-tests on the CLI.
//
// Duration ALONE can't separate "buffer-truncated" from "genuinely short night" — a 4.5 h reading is
// either. The discriminator is WHERE the loss is: truncation drops the FRONT of the night, so the
// captured ONSET lands well after the user's bedtime while the wake time looks normal. A night that
// fit inside the buffer (even a short one) has its onset captured at the real bedtime. So we flag only
// with a bedtime reference AND a late captured onset — never on duration alone (that nagged real short
// sleepers; adversarial review).

import Foundation

public enum SleepCaptureCoverage {

    /// The ring's onboard history-buffer span (seconds). ~114 epochs × 150 s ≈ 4.75 h (🟢 §5.3).
    public static let ringBufferSeconds: TimeInterval = 4.75 * 3600

    /// Slack above the buffer before a span stops looking buffer-limited (drains aren't instant; a
    /// little of the prior load can ride along). A span beyond this was drained overnight → complete.
    static let bufferSlack: TimeInterval = 20 * 60

    /// How far the captured onset must trail the scheduled bedtime before we call the front "missing".
    static let minMissingOnset: TimeInterval = 90 * 60

    public enum Coverage: Equatable, Sendable {
        /// The captured night looks complete (or we can't tell it isn't).
        case full
        /// The captured span has the buffer-limited signature — early hours were likely overwritten
        /// on the ring before any drain. The fix is overnight charging (so iOS runs the drain).
        case likelyTruncated
    }

    /// Classify last night's coverage from WHERE the capture starts relative to bedtime.
    ///
    /// - Parameters:
    ///   - capturedOnset: start of the captured in-bed window (the first staged epoch).
    ///   - capturedInBed: the staged night's in-bed span (seconds). `0`/negative ⇒ `.full`.
    ///   - scheduledBedtime: the user's bedtime for this night (from their sleep schedule), or `nil`
    ///     when no schedule is set — without it we have no reference for "the front is missing".
    /// - Returns: `.likelyTruncated` only on POSITIVE evidence: the span fits within the ring buffer
    ///   (+slack) — so it could be a single buffer-load — AND the captured onset trails bedtime by at
    ///   least `minMissingOnset` (the early hours are missing). Otherwise `.full`. A span beyond the
    ///   buffer was drained overnight (complete); an onset at/near bedtime means the whole night fit
    ///   in the buffer (complete, even if short); no schedule means we don't guess. Conservative by
    ///   design — a missed flag just omits a tip, a false flag would nag.
    public static func classify(capturedOnset: Date,
                                capturedInBed: TimeInterval,
                                scheduledBedtime: Date?) -> Coverage {
        guard capturedInBed > 0 else { return .full }
        // Drained past the buffer ⇒ nothing was lost to overflow.
        guard capturedInBed <= ringBufferSeconds + bufferSlack else { return .full }
        // No bedtime reference ⇒ can't distinguish truncation from a genuinely short night.
        guard let bedtime = scheduledBedtime else { return .full }
        // Truncation loses the FRONT: the captured onset lands well after bedtime.
        return capturedOnset.timeIntervalSince(bedtime) >= minMissingOnset ? .likelyTruncated : .full
    }
}
