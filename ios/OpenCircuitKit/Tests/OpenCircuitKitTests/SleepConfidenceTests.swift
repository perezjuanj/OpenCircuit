import XCTest
@testable import OpenCircuitKit

/// `SleepConfidence` flags a full night whose reported duration is likely over-counted because the
/// ring couldn't see still wakefulness (efficiency pinned implausibly near 100 %). Grounded in the
/// user's own decoded nights (2026-06-29 device pull): the near-100 % nights (06-20/22/24/25/28) are
/// the implausible ones; the nights with real detected wake (06-26 84 %, 06-27 88 %) must NOT flag.
final class SleepConfidenceTests: XCTestCase {

    private func mins(_ m: Double) -> TimeInterval { m * 60 }

    // MARK: - Flags the implausibly-still nights

    func testNear100PercentFullNightFlagsDurationLikelyHigh() {
        // 06-28: asleep 572 m, awake 7 m → in-bed 579 m, efficiency 98.8 %.
        let level = SleepConfidence.classify(asleep: mins(572), inBed: mins(579))
        XCTAssertEqual(level, .durationLikelyHigh,
                       "a 9.5 h night with only 7 min detected wake reads implausibly high")
    }

    func testExactly100PercentFullNightFlags() {
        // 06-24: asleep 487 m, awake 2 m → essentially 100 % efficiency.
        XCTAssertEqual(SleepConfidence.classify(asleep: mins(487), inBed: mins(489)),
                       .durationLikelyHigh)
    }

    // MARK: - Does NOT flag the nights that are already realistic

    func testRealisticEfficiencyNightIsNormal() {
        // 06-27: asleep 553 m, awake 76 m → in-bed 629 m, efficiency 87.9 % (real WASO detected).
        XCTAssertEqual(SleepConfidence.classify(asleep: mins(553), inBed: mins(629)), .normal,
                       "a night with realistic detected wake is not flagged")
    }

    func testLowEfficiencyNightIsNormal() {
        // 06-26: asleep 583 m, awake 110 m → in-bed 693 m, efficiency 84.1 %.
        XCTAssertEqual(SleepConfidence.classify(asleep: mins(583), inBed: mins(693)), .normal)
    }

    // MARK: - Conservative guards

    func testShortNightIsNeverFlaggedEvenAt100Percent() {
        // 06-23: a 68 m block at ~100 % efficiency — far below minNightForFlag, so unremarkable.
        XCTAssertEqual(SleepConfidence.classify(asleep: mins(68), inBed: mins(70)), .normal,
                       "a sub-5 h block (nap / truncated fragment) never flags on efficiency alone")
    }

    func testJustUnderMinNightDurationIsNormal() {
        let justUnder = SleepConfidence.minNightForFlag - 1
        XCTAssertEqual(SleepConfidence.classify(asleep: justUnder, inBed: justUnder), .normal,
                       "below the multi-hour gate we don't judge efficiency")
    }

    func testDegenerateInBedIsNormal() {
        XCTAssertEqual(SleepConfidence.classify(asleep: 0, inBed: 0), .normal)
        XCTAssertEqual(SleepConfidence.classify(asleep: mins(300), inBed: -1), .normal)
    }

    // MARK: - Threshold boundary

    func testEfficiencyAtThresholdIsNormalAboveItFlags() {
        let night = SleepConfidence.minNightForFlag + mins(60)   // a clearly multi-hour night
        // Exactly at the 0.95 threshold → not flagged (strict `>`).
        let atThreshold = SleepConfidence.implausibleEfficiency * night
        XCTAssertEqual(SleepConfidence.classify(asleep: atThreshold, inBed: night), .normal,
                       "efficiency exactly at the threshold is not flagged")
        // A hair above → flagged.
        let above = (SleepConfidence.implausibleEfficiency + 0.02) * night
        XCTAssertEqual(SleepConfidence.classify(asleep: above, inBed: night), .durationLikelyHigh)
    }

    // MARK: - Summary overload agrees with the primitive

    func testSummaryOverloadMatchesPrimitive() {
        // inBed 579 m partitioned: 7 m awake, rest asleep (light/deep/rem) → totalAsleep 572 m.
        let s = SleepStaging.Summary(inBed: mins(579), awake: mins(7),
                                     light: mins(380), deep: mins(45), rem: mins(147))
        XCTAssertEqual(s.minutes.asleep, 572)
        XCTAssertEqual(SleepConfidence.classify(s),
                       SleepConfidence.classify(asleep: s.totalAsleep, inBed: s.inBed))
        XCTAssertEqual(SleepConfidence.classify(s), .durationLikelyHigh)
    }
}
