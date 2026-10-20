import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Decision 75a: each dashboard read moved off the main thread returns exactly the rows build 84's
/// `@Query` returned. The oracle in every test is build 84's descriptor, copied here verbatim and
/// fetched on the main context; the read under test runs on its own context. Synthetic rounded values,
/// fixed dates.
@MainActor
final class DashboardReadsTests: XCTestCase {
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    /// 2026-05-04 00:00 local.
    private let day: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 4))!
    private let ring = SyncDeviceID.ringConn.rawValue
    private let strap = "zeppos:00000000-0000-4000-8000-000000000001"

    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: StoredSample.self, StoredStepSample.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return c.mainContext
    }

    private func sample(_ kind: MetricKind, _ start: Date, _ value: Double, device: String? = nil) -> StoredSample {
        StoredSample(kindRaw: kind.rawValue, start: start, end: start.addingTimeInterval(60), value: value,
                     deviceID: device ?? ring)
    }

    private func snapshots(_ rows: [StoredSample]) -> [SampleSnapshot] { rows.map(SampleSnapshot.init) }

    /// Rows on both sides of every bound the reads use, zero and negative values, other kinds, both
    /// devices. Inserted out of order, so the sort is tested too.
    private func seed(_ context: ModelContext, around bounds: [Date]) throws {
        var rows: [StoredSample] = []
        for (i, bound) in bounds.enumerated() {
            for offset in [-3_600.0, -1, 0, 1, 3_600] {
                let t = bound.addingTimeInterval(offset)
                for kind in [MetricKind.heartRate, .spo2, .hrvSDNN, .stress] {
                    let value: Double = kind == .spo2 ? 0.95 : 60 + Double(i)
                    rows.append(sample(kind, t, value, device: i.isMultiple(of: 2) ? ring : strap))
                    rows.append(sample(kind, t.addingTimeInterval(5), 0))
                    rows.append(sample(kind, t.addingTimeInterval(7), -1))
                }
            }
        }
        for row in rows.reversed() { context.insert(row) }
        try context.save()
    }

    // MARK: Vitals Status (three 32-day sets)

    func testTheVitalsHistoryReadReturnsBuild84sThreeQueriesRows() async throws {
        let context = try makeContext()
        let since = day.addingTimeInterval(-32 * 86_400)
        try seed(context, around: [since, day, day.addingTimeInterval(-10 * 86_400)])

        func build84(_ kind: MetricKind) throws -> [SampleSnapshot] {
            let k = kind.rawValue
            return snapshots(try context.fetch(FetchDescriptor<StoredSample>(
                predicate: #Predicate { $0.kindRaw == k && $0.start >= since && $0.value > 0 },
                sortBy: [SortDescriptor(\.start, order: .forward)])))
        }
        let read = await DashboardReads.vitalsHistory(container: context.container, since: since)
        let history = try XCTUnwrap(read)
        XCTAssertEqual(history.heartRate, try build84(.heartRate))
        XCTAssertEqual(history.spo2, try build84(.spo2))
        XCTAssertEqual(history.hrv, try build84(.hrvSDNN))
        XCTAssertFalse(history.heartRate.isEmpty)
        XCTAssertTrue(history.heartRate.allSatisfy { $0.value > 0 && $0.start >= since }, "value > 0 and the window")
        XCTAssertEqual(Set(history.heartRate.map(\.deviceID)), [ring, strap], "no device filter in the read itself")
        XCTAssertTrue(history.heartRate.contains { $0.start == since }, "the window's start is inside it")
    }

    /// Decision 29's device filter, applied to the snapshots on the detached task, keeps exactly the
    /// rows it kept when build 84 applied it to the stored rows: here the ring until a switch, the
    /// strap after it.
    func testTheDeviceFilterKeepsTheSameRowsOnSnapshotsAsOnStoredRows() async throws {
        let context = try makeContext()
        let since = day.addingTimeInterval(-32 * 86_400)
        let switchAt = day.addingTimeInterval(-10 * 86_400)
        try seed(context, around: [since.addingTimeInterval(3_600), switchAt, day])
        let log = DeviceOwnershipLog(entries: [.init(family: .ringConn, since: .distantPast),
                                               .init(family: .zeppOS, since: switchAt)])
        let read = await DashboardReads.vitalsHistory(container: context.container, since: since)
        let history = try XCTUnwrap(read)

        func stored(_ kind: MetricKind) throws -> [StoredSample] {
            try context.fetch(DashboardReads.vitalsHistoryDescriptor(kind, since: since))
        }
        let build84 = VitalsStatusCardView.currentDeviceRows(
            samples: [try stored(.heartRate), try stored(.spo2), try stored(.hrvSDNN)], nights: [], log: log).samples
        let now = VitalsStatusCardView.ownSamples([history.heartRate, history.spo2, history.hrv], log: log)
        XCTAssertEqual(now, build84.map(snapshots))
        XCTAssertLessThan(now[0].count, history.heartRate.count, "the filter dropped something")
        XCTAssertFalse(now[0].isEmpty, "and kept something")
    }

    // MARK: Today's heart rate + recent step samples (Goals, Readiness, Calories)

    func testTheTodayActivityReadKeepsToTheDayAndDropsNonPositiveHeartRate() async throws {
        let context = try makeContext()
        let dayEnd = DayRollover.nextDayStart(after: day, calendar: .current)
        try seed(context, around: [day, dayEnd])
        let yesterday = day.addingTimeInterval(-86_400)
        for t in [yesterday.addingTimeInterval(-60), yesterday, yesterday.addingTimeInterval(60), day.addingTimeInterval(3_600)] {
            context.insert(StoredStepSample(start: t, end: t.addingTimeInterval(60), delta: 10))
        }
        try context.save()

        let hrKind = MetricKind.heartRate.rawValue
        let build84HR = snapshots(try context.fetch(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hrKind && $0.start >= day && $0.start < dayEnd && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)])))
        let stepsFrom = day.addingTimeInterval(-86_400)
        let build84Steps = try context.fetch(FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.start >= stepsFrom },
            sortBy: [SortDescriptor(\.start, order: .forward)])).map(StepSampleSnapshot.init)

        let read = await DashboardReads.todayActivity(container: context.container, dayStart: day)
        let activity = try XCTUnwrap(read)
        XCTAssertEqual(activity.heartRate, build84HR)
        XCTAssertEqual(activity.steps, build84Steps)
        XCTAssertTrue(activity.heartRate.contains { $0.start == day }, "midnight is today's")
        XCTAssertFalse(activity.heartRate.contains { $0.start >= dayEnd }, "the next midnight is tomorrow's")
        XCTAssertFalse(activity.heartRate.contains { $0.start < day }, "yesterday's last minute is not today's")
        XCTAssertTrue(activity.heartRate.allSatisfy { $0.value > 0 }, "value > 0")
        XCTAssertEqual(activity.steps.map(\.start), [yesterday, yesterday.addingTimeInterval(60), day.addingTimeInterval(3_600)],
                       "steps from yesterday's start, oldest first")
    }

    // MARK: Sleep card's overnight-average rows

    func testTheSleepCardReadGroupsBuild84sRowsByKindNewestFirst() async throws {
        let context = try makeContext()
        let lookback = day.addingTimeInterval(-3 * 86_400)
        try seed(context, around: [lookback, day])

        let hr = MetricKind.heartRate.rawValue
        let hrv = MetricKind.hrvSDNN.rawValue
        let spo2 = MetricKind.spo2.rawValue
        let build84 = try context.fetch(FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                ($0.kindRaw == hr || $0.kindRaw == hrv || $0.kindRaw == spo2)
                    && $0.start > lookback && $0.value > 0
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))
        // What build 84's `overnightAverages` built from that query in `body`.
        var expected: [String: [OvernightAverages.Point]] = [:]
        for row in build84 {
            expected[row.kindRaw, default: []].append(OvernightAverages.Point(value: row.value, start: row.start))
        }

        let read = await DashboardReads.sleepCardVitals(container: context.container, lookback: lookback)
        let grouped = try XCTUnwrap(read)
        XCTAssertEqual(grouped, expected)
        XCTAssertEqual(Set(grouped.keys), [hr, hrv, spo2], "stress is not an overnight vital")
        XCTAssertFalse(grouped.values.joined().contains { $0.start <= lookback }, "the lookback itself is outside")
        XCTAssertTrue(grouped.values.joined().allSatisfy { $0.value > 0 }, "value > 0")
    }

    // MARK: Off the main thread

    func testEveryDashboardReadFetchesOffTheMainThread() async throws {
        let context = try makeContext()
        try seed(context, around: [day])
        _ = DashboardReads.fetchThreadLog.take()
        _ = await DashboardReads.vitalsHistory(container: context.container, since: day.addingTimeInterval(-86_400))
        _ = await DashboardReads.todayActivity(container: context.container, dayStart: day)
        _ = await DashboardReads.sleepCardVitals(container: context.container, lookback: day.addingTimeInterval(-86_400))
        let log = DashboardReads.fetchThreadLog.take()
        XCTAssertEqual(log.onMain, 0, "a dashboard read fetched on the main thread")
        // At least the three vitals sets, today's HR and steps and the sleep card's rows: the test host's
        // own dashboard may read at the same time (off the main thread as well).
        XCTAssertGreaterThanOrEqual(log.offMain, 6)
    }

    func testACancelledReadPublishesNothing() async throws {
        let context = try makeContext()
        try seed(context, around: [day])
        let container = context.container
        let task = Task { @MainActor in await DashboardReads.todayActivity(container: container, dayStart: self.day) }
        task.cancel()
        let read = await task.value
        XCTAssertNil(read, "a read replaced by a newer refresh must not be published")
    }
}
