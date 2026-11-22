import XCTest
@testable import OpenCircuitKit

// The Sleep Score breakdown must add up to the badge it explains: for each producer shape, the
// rebuilt score is run against the REAL producer function (where it is a pure Kit function) and
// must agree with it, and a breakdown that disagrees with the stored score must not exist.
// Every value here is synthetic.

final class SleepScoreBreakdownTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_789_862_400)   // 2026-09-20T00:00:00Z

    /// An in-bed span with whole-minute stages (so the row's rounded minutes lose nothing):
    /// 7 h in bed, 6 h 16 m asleep (core 216 + deep 70 + REM 90), 44 min awake.
    private func night() -> [SleepSegment] {
        let bed = t0.addingTimeInterval(-3600)
        func m(_ minutes: Double) -> Date { bed.addingTimeInterval(minutes * 60) }
        return [
            SleepSegment(start: m(0), end: m(420), stage: .inBed),
            SleepSegment(start: m(0), end: m(120), stage: .asleepCore),
            SleepSegment(start: m(120), end: m(190), stage: .asleepDeep),
            SleepSegment(start: m(190), end: m(214), stage: .awake),
            SleepSegment(start: m(214), end: m(304), stage: .asleepREM),
            SleepSegment(start: m(304), end: m(400), stage: .asleepCore),
            SleepSegment(start: m(400), end: m(420), stage: .awake),
        ]
    }

    private func heartRate(_ segments: [SleepSegment], bpm: Int) -> [HRSample] {
        guard let from = segments.first?.start, let to = segments.last?.end else { return [] }
        return stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 300).map {
            HRSample(bpm: bpm, start: Date(timeIntervalSince1970: $0), end: nil)
        }
    }

    private func priorNights(_ count: Int, celsius: Double) -> [SkinTempBaseline.NightlyTemp] {
        (1...count).map {
            SkinTempBaseline.NightlyTemp(night: t0.addingTimeInterval(TimeInterval(-86_400 * $0)), celsius: celsius)
        }
    }

    /// The row a night would have stored: whole minutes, efficiency as the summary reports it.
    private func rowNight(_ summary: SleepStaging.Summary, score: Int, producer: SleepScoreBreakdown.Producer,
                          hr: Double? = nil, off: Double? = nil) -> SleepScoreBreakdown.Night {
        let m = summary.minutes
        return .init(storedScore: score, producer: producer,
                     asleepMin: m.deep + m.light + m.rem, awakeMin: m.awake,
                     deepMin: m.deep, lightMin: m.light, remMin: m.rem,
                     efficiency: summary.efficiency, restingHR: hr, tempOffsetC: off)
    }

    // MARK: Producer shapes

    /// EDITED night: `applySleepEdit` / `SleepScoreHeal` pass no HR and no temperature.
    func testEditedNightMatchesTheHealProducerAndShowsNoHRorTemperatureRows() throws {
        let segments = night()
        let healed = try XCTUnwrap(SleepScoreHeal.healedScore(hypnogram: segments))
        let summary = try XCTUnwrap(SleepScoreHeal.summary(from: segments))
        // Even if a caller hands HR and a temperature offset in, the edited shape must ignore them.
        let row = rowNight(summary, score: healed, producer: .edited, hr: 52, off: 0.3)
        let breakdown = try XCTUnwrap(SleepScoreBreakdown.make(row))
        XCTAssertEqual(breakdown.score, healed)
        XCTAssertEqual(breakdown.rows.map(\.factor).sorted { $0.rawValue < $1.rawValue },
                       [.efficiency, .stages, .timeAsleep, .timeAwake])
        XCTAssertFalse(breakdown.rows.contains { $0.factor == .heartRate || $0.factor == .temperature })
    }

    /// RING night: the composite is called with the resting HR and the offset vs prior nights.
    func testRingNightRebuildsTheSameScoreWithAllSixRows() throws {
        let segments = night()
        let summary = SleepStaging.summary(segments)
        let restingHR = try XCTUnwrap(RestingHR.value(hr: heartRate(segments, bpm: 54), sleep: segments))
        let composite = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem,
            restingHR: restingHR, tempOffsetC: 0.2))
        let row = rowNight(summary, score: composite.score, producer: .ring, hr: restingHR, off: 0.2)
        let breakdown = try XCTUnwrap(SleepScoreBreakdown.rebuild(row))
        XCTAssertEqual(breakdown.score, composite.score)
        XCTAssertEqual(breakdown.rows.count, 6)
        XCTAssertEqual(breakdown.rows.first(where: { $0.factor == .heartRate })?.valueText, "54 bpm")
        XCTAssertEqual(breakdown.rows.first(where: { $0.factor == .temperature })?.valueText, "+0.2 °C")
    }

    /// STRAP night: `StoredNightScore.scores` over the stored rows; its own `restingHR` and
    /// `tempOffsetC` are exactly what the composite was given.
    func testStrapNightRebuildsTheSameScoreFromTheProducersOwnInputs() throws {
        let segments = night()
        let scores = StoredNightScore.scores(.init(
            segments: segments, heartRate: heartRate(segments, bpm: 58), rmssd: [40, 42, 44],
            skinTempC: 33.8, priorNights: priorNights(5, celsius: 33.5)))
        let stored = try XCTUnwrap(scores.sleepScore)
        let row = rowNight(SleepStaging.summary(segments), score: stored, producer: .strap,
                           hr: scores.restingHR, off: scores.tempOffsetC)
        let breakdown = try XCTUnwrap(SleepScoreBreakdown.rebuild(row))
        XCTAssertEqual(breakdown.score, stored)
        XCTAssertEqual(breakdown.rows.count, 6)
    }

    /// A ring/strap night with no HR and no baseline yet is scored on four factors, and so is its
    /// breakdown: the missing ones are left out, not shown as zero.
    func testMissingOptionalInputsAreLeftOutNotZeroed() throws {
        let segments = night()
        let summary = SleepStaging.summary(segments)
        let composite = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem))
        let breakdown = try XCTUnwrap(SleepScoreBreakdown.rebuild(
            rowNight(summary, score: composite.score, producer: .ring)))
        XCTAssertEqual(breakdown.rows.count, 4)
    }

    // MARK: Weights

    func testWeightsShownSumToOneHundredPercent() throws {
        let segments = night()
        let summary = SleepStaging.summary(segments)
        for (hr, off) in [(Optional(55.0), Optional(0.1)), (55.0, nil), (nil, 0.1), (nil, nil)] {
            let composite = SleepScore.composite(.init(
                totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
                deep: summary.deep, light: summary.light, rem: summary.rem, restingHR: hr, tempOffsetC: off))
            let breakdown = try XCTUnwrap(SleepScoreBreakdown.rebuild(
                rowNight(summary, score: composite.score, producer: .ring, hr: hr, off: off)))
            XCTAssertEqual(breakdown.rows.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-9)
        }
    }

    func testFullShapeShowsTheDocumentedWeightsInWeightOrder() throws {
        let summary = SleepStaging.summary(night())
        let composite = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem, restingHR: 55, tempOffsetC: 0))
        let breakdown = try XCTUnwrap(SleepScoreBreakdown.rebuild(
            rowNight(summary, score: composite.score, producer: .ring, hr: 55, off: 0)))
        XCTAssertEqual(breakdown.rows.map(\.weightText), ["30%", "20%", "20%", "10%", "10%", "10%"])
        XCTAssertEqual(breakdown.rows.first?.factor, .timeAsleep)
    }

    func testEditedShapeRenormalisesOverFourFactors() throws {
        let summary = try XCTUnwrap(SleepScoreHeal.summary(from: night()))
        let healed = try XCTUnwrap(SleepScoreHeal.healedScore(hypnogram: night()))
        let breakdown = try XCTUnwrap(SleepScoreBreakdown.make(rowNight(summary, score: healed, producer: .edited)))
        XCTAssertEqual(breakdown.rows.map(\.weightText), ["37.5%", "25%", "25%", "12.5%"])
    }

    // MARK: Never a breakdown that does not add up

    func testAMismatchReturnsNil() throws {
        let summary = try XCTUnwrap(SleepScoreHeal.summary(from: night()))
        let healed = try XCTUnwrap(SleepScoreHeal.healedScore(hypnogram: night()))
        XCTAssertNotNil(SleepScoreBreakdown.make(rowNight(summary, score: healed, producer: .edited)))
        XCTAssertNil(SleepScoreBreakdown.make(rowNight(summary, score: healed + 1, producer: .edited)))
        XCTAssertNil(SleepScoreBreakdown.make(rowNight(summary, score: healed - 1, producer: .edited)))
        XCTAssertNil(SleepScoreBreakdown.rebuild(rowNight(summary, score: healed + 1, producer: .edited)))
    }

    /// The badge hides on 0 (the column's "never computed" sentinel); so does the breakdown.
    func testNoStoredScoreReturnsNil() throws {
        let summary = try XCTUnwrap(SleepScoreHeal.summary(from: night()))
        XCTAssertNil(SleepScoreBreakdown.rebuild(rowNight(summary, score: 0, producer: .edited)))
    }

    /// An edited night that was scored WITH an HR factor must not match an HR-less rebuild: the
    /// shape check is not a way to paper over a different producer.
    func testARowScoredWithHRDoesNotMatchTheEditedShape() throws {
        let segments = night()
        let summary = SleepStaging.summary(segments)
        let withHR = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem, restingHR: 45, tempOffsetC: nil))
        let noHR = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem))
        try XCTSkipIf(withHR.score == noHR.score, "synthetic night does not separate the two shapes")
        XCTAssertNil(SleepScoreBreakdown.rebuild(rowNight(summary, score: withHR.score, producer: .edited)))
    }

    // MARK: The gate

    /// `make` is the UI's entry point and refuses producers that were measured not to reproduce,
    /// even when one night happens to.
    func testOnlyReproducibleProducersAreShown() throws {
        let summary = SleepStaging.summary(night())
        let composite = SleepScore.composite(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem))
        let row = rowNight(summary, score: composite.score, producer: .ring)
        XCTAssertNotNil(SleepScoreBreakdown.rebuild(row))
        XCTAssertNil(SleepScoreBreakdown.make(row))
        XCTAssertTrue(SleepScoreBreakdown.Producer.edited.isReproducible)
        XCTAssertFalse(SleepScoreBreakdown.Producer.ring.isReproducible)
        XCTAssertFalse(SleepScoreBreakdown.Producer.strap.isReproducible)
    }

    // MARK: Value text

    func testValueTextCarriesTheMeasuredValueAndUnit() throws {
        let night = SleepScoreBreakdown.Night(
            storedScore: 0, producer: .edited, asleepMin: 412, awakeMin: 14,
            deepMin: 80, lightMin: 254, remMin: 78, efficiency: 0.91)
        let composite = SleepScore.composite(.init(
            totalAsleep: 412 * 60, timeAwake: 14 * 60, efficiency: 0.91,
            deep: 80 * 60, light: 254 * 60, rem: 78 * 60))
        var stored = night; stored.storedScore = composite.score
        let rows = try XCTUnwrap(SleepScoreBreakdown.make(stored)).rows
        func text(_ f: SleepScore.Composite.Factor) -> String? { rows.first { $0.factor == f }?.valueText }
        XCTAssertEqual(text(.timeAsleep), "6 h 52 m of 8 h goal")
        XCTAssertEqual(text(.stages), "38% deep + REM")
        XCTAssertEqual(text(.efficiency), "91% efficiency")
        XCTAssertEqual(text(.timeAwake), "14 min awake")
        XCTAssertEqual(rows.first(where: { $0.factor == .timeAsleep })?.subScore, 86)
    }
}
