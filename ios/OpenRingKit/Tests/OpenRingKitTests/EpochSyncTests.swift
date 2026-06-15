import XCTest
@testable import OpenRingKit

final class EpochSyncTests: XCTestCase {
    private func frame(opcode: UInt8, body: [UInt8]) -> Data {
        let withoutTrailer = [opcode] + body
        return Data(withoutTrailer + [Frame.xorTrailer(withoutTrailer)])
    }

    private func record(size: Int, counter: UInt32, fill: UInt8 = 0x01) -> [UInt8] {
        var bytes = [EpochRecord.marker,
                     UInt8((counter >> 16) & 0xFF),
                     UInt8((counter >> 8) & 0xFF),
                     UInt8(counter & 0xFF)]
        bytes += Array(repeating: fill, count: size - bytes.count)
        return bytes
    }

    func testParsesActivityPageTimestampSubtypeAndRawPayload() {
        var rec = record(size: EpochRecord.activityRecordSize, counter: 0x223344, fill: 0x01)
        rec[8] = 0x13
        rec.replaceSubrange(15..<22, with: [1, 2, 3, 4, 5, 6, 7])
        let bytes = frame(opcode: EpochRecord.activityOpcode, body: [0x00, 0x00] + rec)

        let records = EpochRecord.parseActivityPage(bytes, streamHighByte: 0x0C)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].subtype, 0x13)
        XCTAssertEqual(records[0].rawPayload, Data([1, 2, 3, 4, 5, 6, 7]))
        XCTAssertEqual(records[0].timestamp,
                       Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch + 0x0c223344)))
    }

    func testParsesPPGPageTimestampAndRawPayload() {
        var rec = record(size: EpochRecord.ppgRecordSize, counter: 0x000100, fill: 0x01)
        rec.replaceSubrange(9..<47, with: Array(0..<38).map(UInt8.init))
        let bytes = frame(opcode: EpochRecord.ppgOpcode, body: [0x00, 0x03] + rec)

        let records = EpochRecord.parsePPGPage(bytes, streamHighByte: 0x02)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].rawPayload, Data(Array(0..<38).map(UInt8.init)))
        XCTAssertEqual(records[0].timestamp,
                       Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch + 0x02000100)))
        XCTAssertEqual(EpochRecord.remainingRecordCountdown(bytes), 0x03)
    }

    func testRejectsMalformedEpochPages() {
        let wrongMarker = [UInt8](repeating: 0x01, count: EpochRecord.activityRecordSize)
        let bytes = frame(opcode: EpochRecord.activityOpcode, body: [0x00, 0x00] + wrongMarker)

        XCTAssertEqual(EpochRecord.parseActivityPage(bytes), [])
        XCTAssertEqual(EpochRecord.parsePPGPage(Data([0x47, 0x00, 0x00])), [])
    }

    func testDecodesEndOfHistoryWithoutXorTrailer() {
        let bytes = Data([
            0x50, 0x00, 0x00, 0x12,
            0x0c, 0x22, 0xaa, 0xe4,
            0x0c, 0x22, 0xac, 0xb5,
        ])

        let report = EpochRecord.parseEndOfHistory(bytes)

        XCTAssertEqual(report?.subtype, 0x12)
        XCTAssertEqual(report?.cursorFrom, 0x0c22aae4)
        XCTAssertEqual(report?.cursorTo, 0x0c22acb5)
        XCTAssertEqual(report?.streamHighByte, 0x0c)
    }

    func testSessionReparsesBufferedPagesWhenEndFrameProvidesHighByte() {
        var rec = record(size: EpochRecord.activityRecordSize, counter: 0x223344, fill: 0x00)
        rec.replaceSubrange(15..<22, with: [1, 0, 0, 0, 0, 0, 0])
        let page = frame(opcode: EpochRecord.activityOpcode, body: [0x00, 0x00] + rec)
        let end = Data([
            0x50, 0x00, 0x00, 0x12,
            0x0c, 0x22, 0x33, 0x44,
            0x0c, 0x22, 0x33, 0x44,
        ])

        var session = EpochSyncSession()
        XCTAssertEqual(session.appendActivityPage(page).first?.timestamp,
                       Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch + 0x00223344)))
        XCTAssertNotNil(session.complete(with: end))

        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.activityRecords.first?.timestamp,
                       Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch + 0x0c223344)))
        XCTAssertEqual(session.placeholderQuantitySamples(), [
            QuantitySample(
                kind: .heartRate,
                start: Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch + 0x0c223344)),
                value: 0.0
            )
        ])
    }
}
