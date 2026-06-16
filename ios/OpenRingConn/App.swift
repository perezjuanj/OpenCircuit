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
            [StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self]
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
                             StoredSleepSummary.self, StoredDaily.self])
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
    var sleep: [Sleep]
    var daily: [Daily]

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
        let schema = Schema([StoredSleepSummary.self, StoredDaily.self])
        let limited = ModelConfiguration(schema: schema, url: config.url)
        guard let container = try? ModelContainer(for: schema, configurations: limited) else { return nil }
        let ctx = ModelContext(container)
        let sleepRows = (try? ctx.fetch(FetchDescriptor<StoredSleepSummary>())) ?? []
        let dailyRows = (try? ctx.fetch(FetchDescriptor<StoredDaily>())) ?? []
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
        if (try? ctx.save()) != nil, let url = Self.backupURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
