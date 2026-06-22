import XCTest
@testable import OpenCircuitKit

final class HistoryFrameCaptureTests: XCTestCase {

    // MARK: - Opcode filtering

    func testCapturesHistoryAndDescriptorOpcodes() {
        for op in [UInt8(0x47), 0x4c, 0x50, 0x82, 0x10, 0x87] {
            XCTAssertTrue(HistoryFrameCapture.shouldCapture([op, 0x00, 0x01]),
                          "expected 0x\(String(op, radix: 16)) to be captured")
        }
    }

    func testSkipsLiveAndHeartbeatOpcodes() {
        XCTAssertFalse(HistoryFrameCapture.shouldCapture([0x15, 0x00]))  // live sample
        XCTAssertFalse(HistoryFrameCapture.shouldCapture([0x11, 0x00]))  // heartbeat
        XCTAssertFalse(HistoryFrameCapture.shouldCapture([0x81, 0x00]))  // auth challenge
        XCTAssertFalse(HistoryFrameCapture.shouldCapture([]))            // empty
    }

    func testRecordIfRelevantReturnsWhetherRecorded() {
        var cap = HistoryFrameCapture()
        XCTAssertTrue(cap.recordIfRelevant([0x4c, 0x00, 0xab]))
        XCTAssertEqual(cap.count, 1)
        XCTAssertFalse(cap.recordIfRelevant([0x15, 0x00]))  // skipped opcode → not recorded
        XCTAssertEqual(cap.count, 1)
    }

    // MARK: - Frame encoding

    func testFrameHexAndOpcode() {
        let f = CapturedFrame(date: Date(timeIntervalSince1970: 0), bytes: [0x4c, 0x00, 0x0f, 0xff])
        XCTAssertEqual(f.opcode, 0x4c)
        XCTAssertEqual(f.byteCount, 4)
        XCTAssertEqual(f.hex, "4c 00 0f ff")
    }

    // MARK: - Bounded buffer

    func testTrimsToCapKeepingNewest() {
        var cap = HistoryFrameCapture()
        let overflow = HistoryFrameCapture.cap + 50
        for i in 0..<overflow {
            // Vary the descriptor payload so we can identify the survivors.
            cap.recordIfRelevant([0x10, UInt8(i & 0xff), UInt8((i >> 8) & 0xff)])
        }
        XCTAssertEqual(cap.count, HistoryFrameCapture.cap)
        // The very first frame must have been dropped; the last must survive.
        let lastIndex = overflow - 1
        let expectedLastHex = String(format: "10 %02x %02x", lastIndex & 0xff, (lastIndex >> 8) & 0xff)
        XCTAssertEqual(cap.frames.last?.hex, expectedLastHex)
    }

    func testInitTrimsOversizedInput() {
        let frames = (0..<(HistoryFrameCapture.cap + 10)).map {
            CapturedFrame(date: Date(timeIntervalSince1970: TimeInterval($0)), bytes: [0x4c, UInt8($0 & 0xff)])
        }
        let cap = HistoryFrameCapture(frames: frames)
        XCTAssertEqual(cap.count, HistoryFrameCapture.cap)
    }

    func testClearEmptiesBuffer() {
        var cap = HistoryFrameCapture()
        cap.recordIfRelevant([0x4c, 0x00])
        cap.clear()
        XCTAssertEqual(cap.count, 0)
    }

    // MARK: - Summary

    func testCountsByOpcodeSortedAscending() {
        var cap = HistoryFrameCapture()
        cap.recordIfRelevant([0x4c, 0x01])
        cap.recordIfRelevant([0x4c, 0x02])
        cap.recordIfRelevant([0x47, 0x01])
        cap.recordIfRelevant([0x50, 0x00])
        let counts = cap.countsByOpcode()
        XCTAssertEqual(counts.map(\.opcode), [0x47, 0x4c, 0x50])
        XCTAssertEqual(counts.first { $0.opcode == 0x4c }?.count, 2)
    }

    // MARK: - Codable round-trip (it's persisted to UserDefaults)

    func testCodableRoundTrip() throws {
        var cap = HistoryFrameCapture()
        cap.recordIfRelevant([0x4c, 0x00, 0xde, 0xad])
        cap.recordIfRelevant([0x50, 0x00])
        let data = try JSONEncoder().encode(cap)
        let restored = try JSONDecoder().decode(HistoryFrameCapture.self, from: data)
        XCTAssertEqual(restored, cap)
    }

    // MARK: - Report

    func testReportIncludesFirmwareGenerationAndFrames() {
        var cap = HistoryFrameCapture()
        cap.recordIfRelevant([0x4c, 0x00, 0xab, 0xcd])
        let fw = FirmwareInfo(version: "FR05.001", modelName: "RingConn Gen 3",
                              manufacturer: "RingConn", hardwareRevision: "3.0",
                              mac: "AA:BB:CC:DD:EE:FF")
        let report = cap.report(firmware: fw)
        XCTAssertTrue(report.contains("FR05.001"))
        XCTAssertTrue(report.contains("Gen 3"))            // FR05 prefix → .gen3 (recognized)
        XCTAssertTrue(report.contains(FirmwareInfo.pinnedVersion))
        XCTAssertTrue(report.contains("4c 00 ab cd"))      // the raw frame hex
        XCTAssertTrue(report.contains("Frames captured: 1"))
    }

    func testReportHandlesEmptyCapture() {
        let report = HistoryFrameCapture().report(firmware: FirmwareInfo())
        XCTAssertTrue(report.contains("(none"))
        XCTAssertTrue(report.contains("(unread)"))         // no DIS read yet
    }
}
