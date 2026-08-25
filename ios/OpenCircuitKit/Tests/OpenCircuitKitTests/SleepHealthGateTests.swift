import XCTest
@testable import OpenCircuitKit

final class SleepHealthGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNilNeverSettled() {
        XCTAssertFalse(SleepHealthGate.isSettled(latestSegmentEnd: nil, now: now))
    }

    func testInProgressNightNotSettled() {
        // Last epoch 3 min ago — still asleep / block could grow.
        let end = now.addingTimeInterval(-3 * 60)
        XCTAssertFalse(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }

    func testFinishedNightSettled() {
        // Woke 40 min ago — block won't grow.
        let end = now.addingTimeInterval(-40 * 60)
        XCTAssertTrue(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }

    func testExactlyAtMarginIsSettled() {
        let end = now.addingTimeInterval(-SleepHealthGate.settleMargin)
        XCTAssertTrue(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }

    func testJustInsideMarginNotSettled() {
        let end = now.addingTimeInterval(-SleepHealthGate.settleMargin + 1)
        XCTAssertFalse(SleepHealthGate.isSettled(latestSegmentEnd: end, now: now))
    }

    func testOrdinaryWriteStillRequiresSettlement() {
        let end = now.addingTimeInterval(-3 * 60)
        XCTAssertFalse(SleepHealthGate.isReadyToWrite(
            latestSegmentEnd: end, now: now, finalized: false))
    }

    func testFocusEndFinalizationWritesImmediately() {
        let end = now.addingTimeInterval(-3 * 60)
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(
            latestSegmentEnd: end, now: now, finalized: true))
    }

    func testFinalizationStillRequiresRealSegments() {
        XCTAssertFalse(SleepHealthGate.isReadyToWrite(
            latestSegmentEnd: nil, now: now, finalized: true))
    }

    /// 🟢 THE CASE THE EDIT PATHS PASS `finalized: true` FOR (2026-08-24, Gen 2 Air FR04.009,
    /// Europe/Paris). She woke, saw the app had ended her night at a 02:45 bathroom trip, corrected
    /// her wake to 06:44 and saved at 06:50 — SIX minutes later, i.e. inside the 20-minute margin.
    /// `reconcileEditedNightSleepLocked` gated on `isSettled` and therefore wrote NOTHING at Save
    /// time; her report was "the data in Apple Health wasn't updated". Editing your wake right after
    /// waking is the normal case, and an edited night's edges are typed, not growing — so the Save
    /// is the finalization signal. The `false` arm below is the same instant WITHOUT that signal,
    /// so this pins the difference rather than just the new behaviour.
    func testAWearersSaveMinutesAfterHerAssertedWakeWritesImmediately() {
        let assertedWake = Date(timeIntervalSince1970: 1_787_546_640)          // 06:44:00 +02:00
        let saveTime = assertedWake.addingTimeInterval(6 * 60)                 // 06:50:00
        XCTAssertTrue(SleepHealthGate.isReadyToWrite(latestSegmentEnd: assertedWake,
                                                     now: saveTime, finalized: true))
        XCTAssertFalse(SleepHealthGate.isReadyToWrite(latestSegmentEnd: assertedWake,
                                                      now: saveTime, finalized: false),
                       "without the signal her edit is deferred — the behaviour she reported")
    }
}
