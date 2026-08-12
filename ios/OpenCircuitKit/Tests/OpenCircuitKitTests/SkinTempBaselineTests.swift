import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the sleeping skin-temp baseline + nightly deviation (#69).
/// No real health values — controlled inputs with a known expected baseline/offset/band.
final class SkinTempBaselineTests: XCTestCase {

    private func night(_ daysAgo: Int, _ c: Double) -> SkinTempBaseline.NightlyTemp {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return SkinTempBaseline.NightlyTemp(night: day, celsius: c)
    }

    /// The arithmetic, exercised with the coverage gate opened (`minSamples: 1`) so this test keeps
    /// asserting what it always asserted: the mean itself. The gate has its own tests below.
    func testNightlyMean() {
        XCTAssertNil(SkinTempBaseline.nightlyMean([], minSamples: 1))
        XCTAssertEqual(SkinTempBaseline.nightlyMean([30, 31, 32], minSamples: 1)!, 31, accuracy: 1e-9)
    }

    func testNightlyMeanWindowed() {
        let base = Date()
        let samples = [
            TemperatureSample(time: base, celsius: 30),
            TemperatureSample(time: base.addingTimeInterval(60), celsius: 32),
            TemperatureSample(time: base.addingTimeInterval(10_000), celsius: 99),  // outside window
        ]
        let window = DateInterval(start: base, end: base.addingTimeInterval(120))
        XCTAssertEqual(SkinTempBaseline.nightlyMean(samples: samples, in: window, minSamples: 1)!,
                       31, accuracy: 1e-9)
    }

    // MARK: Coverage gate — a barely-connected night is not comparable to a well-covered one

    func testNightlyMeanRejectsAThinlyCoveredNight() {
        // Three readings is what a night with one short connected stretch produces. Sleeping skin
        // temp follows a circadian curve, so three samples from one corner of it are not a night.
        XCTAssertNil(SkinTempBaseline.nightlyMean([30, 31, 32]),
                     "below minNightlySamples → no nightly value at all")
        XCTAssertNil(SkinTempBaseline.nightlyMean(
            Array(repeating: 31.0, count: SkinTempBaseline.minNightlySamples - 1)))
    }

    func testNightlyMeanAcceptsAtTheCoverageFloor() {
        let n = SkinTempBaseline.minNightlySamples
        let values = Array(repeating: 31.0, count: n)
        XCTAssertEqual(SkinTempBaseline.nightlyMean(values)!, 31, accuracy: 1e-9)
    }

    func testWindowedCoverageCountsOnlyInWindowSamples() {
        // Enough samples overall, but only two land inside the sleep window → still nil. The gate
        // must judge the night, not the array it was sliced from.
        let base = Date()
        let inWindow = (0 ..< 2).map {
            TemperatureSample(time: base.addingTimeInterval(Double($0) * 60), celsius: 31)
        }
        let outside = (0 ..< 20).map {
            TemperatureSample(time: base.addingTimeInterval(10_000 + Double($0) * 60), celsius: 31)
        }
        let window = DateInterval(start: base, end: base.addingTimeInterval(300))
        XCTAssertNil(SkinTempBaseline.nightlyMean(samples: inWindow + outside, in: window))
    }

    // MARK: The gate that actually matters — coverage of the night's curve

    private func night(hours: Double = 10) -> DateInterval {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return DateInterval(start: start, duration: hours * 3600)
    }

    /// A well-connected night: the real cadence measured off a tester's descriptor frames is ~1
    /// reading per 68 s, giving 47–69 per hour in every hour of a 10 h window. It must pass with a
    /// wide margin — the gate exists to reject broken nights, not normal ones.
    func testAWellConnectedNightPasses() {
        let w = night()
        let samples = stride(from: 0.0, to: w.duration, by: 68).map {
            TemperatureSample(time: w.start.addingTimeInterval($0), celsius: 35.5)
        }
        XCTAssertGreaterThan(samples.count, 500)
        XCTAssertEqual(SkinTempBaseline.coverage(samples: samples, in: w), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SkinTempBaseline.nightlyMean(samples: samples, in: w,
                       minCoverage: SkinTempBaseline.candidateNightlyCoverage)!, 35.5, accuracy: 1e-9)
    }

    /// The REPORTED case, and the one a count floor cannot catch: the link held for two hours of
    /// ten. Hundreds of readings — far past any sane count floor — but only one corner of the
    /// circadian curve, so its mean is not comparable to a full night's.
    func testAPartiallyConnectedNightIsRejectedDespiteManyReadings() {
        let w = night()
        let samples = stride(from: 0.0, to: 2 * 3600, by: 68).map {
            TemperatureSample(time: w.start.addingTimeInterval($0), celsius: 34.0)
        }
        XCTAssertGreaterThan(samples.count, SkinTempBaseline.minNightlySamples,
                             "the count floor alone would let this through")
        XCTAssertEqual(SkinTempBaseline.coverage(samples: samples, in: w), 0.2, accuracy: 1e-9)
        XCTAssertNil(SkinTempBaseline.nightlyMean(samples: samples, in: w,
                     minCoverage: SkinTempBaseline.candidateNightlyCoverage))
        // …and with the SHIPPED default (gate off) the same night is published — the deliberate
        // ship-state, pinned so turning the gate on is a visible change rather than a silent one.
        XCTAssertNotNil(SkinTempBaseline.nightlyMean(samples: samples, in: w))
    }

    /// A night with gaps but readings spread across most of it is still comparable.
    func testASparseButWellSpreadNightPasses() {
        let w = night()
        // One reading every 20 min → 30 readings, every hour represented.
        let samples = stride(from: 0.0, to: w.duration, by: 1200).map {
            TemperatureSample(time: w.start.addingTimeInterval($0), celsius: 35.0)
        }
        XCTAssertEqual(SkinTempBaseline.coverage(samples: samples, in: w), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SkinTempBaseline.nightlyMean(samples: samples, in: w,
                       minCoverage: SkinTempBaseline.candidateNightlyCoverage)!, 35.0, accuracy: 1e-9)
    }

    /// `minCoverage: 0` is the kill-switch for the coverage half.
    func testCoverageKillSwitch() {
        let w = night()
        let samples = stride(from: 0.0, to: 2 * 3600, by: 68).map {
            TemperatureSample(time: w.start.addingTimeInterval($0), celsius: 34.0)
        }
        XCTAssertNotNil(SkinTempBaseline.nightlyMean(samples: samples, in: w, minCoverage: 0))
    }

    func testBaselineNeedsMinimumHistory() {
        XCTAssertNil(SkinTempBaseline.baseline(priorNights: [night(1, 30), night(2, 31)]),
                     "below minBaselineNights → no baseline")
        let three = [night(1, 30), night(2, 31), night(3, 32)]
        XCTAssertEqual(SkinTempBaseline.baseline(priorNights: three)!, 31, accuracy: 1e-9)
    }

    func testBaselineTrailingWindow() {
        // 5 nights but a window of 3 → only the 3 most-recent count.
        let nights = [night(5, 20), night(4, 20), night(3, 30), night(2, 31), night(1, 32)]
        XCTAssertEqual(SkinTempBaseline.baseline(priorNights: nights, windowNights: 3)!, 31, accuracy: 1e-9)
    }

    func testOffsetSign() {
        XCTAssertEqual(SkinTempBaseline.offset(tonight: 32, baseline: 31), 1, accuracy: 1e-9)
        XCTAssertEqual(SkinTempBaseline.offset(tonight: 30, baseline: 31), -1, accuracy: 1e-9)
    }

    func testDeviationBand() {
        XCTAssertEqual(SkinTempBaseline.deviationBand(offset: 0.5), .normal)
        XCTAssertEqual(SkinTempBaseline.deviationBand(offset: 1.5), .abnormalRise)
        XCTAssertEqual(SkinTempBaseline.deviationBand(offset: -1.5), .abnormalDrop)
        XCTAssertEqual(SkinTempBaseline.deviationBand(offset: 1.0), .normal, "exactly ±1 °C is still normal")
    }

    func testAnomalyFlags() {
        // +1.2 °C vs baseline → abnormalRise; +0.8 °C vs last night → fluctuationRise.
        let f = SkinTempBaseline.anomalyFlags(tonight: 32.2, baseline: 31.0, previousNight: 31.4)
        XCTAssertTrue(f.abnormalRise)
        XCTAssertFalse(f.abnormalDrop)
        XCTAssertTrue(f.fluctuationRise)
        XCTAssertFalse(f.fluctuationDrop)
        XCTAssertTrue(f.any)

        // A calm night within both bands → no flags.
        let calm = SkinTempBaseline.anomalyFlags(tonight: 31.1, baseline: 31.0, previousNight: 31.0)
        XCTAssertFalse(calm.any)

        // A sharp DROP vs last night even when baseline is unknown.
        let drop = SkinTempBaseline.anomalyFlags(tonight: 30.0, baseline: nil, previousNight: 31.0)
        XCTAssertTrue(drop.fluctuationDrop)
        XCTAssertFalse(drop.abnormalDrop, "no baseline → no abnormal classification")
    }

    /// Regression (user-reported, 2026-07-03): one artifact night (86 °F ≈ 30 °C — a cold
    /// object held while asleep) must alert ONCE, on the artifact night. The next night —
    /// back at baseline, i.e. normal — must NOT alert "rose sharply vs the previous night":
    /// tonight being ON the baseline means the previous night was the outlier, and it
    /// already had its alert.
    func testArtifactNightAlertsButRecoveryNightStaysQuiet() {
        let baseline = 34.4                       // ~93.9 °F habitual sleeping skin temp

        // Artifact night: far below baseline AND far below the previous (normal) night —
        // both the abnormal and fluctuation drops fire. This is the expected alert.
        let artifact = SkinTempBaseline.anomalyFlags(tonight: 30.0, baseline: baseline,
                                                     previousNight: 34.5)
        XCTAssertTrue(artifact.abnormalDrop)
        XCTAssertTrue(artifact.fluctuationDrop)
        XCTAssertFalse(artifact.fluctuationRise)

        // Recovery night: dead on baseline (the 30-night mean barely moves from one
        // outlier), but +4.5 °C vs the artifact night. Previously flagged fluctuationRise
        // ("rose sharply") — wrong; the baseline gate must keep it quiet.
        let recovery = SkinTempBaseline.anomalyFlags(tonight: 34.5, baseline: 34.25,
                                                     previousNight: 30.0)
        XCTAssertFalse(recovery.any, "a return to baseline is normal, not a sharp rise")
    }

    /// The gate must NOT swallow a genuine rapid rise: +0.8 °C overnight that lands well
    /// above baseline (but still inside the ±1 °C abnormal band) is exactly what the
    /// fluctuation flag exists to catch early.
    func testGenuineRapidRiseStillFlagged() {
        let f = SkinTempBaseline.anomalyFlags(tonight: 35.2, baseline: 34.4, previousNight: 34.4)
        XCTAssertTrue(f.fluctuationRise, "+0.8 °C overnight and +0.8 °C over baseline → early-warning flag")
        XCTAssertFalse(f.abnormalRise, "still inside the ±1 °C band — fluctuation is the early signal")
    }

    func testReportWithAndWithoutBaseline() {
        let prior = [night(1, 30.8), night(2, 31.0), night(3, 31.2)]   // baseline 31.0
        let r = SkinTempBaseline.report(tonight: 32.5, priorNights: prior, previousNight: 31.0)
        XCTAssertEqual(r.baselineC!, 31.0, accuracy: 1e-9)
        XCTAssertEqual(r.offsetC!, 1.5, accuracy: 1e-9)
        XCTAssertEqual(r.band, .abnormalRise)
        XCTAssertTrue(r.flags.abnormalRise)

        // Too little history → nightly value present, but no baseline/offset/band.
        let thin = SkinTempBaseline.report(tonight: 32.5, priorNights: [night(1, 31)])
        XCTAssertEqual(thin.nightlyC, 32.5, accuracy: 1e-9)
        XCTAssertNil(thin.baselineC)
        XCTAssertNil(thin.offsetC)
        XCTAssertNil(thin.band)
    }
}
