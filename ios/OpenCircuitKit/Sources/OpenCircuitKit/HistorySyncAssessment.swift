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

    /// Safe to re-stage/persist sleep from this channel.
    public var allowsSleepCommit: Bool { self == .complete }
}

public enum HistoryChannelExitReason: String, Codable, Sendable {
    case endMarker
    case quietAfterPages
    case quietNoPages
    case hardTimeout
    case cancelled
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
        return .noAck
    }
}
