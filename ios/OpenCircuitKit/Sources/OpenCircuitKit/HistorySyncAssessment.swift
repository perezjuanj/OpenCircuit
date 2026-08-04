import Foundation

/// Testable classification of one history-drain channel outcome. The BLE session populates the
/// trace incrementally while draining; this pure layer turns that trace into a conservative
/// success/failure verdict for downstream sleep persistence.
public enum HistoryChannelOutcome: String, Codable, Sendable {
    case complete
    case empty
    case partial
    case ppgOnly
    case noAck
    /// The channel's sync-open never reached the wire — the BLE link was down or half-open, so
    /// `RingSession.write` dropped the commands. Split out of `.noAck` (2026-07-27) because the two
    /// were being conflated in tester diagnostics and they mean opposite things: `.noAck` says the
    /// RING was asked and stayed silent (a protocol/cursor signal worth investigating), while this
    /// says WE never asked (a connectivity problem, and the ring is exonerated). A tester export
    /// showing 27 all-day `noAck`s looked like a ring-side channel limit; it was a flaky link.
    case linkDown

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
    }

    public var recordsAdded: Int { max(recordsAtEnd - recordsAtStart, 0) }
    public var sawAnyPage: Bool { page4CCount > 0 || page47Count > 0 }

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
        if sawSyncAck { return .empty }
        // Ordered AFTER every "we heard something" branch: if pages or an ACK arrived, the link
        // plainly worked and a stale write-failure flag must not override real evidence.
        if openWriteFailed == true { return .linkDown }
        return .noAck
    }
}
