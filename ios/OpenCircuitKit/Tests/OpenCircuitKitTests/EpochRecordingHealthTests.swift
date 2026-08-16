import XCTest
@testable import OpenCircuitKit

/// The stranded-sport-mode detector. Every case here is drawn from the proven 2026-08-16 incident
/// or from a benign shape that must NOT produce a warning.
final class EpochRecordingHealthTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_900_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: The failure this exists to catch

    /// The measured incident: the descriptor is seconds-fresh (keepalive is polling, temperature and
    /// battery are current) while the newest epoch is ~20 h old. That combination means the ring is
    /// powered, in range, answering — and writing nothing.
    func testConnectedRingWithNoEpochsForTwentyHoursIsStalled() {
        let s = EpochRecordingHealth.classify(newestEpochAt: ago(20 * 3600),
                                              newestDescriptorAt: ago(30),
                                              now: now)
        XCTAssertTrue(s.isStalled)
        XCTAssertEqual(s, .stalled(since: ago(20 * 3600)))
        XCTAssertEqual(EpochRecordingHealth.stalledHours(s, now: now), 20)
    }

    func testFiresOncePastTheThreshold() {
        let just = EpochRecordingHealth.classify(
            newestEpochAt: ago(EpochRecordingHealth.staleAfter + 1),
            newestDescriptorAt: ago(30), now: now)
        XCTAssertTrue(just.isStalled)
        let notYet = EpochRecordingHealth.classify(
            newestEpochAt: ago(EpochRecordingHealth.staleAfter - 60),
            newestDescriptorAt: ago(30), now: now)
        XCTAssertEqual(notYet, .recording)
    }

    /// Recovery: one fresh epoch after the stop command clears it immediately.
    func testResumesTheMomentAnEpochArrives() {
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: ago(120),
                                                     newestDescriptorAt: ago(10), now: now),
                       .recording)
    }

    // MARK: Benign shapes that must stay silent

    /// A ring in a drawer is the commonest reason for stale epochs and must never warn — the
    /// descriptor is the discriminator.
    func testRingLeftInADrawerIsNotStalled() {
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: ago(30 * 3600),
                                                     newestDescriptorAt: ago(29 * 3600), now: now),
                       .unknown)
    }

    /// A ring that reconnects after being away — descriptor fresh, epochs old, but the descriptor is
    /// NOT newer than the epoch by any meaningful margin because both stopped together (flat
    /// battery). It must not warn before a new epoch has had any chance to arrive.
    func testRingThatStoppedTalkingAndRecordingTogetherIsNotStalled() {
        let stopped = ago(20 * 3600)
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: stopped,
                                                     newestDescriptorAt: stopped.addingTimeInterval(-60),
                                                     now: now),
                       .unknown, "descriptor older than the epoch ⇒ no evidence of a live-but-silent ring")
    }

    /// A fresh install has no history; that is not a fault.
    func testMissingInputsAreUnknownNeverStalled() {
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: nil,
                                                     newestDescriptorAt: ago(10), now: now), .unknown)
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: ago(20 * 3600),
                                                     newestDescriptorAt: nil, now: now), .unknown)
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: nil,
                                                     newestDescriptorAt: nil, now: now), .unknown)
    }

    /// The threshold must clear a legitimately sparse drain cadence — notably the overnight quiet
    /// window, during which no drain runs at all by design.
    func testAnUndrainedOvernightGapDoesNotWarn() {
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: ago(2.5 * 3600),
                                                     newestDescriptorAt: ago(30), now: now),
                       .recording)
    }

    // MARK: Clock robustness

    func testFutureDatedInputsDoNotWarn() {
        // Ring clock ahead of the phone: neither a future epoch nor a future descriptor may be
        // treated as infinitely stale or infinitely fresh.
        XCTAssertEqual(EpochRecordingHealth.classify(newestEpochAt: now.addingTimeInterval(600),
                                                     newestDescriptorAt: ago(30), now: now),
                       .recording)
        let s = EpochRecordingHealth.classify(newestEpochAt: ago(20 * 3600),
                                              newestDescriptorAt: now.addingTimeInterval(600), now: now)
        XCTAssertTrue(s.isStalled, "a future-dated descriptor is still a present ring")
    }

    func testStalledHoursIsNilWhenRecording() {
        XCTAssertNil(EpochRecordingHealth.stalledHours(.recording, now: now))
        XCTAssertNil(EpochRecordingHealth.stalledHours(.unknown, now: now))
    }

    /// Never reads "0 hours" — the copy has to be sensible the moment it fires.
    func testStalledHoursNeverReadsZero() {
        let s = EpochRecordingHealth.Status.stalled(since: ago(EpochRecordingHealth.staleAfter))
        XCTAssertGreaterThanOrEqual(EpochRecordingHealth.stalledHours(s, now: now) ?? 0, 1)
    }
}
