import Foundation
import SwiftData
import OpenCircuitKit

/// One stored sample as a dashboard card reads it: a value copy, so it can cross from the background
/// read to the view (decision 75a).
struct SampleSnapshot: Equatable, Sendable {
    let kindRaw: String
    let start: Date
    let end: Date
    let value: Double
    let deviceID: String

    init(_ row: StoredSample) {
        kindRaw = row.kindRaw
        start = row.start
        end = row.end
        value = row.value
        deviceID = row.deviceID
    }

    init(kindRaw: String, start: Date, end: Date, value: Double, deviceID: String) {
        self.kindRaw = kindRaw
        self.start = start
        self.end = end
        self.value = value
        self.deviceID = deviceID
    }
}

/// One per-snapshot step delta as the Goals, Readiness and Calories cards read it (decision 75a).
struct StepSampleSnapshot: Equatable, Sendable {
    let start: Date
    let end: Date
    let delta: Int

    init(_ row: StoredStepSample) {
        start = row.start
        end = row.end
        delta = row.delta
    }

    init(start: Date, end: Date, delta: Int) {
        self.start = start
        self.end = end
        self.delta = delta
    }
}

/// What a card's off-main read is keyed on: the store-change signal's version and the read's own
/// window bound, so the read runs again when either moves.
struct DashboardReadKey: Equatable {
    let version: Int
    let bound: Date
}

/// A row stamped with the device that recorded it and when, so the decision-29 ownership filter
/// reads stored rows and their snapshots alike.
protocol DeviceTimedRow {
    var deviceID: String { get }
    var start: Date { get }
}

extension StoredSample: DeviceTimedRow {}
extension SampleSnapshot: DeviceTimedRow {}

/// The dashboard's heavy sample reads (decision 75a). Build 84 ran each as a `@Query` on the main
/// context, so every main-context save re-fetched and materialized about 40 k rows ON THE MAIN THREAD
/// (36 k for the Vitals Status card alone), tens of times per strap sync. Each read here runs on a
/// detached task through its own `ModelContext` and returns value snapshots; the cards hold them as
/// state and re-read when `StoreRefreshSignal.version` moves.
///
/// The descriptors are build 84's, unchanged: the same predicates (`value > 0`, the day bounds) and
/// the same sort orders, so every card shows the same numbers. A read is `async` with its detached
/// task inside, so it can't be run on the main actor by mistake (the #306 rule).
enum DashboardReads {

    /// The Vitals Status card's three 32-day sets.
    struct VitalsHistory: Equatable, Sendable {
        var heartRate: [SampleSnapshot]
        var spo2: [SampleSnapshot]
        var hrv: [SampleSnapshot]
    }

    /// Today's heart rate and the step deltas since yesterday's start: what the Goals, Readiness and
    /// Calories cards price the day from.
    struct TodayActivity: Equatable, Sendable {
        var heartRate: [SampleSnapshot]
        var steps: [StepSampleSnapshot]
    }

    // MARK: Descriptors (build 84's `@Query`s)

    /// One vital since `since`, oldest first, `value > 0` (the Vitals Status card).
    nonisolated static func vitalsHistoryDescriptor(_ kind: MetricKind, since: Date) -> FetchDescriptor<StoredSample> {
        let kindRaw = kind.rawValue
        return FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start >= since && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)])
    }

    /// Per-snapshot step deltas from the start of the day before `dayStart`, oldest first, so a
    /// snapshot straddling midnight still contributes its in-day share. Must stay in lockstep with
    /// `HealthKitWriter.flushActiveCalories`.
    nonisolated static func recentStepSamplesDescriptor(dayStart: Date) -> FetchDescriptor<StoredStepSample> {
        let stepsFrom = dayStart.addingTimeInterval(-86_400)
        return FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.start >= stepsFrom },
            sortBy: [SortDescriptor(\.start, order: .forward)])
    }

    /// The Sleep card's HR / HRV / SpO₂ after `lookback`, newest first, `value > 0`.
    nonisolated static func sleepCardVitalsDescriptor(lookback: Date) -> FetchDescriptor<StoredSample> {
        let hr = MetricKind.heartRate.rawValue
        let hrv = MetricKind.hrvSDNN.rawValue
        let spo2 = MetricKind.spo2.rawValue
        return FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                ($0.kindRaw == hr || $0.kindRaw == hrv || $0.kindRaw == spo2)
                    && $0.start > lookback && $0.value > 0
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
    }

    // MARK: Reads

    static func vitalsHistory(container: ModelContainer, since: Date) async -> VitalsHistory? {
        await read(container) { context in
            var interned = DeviceIDs()
            func rows(_ kind: MetricKind) throws -> [SampleSnapshot] {
                try fetch(vitalsHistoryDescriptor(kind, since: since), in: context).map { interned.snapshot($0) }
            }
            return VitalsHistory(heartRate: try rows(.heartRate), spo2: try rows(.spo2), hrv: try rows(.hrvSDNN))
        }
    }

    static func todayActivity(container: ModelContainer, dayStart: Date) async -> TodayActivity? {
        #if DEBUG
        fetchThreadLog.note(todayActivityFor: dayStart, in: container)
        #endif
        return await read(container) { context in
            var interned = DeviceIDs()
            return TodayActivity(
                heartRate: try fetch(GoalsCardQueries.heartRate(dayStart: dayStart), in: context).map { interned.snapshot($0) },
                steps: try fetch(recentStepSamplesDescriptor(dayStart: dayStart), in: context).map(StepSampleSnapshot.init))
        }
    }

    /// The Sleep card's rows grouped by kind, each kind in the query's newest-first order, as the card's
    /// overnight averages read them.
    static func sleepCardVitals(container: ModelContainer, lookback: Date) async -> [String: [OvernightAverages.Point]]? {
        await read(container) { context in
            var pointsByKind: [String: [OvernightAverages.Point]] = [:]
            for row in try fetch(sleepCardVitalsDescriptor(lookback: lookback), in: context) {
                pointsByKind[row.kindRaw, default: []].append(OvernightAverages.Point(value: row.value, start: row.start))
            }
            return pointsByKind
        }
    }

    // MARK: Plumbing

    /// One `String` per device for a read's snapshots. A strap's id is too long to be stored inline, so
    /// without this every row would carry its own heap copy, and the main thread would free tens of
    /// thousands of them each time a card replaced its rows.
    private struct DeviceIDs {
        private var seen: [String: String] = [:]

        mutating func snapshot(_ row: StoredSample) -> SampleSnapshot {
            let id = row.deviceID
            let shared: String
            if let known = seen[id] { shared = known } else { seen[id] = id; shared = id }
            return SampleSnapshot(kindRaw: row.kindRaw, start: row.start, end: row.end, value: row.value, deviceID: shared)
        }
    }

    /// Runs `body` on a detached task through a fresh `ModelContext`. nil when the caller was cancelled
    /// (a newer refresh replaced it), so a stale read is never published; a cancelled read that has
    /// not started yet doesn't fetch at all. A failed fetch reads as empty, as a `@Query` does.
    private static func read<T: Sendable>(_ container: ModelContainer,
                                          _ body: @escaping @Sendable (ModelContext) throws -> T) async -> T? {
        let task = Task.detached(priority: .userInitiated) { () -> T? in
            guard !Task.isCancelled else { return nil }
            return try? body(ModelContext(container))
        }
        let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled ? nil : value
    }

    /// One fetch. Stops a cancelled read between its fetches.
    private nonisolated static func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>,
                                                             in context: ModelContext) throws -> [T] {
        try Task.checkCancellation()
        #if DEBUG
        fetchThreadLog.note(onMainThread: Thread.isMainThread)
        #endif
        return (try? context.fetch(descriptor)) ?? []
    }

    #if DEBUG
    /// Tests only: which thread each fetch ran on.
    static let fetchThreadLog = FetchThreadLog()

    final class FetchThreadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain = 0
        private var offMain = 0
        private var todayActivityDays: [(container: ObjectIdentifier, day: Date)] = []

        func note(onMainThread: Bool) {
            lock.lock(); defer { lock.unlock() }
            if onMainThread { onMain += 1 } else { offMain += 1 }
        }

        func note(todayActivityFor day: Date, in container: ModelContainer) {
            lock.lock(); defer { lock.unlock() }
            todayActivityDays.append((ObjectIdentifier(container), day))
        }

        /// The days the today-activity reads of `container` were asked for since the last call, then
        /// none (for every container).
        func takeTodayActivityDays(of container: ModelContainer) -> [Date] {
            lock.lock(); defer { lock.unlock() }
            defer { todayActivityDays = [] }
            return todayActivityDays.filter { $0.container == ObjectIdentifier(container) }.map(\.day)
        }

        /// (fetches on the main thread, fetches off it) since the last call, then zero.
        func take() -> (onMain: Int, offMain: Int) {
            lock.lock(); defer { lock.unlock() }
            defer { onMain = 0; offMain = 0 }
            return (onMain, offMain)
        }
    }
    #endif
}
