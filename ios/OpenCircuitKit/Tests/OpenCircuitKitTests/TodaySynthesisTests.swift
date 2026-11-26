import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the Today synthesis line (#216). Asserts the exact sentences, because
/// the copy IS the behaviour: each rule, the rule precedence, and the honest degradations when
/// data is missing, stale, or readiness can't be scored.
final class TodaySynthesisTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var fresh: Date { now.addingTimeInterval(-2 * 3600) }

    private func say(_ readiness: TodaySynthesis.Readiness = .pending,
                     hrv: BaselineTrend.Direction? = nil,
                     rhr: BaselineTrend.Direction? = nil,
                     temp: BaselineTrend.Direction? = nil,
                     fever: Bool = false,
                     sleep: Int? = nil, usualSleep: Double? = nil,
                     newest: Date?? = .none) -> String {
        let sentence = TodaySynthesis.sentence(.init(readiness: readiness, hrv: hrv, restingHR: rhr, skinTemp: temp,
                                                     feverSuspected: fever,
                                                     lastNightSleepMinutes: sleep, usualSleepMinutes: usualSleep,
                                                     newestDataAt: newest ?? fresh, now: now))
        // Decision 93a: the score is called Recovery everywhere a user reads it. Every case goes through here.
        XCTAssertFalse(sentence.contains("Readiness"), sentence)
        XCTAssertFalse(sentence.contains("readiness"), sentence)
        return sentence
    }

    // MARK: Missing / stale data

    func testNoDataAtAll() {
        XCTAssertEqual(say(.scored(score: 90, tier: .excellent, factorCount: 3), newest: .some(nil)),
                       "There's no data from your device yet, so connect and sync it to see today's summary.")
    }

    func testStaleDataOverridesEverything() {
        XCTAssertEqual(say(.scored(score: 90, tier: .excellent, factorCount: 3), hrv: .above,
                           newest: now.addingTimeInterval(-40 * 3600)),
                       "Your newest data is over a day old, so sync your device to bring today's summary up to date.")
        XCTAssertEqual(say(newest: now.addingTimeInterval(-3.5 * 86_400)),
                       "Your newest data is 3 days old, so sync your device to bring today's summary up to date.")
    }

    func testBeyondTheLookbackIsNotCounted() {
        XCTAssertEqual(say(newest: now.addingTimeInterval(-14 * 86_400)),
                       "Your newest data is more than two weeks old, so sync your device to bring today's summary up to date.")
    }

    func testThirtyFiveHoursIsNotStale() {
        XCTAssertEqual(say(newest: now.addingTimeInterval(-35 * 3600)), "Working out today's recovery.")
    }

    // MARK: Scored readiness

    func testExcellentWithPositive() {
        XCTAssertEqual(say(.scored(score: 88, tier: .excellent, factorCount: 3), hrv: .above, rhr: .within),
                       "Recovery is excellent at 88, and HRV is above your usual.")
    }

    func testGoodWithConcernUsesThough() {
        XCTAssertEqual(say(.scored(score: 74, tier: .good, factorCount: 3), hrv: .above, sleep: 320),
                       "Recovery is good at 74, though last night's sleep was short.")
    }

    func testGoodSteady() {
        XCTAssertEqual(say(.scored(score: 74, tier: .good, factorCount: 2), hrv: .within, rhr: .within),
                       "Recovery is good at 74, with HRV and resting heart rate in your usual range.")
        XCTAssertEqual(say(.scored(score: 74, tier: .good, factorCount: 2), rhr: .within),
                       "Recovery is good at 74, with resting heart rate in your usual range.")
    }

    func testGoodWithNothingElseKnown() {
        XCTAssertEqual(say(.scored(score: 70, tier: .good, factorCount: 3)), "Recovery is good at 70.")
    }

    func testSleepAloneIsDisclosed() {
        XCTAssertEqual(say(.scored(score: 81, tier: .good, factorCount: 1)),
                       "Recovery is good at 81 based on last night's sleep alone.")
    }

    func testNeedsImprovement() {
        XCTAssertEqual(say(.scored(score: 52, tier: .needsImprovement, factorCount: 3), hrv: .below),
                       "Recovery needs improvement at 52, and HRV is below your usual, so an easier day may help.")
        XCTAssertEqual(say(.scored(score: 52, tier: .needsImprovement, factorCount: 3), hrv: .above),
                       "Recovery needs improvement at 52, so an easier day may help.")
    }

    func testShortNightRelativeToUsual() {
        // 400 min is over 6 h, but 80 min under a 480-min usual → short.
        XCTAssertEqual(say(.scored(score: 75, tier: .good, factorCount: 3), sleep: 400, usualSleep: 480),
                       "Recovery is good at 75, though last night's sleep was short.")
        // 440 vs 480 is within the 60-min allowance → not short.
        XCTAssertEqual(say(.scored(score: 75, tier: .good, factorCount: 3), sleep: 440, usualSleep: 480),
                       "Recovery is good at 75.")
    }

    func testFeverPairTakesPrecedence() {
        XCTAssertEqual(say(.scored(score: 80, tier: .good, factorCount: 3), hrv: .above, rhr: .above, temp: .above,
                           fever: true),
                       "Recovery is good at 80, but skin temperature and resting heart rate are both above your usual, so take today gently.")
        XCTAssertEqual(say(rhr: .above, temp: .above, fever: true),
                       "Skin temperature and resting heart rate are both above your usual, so take today gently.")
    }

    /// Both tiles above their usual is NOT the fever pairing: only Vitals Status's own verdict is.
    func testBothTilesAboveWithoutVitalsStatusFeverIsOrdinaryClauses() {
        XCTAssertEqual(say(.scored(score: 80, tier: .good, factorCount: 3), rhr: .above, temp: .above),
                       "Recovery is good at 80, though resting heart rate is above your usual.")
        XCTAssertEqual(say(rhr: .above, temp: .above), "Resting heart rate is above your usual.")
        XCTAssertEqual(say(.noNight, rhr: .above, temp: .above),
                       "Last night's sleep hasn't synced yet, so there's no recovery score, but resting heart rate is above your usual.")
    }

    // MARK: Agreement with Vitals Status (review #220 S3)

    /// A daily series ending today, oldest first.
    private func trend(_ values: [Double], floor: Double) -> BaselineTrend.Result? {
        BaselineTrend.evaluate(values.enumerated().map { i, v in
            BaselineTrend.Point(date: now.addingTimeInterval(Double(i - values.count + 1) * 86_400), value: v)
        }, minAbsoluteDelta: floor)
    }

    /// The reviewer's probe, asserting the fix. +0.35 °C and +3 bpm put BOTH tiles above their usual
    /// (floors 0.3 °C and 2 bpm), but Vitals Status's fever rule (+1.0 °C AND +8 bpm over 7+ days)
    /// doesn't fire, so the synthesis must not say "take today gently" under a Vitals Status card that
    /// shows no fever. Vitals Status firing is what brings the pairing back.
    func testTheFeverPairingFollowsVitalsStatusNotTheTiles() {
        let temp = trend([33.5, 33.5, 33.5, 33.5, 33.5, 33.85], floor: 0.3)
        let rhrPrior: [Double] = [58, 58, 58, 58, 58, 58, 58]
        let rhr = trend(rhrPrior + [61], floor: 2)
        XCTAssertEqual(temp?.direction, .above)
        XCTAssertEqual(rhr?.direction, .above)
        let noFever = VitalsBaseline.suspectedFever(restingHRToday: 61, restingHRPrior: rhrPrior, skinTempOffsetC: 0.35)
        XCTAssertFalse(noFever)
        let s = say(.scored(score: 80, tier: .good, factorCount: 3), rhr: rhr?.direction, temp: temp?.direction,
                    fever: noFever)
        XCTAssertEqual(s, "Recovery is good at 80, though resting heart rate is above your usual.")

        let fever = VitalsBaseline.suspectedFever(restingHRToday: 67, restingHRPrior: rhrPrior, skinTempOffsetC: 1.2)
        XCTAssertTrue(fever)
        XCTAssertEqual(say(.scored(score: 80, tier: .good, factorCount: 3), rhr: .above, temp: .above, fever: fever),
                       "Recovery is good at 80, but skin temperature and resting heart rate are both above your usual, so take today gently.")
    }

    /// The reviewer's second probe. Resting HR 58 → 61 reads "above your usual" on the tile (allowed:
    /// the tile's band is its own) while Vitals Status calls it normal. Whatever the skin-temperature
    /// tile says, the synthesis must not escalate that to fever signs or "take today gently".
    func testARestingHRTileAboveWhileVitalsStatusIsNormalIsNeverEscalated() {
        let prior: [Double] = [58, 58, 59, 58, 57, 58, 58]
        XCTAssertEqual(trend(prior + [61], floor: 2)?.direction, .above)
        XCTAssertEqual(VitalsBaseline.classify(today: 61, prior: prior, vital: .restingHR).severity, .normal)
        let readinesses: [TodaySynthesis.Readiness] = [.pending, .noNight, .noScore,
                                                       .scored(score: 80, tier: .good, factorCount: 3),
                                                       .scored(score: 40, tier: .needsImprovement, factorCount: 2)]
        for r in readinesses {
            for t: BaselineTrend.Direction? in [nil, .within, .above] {
                let s = say(r, rhr: .above, temp: t)
                XCTAssertFalse(s.contains("gently"), s)
                XCTAssertFalse(s.contains("both above"), s)
            }
        }
    }

    // MARK: No readiness

    func testNoNightSaysSyncHasntHappened() {
        XCTAssertEqual(say(.noNight), "Last night's sleep hasn't synced yet, so there's no recovery score.")
        XCTAssertEqual(say(.noNight, hrv: .below),
                       "Last night's sleep hasn't synced yet, so there's no recovery score, but HRV is below your usual.")
    }

    func testNoScoreNeverSuggestsSync() {
        let s = say(.noScore, hrv: .within)
        XCTAssertEqual(s, "Last night has no sleep score, so there's no recovery today, but HRV is in your usual range.")
        XCTAssertFalse(s.localizedCaseInsensitiveContains("sync"))
    }

    func testPendingFallsBackToVitals() {
        XCTAssertEqual(say(hrv: .above), "HRV is above your usual.")
        XCTAssertEqual(say(hrv: .within, rhr: .within), "HRV and resting heart rate are in your usual range.")
        XCTAssertEqual(say(), "Working out today's recovery.")
    }

    func testEverySentenceIsOneSentence() {
        let readinesses: [TodaySynthesis.Readiness] = [
            .pending, .noNight, .noScore,
            .scored(score: 90, tier: .excellent, factorCount: 3),
            .scored(score: 70, tier: .good, factorCount: 1),
            .scored(score: 40, tier: .needsImprovement, factorCount: 2),
        ]
        let dirs: [BaselineTrend.Direction?] = [nil, .above, .within, .below]
        for r in readinesses { for h in dirs { for rh in dirs { for t in dirs { for f in [false, true] {
            let s = say(r, hrv: h, rhr: rh, temp: t, fever: f, sleep: 300)
            XCTAssertTrue(s.hasSuffix("."), s)
            XCTAssertEqual(s.filter { $0 == "." }.count, 1, s)
            XCTAssertEqual(s.first.map { String($0) }, s.first.map { String($0).uppercased() }, s)
        } } } } }
    }
}
