import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Recovery's third factor (#396, decision 95a): Today's Vitals Status verdict. The ring, the Recovery
// detail and the sentence carry ONE number with or without it; a missing verdict is the two-factor
// score, never a 0; the copy says exactly what Recovery uses.
//
// Every value is synthetic and every date is in the past.

@MainActor
final class TodayScoresVitalsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-05-28 14:13 UTC: an early afternoon, wholly in the past.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func night(score: Int, stress: Int) -> TodayScores.Night {
        let wake = cal.startOfDay(for: now).addingTimeInterval(6.75 * 3600)
        return .init(nightKey: cal.startOfDay(for: wake), inBedStart: wake.addingTimeInterval(-477 * 60),
                     inBedEnd: wake, sleepScore: score, stressScore: stress, asleepMin: 437)
    }

    /// Amended for decision 98 (#410): a verdict counts only when it is dated to the night, so the
    /// helper's verdicts are dated to it (an undated one would not count).
    private func build(_ score: Int, _ stress: Int, vitals: VitalsBaseline.Report?, pending: Bool = false) -> TodayScores {
        let n = night(score: score, stress: stress)
        return TodayScores.build(night: n, strain: nil, trendsLoaded: true,
                                 vitals: vitals, vitalsNights: VitalsVerdictNights(NightDate(n.nightKey, calendar: cal)),
                                 vitalsPending: pending, now: now, calendar: cal)
    }

    // Synthetic Vitals Status reports, built by the Kit's own rule.
    private let normal = VitalsBaseline.report([], skinTempOffsetC: 0.1)
    private let watch = VitalsBaseline.report([], skinTempOffsetC: 0.6)
    private let anomaly = VitalsBaseline.report(
        [.init(vital: .restingHR, today: 70, prior: [54, 55, 56, 54, 55, 56, 55, 54])], skinTempOffsetC: nil)

    /// The sentence over the card's own report (Today maps it through `TodaySynthesis.input`, pinned below).
    private func sentence(_ s: TodayScores) -> String {
        TodaySynthesis.sentence(.init(readiness: s.report.readiness, hrv: nil, restingHR: nil,
                                      lastNightSleepMinutes: s.report.lastNightAsleepMin,
                                      newestDataAt: now, now: now,
                                      withoutSleepingHRV: s.report.withoutSleepingHRV))
    }

    func testTheSyntheticReportsHaveTheirVerdicts() {
        XCTAssertEqual(normal.status, .normal)
        XCTAssertEqual(watch.status, .watch)
        XCTAssertEqual(anomaly.status, .anomaly)
    }

    // MARK: One number

    func testEachVerdictIsOneNumberOnTheRingTheDetailAndTheSentence() throws {
        // Sleep 85, stress 33: 82 without vitals.
        let cases: [(VitalsBaseline.Report?, Int)] = [(nil, 82), (normal, 86), (watch, 74), (anomaly, 62)]
        for (vitals, expected) in cases {
            let s = build(85, 33, vitals: vitals)
            let ring = TodayScoresCopy.recoveryValue(s.recovery)
            XCTAssertEqual(ring, "\(expected)")
            guard case let .scored(score, _, factorCount) = s.report.readiness else {
                return XCTFail("the sentence lost its Recovery")
            }
            XCTAssertEqual(score, expected, "the sentence's number is the ring's")
            XCTAssertEqual(factorCount, vitals == nil ? 2 : 3)
            XCTAssertTrue(sentence(s).contains("\(expected)"), sentence(s))
            XCTAssertTrue(TodayScoresCopy.detailAccessibility(s.recovery).contains("\(expected) out of 100"))
        }
    }

    func testNoVerdictIsTheTwoFactorModelExactly() {
        let without = TodayScores.build(night: night(score: 85, stress: 33), strain: nil, trendsLoaded: true,
                                        now: now, calendar: cal)
        XCTAssertEqual(build(85, 33, vitals: nil), without)
        XCTAssertNil(without.vitals)
        XCTAssertNil(without.recovery.result?.factors[.vitals])
        // Sleep alone keeps the existing low-confidence treatment.
        let alone = build(52, 0, vitals: nil)
        XCTAssertTrue(alone.recovery.isLowConfidence)
        XCTAssertEqual(TodayScoresCopy.recoveryValue(alone.recovery), "52")
        XCTAssertEqual(TodayScoresCopy.detailFactorNote(alone.recovery), TodayScoresCopy.detailSleepAlone)
    }

    func testAnAnomalyNeverRaisesRecovery() {
        for score in [40, 70, 95] {
            for stress in [0, 20, 60] {
                let base = build(score, stress, vitals: nil).recovery.result!.score
                XCTAssertLessThanOrEqual(build(score, stress, vitals: anomaly).recovery.result!.score, base)
                XCTAssertGreaterThanOrEqual(build(score, stress, vitals: normal).recovery.result!.score, base)
            }
        }
    }

    func testTheModelKeepsTheReportOnlyWhenRecoveryCountedIt() {
        XCTAssertEqual(build(85, 33, vitals: watch).vitals, watch)
        let unscored = TodayScores.build(night: night(score: 0, stress: 33), strain: nil, trendsLoaded: true,
                                         vitals: watch, now: now, calendar: cal)
        XCTAssertNil(unscored.vitals)
        XCTAssertEqual(unscored.recovery, .noScore)
        let noNight = TodayScores.build(night: nil, strain: nil, trendsLoaded: true, vitals: anomaly,
                                        now: now, calendar: cal)
        XCTAssertEqual(noNight.recovery, .noNight)
    }

    // MARK: Detail copy

    func testTheFactorNoteSaysWhatWentIn() {
        XCTAssertEqual(TodayScoresCopy.detailFactorNote(build(85, 33, vitals: normal).recovery),
                       "Sleep score counts 47%, sleeping HRV 29%, vitals 24%.")
        XCTAssertEqual(TodayScoresCopy.detailFactorNote(build(85, 33, vitals: nil).recovery),
                       "Sleep score counts 62%, sleeping HRV 38%.")
        XCTAssertEqual(TodayScoresCopy.detailFactorNote(build(85, 0, vitals: normal).recovery),
                       TodayScoresCopy.detailSleepAndVitals)
        XCTAssertEqual(TodayScoresCopy.detailBasis(build(85, 33, vitals: normal).recovery),
                       "From last night's sleep and your vitals")
        XCTAssertEqual(TodayScoresCopy.detailBasis(build(85, 33, vitals: nil).recovery), "From last night's sleep")
    }

    func testTheVitalsRowShowsItsValues() {
        XCTAssertEqual(TodayScoresCopy.vitalsValues(normal, tempUnit: .celsius), ["All tracked vitals within your range"])
        let warm = TodayScoresCopy.vitalsValues(watch, tempUnit: .celsius)
        XCTAssertEqual(warm.count, 1)
        XCTAssertTrue(warm[0].hasPrefix("Skin temperature +0.6"), warm[0])
        XCTAssertTrue(warm[0].hasSuffix("vs your usual"), warm[0])
        let hr = TodayScoresCopy.vitalsValues(anomaly, tempUnit: .celsius)
        XCTAssertEqual(hr, ["Resting heart rate +15 bpm vs your usual 55 bpm"])
        XCTAssertEqual(TodayScoresCopy.vitalsAccessibility(anomaly, tempUnit: .celsius),
                       "Vitals vs your range, Anomaly. Resting heart rate +15 bpm vs your usual 55 bpm.")
    }

    // MARK: VoiceOver and words

    func testVoiceOverStrings() {
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(build(85, 33, vitals: normal).recovery),
                       "Recovery, estimate, 86 out of 100, Excellent")
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(build(85, 0, vitals: watch).recovery),
                       "Recovery, estimate, 73 out of 100, Good, based on last night's sleep and vitals alone, no sleeping HRV")
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(build(85, 33, vitals: nil, pending: true).recovery),
                       "Recovery, loading")
        XCTAssertEqual(TodayScoresCopy.recoveryAccessibility(build(52, 0, vitals: nil).recovery),
                       "Recovery, estimate, 52 out of 100, Needs improvement, based on last night's sleep alone")
    }

    func testNoDoubledStopsNoReadinessAndNoDeviceNames() throws {
        var words = [TodayScoresCopy.detailBasisWithVitals, TodayScoresCopy.detailVitalsFactor,
                     TodayScoresCopy.detailSleepAndVitals, TodayScoresCopy.detailNoVitals,
                     TodayScoresCopy.detailMethod, TodayScoresCopy.detailVitalsShares()]
        for report in [normal, watch, anomaly] {
            words.append(TodayScoresCopy.vitalsAccessibility(report, tempUnit: .fahrenheit))
            words += TodayScoresCopy.vitalsValues(report, tempUnit: .celsius)
            for stress in [0, 33] {
                let r = build(85, stress, vitals: report).recovery
                words += [TodayScoresCopy.recoveryAccessibility(r), TodayScoresCopy.detailAccessibility(r),
                          TodayScoresCopy.detailFactorNote(r) ?? ""]
            }
        }
        let device = try NSRegularExpression(pattern: "\\b(ring|rings|strap|straps)\\b", options: .caseInsensitive)
        for w in words {
            XCTAssertFalse(w.contains(".."), w)
            XCTAssertFalse(w.localizedCaseInsensitiveContains("readiness"), w)
            XCTAssertNil(device.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)), w)
        }
    }

    // MARK: Methods text

    func testTheMethodsTextSaysExactlyWhatRecoveryUses() throws {
        let source = try XCTUnwrap(HealthSources.all.first { $0.topic == .readiness })
        for input in ["sleep score", "sleeping HRV", "vitals against your own range"] {
            XCTAssertTrue(source.method.contains(input), "methods text lost \(input)")
        }
        XCTAssertTrue(TodayScoresCopy.detailMethod.contains("vitals against your own range"))
        for claim in ["activity", "strain", "steps", "exercise", "readiness"] {
            XCTAssertFalse(source.method.localizedCaseInsensitiveContains(claim), "methods text claims \(claim)")
            XCTAssertFalse(TodayScoresCopy.detailMethod.localizedCaseInsensitiveContains(claim), claim)
        }
        // Points at Vitals Status's own entry by its exact title, and never claims a source for SpO₂.
        let vitalsTitle = try XCTUnwrap(HealthSources.all.first { $0.topic == .skinTemperature }?.title)
        XCTAssertTrue(source.method.contains("\"\(vitalsTitle)\""), source.method)
        let covered = try XCTUnwrap(source.method.range(of: "The sources below cover"))
        XCTAssertFalse(source.method[covered.lowerBound...].contains("SpO"), "no source on the page covers SpO₂")
        XCTAssertFalse(source.method.contains("the sources cover its inputs"))
        XCTAssertTrue(source.citations.contains { $0.text.hasPrefix("Nanchen D (2018)") }, "resting heart rate is cited")
        // Cites only sources the page already lists under another topic.
        let elsewhere = Set(HealthSources.all.filter { $0.topic != .readiness }.flatMap { $0.citations.map(\.text) })
        for c in source.citations { XCTAssertTrue(elsewhere.contains(c.text), c.text) }
    }

    // MARK: Hosted: the ring and the detail read one model

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

    func testTheRingAndTheDetailShowTheSameNumberWithAndWithoutVitals() {
        for vitals in [nil, watch] {
            let s = build(85, 33, vitals: vitals)
            let expected = TodayScoresCopy.recoveryAccessibility(s.recovery)
            let card = labels(TodayScoresCard(scores: s, sentence: sentence(s)))
            XCTAssertTrue(card.contains(expected), "ring: \(card)")
            let detail = labels(NavigationStack { RecoveryDetailView(scores: s) })
            XCTAssertTrue(detail.contains { $0.hasPrefix(expected) }, "detail: \(detail)")
            let row = TodayScoresCopy.vitalsAccessibility(watch, tempUnit: .celsius)
            let unitless = detail.contains { $0.hasPrefix("Vitals vs your range, Watch") }
            XCTAssertEqual(unitless, vitals != nil, "the Vitals row shows only when counted: \(detail)")
            if vitals == nil { XCTAssertFalse(detail.contains(row)) }
        }
    }

    // MARK: Today's call sites

    /// Amended in fix round 1 (decision 95a, the hoist): the report now comes from Today's one runner,
    /// not from the card's row.
    func testTodayHandsTheVitalsReportToBothScoresSources() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenCircuit")
        let content = try String(contentsOf: app.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        let sources = content.components(separatedBy: "TodayScoresSource(").dropFirst()
        XCTAssertEqual(sources.count, 2)
        for s in sources { XCTAssertTrue(s.prefix(120).contains("vitals: todayVitals"), String(s.prefix(120))) }
        XCTAssertEqual(content.components(separatedBy: "TodayVitalsRunner(onChange: { todayVitals = $0 })").count, 2,
                       "exactly one runner feeds Recovery")
        XCTAssertTrue(content.contains("VitalsStatusCardView(report: todayVitals.report)"),
                      "Today's card displays the runner's report and runs no read of its own")
        XCTAssertFalse(content.contains("VitalsStatusCardView(onReport:"), "a second computation is back on Today")
    }

    // MARK: Low confidence (decision 95a: vitals never lift it)

    func testSleepAndVitalsWithoutHRVStaysLowConfidence() {
        for vitals in [normal, watch, anomaly] {
            let s = build(80, 0, vitals: vitals)
            XCTAssertTrue(s.recovery.isLowConfidence, "the ring stays dashed without sleeping HRV")
            XCTAssertTrue(s.recovery.isSleepAndVitalsOnly)
            XCTAssertTrue(s.report.withoutSleepingHRV)
            XCTAssertTrue(sentence(s).contains("based on last night's sleep and vitals alone"), sentence(s))
            XCTAssertTrue(TodayScoresCopy.recoveryAccessibility(s.recovery).hasSuffix("no sleeping HRV"))
            XCTAssertEqual(TodayScoresCopy.detailFactorNote(s.recovery), TodayScoresCopy.detailSleepAndVitals)
        }
        // Today's input carries the caveat from the card's report.
        XCTAssertTrue(TodaySynthesis.input(trends: TrendsData(), tiles: [], readiness: build(80, 0, vitals: normal).report,
                                           lastSyncAt: nil, now: now).withoutSleepingHRV)
        XCTAssertFalse(TodaySynthesis.input(trends: TrendsData(), tiles: [], readiness: build(80, 33, vitals: normal).report,
                                            lastSyncAt: nil, now: now).withoutSleepingHRV)
        // Sleep plus sleeping HRV is the solid ring, with or without vitals.
        for vitals in [nil, normal] {
            let s = build(80, 33, vitals: vitals)
            XCTAssertFalse(s.recovery.isLowConfidence)
            XCTAssertFalse(s.report.withoutSleepingHRV)
            XCTAssertFalse(sentence(s).contains(" alone"), sentence(s))
        }
        // Sleep alone keeps its own wording.
        let alone = build(80, 0, vitals: nil)
        XCTAssertTrue(alone.recovery.isLowConfidence)
        XCTAssertFalse(alone.recovery.isSleepAndVitalsOnly)
        XCTAssertTrue(sentence(alone).contains("based on last night's sleep alone"), sentence(alone))
    }

    // MARK: Pending (the first Vitals Status check hasn't finished)

    func testPendingVitalsHoldRecoveryInsteadOfShowingTheTwoFactorNumber() {
        let s = build(85, 33, vitals: nil, pending: true)
        XCTAssertEqual(s.recovery, .pending)
        XCTAssertEqual(s.report.readiness, .pending)
        XCTAssertEqual(TodayScoresCopy.recoveryValue(s.recovery), TodayScoresCopy.missing, "never a number that changes")
        XCTAssertFalse(sentence(s).contains("82"), sentence(s))
        XCTAssertEqual(TodayScoresCopy.detailGap(s.recovery), "Checking your vitals against your range.")
        XCTAssertFalse(TodayScoresCopy.detailAccessibility(s.recovery).contains(TodayScoresCopy.detailNoVitals))
        // Sleep is unaffected, and the no-night states win over pending.
        XCTAssertEqual(s.sleep, .scored(score: 85, asleepMin: 437))
        XCTAssertEqual(TodayScores.build(night: nil, strain: nil, trendsLoaded: true, vitalsPending: true,
                                         now: now, calendar: cal).recovery, .noNight)
        XCTAssertEqual(build(0, 33, vitals: nil, pending: true).recovery, .noScore)
    }

    func testTheVitalsStateSettlesOnceAndFollowsTheNewestReport() {
        var v = TodayVitals.pending
        v = v.receiving(.init(report: watch, isComplete: false))
        XCTAssertEqual(v, TodayVitals(report: watch, settled: false), "a local-only report waits for the fallback")
        v = v.receiving(.init(report: normal, isComplete: true))
        XCTAssertEqual(v, TodayVitals(report: normal, settled: true))
        v = v.receiving(.init(report: anomaly, isComplete: false))
        XCTAssertEqual(v, TodayVitals(report: anomaly, settled: true), "once settled it stays settled")
        XCTAssertEqual(TodayVitals.noVerdict, TodayVitals(report: nil, settled: true))
        XCTAssertGreaterThan(TodayVitalsRunner.settleTimeout, .zero)
    }
}
