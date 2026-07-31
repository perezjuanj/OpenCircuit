import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the robust (median / MAD) personal baseline behind the overnight
/// signals index (#183, Phase 2). Every vector is hand-constructed with a known median, MAD and
/// expected z — never a real health value, and never a value copied from a capture.
///
/// These prove CORRECTNESS, not skill: they show the arithmetic does what `RobustBaseline.swift`
/// claims, and nothing more. No assertion here says the index predicts anything.
final class RobustBaselineTests: XCTestCase {

    // MARK: Median

    func testMedianOddAndEvenCounts() {
        XCTAssertNil(RobustBaseline.median([]))
        XCTAssertEqual(RobustBaseline.median([5])!, 5, accuracy: 1e-9)
        // Odd count, deliberately unsorted input → the middle value after sorting.
        XCTAssertEqual(RobustBaseline.median([9, 1, 5, 3, 7])!, 5, accuracy: 1e-9)
        // Even count → the mean of the two central values: (5 + 7) / 2.
        XCTAssertEqual(RobustBaseline.median([9, 1, 5, 3, 7, 11])!, 6, accuracy: 1e-9)
    }

    func testMADOnHandComputedVectors() {
        // Odd: sorted [50,50,50,60,70,70,70] → median 60; |dev| = [10,10,10,0,10,10,10] → MAD 10.
        let odd = RobustBaseline.stats([50, 50, 50, 60, 70, 70, 70])
        XCTAssertEqual(odd!.median, 60, accuracy: 1e-9)
        XCTAssertEqual(odd!.mad, 10, accuracy: 1e-9)
        XCTAssertEqual(odd!.n, 7)

        // Even: sorted [10,20,30,40,52,60,70,80] → median (40+52)/2 = 46;
        // |dev| sorted = [6,6,14,16,24,26,34,36] → MAD (16+24)/2 = 20.
        let even = RobustBaseline.stats([10, 20, 30, 40, 52, 60, 70, 80])
        XCTAssertEqual(even!.median, 46, accuracy: 1e-9)
        XCTAssertEqual(even!.mad, 20, accuracy: 1e-9)
        XCTAssertEqual(even!.n, 8)
    }

    // MARK: The consistency constant

    /// The 1.4826 Gaussian consistency constant must actually reach the divisor. Without it every
    /// threshold copied from the vitals engine (which is on an SD scale) would silently mean
    /// something else — see the file header's provenance note.
    func testConsistencyConstantIsAppliedInZ() {
        let stats = RobustBaseline.stats([50, 50, 50, 60, 70, 70, 70])!   // median 60, MAD 10
        let scale = RobustBaseline.madConsistency * stats.mad             // 14.826, well above the 5 floor

        // One scaled MAD-unit above the median is exactly z = 1.
        XCTAssertEqual(RobustBaseline.z(today: 60 + scale, stats: stats, noiseFloor: 5),
                       1, accuracy: 1e-9)
        XCTAssertEqual(RobustBaseline.z(today: 60 + 2 * scale, stats: stats, noiseFloor: 5),
                       2, accuracy: 1e-9)
        // Falsifier: had the constant been dropped, the same input would read 1.4826.
        XCTAssertNotEqual(RobustBaseline.z(today: 60 + scale, stats: stats, noiseFloor: 5),
                          (60 + scale - 60) / stats.mad, accuracy: 1e-6)
        XCTAssertEqual(RobustBaseline.madConsistency, 1.4826, accuracy: 1e-12)
    }

    // MARK: Noise-floor clamping

    /// A perfectly regular person has MAD == 0. The floor is applied to the SCALE, so the result is
    /// a small finite number rather than an infinity or a NaN.
    func testZeroMADDoesNotExplodeToInfinity() {
        let stats = RobustBaseline.stats(Array(repeating: 60.0, count: 7))!
        XCTAssertEqual(stats.mad, 0, accuracy: 1e-9)

        let small = RobustBaseline.z(today: 62, stats: stats, noiseFloor: 5)
        XCTAssertTrue(small.isFinite)
        XCTAssertEqual(small, 0.4, accuracy: 1e-9)     // 2 bpm against a 5 bpm floor

        // A genuinely large change still saturates at the clamp rather than running away.
        let big = RobustBaseline.z(today: 100, stats: stats, noiseFloor: 5)
        XCTAssertTrue(big.isFinite)
        XCTAssertEqual(big, RobustBaseline.zClamp, accuracy: 1e-9)
        XCTAssertEqual(RobustBaseline.z(today: 20, stats: stats, noiseFloor: 5),
                       -RobustBaseline.zClamp, accuracy: 1e-9)
    }

    /// A baseline tighter than the noise floor must not turn a 1-bpm wobble into a big z.
    func testSubFloorWobbleYieldsSmallZ() {
        // MAD 0.1 → 1.4826 · 0.1 = 0.148, far below the 5 bpm floor, so the floor is the scale.
        let stats = RobustBaseline.stats([59.9, 60.0, 60.1, 60.0, 59.9, 60.1, 60.0])!
        XCTAssertEqual(stats.median, 60, accuracy: 1e-9)
        XCTAssertEqual(stats.mad, 0.1, accuracy: 1e-9)

        let z = RobustBaseline.z(today: 61, stats: stats, noiseFloor: 5)
        XCTAssertEqual(z, 0.2, accuracy: 1e-9)
        // Unfloored this would be 1 / 0.14826 ≈ 6.7 and would clamp at 4 — a 1 bpm wobble
        // presented as a maximal deviation.
        XCTAssertLessThan(z, 1, "must stay below HeadacheSignals.Tuning().onsetZ, i.e. contribute 0")
    }

    // MARK: Window selection

    func testNilBelowMinBaselineDays() {
        XCTAssertNil(RobustBaseline.stats(Array(repeating: 60.0, count: 6)))
        let s = RobustBaseline.stats(Array(repeating: 60.0, count: 7))
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.n, 7)
        XCTAssertEqual(s!.median, 60, accuracy: 1e-9)
        // Degenerate arguments are refused rather than producing a nonsense estimate.
        XCTAssertNil(RobustBaseline.stats(Array(repeating: 60.0, count: 30), minDays: 0))
        XCTAssertNil(RobustBaseline.stats(Array(repeating: 60.0, count: 30), minDays: 5, maxDays: 3))
    }

    /// `prior` is oldest → newest, so an over-long series must keep the NEWEST window. Keeping the
    /// oldest would score today against a baseline the person has already moved away from.
    func testTrailingWindowKeepsNewestValues() {
        let prior = (1...80).map(Double.init)             // oldest 1 … newest 80
        let s = RobustBaseline.stats(prior)!
        XCTAssertEqual(s.n, RobustBaseline.maxBaselineDays)
        XCTAssertEqual(s.median, 50.5, accuracy: 1e-9, "median of 21…80, the newest 60")
        XCTAssertNotEqual(s.median, 40.5, accuracy: 1e-9, "40.5 = whole series, i.e. no window at all")
        XCTAssertNotEqual(s.median, 30.5, accuracy: 1e-9, "30.5 = the OLDEST 60, i.e. prefix not suffix")
    }

    // MARK: Circular clock arithmetic

    /// Bedtime wraps. The plain median of 23:50 and 00:10 is midday, which would make a perfectly
    /// regular sleeper look maximally irregular.
    func testCircularMedianAcrossMidnight() {
        let tenToMidnight = 23 * 60 + 50      // 1430
        let tenPast = 10

        XCTAssertEqual(RobustBaseline.circularMedianMinutes([tenToMidnight, tenPast, 0]), 0)
        // The even-count case is where the plain median is catastrophically wrong: (1430+10)/2 = 720.
        XCTAssertEqual(RobustBaseline.circularMedianMinutes([tenToMidnight, tenPast]), 0)

        // A non-wrapping cluster still behaves like an ordinary median.
        XCTAssertEqual(RobustBaseline.circularMedianMinutes([1380, 1400, 1420]), 1400)

        XCTAssertEqual(RobustBaseline.circularMedianMinutes([500]), 500)
        XCTAssertNil(RobustBaseline.circularMedianMinutes([]))

        // Out-of-range minutes are normalised into 0…1439 rather than rejected.
        XCTAssertEqual(RobustBaseline.circularMedianMinutes([1440 + 30]), 30)
        XCTAssertEqual(RobustBaseline.circularMedianMinutes([-10]), 1430)
    }

    func testCircularDeltaWraps() {
        XCTAssertEqual(RobustBaseline.circularDeltaMinutes(23 * 60 + 50, 10), 20)
        XCTAssertEqual(RobustBaseline.circularDeltaMinutes(10, 23 * 60 + 50), 20, "symmetric")
        XCTAssertEqual(RobustBaseline.circularDeltaMinutes(0, 0), 0)
        XCTAssertEqual(RobustBaseline.circularDeltaMinutes(0, 800), 640, "the short way round")
        XCTAssertEqual(RobustBaseline.circularDeltaMinutes(0, 720), 720, "the antipode is the maximum")
    }

    // MARK: Why median/MAD and not mean/SD — made falsifiable

    /// The documented artifact night — a cold object held while asleep, read as 86 °F ≈ 30 °C
    /// (`SkinTempBaseline.swift:35-44`, and `SkinTempBaselineTests.testArtifactNightAlerts…`) —
    /// dropped into an otherwise steady series.
    ///
    /// The claim in `RobustBaseline.swift:11-15` is that median/MAD survives it and mean/SD does
    /// not. This test computes BOTH baselines on the same two vectors so the claim can fail: the
    /// robust baseline must move by less than one skin-temp noise floor (0.3 °C), and the shipped
    /// mean/SD engine must move by more.
    func testArtifactDayShiftsBaselineLessThanOneNoiseFloor() {
        let floor = HeadacheSignals.Feature.skinTempDeviation.noiseFloor      // 0.3 °C
        let steady: [Double] = [34.3, 34.4, 34.5, 34.4, 34.3, 34.5, 34.4, 34.4, 34.5]
        let artifactC = 30.0                                                  // ≈ 86 °F
        let contaminated = [artifactC] + steady

        let clean = RobustBaseline.stats(steady)!
        let dirty = RobustBaseline.stats(contaminated)!
        let medianShift = abs(dirty.median - clean.median)
        let madShift = abs(dirty.mad - clean.mad)

        XCTAssertLessThan(medianShift, floor, "one artifact night must not move the robust centre")
        XCTAssertLessThan(madShift, floor, "…nor the robust scale")

        // The alternative, computed with the SHIPPED mean/SD engine on the same two vectors.
        let cleanSD = VitalsBaseline.stats(steady)!
        let dirtySD = VitalsBaseline.stats(contaminated)!
        let meanShift = abs(dirtySD.mean - cleanSD.mean)

        XCTAssertGreaterThan(meanShift, medianShift, "the mean must move MORE — this is the whole argument")
        XCTAssertGreaterThan(meanShift, floor, "and it moves by more than a whole noise floor")
        XCTAssertGreaterThan(dirtySD.sd, 10 * cleanSD.sd, "one outlier inflates the SD by an order of magnitude")

        // The consequence that matters: after the artifact, the mean/SD scale has swollen so far
        // that a genuinely deviant night is MASKED, while the robust scale still sees it.
        let deviantNight = clean.median + 0.6
        let robustZ = RobustBaseline.z(today: deviantNight, stats: dirty, noiseFloor: floor)
        let sdZ = (deviantNight - dirtySD.mean) / dirtySD.sd
        XCTAssertEqual(robustZ, 2.0, accuracy: 1e-9)
        XCTAssertLessThan(sdZ, 1.0)
        XCTAssertGreaterThan(robustZ, 2 * sdZ)
    }
}
