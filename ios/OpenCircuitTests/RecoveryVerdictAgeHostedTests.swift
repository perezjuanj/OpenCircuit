import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 98 (#410), end to end: Today's one `TodayVitalsRunner` over a seeded store, with
// `TodayScoresSource`. When last night's own values are in the store, the verdict is for that night and
// counted; when last night has no sleeping HRV or skin temperature, the verdict Vitals Status shows is an
// earlier night's, and Recovery is exactly the two-factor score. Every value, time and identifier is synthetic.

@MainActor
final class RecoveryVerdictAgeHostedTests: XCTestCase {
    private let ownership = OwnershipOverride()
    private var containers: [ModelContainer] = []
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-0000000410A1")
    /// Last night's wake, an hour ago on the minute; the scores read the day through a clock a minute after it.
    private let wake = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 3600)

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Nine strap nights, the newest ending at `wake`, each scored 85 with overnight stress 33 (82 without
    /// vitals). Sleeping HRV every 5 min (60 ms, 42 ms on the newest night) and skin temperature on every
    /// night, unless `lastNightHasVitals` is false: then the newest night has neither.
    private func store(lastNightHasVitals: Bool) throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        let store = LocalStore(container.mainContext)
        for k in 0...8 {
            let end = wake.addingTimeInterval(-Double(k) * 86_400), bed = end.addingTimeInterval(-8 * 3600)
            let segments = [SleepSegment(start: bed, end: end, stage: .inBed), SleepSegment(start: bed, end: end, stage: .asleepCore)]
            let vitals = k > 0 || lastNightHasVitals
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            extras.skinTempC = vitals ? 34.0 : 0
            extras.sleepScore = 85
            extras.stressScore = 33
            XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments),
                                                      night: SleepNightKey.night(inBedStart: bed, inBedEnd: end),
                                                      inBedStart: bed, inBedEnd: end, sleepOnset: bed, sleepWake: end,
                                                      extras: extras, device: strap), .inserted)
            guard vitals else { continue }
            for t in stride(from: bed.timeIntervalSince1970, to: end.timeIntervalSince1970, by: 300) {
                store.context.insert(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: Date(timeIntervalSince1970: t + 30),
                                                  end: Date(timeIntervalSince1970: t + 90), value: k == 0 ? 42 : 60,
                                                  deviceID: strap.rawValue))
            }
        }
        try store.context.save()
        return store
    }

    private final class Probe {
        var seen: [TodayScores] = []
        var vitals = TodayVitals.pending
    }

    private struct Today: View {
        let probe: Probe
        @State private var vitals = TodayVitals.pending

        var body: some View {
            TodayScoresSource(strain: nil, trendsLoaded: true, vitals: vitals) { scores in
                TodayScoresCard(scores: scores, sentence: "")
                    .onAppear { probe.seen.append(scores) }
                    .onChange(of: scores) { _, new in probe.seen.append(new) }
            }
            .background {
                TodayVitalsRunner(onChange: {
                    vitals = $0
                    probe.vitals = $0
                })
            }
        }
    }

    /// Hosts Today's runner and scores over the store until the vitals settle and have a verdict.
    private func run(lastNightHasVitals: Bool) throws -> Probe {
        let probe = Probe()
        AccessibilityTestSupport.enableAutomation()
        let clock = DayClock(now: { [wake] in wake.addingTimeInterval(60) }, calendar: { .current })
        let vc = UIHostingController(rootView: AnyView(Today(probe: probe)
            .environment(\.storeRefreshSignal, StoreRefreshSignal(interval: 60))
            .environment(\.dayClock, clock)
            .environment(\.vitalsStatusLoader, VitalsStatusLoaderDependencies(healthFallback: { _, _ in
                HealthKitVitalsBaselineReader.Report(restingHR: [], overnightSpO2: [], overnightHRV: [], skinTempOffsetC: nil)
            }))
            .modelContainer(try store(lastNightHasVitals: lastNightHasVitals).context.container)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(10)
        while !(probe.vitals.settled && probe.vitals.report != nil) && Date() < deadline { pump(0.25) }
        pump(1.0)
        window.rootViewController = nil
        window.isHidden = true
        pump(0.3)
        return probe
    }

    func testLastNightsOwnVerdictIsCounted() throws {
        let probe = try run(lastNightHasVitals: true)
        let report = try XCTUnwrap(probe.vitals.report, "the store's history gives a verdict")
        let lastNight = NightDate(Calendar.current.startOfDay(for: wake), calendar: .current)
        XCTAssertEqual(probe.vitals.nights, VitalsVerdictNights(lastNight), "dated to last night")
        let scores = try XCTUnwrap(probe.seen.last)
        let result = try XCTUnwrap(scores.recovery.result)
        XCTAssertNotNil(result.factors[.vitals])
        XCTAssertEqual(result.score, WellnessBalance.recoveryScore(sleepScore: 85, overnightStress: 33,
                                                                   vitalsStatus: report.status)?.score)
        XCTAssertNotEqual(result.score, 82)
        XCTAssertNil(scores.vitalsLeftOut)
    }

    func testAVerdictFromTheNightBeforeIsNotCounted() throws {
        let probe = try run(lastNightHasVitals: false)
        XCTAssertNotNil(probe.vitals.report, "Vitals Status still has a verdict, from the night before")
        let cal = Calendar.current
        let nightBefore = NightDate(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: wake))!, calendar: cal)
        XCTAssertEqual(probe.vitals.nights, VitalsVerdictNights(nightBefore))
        let scores = try XCTUnwrap(probe.seen.last)
        XCTAssertEqual(scores.recovery.result, WellnessBalance.anchoredScore(.init(sleepScore: 85, overnightStress: 33)))
        XCTAssertEqual(scores.recovery.result?.score, 82, "exactly the two-factor score")
        XCTAssertNil(scores.vitals)
        XCTAssertEqual(scores.vitalsLeftOut, .earlierNight)
        XCTAssertEqual(TodayScoresCopy.detailVitalsGap(scores.vitalsLeftOut), TodayScoresCopy.detailVitalsEarlier)
        // Never a three-factor number on the way.
        for seen in probe.seen { XCTAssertNil(seen.recovery.result?.factors[.vitals], "\(seen.recovery)") }
    }
}
