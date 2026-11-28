import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// #396 review round 2: the rules of Today's one Vitals Status computation that the layout tests don't reach.
//   - Leaving Today before the first complete report never settles Recovery without a verdict; on return
//     the verdict arrives (the settle timer's cancelled sleep must not settle).
//   - The display-only card (`VitalsStatusCardView(report:)`) starts no loader of its own.
//   - A report is complete only once the Apple Health fallback has been tried, and a complete report always
//     reflects it, even when the fallback lands while an earlier analysis is still running.
// The Apple Health fallback is injected (`\.vitalsStatusLoader`), so nothing here reads Health. Hosted and
// synchronous, as `TodayVitalsHostedTests`. Every value, time and identifier is synthetic.

@MainActor
final class TodayVitalsLoaderTests: XCTestCase {
    private let ownership = OwnershipOverride()
    private var containers: [ModelContainer] = []
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-0000000396C3")
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

    private func wait(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { pump(0.05) }
    }

    // MARK: Fixtures

    /// Nine strap nights ending at `wake`, sleeping HRV every `hrvEvery` seconds: 60 ms, last night
    /// `lastNightHRV`. No heart-rate samples, so resting heart rate can only come from the fallback.
    private func store(lastNightHRV: Double, hrvEvery: TimeInterval = 300) throws -> LocalStore {
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
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            extras.skinTempC = 34.0
            extras.sleepScore = 85
            extras.stressScore = 33
            XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments),
                                                      night: SleepNightKey.night(inBedStart: bed, inBedEnd: end),
                                                      inBedStart: bed, inBedEnd: end, sleepOnset: bed, sleepWake: end,
                                                      extras: extras, device: strap), .inserted)
            for t in stride(from: bed.timeIntervalSince1970, to: end.timeIntervalSince1970, by: hrvEvery) {
                store.context.insert(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: Date(timeIntervalSince1970: t + 30),
                                                  end: Date(timeIntervalSince1970: t + 50),
                                                  value: k == 0 ? lastNightHRV : 60, deviceID: strap.rawValue))
            }
        }
        try store.context.save()
        return store
    }

    /// An Apple Health fallback whose resting heart rate is far above its own baseline today: with it, the
    /// verdict is an anomaly; without it (HRV and skin temperature in range), it is normal.
    private var raisedRestingHR: HealthKitVitalsBaselineReader.Report {
        let today = Calendar.current.startOfDay(for: wake)
        let days = (0..<20).map { k in
            HealthKitVitalsBaselineReader.DailyValue(day: today.addingTimeInterval(-Double(19 - k) * 86_400),
                                                     value: k == 19 ? 78 : [54, 55, 56][k % 3])
        }
        return .init(restingHR: days, overnightSpO2: [], overnightHRV: [], skinTempOffsetC: nil)
    }

    /// Opens once; a fallback waiting on it polls with a cancellable sleep.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        func release() { lock.lock(); open = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
        func wait() async throws {
            while !isOpen { try await Task.sleep(for: .milliseconds(20)) }
        }
    }

    private func dependencies(after delay: Duration = .zero, gate: Gate? = nil,
                              returning report: HealthKitVitalsBaselineReader.Report? = nil,
                              onStart: (@MainActor () -> Void)? = nil) -> VitalsStatusLoaderDependencies {
        var d = VitalsStatusLoaderDependencies()
        let empty = HealthKitVitalsBaselineReader.Report(restingHR: [], overnightSpO2: [], overnightHRV: [], skinTempOffsetC: nil)
        d.healthFallback = { _, _ in
            if let gate { try await gate.wait() }
            if delay > .zero { try await Task.sleep(for: delay) }
            return report ?? empty
        }
        d.onStart = onStart
        return d
    }

    private func host<V: View>(_ view: V, store: LocalStore, dependencies: VitalsStatusLoaderDependencies) -> UIWindow {
        let vc = UIHostingController(rootView: AnyView(view
            .environment(\.storeRefreshSignal, StoreRefreshSignal(interval: 60))
            .environment(\.vitalsStatusLoader, dependencies)
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

    private final class Log<T> { var items: [T] = [] }

    // MARK: Leaving Today in the first-report window (review round 2, SHOULD-FIX 1)

    @Observable final class TabModel {
        var tab = 0
        var events: [TodayVitals] = []
        var todayAppeared = false
    }

    struct Tabs: View {
        @Bindable var model: TabModel

        var body: some View {
            TabView(selection: $model.tab) {
                Color.clear
                    .background { TodayVitalsRunner(onChange: { model.events.append($0) }) }
                    .onAppear { model.todayAppeared = true }
                    .tabItem { Text("Today") }
                    .tag(0)
                Text("Sleep").tabItem { Text("Sleep") }.tag(1)
            }
        }
    }

    func testLeavingTodayBeforeTheFirstReportNeverSettlesWithoutAVerdict() throws {
        for run in 0..<3 {
            let model = TabModel()
            // The fallback takes 0.4 s, so no report is complete when Today is left at once.
            let window = host(Tabs(model: model), store: try store(lastNightHRV: 42),
                              dependencies: dependencies(after: .milliseconds(400)))
            wait(3) { model.todayAppeared }
            model.tab = 1
            pump(2.0)
            XCTAssertFalse(model.events.contains { $0.settled }, "run \(run): settled while Today was away: \(model.events)")
            model.tab = 0
            wait(10) { model.events.last.map { $0.settled && $0.report != nil } ?? false }
            close(window)

            let firstSettled = try XCTUnwrap(model.events.first { $0.settled }, "run \(run): never settled")
            XCTAssertNotNil(firstSettled.report, "run \(run): settled with no verdict first: \(model.events)")
            XCTAssertNotNil(model.events.last?.report, "run \(run): the verdict arrived on return: \(model.events)")
        }
    }

    /// Leaving Today while the Apple Health fallback is being read cuts that read short. It hasn't been
    /// tried: on return it is read again, and Recovery settles on the verdict that includes it, not on the
    /// local history alone (here normal, where the fallback's resting heart rate makes it an anomaly).
    func testLeavingTodayDuringTheFallbackReadDoesNotCountItAsTried() throws {
        for run in 0..<3 {
            let model = TabModel()
            let window = host(Tabs(model: model), store: try store(lastNightHRV: 60),
                              dependencies: dependencies(after: .milliseconds(400), returning: raisedRestingHR))
            wait(3) { model.todayAppeared }
            model.tab = 1
            pump(1.0)
            model.tab = 0
            wait(10) { model.events.last.map { $0.settled && $0.report?.status == .anomaly } ?? false }
            close(window)

            let firstSettled = try XCTUnwrap(model.events.first { $0.settled }, "run \(run): never settled")
            XCTAssertEqual(firstSettled.report?.status, .anomaly,
                           "run \(run): settled on the local history before the fallback: \(model.events)")
        }
    }

    // MARK: The display-only card runs no loader (review round 2, mB)

    private func loadersStarted<V: View>(_ view: V) throws -> Int {
        let starts = Log<Void>()
        let window = host(view, store: try store(lastNightHRV: 60),
                          dependencies: dependencies(onStart: { starts.items.append(()) }))
        pump(1.0)
        close(window)
        return starts.items.count
    }

    func testTheDisplayOnlyCardStartsNoLoader() throws {
        let report = VitalsBaseline.report([], skinTempOffsetC: 0.6)
        XCTAssertEqual(try loadersStarted(VitalsStatusCardView(report: report)), 0, "Today's card must not compute again")
        XCTAssertEqual(try loadersStarted(VitalsStatusCardView(report: nil)), 0, "not even before a verdict")
        // Controls: the self-loading card and Today's runner each start exactly one.
        XCTAssertEqual(try loadersStarted(VitalsStatusCardView()), 1)
        XCTAssertEqual(try loadersStarted(TodayVitalsRunner(onChange: { _ in })), 1)
    }

    // MARK: Complete means the fallback was tried (review round 2, mL)

    func testAReportIsCompleteOnlyOnceTheHealthFallbackHasBeenTried() throws {
        let results = Log<VitalsStatusLoader.Result>()
        let gate = Gate()
        let window = host(VitalsStatusLoader { results.items.append($0) }, store: try store(lastNightHRV: 60),
                          dependencies: dependencies(gate: gate, returning: raisedRestingHR))
        wait(5) { !results.items.isEmpty }
        pump(0.5)
        XCTAssertFalse(results.items.isEmpty, "the local history gave a report while the fallback was pending")
        XCTAssertFalse(results.items.contains { $0.isComplete }, "complete before the fallback was tried: \(results.items)")
        XCTAssertEqual(results.items.last?.report?.status, .normal, "local history alone")

        gate.release()
        wait(5) { results.items.contains { $0.isComplete } }
        close(window)
        let complete = try XCTUnwrap(results.items.first { $0.isComplete })
        XCTAssertEqual(complete.report?.status, .anomaly, "the complete report reflects the fallback")
    }

    func testAFailedFallbackStillCompletes() throws {
        let results = Log<VitalsStatusLoader.Result>()
        struct Unavailable: Error {}
        var d = VitalsStatusLoaderDependencies()
        d.healthFallback = { _, _ in throw Unavailable() }
        let window = host(VitalsStatusLoader { results.items.append($0) }, store: try store(lastNightHRV: 60), dependencies: d)
        wait(5) { results.items.contains { $0.isComplete } }
        close(window)
        XCTAssertEqual(results.items.last?.isComplete, true, "a fallback that fails has still been tried")
        XCTAssertEqual(results.items.last?.report?.status, .normal)
    }

    // MARK: A fallback landing mid-analysis (review round 2, SUSPICION 1)

    /// The first, local-only analysis is held in flight until the fallback has landed and the newer,
    /// fallback-informed analysis has published. The held one must then be dropped, not published as
    /// complete (or at all) over the newer report.
    func testAFallbackLandingMidAnalysisSupersedesTheAnalysisInFlight() throws {
        let results = Log<VitalsStatusLoader.Result>()
        let gate = Gate()
        var d = dependencies(gate: gate, returning: raisedRestingHR)
        d.beforeAnalysis = { hasFallback in
            guard !hasFallback else { return }
            gate.release()
            // Long enough for the fallback to land and the newer analysis to finish first.
            try? await Task.sleep(for: .milliseconds(1_200))
        }
        let window = host(VitalsStatusLoader { results.items.append($0) }, store: try store(lastNightHRV: 60), dependencies: d)
        wait(5) { results.items.contains { $0.isComplete } }
        pump(2.5) // past the held analysis
        close(window)

        let complete = try XCTUnwrap(results.items.first { $0.isComplete }, "never complete: \(results.items)")
        XCTAssertEqual(complete.report?.status, .anomaly, "the complete report reflects the fallback")
        for r in results.items where r.isComplete {
            XCTAssertEqual(r.report?.status, .anomaly, "a complete report without the fallback: \(results.items)")
        }
        XCTAssertEqual(results.items.last?.report?.status, .anomaly,
                       "the held local-only analysis was published over the newer report: \(results.items)")
        XCTAssertFalse(results.items.contains { $0.report?.status == .normal },
                       "the superseded local-only analysis was published at all: \(results.items)")
    }
}
