import Foundation
import SwiftData

// SwiftData model + LocalStore extension for women's health period logging (#78).
// Period entries are user-entered — not derived from BLE data.

/// One manually-logged period entry. Keyed by `start` (UPSERTED so editing the
/// same period replaces it). `healthWritten` gates the single HealthKit
/// menstrual-flow write, so re-editing a saved entry doesn't double-write.
///
/// Every column is defaulted for SwiftData lightweight migration (cf. #21).
@Model
final class StoredPeriodEntry {
    @Attribute(.unique) var start: Date = Date.distantPast
    /// Optional end date — nil when the user hasn't logged the last day yet.
    var end: Date? = nil
    /// Flow level: 1 = light, 2 = medium, 3 = heavy. 2 is the default.
    var flowLevelRaw: Int = 2
    /// User-selected symptom tags (e.g. "cramping", "bloating"). `[String]` is
    /// supported by SwiftData directly and small enough to store inline.
    var symptoms: [String] = []
    /// Optional free-text notes.
    var notes: String = ""
    /// True once this entry's flow sample has been written to Apple Health.
    /// Set after a confirmed save; never overwritten back to false on re-edit
    /// so the HK sample is only created once (callers delete + re-insert for edits).
    var healthWritten: Bool = false
    var updatedAt: Date = Date()

    init(start: Date = Date.distantPast,
         end: Date? = nil,
         flowLevelRaw: Int = 2,
         symptoms: [String] = [],
         notes: String = "",
         healthWritten: Bool = false,
         updatedAt: Date = Date()) {
        self.start = start
        self.end = end
        self.flowLevelRaw = flowLevelRaw
        self.symptoms = symptoms
        self.notes = notes
        self.healthWritten = healthWritten
        self.updatedAt = updatedAt
    }

    /// Convenience flow-level label.
    var flowLabel: String {
        switch flowLevelRaw {
        case 1: return "Light"
        case 3: return "Heavy"
        default: return "Medium"
        }
    }
}

// MARK: LocalStore extension — period logging operations

extension LocalStore {

    /// Upsert one period entry, keyed by `start`. Re-logging the same start date
    /// updates the existing row (preserving `healthWritten` only when no clinical
    /// fields changed — callers that change flow/symptoms set `resetHKFlag = true`
    /// if they want to trigger a fresh HK write).
    func savePeriodEntry(start: Date,
                         end: Date?,
                         flowLevelRaw: Int,
                         symptoms: [String],
                         notes: String) throws {
        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            predicate: #Predicate { $0.start == start })
        if let existing = try? context.fetch(descriptor).first {
            existing.end = end
            existing.flowLevelRaw = flowLevelRaw
            existing.symptoms = symptoms
            existing.notes = notes
            existing.updatedAt = Date()
            // Do NOT reset `healthWritten` here — let the caller decide.
            // A fresh HK write is triggered by HealthKitWriter once `healthWritten == false`.
        } else {
            context.insert(StoredPeriodEntry(
                start: start, end: end, flowLevelRaw: flowLevelRaw,
                symptoms: symptoms, notes: notes))
        }
        try context.save()
    }

    /// Delete a period entry by start date. Also resets the HK written state so
    /// a re-inserted entry with the same start will be written again.
    func deletePeriodEntry(start: Date) throws {
        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            predicate: #Predicate { $0.start == start })
        if let row = try? context.fetch(descriptor).first {
            context.delete(row)
            try context.save()
        }
    }

    /// All logged period entries, sorted by start (oldest first).
    func allPeriodEntries() throws -> [StoredPeriodEntry] {
        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Period entries not yet written to Apple Health (oldest first).
    func pendingPeriodEntries() throws -> [StoredPeriodEntry] {
        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            predicate: #Predicate { $0.healthWritten == false },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Mark a period entry as written to Apple Health.
    func markPeriodEntryWritten(start: Date) throws {
        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            predicate: #Predicate { $0.start == start })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.healthWritten = true
        try context.save()
    }
}
