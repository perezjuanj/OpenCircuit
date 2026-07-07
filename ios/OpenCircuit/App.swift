import SwiftUI
import SwiftData
import UIKit

@main
struct OpenCircuitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
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
                // Clear any workout Live Activity orphaned by a force-quit/crash mid-workout — a
                // session lives only in memory, so at a cold launch none can still be running.
                .task { WorkoutLiveActivityController.endOrphanedActivitiesAtLaunch() }
        }
        .modelContainer(container)
        // (Re)submit the BGTask requests on every backgrounding (#119). This is the scene-based
        // replacement for `applicationDidEnterBackground`, which iOS does NOT deliver to a
        // SwiftUI-lifecycle app — relying on it meant no request was EVER submitted, so no
        // background task ever ran (device-confirmed). Re-submitting here also refreshes
        // `earliestBeginDate` toward the coming morning as bedtime nears
        // (`BackgroundSyncPolicy.aimedFireDate`).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            let scheduler = BackgroundRefreshScheduler()
            scheduler.schedule()
            scheduler.scheduleProcessing()
            ObservabilityStore().recordScheduled()
        }
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

    /// The one process-wide SwiftData container, published the moment the foreground `App` builds
    /// it (see `makeContainer()`), so the background BGTask handler can REUSE it instead of opening
    /// a second `ModelContainer` over the same store file. (#131)
    ///
    /// Why this is safe to publish and read across the launch: the `@main App` struct's stored
    /// `container` property (`App.swift` line 8) is initialized when SwiftUI instantiates the App
    /// type at process launch — which happens for a background launch too (iOS always creates the
    /// App instance to establish the scene graph, even when no scene will connect). That
    /// initializer runs `makeContainer()`, which assigns this static WHEN the on-disk store opens
    /// (the normal case). The BGTask launch handler is only ever *invoked by BGTaskScheduler on a
    /// later run-loop turn*, never synchronously during launch — so by the time the handler reads
    /// this, the App init has already populated it.
    ///
    /// It is deliberately left `nil` when a background launch can't open the on-disk store (see
    /// `resolveContainer`): the handler then falls through to `makeContainerOrThrow()`, which
    /// re-throws → the run aborts-and-retries rather than draining into a throwaway in-memory
    /// container. The `makeContainerOrThrow()` fallback also covers the theoretical gap where the
    /// App init hasn't run yet.
    ///
    /// It is written exactly once, from the main thread, during the single-threaded App init
    /// before any concurrent reader exists; `ModelContainer` is itself `Sendable` and thread-safe
    /// to use from the `@MainActor` background handler.
    static var sharedContainer: ModelContainer?

    /// The schema + default configuration shared by BOTH container builders, so the foreground
    /// (recovering) and background (non-destructive) paths can never drift apart. (#131)
    private static func makeSchemaAndConfig() -> (Schema, ModelConfiguration) {
        let schema = Schema([StoredSample.self, StoredCursor.self,
                             StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
                             StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self])
        return (schema, ModelConfiguration(schema: schema))
    }

    /// Build the SwiftData container with NO destructive fallback: create the Application Support
    /// directory, open the store through the `MigrationPlan`, and rethrow on any failure. This is
    /// the ONLY builder the background BGTask drain may reach (#131) — a transient open failure
    /// during a routine background wake must abort-and-retry, NEVER wipe the un-resyncable raw
    /// sample/cursor history. It deliberately contains no `exportBeforeWipe`, no `removeStoreFiles`,
    /// and no `fatalError`; the wipe-and-recover recovery lives only in `makeContainer()`, where the
    /// `historyResetDefaultsKey` UI notice can be surfaced to the user.
    ///
    /// `storeURL` is a test-only seam (default nil → the app's default store); production always
    /// calls it with no argument.
    static func makeContainerOrThrow(storeURL: URL? = nil) throws -> ModelContainer {
        // A brand-new app container (fresh install / new bundle id) has no
        // `Library/Application Support` directory, where SwiftData's default store lives. If it's
        // missing, store creation fails, so create it up front. (#fresh-install-crash)
        _ = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)
        let (schema, defaultConfig) = makeSchemaAndConfig()
        let config = storeURL.map { ModelConfiguration(schema: schema, url: $0) } ?? defaultConfig
        return try ModelContainer(for: schema, migrationPlan: MigrationPlan.self,
                                  configurations: config)
    }

    /// Build the SwiftData container, recovering from an incompatible on-disk store.
    ///
    /// The default `.modelContainer(for:)` modifier traps if the container can't be created —
    /// e.g. a schema change neither `MigrationPlan` nor lightweight migration can handle — so the
    /// app dies on the launch screen (black screen). Expected migrations go through the plan;
    /// only if that STILL fails do we fall back to wiping. Before wiping we export the durable
    /// rollups (sleep summaries + daily steps) to a JSON backup and restore them into the fresh
    /// store, and raise `historyResetDefaultsKey` so the UI can tell the user. Raw epoch samples
    /// are not backed up — they're already in Apple Health. (#40)
    ///
    /// #131: the destructive wipe MUST be unreachable on a background (no-scene) launch. The
    /// `@main App` struct's stored `container` initializer runs `makeContainer()` on EVERY cold
    /// launch — including the background cold launches iOS performs for `bluetooth-central` /
    /// `fetch` / `processing` BGTasks and CoreBluetooth state restoration. On such a launch,
    /// post-reboot / pre-first-unlock, the store file is temporarily unreadable under Data
    /// Protection (`CompleteUntilFirstUserAuthentication`), so the open throws transiently — and
    /// wiping then would be the exact #131 silent data-loss, just relocated from the BGTask handler
    /// to App.init. We therefore gate the wipe on real foreground presence: at launch,
    /// `UIApplication.shared.applicationState == .background` iff the process was launched into the
    /// background. Only a genuine foreground launch (`.inactive`) may wipe+recover (and surface the
    /// notice); a background launch defers recovery to the next foreground launch — see
    /// `resolveContainer`.
    static func makeContainer() -> ModelContainer {
        // `UIApplication.shared.applicationState` is main-actor state. `makeContainer()` is invoked
        // from the App struct's stored-property initializer, which runs on the main thread at
        // launch, so this read is valid. (`assumeIsolated` would trap only if called off-main,
        // which no caller does — AppDelegate no longer calls `makeContainer()`.)
        let isBackground = MainActor.assumeIsolated {
            UIApplication.shared.applicationState == .background
        }
        let (schema, config) = makeSchemaAndConfig()
        let (container, publishAsShared) = resolveContainer(
            isBackground: isBackground,
            build: { try makeContainerOrThrow() },
            wipeAndRecover: { wipeAndRecoverForeground(schema: schema, config: config) },
            inMemoryFallback: { inMemoryContainer(schema: schema) })
        if publishAsShared {
            sharedContainer = container   // publish for the background handler to reuse (#131)
        }
        return container
    }

    /// The container-recovery decision, factored out of `makeContainer()` so the #131 rule — the
    /// destructive wipe is UNREACHABLE on a background (no-scene) launch — is unit-testable without
    /// a real launch context. Returns the container to use and whether it may be published as the
    /// process-wide `sharedContainer`.
    ///
    /// - Successful open → use it, publish it.
    /// - Open FAILS in the FOREGROUND (`isBackground == false`) → `wipeAndRecover` (export →
    ///   removeStoreFiles → fresh + restore + reset notice), publish it. Foreground first-launch /
    ///   migration recovery is UNCHANGED.
    /// - Open FAILS in the BACKGROUND (`isBackground == true`) → do NOT wipe and do NOT touch the
    ///   on-disk files; return a throwaway in-memory container (so the App struct's non-optional
    ///   `container` stays valid) and do NOT publish it. Leaving `sharedContainer` nil makes the
    ///   BGTask handler fall through to `makeContainerOrThrow()`, which re-throws against the still-
    ///   unreadable store → `AppDelegate.handle`'s do/catch aborts the run with `success:false`,
    ///   keeps the scheduler armed, and retries on the next wake. The `.store`/`-shm`/`-wal` files
    ///   are left intact for the next FOREGROUND launch to open cleanly (once Data Protection is
    ///   available) or to wipe+recover WITH the UI notice.
    ///
    /// Rare edge (documented, not over-engineered): if the process was background-launched onto the
    /// in-memory fallback and the user then foregrounds THAT SAME process without a relaunch, they'd
    /// see empty data until the next full relaunch, which recovers. Acceptable — no data is lost.
    static func resolveContainer(
        isBackground: Bool,
        build: () throws -> ModelContainer,
        wipeAndRecover: () -> ModelContainer,
        inMemoryFallback: () -> ModelContainer
    ) -> (container: ModelContainer, publishAsShared: Bool) {
        do {
            return (try build(), true)
        } catch {
            #if DEBUG
            print("SwiftData store unusable (\(error)); isBackground=\(isBackground).")
            #endif
            if isBackground {
                // Post-reboot / pre-first-unlock background launch: the store file is temporarily
                // unreadable (Data Protection). Wiping now would be catastrophic AND pointless, so
                // defer recovery to the next foreground launch and leave the on-disk store untouched.
                return (inMemoryFallback(), false)
            }
            return (wipeAndRecover(), true)
        }
    }

    /// The destructive FOREGROUND-ONLY recovery: back up durable rollups, wipe the store files,
    /// rebuild a fresh store, restore the rollups, and raise `historyResetDefaultsKey`. Only reached
    /// from `resolveContainer` when `isBackground == false`. (#40/#131)
    private static func wipeAndRecoverForeground(schema: Schema, config: ModelConfiguration) -> ModelContainer {
        // The app-support directory was already created by the failed `makeContainerOrThrow()`, so
        // `exportBeforeWipe` (which won't create it) can still read the old store.
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

    /// A throwaway in-memory container (same schema) that satisfies the App struct's non-optional
    /// `container` on a background launch where the on-disk store is temporarily unreadable. Never
    /// published as `sharedContainer`, never written to disk. (#131)
    private static func inMemoryContainer(schema: Schema) -> ModelContainer {
        do {
            return try ModelContainer(for: schema,
                                      configurations: ModelConfiguration(schema: schema,
                                                                         isStoredInMemoryOnly: true))
        } catch {
            // In-memory creation essentially never fails; only here is a last resort acceptable.
            fatalError("Unrecoverable in-memory SwiftData store error: \(error)")
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
