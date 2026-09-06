// Is the RING no longer recording, as distinct from "we haven't synced it lately"?
//
// WHY THIS EXISTS. A Gen 2 Air tester's export showed the newest 0x4c epoch four hours old while
// the ring was connected and skin temperature — which is LIVE-only and does not come from the
// drainable history — was updating every few seconds. Home therefore rendered a completely
// healthy-looking screen whose HR was 4 h stale, HRV 12 h stale and RR 12 h stale, each frozen at
// a different moment because each metric rides a different subset of epochs. The tester had to
// work that out by reading timestamps. Nothing in the app said the recorder had stopped.
//
// The stalls are real and they are much worse on Gen 2 Air. Measured over the committed corpus
// plus that export, as a share of each capture's own span with no epochs at all:
// FR02.018 0.0 % / 0.0 % / 11.9 %; FR04.009 16.2 % / 32.0 % / 88.1 %. Three FR04 captures from
// three different people all show multi-hour holes; two of three FR02 captures have none.
//
// ⚠️ THE HARD PART IS NOT DETECTION, IT IS NOT LYING. Two failure modes have to stay separable:
//   • we have not drained recently                       → "not synced"; say nothing about the ring;
//   • we drained, it completed, and the head did not move → the ring recorded nothing.
// And ONE completed-but-empty drain does not prove the second. A drain that exited on the
// `endMarker`/`complete` path has been observed handing over more epochs on each of the next two
// opens, so a single empty drain is evidence of nothing. Hole PERSISTENCE across drains is the
// signal; `minimumUnmovedDrains` is that rule expressed as a number.

import Foundation

public enum RecorderStall {

    /// Completed drains that must each leave the archive head UNMOVED before we will tell a user
    /// the ring stopped recording.
    ///
    /// 🟢 2 is the documented floor, not a tuned one: a drain exiting `endMarker`/`complete` was
    /// observed handing over 2 MORE epochs on each of the next two opens, so at n=1 this predicate
    /// would call a stall on a ring that is merely slow to hand over. Raising it further only
    /// delays a true warning; lowering it to 1 reintroduces that false positive.
    public static let minimumUnmovedDrains = 2

    /// How stale the newest epoch must be before staleness is worth mentioning at all.
    ///
    /// 🟢 The healthy recording cadence is 150 s — the MEDIAN inter-epoch gap is exactly 150 s on
    /// all six captures measured (three FR02.018, three FR04.009), regardless of generation. Two
    /// hours is therefore ~48 missed epochs: far outside normal cadence and outside any plausible
    /// drain latency, while still well short of the 4 h / 7.6 h / 17 h stalls actually observed.
    public static let staleAfter: TimeInterval = 2 * 3600

    /// What the app is entitled to say about the recorder right now.
    public enum Verdict: Equatable, Sendable {
        /// The head is fresh, or not stale enough to mention.
        case recording
        /// Stale, but we have not proven the ring is at fault — we simply have not drained it
        /// enough times to know. The UI must phrase this as OUR uncertainty, never as a ring fault.
        case unknownNotDrained
        /// Charging (or docked): the ring legitimately stops recording, so a hole here is expected
        /// and must never be reported as a fault.
        case expectedWhileCharging
        /// `minimumUnmovedDrains` completed drains in a row left the head unmoved while it went
        /// this stale. The ring is not recording.
        case stalled(since: Date)
    }

    /// Decide what may be said about a ring's recorder.
    ///
    /// - `newestEpochAt`: timestamp of the newest 0x4c epoch held for THIS ring, nil if none.
    /// - `completedDrainsSinceHeadMoved`: how many drains have COMPLETED (reached the ring's own
    ///   end-of-history — not `linkDown`, not cancelled, not "no drain ran") since `newestEpochAt`
    ///   last advanced. Counting ATTEMPTS rather than completions would let a flaky link
    ///   masquerade as a dead recorder — the exact confusion `.linkDown` was split out of `.noAck`
    ///   to prevent.
    /// - `isCharging`: the ring stops recording on the charger; that hole is expected.
    public static func verdict(newestEpochAt: Date?,
                               completedDrainsSinceHeadMoved: Int,
                               isCharging: Bool,
                               now: Date = Date()) -> Verdict {
        guard let newestEpochAt else { return .unknownNotDrained }
        guard now.timeIntervalSince(newestEpochAt) >= staleAfter else { return .recording }
        if isCharging { return .expectedWhileCharging }
        guard completedDrainsSinceHeadMoved >= minimumUnmovedDrains else { return .unknownNotDrained }
        return .stalled(since: newestEpochAt)
    }
}
