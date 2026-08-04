import XCTest
@testable import OpenCircuitKit

/// #188 — the staging decision that decides whether a drained night becomes a sleep summary.
///
/// These assertions are written so that DELETING either rule makes one fail:
///   • drop the `.complete` requirement → `testPartialDrainMayNotStageItsOwnSlice` fails.
///   • drop the adopted-record clause → `testAdoptedOnlyNightIsRescuedFromTheArchive` and
///     `testCompleteDrainWithOnlyAdoptedRecordsStages` fail.
final class HistoryCommitGateTests: XCTestCase {

    private func decide(_ outcome: HistoryChannelOutcome?,
                        added: Int = 0,
                        adopted: Int = 0) -> HistoryCommitGate.Decision {
        HistoryCommitGate.decide(outcome: outcome, recordsAdded: added, adoptedRecordCount: adopted)
    }

    // MARK: rule 1 — conservative staging

    func testCompleteDrainWithItsOwnRecordsStages() {
        XCTAssertEqual(decide(.complete, added: 34), .stage)
    }

    func testPartialDrainMayNotStageItsOwnSlice() {
        // The truncated-night gate: a drain cut mid-stream must never overwrite a fuller stored
        // night, however many records it happens to hold.
        for outcome in [HistoryChannelOutcome.partial, .ppgOnly, .noAck, .linkDown, .empty] {
            XCTAssertNotEqual(decide(outcome, added: 174), .stage,
                              "\(outcome.rawValue) must not stage its own slice")
        }
    }

    func testCompleteButEmptyDrainDoesNothing() {
        // The healthy periodic empty poll: nothing new, nothing adopted → no churn.
        XCTAssertEqual(decide(.complete, added: 0, adopted: 0), .skip)
        XCTAssertEqual(decide(.empty, added: 0, adopted: 0), .skip)
    }

    // MARK: rule 2 — the #188 adopted-night rescue

    /// The Gen 2 / FR02.018 tester: 174 records were ACKed with no drain open, then the drain that
    /// finally attached pulled 34 of its own and reached the ring's `0x50` end marker.
    func testCompleteDrainWithOnlyAdoptedRecordsStages() {
        XCTAssertEqual(decide(.complete, added: 0, adopted: 174), .stage,
                       "adopted records are fresh records — they reached the phone on this connection")
    }

    /// The Gen 2 Air / FR04.009 tester: her whole 7.8 h night was ACKed outside a drain, and the
    /// drain that followed reported `.empty` on its sleep channel. Rule 1 alone hides that night
    /// behind a truncated summary; the rescue re-stages it from the merged archive union.
    func testAdoptedOnlyNightIsRescuedFromTheArchive() {
        XCTAssertEqual(decide(.empty, added: 0, adopted: 189), .restageFromArchive)
    }

    func testAdoptedRecordsRescueEveryNonCompleteOutcome() {
        for outcome in [HistoryChannelOutcome.empty, .partial, .ppgOnly, .noAck, .linkDown] {
            XCTAssertEqual(decide(outcome, adopted: 189), .restageFromArchive,
                           "\(outcome.rawValue) still owes the user the night it already ACKed")
        }
    }

    /// A drain whose sleep channel never ran at all has no outcome to reason from, but adopted
    /// records are self-evidently real.
    func testNoSleepTraceStillRescuesAdoptedRecords() {
        XCTAssertEqual(decide(nil, adopted: 189), .restageFromArchive)
        XCTAssertEqual(decide(nil, added: 0, adopted: 0), .skip)
    }

    /// The rescue is deliberately the WEAKER action: it re-reads the merge-protected archive union
    /// rather than staging this drain's slice, so it can only grow a night, never shrink one.
    func testRescueNeverEscalatesToAFullStage() {
        XCTAssertNotEqual(decide(.partial, added: 174, adopted: 174), .stage)
        XCTAssertEqual(decide(.partial, added: 174, adopted: 174), .restageFromArchive)
    }
}
