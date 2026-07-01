import SwiftUI
import SwiftData

@main
struct OpenCircuitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container = OpenCircuitApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Retention housekeeping: drop raw samples older than the window once per launch
                // (the data already lives in Apple Health; rollups are kept). Runs off the launch
                // path, never per write — see LocalStore.pruneExpiredSamples. (#32)
                .task { OpenCircuitApp.pruneExpiredSamplesAtLaunch(container) }
                // One-time scrub of out-of-band heart-rate samples persisted before the decoder
                // band-guard (the "Resting HR 4 bpm" bug). Gated so it scans at most once.
                .task { OpenCircuitApp.purgeImplausibleHeartRateOnce(container) }
                // One-time scrub of samples with a corrupted/implausible timestamp (e.g. a
                // misaligned bulk-page decode dated years off — surfaces as "13y ago").
                .task { OpenCircuitApp.purgeImplausibleTimestampsOnce(container) }
                // Repair of any SyncCursor watermark stuck in the future by a corrupted-timestamp
                // sample, BEFORE `ingest` guarded plausibility ahead of the cursor advance — run
                // every launch (not one-time; see the function doc), after the sample scrubs so
                // its "latest stored sample" lookup sees the already-cleaned table.
                .task { OpenCircuitApp.repairFutureSyncCursorsAtLaunch(container) }
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

    /// Adds `StoredDaytimeTemp` (Trends-only intraday skin temp, kept separate from #41's
    /// nightly baseline). Purely additive — no existing model changed — so this is a
    /// lightweight migration, not a custom stage.
    enum SchemaV2: VersionedSchema {
        static var versionIdentifier = Schema.Version(2, 0, 0)
        static var models: [any PersistentModel.Type] {
            [StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self,
             StoredNap.self, StoredPeriodEntry.self, StoredDaytimeTemp.self]
        }
    }

    /// Adds `StoredStepSample` (timestamped step DELTAS — #steps-history) alongside the existing
    /// `StoredDaily` running total, so a step reading's actual observation window survives
    /// instead of being folded away. Purely additive — lightweight migration.
    enum SchemaV3: VersionedSchema {
        static var versionIdentifier = Schema.Version(3, 0, 0)
        static var models: [any PersistentModel.Type] {
            [StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self,
             StoredNap.self, StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self]
        }
    }

    enum MigrationPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self] }
        static var stages: [MigrationStage] {
            [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
             .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self)]
        }
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
        // A brand-new app container (fresh install / new bundle id) has no
        // `Library/Application Support` directory, where SwiftData's default store lives. If it's
        // missing, store creation fails — and because `exportBeforeWipe` bails before it would
        // create the directory, BOTH the initial and the post-wipe `ModelContainer` attempts below
        // fail and hit the `fatalError` → black screen on first launch. Create it up front so a
        // fresh install opens cleanly. (#fresh-install-crash)
        _ = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)
        let schema = Schema([StoredSample.self, StoredCursor.self,
                             StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
                             StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self])
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

    /// Run the one-time implausible-TIMESTAMP scrub (`LocalStore.purgeImplausibleTimestamps`) at
    /// most once — same gating pattern as the HR purge above. Clears any pre-existing sample dated
    /// before the ring's counter epoch (or implausibly far future) so it can't surface as e.g.
    /// "13y ago" in a relative-time caption; new out-of-band timestamps are blocked at `ingest`.
    private static let timestampPurgeDoneKey = "store.purgedImplausibleTimestamps.v1"
    @MainActor
    static func purgeImplausibleTimestampsOnce(_ container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: timestampPurgeDoneKey) else { return }
        do {
            _ = try LocalStore(container.mainContext).purgeImplausibleTimestamps()
            UserDefaults.standard.set(true, forKey: timestampPurgeDoneKey)
        } catch { /* leave the flag unset so it retries next launch */ }
    }

    /// Run the `SyncCursor` future-watermark repair (`LocalStore.repairFutureSyncCursors`) on
    /// EVERY launch — deliberately NOT gated to once like the scrubs above. A single one-time run
    /// was observed to NOT reliably clear the `hk:heartRate` mirror cursor (still stuck after the
    /// first launch of the fix; exact cause unconfirmed, suspected ordering against the other
    /// one-time launch tasks below, which all touch the same SwiftData context concurrently). The
    /// repair itself is cheap (a handful of cursor rows) and a no-op once nothing's stuck, so
    /// re-running it every launch is the reliable fix rather than chasing the ordering theory.
    @MainActor
    static func repairFutureSyncCursorsAtLaunch(_ container: ModelContainer) {
        try? LocalStore(container.mainContext).repairFutureSyncCursors()
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
