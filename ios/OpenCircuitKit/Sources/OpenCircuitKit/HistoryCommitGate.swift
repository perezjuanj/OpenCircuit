// Whether a finished history drain may stage and persist the night (#188).
//
// This was an inline two-branch condition in `RingSession.commitDrainedRecords`, which made the
// most consequential decision in the sync pipeline untestable. It is extracted here so the rules
// below are asserted directly rather than inferred by reading.
//
// THE TWO RULES IT ENCODES
//
//  1. CONSERVATIVE STAGING (pre-existing, protected by TruncatedNightGateTests /
//     SleepCaptureCoverageTests). A partial / PPG-only / no-ack sleep drain must NOT overwrite a
//     fuller stored night, so staging requires `outcome == .complete` — see
//     `HistoryChannelOutcome.allowsSleepCommit` — AND some fresh records to stage from.
//
//  2. THE ADOPTED-NIGHT RESCUE (#188). `outcome` describes what THIS drain pulled off the wire and
//     says nothing about records the app ACKed earlier with no drain open (see
//     `UnattributedPageBuffer`). The Gen 2 Air tester's 2026-08-04 case is exactly that: the ring
//     streamed her whole 7.8 h night to a closed gate, and her drain's own sleep channel then came
//     back `.empty`. Rule 1 alone leaves that night durable in the archive but hidden behind a
//     truncated summary. So an adopted set earns a RE-STAGE FROM THE ARCHIVE UNION — deliberately
//     the weaker action, because it reads the merged union rather than this drain's slice and goes
//     through the merge-protected `saveSleepSummary`, which can only GROW a night, never shrink the
//     fuller one rule 1 is protecting.

import Foundation

public enum HistoryCommitGate {

    public enum Decision: String, Equatable, Sendable {
        /// Stage from this drain's night slice and persist (the full commit).
        case stage
        /// Do not stage this slice, but re-stage from the persisted archive union — the rescue path
        /// for records adopted from an out-of-drain stream.
        case restageFromArchive
        /// Neither. Raw records are still kept; only staging is withheld.
        case skip
    }

    /// - Parameters:
    ///   - outcome: this drain's SLEEP-channel outcome (`nil` when the channel never ran).
    ///   - recordsAdded: records this drain pulled off the wire itself.
    ///   - adoptedRecordCount: records adopted from the unattributed buffer — already ACKed by us,
    ///     already merged into the archive, simply older than this drain's own trace.
    public static func decide(outcome: HistoryChannelOutcome?,
                              recordsAdded: Int,
                              adoptedRecordCount: Int) -> Decision {
        let hasFreshRecords = recordsAdded > 0 || adoptedRecordCount > 0
        if outcome?.allowsSleepCommit == true, hasFreshRecords { return .stage }
        // A drain that never ran its sleep channel at all (`outcome == nil`) has no breadcrumb to
        // reason from, but adopted records are self-evidently real — rescue them either way.
        if adoptedRecordCount > 0 { return .restageFromArchive }
        return .skip
    }
}
