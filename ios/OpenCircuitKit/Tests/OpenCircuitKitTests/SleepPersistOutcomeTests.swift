import XCTest
@testable import OpenCircuitKit

// #204 — the night summary can fail to persist silently while naps succeed.
//
// 🟢 GROUNDED on a Gen-3 tester's schema-3 export (FR05.010, build 39, range 2026-08-09 →
// 2026-08-12): `"sleep": []`, no `sleepSessions` key, 3 naps — while the Sleep card showed a full
// 8 h 31 m night with a hypnogram, and `historySyncEvidence` reported `sleepCommitted: true` on
// drain after drain. The flag meant "the stage path ran", not "a row landed", so the one breadcrumb
// that could have caught it actively asserted the opposite.
//
// These assert the CLASSIFICATION — which outcomes mean the wearer has a night and which mean they
// have nothing — because that is what `sleepCommitted`, the metric events and the card's warning are
// all defined against. A branch added later without a decision here fails `testEveryOutcomeIsClassified`.
final class SleepPersistOutcomeTests: XCTestCase {

    func testOnlyRealWritesCount()  {
        XCTAssertTrue(SleepPersistOutcome.inserted.wroteRow)
        XCTAssertTrue(SleepPersistOutcome.updated.wroteRow)
        for o in SleepPersistOutcome.allCases where o != .inserted && o != .updated {
            XCTAssertFalse(o.wroteRow, "\(o) is not a write and must not report one")
        }
    }

    /// The distinction the old boolean could not make: a drain that stored nothing because the
    /// stored night is BETTER is healthy; a drain that stored nothing because the write failed is
    /// the defect. Both are `wroteRow == false`.
    func testDeliberateKeepsAreNotLosses() {
        XCTAssertTrue(SleepPersistOutcome.keptFullerStoredNight.nightIsStored)
        XCTAssertTrue(SleepPersistOutcome.keptManualEdit.nightIsStored)
        XCTAssertFalse(SleepPersistOutcome.keptFullerStoredNight.isSilentLoss)
        XCTAssertFalse(SleepPersistOutcome.keptManualEdit.isSilentLoss)
    }

    func testTheFourWaysToEndUpWithNoStoredNight() {
        let losses: [SleepPersistOutcome] =
            [.noStagedSegments, .deferredNightKeyMigration, .refusedNightKeyCollision, .failed]
        for o in losses {
            XCTAssertTrue(o.isSilentLoss, "\(o) leaves the wearer with no stored night")
            XCTAssertFalse(o.nightIsStored)
        }
    }

    /// A collision is permanent for this staging — every retry hits the same guard — which is why
    /// its user-facing copy must not promise that syncing again will fix it.
    func testCollisionIsNotRecoverableByRetry() {
        XCTAssertFalse(SleepPersistOutcome.refusedNightKeyCollision.isRecoverableByRetry)
        XCTAssertTrue(SleepPersistOutcome.deferredNightKeyMigration.isRecoverableByRetry)
        XCTAssertTrue(SleepPersistOutcome.noStagedSegments.isRecoverableByRetry)
        XCTAssertTrue(SleepPersistOutcome.failed.isRecoverableByRetry)
    }

    func testEveryOutcomeIsClassified() {
        for o in SleepPersistOutcome.allCases {
            // Exactly one of the two states, never both, never neither.
            XCTAssertNotEqual(o.nightIsStored, o.isSilentLoss, "\(o) is unclassified")
            // Only a loss may claim retry-recoverability — a stored night has nothing to retry.
            if o.isRecoverableByRetry { XCTAssertTrue(o.isSilentLoss, "\(o)") }
        }
    }

    /// The raw values are persisted in `historySyncEvidence.nightRowOutcome` and read back from
    /// exports taken on older builds, so they are wire format and must not be renamed casually.
    func testRawValuesAreStable() {
        XCTAssertEqual(SleepPersistOutcome.inserted.rawValue, "inserted")
        XCTAssertEqual(SleepPersistOutcome.updated.rawValue, "updated")
        XCTAssertEqual(SleepPersistOutcome.keptFullerStoredNight.rawValue, "keptFullerStoredNight")
        XCTAssertEqual(SleepPersistOutcome.keptManualEdit.rawValue, "keptManualEdit")
        XCTAssertEqual(SleepPersistOutcome.refusedNightKeyCollision.rawValue, "refusedNightKeyCollision")
        XCTAssertEqual(SleepPersistOutcome.noStagedSegments.rawValue, "noStagedSegments")
        XCTAssertEqual(SleepPersistOutcome.deferredNightKeyMigration.rawValue, "deferredNightKeyMigration")
        XCTAssertEqual(SleepPersistOutcome.failed.rawValue, "failed")
    }
}
