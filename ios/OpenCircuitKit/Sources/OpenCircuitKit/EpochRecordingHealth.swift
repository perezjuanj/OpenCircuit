// Is the ring still WRITING history, or only still TALKING? (the stranded-sport-mode detector)
//
// ══ WHY A HEALTHY-LOOKING RING CAN BE RECORDING NOTHING ══
//
// 🟢 PROVEN on a real ring, 2026-08-16. An app crash mid-workout left the ring in sport mode with
// nobody to send `SportStop`; it then recorded ZERO `0x4c` epochs for 19 h 56 m — no HR, SpO2, HRV
// or RR, and a whole night of sleep that was never written and can never be recovered.
//
// Nothing surfaced it. Every drain in that window logged `4c=0`, and the evidence sat in the user's
// diagnostics export a FULL DAY before anyone noticed — because the app had no rule that reads it.
// The wearer found out when a night vanished.
//
// What makes it invisible is a channel split: skin temperature, battery and charge state ride the
// LIVE `0x10`/`0x87` descriptor, while HR/SpO2/HRV/RR/sleep ride the drainable `0x4c` history. In
// sport mode the descriptor keeps flowing and the history stops, so the connection reads perfectly
// healthy — current temperature, sensible battery, no errors — while nothing is being recorded.
//
// THAT SPLIT LOOKS LIKE A DETECTOR. "No epochs" alone is ordinary; "no epochs WHILE the descriptor
// is live" seems to mean the ring is powered, in range, answering us, and still writing nothing.
//
// ══ ⚠️ NOT WIRED. THIS DOES NOT SHIP ENABLED, AND HERE IS WHY ══
//
// Adversarial review took the version below apart (2026-08-16, 9 confirmed findings). The idea is
// sound; the INPUTS available to it were not, and the result would have been an alert that fires on
// a healthy ring far more often than on a broken one — the precise outcome this file was written to
// avoid. Two proven false-alarm modes, each reproduced from the code:
//
//  1. THE CURSOR IS WORN-EVIDENCE, NOT EPOCH-PRESENCE. The caller fed it the `.heartRate` sync
//     cursor, but `BulkRecord.heartRate` is nil on the `.idle` unworn template and `LocalStore`
//     rejects the 0-bpm placeholders, so an UNWORN ring advances it not at all — while the
//     keepalive keeps the descriptor seconds-fresh. A ring resting on a desk or in its charging
//     case beside the phone therefore reads as "connected and writing nothing" after 3 h, and
//     re-fires every 6 h. On the charger it is guaranteed, because `skipAutoMeasureProbe` also
//     blocks the live-HR read that would otherwise move the watermark.
//  2. THE OVERNIGHT-QUIET WINDOW MAKES EVERY NORMAL NIGHT LOOK STALLED. Automatic drains are
//     SUPPRESSED from bedtime to the learned wake — 8-10 h, by design, so the ring is not disturbed
//     — while the in-window keepalive keeps `lastRingDataAt` seconds-fresh. The first foreground on
//     waking runs the alert pass BEFORE the wake drain lands, sees an 8 h-stale cursor against a
//     30 s-old descriptor, and fires. On nearly every user, nearly every morning.
//     `staleAfter = 3 h` is also simply shorter than the app's own widest legitimate drain gap
//     (the battery-saver day arm is exactly 3 h, and both comparisons use `>=`).
//
// THE REBUILD, when someone returns to this: classify from DRAIN OUTCOMES, not from sample cursors.
// The observable that actually distinguished the proven incident was that every `history-drain`
// logged `4c=0` while completing normally — and that signal is immune to both modes above, because
// an unworn ring still yields idle epochs (`4c > 0`) and a suppressed overnight window yields no
// drains at all (no evidence, so no verdict). `HistoryChannelTrace` already carries the per-channel
// page counts. Gate additionally on `!charging`.
//
// What ships instead is the RECOVERY (`RingSession.clearStrandedSportModeIfNeeded`), which makes the
// stranded state self-healing on the next connect and therefore makes this warning far less
// load-bearing than it was when the incident happened.
//
// Pure Foundation so it unit-tests on the CLI.

import Foundation

public enum EpochRecordingHealth {

    /// How stale the newest epoch must be before we call recording stalled.
    ///
    /// Epochs are written one per 150 s, but they only reach the phone on a drain, and the drain
    /// cadence is deliberately sparse (hourly-ish, and suppressed entirely inside the overnight
    /// quiet window). So this has to clear the widest LEGITIMATE gap between drains, not the epoch
    /// interval. Three hours does that with room to spare while still catching the failure within
    /// one night rather than after it — the proven incident ran 19 h 56 m, and the `4c=0` signature
    /// was already unambiguous in an export taken 19 h before the night was lost.
    ///
    /// Erring long is the right direction: a false "not recording" on a ring that is merely
    /// undrained would train people to ignore the one warning that means their night is being lost.
    public static let staleAfter: TimeInterval = 3 * 3600

    /// How recently the live descriptor must have been heard for the ring to count as "talking".
    ///
    /// Keepalive polls the descriptor continuously while connected, so on a live link this is
    /// seconds-fresh. Fifteen minutes tolerates a brief reconnect without letting a ring that has
    /// genuinely gone away look present.
    public static let descriptorFreshWithin: TimeInterval = 15 * 60

    public enum Status: Equatable, Sendable {
        /// Epochs are current, or there is no evidence of a problem.
        case recording
        /// Not enough information to judge (no descriptor, or no epoch history at all yet).
        case unknown
        /// The ring is connected and answering, but has written no epoch history since `since`.
        /// Everything built on `0x4c` — heart rate, SpO2, HRV, respiratory rate and SLEEP — is being
        /// lost for as long as this lasts.
        case stalled(since: Date)

        public var isStalled: Bool { if case .stalled = self { return true }; return false }
    }

    /// Classify from the two timestamps that matter.
    ///
    /// - Parameters:
    ///   - newestEpochAt: device timestamp of the newest `0x4c` record we hold, or nil if none.
    ///   - newestDescriptorAt: when the live `0x10`/`0x87` descriptor was last heard, or nil.
    ///   - now: reference instant.
    ///
    /// Returns `.unknown` rather than `.stalled` whenever either input is missing: a ring we have
    /// never heard from, and a fresh install with no history, must never produce this warning.
    public static func classify(newestEpochAt: Date?,
                                newestDescriptorAt: Date?,
                                now: Date = Date(),
                                staleAfter: TimeInterval = staleAfter,
                                descriptorFreshWithin: TimeInterval = descriptorFreshWithin) -> Status {
        guard let epoch = newestEpochAt, let descriptor = newestDescriptorAt else { return .unknown }
        // The ring must be demonstrably present RIGHT NOW. Without this the rule fires on every ring
        // left in a drawer, which is the single most common benign reason for stale epochs.
        guard max(0, now.timeIntervalSince(descriptor)) <= descriptorFreshWithin else { return .unknown }
        // A future-dated epoch (ring clock drift) is clamped rather than treated as infinitely fresh.
        guard max(0, now.timeIntervalSince(epoch)) >= staleAfter else { return .recording }
        // ⚠️ THIS GUARD IS DEAD UNDER THE SHIPPED CONSTANTS AND COMPARES TWO DIFFERENT CLOCKS.
        // Review proved it unreachable-as-false at the defaults (the two guards above already force
        // a >= 9900 s gap; 0 hits over 1.46 M grid points), and it could not do its stated job
        // anyway: `epoch` is a DEVICE timestamp off the ring's own counter while `descriptor` is
        // PHONE wall-clock, so ordering them is only meaningful while the two clocks agree. Kept
        // only because it is inert, and flagged so the rebuild does not inherit it — a drain-outcome
        // classifier needs no cross-clock comparison at all.
        guard descriptor > epoch else { return .unknown }
        return .stalled(since: epoch)
    }

    /// Whole hours since recording stopped — for copy that should not read "0 hours".
    public static func stalledHours(_ status: Status, now: Date = Date()) -> Int? {
        guard case .stalled(let since) = status else { return nil }
        return max(1, Int(now.timeIntervalSince(since) / 3600))
    }
}
