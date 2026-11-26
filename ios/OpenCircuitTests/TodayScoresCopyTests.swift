import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Every word on Today's scores card (#391, SCOPE §4.3), the Recovery detail's copy and the corrected
// methods text. The copy IS the behaviour here: a missing value is a dash and a reason, never a 0 (I4);
// no device is named (I5); only "No night yet" may lead to a sync (I6); and the score is "Recovery".
// Every value is synthetic.

final class TodayScoresCopyTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_780_000_000)

    private func reading(_ strain: Double?, seconds: Int, rhr: Int? = 54) -> DailyStrain.Reading {
        DailyStrain.Reading(strain: strain, coveredSeconds: seconds, latestSampleAt: seconds > 0 ? at : nil,
                            maxHR: 185, restingHR: rhr)
    }

    private func recovery(_ sleep: Int, _ stress: Int?) throws -> TodayScores.Recovery {
        .scored(try XCTUnwrap(WellnessBalance.recoveryScore(sleepScore: sleep, overnightStress: stress)))
    }

    // MARK: Sleep

    func testSleepRows() {
        let scored = TodayScores.Sleep.scored(score: 85, asleepMin: 437)
        XCTAssertEqual(TodayScoresCopy.sleepValue(scored), "85")
        XCTAssertEqual(TodayScoresCopy.sleepStatus(scored), "7h 17m")
        XCTAssertEqual(TodayScoresCopy.sleepAccessibility(scored), "Sleep score, 85 out of 100, 7 hours 17 minutes asleep")

        XCTAssertEqual(TodayScoresCopy.sleepValue(.noNight), "—")
        XCTAssertEqual(TodayScoresCopy.sleepStatus(.noNight), "No night yet")
        XCTAssertEqual(TodayScoresCopy.sleepAccessibility(.noNight), "Sleep score unavailable. Last night hasn't synced yet.")

        XCTAssertEqual(TodayScoresCopy.sleepValue(.noScore), "—")
        XCTAssertEqual(TodayScoresCopy.sleepStatus(.noScore), "No score")
        XCTAssertEqual(TodayScoresCopy.sleepAccessibility(.noScore), "Sleep score unavailable. Last night has no score.")
    }

    // MARK: Recovery

    func testRecoveryRows() throws {
        let good = try recovery(85, 33)
        XCTAssertEqual(TodayScoresCopy.recoveryValue(good), "82")
        XCTAssertEqual(TodayScoresCopy.recoveryStatus(good), "Good")
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(good), "Recovery, estimate, 82 out of 100, Good")

        let alone = try recovery(64, nil)
        XCTAssertEqual(TodayScoresCopy.recoveryValue(alone), "64")
        XCTAssertTrue(alone.isLowConfidence)
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(alone),
                       "Recovery, estimate, 64 out of 100, Good, based on last night's sleep alone")

        XCTAssertEqual(TodayScoresCopy.recoveryStatus(try recovery(90, nil)), "Excellent")
        XCTAssertEqual(TodayScoresCopy.recoveryStatus(try recovery(52, nil)), "Needs improvement")

        XCTAssertEqual(TodayScoresCopy.recoveryValue(.noNight), "—")
        XCTAssertEqual(TodayScoresCopy.recoveryStatus(.noNight), "No night yet")
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(.noNight), "Recovery unavailable. Last night hasn't synced yet.")
        XCTAssertEqual(TodayScoresCopy.recoveryValue(.noScore), "—")
        XCTAssertEqual(TodayScoresCopy.recoveryStatus(.noScore), "No score")
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(.noScore), "Recovery unavailable. Last night has no score.")
    }

    // MARK: Strain

    func testStrainRows() {
        let r = reading(8.4, seconds: 5_400)
        XCTAssertEqual(TodayScoresCopy.strainValue(.scored(r)), "8.4")
        XCTAssertEqual(TodayScoresCopy.strainStatus(.scored(r)), "Light · so far")
        XCTAssertEqual(TodayScoresCopy.strainAccessibility(.scored(r)), StrainTileText.accessibilityLabel(r))
        XCTAssertTrue(TodayScoresCopy.strainAccessibility(.scored(r)).contains("as of "), "keeps the time of the newest reading")

        XCTAssertEqual(TodayScoresCopy.strainValue(.noHeartRate), "—")
        XCTAssertEqual(TodayScoresCopy.strainStatus(.noHeartRate), "No HR yet")
        XCTAssertEqual(TodayScoresCopy.strainAccessibility(.noHeartRate), "Strain unavailable. No heart rate yet today.")

        XCTAssertEqual(TodayScoresCopy.strainValue(.needsMinutes(soFar: 4)), "—")
        XCTAssertEqual(TodayScoresCopy.strainStatus(.needsMinutes(soFar: 4)), "4 of 10 min")
        XCTAssertEqual(TodayScoresCopy.strainAccessibility(.needsMinutes(soFar: 4)),
                       "Strain needs 10 minutes of heart rate, 4 so far.")

        XCTAssertEqual(TodayScoresCopy.strainValue(.needsRestingHR), "—")
        XCTAssertEqual(TodayScoresCopy.strainStatus(.needsRestingHR), "Needs resting HR")
        XCTAssertEqual(TodayScoresCopy.strainAccessibility(.needsRestingHR), "Strain needs a resting heart rate first.")

        XCTAssertEqual(TodayScoresCopy.strainValue(.loading), "—")
    }

    func testTheLabelsAndFooter() {
        XCTAssertEqual([TodayScoresCopy.sleepLabel, TodayScoresCopy.recoveryLabel, TodayScoresCopy.strainLabel],
                       ["SLEEP", "RECOVERY", "STRAIN"])
        XCTAssertEqual(TodayScoresCopy.footer, "On-device estimates · not medical advice")
        XCTAssertEqual(TodayScoresCopy.sleepHint, "Opens Sleep")
        XCTAssertEqual(TodayScoresCopy.recoveryHint, "Shows what went into recovery")
        XCTAssertEqual(TodayScoresCopy.strainHint, "Shows today's strain")
    }

    // MARK: I4 — a missing value is never a 0

    func testAMissingValueIsADashNeverAZero() {
        let values = [TodayScoresCopy.sleepValue(.noNight), TodayScoresCopy.sleepValue(.noScore),
                      TodayScoresCopy.recoveryValue(.noNight), TodayScoresCopy.recoveryValue(.noScore),
                      TodayScoresCopy.strainValue(.loading), TodayScoresCopy.strainValue(.noHeartRate),
                      TodayScoresCopy.strainValue(.needsMinutes(soFar: 0)), TodayScoresCopy.strainValue(.needsRestingHR)]
        for v in values {
            XCTAssertEqual(v, TodayScoresCopy.missing)
            XCTAssertFalse(v.contains("0"), v)
        }
        // A night with a score of 0 (never scored) is a dash too, all the way from the model.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let unscored = TodayScores.build(night: .init(nightKey: cal.startOfDay(for: at),
                                                      inBedStart: .distantPast, inBedEnd: .distantPast,
                                                      sleepScore: 0, stressScore: 0, asleepMin: 400),
                                         strain: nil, trendsLoaded: true, now: at, calendar: cal)
        XCTAssertEqual(unscored.sleep, .noScore)
        XCTAssertEqual(TodayScoresCopy.sleepValue(unscored.sleep), "—")
        XCTAssertEqual(TodayScoresCopy.recoveryValue(unscored.recovery), "—")
    }

    // MARK: I6 — only "No night yet" leads to a sync

    func testOnlyTheNoNightStateAdvisesASync() throws {
        let noSync = [
            TodayScoresCopy.sleepStatus(.noScore), TodayScoresCopy.sleepAccessibility(.noScore),
            TodayScoresCopy.recoveryStatus(.noScore), TodayScoresCopy.recoveryAccessibility(.noScore),
            TodayScoresCopy.detailGap(.noScore) ?? "",
            TodayScoresCopy.strainStatus(.noHeartRate), TodayScoresCopy.strainAccessibility(.noHeartRate),
            TodayScoresCopy.strainStatus(.needsMinutes(soFar: 4)), TodayScoresCopy.strainStatus(.needsRestingHR),
            TodayScoresCopy.sleepStatus(.noNight), TodayScoresCopy.recoveryStatus(.noNight),
        ]
        for s in noSync { XCTAssertFalse(s.localizedCaseInsensitiveContains("sync"), s) }
        XCTAssertNil(TodayScoresCopy.detailGap(try recovery(85, 33)))
        XCTAssertEqual(TodayScoresCopy.detailGap(.noNight), "Sync last night's sleep to see today's recovery.")
        XCTAssertEqual(TodayScoresCopy.detailGap(.noScore),
                       "Last night doesn't have a sleep score, so there's no recovery to show today.")
    }

    // MARK: I5 + D2 — no device names, and never "Readiness"

    func testNoCopyNamesADeviceOrSaysReadiness() throws {
        let scored = try recovery(85, 33)
        let strains: [TodayScores.Strain] = [.loading, .scored(reading(15.2, seconds: 9_000)), .noHeartRate,
                                              .needsMinutes(soFar: 4), .needsRestingHR]
        var words = [TodayScoresCopy.footer, TodayScoresCopy.footerAccessibility,
                     TodayScoresCopy.sleepHint, TodayScoresCopy.recoveryHint, TodayScoresCopy.strainHint,
                     TodayScoresCopy.detailBasis, TodayScoresCopy.detailSleepFactor, TodayScoresCopy.detailHRVFactor,
                     TodayScoresCopy.detailSleepAlone, TodayScoresCopy.detailMethod, TodayScoresCopy.detailShares()]
        for s: TodayScores.Sleep in [.scored(score: 85, asleepMin: 437), .noNight, .noScore] {
            words += [TodayScoresCopy.sleepStatus(s), TodayScoresCopy.sleepAccessibility(s)]
        }
        for r: TodayScores.Recovery in [scored, try recovery(52, nil), .noNight, .noScore] {
            words += [TodayScoresCopy.recoveryStatus(r), TodayScoresCopy.recoveryAccessibility(r),
                      TodayScoresCopy.detailGap(r) ?? ""]
        }
        for s in strains { words += [TodayScoresCopy.strainStatus(s), TodayScoresCopy.strainAccessibility(s)] }
        let device = try NSRegularExpression(pattern: "\\b(ring|rings|strap|straps)\\b", options: .caseInsensitive)
        for w in words {
            XCTAssertFalse(w.contains("Readiness") || w.contains("readiness"), w)
            XCTAssertNil(device.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)), w)
        }
    }

    /// VoiceOver never reads a doubled stop (".."), on the card or the Recovery detail.
    func testNoAccessibilityTextHasADoubledPeriod() throws {
        let recoveries: [TodayScores.Recovery] = [try recovery(85, 33), try recovery(52, nil), .noNight, .noScore]
        var spoken = recoveries.flatMap { [TodayScoresCopy.recoveryAccessibility($0), TodayScoresCopy.detailAccessibility($0)] }
        for s: TodayScores.Sleep in [.scored(score: 85, asleepMin: 437), .scored(score: 70, asleepMin: 0), .noNight, .noScore] {
            spoken.append(TodayScoresCopy.sleepAccessibility(s))
        }
        let strains: [TodayScores.Strain] = [.loading, .scored(reading(8.4, seconds: 5_400)), .noHeartRate,
                                              .needsMinutes(soFar: 4), .needsRestingHR]
        spoken += strains.map(TodayScoresCopy.strainAccessibility)
        spoken.append(TodayScoresCopy.footerAccessibility)
        for s in spoken { XCTAssertFalse(s.contains(".."), s) }
        XCTAssertEqual(TodayScoresCopy.detailAccessibility(.noNight),
                       "Recovery unavailable. Last night hasn't synced yet. Sync last night's sleep to see today's recovery.")
        XCTAssertEqual(TodayScoresCopy.detailAccessibility(try recovery(85, 33)), "Recovery, estimate, 82 out of 100, Good")
    }

    // MARK: Recovery detail

    func testTheSharesLineComesFromTheWeights() {
        let shares = WellnessBalance.recoveryShares
        XCTAssertEqual(TodayScoresCopy.detailShares(), "Sleep score counts \(shares.sleep)%, sleeping HRV \(shares.hrv)%.")
        XCTAssertEqual(TodayScoresCopy.detailShares(), "Sleep score counts 62%, sleeping HRV 38%.")
        XCTAssertEqual(TodayScoresCopy.detailShares(.init(sleep: 70, hrv: 30)), "Sleep score counts 70%, sleeping HRV 30%.")
    }

    func testTheDetailKeepsTheEstimateDisclaimer() {
        XCTAssertTrue(TodayScoresCopy.detailMethod.contains("not medical advice"))
        XCTAssertTrue(TodayScoresCopy.detailMethod.contains("estimate"))
        XCTAssertEqual(TodayScoresCopy.detailSleepAlone, "Based on last night's sleep alone: no sleeping HRV was recorded.")
    }

    // MARK: Methods text (App Review 1.4.1)

    /// The methods page must not claim inputs Recovery doesn't use (vitals, activity).
    func testTheRecoveryMethodsTextClaimsOnlyWhatItUses() throws {
        let source = try XCTUnwrap(HealthSources.all.first { $0.topic == .readiness })
        XCTAssertEqual(source.title, "Overnight stress and recovery")
        XCTAssertTrue(source.method.contains("Recovery combines last night's sleep score with overnight stress"))
        XCTAssertFalse(source.method.localizedCaseInsensitiveContains("vitals"))
        XCTAssertFalse(source.method.localizedCaseInsensitiveContains("activity"))
        XCTAssertFalse(source.method.contains("Readiness"))
    }
}
