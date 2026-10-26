import Foundation
import OpenCircuitKit

/// Decision 72 (#278): what one strap sync made of its sleep-session round, as counts only, so the
/// diagnostics bundle can tell "the strap never sent a second `0x48` record" from "it was sent and
/// dropped". No time, no length, no sample value: the line is safe to export.
struct StrapSleepRoundSummary: Equatable {
    /// 72a: distinct `0x48` records received this sync (one sent in two rounds counts once).
    var records = 0
    /// Of those, the sessions `night(from:now:)` staged (non-nil).
    var staged = 0
    /// The strap's own nights after the stitch, and how many raw sessions the stitch joined into the
    /// nights that are more than one (0 when none was joined).
    var nights = 0
    var joinedSessions = 0
    /// Store outcomes of the nights offered this sync.
    var outcomes: [SleepPersistOutcome: Int] = [:]
    /// Decision 28f / 58b: sleeps kept out of a night already in Apple Health (os_log only until now).
    var keptOut58b = 0
    var napsStored = 0
    var napsUnsettled = 0
    var napsTooShort = 0
    /// Staged sessions whose end is after the newest stored night's end (all of them when no night is stored).
    var endsAfterNewestNight = 0
    /// 72b: `0x01` minutes of kind sleep (`0x78`) in the 24 h before the sync that lie outside every
    /// staged session's in-bed span.
    var activitySleepMinutesOutsideSessions = 0
    /// Decision 73c: the activity sleep blocks this sync judged (not one still in progress, 73d) that
    /// joined a session's night, and those that would have stood alone and were used nowhere.
    var activityBlocksJoined = 0
    var activityBlocksAlone = 0
    /// Decision 76f: of `napsStored`, the naps that hold a standalone activity block; and the standalone
    /// blocks taken as the provisional main sleep of a night no stored night covers (stored nowhere).
    var napsFromBlocks = 0
    var mainOnlyBlocks = 0

    /// The one breadcrumb line. Digits only; no clock time.
    var text: String {
        func n(_ outcome: SleepPersistOutcome) -> Int { outcomes[outcome, default: 0] }
        let named: Set<SleepPersistOutcome> = [.inserted, .updated, .keptFullerStoredNight, .ownedByOtherDevice,
                                               .refusedNightKeyCollision, .keptManualEdit]
        let other = outcomes.filter { !named.contains($0.key) }.values.reduce(0, +)
        return "sleep round: records=\(records) staged=\(staged) nights=\(nights) (joined \(joinedSessions)) "
            + "outcomes: inserted=\(n(.inserted)) updated=\(n(.updated)) keptFuller=\(n(.keptFullerStoredNight)) "
            + "ownedByOther=\(n(.ownedByOtherDevice)) keyCollision=\(n(.refusedNightKeyCollision)) "
            + "manualEdit=\(n(.keptManualEdit)) keptOut58b=\(keptOut58b) other=\(other); "
            + "naps: stored=\(napsStored) unsettled=\(napsUnsettled) tooShort=\(napsTooShort)"
            // Decision 76f: each only when non-zero, so every line without one is the line shipped before.
            + (napsFromBlocks > 0 ? " napsFromBlocks=\(napsFromBlocks)" : "")
            + (mainOnlyBlocks > 0 ? " mainOnlyBlocks=\(mainOnlyBlocks)" : "") + "; "
            + "endsAfterNewestNight=\(endsAfterNewestNight); "
            + "activity sleep min outside sessions (24 h)=\(activitySleepMinutesOutsideSessions)"
            // Only when there was a block, so a sync without one leaves the line decision 72 shipped.
            + (activityBlocksJoined + activityBlocksAlone > 0
                ? "; activity blocks: joined=\(activityBlocksJoined) alone=\(activityBlocksAlone)" : "")
    }
}
