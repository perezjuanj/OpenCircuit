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

    /// INVARIANT 5: bounds always CONTAIN the recorded night ±3 h, never exceed the one-night caps,
    /// and clamp is idempotent + a no-op inside them.
    ///
    /// This used to pin the width at exactly `recorded + 6 h`. `strandedEditMargin` (2026-08-22)
    /// makes the width regime-dependent — a night long enough to fill `maxNightSpan` is unchanged,
    /// a truncated one widens — so a single number can no longer express it. Both regimes are
    /// asserted below with their exact expected edges, so the rule still cannot drift silently;
    /// what is gone is the false claim that one formula covers every night.
    func testBoundsWidthAndClampIdempotence() {
        for (o, wk) in [(0.0, 8.0), (-2.0, 5.0), (1.0, 1.5)] {
            let b = SleepEdit.bounds(recordedOnset: at(o), recordedWake: at(wk))
            let floorEarliest = at(o).addingTimeInterval(-SleepEdit.editMargin)
            let floorLatest = at(wk).addingTimeInterval(SleepEdit.editMargin)
            let span = SleepEdit.defaultMaxNightSpan

            XCTAssertLessThanOrEqual(b.earliest, floorEarliest, "the ±3 h parity floor is a FLOOR")
            XCTAssertGreaterThanOrEqual(b.latest, floorLatest, "the ±3 h parity floor is a FLOOR")
            // ⚠️ RE-BASELINED 2026-08-24. This used to assert "an edge may not pass one night-span
            // beyond the OPPOSITE floor". That coupling is exactly what cancelled the stranded
            // margin on any night spanning ≥ 8 h (see
            // `testAFullNightIsWidenedByTheStrandedMarginToo`). The bound that replaces it is each
            // edge's OWN anchor plus the stranded margin — a constant, so still no seesaw — while
            // `span` continues to clip `dataCoverage`, which is what it was really for.
            XCTAssertGreaterThanOrEqual(b.earliest,
                                        at(o).addingTimeInterval(-SleepEdit.strandedEditMargin),
                                        "no coverage was supplied, so nothing may reach past the "
                                        + "stranded margin on the edge's own anchor")
            // ⚠️ RE-BASELINED 2026-08-27. The late edge used to be pinned at `wake + 6 h` and
            // nothing else. That is the ceiling the 2026-08-27 report is about ("a limit on how late
            // I could set the wake up time" on a night reported as under 2 h): anchored solely on
            // `recordedWake`, it moved earlier by exactly the size of the truncation, so the sweep
            // case `(1, 1.5)` below — a 30-MINUTE recorded night — was pinned to a ceiling 6 h after
            // a wake that never happened. The late edge now also carries the truncation ceiling
            // `floorEarliest + maxNightSpan` (see `SleepEdit.bounds` and
            // `SleepEditTruncatedCeilingTests`), which binds only when the recorded span is under
            // 5 h. Both regimes keep an EXACT expected value below, so the rule still cannot drift.
            XCTAssertLessThanOrEqual(b.latest,
                                     max(at(wk).addingTimeInterval(SleepEdit.strandedEditMargin),
                                         floorEarliest.addingTimeInterval(span)),
                                     "no coverage was supplied, so the late edge may reach the "
                                     + "stranded margin or the truncation ceiling, and nothing more")

            // The exact rule, spelled out: the parity floor, widened by the stranded margin, and —
            // on the late edge only — by one plausible night after the parity bedtime.
            let wantEarliest = min(floorEarliest, at(o).addingTimeInterval(-SleepEdit.strandedEditMargin))
            let wantLatest = max(floorLatest,
                                 max(at(wk).addingTimeInterval(SleepEdit.strandedEditMargin),
                                     floorEarliest.addingTimeInterval(span)))
            XCTAssertEqual(b.earliest.timeIntervalSince1970, wantEarliest.timeIntervalSince1970,
                           accuracy: 0.1)
            XCTAssertEqual(b.latest.timeIntervalSince1970, wantLatest.timeIntervalSince1970,
                           accuracy: 0.1)

            for probe in [-10.0, -3.0, 0.0, 4.0, 20.0] {
                let once = SleepEdit.clamp(at(probe), to: b)
                XCTAssertEqual(SleepEdit.clamp(once, to: b), once, "clamp is not idempotent")
                XCTAssertGreaterThanOrEqual(once, b.earliest)
                XCTAssertLessThanOrEqual(once, b.latest)
            }
        }
    }

    /// ⚠️ RE-BASELINED 2026-08-24. This test used to assert the OPPOSITE — that a night already
    /// filling `maxNightSpan` is bit-identical to the pre-stranded-margin rule, because the margin
    /// was clipped by the opposite-floor caps and so "touched truncated nights only".
    ///
    /// That blast-radius bound was the DEFECT, not the guarantee. 🟢 Measured on the Gen 2
    /// (FR02.018) tester night of 2026-08-24: the clipped ceiling is
    /// `recordedWake + max(3 h, min(6 h, 11 h − recordedSpan))`, so any recorded span ≥ 8 h cancels
    /// the margin outright. Her night spanned 8 h 05 m 49 s and her wake picker stopped at 07:40:38,
    /// which is the report this was re-baselined for ("won't allow me to edit wake time").
    ///
    /// The old rule used the recorded SPAN as evidence that the recording had not been truncated.
    /// But a wearer only opens this editor when the recorded night is WRONG, and hers read 8 h only
    /// because staging had absorbed her evening — so the evidence was drawn from the very number
    /// being corrected, and the editor was tightest exactly where detection was worst.
    ///
    /// The margin is now granted on each edge's own anchor, after the caps. What the caps still
    /// clip is `dataCoverage` — see `testLateEdgeIsCappedAtOneNightSpan`, which still passes and is
    /// what stops an evening claim.
    func testAFullNightIsWidenedByTheStrandedMarginToo() {
        let b = SleepEdit.bounds(recordedOnset: at(0), recordedWake: at(8))
        XCTAssertEqual(b.earliest, at(-6), "onset − 6 h: the margin is no longer span-dependent")
        XCTAssertEqual(b.latest, at(14), "wake + 6 h: ditto")
        // The parity floor is still a FLOOR, not the rule.
        XCTAssertLessThanOrEqual(b.earliest, at(-3))
        XCTAssertGreaterThanOrEqual(b.latest, at(11))
    }

    /// INVARIANT 6: validate's accept/reject boundary is exactly `bounds`, swept rather than spot-
    /// checked so the limit cannot quietly drift.
    ///
    /// ⚠️ RE-BASELINED 2026-08-24 with `testAFullNightIsWidenedByTheStrandedMarginToo`: the boundary
    /// is the ±6 h stranded margin, not the ±3 h parity floor. The sweep is widened past it so the
    /// REJECT side is still exercised — a sweep that stopped at ±6 h would assert only accepts and
    /// go vacuous.
    func testValidateBoundaryProperty() {
        let onset = at(0), wake = at(8)
        let margin = SleepEdit.strandedEditMargin / 3600
        for deltaH in stride(from: -8.0, through: 8.0, by: 0.25) {
            let startEdit = SleepEdit.Window(inBedStart: at(deltaH), inBedEnd: wake)
            // `deltaH < 8` keeps the window non-degenerate: at Δ = +8 h the start reaches the fixed
            // end and `.endNotAfterStart` fires first, which is an ordering rule, not a bound.
            XCTAssertEqual(SleepEdit.isValid(startEdit, recordedOnset: onset, recordedWake: wake),
                           deltaH >= -margin && deltaH < 8.0,
                           "start-edge validity wrong at Δ=\(deltaH)h")
            let endEdit = SleepEdit.Window(inBedStart: onset, inBedEnd: at(8 + deltaH))
            XCTAssertEqual(SleepEdit.isValid(endEdit, recordedOnset: onset, recordedWake: wake),
                           deltaH <= margin && (8 + deltaH) > 0, "end-edge validity wrong at Δ=\(deltaH)h")
        }
    }

    /// 🟢 THE REPORTED NIGHT, end to end (Gen 2 FR02.018, `America/New_York`, 2026-08-24):
    /// "Went to bed at 3am 8/24/26 and won't allow me to edit wake time."
    ///
    /// Her staged night after the scoping fix is onset 20:34:49 → wake 05:55:14 — a recorded span of
    /// 9 h 20 m, i.e. comfortably past the 8 h cliff where the old arithmetic cancelled the margin.
    /// Under the old rule her ceiling was `wake + 3 h`; a 10:00 or 11:00 wake was refused with
    /// `.endAfterLatest` and Save stayed disabled with no way forward.
    func testTheReportedNightCanNowReachAPlausibleMorningWake() {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.date(from: DateComponents(year: 2026, month: 8, day: 23))!
        func t(_ h: Int, _ m: Int, _ s: Int = 0, plusDays: Int = 0) -> Date {
            cal.date(byAdding: .second, value: h * 3600 + m * 60 + s,
                     to: cal.date(byAdding: .day, value: plusDays, to: day)!)!
        }
        let onset = t(20, 34, 49)
        let wake = t(5, 55, 14, plusDays: 1)
        XCTAssertGreaterThan(wake.timeIntervalSince(onset), 8 * 3600,
                             "precondition: this night is past the cliff the old arithmetic had")

        let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake)
        XCTAssertGreaterThanOrEqual(b.latest, t(11, 0, 0, plusDays: 1),
                                    "her real morning wake must be reachable")
        // …and the corrected window validates end to end, with her 3am bedtime.
        let times = SleepEdit.Times(inBedStart: t(3, 0, 0, plusDays: 1),
                                    sleepOnset: t(3, 15, 0, plusDays: 1),
                                    sleepWake: t(11, 0, 0, plusDays: 1))
        XCTAssertNil(SleepEdit.validate(times, recordedOnset: onset, recordedWake: wake,
                                        minDuration: 30 * 60))
    }
}
