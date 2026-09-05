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

    // MARK: .linkDown — "we never asked" vs .noAck "the ring stayed silent"

    func testOpenWriteFailureIsLinkDownNotNoAck() {
        // A tester export showed 27 all-day `noAck`s and it read as a ring-side channel limit. The
        // ring had never been asked: the link was down and `RingSession.write` dropped the opens.
        var trace = HistoryChannelTrace(label: "all-day", channel: 0x03)
        trace.openWriteFailed = true
        trace.exitReason = .linkUnusable
        XCTAssertEqual(trace.outcome, .linkDown)
        XCTAssertFalse(trace.outcome.allowsSleepCommit)
    }

    func testRealEvidenceOutranksAStaleWriteFailureFlag() {
        // If the ring answered, the link plainly worked — the flag must not override that.
        var acked = HistoryChannelTrace(label: "all-day", channel: 0x03)
        acked.openWriteFailed = true
        acked.sawSyncAck = true
        XCTAssertEqual(acked.outcome, .empty)

        var paged = HistoryChannelTrace(label: "sleep", channel: 0x00)
        paged.openWriteFailed = true
        paged.page4CCount = 4
        paged.endMarkerCount = 1
        paged.exitReason = .endMarker
        XCTAssertEqual(paged.outcome, .complete)
        XCTAssertTrue(paged.outcome.allowsSleepCommit)

        var ppg = HistoryChannelTrace(label: "sleep", channel: 0x00)
        ppg.openWriteFailed = true
        ppg.page47Count = 1
        XCTAssertEqual(ppg.outcome, .ppgOnly)
    }

    func testTracesWrittenBeforeTheFlagExistedStillClassifyAsNoAck() {
        // `openWriteFailed` is Optional so old persisted ObservabilityStore JSON keeps decoding;
        // nil must behave exactly as the pre-change code did.
        var trace = HistoryChannelTrace(label: "all-day", channel: 0x03)
        trace.exitReason = .quietNoPages
        XCTAssertNil(trace.openWriteFailed)
        XCTAssertEqual(trace.outcome, .noAck)
    }

    func testLegacyTraceJSONWithoutTheNewFieldStillDecodes() throws {
        // Guards the real upgrade path: ObservabilityStore decodes with `try?` and falls back to
        // [], so a decode break would silently wipe a user's whole diagnostics history.
        let legacy = """
        {"label":"all-day","channel":3,"startedAt":0,"sawSyncAck":false,\
        "sawEmptyHistorySignal":false,"page4CCount":0,"page47Count":0,\
        "endMarkerCount":0,"recordsAtStart":0,"recordsAtEnd":0}
        """.data(using: .utf8)!
        let trace = try JSONDecoder().decode(HistoryChannelTrace.self, from: legacy)
        XCTAssertNil(trace.openWriteFailed)
        XCTAssertEqual(trace.outcome, .noAck)
    }

    // MARK: 0x4d sport counters (added 2026-08-27)

    func testLegacyTraceJSONWithoutTheSportCountersStillDecodes() throws {
        // THE ONE THAT MATTERS ON UPGRADE. `ObservabilityStore.historySyncEvidence()` decodes with
        // `try? … ?? []`, so a single `keyNotFound` does not surface as an error — it silently
        // returns the empty list and the user's ENTIRE diagnostics history disappears. A
        // non-optional `page4DCount` would do exactly that to every bundle stored before today.
        // This JSON is a verbatim pre-2026-08-27 trace: it has neither new key.
        let legacy = """
        {"label":"sport","channel":2,"startedAt":0,"sawSyncAck":true,\
        "sawEmptyHistorySignal":false,"page4CCount":0,"page47Count":0,\
        "endMarkerCount":1,"recordsAtStart":0,"recordsAtEnd":0,"exitReason":"endMarker"}
        """.data(using: .utf8)!
        let trace = try JSONDecoder().decode(HistoryChannelTrace.self, from: legacy)
        XCTAssertNil(trace.page4DCount)
        XCTAssertNil(trace.sportSampleCount)
        // …and nil must classify EXACTLY as the pre-change code did, so re-reading an old bundle
        // cannot invent a sport drain that never happened.
        XCTAssertEqual(trace.outcome, .empty)
    }

    func testNilCountersMeanPreUpgradeWhileAFreshTraceMeansMeasuredZero() {
        // The whole point of the pair: "we counted and it was zero" (a fresh trace) must be
        // distinguishable from "this build never counted" (a decoded legacy trace). `init` zeroes
        // them; the synthesized decoder leaves them nil.
        let fresh = HistoryChannelTrace(label: "sport", channel: 0x02)
        XCTAssertEqual(fresh.page4DCount, 0)
        XCTAssertEqual(fresh.sportSampleCount, 0)
    }

    func testSportPagesClassifyAsSportOnlyNotEmpty() {
        // The defect: a sport drain FULL of workout history exported `outcome: "empty"`, because
        // nothing counted 0x4d. That is why the project's own notes say the ring returns empty
        // sport history — the instrument could not tell that from a drain we mishandled.
        var trace = HistoryChannelTrace(label: "sport", channel: 0x02)
        trace.sawSyncAck = true
        trace.page4DCount = 7
        trace.sportSampleCount = 210
        trace.exitReason = .endMarker
        XCTAssertEqual(trace.outcome, .sportOnly)
        XCTAssertTrue(trace.sawAnyPage)
    }

    func testSportChannelThatTrulyReturnedNothingIsStillEmpty() {
        // The mirror case — this is the reading the old code CLAIMED to be making. It must still
        // be reachable, or `.sportOnly` would just relabel the ambiguity instead of resolving it.
        var trace = HistoryChannelTrace(label: "sport", channel: 0x02)
        trace.sawSyncAck = true
        trace.exitReason = .endMarker
        XCTAssertEqual(trace.outcome, .empty)
        XCTAssertFalse(trace.sawAnyPage)
    }

    func testPagesWithoutSamplesIsDistinguishableFromAnEmptyChannel() {
        // Pages > 0 with samples == 0 means the ring delivered and OUR decode dropped it. Before
        // the counters existed this was indistinguishable from a channel that returned nothing —
        // the two need opposite fixes, so the classification must not merge them.
        var decodeBroken = HistoryChannelTrace(label: "sport", channel: 0x02)
        decodeBroken.sawSyncAck = true
        decodeBroken.page4DCount = 5
        decodeBroken.sportSampleCount = 0
        XCTAssertEqual(decodeBroken.outcome, .sportOnly)

        var ringEmpty = HistoryChannelTrace(label: "sport", channel: 0x02)
        ringEmpty.sawSyncAck = true
        XCTAssertEqual(ringEmpty.outcome, .empty)
        XCTAssertNotEqual(decodeBroken.outcome, ringEmpty.outcome)
    }

    func testSportOnlyNeverCommitsSleep() {
        // Sport records carry no sleep epochs. `.sportOnly` took over branches of `.empty`/`.noAck`
        // that were both non-committing, so this invariant must survive the new case.
        XCTAssertFalse(HistoryChannelOutcome.sportOnly.allowsSleepCommit)
        XCTAssertEqual(HistoryCommitGate.decide(outcome: .sportOnly, recordsAdded: 5,
                                                adoptedRecordCount: 0),
                       .skip)
    }

    func testSportCountersNeverDegradeAnEpochOrPPGChannel() {
        // Ordering lock: `.sportOnly` sits AFTER the 0x4c and 0x47 branches, so a channel that
        // delivered real epoch or PPG pages keeps the exact classification it had before the case
        // existed — even if a 0x4d somehow landed on it. A regression here could flip a committable
        // sleep drain to non-committable, which is the night-losing class.
        var sleep = HistoryChannelTrace(label: "sleep", channel: 0x00)
        sleep.sawSyncAck = true
        sleep.page4CCount = 3
        sleep.page4DCount = 2
        sleep.endMarkerCount = 1
        sleep.exitReason = .endMarker
        XCTAssertEqual(sleep.outcome, .complete)
        XCTAssertTrue(sleep.outcome.allowsSleepCommit)

        var ppg = HistoryChannelTrace(label: "sleep", channel: 0x00)
        ppg.sawSyncAck = true
        ppg.page47Count = 1
        ppg.page4DCount = 2
        XCTAssertEqual(ppg.outcome, .ppgOnly)
    }

    func testOutcomeAndExitReasonRawValuesAreStable() {
        // Both are persisted as strings in ObservabilityStore evidence bundles.
        XCTAssertEqual(HistoryChannelOutcome.linkDown.rawValue, "linkDown")
        XCTAssertEqual(HistoryChannelOutcome.sportOnly.rawValue, "sportOnly")
        XCTAssertEqual(HistoryChannelExitReason.linkUnusable.rawValue, "linkUnusable")
    }

    // MARK: .cancelled — interrupted by OUR OWN session teardown, not a ring-side signal

    func testCancelledMidWaitIsNotMisreportedAsNoAck() {
        // A BLE session replacement cancels whatever channel is mid-wait. Before this outcome had
        // no `.cancelled` branch, so a channel cut off before any ring response fell through to
        // `.noAck` — indistinguishable from a live link the ring genuinely never answered on. That
        // conflation is exactly what let session-churn starvation misdiagnose as "the ring stayed
        // silent" (2026-09-04 tester export: `all-day`/`sport` `noAck` on nearly every cycle, only
        // `sleep` — first in the foreground plan — occasionally winning the race).
        var trace = HistoryChannelTrace(label: "all-day", channel: 0x03)
        trace.exitReason = .cancelled
        XCTAssertEqual(trace.outcome, .cancelled)
        XCTAssertFalse(trace.outcome.allowsSleepCommit)
    }

    func testRealEvidenceOutranksACancelledExitReason() {
        // If pages or an ACK arrived before the cancellation landed, that's real evidence the
        // cancel must not erase — same precedence rule as the `.linkDown` write-failure flag.
        var acked = HistoryChannelTrace(label: "all-day", channel: 0x03)
        acked.sawSyncAck = true
        acked.exitReason = .cancelled
        XCTAssertEqual(acked.outcome, .empty)

        var paged = HistoryChannelTrace(label: "sleep", channel: 0x00)
        paged.page4CCount = 2
        paged.endMarkerCount = 1
        paged.exitReason = .cancelled
        XCTAssertEqual(paged.outcome, .complete)
        XCTAssertTrue(paged.outcome.allowsSleepCommit)
    }
}
