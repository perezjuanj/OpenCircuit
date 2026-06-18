import XCTest
@testable import OpenRingKit

final class EpochArchiveTests: XCTestCase {

    /// Build a 23-byte record with a given big-endian counter and a marker in `[4]` (HR slot) so
    /// dedup-override is observable.
    private func rec(_ counter: UInt32, marker: UInt8 = 0) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: BulkRecord.length)
        b[0] = UInt8((counter >> 24) & 0xff)
        b[1] = UInt8((counter >> 16) & 0xff)
        b[2] = UInt8((counter >> 8) & 0xff)
        b[3] = UInt8(counter & 0xff)
        b[4] = marker
        return BulkRecord(b)!
    }

    func testMergeDedupsByCounterIncomingWins() {
        let merged = EpochArchive.merge(existing: [rec(100, marker: 1)],
                                        incoming: [rec(100, marker: 2)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.raw[4], 2)   // the fresher drain's copy wins
    }

    func testMergeSortsByCounter() {
        let merged = EpochArchive.merge(existing: [rec(300)], incoming: [rec(100), rec(200)])
        XCTAssertEqual(merged.map(\.counter), [100, 200, 300])
    }

    func testMergePrunesBeyondRetention() {
        // retention 1000s; newest = 5000 → cutoff 4000. Anything below 4000 is dropped.
        let merged = EpochArchive.merge(existing: [rec(0), rec(3999), rec(4000)],
                                        incoming: [rec(5000)],
                                        retention: 1000)
        XCTAssertEqual(merged.map(\.counter), [4000, 5000])
    }

    func testRetentionUnderflowGuardKeepsAll() {
        // newest (20) < retention (huge) → cutoff clamps to 0, nothing pruned.
        let merged = EpochArchive.merge(existing: [rec(10), rec(20)], incoming: [],
                                        retention: 30 * 3600)
        XCTAssertEqual(merged.map(\.counter), [10, 20])
    }

    func testEncodeDecodeRoundTrip() {
        let records = [rec(100, marker: 7), rec(250, marker: 9)]
        let decoded = EpochArchive.decode(EpochArchive.encode(records))
        XCTAssertEqual(decoded.map(\.counter), [100, 250])
        XCTAssertEqual(decoded.map { $0.raw[4] }, [7, 9])
    }

    func testDecodeDropsTrailingPartialChunk() {
        var blob = EpochArchive.encode([rec(100), rec(200)])
        blob.append(contentsOf: [0xde, 0xad, 0xbe, 0xef, 0x01])   // 5 stray bytes, < one record
        XCTAssertEqual(EpochArchive.decode(blob).map(\.counter), [100, 200])
    }

    func testEmptyInputs() {
        XCTAssertTrue(EpochArchive.merge(existing: [], incoming: []).isEmpty)
        XCTAssertTrue(EpochArchive.encode([]).isEmpty)
        XCTAssertTrue(EpochArchive.decode(Data()).isEmpty)
    }

    /// Stitching shape: a night drained in two disjoint slices reassembles into one ordered series.
    func testTwoDisjointSlicesReassemble() {
        // slice 1 = early night [0, 150, 300]; slice 2 = late night [450, 600] (later drain).
        let early = [rec(0), rec(150), rec(300)]
        let late = [rec(450), rec(600)]
        let night = EpochArchive.merge(existing: early, incoming: late, retention: 30 * 3600)
        XCTAssertEqual(night.map(\.counter), [0, 150, 300, 450, 600])
    }
}
