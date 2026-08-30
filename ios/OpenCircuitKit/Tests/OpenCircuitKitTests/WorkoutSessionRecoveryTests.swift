// WorkoutSessionRecoveryTests.swift — pins the honesty invariants of crash-orphan workout recovery.
//
// SYNTHETIC by construction: these are pure date/decision invariants, not decoded ring bytes. The
// span they defend is the one the tester's 2026-08-29 report exposed — a ~55-minute evening walk
// that the app destroyed instead of saving.

import XCTest
@testable import OpenCircuitKit

final class WorkoutSessionRecoveryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    private func snapshot(start: Date, alive: Date,
                          hrSampleCount: Int = 12,
                          kcal: Double? = 210) -> WorkoutSessionSnapshot {
        WorkoutSessionSnapshot(sport: .walkingOutdoor, startDate: start, lastAliveAt: alive,
                               hrSampleCount: hrSampleCount, activeKcal: kcal,
                               avgHR: 104, maxHR: 131)
    }

    // MARK: - The load-bearing invariant

    /// THE rule: a recovered workout ends when the app last SAW the session, never at `now`. A
    /// process that died at 19:20 has no evidence the walk continued — stretching to `now` would
    /// fabricate duration and, through HealthKit, an activity credit.
    func testRecoveredEndIsTheLastObservedInstantNotNow() {
        let start = t0
        let lastAlive = t0.addingTimeInterval(55 * 60)
        let openedTheAppMuchLater = t0.addingTimeInterval(9 * 3600)

        guard case .offer(let recovered) = WorkoutSessionRecovery.decide(
            snapshot: snapshot(start: start, alive: lastAlive), now: openedTheAppMuchLater)
        else { return XCTFail("expected an offer") }

        XCTAssertEqual(recovered.end, lastAlive)
        XCTAssertEqual(recovered.durationSeconds, 55 * 60, accuracy: 0.001)
        XCTAssertNotEqual(recovered.end, openedTheAppMuchLater)
    }

    func testOfferCarriesTheSessionsOwnMeasurements() {
        guard case .offer(let recovered) = WorkoutSessionRecovery.decide(
            snapshot: snapshot(start: t0, alive: t0.addingTimeInterval(600)),
            now: t0.addingTimeInterval(3600))
        else { return XCTFail("expected an offer") }

        XCTAssertEqual(recovered.sport, .walkingOutdoor)
        XCTAssertEqual(recovered.start, t0)
        XCTAssertEqual(recovered.hrSampleCount, 12)
        XCTAssertEqual(recovered.activeKcal, 210)
        XCTAssertEqual(recovered.avgHR, 104)
        XCTAssertEqual(recovered.maxHR, 131)
    }

    /// No reading ever locked ⇒ no energy is carried. A recovered save must write nothing rather
    /// than an invented number (#45 honesty, carried through the crash path).
    func testNoCapturedHRCarriesNoEnergy() {
        guard case .offer(let recovered) = WorkoutSessionRecovery.decide(
            snapshot: snapshot(start: t0, alive: t0.addingTimeInterval(600),
                               hrSampleCount: 0, kcal: nil),
            now: t0.addingTimeInterval(3600))
        else { return XCTFail("expected an offer") }

        XCTAssertNil(recovered.activeKcal)
        XCTAssertEqual(recovered.hrSampleCount, 0)
    }

    // MARK: - Refusals

    func testNoSnapshotRecoversNothing() {
        XCTAssertEqual(WorkoutSessionRecovery.decide(snapshot: nil, now: t0), .nothingToRecover)
    }

    /// The session died before its first heartbeat: there is no observed span, so there is nothing
    /// to save and nothing worth interrupting the user about.
    func testSpanThatWasNeverObservedIsDiscarded() {
        XCTAssertEqual(
            WorkoutSessionRecovery.decide(snapshot: snapshot(start: t0, alive: t0),
                                          now: t0.addingTimeInterval(60)),
            .discard(.noObservedSpan))
        XCTAssertEqual(
            WorkoutSessionRecovery.decide(
                snapshot: snapshot(start: t0, alive: t0.addingTimeInterval(-1)),
                now: t0.addingTimeInterval(60)),
            .discard(.noObservedSpan))
    }

    /// A snapshot claiming the session was alive in the future (clock moved backwards, or a corrupt
    /// blob) is refused BEFORE it can reach Apple Health — the same plausibility discipline the
    /// sync cursor applies to samples.
    func testFutureDatedSnapshotIsRefused() {
        XCTAssertEqual(
            WorkoutSessionRecovery.decide(
                snapshot: snapshot(start: t0, alive: t0.addingTimeInterval(3600)),
                now: t0.addingTimeInterval(600)),
            .discard(.endsInTheFuture))
    }

    /// Boundary: a heartbeat landing exactly at `now` is fine — only strictly-future is refused.
    func testLastAliveExactlyNowIsStillOffered() {
        let alive = t0.addingTimeInterval(600)
        guard case .offer = WorkoutSessionRecovery.decide(
            snapshot: snapshot(start: t0, alive: alive), now: alive)
        else { return XCTFail("a heartbeat at `now` is not in the future") }
    }

    // MARK: - Persistence round-trip

    func testSnapshotRoundTripsThroughItsPersistedForm() {
        let original = snapshot(start: t0, alive: t0.addingTimeInterval(1234))
        let restored = WorkoutSessionSnapshot.decoded(from: original.encoded())
        XCTAssertEqual(restored, original)
    }

    /// A blob this build cannot read is treated as NO snapshot, never as a half-populated one — a
    /// partially-decoded session would be exactly the fabricated span the policy exists to refuse.
    func testUnreadableBlobIsTreatedAsAbsent() {
        XCTAssertNil(WorkoutSessionSnapshot.decoded(from: nil))
        XCTAssertNil(WorkoutSessionSnapshot.decoded(from: Data([0x00, 0x01, 0x02])))
        XCTAssertEqual(
            WorkoutSessionRecovery.decide(
                snapshot: WorkoutSessionSnapshot.decoded(from: Data("{}".utf8)), now: t0),
            .nothingToRecover)
    }
}
