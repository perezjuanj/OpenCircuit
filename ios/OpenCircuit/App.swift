import SwiftUI
import SwiftData
import UIKit
import OpenCircuitKit

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
                // One-time re-key of stored nights from the bedtime day onto the WAKE day
                // (`SleepNightKey`). Must run before any sleep write this launch, or a night staged
                // under the new key could land beside its own un-migrated row.
                .task { OpenCircuitApp.rekeySleepNightsOnce(container) }
                // Backfill the reversibility + provenance columns (SchemaV7). Idempotent and
                // additive; runs AFTER the re-key so it sees each row under its final night key.
                .task { OpenCircuitApp.backfillSleepProvenanceOnce(container) }
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
    /// ⚠️ EVERY VERSION BELOW EXCEPT THE LAST NAMES ONLY FROZEN TYPES — see `Store/FrozenSchemas.swift`.
    /// A historical version that names a LIVE `@Model` does not describe a fixed shape, so the next
    /// column added to that type silently changes this version's checksum and the store on the phone
    /// stops being identifiable. `ShippedStoreMigrationTests.testNoHistoricalSchemaVersionNamesALiveType`
    /// fails if one ever does again.
    ///
    /// ⚠️ CORRECTED, AND THE CORRECTION IS LOAD-BEARING. This note used to say "no store can match
    /// V1, V2 or V3 any more, whatever they are pinned to". **That is false for V3**, measured by
    /// re-scanning every `v1.0-b*` tag and by opening a store written in the b22–b33 shape through
    /// the real plan (`ShippedStoreMigrationTests.testABuild33StoreOpensAndKeepsEveryRow`). What the
    /// scan actually shows:
    ///
    ///   * **V1 — inert.** Six entities. The six-entity builds are b1–b17, and there the summary is
    ///     19 props (b1–b12) or 21 (b13–b20) and `StoredNap` is 6 props. V1 pins the b22 summary
    ///     (29) and the b22 nap (11), a combination no six-entity build ever wrote.
    ///   * **V2 — inert.** Seven entities. `StoredDaytimeTemp` and `StoredStepSample` both first
    ///     shipped at b18, so the entity count goes straight from 6 to 8: no build ever wrote a
    ///     seven-entity store at all.
    ///   * **V3 — NOT inert. It is exactly the shape builds 22 through 33 shipped**: eight entities,
    ///     `StoredSleepSummary` at 29 props, `StoredNap` at 11. Those builds are ~3 weeks old, so a
    ///     phone can still be sitting on one. Pinning V1…V3 to frozen snapshots did not merely add a
    ///     tripwire, it handed b22–b33 stores back a matching version — they open and keep every
    ///     row instead of being wiped.
    ///
    /// So do NOT "tidy" V3 back to naming live types on the argument that nothing can match it. That
    /// edit would wipe every phone still on b22–b33. The claim is now enforced rather than asserted:
    /// `testEachFrozenVersionStillDescribesTheShippedShape` compares `SchemaV3` against a shipped
    /// shape transcribed independently in the test target, and the open test above exercises it
    /// through `makeContainerOrThrow`.
    enum SchemaV1: VersionedSchema {
        static var versionIdentifier = Schema.Version(1, 0, 0)
        static var models: [any PersistentModel.Type] {
            [FrozenModels.StoredSample.self, FrozenModels.StoredCursor.self,
             SchemaV4.StoredSleepSummary.self, FrozenModels.StoredDaily.self,
             FrozenModels.StoredNap.self, FrozenModels.StoredPeriodEntry.self]
        }
    }

    /// Adds `StoredDaytimeTemp` (Trends-only intraday skin temp, kept separate from #41's
    /// nightly baseline). Purely additive — no existing model changed — so this is a
    /// lightweight migration, not a custom stage.
    ///
    /// V2 never existed as an on-disk shape: `StoredDaytimeTemp` and `StoredStepSample` both first
    /// shipped in build 18, so no build ever wrote a store with one and not the other (measured
    /// across the tags). It stays in the plan because removing a version identifier from a shipped
    /// plan is its own risk, and the V1→V2→V3 stages are pure no-op additions.
    enum SchemaV2: VersionedSchema {
        static var versionIdentifier = Schema.Version(2, 0, 0)
        static var models: [any PersistentModel.Type] {
            SchemaV1.models + [FrozenModels.StoredDaytimeTemp.self]
        }
    }

    /// Adds `StoredStepSample` (timestamped step DELTAS — #steps-history) alongside the existing
    /// `StoredDaily` running total, so a step reading's actual observation window survives
    /// instead of being folded away. Purely additive — lightweight migration.
    ///
    /// ⚠️ V3 IS REACHABLE — unlike V1 and V2 it describes a shape that really shipped (builds 22
    /// through 33). See the correction above the `SchemaV1` declaration before changing anything
    /// here.
    enum SchemaV3: VersionedSchema {
        static var versionIdentifier = Schema.Version(3, 0, 0)
        static var models: [any PersistentModel.Type] {
            SchemaV2.models + [FrozenModels.StoredStepSample.self]
        }
    }

    /// Adds `StoredHeadacheEntry` (the user-entered headache log) and `StoredHeadacheRisk` (the
    /// frozen daily signals rows Phase 2 populates) — see `Store/HeadacheStore.swift`. Both are
    /// brand-new tables and every column carries a default, so no existing model changes shape:
    /// lightweight migration, not a custom stage. Both land in ONE version deliberately, so the
    /// Phase-2 risk rows never need a second migration — each migration is a launch-crash surface
    /// whose recovery path wipes un-resyncable raw history (#40).
    ///
    /// V4 IS FROZEN. It shipped in build 34 (`v1.0-b34`, 2026-07-31) and every build since, so its
    /// shape is now the shape on real phones and may no longer be edited in place. While it was
    /// unreleased it WAS edited in place (Phase 2 added `StoredHeadacheRisk.nightKey` without a
    /// bump), which was correct then and is not correct now.
    ///
    /// `StoredSleepSummary` is therefore pinned to the shape build 34 wrote, as a NESTED snapshot,
    /// rather than pointing at the live type. MEASURED, not assumed: with V4 listing the live type
    /// after `hypnogramData` was added, opening a store written by build 34 fails with
    /// `NSCocoaErrorDomain 134504 "Cannot use staged migration with an unknown model version."` —
    /// SwiftData identifies a store by its model-shape checksum, so a changed V4 no longer matches
    /// anything on disk and the whole store is unidentifiable. That routes straight to
    /// `wipeAndRecoverForeground`, which keeps only the rollups and deletes every raw
    /// `StoredSample`/`StoredCursor`/`StoredStepSample`/`StoredDaytimeTemp` row — history the ring
    /// cannot re-supply. With the snapshot below plus a real V5, the same store opens, keeps its
    /// rows, and gains the column by lightweight migration (both arms measured on this toolchain).
    ///
    /// The snapshot is also what makes a V5 legal at all: the "duplicate version checksums"
    /// rejection the previous note warned about happens only when two versions describe the SAME
    /// shapes. V4 (pinned) and V5 (live) now differ by exactly `hypnogramData`.
    enum SchemaV4: VersionedSchema {
        static var versionIdentifier = Schema.Version(4, 0, 0)
        static var models: [any PersistentModel.Type] {
            // `StoredSleepSummary` here resolves to the nested snapshot below — deliberately.
            // Everything else is a FROZEN snapshot too (`Store/FrozenSchemas.swift`); this list
            // named the live types until SchemaV7 widened `StoredNap` and a genuine build-34 store
            // stopped opening (measured: NSCocoaErrorDomain 134504, `ShippedStoreMigrationTests`).
            [FrozenModels.StoredSample.self, FrozenModels.StoredCursor.self,
             StoredSleepSummary.self, FrozenModels.StoredDaily.self,
             FrozenModels.StoredNap.self, FrozenModels.StoredPeriodEntry.self,
             FrozenModels.StoredDaytimeTemp.self, FrozenModels.StoredStepSample.self,
             FrozenModels.StoredHeadacheEntry.self, FrozenModels.StoredHeadacheRisk.self]
        }

        /// `StoredSleepSummary` EXACTLY as build 34 wrote it — the pre-`hypnogramData` shape, which
        /// is also what builds 22 through 37 wrote (measured across the tags; the summary did not
        /// change again until b38).
        ///
        /// It exists only to give V4 the checksum that is on disk; nothing reads or writes through
        /// it, and the live type in `Store/LocalStore.swift` remains the one the app uses. Keep the
        /// property names, types and attributes byte-for-byte identical to build 34's: the class
        /// name is the CoreData entity name, and any divergence re-breaks store identification.
        /// Do NOT add to it — a new column belongs on the live type plus a new schema version.
        @Model final class StoredSleepSummary {
            @Attribute(.unique) var night: Date = Date.distantPast
            var asleepMin: Int = 0
            var deepMin: Int = 0
            var lightMin: Int = 0
            var remMin: Int = 0
            var awakeMin: Int = 0
            var efficiency: Double = 0
            var inBedStart: Date = Date.distantPast
            var inBedEnd: Date = Date.distantPast
            var sleepOnset: Date = Date.distantPast
            var sleepWake: Date = Date.distantPast
            var updatedAt: Date = Date.distantPast
            var skinTempC: Double = 0
            var sleepScore: Int = 0
            var stressScore: Int = 0
            var feelScore: Int = 0
            var hrDeep: Int = 0
            var hrLight: Int = 0
            var hrRem: Int = 0
            var hrAwake: Int = 0
            var movementLevels: [Int] = []
            var osaAvgSpO2: Double = 0
            var osaMinSpO2: Double = 0
            var osaTimeBelow90Sec: Double = 0
            var osaODI: Double = 0
            var osaValidWindows: Int = 0
            var editedInBedStart: Date = Date.distantPast
            var editedInBedEnd: Date = Date.distantPast
            var isManuallyEdited: Bool = false
            init() {}
        }
    }

    /// Adds `StoredSleepSummary.hypnogramData` — the night's staged segments, so a session export can
    /// say WHEN a stage happened and not only how many minutes of it there were. One defaulted column
    /// on an existing model: lightweight migration, not a custom stage (cf. #21).
    ///
    /// V5 IS FROZEN. Its shape is the shape on real phones for **builds 38–43** — CORRECTED: this
    /// note used to say build 35, but `hypnogramData` is absent at the `v1.0-b35`, `b36` and `b37`
    /// tags and first appears at `v1.0-b38` (measured by scanning every `v1.0-b*` tag). The V4
    /// snapshot therefore covers b22–b37, not b22–b34. `StoredSleepSummary` is pinned to a NESTED
    /// snapshot of exactly the b38–b43 shape — the same discipline as V4 above, learned the hard
    /// way TWICE now:
    ///
    /// ⚠️ 🟢 THE BUILD-44 WIPE (2026-08-16): build 44 added the four `widenedRecorded*` columns to
    /// the LIVE type while V5 still pointed at it — so a store written by build 43 matched NO
    /// version in the plan ("Cannot use staged migration with an unknown model version"), routed to
    /// `wipeAndRecoverForeground`, and every raw StoredSample/StoredCursor/StoredStepSample/
    /// StoredDaytimeTemp row was deleted on upgrade — the maintainer's own Trends history among
    /// them. The defaulted-column rule (#21) is NECESSARY but NOT SUFFICIENT once a migration plan
    /// exists: a new column ALWAYS also needs a new `VersionedSchema` whose predecessor pins the
    /// previous live shape. Build 44 was expired on TestFlight the same day.
    enum SchemaV5: VersionedSchema {
        static var versionIdentifier = Schema.Version(5, 0, 0)
        static var models: [any PersistentModel.Type] {
            // `StoredSleepSummary` here resolves to the nested snapshot below — deliberately; every
            // other entry is a FROZEN snapshot (`Store/FrozenSchemas.swift`). See V4.
            [FrozenModels.StoredSample.self, FrozenModels.StoredCursor.self,
             StoredSleepSummary.self, FrozenModels.StoredDaily.self,
             FrozenModels.StoredNap.self, FrozenModels.StoredPeriodEntry.self,
             FrozenModels.StoredDaytimeTemp.self, FrozenModels.StoredStepSample.self,
             FrozenModels.StoredHeadacheEntry.self, FrozenModels.StoredHeadacheRisk.self]
        }

        /// `StoredSleepSummary` EXACTLY as builds 38–43 wrote it — V4's shape + `hypnogramData`,
        /// WITHOUT the `widenedRecorded*` columns. Same rules as V4's snapshot: nothing reads or
        /// writes through it, keep it byte-for-byte, and do NOT add to it — a new column belongs on
        /// the live type plus a new schema version.
        @Model final class StoredSleepSummary {
            @Attribute(.unique) var night: Date = Date.distantPast
            var asleepMin: Int = 0
            var deepMin: Int = 0
            var lightMin: Int = 0
            var remMin: Int = 0
            var awakeMin: Int = 0
            var efficiency: Double = 0
            var inBedStart: Date = Date.distantPast
            var inBedEnd: Date = Date.distantPast
            var sleepOnset: Date = Date.distantPast
            var sleepWake: Date = Date.distantPast
            var updatedAt: Date = Date.distantPast
            var skinTempC: Double = 0
            var sleepScore: Int = 0
            var stressScore: Int = 0
            var feelScore: Int = 0
            var hrDeep: Int = 0
            var hrLight: Int = 0
            var hrRem: Int = 0
            var hrAwake: Int = 0
            var movementLevels: [Int] = []
            var hypnogramData: Data = Data()
            var osaAvgSpO2: Double = 0
            var osaMinSpO2: Double = 0
            var osaTimeBelow90Sec: Double = 0
            var osaODI: Double = 0
            var osaValidWindows: Int = 0
            var editedInBedStart: Date = Date.distantPast
            var editedInBedEnd: Date = Date.distantPast
            var isManuallyEdited: Bool = false
            init() {}
        }
    }

    /// Adds the four `StoredSleepSummary.widenedRecorded*` columns (the kept-edit clamp overlay —
    /// see the live type). Four defaulted Date columns on an existing model: lightweight migration.
    /// V5 (pinned) and V6 (pinned) differ by exactly those four columns, which is what makes the two
    /// checksums distinct and the stage legal.
    ///
    /// ⚠️ V6 IS NOW FROZEN — it shipped in build 45 (`f042639`, the SchemaV6 store-wipe hotfix), so
    /// its shape is the shape on real phones. Both `StoredSleepSummary` AND `StoredNap` are pinned to
    /// nested snapshots of exactly that shape, because V7 adds columns to BOTH. This is the third
    /// time this discipline has been applied and the second time it was learned the hard way; see
    /// the build-44 note on V5.
    enum SchemaV6: VersionedSchema {
        static var versionIdentifier = Schema.Version(6, 0, 0)
        static var models: [any PersistentModel.Type] {
            // `StoredSleepSummary` and `StoredNap` here resolve to the nested snapshots below —
            // deliberately. Every other entry is a FROZEN snapshot (`Store/FrozenSchemas.swift`);
            // they used to be the live types on the argument that V7 does not change them, which is
            // true today and was true of `StoredNap` right up until V7 changed it.
            [FrozenModels.StoredSample.self, FrozenModels.StoredCursor.self,
             StoredSleepSummary.self, FrozenModels.StoredDaily.self,
             StoredNap.self, FrozenModels.StoredPeriodEntry.self,
             FrozenModels.StoredDaytimeTemp.self, FrozenModels.StoredStepSample.self,
             FrozenModels.StoredHeadacheEntry.self, FrozenModels.StoredHeadacheRisk.self]
        }

        /// `StoredSleepSummary` EXACTLY as build 45 wrote it — V5's snapshot + the four
        /// `widenedRecorded*` columns, WITHOUT the provenance/reversibility block. Same rules as the
        /// V4 and V5 snapshots: nothing reads or writes through it, keep it byte-for-byte, and do NOT
        /// add to it — a new column belongs on the live type plus a new schema version.
        @Model final class StoredSleepSummary {
            @Attribute(.unique) var night: Date = Date.distantPast
            var asleepMin: Int = 0
            var deepMin: Int = 0
            var lightMin: Int = 0
            var remMin: Int = 0
            var awakeMin: Int = 0
            var efficiency: Double = 0
            var inBedStart: Date = Date.distantPast
            var inBedEnd: Date = Date.distantPast
            var sleepOnset: Date = Date.distantPast
            var sleepWake: Date = Date.distantPast
            var updatedAt: Date = Date.distantPast
            var skinTempC: Double = 0
            var sleepScore: Int = 0
            var stressScore: Int = 0
            var feelScore: Int = 0
            var hrDeep: Int = 0
            var hrLight: Int = 0
            var hrRem: Int = 0
            var hrAwake: Int = 0
            var movementLevels: [Int] = []
            var hypnogramData: Data = Data()
            var osaAvgSpO2: Double = 0
            var osaMinSpO2: Double = 0
            var osaTimeBelow90Sec: Double = 0
            var osaODI: Double = 0
            var osaValidWindows: Int = 0
            var editedInBedStart: Date = Date.distantPast
            var editedInBedEnd: Date = Date.distantPast
            var isManuallyEdited: Bool = false
            var widenedRecordedInBedStart: Date = Date.distantPast
            var widenedRecordedInBedEnd: Date = Date.distantPast
            var widenedRecordedOnset: Date = Date.distantPast
            var widenedRecordedWake: Date = Date.distantPast
            init() {}
        }

        /// `StoredNap` EXACTLY as build 45 wrote it, WITHOUT `recordedNapSegmentsData` /
        /// `healthWrittenStart` / `healthWrittenEnd`. Same rules as the snapshot above.
        @Model final class StoredNap {
            @Attribute(.unique) var start: Date = Date.distantPast
            var end: Date = Date.distantPast
            var asleepMin: Int = 0
            var isLongNap: Bool = false
            var healthWritten: Bool = false
            var updatedAt: Date = Date.distantPast
            var isManuallyEdited: Bool = false
            var isManuallyAdded: Bool = false
            var napSegmentsData: Data? = nil
            var editedStart: Date? = nil
            var editedEnd: Date? = nil
            init() {}
        }
    }

    /// Adds the reversibility + provenance block. On `StoredSleepSummary`: `recordedHypnogramData`
    /// (the ring's own hypnogram, so an edit stops being irreversible), `measuredAsleepSeconds`,
    /// `assertedAsleepSeconds`, `coverageFraction`, `longestGapSeconds`, and the `sleepBasis` stamp.
    /// On `StoredNap`: `recordedNapSegmentsData` and the `healthWritten{Start,End}` span.
    ///
    /// ADDITIVE ONLY, and every column is DEFAULTED, so this is a lightweight stage: no existing
    /// value is read, rewritten, or reinterpreted by the migration itself. The one BACKFILL — copying
    /// `hypnogramData` into `recordedHypnogramData` for rows that are still pure recordings — runs
    /// AFTER the container opens (`LocalStore.backfillRecordedHypnograms`), not inside the migration,
    /// so a failure there can never take the store down with it.
    ///
    /// ⚠️ REHEARSE THIS ON A POPULATED DEVICE STORE, NOT A SIMULATOR — the numbered procedure is
    /// `docs/RUNBOOK_SCHEMA_MIGRATION_REHEARSAL.md`, and it starts from a PRE-45 build because a
    /// rehearsal that starts from a current-build store skips the defect entirely. Build 44 added
    /// four defaulted columns without a schema version and deleted every raw history row on upgrade;
    /// build 45 was the hotfix. A migration in this area gets a device rehearsal.
    ///
    /// V7 is the CURRENT version and therefore the ONLY one that may name live types. When V8 is
    /// added, V7 must first be pinned to snapshots of whatever the live shapes are the day V7 ships.
    enum SchemaV7: VersionedSchema {
        static var versionIdentifier = Schema.Version(7, 0, 0)
        static var models: [any PersistentModel.Type] {
            [StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self,
             StoredNap.self, StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
             StoredHeadacheEntry.self, StoredHeadacheRisk.self]
        }
    }

    enum MigrationPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self,
             SchemaV6.self, SchemaV7.self]
        }
        static var stages: [MigrationStage] {
            [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
             .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
             .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self),
             .lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self),
             .lightweight(fromVersion: SchemaV5.self, toVersion: SchemaV6.self),
             .lightweight(fromVersion: SchemaV6.self, toVersion: SchemaV7.self)]
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
        // Must list exactly `SchemaV7.models` (the CURRENT version) — the container is built from
        // THIS array, so a model present only in the versioned schema enum would migrate in and then
        // be unreachable. Every type here is the LIVE one, never a frozen snapshot; the current
        // version is the ONLY place a live type may appear. (`ShippedStoreMigrationTests` asserts
        // both halves of that rule.)
        let schema = Schema([StoredSample.self, StoredCursor.self,
                             StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
                             StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
                             StoredHeadacheEntry.self, StoredHeadacheRisk.self])
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

    /// Re-key stored sleep summaries from the bedtime day onto the WAKE day, at most once — same
    /// gating pattern as the scrubs above. Fixes the key collision that let one night silently
    /// discard another (`SleepNightKey`); `rekeySleepNightsToWakeDay` is idempotent and
    /// non-destructive, so a retry after a failure is safe.
    ///
    /// This is the BACKSTOP, not the guarantee. A background launch (BGTask / CoreBluetooth
    /// restoration) connects no scene, so this `.task` never runs there — `LocalStore` therefore
    /// gates its own first sleep write on the same flag. This path exists so a launch that writes no
    /// sleep at all still migrates the history the UI reads.
    @MainActor
    static func rekeySleepNightsOnce(_ container: ModelContainer) {
        // Routed through `ensureNightKeyMigrated` rather than duplicating the latch: it is the one
        // place that knows not to latch over a store it never saw a row in (the #131 in-memory
        // fallback container is empty by construction) and not to latch on a refused run.
        LocalStore(container.mainContext).ensureNightKeyMigrated()
    }

    /// Fill the SchemaV7 reversibility + provenance columns on rows written before they existed.
    ///
    /// Deliberately NOT latched behind a UserDefaults flag: it is idempotent (it skips any row that
    /// already carries a basis stamp), it is cheap (one fetch over the sleep table, which is one row
    /// per night), and un-latched means a row that arrives later — from a restore, or from a night
    /// re-keyed after the first run — is still picked up. It runs OUTSIDE the SwiftData migration on
    /// purpose: a backfill that throws inside a migration takes the whole store down with it, which
    /// is how build 44 deleted every raw history row on upgrade.
    @MainActor
    static func backfillSleepProvenanceOnce(_ container: ModelContainer) {
        let changed = LocalStore(container.mainContext).backfillSleepProvenance()
        if changed > 0 {
            ringLog.info("[OC] sleep-provenance: backfilled \(changed, privacy: .public) night rows")
        }
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
        // Optional keeps decoding compatible with a backup written by an older app build.
        var sleepOnset, sleepWake: Date?
        var editedInBedStart, editedInBedEnd: Date?
        var isManuallyEdited: Bool?
        /// ⚠️ THE TIMELINE AND ITS PROVENANCE MUST SURVIVE A WIPE, or the recovered row keeps its
        /// asleep MINUTES while losing every way to check them. Before these fields existed, a
        /// store-wipe recovery restored an edited night's 403 asserted-inclusive minutes and its
        /// 0.918 efficiency but dropped the hypnogram entirely — so the export contract then
        /// reported that night as "not recorded" (`hypnogram == []`) while the fabricated total
        /// lived on, now unfalsifiable. `recordedHypnogram` is the ring's own reading and is the one
        /// piece that cannot be re-derived from anything else after a wipe.
        var hypnogramData: Data?
        var recordedHypnogramData: Data?
        var measuredAsleepSeconds, assertedAsleepSeconds: Double?
        var coverageFraction, longestGapSeconds, measuredEfficiency: Double?
        var sleepBasis: String?
        /// ⚠️ THE REST OF THE ROW. Until these existed the "durable rollup" backup restored a night's
        /// asleep MINUTES and dropped its score, its stress and feel scores, its skin temperature,
        /// its per-stage heart rates, its movement bars and its whole OSA block — so a recovered
        /// night came back looking measured while every number a user could sanity-check it against
        /// was silently gone. None of it is re-derivable: `skinTempC` comes from a LIVE-only
        /// descriptor the ring never re-sends, and the scores are computed from raw samples the same
        /// wipe deletes. Optional, so a backup written by an older build still decodes.
        var skinTempC: Double?
        var sleepScore, stressScore, feelScore: Int?
        var hrDeep, hrLight, hrRem, hrAwake: Int?
        var movementLevels: [Int]?
        var osaAvgSpO2, osaMinSpO2, osaTimeBelow90Sec, osaODI: Double?
        var osaValidWindows: Int?
        /// The kept-edit clamp overlay (build 45). Without it a restored night loses the record of
        /// what the ring actually recorded around a user's edit, which is the input the clamp uses.
        var widenedRecordedInBedStart, widenedRecordedInBedEnd: Date?
        var widenedRecordedOnset, widenedRecordedWake: Date?
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
    /// Naps (#76). The AUTO-DETECTED window is re-derivable from synced sleep — the rest is not.
    ///
    /// ⚠️ Until the overlay fields below existed this struct carried six columns of fourteen, and
    /// what it dropped was precisely the part a PERSON created: `isManuallyAdded` (a nap the ring
    /// never detected — restoring it as `false` hands it to auto re-detection to overwrite),
    /// `isManuallyEdited` + `editedStart`/`editedEnd` (the corrected window, so a restored nap
    /// silently snapped back to the machine's guess), and `napSegmentsData` (the staged hypnogram
    /// Apple Health is written from). `healthWrittenStart`/`healthWrittenEnd` round-trip for the
    /// same reason `healthWritten` does: without them `flushNaps` cannot clean a stale wider span
    /// out of Health. All optional, so an older backup still decodes.
    struct Nap: Codable {
        var start: Date
        var end: Date
        var asleepMin: Int
        var isLongNap: Bool
        var healthWritten: Bool
        var updatedAt: Date
        var isManuallyEdited: Bool?
        var isManuallyAdded: Bool?
        var napSegmentsData: Data?
        var recordedNapSegmentsData: Data?
        var editedStart, editedEnd: Date?
        var healthWrittenStart, healthWrittenEnd: Date?
    }
    /// User-ENTERED headache logs (headache-signals Phase 1). Same irreplaceability argument as
    /// `Period` above, and it bites harder: this is the ground-truth LABEL series the detector can
    /// only ever be validated against, HealthKit is never read back as a recovery source (import is
    /// a user-initiated one-off, not a restore path), and the developer doesn't get headaches — so
    /// a tester's labels lost to a wipe are lost for good. `healthWritten` + `hkSampleUUIDs` round-
    /// trip so a restored entry is neither re-written to Health nor orphaned there (an orphaned
    /// UUID is a sample the user can never delete through our UI again).
    struct Headache: Codable {
        var onset: Date
        var end: Date?
        var severityRaw: Int
        var symptoms: [String]
        var customSymptoms: [String]
        var factors: [String]
        var notes: String
        var sourceRaw: String
        var importedHKUUID: String?
        var healthWritten: Bool
        var hkSampleUUIDs: [String]
        var updatedAt: Date
    }
    /// Frozen daily signals rows (Phase 2+). Backed up because the freeze is the point: a row is
    /// written once and NEVER recomputed, so a wiped row cannot be regenerated — the day would
    /// silently vanish from every later precision/AUC number instead of being restored.
    struct RiskDay: Codable {
        var day: Date
        /// Optional so a backup written before the timezone-stable key existed still decodes.
        var nightKey: Date?
        var index: Double
        var bandRaw: Int
        var ringFeatureCount: Int
        var coverageFraction: Double
        var contributionsJSON: String
        var absentJSON: String
        var computedAt: Date
        var sleepUpdatedAt: Date?
        var sleepRestaged: Bool
        var alerted: Bool
        var postUnlock: Bool
        var updatedAt: Date
    }
    var sleep: [Sleep]
    var daily: [Daily]
    var periods: [Period]
    var naps: [Nap]
    // Optional (like `Sleep.sleepOnset` above) so a backup file written by a shipped pre-headache
    // build — which has no such keys — still decodes instead of failing the whole restore.
    var headaches: [Headache]? = nil
    var riskDays: [RiskDay]? = nil

    private static var backupURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("rollup-backup.json")
    }

    /// Read the rollup tables from the (un-openable-as-current) store using a schema LIMITED to
    /// just those tables — so a schema change to the sample/cursor tables can't block reading
    /// them — and write a JSON snapshot. Returns the snapshot (nil if even this best-effort read
    /// fails).
    ///
    /// ⚠️ TWO GAPS HERE, both pre-existing and both deliberately left alone by the M1 fix — they are
    /// reported so the next person does not re-derive them from a comment that was wrong:
    ///
    ///  1. **The JSON file is WRITE-ONLY.** This comment used to end "the file persists so a crash
    ///     mid-wipe can't lose the rollups". It cannot do that: `rollup-backup.json` is written
    ///     here and deleted in `restore(into:)`, and **nothing in the app ever reads it back** —
    ///     grep the target. Only the in-memory return value is used. A crash between
    ///     `removeStoreFiles` and `restore` therefore loses the rollups anyway, with the file
    ///     sitting on disk unread. Making it real means reading it at launch when it exists.
    ///  2. **`StoredDaytimeTemp` is not backed up** — it is absent from the limited schema below,
    ///     so the Trends intraday skin-temperature series is destroyed permanently by a wipe. Skin
    ///     temp is LIVE-only (the `0x10`/`0x87` descriptor); the ring holds no history of it and
    ///     can never re-send it, and it is deliberately not mirrored into Apple Health, so there is
    ///     no second copy anywhere. Adding it here is a behaviour change to the wipe path and was
    ///     out of scope for a comment-and-tests fix; it is the single biggest remaining hole.
    static func exportBeforeWipe(config: ModelConfiguration) -> RollupBackup? {
        let schema = Schema([StoredSleepSummary.self, StoredDaily.self,
                             StoredPeriodEntry.self, StoredNap.self,
                             StoredHeadacheEntry.self, StoredHeadacheRisk.self])
        let limited = ModelConfiguration(schema: schema, url: config.url)
        guard let container = try? ModelContainer(for: schema, configurations: limited) else { return nil }
        let ctx = ModelContext(container)
        let sleepRows = (try? ctx.fetch(FetchDescriptor<StoredSleepSummary>())) ?? []
        let dailyRows = (try? ctx.fetch(FetchDescriptor<StoredDaily>())) ?? []
        let periodRows = (try? ctx.fetch(FetchDescriptor<StoredPeriodEntry>())) ?? []
        let napRows = (try? ctx.fetch(FetchDescriptor<StoredNap>())) ?? []
        let headacheRows = (try? ctx.fetch(FetchDescriptor<StoredHeadacheEntry>())) ?? []
        let riskRows = (try? ctx.fetch(FetchDescriptor<StoredHeadacheRisk>())) ?? []
        let backup = RollupBackup(
            sleep: sleepRows.map {
                Sleep(night: $0.night, asleepMin: $0.asleepMin, deepMin: $0.deepMin,
                      lightMin: $0.lightMin, remMin: $0.remMin, awakeMin: $0.awakeMin,
                      efficiency: $0.efficiency, inBedStart: $0.inBedStart,
                      inBedEnd: $0.inBedEnd, updatedAt: $0.updatedAt,
                      sleepOnset: $0.sleepOnset, sleepWake: $0.sleepWake,
                      editedInBedStart: $0.editedInBedStart, editedInBedEnd: $0.editedInBedEnd,
                      isManuallyEdited: $0.isManuallyEdited,
                      hypnogramData: $0.hypnogramData,
                      recordedHypnogramData: $0.recordedHypnogramData,
                      measuredAsleepSeconds: $0.measuredAsleepSeconds,
                      assertedAsleepSeconds: $0.assertedAsleepSeconds,
                      coverageFraction: $0.coverageFraction,
                      longestGapSeconds: $0.longestGapSeconds,
                      measuredEfficiency: $0.measuredEfficiency,
                      sleepBasis: $0.sleepBasis,
                      skinTempC: $0.skinTempC,
                      sleepScore: $0.sleepScore, stressScore: $0.stressScore,
                      feelScore: $0.feelScore,
                      hrDeep: $0.hrDeep, hrLight: $0.hrLight, hrRem: $0.hrRem,
                      hrAwake: $0.hrAwake,
                      movementLevels: $0.movementLevels,
                      osaAvgSpO2: $0.osaAvgSpO2, osaMinSpO2: $0.osaMinSpO2,
                      osaTimeBelow90Sec: $0.osaTimeBelow90Sec, osaODI: $0.osaODI,
                      osaValidWindows: $0.osaValidWindows,
                      widenedRecordedInBedStart: $0.widenedRecordedInBedStart,
                      widenedRecordedInBedEnd: $0.widenedRecordedInBedEnd,
                      widenedRecordedOnset: $0.widenedRecordedOnset,
                      widenedRecordedWake: $0.widenedRecordedWake)
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
                    isLongNap: $0.isLongNap, healthWritten: $0.healthWritten,
                    updatedAt: $0.updatedAt,
                    isManuallyEdited: $0.isManuallyEdited, isManuallyAdded: $0.isManuallyAdded,
                    napSegmentsData: $0.napSegmentsData,
                    recordedNapSegmentsData: $0.recordedNapSegmentsData,
                    editedStart: $0.editedStart, editedEnd: $0.editedEnd,
                    healthWrittenStart: $0.healthWrittenStart,
                    healthWrittenEnd: $0.healthWrittenEnd)
            },
            headaches: headacheRows.map {
                Headache(onset: $0.onset, end: $0.end, severityRaw: $0.severityRaw,
                         symptoms: $0.symptoms, customSymptoms: $0.customSymptoms,
                         factors: $0.factors, notes: $0.notes, sourceRaw: $0.sourceRaw,
                         importedHKUUID: $0.importedHKUUID, healthWritten: $0.healthWritten,
                         hkSampleUUIDs: $0.hkSampleUUIDs, updatedAt: $0.updatedAt)
            },
            riskDays: riskRows.map {
                RiskDay(day: $0.day, nightKey: $0.nightKey, index: $0.index, bandRaw: $0.bandRaw,
                        ringFeatureCount: $0.ringFeatureCount,
                        coverageFraction: $0.coverageFraction,
                        contributionsJSON: $0.contributionsJSON, absentJSON: $0.absentJSON,
                        computedAt: $0.computedAt, sleepUpdatedAt: $0.sleepUpdatedAt,
                        sleepRestaged: $0.sleepRestaged, alerted: $0.alerted,
                        postUnlock: $0.postUnlock, updatedAt: $0.updatedAt)
            })
        if let url = backupURL, let data = try? JSONEncoder().encode(backup) {
            try? data.write(to: url, options: .atomic)
        }
        return backup
    }

    /// Re-insert the backed-up rollups into the fresh store, then remove the JSON file.
    ///
    /// ⚠️ The unique `night`/`day` keys do NOT make this idempotent — that belief is MEASURED false:
    /// inserting a duplicate unique key makes `save()` succeed and silently destroy a row (see
    /// `LocalStore.rekeySleepNightsToWakeDay`). So keys are normalised through `SleepNightKey` and
    /// de-duplicated here, rather than trusting whatever scheme the backup JSON was written under —
    /// a backup taken before the night-key migration would otherwise re-seed old-scheme keys into a
    /// store that will never be migrated again. Best-effort: a failure just means the dashboard
    /// starts without past history.
    func restore(into container: ModelContainer) {
        let ctx = ModelContext(container)
        var seenNights = Set<Date>()
        for s in sleep {
            // Same refusal rule as the migration: a row with no usable in-bed window keeps its key.
            let night = SleepNightKey.rekeyed(storedNight: s.night,
                                              inBedStart: s.inBedStart,
                                              inBedEnd: s.inBedEnd) ?? s.night
            guard seenNights.insert(Calendar.current.startOfDay(for: night)).inserted else { continue }
            let row = StoredSleepSummary(
                night: night, asleepMin: s.asleepMin, deepMin: s.deepMin, lightMin: s.lightMin,
                remMin: s.remMin, awakeMin: s.awakeMin, efficiency: s.efficiency,
                inBedStart: s.inBedStart, inBedEnd: s.inBedEnd,
                sleepOnset: s.sleepOnset ?? .distantPast,
                sleepWake: s.sleepWake ?? .distantPast, updatedAt: s.updatedAt)
            row.editedInBedStart = s.editedInBedStart ?? .distantPast
            row.editedInBedEnd = s.editedInBedEnd ?? .distantPast
            row.isManuallyEdited = s.isManuallyEdited ?? false
            // Restore the timeline and its provenance. Absent (a backup written by an older build)
            // leaves the live defaults — empty timeline, `-1` sentinels, `unknown` basis — which is
            // honest: those rows genuinely cannot say what they measured.
            row.hypnogramData = s.hypnogramData ?? Data()
            row.recordedHypnogramData = s.recordedHypnogramData ?? Data()
            row.measuredAsleepSeconds = s.measuredAsleepSeconds ?? -1
            row.assertedAsleepSeconds = s.assertedAsleepSeconds ?? -1
            row.coverageFraction = s.coverageFraction ?? -1
            row.longestGapSeconds = s.longestGapSeconds ?? -1
            row.measuredEfficiency = s.measuredEfficiency ?? -1
            row.sleepBasis = s.sleepBasis ?? ""
            // The rest of the row. Absent (an older backup) leaves the live defaults, which read as
            // "no value" everywhere: a 0 score hides the badge, a 0 skin temp is filtered by the
            // Trends reader, an empty `movementLevels` draws no bar.
            row.skinTempC = s.skinTempC ?? 0
            row.sleepScore = s.sleepScore ?? 0
            row.stressScore = s.stressScore ?? 0
            row.feelScore = s.feelScore ?? 0
            row.hrDeep = s.hrDeep ?? 0
            row.hrLight = s.hrLight ?? 0
            row.hrRem = s.hrRem ?? 0
            row.hrAwake = s.hrAwake ?? 0
            row.movementLevels = s.movementLevels ?? []
            row.osaAvgSpO2 = s.osaAvgSpO2 ?? 0
            row.osaMinSpO2 = s.osaMinSpO2 ?? 0
            row.osaTimeBelow90Sec = s.osaTimeBelow90Sec ?? 0
            row.osaODI = s.osaODI ?? 0
            row.osaValidWindows = s.osaValidWindows ?? 0
            row.widenedRecordedInBedStart = s.widenedRecordedInBedStart ?? .distantPast
            row.widenedRecordedInBedEnd = s.widenedRecordedInBedEnd ?? .distantPast
            row.widenedRecordedOnset = s.widenedRecordedOnset ?? .distantPast
            row.widenedRecordedWake = s.widenedRecordedWake ?? .distantPast
            ctx.insert(row)
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
            let nap = StoredNap(start: n.start, end: n.end, asleepMin: n.asleepMin,
                                isLongNap: n.isLongNap, healthWritten: n.healthWritten,
                                updatedAt: n.updatedAt)
            // The user's own overlay. `isManuallyAdded` in particular is load-bearing: `saveNap`
            // PRESERVES a manual nap across auto re-detection, so restoring it as `false` would let
            // the next detection pass quietly delete a nap the person entered by hand.
            nap.isManuallyEdited = n.isManuallyEdited ?? false
            nap.isManuallyAdded = n.isManuallyAdded ?? false
            nap.napSegmentsData = n.napSegmentsData
            nap.recordedNapSegmentsData = n.recordedNapSegmentsData
            nap.editedStart = n.editedStart
            nap.editedEnd = n.editedEnd
            nap.healthWrittenStart = n.healthWrittenStart ?? .distantPast
            nap.healthWrittenEnd = n.healthWrittenEnd ?? .distantPast
            ctx.insert(nap)
        }
        for h in headaches ?? [] {
            ctx.insert(StoredHeadacheEntry(
                onset: h.onset, end: h.end, severityRaw: h.severityRaw,
                symptoms: h.symptoms, customSymptoms: h.customSymptoms, factors: h.factors,
                notes: h.notes, sourceRaw: h.sourceRaw, importedHKUUID: h.importedHKUUID,
                healthWritten: h.healthWritten, hkSampleUUIDs: h.hkSampleUUIDs,
                updatedAt: h.updatedAt))
        }
        for r in riskDays ?? [] {
            ctx.insert(StoredHeadacheRisk(
                day: r.day, nightKey: r.nightKey ?? .distantPast,
                index: r.index, bandRaw: r.bandRaw,
                ringFeatureCount: r.ringFeatureCount, coverageFraction: r.coverageFraction,
                contributionsJSON: r.contributionsJSON, absentJSON: r.absentJSON,
                computedAt: r.computedAt, sleepUpdatedAt: r.sleepUpdatedAt,
                sleepRestaged: r.sleepRestaged, alerted: r.alerted, postUnlock: r.postUnlock,
                updatedAt: r.updatedAt))
        }
        if (try? ctx.save()) != nil, let url = Self.backupURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
