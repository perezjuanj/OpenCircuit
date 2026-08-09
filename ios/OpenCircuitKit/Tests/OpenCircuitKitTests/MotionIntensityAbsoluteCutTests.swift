import XCTest
@testable import OpenCircuitKit

// #197 — the intensity-tail light/active seam must be an ABSOLUTE value, not a rank over whatever
// has drained.
//
// The defect these tests pin: both legacy seams (the 0.80 quantile and the Otsu split) are computed
// over `positive`, i.e. over the record set being staged. So the same epoch could be "still" in one
// sync and "movement" in the next, with no byte of physiology changed. 🟢 MEASURED on 2026-08-05:
// the cut moved 249 → 247 → 247 → 249 across consecutive 5-minute truncation cuts and swung the
// reported night 478 · 473 · 473 · 478.
//
// The central property is SET-INDEPENDENCE, and it is tested by construction: extend the record set
// and assert the verdict on the ORIGINAL epochs does not move. Each such test has a twin that pins
// the legacy behaviour, so the property can never pass vacuously.
final class MotionIntensityAbsoluteCutTests: XCTestCase {

    /// A worn, non-idle record whose `[15:20]` intensity tail sums to `tailSum`.
    private func rec(_ counter: UInt32, tailSum: Int) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = 55; b[5] = 50; b[8] = 0x62          // HR/HRV/SpO2 — a sleep-vitals epoch
        for k in 0..<5 { b[10 + k] = 1 }           // still primary channel
        var left = tailSum
        for k in 0..<5 {                            // spread the sum across [15:20]
            let take = min(left, 255)
            b[15 + k] = UInt8(take)
            left -= take
        }
        XCTAssertEqual(left, 0, "fixture cannot express a tail sum above 1275")
        return BulkRecord(b)!
    }

    private func records(_ sums: [Int]) -> [BulkRecord] {
        sums.enumerated().map { rec(UInt32(1_000_000 + $0 * BulkRecord.epochSeconds), tailSum: $1) }
    }

    /// Straddles the shipped cut: 344 below, 345 exactly on it, 346 above.
    private let base = [100, 200, 344, 345, 346, 500]

    // MARK: - The property: a verdict may not depend on what else is in the set

    func testAbsoluteCutIsIndependentOfWhatElseIsInTheSet() {
        let short = BulkSleep.motionIntensityFallbackMagnitudes(records(base), degenerate: false)
        // 20 large-movement epochs arrive on the next sync.
        let long = BulkSleep.motionIntensityFallbackMagnitudes(
            records(base + [Int](repeating: 1200, count: 20)), degenerate: false)
        XCTAssertEqual(Array(long.prefix(base.count)), short,
                       "the same epochs must keep the same verdict when more history drains in")
        XCTAssertEqual(short, [1, 1, 1, 16, 16, 16],
                       "seam is >= 345: 344 is still, 345 and above are movement")
    }

    /// THE TWIN. Without it the test above could pass for the wrong reason.
    func testTheLegacyRankIsNotIndependentOfTheSet() {
        let short = BulkSleep.motionIntensityFallbackMagnitudes(records(base), degenerate: false,
                                                                absoluteActiveCut: 0)
        let long = BulkSleep.motionIntensityFallbackMagnitudes(
            records(base + [Int](repeating: 1200, count: 20)), degenerate: false, absoluteActiveCut: 0)
        XCTAssertNotEqual(Array(long.prefix(base.count)), short,
                          "fixture sanity: the legacy p80 rank MUST move when the set grows — "
                          + "if this ever passes, the defect fixture stopped reproducing the defect")
    }

    func testAbsoluteCutIsIndependentOfTheSetOnTheDegenerateBranchToo() {
        let short = BulkSleep.motionIntensityFallbackMagnitudes(records(base), degenerate: true)
        let long = BulkSleep.motionIntensityFallbackMagnitudes(
            records(base + [Int](repeating: 1200, count: 20)), degenerate: true)
        XCTAssertEqual(Array(long.prefix(base.count)), short)
        XCTAssertEqual(short, [1, 1, 1, 16, 16, 16],
                       "the absolute seam replaces Otsu as well — #197 checked BOTH ranks")
    }

    func testTheLegacyOtsuSeamIsAlsoNotIndependentOfTheSet() {
        let short = BulkSleep.motionIntensityFallbackMagnitudes(records(base), degenerate: true,
                                                               absoluteActiveCut: 0)
        let long = BulkSleep.motionIntensityFallbackMagnitudes(
            records(base + [Int](repeating: 1200, count: 20)), degenerate: true, absoluteActiveCut: 0)
        XCTAssertNotEqual(Array(long.prefix(base.count)), short,
                          "fixture sanity: Otsu carries the same exposure the quantile does")
    }

    /// The property has to survive the layer the staging model actually calls.
    func testMotionMagnitudesForwardsTheSeam() {
        let recs = records(base)
        XCTAssertEqual(BulkSleep.motionMagnitudes(from: recs, absoluteActiveCut: 400),
                       BulkSleep.motionIntensityFallbackMagnitudes(recs, degenerate: false,
                                                                   absoluteActiveCut: 400),
                       "if this diverges, staging is not using the seam the tests pin")
    }

    // MARK: - The kill switch

    func testZeroRestoresTheLegacyQuantileExactly() {
        let sums = base
        let got = BulkSleep.motionIntensityFallbackMagnitudes(records(sums), degenerate: false,
                                                              absoluteActiveCut: 0)
        // p80 of [100,200,344,345,346,500] is index round(5*0.8) = 4 → 346.
        let expected = sums.map { $0 == 0 ? Float(0) : ($0 >= 346 ? 16 : 1) }
        XCTAssertEqual(got, expected, "0 must reproduce the pre-#197 rank byte for byte")
    }

    func testZeroRestoresTheLegacyOtsuSeamExactly() {
        let sums = base
        let positive = sums.filter { $0 > 0 }.sorted()
        let otsu = BulkSleep.otsuIntensityCut(positive)
        let got = BulkSleep.motionIntensityFallbackMagnitudes(records(sums), degenerate: true,
                                                              absoluteActiveCut: 0)
        XCTAssertEqual(got, sums.map { $0 >= otsu ? Float(16) : Float(1) })
    }

    // MARK: - Invariants that must hold whichever seam is in force

    func testAZeroTailIsAlwaysZeroMovement() {
        // The ring's OWN "nothing moved" verdict outranks any seam.
        for cut in [0, 345, 1_000_000] {
            let m = BulkSleep.motionIntensityFallbackMagnitudes(records([0, 0, 500, 0]),
                                                                degenerate: false,
                                                                absoluteActiveCut: cut)
            XCTAssertEqual(m[0], 0); XCTAssertEqual(m[1], 0); XCTAssertEqual(m[3], 0)
        }
    }

    func testAnAllZeroTailProducesNoMovementAtAll() {
        XCTAssertEqual(BulkSleep.motionIntensityFallbackMagnitudes(records([0, 0, 0]),
                                                                   degenerate: false),
                       [0, 0, 0])
    }

    /// Values must keep straddling the thresholds the rest of the pipeline is calibrated to:
    /// `motionStillThreshold == 2` and `awakeMotion == 15`.
    func testEmittedMagnitudesStraddleTheDownstreamThresholds() {
        let m = BulkSleep.motionIntensityFallbackMagnitudes(records([100, 500]), degenerate: false)
        XCTAssertLessThan(m[0], ActivityPeriod.motionStillThreshold, "still must read below the still bar")
        XCTAssertGreaterThan(Int(m[1]), SleepStaging.Tuning.default.awakeMotion, "active must clear awakeMotion")
    }

    // MARK: - The constant itself

    /// 345 is the MEDIAN per-night legacy cut over the corpus (16 night-staging sources → 344.5;
    /// the primary user's own ring, n = 11 → 343). Its whole justification is that it preserves the
    /// operating point the surrounding calibrations were fitted to, so it must stay inside the band
    /// the per-night ranks actually occupied: 262 … 474.
    func testDefaultSeamSitsInsideTheMeasuredCorpusBand() {
        XCTAssertGreaterThanOrEqual(BulkSleep.motionIntensityActiveCut, 262)
        XCTAssertLessThanOrEqual(BulkSleep.motionIntensityActiveCut, 474)
    }

    func testDefaultSeamIsEnabled() {
        XCTAssertGreaterThan(BulkSleep.motionIntensityActiveCut, 0,
                             "0 is the revert; shipping it disables the #197 fix")
    }
}
