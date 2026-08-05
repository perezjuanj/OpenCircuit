import XCTest
@testable import OpenCircuitKit

/// `SleepHypnogramCodec` is an ON-DISK format: these bytes sit in `StoredSleepSummary` on every
/// install. The format-lock test below is the thing that stops a future refactor from silently
/// changing what stored nights decode to.
final class SleepHypnogramCodecTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    // MARK: - Round trip

    func testRoundTripIsExact() {
        let segments = [
            SleepSegment(start: at(0), end: at(150), stage: .inBed),
            SleepSegment(start: at(150), end: at(600), stage: .awake),
            SleepSegment(start: at(600), end: at(3_000), stage: .asleepCore),
            SleepSegment(start: at(3_000), end: at(5_400), stage: .asleepDeep),
            SleepSegment(start: at(5_400), end: at(9_000), stage: .asleepREM),
        ]
        XCTAssertEqual(SleepHypnogramCodec.decode(SleepHypnogramCodec.encode(segments)), segments)
    }

    func testEveryStageSurvivesRoundTrip() {
        // Guards the code table: a renumbered case would decode as a different stage.
        for (i, stage) in SleepStage.allCases.enumerated() {
            let seg = SleepSegment(start: at(TimeInterval(i * 300)),
                                   end: at(TimeInterval(i * 300 + 150)), stage: stage)
            XCTAssertEqual(SleepHypnogramCodec.decode(SleepHypnogramCodec.encode([seg])), [seg],
                           "stage \(stage.rawValue) did not survive the round trip")
        }
    }

    func testEmptySegmentsEncodeToEmptyJSONArray() {
        XCTAssertEqual(String(data: SleepHypnogramCodec.encode([]), encoding: .utf8), "[]")
        XCTAssertEqual(SleepHypnogramCodec.decode(SleepHypnogramCodec.encode([])), [])
    }

    // MARK: - On-disk format lock

    func testOnDiskFormatIsPinnedToExactBytes() {
        let segments = [
            SleepSegment(start: t0, end: at(150), stage: .asleepDeep),
            SleepSegment(start: at(150), end: at(300), stage: .asleepCore),
        ]
        let encoded = String(data: SleepHypnogramCodec.encode(segments), encoding: .utf8)
        XCTAssertEqual(encoded, "[[1700000000,1700000150,3],[1700000150,1700000300,2]]",
                       """
                       On-disk hypnogram format changed. Nights already stored on user devices \
                       are in the OLD format — changing this encoding requires a migration, not \
                       an edit to this expectation.
                       """)
    }

    func testStageCodesArePinned() {
        // Spelled out separately from the byte lock so a renumbering names the offending stage.
        let expected: [SleepStage: Int] = [
            .inBed: 0, .awake: 1, .asleepCore: 2, .asleepDeep: 3, .asleepREM: 4
        ]
        for (stage, code) in expected {
            let data = SleepHypnogramCodec.encode(
                [SleepSegment(start: t0, end: at(150), stage: stage)])
            XCTAssertEqual(String(data: data, encoding: .utf8),
                           "[[1700000000,1700000150,\(code)]]",
                           "stage \(stage.rawValue) must stay wire code \(code)")
        }
    }

    // MARK: - Defensive decode (never throws, never fabricates)

    func testEmptyDataDecodesToEmpty() {
        XCTAssertEqual(SleepHypnogramCodec.decode(Data()), [])
    }

    func testMalformedJSONDecodesToEmpty() {
        for junk in ["not json at all", "{\"night\":1}", "[", "[[1,2,\"deep\"]]", "[1,2,3]"] {
            XCTAssertEqual(SleepHypnogramCodec.decode(Data(junk.utf8)), [],
                           "malformed payload \(junk) should decode to []")
        }
    }

    func testUnknownStageCodeDropsOnlyThatSegment() {
        let data = Data("[[1700000000,1700000150,3],[1700000150,1700000300,99]]".utf8)
        XCTAssertEqual(SleepHypnogramCodec.decode(data),
                       [SleepSegment(start: t0, end: at(150), stage: .asleepDeep)])
    }

    func testWrongArityDropsOnlyThatSegment() {
        let data = Data("[[1700000000,1700000150],[1700000150,1700000300,2]]".utf8)
        XCTAssertEqual(SleepHypnogramCodec.decode(data),
                       [SleepSegment(start: at(150), end: at(300), stage: .asleepCore)])
    }

    func testReversedAndZeroLengthSegmentsAreDropped() {
        let data = Data("""
        [[1700000150,1700000000,2],[1700000000,1700000000,2],[1700000000,1700000150,1]]
        """.utf8)
        XCTAssertEqual(SleepHypnogramCodec.decode(data),
                       [SleepSegment(start: t0, end: at(150), stage: .awake)])
    }

    func testEncodeSkipsSegmentsDecodeWouldRefuse() {
        // A stored segment we would not read back gives a night whose stored form disagrees
        // with its loaded form; encode must not create one.
        let segments = [
            SleepSegment(start: at(150), end: at(0), stage: .asleepCore),    // reversed
            SleepSegment(start: at(300), end: at(300), stage: .asleepCore),  // zero length
            SleepSegment(start: at(600), end: at(750), stage: .asleepREM),   // good
        ]
        let encoded = SleepHypnogramCodec.encode(segments)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "[[1700000600,1700000750,4]]")
        XCTAssertEqual(SleepHypnogramCodec.decode(encoded), [segments[2]])
    }

    func testEncodeIsIdempotentThroughDecode() {
        let segments = [
            SleepSegment(start: t0, end: at(150), stage: .asleepDeep),
            SleepSegment(start: at(150), end: at(300), stage: .asleepREM),
        ]
        let once = SleepHypnogramCodec.encode(segments)
        let twice = SleepHypnogramCodec.encode(SleepHypnogramCodec.decode(once))
        XCTAssertEqual(once, twice)
    }
}
