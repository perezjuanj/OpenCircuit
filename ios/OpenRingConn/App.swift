import SwiftUI
import SwiftData

@main
struct OpenRingConnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container = OpenRingConnApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Retention housekeeping: drop raw samples older than the window once per launch
                // (the data already lives in Apple Health; rollups are kept). Runs off the launch
                // path, never per write — see LocalStore.pruneExpiredSamples. (#32)
                .task { OpenRingConnApp.pruneExpiredSamplesAtLaunch(container) }
                // One-time scrub of out-of-band heart-rate samples persisted before the decoder
                // band-guard (the "Resting HR 4 bpm" bug). Gated so it scans at most once.
                .task { OpenRingConnApp.purgeImplausibleHeartRateOnce(container) }
        }
        .modelContainer(container)
    }

    // MARK: Schema versioning (#40)
    //
    // A real (currently single-version) migration plan so an *expected* schema change is handled
    // by lightweight/custom migration instead of falling through to the last-resort wipe below.
    // Future schema changes append a `VersionedSchema` + a `MigrationStage` here rather than
    // relying on the wipe — which destroys un-resyncable local history.
    enum SchemaV1: VersionedSchema {
        static var versionIdentifier = Schema.Version(1, 0, 0)
        static var models: [any PersistentModel.Type] {
            [StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self,
             StoredNap.self, StoredPeriodEntry.self]
        }
    }

    enum MigrationPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
        static var stages: [MigrationStage] { [] }
    }

    /// UserDefaults flag the UI can read to tell the user their local cache was rebuilt (raw
    /// sample history isn't re-syncable once the ring has been drained). Set only when the
    /// last-resort wipe runs; the UI clears it after showing the notice. (#40)
    static let historyResetDefaultsKey = "localHistoryWasReset"

    /// Build the SwiftData container, recovering from an incompatible on-disk store.
    ///
    /// The default `.modelContainer(for:)` modifier traps if the container can't be created —
    /// e.g. a schema change neither `MigrationPlan` nor lightweight migration can handle — so the
    /// app dies on the launch screen (black screen). Expected migrations go through the plan;
    /// only if that STILL fails do we fall back to wiping. Before wiping we export the durable
    /// rollups (sleep summaries + daily steps) to a JSON backup and restore them into the fresh
    /// store, and raise `historyResetDefaultsKey` so the UI can tell the user. Raw epoch samples
    /// are not backed up — they're already in Apple Health. (#40)
    static func makeContainer() -> ModelContainer {
        let schema = Schema([StoredSample.self, StoredCursor.self,
                             StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
                             StoredPeriodEntry.self])
        let config = ModelConfiguration(schema: schema)

        do {
            return try ModelContainer(for: schema, migrationPlan: MigrationPlan.self,
                                      configurations: config)
        } catch {
            #if DEBUG
            print("SwiftData store unusable (\(error)); backing up rollups, resetting cache, retrying.")
            #endif
            let backup = RollupBackup.exportBeforeWipe(config: config)
            removeStoreFiles(at: config.url)
            let fresh: ModelContainer
            do {
                fresh = try ModelContainer(for: schema, migrationPlan: MigrationPlan.self,
                                           configurations: config)
            } catch {
                // A fresh store still failed — genuinely unrecoverable (e.g. no disk).
                fatalError("Unrecoverable SwiftData store error: \(error)")
            }
            backup?.restore(into: fresh)
            UserDefaults.standard.set(true, forKey: historyResetDefaultsKey)
            return fresh
        }
    }

    /// Prune expired raw samples once at launch. Best-effort — retention is housekeeping, so a
    /// failure here must never block the UI.
    @MainActor
    static func pruneExpiredSamplesAtLaunch(_ container: ModelContainer) {
        try? LocalStore(container.mainContext).pruneExpiredSamples()
    }

    /// Run the one-time out-of-band heart-rate scrub (`LocalStore.purgeImplausibleHeartRate`) at
    /// most once, gated by a UserDefaults flag so it doesn't scan on every launch (#32). Best-
    /// effort: a failure leaves the flag unset so it retries next launch, and never blocks the UI.
    private static let hrPurgeDoneKey = "store.purgedImplausibleHR.v1"
    @MainActor
    static func purgeImplausibleHeartRateOnce(_ container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: hrPurgeDoneKey) else { return }
        do {
            _ = try LocalStore(container.mainContext).purgeImplausibleHeartRate()
            UserDefaults.standard.set(true, forKey: hrPurgeDoneKey)
        } catch { /* leave the flag unset so it retries next launch */ }
    }

    /// Delete the SQLite store plus its `-shm`/`-wal` sidecar files.
    private static func removeStoreFiles(at storeURL: URL) {
        let fm = FileManager.default
        let base = storeURL.deletingPathExtension()
        for url in [storeURL,
                    base.appendingPathExtension("store-shm"),
                    base.appendingPathExtension("store-wal")] {
            try? fm.removeItem(at: url)
        }
    }
}

/// Best-effort JSON backup of the durable rollup tables, used by `makeContainer` to carry sleep
/// summaries + daily steps across a last-resort store wipe (#40). Raw `StoredSample` epochs are
/// intentionally excluded — they already live in Apple Health and would bloat the backup.
/// Everything here is best-effort: a failure degrades to "history reset", never a crash.
struct RollupBackup: Codable {
    struct Sleep: Codable {
        var night: Date
        var asleepMin, deepMin, lightMin, remMin, awakeMin: Int
        var efficiency: Double
        var inBedStart, inBedEnd, updatedAt: Date
    }
    struct Daily: Codable {
        var day: Date
        var steps: Int
        var updatedAt: Date
        var healthWrittenSteps: Int
    }
    /// User-ENTERED period logs (#78). Unlike sleep/steps these are NOT re-syncable from the
    /// ring or recoverable from Apple Health (HK menstrualFlow isn't read back), so they're the
    /// most irreplaceable rows and MUST survive a wipe. `healthWritten` + `hkSampleUUIDs` round-
    /// trip so a restored entry isn't re-written to HealthKit and stays editable/deletable there.
    struct Period: Codable {
        var start: Date
        var end: Date?
        var flowLevelRaw: Int
        var symptoms: [String]
        var notes: String
        var healthWritten: Bool
        var hkSampleUUIDs: [String]
        var updatedAt: Date
    }
    /// Auto-detected naps (#76). Re-derivable from synced sleep, but cheap to preserve and the
    /// `healthWritten` flag round-trips so a restored nap isn't re-mirrored to Health.
    struct Nap: Codable {
        var start: Date
        var end: Date
        var asleepMin: Int
        var isLongNap: Bool
        var healthWritten: Bool
        var updatedAt: Date
    }
    var sleep: [Sleep]
    var daily: [Daily]
    var periods: [Period]
    var naps: [Nap]

    private static var backupURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("rollup-backup.json")
    }

    /// Read the rollup tables from the (un-openable-as-current) store using a schema LIMITED to
    /// just those tables — so a schema change to the sample/cursor tables can't block reading
    /// them — and write a JSON snapshot. Returns the snapshot (nil if even this best-effort read
    /// fails). The file persists so a crash mid-wipe can't lose the rollups.
    static func exportBeforeWipe(config: ModelConfiguration) -> RollupBackup? {
        let schema = Schema([StoredSleepSummary.self, StoredDaily.self,
                             StoredPeriodEntry.self, StoredNap.self])
        let limited = ModelConfiguration(schema: schema, url: config.url)
        guard let container = try? ModelContainer(for: schema, configurations: limited) else { return nil }
        let ctx = ModelContext(container)
        let sleepRows = (try? ctx.fetch(FetchDescriptor<StoredSleepSummary>())) ?? []
        let dailyRows = (try? ctx.fetch(FetchDescriptor<StoredDaily>())) ?? []
        let periodRows = (try? ctx.fetch(FetchDescriptor<StoredPeriodEntry>())) ?? []
        let napRows = (try? ctx.fetch(FetchDescriptor<StoredNap>())) ?? []
        let backup = RollupBackup(
            sleep: sleepRows.map {
                Sleep(night: $0.night, asleepMin: $0.asleepMin, deepMin: $0.deepMin,
                      lightMin: $0.lightMin, remMin: $0.remMin, awakeMin: $0.awakeMin,
                      efficiency: $0.efficiency, inBedStart: $0.inBedStart,
                      inBedEnd: $0.inBedEnd, updatedAt: $0.updatedAt)
            },
            daily: dailyRows.map {
                Daily(day: $0.day, steps: $0.steps, updatedAt: $0.updatedAt,
                      healthWrittenSteps: $0.healthWrittenSteps)
            },
            periods: periodRows.map {
                Period(start: $0.start, end: $0.end, flowLevelRaw: $0.flowLevelRaw,
                       symptoms: $0.symptoms, notes: $0.notes, healthWritten: $0.healthWritten,
                       hkSampleUUIDs: $0.hkSampleUUIDs, updatedAt: $0.updatedAt)
            },
            naps: napRows.map {
                Nap(start: $0.start, end: $0.end, asleepMin: $0.asleepMin,
                    isLongNap: $0.isLongNap, healthWritten: $0.healthWritten, updatedAt: $0.updatedAt)
            })
        if let url = backupURL, let data = try? JSONEncoder().encode(backup) {
            try? data.write(to: url, options: .atomic)
        }
        return backup
    }

    /// Re-insert the backed-up rollups into the fresh store, then remove the JSON file. The
    /// unique `night`/`day` keys keep this idempotent. Best-effort — a failure just means the
    /// dashboard starts without past history.
    func restore(into container: ModelContainer) {
        let ctx = ModelContext(container)
        for s in sleep {
            ctx.insert(StoredSleepSummary(
                night: s.night, asleepMin: s.asleepMin, deepMin: s.deepMin, lightMin: s.lightMin,
                remMin: s.remMin, awakeMin: s.awakeMin, efficiency: s.efficiency,
                inBedStart: s.inBedStart, inBedEnd: s.inBedEnd, updatedAt: s.updatedAt))
        }
        for d in daily {
            ctx.insert(StoredDaily(day: d.day, steps: d.steps, updatedAt: d.updatedAt,
                                   healthWrittenSteps: d.healthWrittenSteps))
        }
        for p in periods {
            ctx.insert(StoredPeriodEntry(
                start: p.start, end: p.end, flowLevelRaw: p.flowLevelRaw,
                symptoms: p.symptoms, notes: p.notes, healthWritten: p.healthWritten,
                hkSampleUUIDs: p.hkSampleUUIDs, updatedAt: p.updatedAt))
        }
        for n in naps {
            ctx.insert(StoredNap(start: n.start, end: n.end, asleepMin: n.asleepMin,
                                 isLongNap: n.isLongNap, healthWritten: n.healthWritten,
                                 updatedAt: n.updatedAt))
        }
        if (try? ctx.save()) != nil, let url = Self.backupURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
