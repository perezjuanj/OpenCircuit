import XCTest
@testable import OpenCircuitKit

/// Locks in the "stuck at 98 while the reading counter climbs" regression fix (#45): a workout
/// must record a live-HR sample only for a genuinely fresh, in-session, not-yet-recorded lock —
/// never the ring's last value held between polls.
final class WorkoutHRGateTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Records a real fresh lock

    func testRecordsAFreshInSessionLock() {
        let now = start.addingTimeInterval(10)
        let lockedAt = now.addingTimeInterval(-1)   // 1 s old ⇒ fresh
        XCTAssertTrue(WorkoutHRGate.shouldRecord(
            liveHRAt: lockedAt, sessionStart: start,
            lastRecordedAt: nil, now: now))
    }

    // MARK: - The freeze: a held latch must NOT be re-recorded

    func testRejectsAHeldLatchReReadEveryPoll() {
        // The ring locked once at t+2 and never re-locked; the workout polls again at t+4, t+6…
        let lockedAt = start.addingTimeInterval(2)
        // First poll records it.
        XCTAssertTrue(WorkoutHRGate.shouldRecord(
            liveHRAt: lockedAt, sessionStart: start,
            lastRecordedAt: nil, now: start.addingTimeInterval(2)))
        // Subsequent polls see the SAME capture time ⇒ must be rejected (no climbing counter).
        for tick in stride(from: 4.0, through: 20.0, by: 2.0) {
            XCTAssertFalse(WorkoutHRGate.shouldRecord(
                liveHRAt: lockedAt, sessionStart: start,
                lastRecordedAt: lockedAt, now: start.addingTimeInterval(tick)),
                "a held latch re-read at t+\(tick) must not record")
        }
    }

    func testRejectsAStaleLockOlderThanMaxAge() {
        let lockedAt = start.addingTimeInterval(2)
        let now = start.addingTimeInterval(2 + WorkoutHRGate.defaultMaxAge + 0.5)   // just past the window
        XCTAssertFalse(WorkoutHRGate.shouldRecord(
            liveHRAt: lockedAt, sessionStart: start,
            lastRecordedAt: nil, now: now))
    }

    // MARK: - The carry-in: a pre-workout resting lock must not seed the session

    func testRejectsAPreWorkoutLockCarriedIn() {
        // A resting "98" measured 30 s BEFORE the workout, still held in the latch at start.
        let preWorkoutLock = start.addingTimeInterval(-30)
        let now = start.addingTimeInterval(1)
        // Even though lastRecordedAt is nil (nothing recorded yet) and it's "recent", the
        // in-session floor rejects it — without this clause one stale sample leaks in.
        XCTAssertFalse(WorkoutHRGate.shouldRecord(
            liveHRAt: preWorkoutLock, sessionStart: start,
            lastRecordedAt: nil, now: now))
    }

    // MARK: - No lock at all

    func testRejectsWhenNoLockEverExisted() {
        XCTAssertFalse(WorkoutHRGate.shouldRecord(
            liveHRAt: nil, sessionStart: start,
            lastRecordedAt: nil, now: start.addingTimeInterval(5)))
    }

    // MARK: - A genuinely new lock after an earlier one IS recorded

    func testRecordsAnAdvancedLockAfterAPreviousOne() {
        let firstLock = start.addingTimeInterval(2)
        let secondLock = start.addingTimeInterval(4)   // a real new lock 2 s later
        XCTAssertTrue(WorkoutHRGate.shouldRecord(
            liveHRAt: secondLock, sessionStart: start,
            lastRecordedAt: firstLock, now: start.addingTimeInterval(4)))
    }

    // MARK: - Boundary: lock exactly at session start is in-session

    func testLockExactlyAtStartIsInSession() {
        XCTAssertTrue(WorkoutHRGate.shouldRecord(
            liveHRAt: start, sessionStart: start,
            lastRecordedAt: nil, now: start.addingTimeInterval(0.5)))
    }
}
