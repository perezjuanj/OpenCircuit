import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The Today scores widget (#398): the snapshot codec, freshness, that the widget shows exactly what the
/// card shows, the deep links, and that the extension never computes a score. SYNTHETIC inputs only.
final class ScoresWidgetTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private lazy var today = cal.date(from: DateComponents(year: 2026, month: 3, day: 10))!
    private lazy var noon = today.addingTimeInterval(12 * 3600)

    private func night(daysAgo: Int = 0, score: Int, stress: Int, asleep: Int = 430) -> TodayScores.Night {
        let wake = today.addingTimeInterval(Double(-daysAgo) * 86_400 + 6.5 * 3600)
        return .init(nightKey: cal.startOfDay(for: wake), inBedStart: wake.addingTimeInterval(-Double(asleep + 30) * 60),
                     inBedEnd: wake, sleepScore: score, stressScore: stress, asleepMin: asleep)
    }

    private func strain(_ value: Double?, minutes: Int) -> DailyStrain.Reading {
        DailyStrain.Reading(strain: value, coveredSeconds: minutes * 60, latestSampleAt: minutes > 0 ? noon : nil,
                            maxHR: 185, restingHR: 54)
    }

    private func scores(_ n: TodayScores.Night?, _ s: DailyStrain.Reading?) -> TodayScores {
        TodayScores.build(night: n, strain: s, trendsLoaded: true, now: noon, calendar: cal)
    }

    /// Every card state the widget can be handed.
    private var allStates: [TodayScores] {
        [scores(night(score: 81, stress: 40), strain(12.4, minutes: 600)),
         scores(night(score: 52, stress: 0), strain(nil, minutes: 4)),
         scores(night(score: 0, stress: 0), strain(nil, minutes: 0)),
         scores(night(daysAgo: 1, score: 81, stress: 40), nil),
         scores(nil, strain(nil, minutes: 30)),
         scores(night(score: 95, stress: 10), strain(3.1, minutes: 300))]
    }

    private func roundTrip(_ s: TodayScores, at: Date? = nil, viewedAt: Date? = nil) throws -> ScoresWidgetDisplay {
        let snap = try XCTUnwrap(ScoresWidgetSnapshotBuilder.snapshot(s, at: at ?? noon))
        let data = try XCTUnwrap(ScoresWidgetCodec.encode(snap))
        let decoded = try XCTUnwrap(ScoresWidgetCodec.decode(data))
        XCTAssertEqual(decoded, snap)
        return ScoresWidgetDisplay.make(decoded, now: viewedAt ?? noon, calendar: cal)
    }

    // MARK: Codec

    func testRoundTripKeepsEveryDial() throws {
        let s = allStates[0]
        let snap = try XCTUnwrap(ScoresWidgetSnapshotBuilder.snapshot(s, at: noon))
        XCTAssertEqual(ScoresWidgetCodec.decode(try XCTUnwrap(ScoresWidgetCodec.encode(snap))), snap)
        XCTAssertEqual(snap.sleep.value, "81")
        XCTAssertEqual(snap.writtenAt, noon)
    }

    func testMissingValueIsAbsentAndDrawnAsADashNeverZero() throws {
        let s = scores(nil, strain(nil, minutes: 0))
        let snap = try XCTUnwrap(ScoresWidgetSnapshotBuilder.snapshot(s, at: noon))
        for dial in [snap.sleep, snap.recovery, snap.strain] {
            XCTAssertNil(dial.value)
            XCTAssertNil(dial.fill)
        }
        let json = try XCTUnwrap(String(data: try XCTUnwrap(ScoresWidgetCodec.encode(snap)), encoding: .utf8))
        XCTAssertFalse(json.contains("\"value\""), json)
        let display = try roundTrip(s)
        for dial in display.dials {
            XCTAssertEqual(dial.value, "—")
            XCTAssertNotEqual(dial.value, "0")
            XCTAssertNil(dial.fill)
        }
    }

    func testSnapshotCarriesOnlyTheThreeDialsAndTheirStates() throws {
        let snap = try XCTUnwrap(ScoresWidgetSnapshotBuilder.snapshot(allStates[0], at: noon))
        let data = try XCTUnwrap(ScoresWidgetCodec.encode(snap))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "at", "sleep", "recovery", "strain"])
        for key in ["sleep", "recovery", "strain"] {
            let dial = try XCTUnwrap(object[key] as? [String: Any])
            XCTAssertEqual(Set(dial.keys), ["value", "fill", "status", "tint", "dashed", "spoken"], key)
        }
    }

    func testDecoderRejectsUnknownVersionExtraKeysAndGarbage() throws {
        let snap = try XCTUnwrap(ScoresWidgetSnapshotBuilder.snapshot(allStates[0], at: noon))
        let data = try XCTUnwrap(ScoresWidgetCodec.encode(snap))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func decodes(_ o: [String: Any]) throws -> Bool {
            ScoresWidgetCodec.decode(try JSONSerialization.data(withJSONObject: o)) != nil
        }
        XCTAssertTrue(try decodes(object))

        var v2 = object; v2["v"] = 2
        XCTAssertFalse(try decodes(v2), "unknown version")
        var extra = object; extra["hrv"] = 61
        XCTAssertFalse(try decodes(extra), "extra top-level field")
        var noStrain = object; noStrain["strain"] = nil
        XCTAssertFalse(try decodes(noStrain), "missing dial")
        var sleep = try XCTUnwrap(object["sleep"] as? [String: Any])
        sleep["fill"] = 1.5
        object["sleep"] = sleep
        XCTAssertFalse(try decodes(object), "fill out of range")
        sleep["fill"] = 0.8; sleep["value"] = "—"
        object["sleep"] = sleep
        XCTAssertFalse(try decodes(object), "a dash stored as a value")
        sleep["value"] = "81"; sleep["score"] = 81
        object["sleep"] = sleep
        XCTAssertFalse(try decodes(object), "extra dial field")

        for garbage in [Data(), Data("null".utf8), Data("[]".utf8), Data("{\"v\":1}".utf8), Data([0xFF, 0x00, 0x13])] {
            XCTAssertNil(ScoresWidgetCodec.decode(garbage))
        }
    }

    func testNoSnapshotWhileStrainIsLoading() {
        let loading = TodayScores.build(night: night(score: 81, stress: 40), strain: nil, trendsLoaded: false,
                                        now: noon, calendar: cal)
        XCTAssertNil(ScoresWidgetSnapshotBuilder.snapshot(loading, at: noon))
    }

    // MARK: Freshness

    func testFreshnessCurrentStaleExpired() {
        XCTAssertEqual(ScoresWidgetFreshness.of(writtenAt: noon, now: noon + 3600, calendar: cal), .current)
        XCTAssertEqual(ScoresWidgetFreshness.of(writtenAt: noon, now: noon + 3 * 3600 + 1, calendar: cal), .stale)
        XCTAssertEqual(ScoresWidgetFreshness.of(writtenAt: noon - 86_400, now: noon, calendar: cal), .expired)
        XCTAssertEqual(ScoresWidgetFreshness.of(writtenAt: today + 23.9 * 3600, now: today + 24.1 * 3600,
                                                calendar: cal), .expired, "across midnight")
        XCTAssertEqual(ScoresWidgetFreshness.of(writtenAt: noon + 3600, now: noon, calendar: cal), .expired,
                       "written in the future")
        XCTAssertEqual(ScoresWidgetFreshness.of(writtenAt: nil, now: noon, calendar: cal), .none)
    }

    func testStaleSnapshotIsMarkedAndExpiredOneIsEmpty() throws {
        let stale = try roundTrip(allStates[0], at: noon, viewedAt: noon + 5 * 3600)
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertNotNil(stale.asOf)
        XCTAssertEqual(stale.dial(.sleep).value, "81", "a stale value is still today's, shown dimmed")
        XCTAssertTrue(stale.dial(.sleep).spoken.contains(try XCTUnwrap(stale.asOf)))

        let current = try roundTrip(allStates[0], at: noon, viewedAt: noon + 60)
        XCTAssertEqual(current.freshness, .current)
        XCTAssertNil(current.asOf)

        let expired = try roundTrip(allStates[0], at: noon, viewedAt: noon + 86_400)
        XCTAssertEqual(expired.freshness, .expired)
        XCTAssertTrue(expired.dials.allSatisfy { $0.value == "—" && $0.fill == nil })
        XCTAssertTrue(expired.dials.allSatisfy { $0.status == ScoresWidgetDisplay.notUpdatedToday })

        let none = ScoresWidgetDisplay.make(nil, now: noon, calendar: cal)
        XCTAssertTrue(none.dials.allSatisfy { $0.value == "—" && $0.status == ScoresWidgetDisplay.neverWritten })
    }

    func testRedrawDatesAreTheStaleMomentAndMidnight() {
        XCTAssertEqual(ScoresWidgetFreshness.changeDates(writtenAt: noon, after: noon, calendar: cal),
                       [noon + 3 * 3600, today + 86_400])
    }

    // MARK: Widget state == card state

    func testWidgetShowsExactlyWhatTheCardShows() throws {
        for s in allStates {
            let d = try roundTrip(s)
            XCTAssertEqual(d.freshness, .current)
            XCTAssertEqual(d.dials.map(\.kind), [.sleep, .recovery, .strain])
            XCTAssertEqual(d.dial(.sleep).value, TodayScoresCopy.sleepValue(s.sleep))
            XCTAssertEqual(d.dial(.sleep).status, TodayScoresCopy.sleepStatus(s.sleep))
            XCTAssertEqual(d.dial(.sleep).spoken, TodayScoresCopy.sleepAccessibility(s.sleep))
            XCTAssertEqual(d.dial(.sleep).label, TodayScoresCopy.sleepLabel)
            XCTAssertEqual(d.dial(.sleep).fill, s.sleepFill)
            XCTAssertEqual(d.dial(.recovery).value, TodayScoresCopy.recoveryValue(s.recovery))
            XCTAssertEqual(d.dial(.recovery).status, TodayScoresCopy.recoveryStatus(s.recovery))
            XCTAssertEqual(d.dial(.recovery).spoken, TodayScoresCopy.recoveryAccessibility(s.recovery))
            XCTAssertEqual(d.dial(.recovery).label, TodayScoresCopy.recoveryLabel)
            XCTAssertEqual(d.dial(.recovery).fill, s.recoveryFill)
            XCTAssertEqual(d.dial(.recovery).dashed, s.recovery.isLowConfidence)
            XCTAssertEqual(d.dial(.strain).value, TodayScoresCopy.strainValue(s.strain))
            XCTAssertEqual(d.dial(.strain).status, TodayScoresCopy.strainStatus(s.strain))
            XCTAssertEqual(d.dial(.strain).spoken, TodayScoresCopy.strainAccessibility(s.strain))
            XCTAssertEqual(d.dial(.strain).label, TodayScoresCopy.strainLabel)
            XCTAssertEqual(d.dial(.strain).fill, s.strainFill)
        }
        // The fills are the card's own: score / 100 and the strain gauge.
        let s = allStates[0]
        XCTAssertEqual(s.sleepFill, 0.81)
        XCTAssertEqual(s.recoveryFill, s.recovery.result.map { Double($0.score) / 100 })
        if case let .scored(reading) = s.strain { XCTAssertEqual(s.strainFill, reading.gaugeFraction) }
        else { XCTFail("strain should be scored") }
    }

    func testRecoveryTintFollowsTheTierAndPaletteMatchesTheTheme() throws {
        for s in allStates {
            let tint = ScoresWidgetSnapshotBuilder.recoveryTint(s.recovery)
            XCTAssertEqual(try roundTrip(s).dial(.recovery).tint, tint)
            switch s.recovery.result?.tier {
            case .excellent?: XCTAssertEqual(tint, .recoveryExcellent)
            case .good?: XCTAssertEqual(tint, .recoveryGood)
            case .needsImprovement?: XCTAssertEqual(tint, .recoveryNeedsImprovement)
            case nil: XCTAssertEqual(tint, .recoveryNone)
            }
        }
        let pairs: [(ScoresWidgetSnapshot.Tint, Color)] = [
            (.sleep, Theme.sleep), (.strain, Theme.energy), (.recoveryNone, Theme.readiness),
            (.recoveryExcellent, WellnessBalance.Tier.excellent.ringColor),
            (.recoveryGood, WellnessBalance.Tier.good.ringColor),
            (.recoveryNeedsImprovement, WellnessBalance.Tier.needsImprovement.ringColor)]
        for (tint, theme) in pairs {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                XCTAssertEqual(UIColor(ScoresWidgetPalette.color(tint)).resolvedColor(with: traits),
                               UIColor(theme).resolvedColor(with: traits), "\(tint) \(style.rawValue)")
            }
        }
    }

    func testCardWordsAreTheSharedWords() {
        XCTAssertEqual(TodayScoresCopy.missing, TodayScoresWords.missing)
        XCTAssertEqual(TodayScoresCopy.footer, TodayScoresWords.footer)
        XCTAssertTrue(TodayScoresWords.footer.contains("not medical advice"))
    }

    // MARK: The widget draws what was stored

    /// SF-2: a value that disagrees with its fill. Computing either from the other would show here; the
    /// parity test can't tell, because a real snapshot's fill is exactly its score / 100.
    func testWidgetDrawsTheStoredValueAndFillNeverOneFromTheOther() throws {
        func dial(_ value: String?, _ fill: Double?, _ tint: ScoresWidgetSnapshot.Tint) -> ScoresWidgetSnapshot.Dial {
            .init(value: value, fill: fill, status: "Stored status", tint: tint, dashed: false, spoken: "Stored words")
        }
        let snap = ScoresWidgetSnapshot(version: ScoresWidgetSnapshot.currentVersion, writtenAt: noon,
                                        sleep: dial("81", 0.5, .sleep), recovery: dial("40", 0.9, .recoveryGood),
                                        strain: dial("12.4", 0.25, .strain))
        let decoded = try XCTUnwrap(ScoresWidgetCodec.decode(try XCTUnwrap(ScoresWidgetCodec.encode(snap))))
        let d = ScoresWidgetDisplay.make(decoded, now: noon + 60, calendar: cal)
        XCTAssertEqual(d.dials.map(\.value), ["81", "40", "12.4"])
        XCTAssertEqual(d.dials.map(\.fill), [0.5, 0.9, 0.25])
        XCTAssertEqual(d.dials.map(\.status), ["Stored status", "Stored status", "Stored status"])
        XCTAssertEqual(d.dials.map(\.spoken), ["Stored words", "Stored words", "Stored words"])
        XCTAssertEqual(d.dials.map(\.tint), [.sleep, .recoveryGood, .strain])
    }

    // MARK: Stale is drawn as stale

    /// SF-3: the dimming is decided once, in `ScoresShared`, and every dial carries it.
    func testOnlyAStaleSnapshotIsDimmed() throws {
        let stale = try roundTrip(allStates[0], at: noon, viewedAt: noon + 5 * 3600)
        XCTAssertTrue(stale.isDimmed)
        XCTAssertTrue(stale.dials.allSatisfy(\.isDimmed))
        XCTAssertTrue(ScoresWidgetDial.Kind.allCases.allSatisfy { stale.dial($0).isDimmed })
        for viewedAt in [noon + 60, noon + 86_400] {
            let d = try roundTrip(allStates[0], at: noon, viewedAt: viewedAt)
            XCTAssertFalse(d.isDimmed)
            XCTAssertFalse(d.dials.contains(where: \.isDimmed))
        }
        XCTAssertFalse(ScoresWidgetDisplay.make(nil, now: noon, calendar: cal).dials.contains(where: \.isDimmed))
    }

    /// SF-3: every size draws a stale snapshot differently from the same snapshot while current. The
    /// lock-screen circle shows it by dimming alone, so a view that ignores staleness renders identically.
    @MainActor
    func testEveryWidgetSizeDrawsStaleDifferently() throws {
        let current = try roundTrip(allStates[0], at: noon, viewedAt: noon + 60)
        let stale = try roundTrip(allStates[0], at: noon, viewedAt: noon + 5 * 3600)
        XCTAssertEqual(current.dials.map(\.value), stale.dials.map(\.value))
        func png(_ view: some View, _ w: CGFloat, _ h: CGFloat) throws -> Data {
            let renderer = ImageRenderer(content: view.frame(width: w, height: h))
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        XCTAssertNotEqual(try png(ScoresWidgetSmallView(display: current), 140, 140),
                          try png(ScoresWidgetSmallView(display: stale), 140, 140), "small")
        XCTAssertNotEqual(try png(ScoresWidgetMediumView(display: current), 330, 140),
                          try png(ScoresWidgetMediumView(display: stale), 330, 140), "medium")
        XCTAssertNotEqual(try png(ScoresWidgetRectangularView(display: current), 172, 76),
                          try png(ScoresWidgetRectangularView(display: stale), 172, 76), "rectangular")
        XCTAssertNotNil(stale.asOf, "the rectangular widget's visible mark")
        for kind in ScoresWidgetDial.Kind.allCases {
            XCTAssertNotEqual(try png(ScoresWidgetCircularView(dial: current.dial(kind)), 76, 76),
                              try png(ScoresWidgetCircularView(dial: stale.dial(kind)), 76, 76), "circle \(kind)")
        }
    }

    // MARK: Deep links

    func testDeepLinksOpenEachDialsScreen() throws {
        let cases: [(String, ScoresQuickLink.Route, ScoresLinkDestination)] = [
            ("opencircuit://today", .today, .today(path: [])),
            ("opencircuit://today/sleep", .sleep, .sleepTab),
            ("opencircuit://today/recovery", .recovery, .today(path: [.recovery])),
            ("opencircuit://today/strain", .strain, .today(path: [.strain])),
            ("opencircuit://today/sources", .sources, .today(path: [.sources]))]
        for (string, route, destination) in cases {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertEqual(ScoresQuickLink.parse(url), route, string)
            XCTAssertEqual(ScoresQuickLink.url(route), url)
            XCTAssertEqual(ScoresQuickLink.destination(route), destination, string)
        }
        XCTAssertEqual(ScoresWidgetDisplay.make(nil, now: noon).dials.map(\.route), [.sleep, .recovery, .strain])
        for other in ["opencircuit://today/hrv", "opencircuit://today/today", "opencircuit://today/sleep/x",
                      "opencircuit://workout/active", "opencircuit://headache/log?when=now",
                      "https://today/sleep", "opencircuit://today/sleep?x=1"] {
            XCTAssertNil(ScoresQuickLink.parse(try XCTUnwrap(URL(string: other))), other)
        }
        XCTAssertTrue(WorkoutQuickLink.isActiveSession(WorkoutQuickLink.activeSession))
        XCTAssertNil(ScoresQuickLink.parse(WorkoutQuickLink.activeSession))
    }

    // MARK: The extension never computes

    private var iosDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    func testWidgetSourcesComputeNoScore() throws {
        let fm = FileManager.default
        var checked = 0
        for folder in ["ScoresWidget", "ScoresShared"] {
            let dir = iosDir.appendingPathComponent(folder)
            for name in try fm.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let source = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                for banned in ["import OpenCircuitKit", "WellnessBalance", "DailyStrain", "SleepScore", "SleepStress",
                               "TodayScores.build", "recoveryScore", "StoredSleepSummary", "SwiftData", "HealthKit",
                               "gaugeFraction"] {
                    XCTAssertFalse(code.contains(banned), "\(folder)/\(name) mentions \(banned)")
                }
                // No arithmetic turns a stored value into a number: the value is drawn as stored text.
                let compact = code.replacingOccurrences(of: " ", with: "")
                XCTAssertFalse(compact.contains("Int(dial.value") || compact.contains("Double(dial.value")
                               || compact.contains("/100") || compact.contains("*100"),
                               "\(folder)/\(name) derives a number")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3)

        let yml = try String(contentsOf: iosDir.appendingPathComponent("project.yml"), encoding: .utf8)
        let target = try XCTUnwrap(yml.components(separatedBy: "\n  ScoresWidget:\n").dropFirst().first)
        let block = try XCTUnwrap(target.components(separatedBy: "\n  OpenCircuitTests:").first)
        XCTAssertFalse(block.contains("dependencies:"), "the extension links nothing but system frameworks")
        XCTAssertFalse(block.contains("OpenCircuitKit\n"), "no Kit in the extension")
    }
}
