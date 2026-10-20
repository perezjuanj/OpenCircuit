import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Decision 75d (i): what 20 sync-sized saves cost the main thread while the Today cards are on
/// screen, on a store seeded to owner size (32 days: 25,800 heart-rate, 7,000 HRV and 3,300 SpO₂
/// rows, 2,200 of the heart-rate rows today, 1,800 step minutes over two days; rounded synthetic
/// values). Reports main-thread busy time per save and the longest single main-thread stall.
///
/// Opt-in, because it is a measurement and not a check: it runs only with `OC_BENCH=1` in the test
/// runner's environment (`TEST_RUNNER_OC_BENCH=1 xcodebuild test …`), and prints its table.
@MainActor
final class SyncSaveMainThreadBenchmarkTests: XCTestCase {

    /// How the benchmark tells the app a sync started and ended (no-ops on build 84, which had no
    /// notion of it).
    @MainActor private enum SyncHooks {
        static func begin() { StoreRefreshSignal.shared.setSyncActive(true) }
        static func end() { StoreRefreshSignal.shared.setSyncActive(false) }
    }

    private static let saves = 20
    private static let samplesPerSave = 60
    private static let gapAfterSave: TimeInterval = 0.5

    /// Every container stays alive until the test ends: a hosted view outliving its container traps.
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeContainer() throws -> ModelContainer {
        let c = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self,
            StoredNap.self, StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return c
    }

    /// The owner-sized store. Values are rounded and synthetic.
    private func seed(_ store: LocalStore, now: Date) throws -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let firstDay = today.addingTimeInterval(-31 * 86_400)
        // Today's heart rate ends 25 minutes ago, so the scripted saves land after it.
        let todayEnd = now.addingTimeInterval(-25 * 60)
        var hr: [QuantitySample] = []
        let earlierPerDay = (25_800 - 2_200) / 31
        for d in 0..<31 {
            let day = firstDay.addingTimeInterval(Double(d) * 86_400)
            let step = 86_400 / Double(earlierPerDay)
            for i in 0..<earlierPerDay {
                let t = day.addingTimeInterval(Double(i) * step)
                hr.append(QuantitySample(kind: .heartRate, start: t, end: t.addingTimeInterval(60),
                                         value: Double(60 + (i % 5) * 5)))
            }
        }
        let todayStep = max(todayEnd.timeIntervalSince(today), 2_200) / 2_200
        for i in 0..<2_200 {
            let t = min(today.addingTimeInterval(Double(i) * todayStep), todayEnd)
            hr.append(QuantitySample(kind: .heartRate, start: t, end: t.addingTimeInterval(1), value: Double(70 + (i % 4) * 5)))
        }
        var hrv: [QuantitySample] = []
        var spo2: [QuantitySample] = []
        var nights: [StoredSleepSummary] = []
        for d in 0..<32 {
            let wake = firstDay.addingTimeInterval(Double(d) * 86_400 + 7 * 3_600)
            let bed = wake.addingTimeInterval(-8 * 3_600)
            for i in 0..<218 {
                let t = bed.addingTimeInterval(Double(i) * 132)
                hrv.append(QuantitySample(kind: .hrvSDNN, start: t, end: t.addingTimeInterval(60), value: Double(40 + (i % 3) * 10)))
            }
            for i in 0..<103 {
                let t = bed.addingTimeInterval(Double(i) * 280)
                spo2.append(QuantitySample(kind: .spo2, start: t, end: t.addingTimeInterval(60), value: 0.95 + Double(i % 3) * 0.01))
            }
            nights.append(StoredSleepSummary(night: cal.startOfDay(for: wake), asleepMin: 420, deepMin: 80, lightMin: 260,
                                             remMin: 80, awakeMin: 60, efficiency: 0.9, inBedStart: bed,
                                             inBedEnd: wake, sleepOnset: bed.addingTimeInterval(600),
                                             sleepWake: wake, skinTempC: 34, sleepScore: 80, stressScore: 30))
        }
        _ = try store.ingest(hr.sorted { $0.start < $1.start })
        _ = try store.ingest(hrv)
        _ = try store.ingest(spo2)
        for n in nights { store.context.insert(n) }
        let yesterday = today.addingTimeInterval(-86_400)
        for i in 0..<1_800 {
            let t = yesterday.addingTimeInterval(Double(i) * 96)
            store.context.insert(StoredStepSample(start: t, end: t.addingTimeInterval(60), delta: 10 + i % 7))
        }
        store.context.insert(StoredDaily(day: today, steps: 6_000))
        try store.context.save()
        return todayEnd
    }

    private func todayCards(_ container: ModelContainer) -> some View {
        List {
            Group {
                OCCard { WellnessBalanceCardView() }
                VitalsStatusCardView()
                OCCard { CaloriesCardView() }
                OCCard { GoalsCardView() }
                SleepCardView()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .modelContainer(container)
    }

    private struct Row {
        var name: String
        var saveMS: [Double] = []
        var busyMS: [Int] = []
        var longestMS: [Int] = []
        var endBusyMS = 0
        var endLongestMS = 0

        func line() -> String {
            let avgBusy = busyMS.isEmpty ? 0 : Double(busyMS.reduce(0, +)) / Double(busyMS.count)
            let avgSave = saveMS.isEmpty ? 0 : saveMS.reduce(0, +) / Double(saveMS.count)
            return String(format: "BENCH | %@ | save call avg %.0f ms | busy per save avg %.0f ms, max %d ms | longest stall %d ms | after the sync: busy %d ms, longest %d ms",
                          name, avgSave, avgBusy, busyMS.max() ?? 0, longestMS.max() ?? 0, endBusyMS, endLongestMS)
        }
    }

    private func run(_ name: String, duringSync: Bool, cards: Bool = true) throws -> Row {
        let c = try makeContainer()
        let store = LocalStore(c.mainContext)
        let now = Date()
        var next = try seed(store, now: now)
        let vc = UIHostingController(rootView: cards ? AnyView(todayCards(c)) : AnyView(Color.clear.modelContainer(c)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 3_000))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        let probe = MainThreadStallProbe()
        settle(probe)   // first fetches and reports land before anything is measured

        var row = Row(name: name)
        if duringSync { SyncHooks.begin() }
        probe.start()
        for _ in 0..<Self.saves {
            _ = probe.take()
            let batch = (0..<Self.samplesPerSave).map { i -> QuantitySample in
                let t = next.addingTimeInterval(Double(i + 1))
                return QuantitySample(kind: .heartRate, start: t, end: t.addingTimeInterval(1), value: Double(80 + i % 10))
            }
            next = next.addingTimeInterval(Double(Self.samplesPerSave))
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try store.ingest(batch)
            row.saveMS.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            pump(Self.gapAfterSave)
            let r = probe.take()
            row.busyMS.append(r.busyMS)
            row.longestMS.append(r.longestMS)
        }
        if duringSync {
            _ = probe.take()
            SyncHooks.end()
            pump(3)
            let r = probe.take()
            row.endBusyMS = r.busyMS
            row.endLongestMS = r.longestMS
        }
        probe.stop()
        window.isHidden = true
        window.rootViewController = nil
        pump(1)
        return row
    }

    /// Pumps the main run loop until a quarter second passes with no busy stretch over 20 ms (at most
    /// 20 s), so a measurement starts from an idle screen.
    private func settle(_ probe: MainThreadStallProbe) {
        probe.start()
        let deadline = Date().addingTimeInterval(20)
        _ = probe.take()
        while Date() < deadline {
            pump(0.25)
            if probe.take().longestMS <= 20 { break }
        }
        probe.stop()
    }

    func testMainThreadCostOfTwentySyncSizedSavesWithTodayOnScreen() throws {
        guard ProcessInfo.processInfo.environment["OC_BENCH"] == "1" else {
            throw XCTSkip("benchmark: set TEST_RUNNER_OC_BENCH=1 to run it")
        }
        // A first pass warms the process (first-use SwiftUI and SwiftData paths); not reported.
        _ = try run("warm-up", duringSync: true)
        let during = try run("during a sync", duringSync: true)
        let outside = try run("outside a sync", duringSync: false)
        // The same saves with nothing on screen: what the store write costs by itself.
        let bare = try run("no cards on screen", duringSync: true, cards: false)
        print(during.line())
        print(outside.line())
        print(bare.line())
        print("BENCH-RAW | during busy \(during.busyMS) longest \(during.longestMS)")
        print("BENCH-RAW | outside busy \(outside.busyMS) longest \(outside.longestMS)")
    }
}
