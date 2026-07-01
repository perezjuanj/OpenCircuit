import Foundation
import OpenCircuitKit

/// One persisted history-sync evidence bundle. Kept separate from the human-readable activity log:
/// this is a machine-oriented breadcrumb for "why did sleep not land?" incidents.
struct HistorySyncEvidence: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var ringID: String
    var trigger: String
    var sleepCommitted: Bool
    var stagedSleepSegments: Int
    var mergedRecordCount: Int
    var historySampleCount: Int
    var channels: [HistoryChannelTrace]
    /// Reconstructed raw 0x4c records captured this sync (fixed 23-byte records concatenated).
    /// Stored for a few days so a failed overnight sync can be replayed/analyzed later.
    var rawRecordBlob: Data
}

struct HistorySyncEvidenceStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let limit = 24
    static let retention: TimeInterval = 3 * 24 * 3600

    private enum Key {
        static let entries = "obs.historySyncEvidence"
    }

    func entries() -> [HistorySyncEvidence] {
        guard let data = defaults.data(forKey: Key.entries),
              let rows = try? JSONDecoder().decode([HistorySyncEvidence].self, from: data) else { return [] }
        return rows
    }

    func record(_ entry: HistorySyncEvidence, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var rows = entries().filter { $0.date >= cutoff }
        rows.append(entry)
        if rows.count > Self.limit {
            rows.removeFirst(rows.count - Self.limit)
        }
        if let data = try? JSONEncoder().encode(rows) {
            defaults.set(data, forKey: Key.entries)
        }
    }
}
