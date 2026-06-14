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

    init(kindRaw: String, start: Date, end: Date, value: Double) {
        self.kindRaw = kindRaw
        self.start = start
        self.end = end
        self.value = value
    }

    convenience init(_ s: QuantitySample) {
        self.init(kindRaw: s.kind.rawValue, start: s.start, end: s.end, value: s.value)
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
        for s in fresh { context.insert(StoredSample(s)) }
        for kind in MetricKind.allCases {
            guard let last = cursor.last(kind) else { continue }
            upsertCursor(kind: kind.rawValue, last: last)
        }
        try context.save()
        return fresh
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
}
