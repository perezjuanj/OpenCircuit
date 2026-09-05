import Foundation

/// Testable classification of one history-drain channel outcome. The BLE session populates the
/// trace incrementally while draining; this pure layer turns that trace into a conservative
/// success/failure verdict for downstream sleep persistence.
public enum HistoryChannelOutcome: String, Codable, Sendable {
    /// ⚠️ MEANS "THIS CHANNEL OPEN ENDED CLEANLY" — pages arrived and the drain exited on a `0x50`
    /// end-marker (or went quiet after pages). It does NOT mean the RING IS EMPTY, and reading it
    /// that way is how a truncated night gets called healthy.
    ///
    /// 🟢 Device-proven false twice inside FIVE MINUTES on 2026-08-26 (Gen 2 Air FR04.009, build 48;
    /// three consecutive drains at 04:47:44 / 04:49:43 / 04:52:41 UTC, `historySyncEvidence` blobs
    /// decoded from that tester's Data Export — health data, so it is not in the repo, per CLAUDE.md):
    /// the 04:47:44 drain exited `endMarker`/`.complete` with its newest record at 02:42:30, and the
    /// next two opens delivered 02:45:00 and 02:47:30. The `0x50` reports where the ring's resume
    /// pointer stood AT THAT MOMENT; the ring keeps recording, so "cleanly finished" and "nothing
    /// left" are different facts. `.complete` is only ever a statement about the OPEN, never about
    /// the device. It is the one outcome that unlocks `allowsSleepCommit` for that reason: a clean
    /// exit means what we pulled is trustworthy to stage, not that we pulled everything there is.
    case complete
    case empty
    case partial
    case ppgOnly
    /// Pages arrived, but every one was a `0x4d` sport record — no `0x4c` epoch, no `0x47` PPG.
    /// This is the NORMAL shape of a healthy sport-channel (0x02) drain. Split out of `.empty`
    /// (2026-08-27) because before this the two were indistinguishable, which is why the project's
    /// own notes say "the RING returns EMPTY sport history": the instrument could not tell a drain
    /// full of workout history from a channel that returned nothing. Like every non-`.complete`
    /// outcome it does not allow a sleep commit — sport records carry no sleep epochs.
    ///
    /// ⚠️ NOT a proof that the SPORT CHANNEL was the source. `0x4d` is the per-epoch record, and
    /// the sport channel is not its only emitter: `docs/RUNBOOK_OSA_APNEA.md` (§Opcodes) records a
    /// brief `0x4d` burst at OSA ASSESSMENT START, which is pushed rather than requested and can
    /// therefore land on whatever trace happens to be open. So on a non-sport channel read this as
    /// "some `0x4d` arrived during this open and no epoch/PPG page did", not as "the ring sent
    /// workout history on the sleep channel". Cross-check `label`/`channel` before concluding.
    case sportOnly
    case noAck
    /// The channel's sync-open never reached the wire — the BLE link was down or half-open, so
    /// `RingSession.write` dropped the commands. Split out of `.noAck` (2026-07-27) because the two
    /// were being conflated in tester diagnostics and they mean opposite things: `.noAck` says the
    /// RING was asked and stayed silent (a protocol/cursor signal worth investigating), while this
    /// says WE never asked (a connectivity problem, and the ring is exonerated). A tester export
    /// showing 27 all-day `noAck`s looked like a ring-side channel limit; it was a flaky link.
    case linkDown
    /// The channel was still waiting on the ring (no ACK, no pages) when OUR OWN session was torn
    /// down — a BLE reconnect replaced it mid-wait. Split out of `.noAck` (2026-09-04) for the same
    /// reason `.linkDown` was: the two mean opposite things. `.noAck` says a LIVE link sat idle and
    /// the ring never answered; this says the question was still in flight when we stopped listening
    /// for our own reasons, so the ring is exonerated and no protocol signal should be inferred. A
    /// tester export dominated by "session replaced — no drain ran" with `all-day`/`sport` `noAck`
    /// on nearly every cycle (while `sleep`, going first in the foreground plan, occasionally won the
    /// race) looked like the ring refusing those channels; it was session churn cutting them off
    /// before their turn. See `HistoryDrainPlan.resuming` for how this is used to recover.
    case cancelled

    /// Safe to re-stage/persist sleep from this channel.
    public var allowsSleepCommit: Bool { self == .complete }
}

public enum HistoryChannelExitReason: String, Codable, Sendable {
    case endMarker
    case quietAfterPages
    case quietNoPages
    case hardTimeout
    case cancelled
    /// Abandoned because the link went unusable — either the opens could not be written at all, or
    /// it dropped mid-drain. Distinct from `.hardTimeout`/`.quietNoPages`, which mean we waited out
    /// a live link and heard nothing.
    case linkUnusable
}

public struct HistoryChannelTrace: Equatable, Codable, Sendable {
    public let label: String
    public let channel: UInt8
    public let startedAt: Date
    public var finishedAt: Date?
    public var sawSyncAck = false
    public var syncAckFlag: UInt8?
    /// 0x82 byte[1] == 0xff — ring signals its history pointer is already at end (🟡 probable,
    /// first observed 2026-06-28: `82 ff 00 7d` on the all-day channel after the sleep channel
    /// was already drained. byte[1]=0x00 in prior real-cursor ACKs that DID stream pages).
    /// When true with no pages, the drain can exit early instead of waiting the full 45s cap.
    public var sawEmptyHistorySignal = false
    /// The channel's sync-open commands never reached the wire — `RingSession.write` dropped them
    /// because the link was down or half-open. Drives `.linkDown`.
    ///
    /// OPTIONAL ON PURPOSE, do not "tidy" it to a defaulted `Bool`. `ObservabilityStore` persists
    /// these traces as JSON and decodes them with `try? JSONDecoder().decode([HistorySyncEvidence]…)`,
    /// falling back to `[]` on any error. Swift's SYNTHESIZED decoder does not fall back to a
    /// property's default when its key is absent — it throws `keyNotFound` — so adding a
    /// non-optional field here would make every previously-stored evidence bundle fail to decode
    /// and silently wipe the user's whole diagnostics history on upgrade. An Optional decodes via
    /// `decodeIfPresent` and simply reads back `nil` for traces written before this field existed.
    public var openWriteFailed: Bool?
    public var page4CCount = 0
    public var page47Count = 0
    /// `0x4d` pages seen on this channel — the per-epoch SPORT record (#179). The sport channel
    /// (`0x02`) is the only channel that streams it AS HISTORY; it is not the only emitter, because
    /// an OSA assessment also pushes a brief `0x4d` burst at start (`docs/RUNBOOK_OSA_APNEA.md`,
    /// §Opcodes), so do not read a non-zero count on another channel as workout history. Nothing
    /// counted `0x4d` anywhere before 2026-08-27, so a sport drain FULL of workout history
    /// classified `.empty` and exported as such: "auto-detect doesn't work for walks" was
    /// structurally unanswerable from a bundle.
    /// Counted from the WIRE (before decode) on purpose, so it stays true even when a page fails
    /// its XOR — a page/sample disagreement is then itself the signal that decoding, not the ring,
    /// is at fault.
    ///
    /// OPTIONAL ON PURPOSE — see the `openWriteFailed` note above; a non-optional field here wipes
    /// every stored evidence bundle on upgrade. Zeroed by `init`, so on a trace THIS build produced
    /// it is always a measured count and `nil` means exactly one thing: the bundle was written
    /// before the counter existed. That distinction is the whole point — "we counted and it was
    /// zero" and "we never counted" are the two readings this change exists to separate.
    public var page4DCount: Int?
    /// Sport SAMPLES decoded out of those `0x4d` pages (`HistoricalSportFrame.decode`). Same
    /// Optional/zero-init contract as `page4DCount`. Kept separate from the page count because the
    /// pair is the diagnostic: pages > 0 with samples == 0 says the channel delivered and OUR
    /// decode dropped it; both zero on an acked channel says the ring really had nothing.
    public var sportSampleCount: Int?
    public var endMarkerCount = 0
    public var recordsAtStart = 0
    public var recordsAtEnd = 0
    public var firstOpcode: UInt8?
    public var lastOpcode: UInt8?
    public var exitReason: HistoryChannelExitReason?

    public init(label: String, channel: UInt8, startedAt: Date = Date()) {
        self.label = label
        self.channel = channel
        self.startedAt = startedAt
        // Zeroed here, NOT via a property default: the synthesized decoder never consults a
        // property default, so a trace this build creates carries a measured 0 while one decoded
        // from pre-2026-08-27 JSON reads back nil. That is the discriminator described above.
        self.page4DCount = 0
        self.sportSampleCount = 0
    }

    public var recordsAdded: Int { max(recordsAtEnd - recordsAtStart, 0) }
    /// Any history page at all, sport included — the name promises "any", so `0x4d` counts.
    public var sawAnyPage: Bool { page4CCount > 0 || page47Count > 0 || (page4DCount ?? 0) > 0 }

    /// `firstOpcode` is stamped by the first frame seen AFTER this trace was installed. A healthy
    /// attempt sees its OWN handshake first — `0x81` (auth challenge) or `0x82` (sync-open ACK). A
    /// `0x4c` first means the ring was ALREADY mid-handoff when we started counting, i.e. pages were
    /// in flight and uncounted before this drain existed.
    ///
    /// 🟢 This is the 2026-08-04 fingerprint (#188), present on BOTH testers' bundles and on no
    /// other bundle in either export. Computed, NOT stored: adding a stored field here would break
    /// every previously-persisted evidence bundle (see the `openWriteFailed` note above).
    public var openedOntoLiveStream: Bool { firstOpcode == 0x4C }
    public var durationSeconds: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    public var outcome: HistoryChannelOutcome {
        if page4CCount > 0, endMarkerCount > 0 { return .complete }
        if page4CCount > 0, exitReason == .quietAfterPages { return .complete }
        if page4CCount > 0 { return .partial }
        if page47Count > 0 { return .ppgOnly }
        // Ordered AFTER both epoch/PPG branches so it can only ever narrow `.empty`/`.noAck`: a
        // channel that delivered 0x4c or 0x47 keeps the exact classification it had before this
        // case existed, and every branch it takes over already had `allowsSleepCommit == false`,
        // so no sleep-commit decision can move (`HistoryCommitGate` treats the two identically).
        //
        // ⚠️ It is NOT sport-channel-only in practice: an OSA assessment pushes a brief 0x4d burst
        // at start (`docs/RUNBOOK_OSA_APNEA.md`, §Opcodes), so an armed OSA user whose sleep channel
        // returned nothing can land here instead of `.empty`. The one place that is user-visible is
        // `RingSession.finalizeSync`, which shows a "Partial sync — sleep channel …" line for any
        // sleep outcome that is neither `.complete` nor `.empty`; see the note at that call site.
        // Nothing else branches on the distinction.
        if (page4DCount ?? 0) > 0 { return .sportOnly }
        if sawSyncAck { return .empty }
        // Ordered AFTER every "we heard something" branch: if pages or an ACK arrived, the link
        // plainly worked and a stale write-failure flag (or a cancellation that landed just after)
        // must not override real evidence.
        if openWriteFailed == true { return .linkDown }
        // Ordered AFTER `.linkDown`: `openWriteFailed` is only ever paired with `.linkUnusable`
        // (never `.cancelled`, see `RingSession.drainChannel`), so this never shadows it — it only
        // catches the case `.linkDown` doesn't: the write succeeded and we were genuinely waiting
        // on the ring when OUR OWN session teardown cancelled the wait.
        if exitReason == .cancelled { return .cancelled }
        return .noAck
    }
}
