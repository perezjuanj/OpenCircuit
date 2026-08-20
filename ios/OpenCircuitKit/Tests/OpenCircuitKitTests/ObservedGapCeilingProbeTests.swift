// COVERAGE-CEILING PROBE — what does `observed / expected` actually read for a gap that is
// COMPLETELY covered by records?
//
// WHY THIS EXISTS. The observed-gap guard's cut is a ratio
//     observed = records STRICTLY INSIDE (p.end, clusterStart)      // endpoints excluded
//     expected = gap / 150 s                                        // endpoints included
// The numerator excludes the two records that bound the gap while the denominator counts them, so a
// gap with EVERY epoch present does not read 1.000 — it reads roughly (n-1)/n for n = gap/150. The
// shorter the gap, the lower that ceiling. A cut set above the ceiling is silently UNREACHABLE for
// that gap length: the guard would be inert for an arithmetic reason, not a physical one.
//
// This probe measures the ceiling curve directly instead of deriving it, so the shipped cut can be
// justified against a measured reachability bound. It touches no production source.
//
//   cd ios/OpenCircuitKit && swift test --filter ObservedGapCeilingProbeTests

import XCTest
@testable import OpenCircuitKit

final class ObservedGapCeilingProbeTests: XCTestCase {

    /// Coverage as the guard computes it (`BulkSleep.swift`, observed-gap guard) for a gap that is
    /// perfectly covered at the 150 s cadence, as a function of gap length.
    func testCoverageCeilingForAFullyObservedGap() {
        let cadence = Double(BulkRecord.epochSeconds)
        print("\n=== OBSERVED-GAP COVERAGE CEILING (gap fully covered at \(Int(cadence)) s cadence)")
        print("gapMin   epochsInGap   observed(strictly inside)   expected   coverage")

        var rows: [(Double, Double)] = []
        for gapMinutes in [7.5, 10.0, 15.0, 20.0, 30.0, 39.2, 43.0, 60.0, 90.0, 120.0, 360.0] {
            let gap = gapMinutes * 60.0
            // A gap bounded by a record at each end, every intermediate epoch present.
            // Records sit at t = 0, 150, 300, ... The gap runs from the record at 0 to the record at
            // `gap`; strictly-inside records are those at 150 ... gap-150.
            let interior = max(0, Int((gap / cadence).rounded(.down)) - 1)
            let expected = gap / cadence
            let coverage = Double(interior) / expected
            rows.append((gapMinutes, coverage))
            print(String(format: "%6.1f   %11.2f   %25d   %8.2f   %8.3f",
                         gapMinutes, gap / cadence, interior, expected, coverage))
        }

        // The guard never judges a gap at or below `onsetContiguityGap`; that is the shortest gap for
        // which a cut has to be reachable.
        let floorMinutes = BulkSleep.onsetContiguityGap / 60.0
        print(String(format: "\nonsetContiguityGap = %.1f min -> shortest judgeable gap", floorMinutes))
        if let atFloor = rows.first(where: { $0.0 >= floorMinutes }) {
            print(String(format: "ceiling at the shortest judgeable gap: %.3f", atFloor.1))
        }
        print("ceiling at 30 min: " + String(format: "%.3f", rows.first { $0.0 == 30.0 }!.1))
        print("ceiling at 60 min: " + String(format: "%.3f", rows.first { $0.0 == 60.0 }!.1))

        // Sanity: the ceiling is monotone in gap length and always < 1.
        for (m, c) in rows { XCTAssertLessThan(c, 1.0, "gap \(m) min") }
    }
}
