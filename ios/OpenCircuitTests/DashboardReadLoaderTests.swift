import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Decision 75b, round 2: a card's off-main read is never thrown away by a version move. The read
/// under way publishes, then exactly one more read runs for the newest request; only a new window
/// bound (the day moved) drops a read. Reads here are held open by the test, so the order is exact.
@MainActor
final class DashboardReadLoaderTests: XCTestCase {
    private var containers: [ModelContainer] = []

    override func tearDown() {
        DashboardReads.fetchThreadLog.readDelay = 0
        containers.removeAll()
        super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer {
        let c = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return c
    }

    /// Reads the test answers one by one, in any order.
    private actor HeldReads {
        private var waiting: [Int: CheckedContinuation<String?, Never>] = [:]
        private(set) var started = 0
        private(set) var concurrent = 0
        private(set) var maxConcurrent = 0

        func read() async -> String? {
            started += 1
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            let n = started
            let value = await withCheckedContinuation { waiting[n] = $0 }
            concurrent -= 1
            return value
        }

        /// Answers the `n`th read (1-based). False while it hasn't started yet.
        func answer(_ n: Int, with value: String?) -> Bool {
            guard let c = waiting.removeValue(forKey: n) else { return false }
            c.resume(returning: value)
            return true
        }
    }

    private let day1 = Date(timeIntervalSince1970: 1_780_000_000)
    private let day2 = Date(timeIntervalSince1970: 1_780_086_400)

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    private func answer(_ reads: HeldReads, _ n: Int, _ value: String?) async {
        for _ in 0..<200 {
            if await reads.answer(n, with: value) { await settle(); return }
            await Task.yield()
        }
        XCTFail("read \(n) never started")
    }

    func testAReadUnderWayWhenTheVersionMovesIsPublishedThenReadExactlyOnceMore() async throws {
        let container = try makeContainer()
        let loader = DashboardReadLoader<String>("t")
        let reads = HeldReads()
        func ask(_ v: Int) {
            loader.request(DashboardReadKey(version: v, bound: day1), container: container) { _ in await reads.read() }
        }
        ask(1)
        await settle()
        ask(2)
        ask(3)
        await settle()
        let startedDuring = await reads.started
        XCTAssertEqual(startedDuring, 1, "a version move while a read runs starts nothing")
        await answer(reads, 1, "v1")
        XCTAssertEqual(loader.value, "v1", "the read under way was published, not thrown away")
        XCTAssertEqual(loader.publishedVersion, 1)
        let startedAfter = await reads.started
        XCTAssertEqual(startedAfter, 2, "then exactly one more read")
        await answer(reads, 2, "v3")
        XCTAssertEqual(loader.value, "v3")
        XCTAssertEqual(loader.publishedVersion, 3, "the re-read is for the newest request")
        let total = await reads.started
        XCTAssertEqual(total, 2, "and nothing after it")
        XCTAssertFalse(loader.isReading)
    }

    func testAnOlderReadIsNeverPublishedOverANewerOneAndADayChangeDropsTheOldWindow() async throws {
        let container = try makeContainer()
        let loader = DashboardReadLoader<String>("t")
        let reads = HeldReads()
        loader.request(DashboardReadKey(version: 1, bound: day1), container: container) { _ in await reads.read() }
        await settle()
        // The day moves while the old window's read is still out.
        loader.request(DashboardReadKey(version: 1, bound: day2), container: container) { _ in await reads.read() }
        await settle()
        let started = await reads.started
        XCTAssertEqual(started, 2, "the new window reads at once")
        await answer(reads, 2, "day2")
        XCTAssertEqual(loader.value, "day2")
        await answer(reads, 1, "day1")   // the old window's read lands late
        XCTAssertEqual(loader.value, "day2", "the old window's read was dropped, not published over the new one")
        let total = await reads.started
        XCTAssertEqual(total, 2, "and it does not start a re-read either")
    }

    func testASaveStreamFasterThanTheReadStillPublishesAndEndsOnTheLastSave() async throws {
        let container = try makeContainer()
        let loader = DashboardReadLoader<Int>("t")
        actor Slow {
            private(set) var concurrent = 0
            private(set) var maxConcurrent = 0
            func read(_ v: Int) async -> Int? {
                concurrent += 1
                maxConcurrent = max(maxConcurrent, concurrent)
                try? await Task.sleep(nanoseconds: 200_000_000)   // one read: 0.2 s
                concurrent -= 1
                return v
            }
        }
        let slow = Slow()
        var published: [Int] = []
        var last = 0
        for v in 1...20 {   // a request every 0.05 s for a second: four per read
            last = v
            loader.request(DashboardReadKey(version: v, bound: day1), container: container) { _ in await slow.read(v) }
            try await Task.sleep(nanoseconds: 50_000_000)
            if let p = loader.publishedVersion, published.last != p { published.append(p) }
        }
        XCTAssertGreaterThanOrEqual(published.count, 2, "the card published during the burst: \(published)")
        for _ in 0..<40 where loader.isReading { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(loader.publishedVersion, last, "the final published read includes the last save")
        XCTAssertEqual(loader.value, last)
        let most = await slow.maxConcurrent
        XCTAssertEqual(most, 1, "one read in flight at a time")
        XCTAssertEqual(published, published.sorted(), "never an older read over a newer one")
    }

    // MARK: A hosted card

    /// Synchronous: a nested run loop inside an `async` test does not run the card's main-actor work.
    func testTheVitalsCardPublishesDuringASaveStreamFasterThanItsRead() throws {
        let container = try makeContainer()
        let store = LocalStore(container.mainContext)
        let signal = StoreRefreshSignal(interval: 60)
        signal.observeSaves(of: container)
        DashboardReads.fetchThreadLog.readDelay = 0.4   // every read takes longer than the saves' spacing
        let vc = UIHostingController(rootView: AnyView(
            VitalsStatusCardView().environment(\.storeRefreshSignal, signal).modelContainer(container)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        _ = DashboardReads.fetchThreadLog.takeReads("vitals", of: container)

        var t = Date(timeIntervalSince1970: 1_789_900_000)
        for _ in 0..<16 {   // 16 saves, 0.15 s apart, outside a sync
            t = t.addingTimeInterval(60)
            _ = try store.ingest([QuantitySample(kind: .heartRate, start: t, end: t.addingTimeInterval(60), value: 70)])
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        let during = DashboardReads.fetchThreadLog.takeReads("vitals", of: container)
        let lastVersion = signal.version
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let after = DashboardReads.fetchThreadLog.takeReads("vitals", of: container)

        XCTAssertGreaterThanOrEqual(during.published.count, 2, "the card published during the burst: \(during)")
        XCTAssertLessThanOrEqual(during.started, 16 / 2, "reads did not stack one per save: \(during)")
        XCTAssertEqual((during.published + after.published).last, lastVersion, "its final data includes the last save")
        window.rootViewController = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }
}
