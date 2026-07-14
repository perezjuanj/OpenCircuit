import XCTest
@testable import OpenCircuitKit

/// IMPLEMENTATION-AGNOSTIC invariants for the manual sleep-edit engine (#176). Where the sibling
/// SleepEditTests pins specific cases, these lock GENERAL guarantees that must hold for any correct
/// `recompute`/`bounds`/`validate` — so they survive internal reworks and adversarially guard the two
/// properties the review flagged as safety-critical: recompute never escapes the edited window, and
/// it never fabricates asleep time beyond that window. Fixed anchor, no wall-clock.
final class SleepEditInvariantTests: XCTestCase {

    private let ref = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ h: Double) -> Date { ref.addingTimeInterval(h * 3600) }
    private func seg(_ a: Double, _ b: Double, _ s: SleepStage) -> SleepSegment {
        SleepSegment(start: at(a), end: at(b), stage: s)
    }
    private func asleepSeconds(_ segs: [SleepSegment]) -> TimeInterval {
        segs.filter { $0.stage != .awake && $0.stage != .inBed }.reduce(0) { $0 + $1.duration }
    }

    /// A spread of well-formed (non-overlapping) base nights + a spread of windows around them.
    private var bases: [[SleepSegment]] {
        [
            [],                                                        // no recording
            [seg(0, 8, .asleepCore)],                                  // single block
            [seg(0, 8, .inBed), seg(0, 8, .asleepCore)],              // two-layer staged night
            [seg(0, 3, .asleepCore), seg(5, 8, .asleepDeep)],          // interior awake gap 3–5
            [seg(1, 2.5, .asleepCore), seg(2.5, 4, .asleepDeep), seg(4, 6.5, .asleepREM)],
        ]
    }
    private var windows: [SleepEdit.Window] {
        [-1, -0.5, 0, 0.5, 1, 3.5, 4].flatMap { start -> [SleepEdit.Window] in
            [7, 8, 9, 9.5, 6, 4.5].map { end in SleepEdit.Window(inBedStart: at(start), inBedEnd: at(end)) }
        }
    }

    /// INVARIANT 1: every recomputed segment lies within the edited window — the edit can never write
    /// sleep outside the bedtime/wake the user chose.
    func testRecomputeNeverEscapesTheWindow() {
        for base in bases {
            for w in windows where w.inBedEnd > w.inBedStart {
                for s in SleepEdit.recompute(baseSegments: base, window: w) {
                    XCTAssertGreaterThanOrEqual(s.start, w.inBedStart, "segment starts before the window")
                    XCTAssertLessThanOrEqual(s.end, w.inBedEnd, "segment ends after the window")
                    XCTAssertGreaterThan(s.end, s.start, "degenerate segment emitted")
                }
            }
        }
    }

    /// INVARIANT 2: recompute never credits MORE asleep time than the window is long — no fabrication
    /// beyond the chosen window, even when extension-filling a truncated night.
    func testRecomputeNeverFabricatesAsleepBeyondWindow() {
        for base in bases {
            for w in windows where w.inBedEnd > w.inBedStart {
                let out = SleepEdit.recompute(baseSegments: base, window: w)
                XCTAssertLessThanOrEqual(asleepSeconds(out), w.duration + 0.001,
                                         "asleep exceeds the edited window length")
            }
        }
    }

    /// INVARIANT 3: a window that sits wholly inside an INTERIOR recording gap invents nothing — a real
    /// mid-night awake gap must never become synthetic sleep.
    func testWindowInsideInteriorGapInventsNothing() {
        let base = [seg(0, 3, .asleepCore), seg(5, 8, .asleepDeep)]   // gap 3–5
        let out = SleepEdit.recompute(baseSegments: base,
                                      window: .init(inBedStart: at(3.4), inBedEnd: at(4.6)))
        XCTAssertEqual(asleepSeconds(out), 0, "the 3–5 h awake gap was back-filled as sleep")
    }

    /// INVARIANT 4: a degenerate window (end ≤ start) yields nothing.
    func testDegenerateWindowIsEmpty() {
        XCTAssertTrue(SleepEdit.recompute(baseSegments: [seg(0, 8, .asleepCore)],
                                          window: .init(inBedStart: at(5), inBedEnd: at(5))).isEmpty)
        XCTAssertTrue(SleepEdit.recompute(baseSegments: [seg(0, 8, .asleepCore)],
                                          window: .init(inBedStart: at(6), inBedEnd: at(5))).isEmpty)
    }

    /// INVARIANT 5: bounds always span exactly the recorded (onset→wake) plus 6 h (±3 h), and clamp is
    /// idempotent + a no-op inside the bounds.
    func testBoundsWidthAndClampIdempotence() {
        for (o, wk) in [(0.0, 8.0), (-2.0, 5.0), (1.0, 1.5)] {
            let b = SleepEdit.bounds(recordedOnset: at(o), recordedWake: at(wk))
            XCTAssertEqual(b.latest.timeIntervalSince(b.earliest), (wk - o) * 3600 + 6 * 3600, accuracy: 0.1)
            for probe in [-10.0, -3.0, 0.0, 4.0, 20.0] {
                let once = SleepEdit.clamp(at(probe), to: b)
                XCTAssertEqual(SleepEdit.clamp(once, to: b), once, "clamp is not idempotent")
                XCTAssertGreaterThanOrEqual(once, b.earliest)
                XCTAssertLessThanOrEqual(once, b.latest)
            }
        }
    }

    /// INVARIANT 6: validate's accept/reject boundary is exactly the ±3 h rule — a property sweep, not
    /// a single case, so the limit can't quietly drift.
    func testValidateBoundaryProperty() {
        let onset = at(0), wake = at(8)
        // Start edge: allowed iff ≥ onset−3h; end edge: allowed iff ≤ wake+3h (with the other edge fixed inside).
        for deltaH in stride(from: -4.0, through: 4.0, by: 0.25) {
            let startEdit = SleepEdit.Window(inBedStart: at(deltaH), inBedEnd: wake)
            XCTAssertEqual(SleepEdit.isValid(startEdit, recordedOnset: onset, recordedWake: wake),
                           deltaH >= -3.0, "start-edge validity wrong at Δ=\(deltaH)h")
            let endEdit = SleepEdit.Window(inBedStart: onset, inBedEnd: at(8 + deltaH))
            XCTAssertEqual(SleepEdit.isValid(endEdit, recordedOnset: onset, recordedWake: wake),
                           deltaH <= 3.0 && (8 + deltaH) > 0, "end-edge validity wrong at Δ=\(deltaH)h")
        }
    }
}
