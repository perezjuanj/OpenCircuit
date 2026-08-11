import Foundation

/// What actually happened when a drain tried to STORE a night's summary (#204).
///
/// ⚠️ THIS EXISTS BECAUSE "WE STAGED A NIGHT" AND "THE WEARER HAS A NIGHT" ARE DIFFERENT CLAIMS,
/// and the app used to report only the first. 🟢 MEASURED on a Gen-3 tester's schema-3 export
/// (FR05.010, build 39, range 2026-08-09 → 2026-08-12): the file carries `"sleep": []`, no
/// `sleepSessions` key at all, and 3 naps — while the Sleep card was showing a full 8 h 31 m night
/// with a hypnogram. `provenance` carries exactly the 7 base keys and none of the `sleepSessions.*`
/// ones, which `ExportEngine` adds only for a non-empty session array, so the array was empty AT
/// BUILD TIME: no `StoredSleepSummary` row ever existed. Meanwhile `historySyncEvidence` reported
/// `sleepCommitted: true` on drain after drain.
///
/// The write path had four ways to store nothing and only one of them said so:
///   • the night-key migration had not succeeded, so the write was deferred (throws);
///   • the overnight gate left no staged segments, so nothing was offered;
///   • merge protection or the wearer's own edit deliberately kept the stored night;
///   • the night-key collision guard refused the write (the only branch that logged).
/// `saveSleepSummary` is called through `try?`, so a throw was swallowed with no log, no metric and
/// no user-visible signal — and the card then fell through to LIVE in-memory staging, showing a
/// night that would vanish on the next launch and never reach Apple Health.
///
/// Lives in the Kit, not the app target, so the meaning of each branch is asserted by tests rather
/// than inferred at the call site, and so `sleepCommitted` can be defined against `wroteRow` in one
/// place.
public enum SleepPersistOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    /// A new row was inserted for this night.
    case inserted
    /// An existing row was refreshed from this staging.
    case updated
    /// Merge protection kept the stored night because it is at least as complete (`SleepSummaryMerge`).
    /// NOT a failure: the wearer has the better night.
    case keptFullerStoredNight
    /// The wearer manually edited this night (#176) and the edit is authoritative. NOT a failure.
    case keptManualEdit
    /// A DIFFERENT night already owns this key and the incoming block is an unfinished evening bout,
    /// so the write was refused rather than allowed to evict it.
    case refusedNightKeyCollision
    /// Staging produced no segments — the overnight gate rejected the block, so nothing was offered
    /// to the store. The night is not stored and nothing is protecting it.
    case noStagedSegments
    /// The one-shot night-key migration has not succeeded yet, so the write was deferred rather than
    /// filed under a scheme the rest of the table has not adopted. Recoverable: the epochs are still
    /// in the 30 h archive and the next drain re-stages them.
    case deferredNightKeyMigration
    /// The store threw. Previously swallowed by `try?`.
    case failed

    /// Whether a `StoredSleepSummary` row now reflects THIS staging. This — not "the stage path ran"
    /// — is what `historySyncEvidence.sleepCommitted` means.
    public var wroteRow: Bool { self == .inserted || self == .updated }

    /// Whether the night is represented by a stored row at all. The two deliberate keeps count: the
    /// wearer has a night, it just isn't the one this drain staged.
    public var nightIsStored: Bool {
        wroteRow || self == .keptFullerStoredNight || self == .keptManualEdit
    }

    /// No stored row backs this night and nothing deliberately kept one — the state in which the
    /// Sleep card can display a night the stored pipeline never computed. The only outcomes that
    /// should ever reach the wearer as a warning.
    public var isSilentLoss: Bool { !nightIsStored }

    /// Whether the same drain, repeated, could still land the night. `refusedNightKeyCollision` is
    /// permanent for this staging (every retry hits the same guard); the other two losses are not.
    public var isRecoverableByRetry: Bool {
        self == .deferredNightKeyMigration || self == .noStagedSegments || self == .failed
    }
}
