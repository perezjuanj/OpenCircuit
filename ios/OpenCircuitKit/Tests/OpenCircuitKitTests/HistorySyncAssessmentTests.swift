import XCTest
@testable import OpenCircuitKit

final class HistorySyncAssessmentTests: XCTestCase {

    func testSleepPagesAndEndMarkerAreComplete() {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.sawSyncAck = true
        trace.page4CCount = 2
        trace.endMarkerCount = 1
        trace.exitReason = .endMarker
        XCTAssertEqual(trace.outcome, .complete)
        XCTAssertTrue(trace.outcome.allowsSleepCommit)
    }

    func testQuietAfterSleepPagesStillCountsAsComplete() {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.sawSyncAck = true
        trace.page4CCount = 1
        trace.exitReason = .quietAfterPages
        XCTAssertEqual(trace.outcome, .complete)
    }

    func testSleepPagesWithoutCleanExitArePartial() {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.sawSyncAck = true
        trace.page4CCount = 1
        trace.exitReason = .hardTimeout
        XCTAssertEqual(trace.outcome, .partial)
        XCTAssertFalse(trace.outcome.allowsSleepCommit)
    }

    func testPpgOnlyDrainIsNotSleepSuccess() {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.sawSyncAck = true
        trace.page47Count = 3
        trace.exitReason = .quietAfterPages
        XCTAssertEqual(trace.outcome, .ppgOnly)
    }

    func testAckPlusEndMarkerWithoutPagesIsEmpty() {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.sawSyncAck = true
        trace.endMarkerCount = 1
        trace.exitReason = .endMarker
        XCTAssertEqual(trace.outcome, .empty)
    }

    func testNoAckIsNoAck() {
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.exitReason = .hardTimeout
        XCTAssertEqual(trace.outcome, .noAck)
    }

    // MARK: sawEmptyHistorySignal (0x82 byte[1]=0xff, added 2026-06-28)

    func testSawEmptyHistorySignalDefaultsFalse() {
        let trace = HistoryChannelTrace(label: "all-day", channel: 0x03)
        XCTAssertFalse(trace.sawEmptyHistorySignal)
    }

    func testSawEmptyHistorySignal_outcomeIsEmptyWhenAckAndNoPages() {
        // Matches the observed `82 ff 00 7d` ACK: got ACK, no pages, signal set.
        // Outcome must be .empty — same as a normal empty-ACK channel. The signal
        // only affects the drain LOOP's exit timing, not the classification.
        var trace = HistoryChannelTrace(label: "all-day", channel: 0x03)
        trace.sawSyncAck = true
        trace.sawEmptyHistorySignal = true
        trace.exitReason = .quietNoPages
        XCTAssertEqual(trace.outcome, .empty)
        XCTAssertFalse(trace.outcome.allowsSleepCommit)
    }

    func testSawEmptyHistorySignal_doesNotDegradeCompleteOutcome() {
        // If pages somehow arrive after an empty-signal ACK, the outcome is still .complete.
        // The signal is a hint to exit early — it must not poison a real drain.
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.sawSyncAck = true
        trace.sawEmptyHistorySignal = true   // signal set but pages arrived anyway
        trace.page4CCount = 3
        trace.endMarkerCount = 1
        trace.exitReason = .endMarker
        XCTAssertEqual(trace.outcome, .complete)
        XCTAssertTrue(trace.outcome.allowsSleepCommit)
    }

    func testSawEmptyHistorySignal_noAckWithSignalStaysNoAck() {
        // Signal alone (no ACK, no pages) must not change the .noAck classification.
        var trace = HistoryChannelTrace(label: "sleep", channel: 0x00)
        trace.sawEmptyHistorySignal = true
        trace.exitReason = .quietNoPages
        XCTAssertEqual(trace.outcome, .noAck)
    }
}
