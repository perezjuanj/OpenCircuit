// COVERAGE-GEOMETRY PROBE — what does `observed / expected` actually read for a gap that is
// COMPLETELY covered by records?
//
// WHY THIS EXISTS. The observed-gap guard's cut is a ratio
//     observed = records STRICTLY INSIDE (p.end, clusterStart)      // endpoints excluded
//     expected = gap / 150 s                                        // endpoints included
// so the value a FULL gap reads is not 1.0 by construction — it depends on where the gap's two
// endpoints fall relative to the 150 s record grid. The endpoints are `ActivityPeriod` block
// boundaries, NOT record times, so they are generally off-grid.
//
// ⚠️ CORRECTION, and the reason this file is shaped the way it is. An earlier revision modelled the
// interior as `floor(L) - 1` and concluded that a fully observed gap "cannot reach 1.0", topping out
// at 0.930 for a 43-min gap. That model silently assumes BOTH endpoints sit on the grid. The corpus
// refutes it: `R3_2026-08-19`'s real 43.0-min bridge reads **0.988** with an unbroken 150 s cadence
// throughout. `floor(L) - 1` is the LOWER edge of the achievable band, not a ceiling. There is
// therefore NO reachability bound — every cut ≤ 1.0 is reachable at every gap length — and the
// shipped cut is justified by completeness semantics instead (see the constant's doc).
//
// What this probe DOES establish, and what the cut rests on, is the per-length **floor for a fully
// observed gap**: the smallest value a gap with every epoch present can read. A cut at or below that
// floor cannot distinguish "complete" from "one epoch short"; a cut above it demands completeness.
//
//   cd ios/OpenCircuitKit && swift test --filter ObservedGapCeilingProbeTests

import XCTest
@testable import OpenCircuitKit

final class ObservedGapCeilingProbeTests: XCTestCase {

    /// How many records at the 150 s cadence can fall STRICTLY inside a window of `gap` seconds,
    /// minimised and maximised over every sub-epoch alignment of the window's endpoints.
    private func achievableInterior(_ gap: Double) -> (min: Int, max: Int) {
        let cadence = Double(BulkRecord.epochSeconds)
        var lo = Int.max, hi = 0
        // Sweep the phase of the record grid relative to the gap's start, at 1 s resolution.
        for step in 0..<Int(cadence) {
            var count = 0
            var t = Double(step)
            while t < gap {
                if t > 0 { count += 1 }
                t += cadence
            }
            lo = min(lo, count); hi = max(hi, count)
        }
        return (lo, hi)
    }

    func testCoverageBandForAFullyObservedGap() {
        let cadence = Double(BulkRecord.epochSeconds)
        print("\n=== OBSERVED-GAP COVERAGE BAND (gap fully covered at \(Int(cadence)) s cadence)")
        print("gapMin        L   fullyObservedFloor   fullyObservedCeiling")

        var floors: [(Double, Double)] = []
        for gapMinutes in [7.5, 10.0, 15.0, 20.0, 30.0, 39.2, 43.0, 60.0, 90.0, 120.0, 360.0] {
            let gap = gapMinutes * 60.0
            let L = gap / cadence
            let band = achievableInterior(gap)
            let floor = Double(band.min) / L
            let ceiling = Double(band.max) / L
            floors.append((gapMinutes, floor))
            print(String(format: "%6.1f  %7.3f   %18.4f   %20.4f", gapMinutes, L, floor, ceiling))

            // THE REFUTATION, pinned: a fully observed gap CAN read 1.0 or more.
            XCTAssertGreaterThanOrEqual(ceiling, 1.0,
                                        "gap \(gapMinutes) min: a full gap must be able to read >= 1.0")
        }

        // The guard never judges a gap at or below `onsetContiguityGap`; that is the shortest gap for
        // which the cut has to mean something.
        let floorMinutes = BulkSleep.onsetContiguityGap / 60.0
        print(String(format: "\nonsetContiguityGap = %.1f min -> shortest judgeable gap", floorMinutes))
        for want in [7.5, 30.0, 60.0, 360.0] {
            print(String(format: "fully-observed floor at %5.1f min: %.4f",
                         want, floors.first { $0.0 == want }!.1))
        }

        // The floor is exactly (⌈L⌉ − 1)/L. ⚠️ It is NOT monotone in gap length: a gap whose L has a
        // fractional part has a HIGHER floor than the next whole L. Measured here: 43 min (L=17.2)
        // floors at 0.988 while 60 min (L=24) floors at 0.958. So the ratio does carry some
        // dependence on the fractional part of L, and a cut near the top of the band inherits it.
        // That is a real, accepted limitation of this discriminator — it is bounded (the spread over
        // any L ≥ 12 is under 0.05) and it is why the guard is a completeness test, not a fine
        // measurement.
        for (gapMinutes, floor) in floors {
            let L = gapMinutes * 60.0 / cadence
            XCTAssertEqual(floor, (L.rounded(.up) - 1) / L, accuracy: 1e-9,
                           "gap \(gapMinutes) min: floor must equal (ceil(L) - 1)/L")
        }
        // Over WHOLE gap lengths the floor does rise with length.
        let wholeL = floors.filter { ($0.0 * 60.0 / cadence).truncatingRemainder(dividingBy: 1) == 0 }
        for i in 1..<wholeL.count {
            XCTAssertGreaterThanOrEqual(wholeL[i].1, wholeL[i - 1].1 - 1e-9,
                                        "at whole L the floor must not fall as the gap lengthens")
        }
    }

    /// The shipped cut must sit ABOVE the fully-observed floor for the gap lengths the corpus
    /// actually produced (39–43 min) — otherwise it could not tell a complete gap from a holed one,
    /// which is the single discrimination it is asked to make.
    ///
    /// 🟢 The two corpus bridges, measured from the bytes:
    ///   R3_2026-08-19  gap 2580 s (L 17.200), 17 interior, all deltas 150 s   -> 0.988, COMPLETE
    ///   R3_2026-08-12  gap 2350 s (L 15.667), 14 interior, deltas incl 215/275 -> 0.894, HOLED
    func testShippedCutSeparatesTheTwoCorpusBridges() {
        let complete = 17.0 / (2580.0 / Double(BulkRecord.epochSeconds))   // R3_2026-08-19
        let holed    = 14.0 / (2350.0 / Double(BulkRecord.epochSeconds))   // R3_2026-08-12
        XCTAssertEqual(complete, 0.9884, accuracy: 0.0002)
        XCTAssertEqual(holed, 0.8936, accuracy: 0.0002)

        let cut = BulkSleep.observedGapAbsorbCoverageCut
        XCTAssertGreaterThan(cut, 0, "the guard ships ENABLED")
        XCTAssertGreaterThanOrEqual(complete, cut,
                                    "the complete gap must fire at the shipped cut")
        XCTAssertLessThan(holed, cut,
                          "the holed gap must be DECLINED at the shipped cut — a gap missing an "
                          + "epoch is a hole, which is exactly what the backward chain exists for")

        // And the complete gap really is complete: 0.988 is its own fully-observed floor.
        let L = 2580.0 / Double(BulkRecord.epochSeconds)
        XCTAssertEqual(complete, (L.rounded(.up) - 1) / L, accuracy: 1e-9)
    }
}
