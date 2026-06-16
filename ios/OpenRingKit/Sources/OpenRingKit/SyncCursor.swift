// Per-metric sync bookkeeping: remembers the newest record written for each
// metric so re-syncs only push newer samples (HealthKit dedup, mapping notes).
// Pure value type — the SwiftData store persists it; HealthKitWriter consults it.

import Foundation

public struct SyncCursor: Equatable, Codable, Sendable {
    /// Keyed by MetricKind.rawValue for JSON/SwiftData-friendly persistence.
    private var lastByKind: [String: Date]

    public init(lastByKind: [String: Date] = [:]) {
        self.lastByKind = lastByKind
    }

    /// Newest record timestamp written for `kind`, or nil if never synced.
    public func last(_ kind: MetricKind) -> Date? {
        lastByKind[kind.rawValue]
    }

    /// True if `date` is strictly newer than what's been synced for `kind`.
    public func isNew(_ kind: MetricKind, _ date: Date) -> Bool {
        date > (lastByKind[kind.rawValue] ?? .distantPast)
    }

    /// Move the cursor forward to `date` (never backward).
    public mutating func advance(_ kind: MetricKind, to date: Date) {
        if isNew(kind, date) { lastByKind[kind.rawValue] = date }
    }

    /// Keep only samples newer than the cursor, then advance past the newest kept.
    /// Returns the to-write subset, sorted by start. Mutates the cursor.
    public mutating func selectNew(_ samples: [QuantitySample]) -> [QuantitySample] {
        let fresh = samples
            .filter { isNew($0.kind, $0.start) }
            .sorted { $0.start < $1.start }
        for s in fresh { advance(s.kind, to: s.start) }
        return fresh
    }

    /// Non-mutating `selectNew` for callers that must only advance the cursor AFTER a durable
    /// store commit: returns the to-write subset together with the cursor state to persist
    /// *once the save succeeds*. Staging the advance means a failed/rolled-back save leaves the
    /// cursor where it was, so the same decoded samples are retried next time rather than being
    /// skipped — decoded frames must always end up stored (#22).
    public func selectNewStaged(_ samples: [QuantitySample]) -> (fresh: [QuantitySample], advanced: SyncCursor) {
        var advanced = self
        let fresh = advanced.selectNew(samples)
        return (fresh, advanced)
    }

    /// Kinds whose high-water mark differs from `previous` — i.e. the cursors that actually
    /// moved. Lets the store persist only the changed rows instead of re-writing every kind on
    /// every ingest (#33).
    public func advancedKinds(since previous: SyncCursor) -> [MetricKind] {
        MetricKind.allCases.filter { last($0) != previous.last($0) }
    }
}
