import XCTest
@testable import OpenCircuitKit

/// The export's `coverageFraction` witness — see `ExportCoverageWitness` for the measured defect
/// these cover (the persisted store rows are `SyncCursor.selectNew`'s forward-only output, not the
/// record set staging runs on, so a single live sample stranded 62 real epochs and the file
/// published `0.7333 / 4 gaps` about a window the ring had recorded end to end).
final class ExportCoverageWitnessTests: XCTestCase {

    // MARK: - Record construction

    /// A worn `0x4c` epoch with a real HR byte. Built from raw bytes rather than a synthetic
    /// convenience initializer so the record goes through the SAME `layout`/`heartRate` accessors
    /// production reads (the project's flat-motion-fixture scar: a hand-made "record" that skips the
    /// real decode path makes a test pass by construction).
    private func wornRecord(at date: Date, hr: UInt8 = 58) -> BulkRecord {
        var raw = [UInt8](repeating: 0, count: BulkRecord.length)
        let counter = UInt32(Int(date.timeIntervalSince1970) - Command.syncEpoch)
        raw[0] = UInt8(counter >> 24); raw[1] = UInt8((counter >> 16) & 0xff)
        raw[2] = UInt8((counter >> 8) & 0xff); raw[3] = UInt8(counter & 0xff)
        raw[4] = hr                       // HR — `[4]` on any worn epoch
        raw[8] = 0x60                     // 96 % SpO2 → .sleepVitals, not the activity sentinel
        raw[9] = 0x0a
        for i in 10..<15 { raw[i] = 2 }   // motion, deliberately NOT the 01×5 idle template
        return BulkRecord(raw)!
    }

    /// The unworn/charging template — a record that exists but measures nothing.
    private func idleRecord(at date: Date) -> BulkRecord {
        var raw = [UInt8](repeating: 0, count: BulkRecord.length)
        let counter = UInt32(Int(date.timeIntervalSince1970) - Command.syncEpoch)
        raw[0] = UInt8(counter >> 24); raw[1] = UInt8((counter >> 16) & 0xff)
        raw[2] = UInt8((counter >> 8) & 0xff); raw[3] = UInt8(counter & 0xff)
        raw[4] = 0x05; raw[5] = 0x00; raw[6] = 0x0c; raw[7] = 0x00
        raw[9] = 0x0a
        for i in 10..<15 { raw[i] = 1 }
        return BulkRecord(raw)!
    }

    private let start = Date(timeIntervalSince1970: 1_755_000_000)
    private var end: Date { start.addingTimeInterval(3 * 3600) }

    private func epochs(count: Int, from offset: TimeInterval = 0) -> [BulkRecord] {
        (0..<count).map {
            wornRecord(at: start.addingTimeInterval(offset + Double($0) * 150))
        }
    }

    // MARK: - The defect

    /// THE MEASURED DEFECT, in miniature. The ring recorded the whole window; the store holds only
    /// the tail because a live sample pushed the forward-only cursor past the rest. The store-only
    /// witness reports a large hole that never happened; the union reports none.
    func testArchiveEpochsRescueACoverageHoleTheForwardOnlyCursorInvented() {
        let archive = epochs(count: 72)                    // 72 × 150 s = the full 3 h window
        let strandedTail = archive.suffix(20).map { $0.date() }

        let storeOnly = ExportCoverage.assess(sampleTimes: strandedTail, from: start, to: end)
        XCTAssertEqual(storeOnly.gaps.count, 1)
        XCTAssertGreaterThan(storeOnly.longestGapSeconds, 7000)
        XCTAssertLessThan(storeOnly.coverageFraction, 0.3)

        let witness = ExportCoverageWitness.sampleTimes(
            archives: [archive], storedHeartRateTimes: strandedTail, from: start, to: end)
        let union = ExportCoverage.assess(sampleTimes: witness, from: start, to: end)
        XCTAssertEqual(union.gaps.count, 0, "the ring recorded every epoch of this window")
        XCTAssertEqual(union.coverageFraction, 1.0, accuracy: 0.0001)
    }

    /// THE OTHER HALF, and the reason this is a UNION and not a switch to the archive. The archive
    /// is a ~30 h rolling buffer; a night it has aged out of must fall back to the store, NOT be
    /// reported as a night-long hole. (Measured consequence of getting this wrong: night
    /// 2026-08-23 of the tester export would have gone from 0.9832 / one 602 s gap to 0.5798 / one
    /// 7701 s gap, every second of which is retention.)
    func testAnArchiveThatHasAgedPastTheNightLeavesTheStoreWitnessAlone() {
        // Archive holds only ground a full day AFTER the night being exported.
        let staleArchive = (0..<72).map {
            wornRecord(at: start.addingTimeInterval(86_400 + Double($0) * 150))
        }
        let storeTimes = epochs(count: 72).map { $0.date() }

        let witness = ExportCoverageWitness.sampleTimes(
            archives: [staleArchive], storedHeartRateTimes: storeTimes, from: start, to: end)
        let union = ExportCoverage.assess(sampleTimes: witness, from: start, to: end)
        let storeOnly = ExportCoverage.assess(sampleTimes: storeTimes, from: start, to: end)
        XCTAssertEqual(union.coverageFraction, storeOnly.coverageFraction)
        XCTAssertEqual(union.gaps.count, storeOnly.gaps.count)
        XCTAssertEqual(union.observedSamples, storeOnly.observedSamples)
    }

    // MARK: - Invariants

    /// MONOTONICITY. The union can only ever ADD instants we genuinely hold, so no night whose
    /// coverage hole is REAL can have it papered over: coverage never falls and gaps never grow.
    /// Checked against a real hole — the archive itself is missing the middle hour.
    func testAGenuineRecordingHoleSurvivesTheUnion() {
        let firstHour = epochs(count: 24)                       // 00:00 → 01:00
        let lastHour = epochs(count: 24, from: 2 * 3600)         // 02:00 → 03:00
        let archive = firstHour + lastHour
        let storeTimes = lastHour.map { $0.date() }

        let witness = ExportCoverageWitness.sampleTimes(
            archives: [archive], storedHeartRateTimes: storeTimes, from: start, to: end)
        let union = ExportCoverage.assess(sampleTimes: witness, from: start, to: end)
        let storeOnly = ExportCoverage.assess(sampleTimes: storeTimes, from: start, to: end)

        XCTAssertEqual(union.gaps.count, 1, "the middle hour is a real hole in the record stream")
        XCTAssertEqual(union.longestGapSeconds, 3600, accuracy: 150)
        // …and it is still an improvement on the store-only view, never a regression.
        XCTAssertGreaterThan(union.coverageFraction, storeOnly.coverageFraction)
        XCTAssertLessThanOrEqual(union.longestGapSeconds, storeOnly.longestGapSeconds)
    }

    /// An `.idle` (unworn/charging) record is not a measurement and must not count as coverage —
    /// otherwise a ring sitting in its case would export as a fully covered night.
    func testIdleRecordsAreNotCoverage() {
        let idle = (0..<72).map { idleRecord(at: start.addingTimeInterval(Double($0) * 150)) }
        let witness = ExportCoverageWitness.sampleTimes(
            archives: [idle], storedHeartRateTimes: [], from: start, to: end)
        XCTAssertTrue(witness.isEmpty)
        XCTAssertEqual(ExportCoverage.assess(sampleTimes: witness, from: start, to: end)
                        .coverageFraction, 0)
    }

    /// TWO RINGS ARE NOT ONE TIMELINE. The archive is per-ring precisely so two rings' records are
    /// never merged; the witness picks the archive that actually recorded this night instead of
    /// unioning them into a coverage number neither ring earned.
    func testTwoRingArchivesAreNotMergedIntoOneWitness() {
        let wornRing = epochs(count: 72)
        // The other ring contributed only 12 epochs to the same window — it covers the first 30
        // minutes and then has nothing. (These ARE worn records; `epochs(count:)` builds no charging
        // state, so this fixture says "recorded less", not "was on a charger". The witness must pick
        // the archive that actually covers the night either way.)
        let otherRing = epochs(count: 12)
        let witness = ExportCoverageWitness.sampleTimes(
            archives: [otherRing, wornRing], storedHeartRateTimes: [], from: start, to: end)
        XCTAssertEqual(witness.count, 72)
        XCTAssertEqual(Set(witness), Set(wornRing.map { $0.date() }))
    }

    /// Records outside the window are ignored rather than counted, and a degenerate window returns
    /// the store witness untouched (the caller's own `end > start` guard is what gates the block,
    /// so this only has to be non-destructive).
    func testOutOfWindowRecordsAndDegenerateWindows() {
        let before = (1...10).map { wornRecord(at: start.addingTimeInterval(Double(-$0) * 150)) }
        let inside = epochs(count: 5)
        let witness = ExportCoverageWitness.sampleTimes(
            archives: [before + inside], storedHeartRateTimes: [], from: start, to: end)
        XCTAssertEqual(witness.count, 5)

        let stored = [start]
        XCTAssertEqual(ExportCoverageWitness.sampleTimes(
            archives: [inside], storedHeartRateTimes: stored, from: end, to: start), stored)
    }
}
