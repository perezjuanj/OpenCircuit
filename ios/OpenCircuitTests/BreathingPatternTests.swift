import XCTest
@testable import OpenCircuit

final class BreathingPatternTests: XCTestCase {
    func testBoxBoundariesAreExact() {
        let box = BreathingPattern.box
        XCTAssertEqual(box.position(at: 0).kind, .inhale)
        XCTAssertEqual(box.position(at: 3.99).kind, .inhale)
        XCTAssertEqual(box.position(at: 4.0).kind, .holdFull)
        XCTAssertEqual(box.position(at: 7.99).kind, .holdFull)
        XCTAssertEqual(box.position(at: 8.0).kind, .exhale)
        XCTAssertEqual(box.position(at: 12.0).kind, .holdEmpty)
        XCTAssertEqual(box.position(at: 15.99).kind, .holdEmpty)
        XCTAssertEqual(box.cycleDuration, 16)
    }

    func testBoxWrapsToNextCycle() {
        let p = BreathingPattern.box.position(at: 16.0)
        XCTAssertEqual(p.kind, .inhale)
        XCTAssertEqual(p.cycle, 1)
        XCTAssertEqual(p.progress, 0, accuracy: 1e-9)
        XCTAssertEqual(BreathingPattern.box.position(at: 34.5).cycle, 2)
        XCTAssertEqual(BreathingPattern.box.position(at: 34.5).kind, .inhale)
    }

    func testFourSevenEightCycleIs19Seconds() {
        let p = BreathingPattern.fourSevenEight
        XCTAssertEqual(p.cycleDuration, 19)
        XCTAssertEqual(p.phases.map(\.kind), [.inhale, .holdFull, .exhale])
        XCTAssertEqual(p.position(at: 3.99).kind, .inhale)
        XCTAssertEqual(p.position(at: 4).kind, .holdFull)
        XCTAssertEqual(p.position(at: 10.99).kind, .holdFull)
        XCTAssertEqual(p.position(at: 11).kind, .exhale)
        XCTAssertEqual(p.position(at: 18.99).kind, .exhale)
        XCTAssertEqual(p.position(at: 19).kind, .inhale)
        XCTAssertEqual(p.position(at: 19).cycle, 1)
    }

    func testCoherentIsFivePointFiveInAndOut() {
        let p = BreathingPattern.coherent
        XCTAssertEqual(p.cycleDuration, 11)
        XCTAssertEqual(p.position(at: 5.49).kind, .inhale)
        XCTAssertEqual(p.position(at: 5.5).kind, .exhale)
        XCTAssertEqual(p.position(at: 11).kind, .inhale)
    }

    func testProgressRemainingAndCountdown() {
        let p = BreathingPattern.box.position(at: 1)
        XCTAssertEqual(p.progress, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.remaining, 3, accuracy: 1e-9)
        XCTAssertEqual(p.countdown, 3)
        XCTAssertEqual(BreathingPattern.box.position(at: 3.99).countdown, 1)   // never 0 while running
        XCTAssertEqual(BreathingPattern.box.position(at: 0).countdown, 4)
    }

    func testFullnessGrowsHoldsAndShrinks() {
        let box = BreathingPattern.box
        XCTAssertEqual(box.position(at: 0).fullness, 0, accuracy: 1e-9)
        XCTAssertEqual(box.position(at: 2).fullness, 0.5, accuracy: 1e-9)
        XCTAssertEqual(box.position(at: 5).fullness, 1)
        XCTAssertEqual(box.position(at: 10).fullness, 0.5, accuracy: 1e-9)
        XCTAssertEqual(box.position(at: 13).fullness, 0)
    }

    func testPhaseIDChangesExactlyAtBoundaries() {
        let box = BreathingPattern.box
        XCTAssertEqual(box.position(at: 3.99).phaseID, box.position(at: 0).phaseID)
        XCTAssertNotEqual(box.position(at: 4).phaseID, box.position(at: 3.99).phaseID)
        XCTAssertNotEqual(box.position(at: 16).phaseID, box.position(at: 15.99).phaseID)
    }

    func testNegativeTimeClampsToStart() {
        XCTAssertEqual(BreathingPattern.box.position(at: -3).kind, .inhale)
    }

    func testSessionEndsAtChosenLength() {
        for length in BreathingLength.allCases {
            XCTAssertFalse(length.isFinished(at: length.seconds - 0.01))
            XCTAssertTrue(length.isFinished(at: length.seconds))
        }
        XCTAssertEqual(BreathingLength.allCases.map(\.seconds), [60, 180, 300])
        XCTAssertEqual(BreathingLength.from(seconds: 123), .three)
    }

    func testUnknownPatternIDFallsBackToBox() {
        XCTAssertEqual(BreathingPattern.pattern(id: "nope"), .box)
        XCTAssertEqual(BreathingPattern.pattern(id: "478"), .fourSevenEight)
    }

    func testHeartRateSummaryTracksStartEndLowest() {
        var s = BreathingHeartRateSummary()
        XCTAssertFalse(s.hasReadings)
        s.record(0)
        XCTAssertFalse(s.hasReadings)
        s.record(72); s.record(65); s.record(68)
        XCTAssertEqual(s.start, 72)
        XCTAssertEqual(s.end, 68)
        XCTAssertEqual(s.lowest, 65)
    }
}
