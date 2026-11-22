import XCTest
@testable import OpenCircuitKit

// The factors saved with a night's Sleep Score: built by the same call that produces the score, for
// every Kit writer, and shown only while they still describe the row's score. Synthetic values only.

final class SleepScoreFactorsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_789_862_400)   // 2026-09-20T00:00:00Z

    /// 7 h in bed with whole-minute stages.
    private func night() -> [SleepSegment] {
        let bed = t0.addingTimeInterval(-3600)
        func m(_ minutes: Double) -> Date { bed.addingTimeInterval(minutes * 60) }
        return [
            SleepSegment(start: m(0), end: m(420), stage: .inBed),
            SleepSegment(start: m(0), end: m(120), stage: .asleepCore),
            SleepSegment(start: m(120), end: m(190), stage: .asleepDeep),
            SleepSegment(start: m(190), end: m(214), stage: .awake),
            SleepSegment(start: m(214), end: m(304), stage: .asleepREM),
            SleepSegment(start: m(304), end: m(420), stage: .asleepCore),
        ]
    }

    private func input(hr: Double? = 55, off: Double? = 0.2) -> SleepScore.CompositeInput {
        let s = SleepStaging.summary(night())
        return .init(totalAsleep: s.totalAsleep, timeAwake: s.awake, efficiency: s.efficiency,
                     deep: s.deep, light: s.light, rem: s.rem, restingHR: hr, tempOffsetC: off)
    }

    private func keyed(_ c: SleepScore.Composite) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: c.factors.map { ($0.key.rawValue, $0.value) })
    }

    // MARK: Same call, same number

    /// The ring writer's step (`RingSession.computeSleepExtras`).
    func testScoredIsTheCompositeScoreAndFactors() {
        for (hr, off) in [(Optional(55.0), Optional(0.2)), (60, nil), (nil, -0.4), (nil, nil)] {
            let entry = SleepScoreFactors.scored(input(hr: hr, off: off), producer: .ring)
            let composite = SleepScore.composite(input(hr: hr, off: off))
            XCTAssertEqual(entry.score, composite.score)
            XCTAssertEqual(entry.factors, keyed(composite))
            XCTAssertEqual(entry.recomputedScore, entry.score)
            XCTAssertEqual(Set(entry.weights.keys), Set(entry.factors.keys))
        }
    }

    /// The strap writer (`StoredNightScore.scores`).
    func testTheStrapProducerReturnsItsFactorsWithItsScore() throws {
        let segments = night()
        let hr = stride(from: segments[0].start.timeIntervalSince1970, to: segments[0].end.timeIntervalSince1970,
                        by: 300).map { HRSample(bpm: 57, start: Date(timeIntervalSince1970: $0), end: nil) }
        let priors = (1...5).map {
            SkinTempBaseline.NightlyTemp(night: t0.addingTimeInterval(TimeInterval(-86_400 * $0)), celsius: 33.5)
        }
        let scores = StoredNightScore.scores(.init(segments: segments, heartRate: hr, rmssd: [40, 42, 44],
                                                   skinTempC: 33.8, priorNights: priors))
        let entry = try XCTUnwrap(scores.factors)
        XCTAssertEqual(entry.score, scores.sleepScore)
        XCTAssertEqual(entry.producer, .strap)
        XCTAssertEqual(entry.inputs.restingHR, scores.restingHR)
        XCTAssertEqual(entry.inputs.tempOffsetC, scores.tempOffsetC)
        XCTAssertEqual(entry.factors, keyed(SleepScore.composite(entry.inputs.compositeInput)))
        XCTAssertEqual(entry.factors.count, 6)
    }

    func testAnUnscorableStrapNightHasNoFactors() {
        let scores = StoredNightScore.scores(.init(segments: []))
        XCTAssertNil(scores.sleepScore)
        XCTAssertNil(scores.factors)
    }

    /// The heal writer (`SleepScoreHeal`).
    func testTheHealProducerReturnsItsFactorsWithItsScore() throws {
        let entry = try XCTUnwrap(SleepScoreHeal.healedFactors(hypnogram: night()))
        XCTAssertEqual(entry.score, SleepScoreHeal.healedScore(hypnogram: night()))
        XCTAssertEqual(entry.producer, .edited)
        XCTAssertNil(entry.factors["heartRate"])
        XCTAssertNil(entry.factors["temperature"])
        XCTAssertEqual(entry.factors, keyed(SleepScore.composite(entry.inputs.compositeInput)))
    }

    // MARK: Shown only while it is the row's score

    func testASavedEntryIsShownWhenItsScoreIsTheRows() throws {
        let entry = SleepScoreFactors.scored(input(), producer: .ring)
        let breakdown = try XCTUnwrap(SleepScoreBreakdown.make(saved: entry, storedScore: entry.score))
        XCTAssertEqual(breakdown.score, entry.score)
        XCTAssertEqual(breakdown.rows.count, 6)
        XCTAssertEqual(breakdown.rows.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-9)
        XCTAssertEqual(breakdown.rows.first { $0.factor == .heartRate }?.valueText, "55 bpm")
        XCTAssertEqual(breakdown.rows.first { $0.factor == .temperature }?.valueText, "+0.2 °C")
    }

    func testASavedEntryWithADifferentScoreShowsNothing() {
        let entry = SleepScoreFactors.scored(input(), producer: .ring)
        XCTAssertNil(SleepScoreBreakdown.make(saved: entry, storedScore: entry.score + 1))
        XCTAssertNil(SleepScoreBreakdown.make(saved: entry, storedScore: entry.score - 1))
        XCTAssertNil(SleepScoreBreakdown.make(saved: nil, storedScore: entry.score))
        XCTAssertNil(SleepScoreBreakdown.make(saved: entry, storedScore: 0))
    }

    /// An entry whose own factors do not add up to its score (a damaged file) is never shown.
    func testAnEntryWhoseFactorsDoNotAddUpShowsNothing() {
        let good = SleepScoreFactors.scored(input(), producer: .ring)
        var factors = good.factors
        factors["timeAsleep"] = 0
        let bad = SleepScoreFactors(score: good.score, producer: .ring, factors: factors,
                                    weights: good.weights, inputs: good.inputs)
        XCTAssertNotEqual(bad.recomputedScore, bad.score)
        XCTAssertNil(SleepScoreBreakdown.make(saved: bad, storedScore: good.score))
    }

    /// A missing factor is left out, not shown as 0, and the rest are re-weighted.
    func testAFourFactorEntryRenormalises() throws {
        let entry = SleepScoreFactors.scored(input(hr: nil, off: nil), producer: .edited)
        let rows = try XCTUnwrap(SleepScoreBreakdown.make(saved: entry, storedScore: entry.score)).rows
        XCTAssertEqual(rows.map(\.weightText), ["37.5%", "25%", "25%", "12.5%"])
    }

    func testItRoundTripsThroughJSON() throws {
        let entry = SleepScoreFactors.scored(input(), producer: .strap)
        let decoded = try JSONDecoder().decode(SleepScoreFactors.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        let noOptional = SleepScoreFactors.scored(input(hr: nil, off: nil), producer: .edited)
        XCTAssertEqual(try JSONDecoder().decode(SleepScoreFactors.self, from: JSONEncoder().encode(noOptional)),
                       noOptional)
    }
}
