import XCTest
@testable import OpenCircuitKit

// Bit-width is settled offline (issue #8) — see PPGTrend.swift's header. These tests pin the
// 10-bit BE unpacking against hand-built vectors; they don't re-prove the bit-width itself
// (that proof lives in desktop/analyze_0x47_bitwidth.py against real captures).
final class PPGTrendTests: XCTestCase {

    func testAllZeroPayloadDecodesToZeroSamples() {
        let payload = Data(repeating: 0x00, count: 38)
        let samples = PPGTrend.samples(from: payload)
        XCTAssertEqual(samples.count, PPGTrend.expectedSamplesPerRecord)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }

    func testKnownFirstSample() {
        // First 10 bits = 0b1111111111 = 1023 (max 10-bit value): bytes 0xFF 0xC0 give
        // bits 11111111 11 (first 10 of those are all 1).
        var bytes = [UInt8](repeating: 0x00, count: 38)
        bytes[0] = 0xFF
        bytes[1] = 0xC0
        let samples = PPGTrend.samples(from: Data(bytes))
        XCTAssertEqual(samples.first, 1023)
    }

    func testConsecutiveSamplesAreNotByteAligned() {
        // bytes[0]=0b00000001, bytes[1]=0b00000000, bytes[2]=0b10000000.
        // Bitstream indices 0..23: 00000001 00000000 10000000.
        // sample0 = bits[0..10)  = 0000000100 = 4 (straddles bytes 0-1).
        // sample1 = bits[10..20) = 0000001000 = 8 (straddles bytes 1-2) — proves samples
        // are NOT byte-aligned (10 doesn't divide 8), the structural signature in §5.2.
        var bytes = [UInt8](repeating: 0x00, count: 38)
        bytes[0] = 0b00000001
        bytes[1] = 0b00000000
        bytes[2] = 0b10000000
        let samples = PPGTrend.samples(from: Data(bytes))
        XCTAssertEqual(samples[0], 4)
        XCTAssertEqual(samples[1], 8)
    }

    func testRecordCountFromRealisticPayloadSize() {
        // 38 bytes = 304 bits -> 30 full 10-bit samples (300 bits), 4 bits dropped.
        let payload = Data((0..<38).map { UInt8($0 * 7 % 256) })
        XCTAssertEqual(PPGTrend.samples(from: payload).count, 30)
    }

    func testSamplesFromRecordsPairsTimestamp() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let record = EpochRecord.PPGRecord(timestamp: t, rawPayload: Data(repeating: 0x00, count: 38))
        let paired = PPGTrend.samples(from: [record])
        XCTAssertEqual(paired.count, 1)
        XCTAssertEqual(paired[0].timestamp, t)
        XCTAssertEqual(paired[0].samples.count, 30)
    }
}
