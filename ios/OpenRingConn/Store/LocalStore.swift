import Foundation
import SwiftData
import OpenRingKit

// SwiftData persistence: raw decoded samples + the per-metric sync cursor. The
// cursor mirrors OpenRingKit.SyncCursor (the testable source of truth); these
// @Model types are just its on-disk form.

@Model
final class StoredSample {
    var kindRaw: String
    var start: Date
    var end: Date
    var value: Double
    var rawValue: Double?
    // Default required so SwiftData can auto-migrate stores written before these
    // cumulative-counter columns existed (#21) — a new non-optional attribute with no
    // default fails lightweight migration and traps at ModelContainer init on launch.
    var isDelta: Bool = false
    var dailyTotal: Double?

    init(
        kindRaw: String,
        start: Date,
        end: Date,
        value: Double,
        rawValue: Double? = nil,
        isDelta: Bool = false,
        dailyTotal: Double? = nil
    ) {
        self.kindRaw = kindRaw
        self.start = start
        self.end = end
        self.value = value
        self.rawValue = rawValue
        self.isDelta = isDelta
        self.dailyTotal = dailyTotal
    }

    convenience init(
        _ s: QuantitySample,
        rawValue: Double? = nil,
        isDelta: Bool = false,
        dailyTotal: Double? = nil
    ) {
        self.init(
            kindRaw: s.kind.rawValue,
            start: s.start,
            end: s.end,
            value: s.value,
            rawValue: rawValue,
            isDelta: isDelta,
            dailyTotal: dailyTotal
        )
    }

    var sample: QuantitySample? {
        guard let kind = MetricKind(rawValue: kindRaw) else { return nil }
        return QuantitySample(kind: kind, start: start, end: end, value: value)
    }
}

@Model
final class StoredCursor {
    @Attribute(.unique) var kindRaw: String
    var last: Date

    init(kindRaw: String, last: Date) {
        self.kindRaw = kindRaw
        self.last = last
    }
}

@MainActor
struct LocalStore {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    /// Rebuild the in-memory SyncCursor from persisted rows.
    func loadCursor() throws -> SyncCursor {
        let rows = try context.fetch(FetchDescriptor<StoredCursor>())
        var map: [String: Date] = [:]
        for r in rows { map[r.kindRaw] = r.last }
        return SyncCursor(lastByKind: map)
    }

    /// Persist new samples and advance the cursor in one step.
    func ingest(_ samples: [QuantitySample]) throws -> [QuantitySample] {
        var cursor = try loadCursor()
        let fresh = cursor.selectNew(samples)
        var cumulativeStates: [MetricKind: CumulativeMetricState] = [:]
        var cumulativeStateDays: [MetricKind: Date] = [:]
        var ingested: [QuantitySample] = []

        for s in fresh {
            guard s.kind.isCumulativeCounter else {
                context.insert(StoredSample(s))
                ingested.append(s)
                continue
            }

            // The daily total resets at midnight. `fresh` is sorted oldest→newest, so a
            // single batch can span a day boundary; when it does, carry the raw counter
            // forward (so the delta stays correct) but reset the running total to 0 for the
            // new day. The initial DB-backed state is already day-bounded by `cumulativeState`.
            let dayStart = Calendar.current.startOfDay(for: s.start)
            let state: CumulativeMetricState
            if let existing = cumulativeStates[s.kind] {
                state = cumulativeStateDays[s.kind] == dayStart
                    ? existing
                    : CumulativeMetricState(previousRawValue: existing.previousRawValue, dailyTotal: 0)
            } else {
                state = try cumulativeState(for: s.kind, before: s.start)
            }

            let result = CumulativeMetricAccumulator.accumulate(s, state: state)
            let deltaSample = QuantitySample(kind: s.kind, start: s.start, end: s.end, value: result.deltaValue)
            context.insert(StoredSample(
                deltaSample,
                rawValue: result.rawValue,
                isDelta: true,
                dailyTotal: result.dailyTotal
            ))
            cumulativeStates[s.kind] = CumulativeMetricState(
                previousRawValue: result.rawValue,
                dailyTotal: result.dailyTotal
            )
            cumulativeStateDays[s.kind] = dayStart
            // Return the per-epoch DELTA, not the running total: HealthKit *sums* cumulative
            // quantity types (stepCount / activeEnergyBurned), so writing the daily total on
            // every epoch would massively overcount. Deltas sum back to the daily total in Health.
            ingested.append(deltaSample)
        }
        for kind in MetricKind.allCases {
            guard let last = cursor.last(kind) else { continue }
            upsertCursor(kind: kind.rawValue, last: last)
        }
        try context.save()
        return ingested
    }

    /// Gate a night's sleep segments on the `.sleep` cursor so re-syncs don't
    /// duplicate. Returns the segments to write (empty if this night is already
    /// synced), advancing the cursor to the latest segment end.
    func ingestSleep(_ segments: [SleepSegment]) throws -> [SleepSegment] {
        guard let latest = segments.map(\.end).max() else { return [] }
        var cursor = try loadCursor()
        guard cursor.isNew(.sleep, latest) else { return [] }
        cursor.advance(.sleep, to: latest)
        if let last = cursor.last(.sleep) {
            upsertCursor(kind: MetricKind.sleep.rawValue, last: last)
        }
        try context.save()
        return segments
    }

    func latestSample(kind: MetricKind) throws -> QuantitySample? {
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.sample
    }

    private func upsertCursor(kind: String, last: Date) {
        let descriptor = FetchDescriptor<StoredCursor>(
            predicate: #Predicate { $0.kindRaw == kind })
        if let existing = try? context.fetch(descriptor).first {
            existing.last = last
        } else {
            context.insert(StoredCursor(kindRaw: kind, last: last))
        }
    }

    private func cumulativeState(for kind: MetricKind, before date: Date) throws -> CumulativeMetricState {
        let kindRaw = kind.rawValue
        var previousDescriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start < date },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        previousDescriptor.fetchLimit = 1
        let previous = try context.fetch(previousDescriptor).first
        let previousRaw = previous.map { $0.rawValue ?? $0.value }

        let dayInterval = Calendar.current.dateInterval(of: .day, for: date)
        let dayStart = dayInterval?.start ?? date
        let nextDay = dayInterval?.end ?? date
        var dayDescriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw && $0.start >= dayStart && $0.start < nextDay && $0.start < date
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        dayDescriptor.fetchLimit = 1

        if let latestToday = try context.fetch(dayDescriptor).first {
            if let dailyTotal = latestToday.dailyTotal {
                return CumulativeMetricState(previousRawValue: previousRaw, dailyTotal: dailyTotal)
            }
            if !latestToday.isDelta {
                return CumulativeMetricState(
                    previousRawValue: previousRaw,
                    dailyTotal: latestToday.rawValue ?? latestToday.value
                )
            }
        }

        return CumulativeMetricState(previousRawValue: previousRaw)
    }
}

struct LaunchSnapshot {
    let lastHeartRate: QuantitySample?

    @MainActor
    static func load(from store: LocalStore) throws -> LaunchSnapshot {
        LaunchSnapshot(lastHeartRate: try store.latestSample(kind: .heartRate))
    }
}
