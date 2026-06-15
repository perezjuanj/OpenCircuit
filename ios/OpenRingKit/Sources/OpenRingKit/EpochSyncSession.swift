import Foundation

/// Accumulates raw epoch pages across one sync drain and reparses them once the
/// end-of-history cursor report reveals the stream high byte.
public struct EpochSyncSession: Equatable, Sendable {
    public private(set) var streamHighByte: UInt8
    public private(set) var activityRecords: [EpochRecord.ActivityRecord]
    public private(set) var ppgRecords: [EpochRecord.PPGRecord]
    public private(set) var endOfHistory: EpochRecord.EndOfHistoryFrame?

    private var activityPages: [Data]
    private var ppgPages: [Data]

    public init(syncOpenCursor: UInt32? = nil) {
        if let syncOpenCursor, syncOpenCursor != UInt32.max {
            self.streamHighByte = UInt8((syncOpenCursor >> 24) & 0xFF)
        } else {
            self.streamHighByte = 0
        }
        self.activityRecords = []
        self.ppgRecords = []
        self.endOfHistory = nil
        self.activityPages = []
        self.ppgPages = []
    }

    @discardableResult
    public mutating func appendActivityPage(_ data: Data) -> [EpochRecord.ActivityRecord] {
        activityPages.append(data)
        let records = EpochRecord.parseActivityPage(data, streamHighByte: streamHighByte)
        activityRecords.append(contentsOf: records)
        return records
    }

    @discardableResult
    public mutating func appendPPGPage(_ data: Data) -> [EpochRecord.PPGRecord] {
        ppgPages.append(data)
        let records = EpochRecord.parsePPGPage(data, streamHighByte: streamHighByte)
        ppgRecords.append(contentsOf: records)
        return records
    }

    @discardableResult
    public mutating func complete(with data: Data) -> EpochRecord.EndOfHistoryFrame? {
        guard let frame = EpochRecord.parseEndOfHistory(data) else { return nil }
        endOfHistory = frame
        streamHighByte = frame.streamHighByte
        reparseBufferedPages()
        return frame
    }

    public var isComplete: Bool {
        endOfHistory != nil
    }

    public func placeholderQuantitySamples() -> [QuantitySample] {
        activityRecords
            .filter { $0.rawPayload.contains { $0 != 0 } }
            .map {
                QuantitySample(
                    kind: .heartRate,
                    start: $0.timestamp,
                    value: 0.0
                )
            }
    }

    private mutating func reparseBufferedPages() {
        activityRecords = activityPages.flatMap {
            EpochRecord.parseActivityPage($0, streamHighByte: streamHighByte)
        }
        ppgRecords = ppgPages.flatMap {
            EpochRecord.parsePPGPage($0, streamHighByte: streamHighByte)
        }
    }
}
