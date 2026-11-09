// The strap's workout records (§22.2 summary, §22.3 detail, decision 91b). Every fixture is synthetic:
// the spec's constructed worked examples N and O, and records built here from made-up values.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// Builders for synthetic workout records, shared with the walk tests.
enum WorkoutFixture {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func tag(_ field: UInt64, _ wire: UInt64) -> [UInt8] { varint(field << 3 | wire) }
    static func varintField(_ field: UInt64, _ value: UInt64) -> [UInt8] { tag(field, 0) + varint(value) }
    static func message(_ field: UInt64, _ body: [UInt8]) -> [UInt8] { tag(field, 2) + varint(UInt64(body.count)) + body }

    /// A summary with the §22.2 fields; nil leaves a field out.
    static func summary(start: UInt64, duration: UInt64?, kcal: UInt64? = 150, hr: (UInt64, UInt64, UInt64)? = (110, 130, 90),
                        sport: UInt64 = 0xdf, flag: UInt64 = 257) -> [UInt8] {
        var out: [UInt8] = [0x00, 0x80]
        out += message(1, Array("2.1".utf8))
        out += message(2, varintField(1, start) + varintField(2, 0) + varintField(3, 39) + varintField(13, flag))
        out += message(3, varintField(1, sport) + varintField(2, 1))
        if let duration { out += message(7, varintField(1, duration) + varintField(2, duration)) }
        if let kcal { out += message(16, varintField(1, kcal)) }
        if let hr { out += message(19, varintField(1, hr.0) + varintField(2, hr.1) + varintField(3, hr.2)) }
        return out
    }

    static func blockHeader(ms: UInt64) -> [UInt8] {
        [0x01, 0x0c, 0x70, 0x73, 0x6d, 0x68] + (0..<6).map { UInt8((ms >> (8 * UInt64($0))) & 0xFF) } + [0x00, 0x00]
    }

    static func sample(offsetMs: UInt16, bpm: UInt8) -> [UInt8] {
        [0x08, 0x03, UInt8(offsetMs & 0xFF), UInt8(offsetMs >> 8), bpm]
    }

    /// A 1 Hz track from `fromS` to `toS` (Unix seconds, `toS` excluded), a block every 30 s.
    static func track(fromS: UInt64, toS: UInt64, bpm: (UInt64) -> UInt8 = { _ in 120 }) -> [UInt8] {
        var out: [UInt8] = []
        var t = fromS
        while t < toS {
            out += blockHeader(ms: t * 1000)
            for k in 0..<UInt64(30) where t + k < toS {
                out += sample(offsetMs: UInt16(k * 1000), bpm: bpm(t + k))
            }
            t += 30
        }
        return out
    }
}

final class WorkoutRecordParserTests: XCTestCase {

    /// §22.2 worked example N, byte for byte.
    static let exampleN = hex("00 80 0a 03 32 2e 31 12 0d 08 80 f7 c4 d5 06 10 00 18 27 68 81 02 1a 05 08 df 01 10 01"
                              + " 3a 06 08 dc 0b 10 dc 0b 82 01 03 08 96 01 9a 01 07 08 6e 10 82 01 18 5a")

    /// §22.3 worked example O.
    static let exampleO = hex("01 0c 70 73 6d 68 00 6c 50 c4 a0 01 00 00 08 03 00 00 64 08 03 e8 03 65 08 03 d0 07 67")

    private let window = DateInterval(start: date(1_790_000_000), duration: 1500)

    // MARK: Worked examples

    func testWorkedExampleNDecodesToTheSpecsValues() throws {
        let s = try ZeppWorkoutSummary.parse(Self.exampleN)
        XCTAssertEqual(s.start, date(1_790_000_000))
        XCTAssertEqual(s.durationSeconds, 1500)
        XCTAssertEqual(s.end, date(1_790_001_500))
        XCTAssertEqual(s.kilocalories, 150)
        XCTAssertEqual(s.averageHeartRate, 110)
        XCTAssertEqual(s.maximumHeartRate, 130)
        XCTAssertEqual(s.minimumHeartRate, 90)
        XCTAssertEqual(s.sportCode, 0xdf)
        XCTAssertEqual(s.raw2_13, 257)
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: s.sportCode), .other)
    }

    func testTheBuilderReproducesWorkedExampleN() {
        XCTAssertEqual(WorkoutFixture.summary(start: 1_790_000_000, duration: 1500), Self.exampleN)
    }

    func testWorkedExampleODecodesToTheSpecsValues() throws {
        let d = try ZeppWorkoutDetail.parse(Self.exampleO, window: window)
        XCTAssertEqual(d.heartRate, [
            ZeppWorkoutHeartRate(time: date(1_790_000_000), bpm: 100),
            ZeppWorkoutHeartRate(time: date(1_790_000_001), bpm: 101),
            ZeppWorkoutHeartRate(time: date(1_790_000_002), bpm: 103),
        ])
        XCTAssertEqual(d.rawSampleCount, 3)
    }

    // MARK: Unknown content is skipped

    func testAnUnknownSummaryFieldOfEveryWireTypeIsSkipped() throws {
        let expected = try ZeppWorkoutSummary.parse(Self.exampleN)
        let f = WorkoutFixture.self
        let unknownTop = f.varintField(30, 12345)                                  // varint
            + f.tag(31, 1) + [1, 2, 3, 4, 5, 6, 7, 8]                              // fixed64
            + f.message(32, [0xde, 0xad, 0xbe, 0xef])                              // length-delimited
            + f.tag(33, 5) + [0x00, 0x00, 0x80, 0x3f]                              // fixed32 (1.0f)
            + f.message(21, f.tag(4, 5) + [0xcd, 0xcc, 0x4c, 0x40] + f.varintField(6, 77))  // 21.x (🔴)
            + f.message(22, f.message(2, [100, 120, 140, 150, 160, 170]))           // 22.2 packed zones
        // And unknown fields of every wire type INSIDE the known messages.
        let unknownInner = f.varintField(9, 1) + f.tag(10, 1) + [UInt8](repeating: 0xAA, count: 8)
            + f.message(11, [1, 2]) + f.tag(12, 5) + [9, 9, 9, 9]
        var record: [UInt8] = [0x00, 0x80]
        record += unknownTop
        record += f.message(1, Array("2.1".utf8))
        record += f.message(2, unknownInner + f.varintField(1, 1_790_000_000) + f.varintField(13, 257))
        record += f.message(3, f.varintField(1, 0xdf) + unknownInner)
        record += f.message(7, unknownInner + f.varintField(1, 1500) + f.varintField(4, 1400))
        record += f.message(16, f.varintField(1, 150) + unknownInner)
        record += f.message(19, f.varintField(1, 110) + unknownInner + f.varintField(2, 130) + f.varintField(3, 90))
        record += unknownTop
        XCTAssertEqual(try ZeppWorkoutSummary.parse(record), expected)
    }

    func testAnUnknownDetailTypeIsSkippedByItsLength() throws {
        let expected = try ZeppWorkoutDetail.parse(Self.exampleO, window: window)
        let header = Array(Self.exampleO[0..<14])
        let samples = Array(Self.exampleO[14...])
        var record = [0x04, 0x04, 0x01, 0x02, 0x03, 0x04] + header              // `04` before the header
        record += Array(samples[0..<5])
        record += [0x05, 0x08] + [UInt8](repeating: 0x08, count: 8)             // `05`, 8 bytes of 08s
        record += [0x00, 0x00]                                                   // `00`, length 0
        record += Array(samples[5..<10])
        record += [0x1f, 0x1e] + [UInt8](repeating: 0x01, count: 30)            // 30 bytes that look like headers
        record += [0xfa, 0x03, 0x08, 0x03, 0x00]                                 // looks like a sample inside
        record += Array(samples[10...])
        record += [0x0f, 0x02, 0xff, 0xff]
        XCTAssertEqual(try ZeppWorkoutDetail.parse(record, window: window), expected)
    }

    // MARK: Trimming and readings

    func testHeartRateOutsideTheWindowIsTrimmedAndNoReadingIsDropped() throws {
        let f = WorkoutFixture.self
        // Block 10 s before the start; readings at −10 s, −1 s, 0, +1 (00), +2 (ff), +3, end − 1, end, end + 5.
        let base: UInt64 = 1_790_000_000 - 10
        var record = f.blockHeader(ms: base * 1000)
        record += f.sample(offsetMs: 0, bpm: 90)              // −10 s
        record += f.sample(offsetMs: 9_000, bpm: 91)          // −1 s
        record += f.sample(offsetMs: 10_000, bpm: 100)        // start: kept
        record += f.sample(offsetMs: 11_000, bpm: 0x00)       // no reading
        record += f.sample(offsetMs: 12_000, bpm: 0xff)       // no reading
        record += f.sample(offsetMs: 13_000, bpm: 103)
        record += f.blockHeader(ms: (1_790_001_500 - 1) * 1000)
        record += f.sample(offsetMs: 0, bpm: 140)             // end − 1 s: kept
        record += f.sample(offsetMs: 1_000, bpm: 141)         // end: outside [start, end)
        record += f.sample(offsetMs: 6_000, bpm: 142)         // after
        let d = try ZeppWorkoutDetail.parse(record, window: window)
        XCTAssertEqual(d.heartRate, [
            ZeppWorkoutHeartRate(time: date(1_790_000_000), bpm: 100),
            ZeppWorkoutHeartRate(time: date(1_790_000_003), bpm: 103),
            ZeppWorkoutHeartRate(time: date(1_790_001_499), bpm: 140),
        ])
        XCTAssertEqual(d.rawSampleCount, 9)
    }

    func testABlockHeaderCarriesAU48MillisecondStart() throws {
        let f = WorkoutFixture.self
        // A start with a fraction of a second, and the u48's top byte in use: 2026-09-21T14:13:20.250Z.
        let ms: UInt64 = 1_790_000_000_250
        XCTAssertEqual(f.blockHeader(ms: ms)[6...11].map { $0 }, [0xfa, 0x6c, 0x50, 0xc4, 0xa0, 0x01])
        var record = f.blockHeader(ms: ms) + f.sample(offsetMs: 750, bpm: 120) + f.sample(offsetMs: 65_535, bpm: 121)
        // A later block resets the base: its offset counts from its own start.
        record += f.blockHeader(ms: 1_790_000_100_000) + f.sample(offsetMs: 500, bpm: 122)
        let d = try ZeppWorkoutDetail.parse(record, window: window)
        XCTAssertEqual(d.heartRate.map(\.time.timeIntervalSince1970), [1_790_000_001, 1_790_000_065.785, 1_790_000_100.5])
        XCTAssertEqual(d.heartRate.map(\.bpm), [120, 121, 122])
    }

    func testAHeartRateEntryBeforeAnyBlockHeaderFailsTheRecord() {
        let record = WorkoutFixture.sample(offsetMs: 0, bpm: 100) + Self.exampleO
        XCTAssertThrowsError(try ZeppWorkoutDetail.parse(record, window: window))
        XCTAssertThrowsError(try ZeppWorkoutDetail.parse([0x04, 0x04, 1, 2, 3, 4], window: window), "no block header")
    }

    func testASummaryWithoutAStartOrADurationFails() {
        let f = WorkoutFixture.self
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse(f.summary(start: 1_790_000_000, duration: nil))) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .missingField("7.1 duration"))
        }
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse([0x00, 0x80] + f.message(7, f.varintField(1, 60)))) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .missingField("2.1 start"))
        }
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse(f.summary(start: 1_790_000_000, duration: 0)))
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse(f.summary(start: 3, duration: 1500)), "a 1970 start")
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse(Array(Self.exampleN.dropFirst(2))), "no header")
    }

    func testAbsentOptionalFieldsAreNil() throws {
        let s = try ZeppWorkoutSummary.parse(WorkoutFixture.summary(start: 1_790_000_000, duration: 900, kcal: nil, hr: nil, sport: 0x34, flag: 1))
        XCTAssertNil(s.kilocalories)
        XCTAssertNil(s.averageHeartRate)
        XCTAssertEqual(s.sportCode, 0x34)
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: s.sportCode), .strengthTraining)
    }

    func testTheSportCodeMapsBackThroughTheStrapsTable() {
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: 0xe3), .pickleball)
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: 0x11), .tennis)
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: 0x02), .runningIndoor)
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: 0xdf), .other)
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: nil), .other)
        XCTAssertEqual(ZeppWorkoutSport.sport(forCode: 0x1_02), .other, "a code past one byte is not the table's")
        for sport in WorkoutSportType.allCases {
            if let code = ZeppWorkoutSport.forSport(sport)?.code {
                XCTAssertEqual(ZeppWorkoutSport.sport(forCode: UInt64(code)), sport)
            }
        }
    }

    // MARK: Malformed input throws, never traps

    func testEmptyInputsThrow() {
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse([])) { XCTAssertEqual($0 as? ZeppWorkoutRecordError, .empty) }
        XCTAssertThrowsError(try ZeppWorkoutDetail.parse([], window: window)) { XCTAssertEqual($0 as? ZeppWorkoutRecordError, .empty) }
    }

    func testOversizedInputsThrow() {
        let summary = Self.exampleN + [UInt8](repeating: 0, count: (64 << 10) + 1 - Self.exampleN.count)
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse(summary)) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .oversized(length: (64 << 10) + 1, limit: 64 << 10))
        }
        let detail = Self.exampleO + [UInt8](repeating: 0, count: (2 << 20) + 1 - Self.exampleO.count)
        XCTAssertThrowsError(try ZeppWorkoutDetail.parse(detail, window: window)) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .oversized(length: (2 << 20) + 1, limit: 2 << 20))
        }
    }

    func testATruncatedSummaryThrowsOrKeepsOnlyWholeFields() throws {
        let full = try ZeppWorkoutSummary.parse(Self.exampleN)
        // A cut inside a field (here: inside field 2's start varint, and inside field 19) throws.
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse(Array(Self.exampleN.prefix(12)))) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .truncated)
        }
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse(Array(Self.exampleN.dropLast()))) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .truncated)
        }
        // Every cut either throws or, at a field boundary, keeps the whole fields it holds (no invented value).
        for length in 0..<Self.exampleN.count {
            guard let s = try? ZeppWorkoutSummary.parse(Array(Self.exampleN.prefix(length))) else { continue }
            XCTAssertEqual(s.start, full.start)
            XCTAssertEqual(s.durationSeconds, full.durationSeconds)
            XCTAssertTrue(s.kilocalories == nil || s.kilocalories == full.kilocalories)
            XCTAssertTrue(s.averageHeartRate == nil || s.averageHeartRate == full.averageHeartRate)
        }
    }

    func testATruncatedDetailThrows() {
        // A cut inside any entry throws; a cut at an entry boundary keeps the entries before it.
        let boundaries: Set<Int> = [14, 19, 24]
        for length in 1..<Self.exampleO.count {
            let prefix = Array(Self.exampleO.prefix(length))
            if boundaries.contains(length) {
                XCTAssertNoThrow(try ZeppWorkoutDetail.parse(prefix, window: window), "\(length)")
            } else {
                XCTAssertThrowsError(try ZeppWorkoutDetail.parse(prefix, window: window), "\(length)")
            }
        }
    }

    func testMalformedVarintsAndWireTypesThrow() {
        let f = WorkoutFixture.self
        let eleven = [UInt8](repeating: 0xff, count: 10) + [0x01]
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse([0x00, 0x80, 0x08] + eleven)) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .malformedVarint)
        }
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse([0x00, 0x80] + f.tag(5, 3) + Self.exampleN.dropFirst(2))) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .malformedField, "a group")
        }
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse([0x00, 0x80, 0x00, 0x00]), "field 0")
        // A length-delimited field that claims more than the record holds.
        XCTAssertThrowsError(try ZeppWorkoutSummary.parse([0x00, 0x80, 0x12, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x08])) {
            XCTAssertEqual($0 as? ZeppWorkoutRecordError, .truncated)
        }
    }

    func testRandomBuffersThrowAndNeverTrap() {
        var gen = TestBytes(seed: 0x0226_0005)
        var summaryThrew = 0, detailThrew = 0
        for _ in 0..<2_500 {
            let data = gen.bytes(gen.int(1...700))
            if (try? ZeppWorkoutSummary.parse(data)) == nil { summaryThrew += 1 }
            if (try? ZeppWorkoutDetail.parse(data, window: window)) == nil { detailThrew += 1 }
        }
        XCTAssertEqual(summaryThrew, 2_500)
        XCTAssertEqual(detailThrew, 2_500)
    }

    func testRandomBuffersBehindAValidHeaderNeverTrap() {
        // Past the header check, so the protocol-buffers reader and the TLV walk run on garbage.
        var gen = TestBytes(seed: 0x0226_0006)
        for _ in 0..<2_000 {
            let body = gen.bytes(gen.int(0...300))
            if let s = try? ZeppWorkoutSummary.parse([0x00, 0x80] + body) {
                XCTAssertTrue(ZeppWorkoutSummary.plausibleStarts.contains(s.start))
                XCTAssertGreaterThan(s.durationSeconds, 0)
            }
            if let d = try? ZeppWorkoutDetail.parse(Self.exampleO + body, window: window) {
                XCTAssertTrue(d.heartRate.allSatisfy { window.start <= $0.time && $0.time < window.end })
            }
        }
    }

    func testABigSyntheticTrackParsesInOrder() throws {
        let start: UInt64 = 1_790_000_000
        let record = WorkoutFixture.track(fromS: start - 300, toS: start + 1500 + 600) { UInt8(100 + $0 % 50) }
        let d = try ZeppWorkoutDetail.parse(record, window: window)
        XCTAssertEqual(d.heartRate.count, 1500)
        XCTAssertEqual(d.rawSampleCount, 300 + 1500 + 600)
        XCTAssertEqual(d.heartRate.first?.time, date(1_790_000_000))
        XCTAssertEqual(d.heartRate.last?.time, date(1_790_001_499))
        XCTAssertEqual(d.heartRate.map(\.time), d.heartRate.map(\.time).sorted())
    }
}
