import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Decision 98 (#410): Recovery counts the Vitals Status verdict only when it is for the same night as the
// sleep score it is built on. Any other verdict is not passed to `recoveryScore`, so Recovery is exactly the
// two-factor score, and the ring, the detail, the sentence, VoiceOver and the widget snapshot show that one
// number. The detail says an older verdict is older, never that there is none.
//
// Every value is synthetic and every date is in the past.

@MainActor
final class RecoveryVerdictAgeTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private lazy var utc = calendar("UTC")
    /// 2026-05-28 14:13 UTC: an early afternoon, wholly in the past.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func night(score: Int = 85, stress: Int = 33, wakeHour: Double = 6.75, cal: Calendar? = nil) -> TodayScores.Night {
        let cal = cal ?? utc
        let wake = cal.startOfDay(for: now).addingTimeInterval(wakeHour * 3600)
        return .init(nightKey: SleepNightKey.night(inBedStart: wake.addingTimeInterval(-477 * 60), inBedEnd: wake, calendar: cal),
                     inBedStart: wake.addingTimeInterval(-477 * 60), inBedEnd: wake,
                     sleepScore: score, stressScore: stress, asleepMin: 437)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> NightDate { NightDate(year: y, month: m, day: d) }
    /// The day of `now` in UTC (2026-05-28), the night the sleep score is for.
    private var lastNight: NightDate { date(2026, 5, 28) }

    // Synthetic Vitals Status reports, built by the Kit's own rule.
    private let normal = VitalsBaseline.report([], skinTempOffsetC: 0.1)
    private let watch = VitalsBaseline.report([], skinTempOffsetC: 0.6)
    private let anomaly = VitalsBaseline.report(
        [.init(vital: .restingHR, today: 70, prior: [54, 55, 56, 54, 55, 56, 55, 54])], skinTempOffsetC: nil)

    private func build(_ n: TodayScores.Night? = nil, vitals: VitalsBaseline.Report?, nights: VitalsVerdictNights?,
                       cal: Calendar? = nil) -> TodayScores {
        TodayScores.build(night: n ?? night(), strain: nil, trendsLoaded: true, vitals: vitals,
                          vitalsNights: nights, now: now, calendar: cal ?? utc)
    }

    /// Sleep 85 and overnight stress 33 alone: the two-factor score.
    private var twoFactor: TodayScores { build(vitals: nil, nights: nil) }

    // MARK: The one pure function

    func testTheSameNightIsCounted() {
        let key = night().nightKey
        XCTAssertEqual(RecoveryVitalsAge.match(VitalsVerdictNights(lastNight), sleepNightKey: key, calendar: utc), .sameNight)
        for vitals in [normal, watch, anomaly] {
            let s = build(vitals: vitals, nights: VitalsVerdictNights(lastNight))
            XCTAssertEqual(s.recovery.result?.factors[.vitals] != nil, true, "counted: \(vitals.status)")
            XCTAssertEqual(s.recovery.result?.score,
                           WellnessBalance.recoveryScore(sleepScore: 85, overnightStress: 33, vitalsStatus: vitals.status)?.score)
            XCTAssertEqual(s.vitals, vitals)
            XCTAssertNil(s.vitalsLeftOut)
        }
    }

    func testTheNightBeforeIsNotCounted() {
        let key = night().nightKey
        let before = VitalsVerdictNights(date(2026, 5, 27))
        XCTAssertEqual(RecoveryVitalsAge.match(before, sleepNightKey: key, calendar: utc), .earlierNight)
        // Partly from the night before: still not the same night.
        let partly = VitalsVerdictNights(oldest: date(2026, 5, 27), newest: lastNight)
        XCTAssertEqual(RecoveryVitalsAge.match(partly, sleepNightKey: key, calendar: utc), .partlyEarlierNight)
        // A month earlier with the same day number is earlier, not the same night.
        XCTAssertEqual(RecoveryVitalsAge.match(VitalsVerdictNights(date(2026, 4, 28)), sleepNightKey: key, calendar: utc),
                       .earlierNight)
        for (nights, why) in [(before, RecoveryVitalsAge.Match.earlierNight), (partly, .partlyEarlierNight)] {
            for vitals in [normal, watch, anomaly] {
                let s = build(vitals: vitals, nights: nights)
                XCTAssertEqual(s.recovery, twoFactor.recovery, "exactly the two-factor score")
                XCTAssertEqual(s.report, twoFactor.report)
                XCTAssertNil(s.vitals)
                XCTAssertEqual(s.vitalsLeftOut, why)
            }
        }
    }

    func testNoVerdictIsTheTwoFactorScore() throws {
        let s = build(vitals: nil, nights: VitalsVerdictNights(lastNight))
        XCTAssertEqual(s, twoFactor, "nights without a verdict change nothing")
        XCTAssertNil(s.vitalsLeftOut, "no verdict is not a left-out verdict")
        let result = try XCTUnwrap(s.recovery.result)
        XCTAssertEqual(result, WellnessBalance.anchoredScore(.init(sleepScore: 85, overnightStress: 33)))
        XCTAssertEqual(result.score, 82)
        // A verdict with no known nights never counts.
        let undated = build(vitals: normal, nights: nil)
        XCTAssertEqual(undated.recovery, twoFactor.recovery)
        XCTAssertEqual(undated.vitalsLeftOut, .otherNight)
        XCTAssertEqual(RecoveryVitalsAge.match(nil, sleepNightKey: night().nightKey, calendar: utc), .otherNight)
    }

    func testAVerdictDatedAfterTheSleepScoresNightIsNotCounted() {
        let key = night().nightKey
        let after = VitalsVerdictNights(date(2026, 5, 29))
        XCTAssertEqual(RecoveryVitalsAge.match(after, sleepNightKey: key, calendar: utc), .otherNight)
        let straddling = VitalsVerdictNights(oldest: lastNight, newest: date(2026, 5, 29))
        XCTAssertEqual(RecoveryVitalsAge.match(straddling, sleepNightKey: key, calendar: utc), .otherNight)
        let s = build(vitals: watch, nights: after)
        XCTAssertEqual(s.recovery, twoFactor.recovery)
        XCTAssertEqual(s.vitalsLeftOut, .otherNight)
    }

    func testTheMidnightBoundary() {
        // A night that ends at 00:20 is filed under that day; a value from 23:50 the evening before is from
        // the day before, one from 00:05 is from the night.
        let n = night(wakeHour: 20.0 / 60)
        XCTAssertEqual(NightDate(n.nightKey, calendar: utc), lastNight)
        let evening = Date(timeIntervalSince1970: utc.startOfDay(for: now).timeIntervalSince1970 - 10 * 60)
        let justAfter = utc.startOfDay(for: now).addingTimeInterval(5 * 60)
        let before = VitalsVerdictNights(days: [utc.startOfDay(for: evening)], calendar: utc)
        let same = VitalsVerdictNights(days: [utc.startOfDay(for: justAfter)], calendar: utc)
        XCTAssertEqual(RecoveryVitalsAge.match(before, sleepNightKey: n.nightKey, calendar: utc), .earlierNight)
        XCTAssertEqual(RecoveryVitalsAge.match(same, sleepNightKey: n.nightKey, calendar: utc), .sameNight)
        XCTAssertEqual(build(n, vitals: normal, nights: before).recovery, build(n, vitals: nil, nights: nil).recovery)
        XCTAssertNotNil(build(n, vitals: normal, nights: same).recovery.result?.factors[.vitals])
        // The last instant of the evening and the first of the night.
        let lastInstant = VitalsVerdictNights(days: [utc.startOfDay(for: now).addingTimeInterval(-1)], calendar: utc)
        XCTAssertEqual(RecoveryVitalsAge.match(lastInstant, sleepNightKey: n.nightKey, calendar: utc), .earlierNight)
    }

    func testTheDateIsReadInTheCalendarPassedIn() {
        // Midnight in Zurich on 2026-05-28 is 22:00 UTC on the 27th: the same instant is a different date.
        let zurich = calendar("Europe/Zurich")
        let n = night(cal: zurich)
        XCTAssertEqual(NightDate(n.nightKey, calendar: zurich), lastNight)
        XCTAssertEqual(NightDate(n.nightKey, calendar: utc), date(2026, 5, 27))
        let verdict = VitalsVerdictNights(days: [zurich.startOfDay(for: n.inBedEnd)], calendar: zurich)
        XCTAssertEqual(verdict, VitalsVerdictNights(lastNight))
        XCTAssertEqual(RecoveryVitalsAge.match(verdict, sleepNightKey: n.nightKey, calendar: zurich), .sameNight)
        XCTAssertEqual(RecoveryVitalsAge.match(verdict, sleepNightKey: n.nightKey, calendar: utc), .otherNight)
        XCTAssertNotNil(build(n, vitals: watch, nights: verdict, cal: zurich).recovery.result?.factors[.vitals])
        // East of UTC too: midnight in Tokyo on the 28th is 15:00 UTC on the 27th.
        let tokyo = calendar("Asia/Tokyo")
        let t = night(cal: tokyo)
        let tv = VitalsVerdictNights(days: [tokyo.startOfDay(for: t.inBedEnd)], calendar: tokyo)
        XCTAssertEqual(RecoveryVitalsAge.match(tv, sleepNightKey: t.nightKey, calendar: tokyo), .sameNight)
    }

    func testATimeZoneChange() {
        // The night was filed in Zurich (its key is Zurich's midnight); the phone is now in New York.
        let zurich = calendar("Europe/Zurich"), newYork = calendar("America/New_York")
        let n = night(cal: zurich)
        // Today recomputes the verdict in New York: a value keyed by that stored night reads as the date
        // the key falls on there, and so does the sleep score's night. Same night: counted.
        let recomputed = VitalsVerdictNights(days: [newYork.startOfDay(for: n.nightKey)], calendar: newYork)
        XCTAssertEqual(RecoveryVitalsAge.match(recomputed, sleepNightKey: n.nightKey, calendar: newYork), .sameNight)
        // A verdict still dated in Zurich, judged in New York before it is recomputed, reads as a later date
        // than the key there: not counted, so a zone change never counts a verdict it can't place.
        let stillZurich = VitalsVerdictNights(days: [zurich.startOfDay(for: n.nightKey)], calendar: zurich)
        XCTAssertEqual(RecoveryVitalsAge.match(stillZurich, sleepNightKey: n.nightKey, calendar: newYork), .otherNight)
        // The night before, read in the new zone, is still the night before.
        let dayBefore = newYork.date(byAdding: .day, value: -1, to: newYork.startOfDay(for: n.nightKey))!
        XCTAssertEqual(RecoveryVitalsAge.match(VitalsVerdictNights(days: [dayBefore], calendar: newYork),
                                               sleepNightKey: n.nightKey, calendar: newYork), .earlierNight)
    }

    // MARK: The loader dates what it judged

    func testTheReportCarriesTheNightsOfTheValuesItJudged() throws {
        // Nine nights of skin temperature and sleeping HRV, filed under consecutive days in the local calendar.
        let cal = Calendar.current
        let lastKey = cal.startOfDay(for: now)
        func nights(skipLatestHRV: Bool) -> (hrv: [(start: Date, value: Double)],
                                             rows: [(night: Date, skinTempC: Double, inBedStart: Date, inBedEnd: Date)]) {
            var hrv: [(start: Date, value: Double)] = []
            var rows: [(night: Date, skinTempC: Double, inBedStart: Date, inBedEnd: Date)] = []
            for k in 0...8 {
                let key = cal.date(byAdding: .day, value: -k, to: lastKey)!
                let end = key.addingTimeInterval(6 * 3600), bed = end.addingTimeInterval(-8 * 3600)
                rows.append((night: key, skinTempC: 34.0, inBedStart: bed, inBedEnd: end))
                if !(skipLatestHRV && k == 0) { hrv.append((start: bed.addingTimeInterval(3600), value: k == 0 ? 42 : 60)) }
            }
            return (hrv, rows)
        }
        let full = nights(skipLatestHRV: false)
        let dated = try XCTUnwrap(VitalsStatusCardView.computeDatedReport(
            hr: [], spo2: [], hrv: full.hrv, nights: full.rows, fallbackRestingHR: nil, fallbackSpO2: nil,
            fallbackHRV: nil, fallbackSkinTempOffsetC: nil))
        XCTAssertEqual(dated.nights, VitalsVerdictNights(NightDate(lastKey, calendar: cal)))
        XCTAssertEqual(dated.report, VitalsStatusCardView.computeReport(
            hr: [], spo2: [], hrv: full.hrv, nights: full.rows, fallbackRestingHR: nil, fallbackSpO2: nil,
            fallbackHRV: nil, fallbackSkinTempOffsetC: nil), "the same report as before")

        // Last night has skin temperature but no sleeping HRV: the HRV judged is the night before's.
        let partly = nights(skipLatestHRV: true)
        let older = try XCTUnwrap(VitalsStatusCardView.computeDatedReport(
            hr: [], spo2: [], hrv: partly.hrv, nights: partly.rows, fallbackRestingHR: nil, fallbackSpO2: nil,
            fallbackHRV: nil, fallbackSkinTempOffsetC: nil))
        let dayBefore = cal.date(byAdding: .day, value: -1, to: lastKey)!
        XCTAssertEqual(older.nights, VitalsVerdictNights(oldest: NightDate(dayBefore, calendar: cal),
                                                         newest: NightDate(lastKey, calendar: cal)))
        XCTAssertEqual(RecoveryVitalsAge.match(older.nights, sleepNightKey: lastKey, calendar: cal), .partlyEarlierNight)

        // The Apple Health fallback's skin-temperature offset is dated by its own night.
        let fallbackOnly = try XCTUnwrap(VitalsStatusCardView.computeDatedReport(
            hr: [], spo2: [], hrv: [], nights: [], fallbackRestingHR: nil, fallbackSpO2: nil, fallbackHRV: nil,
            fallbackSkinTempOffsetC: 0.2, fallbackSkinTempNight: dayBefore))
        XCTAssertEqual(fallbackOnly.nights, VitalsVerdictNights(NightDate(dayBefore, calendar: cal)))
        // Without its night, the verdict has no known nights and never counts.
        let undated = try XCTUnwrap(VitalsStatusCardView.computeDatedReport(
            hr: [], spo2: [], hrv: [], nights: [], fallbackRestingHR: nil, fallbackSpO2: nil, fallbackHRV: nil,
            fallbackSkinTempOffsetC: 0.2))
        XCTAssertNil(undated.nights)
    }

    func testTheRunnerStateKeepsTheNewestNights() {
        let a = VitalsVerdictNights(date(2026, 5, 27)), b = VitalsVerdictNights(lastNight)
        var v = TodayVitals.pending
        v = v.receiving(.init(report: watch, isComplete: false, nights: a))
        XCTAssertEqual(v.nights, a)
        v = v.receiving(.init(report: normal, isComplete: true, nights: b))
        XCTAssertEqual(v.nights, b)
        v = v.receiving(.init(report: nil, isComplete: true))
        XCTAssertNil(v.nights, "no report, no nights")
    }

    // MARK: The detail's words

    func testTheDetailSaysAnOlderVerdictIsOlder() {
        XCTAssertEqual(TodayScoresCopy.detailVitalsEarlier, "Vitals are from an earlier night, so they aren't counted.")
        XCTAssertEqual(TodayScoresCopy.detailVitalsGap(.earlierNight), TodayScoresCopy.detailVitalsEarlier)
        XCTAssertEqual(TodayScoresCopy.detailVitalsGap(.partlyEarlierNight),
                       "Some vitals are from an earlier night, so they aren't counted.")
        XCTAssertEqual(TodayScoresCopy.detailVitalsGap(.otherNight), "Vitals aren't from last night, so they aren't counted.")
        XCTAssertEqual(TodayScoresCopy.detailVitalsGap(nil), TodayScoresCopy.detailNoVitals)
        for why: RecoveryVitalsAge.Match in [.earlierNight, .partlyEarlierNight, .otherNight] {
            let line = TodayScoresCopy.detailVitalsGap(why)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("no verdict"), line)
            XCTAssertFalse(line.contains(".."), line)
            let device = try? NSRegularExpression(pattern: "\\b(ring|rings|strap|straps)\\b", options: .caseInsensitive)
            XCTAssertNil(device?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
    }

    private func labels<V: View>(_ view: V) -> [String] {
        AccessibilityTestSupport.enableAutomation()
        let vc = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1600))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        vc.view.layoutIfNeeded()
        defer { window.isHidden = true }
        return AccessibilityTestSupport.labels(in: vc.view)
    }

    func testTheDetailNeverSaysNoVerdictYetWhenAnOlderOneExists() {
        let stale = build(vitals: watch, nights: VitalsVerdictNights(date(2026, 5, 27)))
        let detail = labels(NavigationStack { RecoveryDetailView(scores: stale) })
        XCTAssertTrue(detail.contains(TodayScoresCopy.detailVitalsEarlier), "\(detail)")
        XCTAssertFalse(detail.contains { $0.contains(TodayScoresCopy.detailNoVitals) }, "\(detail)")
        XCTAssertFalse(detail.contains { $0.hasPrefix("\(TodayScoresCopy.detailVitalsFactor), ") },
                       "no Vitals row for a verdict that wasn't counted: \(detail)")
        XCTAssertEqual(TodayScoresCopy.detailBasis(stale.recovery), TodayScoresCopy.detailBasis, "the basis is sleep alone")
        // With no verdict at all, it says that instead.
        let none = labels(NavigationStack { RecoveryDetailView(scores: twoFactor) })
        XCTAssertTrue(none.contains(TodayScoresCopy.detailNoVitals), "\(none)")
        XCTAssertFalse(none.contains(TodayScoresCopy.detailVitalsEarlier))
    }

    // MARK: One number everywhere

    private func sentence(_ s: TodayScores) -> String {
        TodaySynthesis.sentence(.init(readiness: s.report.readiness, hrv: nil, restingHR: nil,
                                      lastNightSleepMinutes: s.report.lastNightAsleepMin,
                                      newestDataAt: now, now: now,
                                      withoutSleepingHRV: s.report.withoutSleepingHRV))
    }

    func testRingDetailSentenceAndWidgetShowOneNumberWithAndWithoutACountedVerdict() throws {
        let cases: [(String, TodayScores, Int)] = [
            ("counted normal", build(vitals: normal, nights: VitalsVerdictNights(lastNight)), 86),
            ("counted watch", build(vitals: watch, nights: VitalsVerdictNights(lastNight)), 74),
            ("stale anomaly", build(vitals: anomaly, nights: VitalsVerdictNights(date(2026, 5, 27))), 82),
            ("stale normal", build(vitals: normal, nights: VitalsVerdictNights(oldest: date(2026, 5, 26), newest: lastNight)), 82),
            ("later watch", build(vitals: watch, nights: VitalsVerdictNights(date(2026, 5, 29))), 82),
            ("no verdict", twoFactor, 82),
        ]
        for (name, s, expected) in cases {
            let result = try XCTUnwrap(s.recovery.result, name)
            XCTAssertEqual(result.score, expected, name)
            let value = "\(expected)"
            XCTAssertEqual(TodayScoresCopy.recoveryValue(s.recovery), value, name)
            // The ring.
            let spoken = TodayScoresCopy.recoveryAccessibility(s.recovery)
            XCTAssertTrue(spoken.contains("\(value) out of 100"), "\(name): \(spoken)")
            let card = labels(TodayScoresCard(scores: s, sentence: sentence(s)))
            XCTAssertTrue(card.contains(spoken), "\(name) ring: \(card)")
            // The detail.
            let detail = labels(NavigationStack { RecoveryDetailView(scores: s) })
            XCTAssertTrue(detail.contains { $0.hasPrefix(spoken) }, "\(name) detail: \(detail)")
            XCTAssertTrue(TodayScoresCopy.detailAccessibility(s.recovery).contains("\(value) out of 100"), name)
            // The sentence.
            XCTAssertEqual(s.report.readiness, .scored(score: expected, tier: result.tier, factorCount: result.factors.count), name)
            XCTAssertTrue(sentence(s).contains(" \(value)"), "\(name): \(sentence(s))")
            // The widget snapshot.
            let snapshot = try XCTUnwrap(ScoresWidgetSnapshotBuilder.snapshot(s, at: now), name)
            XCTAssertEqual(snapshot.recovery.value, value, name)
            XCTAssertEqual(snapshot.recovery.spoken, spoken, name)
            XCTAssertEqual(snapshot.recovery.fill, Double(expected) / 100, name)
            XCTAssertEqual(snapshot.recovery.status, TodayScoresCopy.recoveryStatus(s.recovery), name)
            XCTAssertEqual(snapshot.recovery.dashed, s.recovery.isLowConfidence, name)
        }
    }

    // MARK: Methods text

    func testTheMethodsTextSaysTheVerdictMustBeForTheSameNight() throws {
        let source = try XCTUnwrap(HealthSources.all.first { $0.topic == .readiness })
        for text in [TodayScoresCopy.detailMethod, source.method] {
            XCTAssertTrue(text.contains("has a verdict for that same night"), text)
            XCTAssertFalse(text.contains("once Vitals Status has a verdict"), "claims every verdict counts: \(text)")
            XCTAssertFalse(text.contains("Until it has a verdict"), text)
            XCTAssertTrue(text.contains("Overnight HRV informs two of"), "the accepted double count is stated: \(text)")
            XCTAssertFalse(text.contains(".."), text)
        }
        XCTAssertTrue(source.method.contains("Without a verdict, or with one from another night, Recovery uses the first two alone."),
                      source.method)
    }
}
