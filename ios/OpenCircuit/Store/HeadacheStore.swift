import Foundation
import SwiftData

// SwiftData models + LocalStore extension for headache logging and the (Phase-2) overnight
// signals index. Modelled file-for-file on `CycleStore.swift` (#78), which is the house pattern
// for user-entered data that mirrors into Apple Health.
//
// TWO models live here because they migrate together: adding both in one schema version means
// Phase 2 needs no second migration. `StoredHeadacheRisk` is written from Phase 2 onward and is
// simply never populated until then — an empty table costs nothing and a second lightweight
// migration is a launch-crash surface we only want to cross once.
//
// Every column is defaulted for SwiftData lightweight migration (cf. #21): a non-defaulted new
// attribute fails the migration and traps at `ModelContainer` init on launch — which the
// foreground recovery path answers by WIPING 30 days of un-resyncable raw samples (#40).

// MARK: - Headache log (user-entered labels)

/// One logged headache. Keyed by `onset` (UPSERTED, so re-logging the same moment replaces it).
///
/// This is the ground-truth label series for the headache-signals detector, and it is the ONLY
/// source of headache labels — nothing in this app ever infers a headache and writes it here.
/// `source` records provenance so an imported row is never mistaken for a user's own entry and
/// never written back to the store it came from.
///
/// `healthWritten` gates the Apple Health mirror so a finalized entry isn't re-written;
/// `hkSampleUUIDs` records the exact `HKCategorySample`(s) written for this entry so an edit can
/// delete-then-rewrite (HealthKit is append-only) and a delete can remove them from Apple Health.
@Model
final class StoredHeadacheEntry {
    /// Onset timestamp — the natural key. Unique so re-logging the same onset upserts.
    @Attribute(.unique) var onset: Date = Date.distantPast
    /// Optional end. `nil` = the user logged an onset but no resolution yet (an open headache),
    /// which writes a zero-length sample rather than inventing a duration.
    var end: Date? = nil
    /// Severity, using `HKCategoryValueSeverity`'s raw values 1:1 so the HealthKit mapping is the
    /// identity function and cannot drift: 0 = unspecified, 1 = notPresent, 2 = mild,
    /// 3 = moderate, 4 = severe. Defaults to 0 (unspecified) — a real choice, not a placeholder.
    var severityRaw: Int = 0
    /// Selected symptom tags from the built-in catalog (raw values of `HeadacheSymptom`).
    var symptoms: [String] = []
    /// Free-text symptom tags the user added themselves.
    var customSymptoms: [String] = []
    /// Selected possible-trigger tags (raw values of `HeadacheTrigger`).
    var factors: [String] = []
    /// Optional free-text notes. NOT clinically relevant — editing notes alone never re-writes
    /// Apple Health.
    var notes: String = ""
    /// Provenance: `"user"`, `"healthImport"` (read back from Apple Health), or
    /// `"periodLogImport"` (migrated from a `StoredPeriodEntry.symptoms` headache tag).
    var sourceRaw: String = HeadacheSource.user.rawValue
    /// For `sourceRaw == "healthImport"`, the UUID of the Apple Health sample this came from, so
    /// repeated imports are idempotent and we never write an imported sample back to Health.
    var importedHKUUID: String? = nil
    /// True once mirrored to Apple Health and finalized, so it isn't re-written.
    var healthWritten: Bool = false
    /// UUID strings of the HealthKit sample(s) last written for this entry — used to delete the
    /// stale sample(s) before re-writing on edit, and to remove them on delete. Without this the
    /// append-only HealthKit store would accumulate duplicates.
    var hkSampleUUIDs: [String] = []
    var updatedAt: Date = Date()

    init(onset: Date = Date.distantPast,
         end: Date? = nil,
         severityRaw: Int = 0,
         symptoms: [String] = [],
         customSymptoms: [String] = [],
         factors: [String] = [],
         notes: String = "",
         sourceRaw: String = HeadacheSource.user.rawValue,
         importedHKUUID: String? = nil,
         healthWritten: Bool = false,
         hkSampleUUIDs: [String] = [],
         updatedAt: Date = Date()) {
        self.onset = onset
        self.end = end
        self.severityRaw = severityRaw
        self.symptoms = symptoms
        self.customSymptoms = customSymptoms
        self.factors = factors
        self.notes = notes
        self.sourceRaw = sourceRaw
        self.importedHKUUID = importedHKUUID
        self.healthWritten = healthWritten
        self.hkSampleUUIDs = hkSampleUUIDs
        self.updatedAt = updatedAt
    }
}

/// Where a logged headache came from. Stored as a raw string so an unknown future value read back
/// from an older/newer build degrades to `.user` rather than trapping.
enum HeadacheSource: String, CaseIterable, Sendable {
    case user
    case healthImport
    case periodLogImport
}

extension StoredHeadacheEntry {
    var source: HeadacheSource { HeadacheSource(rawValue: sourceRaw) ?? .user }

    /// Human-readable severity. Deliberately mirrors the four choices the log sheet offers.
    var severityLabel: String {
        switch severityRaw {
        case 2: return "Mild"
        case 3: return "Moderate"
        case 4: return "Severe"
        case 1: return "None"
        default: return "Unspecified"
        }
    }
}

// MARK: - Frozen daily risk rows (Phase 2+)

/// One day's FROZEN overnight-signals score.
///
/// The freeze is the load-bearing invariant of the whole feature: a row is written exactly once,
/// by `insertRiskDayIfAbsent`, and is NEVER recomputed. Every later precision/AUC number is
/// therefore computed on scores that could not have seen the label — without this, any
/// self-evaluation is a retro-fit and the unlock gate is theatre.
///
/// `sleepRestaged` records that the night's sleep summary changed AFTER the score was frozen (our
/// nights re-stage hours after wake). Such days stay visible but are EXCLUDED from evaluation
/// rather than rescored, because rescoring would break the freeze.
@Model
final class StoredHeadacheRisk {
    /// Local start-of-day for the night that ENDED this morning — the natural key.
    @Attribute(.unique) var day: Date = Date.distantPast
    /// The relative index (0–100) for this day. Meaningful only against this user's own history.
    var index: Double = 0
    /// Band: 0 = typical, 1 = elevated, 2 = flagged.
    var bandRaw: Int = 0
    /// How many ring-derived features actually contributed (missing inputs are ABSENT, not zero).
    var ringFeatureCount: Int = 0
    /// Fraction of the expected overnight capture that was actually present.
    var coverageFraction: Double = 0
    /// JSON: per-feature signed contributions, for the detail screen and the Diagnostics export.
    var contributionsJSON: String = ""
    /// JSON: per-feature absence reasons, so a detector with missing inputs is debuggable remotely.
    var absentJSON: String = ""
    var computedAt: Date = Date()
    /// The sleep summary's `updatedAt` at freeze time, used to detect a later re-stage.
    var sleepUpdatedAt: Date? = nil
    var sleepRestaged: Bool = false
    /// Whether a notification actually fired for this day.
    var alerted: Bool = false
    /// Whether this day was scored AFTER alerts unlocked. Promotion statistics are computed on
    /// PRE-unlock days only, so the gate can never be validated on days it influenced.
    var postUnlock: Bool = false
    var updatedAt: Date = Date()

    init(day: Date = Date.distantPast,
         index: Double = 0,
         bandRaw: Int = 0,
         ringFeatureCount: Int = 0,
         coverageFraction: Double = 0,
         contributionsJSON: String = "",
         absentJSON: String = "",
         computedAt: Date = Date(),
         sleepUpdatedAt: Date? = nil,
         sleepRestaged: Bool = false,
         alerted: Bool = false,
         postUnlock: Bool = false,
         updatedAt: Date = Date()) {
        self.day = day
        self.index = index
        self.bandRaw = bandRaw
        self.ringFeatureCount = ringFeatureCount
        self.coverageFraction = coverageFraction
        self.contributionsJSON = contributionsJSON
        self.absentJSON = absentJSON
        self.computedAt = computedAt
        self.sleepUpdatedAt = sleepUpdatedAt
        self.sleepRestaged = sleepRestaged
        self.alerted = alerted
        self.postUnlock = postUnlock
        self.updatedAt = updatedAt
    }
}

// MARK: - LocalStore extension — headache log operations

extension LocalStore {

    /// Upsert one headache entry, keyed by `onset`. When `originalOnset` is supplied and differs,
    /// the user moved an existing entry's onset: the original row is RELOCATED (not left behind as
    /// a duplicate), carrying its `hkSampleUUIDs` so the flush can delete the stale Apple Health
    /// sample(s).
    ///
    /// `healthWritten` is reset to `false` only on a CLINICAL change (severity / onset / end /
    /// symptoms) so the writer deletes the prior sample and re-writes the corrected entry. A
    /// notes-only or trigger-only edit never touches Apple Health — those fields have no HealthKit
    /// representation, so re-writing for them would churn the user's Health store for nothing.
    func saveHeadacheEntry(onset: Date,
                           end: Date?,
                           severityRaw: Int,
                           symptoms: [String],
                           customSymptoms: [String] = [],
                           factors: [String] = [],
                           notes: String = "",
                           source: HeadacheSource = .user,
                           importedHKUUID: String? = nil,
                           originalOnset: Date? = nil) throws {
        // Onset moved while editing: relocate the original row's identity so one logical edit
        // doesn't leave an orphan behind.
        if let orig = originalOnset, orig != onset {
            // If a row already occupies the new onset, fold it away first, carrying its HK sample
            // UUIDs onto the row we keep so the flush still cleans them up.
            var inheritedUUIDs: [String] = []
            let clashDesc = FetchDescriptor<StoredHeadacheEntry>(
                predicate: #Predicate { $0.onset == onset })
            if let clash = try? context.fetch(clashDesc).first {
                inheritedUUIDs = clash.hkSampleUUIDs
                context.delete(clash)
            }
            let origDesc = FetchDescriptor<StoredHeadacheEntry>(
                predicate: #Predicate { $0.onset == orig })
            if let origRow = try? context.fetch(origDesc).first {
                origRow.onset = onset
                origRow.end = end
                origRow.severityRaw = severityRaw
                origRow.symptoms = symptoms
                origRow.customSymptoms = customSymptoms
                origRow.factors = factors
                origRow.notes = notes
                origRow.updatedAt = Date()
                origRow.hkSampleUUIDs += inheritedUUIDs
                origRow.healthWritten = false   // re-write at the new time; flush deletes the old
                try context.save()
                return
            }
            // Original vanished (unexpected) — fall through to a plain upsert by `onset`.
        }

        let descriptor = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.onset == onset })
        if let existing = try? context.fetch(descriptor).first {
            let clinicalChanged = existing.severityRaw != severityRaw
                || existing.end != end
                || existing.symptoms != symptoms
            existing.end = end
            existing.severityRaw = severityRaw
            existing.symptoms = symptoms
            existing.customSymptoms = customSymptoms
            existing.factors = factors
            existing.notes = notes
            existing.updatedAt = Date()
            if clinicalChanged { existing.healthWritten = false }
        } else {
            context.insert(StoredHeadacheEntry(
                onset: onset, end: end, severityRaw: severityRaw,
                symptoms: symptoms, customSymptoms: customSymptoms, factors: factors,
                notes: notes, sourceRaw: source.rawValue, importedHKUUID: importedHKUUID))
        }
        try context.save()
    }

    /// Delete a headache entry by onset and return the UUID strings of its previously-written
    /// Apple Health sample(s), so the caller can remove them from HealthKit (the store layer stays
    /// HealthKit-agnostic). Returns `[]` when the row didn't exist or had no HK samples.
    @discardableResult
    func deleteHeadacheEntry(onset: Date) throws -> [String] {
        let descriptor = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.onset == onset })
        guard let row = try? context.fetch(descriptor).first else { return [] }
        let uuids = row.hkSampleUUIDs
        context.delete(row)
        try context.save()
        return uuids
    }

    /// All logged headache entries, oldest first.
    func allHeadacheEntries() throws -> [StoredHeadacheEntry] {
        let descriptor = FetchDescriptor<StoredHeadacheEntry>(
            sortBy: [SortDescriptor(\.onset, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Headache entries whose onset falls in `[from, to)`, oldest first.
    func headacheEntries(from: Date, to: Date) throws -> [StoredHeadacheEntry] {
        let descriptor = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.onset >= from && $0.onset < to },
            sortBy: [SortDescriptor(\.onset, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Entries not yet mirrored to Apple Health, oldest first.
    ///
    /// Rows imported FROM Apple Health are excluded — writing them back would duplicate the user's
    /// own Health data and create a feedback loop between the two stores.
    func pendingHeadacheEntries() throws -> [StoredHeadacheEntry] {
        let imported = HeadacheSource.healthImport.rawValue
        let descriptor = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.healthWritten == false && $0.sourceRaw != imported },
            sortBy: [SortDescriptor(\.onset, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// UUIDs of Apple Health samples already imported, so a repeated import is idempotent.
    func importedHeadacheHKUUIDs() throws -> Set<String> {
        let descriptor = FetchDescriptor<StoredHeadacheEntry>()
        return Set(try context.fetch(descriptor).compactMap(\.importedHKUUID))
    }

    /// Record the result of a HealthKit headache write: store the written sample UUIDs and set the
    /// watermark. An OPEN headache (`end == nil`) keeps `finalized == false` so a later flush can
    /// extend it once the user logs a resolution.
    func recordHeadacheEntryHK(onset: Date, hkSampleUUIDs: [String], finalized: Bool) throws {
        let descriptor = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.onset == onset })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.hkSampleUUIDs = hkSampleUUIDs
        row.healthWritten = finalized
        try context.save()
    }
}

// MARK: - LocalStore extension — frozen risk rows (Phase 2+)

extension LocalStore {

    /// Insert a day's score ONLY if that day has no row yet. Returns `true` when a row was
    /// actually inserted.
    ///
    /// This is the freeze. There is deliberately no update path for `index`/`bandRaw`: a day's
    /// score is written once, from the first evaluation after the night settles, and every later
    /// pass is a no-op. Any "recompute today's score" convenience added here would silently
    /// invalidate every precision and AUC number the unlock gate depends on.
    @discardableResult
    func insertRiskDayIfAbsent(_ row: StoredHeadacheRisk) throws -> Bool {
        let day = row.day
        let descriptor = FetchDescriptor<StoredHeadacheRisk>(
            predicate: #Predicate { $0.day == day })
        if let existing = try? context.fetch(descriptor).first, existing.day == day { return false }
        context.insert(row)
        try context.save()
        return true
    }

    /// Frozen risk rows in `[from, to)`, oldest first.
    func riskDays(from: Date, to: Date) throws -> [StoredHeadacheRisk] {
        let descriptor = FetchDescriptor<StoredHeadacheRisk>(
            predicate: #Predicate { $0.day >= from && $0.day < to },
            sortBy: [SortDescriptor(\.day, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Mark a frozen day as having had its sleep re-staged after the score was taken. The score
    /// itself is NOT touched — the day is excluded from evaluation instead.
    func markRiskRestaged(day: Date, sleepUpdatedAt: Date) throws {
        let descriptor = FetchDescriptor<StoredHeadacheRisk>(
            predicate: #Predicate { $0.day == day })
        guard let row = try? context.fetch(descriptor).first else { return }
        guard !row.sleepRestaged else { return }
        row.sleepRestaged = true
        row.sleepUpdatedAt = sleepUpdatedAt
        row.updatedAt = Date()
        try context.save()
    }

    /// Record that a notification fired for this day (used for the alerts-per-week readout and to
    /// keep the per-day ledger honest across reinstalls).
    func markRiskAlerted(day: Date) throws {
        let descriptor = FetchDescriptor<StoredHeadacheRisk>(
            predicate: #Predicate { $0.day == day })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.alerted = true
        row.updatedAt = Date()
        try context.save()
    }
}
