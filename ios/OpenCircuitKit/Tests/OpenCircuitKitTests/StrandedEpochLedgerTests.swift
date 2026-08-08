import XCTest
@testable import OpenCircuitKit

final class StrandedEpochLedgerTests: XCTestCase {

    /// A record with a given counter; the remaining 19 bytes are irrelevant to ledger selection.
    private func record(counter: UInt32, fill: UInt8 = 0x0a) -> BulkRecord {
        var bytes: [UInt8] = [
            UInt8((counter >> 24) & 0xff), UInt8((counter >> 16) & 0xff),
            UInt8((counter >> 8) & 0xff), UInt8(counter & 0xff),
        ]
        bytes += Array(repeating: fill, count: BulkRecord.length - 4)
        return BulkRecord(bytes)!
    }

    // MARK: selection

    /// The healthy ring: nothing owed, so a drain folds in nothing and behaves exactly as before.
    func testEmptyLedgerSelectsNothing() {
        let archive = (0..<5).map { record(counter: 1000 + UInt32($0) * 150) }
        XCTAssertTrue(StrandedEpochLedger.select(archive: archive, ledger: [], alreadyHeld: []).isEmpty)
    }

    func testSelectsOnlyLedgeredRecords() {
        let archive = (0..<5).map { record(counter: 1000 + UInt32($0) * 150) }
        let selected = StrandedEpochLedger.select(archive: archive, ledger: [1000, 1300], alreadyHeld: [])
        XCTAssertEqual(selected.map(\.counter), [1000, 1300])
    }

    /// `LocalStore.ingest` has no within-batch dedup, so a record the drain already holds (an adopted
    /// orphan) must never be folded in a second time.
    func testExcludesRecordsTheDrainAlreadyHolds() {
        let archive = (0..<5).map { record(counter: 1000 + UInt32($0) * 150) }
        let selected = StrandedEpochLedger.select(archive: archive,
                                                  ledger: [1000, 1150, 1300],
                                                  alreadyHeld: [1150])
        XCTAssertEqual(selected.map(\.counter), [1000, 1300])
    }

    /// A ledger entry the archive no longer holds (pruned at 30 h retention) is simply not selected —
    /// it must not fabricate a record or trap the ledger in a non-empty state that never resolves.
    func testLedgerEntryMissingFromArchiveIsIgnored() {
        let archive = [record(counter: 1000)]
        let selected = StrandedEpochLedger.select(archive: archive, ledger: [1000, 999_999], alreadyHeld: [])
        XCTAssertEqual(selected.map(\.counter), [1000])
    }

    // MARK: mark / retire

    func testMarkIsIdempotent() {
        var ledger = StrandedEpochLedger.mark(ledger: [], banked: [1000, 1150])
        ledger = StrandedEpochLedger.mark(ledger: ledger, banked: [1150, 1300])
        XCTAssertEqual(ledger, [1000, 1150, 1300])
    }

    /// 🔒 THE `.idle` TRAP. An unworn/charging epoch decodes NO samples at all, so a "retire only what
    /// produced a sample" rule would re-select it on every drain forever — and since the archive
    /// prunes by AGE while these are the newest records, retention could never clear it either.
    /// Retiring on commit regardless of yield is what makes this converge.
    func testRetireIsUnconditionalSoSampleLessEpochsCannotLoopForever() {
        let ledger: Set<UInt32> = [1000, 1150, 1300]
        // The commit ran all three through `persist`; none yielded a sample.
        let after = StrandedEpochLedger.retire(ledger: ledger, committed: [1000, 1150, 1300])
        XCTAssertTrue(after.isEmpty, "a committed epoch must retire even when it produced no samples")
    }

    func testRetireLeavesUncommittedEntriesStanding() {
        let after = StrandedEpochLedger.retire(ledger: [1000, 1150, 1300], committed: [1000])
        XCTAssertEqual(after, [1150, 1300])
    }

    /// End-to-end convergence: bank → select → commit → retire leaves nothing owed, and a second
    /// drain re-selects nothing.
    func testBankSelectCommitRetireConverges() {
        let archive = (0..<4).map { record(counter: 2000 + UInt32($0) * 150) }
        var ledger = StrandedEpochLedger.mark(ledger: [], banked: archive.map(\.counter))

        let firstPass = StrandedEpochLedger.select(archive: archive, ledger: ledger, alreadyHeld: [])
        XCTAssertEqual(firstPass.count, 4, "a stranded night must be offered to the next drain")

        ledger = StrandedEpochLedger.retire(ledger: ledger, committed: firstPass.map(\.counter))
        XCTAssertTrue(ledger.isEmpty)

        let secondPass = StrandedEpochLedger.select(archive: archive, ledger: ledger, alreadyHeld: [])
        XCTAssertTrue(secondPass.isEmpty, "re-hydration must not repeat once committed")
    }
}
