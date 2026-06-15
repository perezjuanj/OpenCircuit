import Foundation

/// Timestamp-only decoder for epoch sync records.
///
/// This namespace intentionally exposes only byte-structure facts confirmed by
/// captures: record splitting, cursor-space timestamp reconstruction, subtype
/// tags, and raw payload bytes for future metric decoding.
public enum EpochRecord {
    public static let syncEpoch = Command.syncEpoch
    public static let marker: UInt8 = 0x0C
    public static let ppgOpcode: UInt8 = 0x47
    public static let activityOpcode: UInt8 = 0x4C
    public static let endOfHistoryOpcode: UInt8 = 0x50
    public static let ppgRecordSize = 47
    public static let activityRecordSize = 23

    // 0x4C activity/sleep record - 23 bytes.
    public struct ActivityRecord: Equatable, Sendable {
        public let timestamp: Date
        public let subtype: UInt8
        public let rawPayload: Data

        public init(timestamp: Date, subtype: UInt8, rawPayload: Data) {
            self.timestamp = timestamp
            self.subtype = subtype
            self.rawPayload = rawPayload
        }
    }

    // 0x47 PPG/waveform record - 47 bytes.
    public struct PPGRecord: Equatable, Sendable {
        public let timestamp: Date
        public let rawPayload: Data

        public init(timestamp: Date, rawPayload: Data) {
            self.timestamp = timestamp
            self.rawPayload = rawPayload
        }
    }

    public struct EndOfHistoryFrame: Equatable, Sendable {
        public let subtype: UInt8
        public let cursorFrom: UInt32
        public let cursorTo: UInt32

        public init(subtype: UInt8, cursorFrom: UInt32, cursorTo: UInt32) {
            self.subtype = subtype
            self.cursorFrom = cursorFrom
            self.cursorTo = cursorTo
        }

        public var streamHighByte: UInt8 {
            UInt8((cursorTo >> 24) & 0xFF)
        }
    }

    /// Parse all activity records out of a 0x4C page frame.
    /// `streamHighByte` is the high byte of the 4-byte cursor, reconstructed
    /// from the 0x50 end-of-sync frame or the sync-open cursor.
    public static func parseActivityPage(_ data: Data, streamHighByte: UInt8 = 0) -> [ActivityRecord] {
        let bytes = [UInt8](data)
        guard let payload = pagePayload(bytes, opcode: activityOpcode),
              payload.count % activityRecordSize == 0 else { return [] }

        return stride(from: 0, to: payload.count, by: activityRecordSize).compactMap { offset in
            let record = Array(payload[offset..<(offset + activityRecordSize)])
            guard record[0] == marker else { return nil }
            return ActivityRecord(
                timestamp: timestamp(record, streamHighByte: streamHighByte),
                subtype: record[8],
                rawPayload: Data(record[15..<22])
            )
        }
    }

    public static func parsePPGPage(_ data: Data, streamHighByte: UInt8 = 0) -> [PPGRecord] {
        let bytes = [UInt8](data)
        guard let payload = pagePayload(bytes, opcode: ppgOpcode),
              payload.count % ppgRecordSize == 0 else { return [] }

        return stride(from: 0, to: payload.count, by: ppgRecordSize).compactMap { offset in
            let record = Array(payload[offset..<(offset + ppgRecordSize)])
            guard record[0] == marker else { return nil }
            return PPGRecord(
                timestamp: timestamp(record, streamHighByte: streamHighByte),
                rawPayload: Data(record[9..<47])
            )
        }
    }

    public static func remainingRecordCountdown(_ data: Data) -> UInt8? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3,
              (bytes[0] == ppgOpcode || bytes[0] == activityOpcode) else { return nil }
        return bytes[2]
    }

    /// Parse the no-XOR 0x50 end-of-history cursor report.
    ///
    /// The confirmed capture shape is a 6-byte cursor entry after `50 00 00`.
    /// Newer issue notes describe a compact from/to form. Both are accepted so
    /// the session can recover the high cursor byte without blocking the drain.
    public static func parseEndOfHistory(_ data: Data) -> EndOfHistoryFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8,
              bytes[0] == endOfHistoryOpcode,
              bytes[1] == 0x00,
              bytes[2] == 0x00 else { return nil }

        if bytes.count == 12 {
            let from = uint32BE(bytes, offset: 4)
            let to = uint32BE(bytes, offset: 8)
            return EndOfHistoryFrame(subtype: bytes[3], cursorFrom: from, cursorTo: to)
        }

        if bytes.count == 9, bytes[3] == 0x15 {
            let cursor = uint32BE(bytes, offset: 5)
            return EndOfHistoryFrame(subtype: bytes[4], cursorFrom: cursor, cursorTo: cursor)
        }

        if bytes.count == 8 {
            let cursor = uint32BE(bytes, offset: 4)
            return EndOfHistoryFrame(subtype: bytes[3], cursorFrom: cursor, cursorTo: cursor)
        }

        return nil
    }

    private static func pagePayload(_ bytes: [UInt8], opcode: UInt8) -> [UInt8]? {
        guard bytes.first == opcode,
              let parsed = Frame.parse(bytes),
              parsed.opcode == opcode,
              parsed.body.count >= 2,
              parsed.body[0] == 0x00 else { return nil }
        return Array(parsed.body.dropFirst(2))
    }

    private static func timestamp(_ record: [UInt8], streamHighByte: UInt8) -> Date {
        let low3 = UInt32(record[1]) << 16 | UInt32(record[2]) << 8 | UInt32(record[3])
        let full = UInt32(streamHighByte) << 24 | low3
        let unixSeconds = Double(full) + Double(syncEpoch)
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func uint32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
