import Foundation
import SwiftData

// SwiftData model + LocalStore extension for women's health period logging (#78).
// Period entries are user-entered — not derived from BLE data.

/// One manually-logged period entry. Keyed by `start` (UPSERTED so editing the
/// same period replaces it). `healthWritten` gates the HealthKit menstrual-flow
/// write so a finalized period isn't re-written; `hkSampleUUIDs` records the exact
/// HKCategorySample(s) written for this entry so an edit can delete-then-rewrite
/// (HealthKit is append-only) and a delete can remove them from Apple Health.
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
    /// True once this entry has been fully mirrored to Apple Health. For a FINALIZED
    /// period (`end != nil`) this is set after the write so it isn't re-written. For an
    /// OPEN period (`end == nil`) it stays `false` so each flush extends the per-day
    /// samples as new days elapse. Reset to `false` on any clinical edit so the writer
    /// deletes the stale sample(s) (see `hkSampleUUIDs`) and re-writes the corrected one.
    var healthWritten: Bool = false
    /// UUID strings of the HKCategorySample(s) last written for this entry. Used to delete
    /// the prior Apple Health sample(s) before re-writing on edit, and to remove them on
    /// delete — without this the append-only HealthKit store would accumulate duplicates.
    var hkSampleUUIDs: [String] = []
    var updatedAt: Date = Date()

    init(start: Date = Date.distantPast,
         end: Date? = nil,
         flowLevelRaw: Int = 2,
         symptoms: [String] = [],
         notes: String = "",
         healthWritten: Bool = false,
         hkSampleUUIDs: [String] = [],
         updatedAt: Date = Date()) {
        self.start = start
        self.end = end
        self.flowLevelRaw = flowLevelRaw
        self.symptoms = symptoms
        self.notes = notes
        self.healthWritten = healthWritten
        self.hkSampleUUIDs = hkSampleUUIDs
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

    /// Upsert one period entry. When `originalStart` is supplied and differs from `start`,
    /// the user moved an existing entry's start date: the original row is RELOCATED (not left
    /// behind as a duplicate), carrying its `hkSampleUUIDs` so the flush can delete the stale
    /// Apple Health sample(s). On any clinical change (flow / end / symptoms) `healthWritten`
    /// is reset to `false` so `HealthKitWriter.flushMenstrualFlow` deletes the prior sample(s)
    /// and re-writes the corrected entry — keeping Apple Health in sync without duplicating.
    func savePeriodEntry(start: Date,
                         end: Date?,
                         flowLevelRaw: Int,
                         symptoms: [String],
                         notes: String,
                         originalStart: Date? = nil) throws {
        // Start-date moved while editing: relocate the original row's identity to the new
        // start so we don't insert a second row (and orphan the first) for one logical edit.
        if let orig = originalStart, orig != start {
            // If a row already occupies the new start, fold it away first (carry its HK
            // sample UUIDs onto the row we keep so the flush still cleans them up).
            var inheritedUUIDs: [String] = []
            let clashDesc = FetchDescriptor<StoredPeriodEntry>(predicate: #Predicate { $0.start == start })
            if let clash = try? context.fetch(clashDesc).first {
                inheritedUUIDs = clash.hkSampleUUIDs
                context.delete(clash)
            }
            let origDesc = FetchDescriptor<StoredPeriodEntry>(predicate: #Predicate { $0.start == orig })
            if let origRow = try? context.fetch(origDesc).first {
                origRow.start = start
                origRow.end = end
                origRow.flowLevelRaw = flowLevelRaw
                origRow.symptoms = symptoms
                origRow.notes = notes
                origRow.updatedAt = Date()
                origRow.hkSampleUUIDs += inheritedUUIDs
                origRow.healthWritten = false   // re-write at the new dates; flush deletes old samples
                try context.save()
                return
            }
            // Original vanished (unexpected) — fall through to a plain upsert by `start`.
        }

        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            predicate: #Predicate { $0.start == start })
        if let existing = try? context.fetch(descriptor).first {
            let clinicalChanged = existing.flowLevelRaw != flowLevelRaw
                || existing.end != end
                || existing.symptoms != symptoms
            existing.end = end
            existing.flowLevelRaw = flowLevelRaw
            existing.symptoms = symptoms
            existing.notes = notes
            existing.updatedAt = Date()
            // Reset the HK watermark only when a clinically-relevant field changed, so the
            // writer deletes the stale sample(s) and re-writes the corrected entry. (A pure
            // notes-only edit doesn't touch Apple Health.)
            if clinicalChanged { existing.healthWritten = false }
        } else {
            context.insert(StoredPeriodEntry(
                start: start, end: end, flowLevelRaw: flowLevelRaw,
                symptoms: symptoms, notes: notes))
        }
        try context.save()
    }

    /// Delete a period entry by start date and return the UUID strings of its previously-written
    /// Apple Health sample(s) so the caller can remove them from HealthKit (the store layer is
    /// HK-agnostic). Returns `[]` when the row didn't exist or had no HK samples.
    @discardableResult
    func deletePeriodEntry(start: Date) throws -> [String] {
        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            predicate: #Predicate { $0.start == start })
        guard let row = try? context.fetch(descriptor).first else { return [] }
        let uuids = row.hkSampleUUIDs
        context.delete(row)
        try context.save()
        return uuids
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

    /// Record the result of a HealthKit menstrual-flow write for a period entry: store the
    /// written sample UUIDs and set the written watermark. A FINALIZED period (`finalized ==
    /// true`) sets `healthWritten = true` so it isn't re-written; an OPEN period keeps it
    /// `false` so each subsequent flush extends the per-day samples as new days elapse (the
    /// flush deletes the stored UUIDs before re-writing, so no duplicates accumulate).
    func recordPeriodEntryHK(start: Date, hkSampleUUIDs: [String], finalized: Bool) throws {
        let descriptor = FetchDescriptor<StoredPeriodEntry>(
            predicate: #Predicate { $0.start == start })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.hkSampleUUIDs = hkSampleUUIDs
        row.healthWritten = finalized
        try context.save()
    }
}
