// Decision 84j: an indoor run or walk with steps waits for its distance prompt before its HKWorkout is
// saved; a kill in that wait is offered back at the next launch, and saved with its step estimate. The
// two recovery records (the strap's journal, the ring's snapshot) carry that estimate through their
// decisions, and a record without one (every other workout, every older build's) carries none.
// Synthetic, rounded times.

import XCTest
@testable import OpenCircuitKit

final class IndoorRunRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheStrapJournalOfAnEndedIndoorRunOffersItBackWithItsEstimate() {
        let journal = StrapWorkoutJournal(sport: .runningIndoor, ledger: WorkoutActivityLedger(start: t0),
                                          lastAliveAt: t0.addingTimeInterval(300), timelineRaw: "zeppos:X",
                                          stepStreamOn: false, indoorEstimateMeters: 702)
        let readings = stride(from: 10.0, through: 300, by: 10).map {
            HRSample(bpm: 160, start: t0.addingTimeInterval($0 - 1), end: t0.addingTimeInterval($0))
        }
        guard case .offer(let recovered) = StrapWorkoutRecovery.decide(journal: journal, samples: readings,
                                                                       now: t0.addingTimeInterval(4_000)) else {
            return XCTFail("expected an offer")
        }
        XCTAssertEqual(recovered.indoorEstimateMeters, 702)
        XCTAssertEqual(recovered.end, t0.addingTimeInterval(300))
        // Round trip through the journal file's JSON, and an older journal without the field.
        XCTAssertEqual(StrapWorkoutJournal.decoded(from: journal.encoded())?.indoorEstimateMeters, 702)
        let older = #"{"sport":"runningIndoor","ledger":{"start":0,"pauses":[],"gaps":[]},"lastAliveAt":300,"timelineRaw":"zeppos:X"}"#
        XCTAssertNil(StrapWorkoutJournal.decoded(from: Data(older.utf8))?.indoorEstimateMeters)
    }

    func testTheRingSnapshotOfAnEndedIndoorRunOffersItBackWithItsEstimateAndOthersCarryNone() {
        let ended = WorkoutSessionSnapshot(sport: .walkingIndoor, startDate: t0, lastAliveAt: t0.addingTimeInterval(600),
                                           hrSampleCount: 60, indoorEstimateMeters: 450)
        guard case .offer(let recovered) = WorkoutSessionRecovery.decide(snapshot: ended, now: t0.addingTimeInterval(4_000)) else {
            return XCTFail("expected an offer")
        }
        XCTAssertEqual(recovered.indoorEstimateMeters, 450)
        XCTAssertEqual(recovered.end, t0.addingTimeInterval(600))
        XCTAssertEqual(WorkoutSessionSnapshot.decoded(from: ended.encoded())?.indoorEstimateMeters, 450)

        let outdoor = WorkoutSessionSnapshot(sport: .runningOutdoor, startDate: t0, lastAliveAt: t0.addingTimeInterval(600),
                                             hrSampleCount: 60)
        guard case .offer(let plain) = WorkoutSessionRecovery.decide(snapshot: outdoor, now: t0.addingTimeInterval(4_000)) else {
            return XCTFail("expected an offer")
        }
        XCTAssertNil(plain.indoorEstimateMeters)
    }
}
