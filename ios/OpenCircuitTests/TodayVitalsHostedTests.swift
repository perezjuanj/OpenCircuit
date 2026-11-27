import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// #396 fix round 1 (decision 95a): Recovery's Vitals Status verdict must not depend on where the Vitals
// Status card's row is. Hosted over a store whose history gives a verdict, with Today's own pieces (the one
// `TodayVitalsRunner` behind the list, `TodayScoresSource`, the display-only card): the card shown below the
// fold (never built by the lazy list), hidden, or first must all give the same Recovery, counted with
// vitals, and never the two-factor number first. Synchronous on purpose (as
// `StrapLeadInViewCallLineHostedTests`). Every value, time and identifier is synthetic.

@MainActor
final class TodayVitalsHostedTests: XCTestCase {
    private let ownership = OwnershipOverride()
    private var containers: [ModelContainer] = []
    private let calendar = Calendar.current
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-0000000396A1")
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

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    /// Nine strap nights, the newest ending at `wake`, each scored 85 with overnight stress 33 (82 without
    /// vitals); sleeping HRV every 5 min, 60 ms, last night 42 ms, so Vitals Status has a verdict.
    private func vitalsStore() throws -> LocalStore {
        let store = try makeStore()
        for k in 0...8 {
            let end = wake.addingTimeInterval(-Double(k) * 86_400), bed = end.addingTimeInterval(-8 * 3600)
            let segments = [SleepSegment(start: bed, end: end, stage: .inBed), SleepSegment(start: bed, end: end, stage: .asleepCore)]
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            extras.skinTempC = 34.0
            extras.sleepScore = 85
            extras.stressScore = 33
            XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments),
                                                      night: SleepNightKey.night(inBedStart: bed, inBedEnd: end),
                                                      inBedStart: bed, inBedEnd: end, sleepOnset: bed, sleepWake: end,
                                                      extras: extras, device: strap), .inserted)
            for t in stride(from: bed.timeIntervalSince1970, to: end.timeIntervalSince1970, by: 300) {
                store.context.insert(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: Date(timeIntervalSince1970: t + 30),
                                                  end: Date(timeIntervalSince1970: t + 90), value: k == 0 ? 42 : 60,
                                                  deviceID: strap.rawValue))
            }
        }
        try store.context.save()
        return store
    }

    // MARK: Harness: Today's pieces in a lazy list

    private enum Placement { case belowFold, hidden, first }

    private final class Probe {
        var seen: [TodayScores] = []
        var cardBuilt = false
        var vitals = TodayVitals.pending
        var latest: TodayScores? { seen.last }
    }

    private struct Today: View {
        let placement: Placement
        let probe: Probe
        @State private var vitals = TodayVitals.pending

        var body: some View {
            List {
                if placement == .first { card }
                TodayScoresSource(strain: nil, trendsLoaded: true, vitals: vitals) { scores in
                    TodayScoresCard(scores: scores, sentence: "")
                        .onAppear { probe.seen.append(scores) }
                        .onChange(of: scores) { _, new in probe.seen.append(new) }
                }
                ForEach(0..<30, id: \.self) { _ in Color.gray.frame(height: 220) }
                if placement == .belowFold { card }
            }
            .background {
                TodayVitalsRunner(onChange: {
                    vitals = $0
                    probe.vitals = $0
                })
            }
        }

        private var card: some View {
            VitalsStatusCardView(report: vitals.report).onAppear { probe.cardBuilt = true }
        }
    }

    private func host<V: View>(_ view: V, store: LocalStore) -> UIWindow {
        AccessibilityTestSupport.enableAutomation()
        let clock = DayClock(now: { [wake] in wake.addingTimeInterval(60) }, calendar: { .current })
        let vc = UIHostingController(rootView: AnyView(view
            .environment(\.storeRefreshSignal, StoreRefreshSignal(interval: 60))
            .environment(\.dayClock, clock)
            .modelContainer(store.context.container)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
        pump(0.3)
    }

    /// Hosts Today with the card at `placement` until the vitals settle (at most past the runner's timeout).
    private func run(_ placement: Placement) throws -> Probe {
        let probe = Probe()
        let window = host(Today(placement: placement, probe: probe), store: try vitalsStore())
        let deadline = Date().addingTimeInterval(10)
        while !probe.vitals.settled && Date() < deadline { pump(0.25) }
        pump(1.0)
        close(window)
        return probe
    }

    // MARK: One Recovery whatever the layout

    func testRecoveryIsTheSameWhetherTheCardIsBelowTheFoldHiddenOrFirst() throws {
        let below = try run(.belowFold), hidden = try run(.hidden), first = try run(.first)
        XCTAssertFalse(below.cardBuilt, "the scenario: a shown card below the fold that the lazy list never built")
        XCTAssertTrue(first.cardBuilt)

        var numbers: [Int] = []
        for (name, probe) in [("below the fold", below), ("hidden", hidden), ("first", first)] {
            XCTAssertTrue(probe.vitals.settled, name)
            let report = try XCTUnwrap(probe.vitals.report, "\(name): the store's history gives a verdict")
            let scores = try XCTUnwrap(probe.latest, name)
            let result = try XCTUnwrap(scores.recovery.result, "\(name): Recovery is scored")
            XCTAssertNotNil(result.factors[.vitals], "\(name): the verdict was counted")
            XCTAssertEqual(scores.vitals, report)
            XCTAssertEqual(result.score, WellnessBalance.recoveryScore(sleepScore: 85, overnightStress: 33,
                                                                       vitalsStatus: report.status)?.score, name)
            XCTAssertEqual(scores.report.readiness, .scored(score: result.score, tier: result.tier, factorCount: 3), name)
            // Never the two-factor number first: before the verdict Recovery waits.
            for seen in probe.seen {
                XCTAssertTrue(seen.recovery == .pending || seen.recovery.result?.factors[.vitals] != nil,
                              "\(name): showed \(seen.recovery) before the verdict")
            }
            numbers.append(result.score)
        }
        XCTAssertEqual(Set(numbers).count, 1, "one Recovery for every layout: \(numbers)")
        XCTAssertNotEqual(numbers.first, 82, "the verdict moved the two-factor 82")
    }

    // MARK: The detail with a verdict in the data

    func testTheDetailNeverSaysNoVerdictWhenTheDataHasOne() throws {
        let probe = try run(.belowFold)
        let scores = try XCTUnwrap(probe.latest)
        XCTAssertNotNil(probe.vitals.report)
        let vc = UIHostingController(rootView: AnyView(NavigationStack { RecoveryDetailView(scores: scores) }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_600))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        pump(1.5)
        let labels = AccessibilityTestSupport.labels(in: vc.view)
        close(window)
        XCTAssertFalse(labels.contains { $0.contains(TodayScoresCopy.detailNoVitals) }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("\(TodayScoresCopy.detailVitalsFactor), ") }, "the Vitals row: \(labels)")
        // While the first check runs, the detail says it is checking, not that there is no verdict.
        let pending = TodayScores.build(night: .init(nightKey: wake, inBedStart: wake.addingTimeInterval(-8 * 3600),
                                                     inBedEnd: wake, sleepScore: 85, stressScore: 33, asleepMin: 440),
                                        strain: nil, trendsLoaded: true, vitalsPending: true,
                                        now: wake.addingTimeInterval(60))
        XCTAssertEqual(pending.recovery, .pending)
        XCTAssertNotEqual(TodayScoresCopy.detailGap(pending.recovery), TodayScoresCopy.detailNoVitals)
    }
}
