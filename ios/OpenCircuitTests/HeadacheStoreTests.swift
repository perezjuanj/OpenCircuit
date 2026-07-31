import SwiftData
import XCTest
@testable import OpenCircuit

/// `HeadacheStore.swift` — the headache LOG (user-entered labels) and the frozen daily risk rows.
///
/// The log is the only source of headache labels in the app: nothing infers one. Every guarantee
/// below is about not corrupting that series — no duplicate row for one logical edit, no Apple
/// Health churn for a field Health can't represent, no stale Health sample left orphaned, no
/// imported row written back into the store it came from, and no re-scoring of a frozen day.
///
/// All fixtures are synthetic (fixed reference date, made-up UUID strings) — no real health data.
@MainActor
final class HeadacheStoreTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_785_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func at(_ hours: Double) -> Date { ref.addingTimeInterval(hours * 3600) }

    private func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return container
    }

    private func makeStore() throws -> LocalStore {
        LocalStore(try makeContainer().mainContext)
    }

    private func uniqueTempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("headache-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        let base = url.deletingPathExtension()
        for u in [url, base.appendingPathExtension("store-shm"), base.appendingPathExtension("store-wal")] {
            try? FileManager.default.removeItem(at: u)
        }
    }

    // MARK: Upsert / edit semantics

    /// `onset` is the natural key, so re-logging the same moment REPLACES rather than appending —
    /// otherwise a user tapping Save twice would double-count a single headache in the label series.
    func testUpsertByOnset() throws {
        let store = try makeStore()
        try store.saveHeadacheEntry(onset: at(0), end: nil, severityRaw: 2, symptoms: ["nausea"])
        try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 4,
                                    symptoms: ["nausea", "light sensitivity"],
                                    notes: "got worse after an hour")

        let rows = try store.allHeadacheEntries()
        XCTAssertEqual(rows.count, 1, "one onset is one headache, not two")
        XCTAssertEqual(rows[0].severityRaw, 4)
        XCTAssertEqual(rows[0].end, at(2))
        XCTAssertEqual(rows[0].symptoms, ["nausea", "light sensitivity"])
        XCTAssertEqual(rows[0].notes, "got worse after an hour")
        XCTAssertEqual(rows[0].source, .user)
    }

    /// Moving an entry's onset (the user corrects "it actually started at 5") RELOCATES the row
    /// instead of inserting a second one, and carries the Apple Health sample UUIDs — including
    /// those of any row already sitting at the destination — so the flush can still delete the now-
    /// stale Health samples. Losing the UUIDs would strand them in Health forever: HealthKit is
    /// append-only and we can only delete objects we can still name.
    func testOnsetMoveRelocatesRowAndCarriesHKUUIDs() throws {
        let store = try makeStore()
        try store.saveHeadacheEntry(onset: at(0), end: at(1), severityRaw: 3, symptoms: [])
        try store.recordHeadacheEntryHK(onset: at(0), hkSampleUUIDs: ["hk-original"], finalized: true)
        try store.saveHeadacheEntry(onset: at(5), end: at(6), severityRaw: 2, symptoms: [])
        try store.recordHeadacheEntryHK(onset: at(5), hkSampleUUIDs: ["hk-clash"], finalized: true)

        // The user moves the first entry's onset onto the second entry's slot.
        try store.saveHeadacheEntry(onset: at(5), end: at(6), severityRaw: 3, symptoms: [],
                                    originalOnset: at(0))

        let rows = try store.allHeadacheEntries()
        XCTAssertEqual(rows.count, 1, "one logical edit must not leave an orphan row behind")
        XCTAssertEqual(rows[0].onset, at(5))
        XCTAssertEqual(Set(rows[0].hkSampleUUIDs), ["hk-original", "hk-clash"],
                       "both stale Health samples must stay nameable so they can be deleted")
        XCTAssertFalse(rows[0].healthWritten, "the entry must be re-written at its new time")
        XCTAssertEqual(try store.pendingHeadacheEntries().map(\.onset), [at(5)])
    }

    /// Notes have no HealthKit representation, so a notes-only edit must not reset the mirror
    /// watermark: re-writing would delete + re-save the same sample in the user's Health store for
    /// nothing, every time they add a line of text.
    func testNotesOnlyEditDoesNotResetHealthWritten() throws {
        let store = try makeStore()
        try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 3, symptoms: ["nausea"])
        try store.recordHeadacheEntryHK(onset: at(0), hkSampleUUIDs: ["hk-1"], finalized: true)

        try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 3, symptoms: ["nausea"],
                                    notes: "took ibuprofen at 09:20")

        let row = try XCTUnwrap(try store.allHeadacheEntries().first)
        XCTAssertEqual(row.notes, "took ibuprofen at 09:20")
        XCTAssertTrue(row.healthWritten, "notes are not clinical — Health must not be re-written")
        XCTAssertTrue(try store.pendingHeadacheEntries().isEmpty)
    }

    /// Possible-trigger tags are ours alone (Apple Health has no field for them), so the same rule
    /// applies as for notes.
    func testTriggerOnlyEditDoesNotResetHealthWritten() throws {
        let store = try makeStore()
        try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 3, symptoms: ["nausea"])
        try store.recordHeadacheEntryHK(onset: at(0), hkSampleUUIDs: ["hk-1"], finalized: true)

        try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 3, symptoms: ["nausea"],
                                    factors: ["poor sleep", "skipped a meal"])

        let row = try XCTUnwrap(try store.allHeadacheEntries().first)
        XCTAssertEqual(row.factors, ["poor sleep", "skipped a meal"])
        XCTAssertTrue(row.healthWritten, "triggers have no HealthKit field — Health is unaffected")
        XCTAssertTrue(try store.pendingHeadacheEntries().isEmpty)
    }

    /// Severity IS the sample's value, so correcting it must re-open the mirror — and the prior
    /// sample's UUID must survive the reset, or the corrected entry would be ADDED alongside the
    /// wrong one rather than replacing it.
    func testSeverityEditDoesResetHealthWritten() throws {
        let store = try makeStore()
        try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 2, symptoms: ["nausea"])
        try store.recordHeadacheEntryHK(onset: at(0), hkSampleUUIDs: ["hk-1"], finalized: true)

        try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 4, symptoms: ["nausea"])

        let row = try XCTUnwrap(try store.allHeadacheEntries().first)
        XCTAssertEqual(row.severityRaw, 4)
        XCTAssertFalse(row.healthWritten, "a clinical change must be corrected in Apple Health")
        XCTAssertEqual(row.hkSampleUUIDs, ["hk-1"],
                       "the superseded sample must still be deletable on the next flush")
        XCTAssertEqual(try store.pendingHeadacheEntries().map(\.onset), [at(0)])
    }

    // MARK: Delete + provenance

    /// Deleting the row is only half the job: the caller needs the sample UUIDs back to remove them
    /// from Apple Health, or the deleted headache stays visible there forever.
    func testDeleteReturnsStaleUUIDs() throws {
        let store = try makeStore()
        try store.saveHeadacheEntry(onset: at(0), end: at(1), severityRaw: 3, symptoms: [])
        try store.recordHeadacheEntryHK(onset: at(0), hkSampleUUIDs: ["hk-1", "hk-2"], finalized: true)

        XCTAssertEqual(try store.deleteHeadacheEntry(onset: at(0)), ["hk-1", "hk-2"])
        XCTAssertTrue(try store.allHeadacheEntries().isEmpty)
        XCTAssertEqual(try store.deleteHeadacheEntry(onset: at(0)), [],
                       "deleting a row that isn't there is a no-op, not an error")
    }

    /// A row IMPORTED from Apple Health must never be written back: it would duplicate the user's
    /// own Health data and open a feedback loop between the two stores (import → write → import).
    func testPendingExcludesHealthImportedRows() throws {
        let store = try makeStore()
        try store.saveHeadacheEntry(onset: at(0), end: at(1), severityRaw: 3, symptoms: [])
        try store.saveHeadacheEntry(onset: at(4), end: at(5), severityRaw: 2, symptoms: [],
                                    source: .healthImport, importedHKUUID: "hk-imported")

        XCTAssertEqual(try store.pendingHeadacheEntries().map(\.onset), [at(0)],
                       "an imported entry is already in Health — writing it back duplicates it")
        XCTAssertEqual(try store.importedHeadacheHKUUIDs(), ["hk-imported"],
                       "a repeated import must be idempotent")
    }

    // MARK: The freeze (Phase 2 rows, migrated in during Phase 1)

    /// THE invariant of the whole feature: a day's score is written exactly once and never
    /// recomputed. Every later precision/AUC number is computed on scores that could not have seen
    /// the label — so if a second pass could overwrite `index`/`bandRaw`, any self-evaluation
    /// becomes a retro-fit and the alerts gate it feeds is theatre.
    ///
    /// A later re-stage or a fired alert may only annotate the row; neither may touch the score.
    func testInsertRiskDayIfAbsentIsIdempotent() throws {
        let store = try makeStore()
        let day = at(0)
        XCTAssertTrue(try store.insertRiskDayIfAbsent(
            StoredHeadacheRisk(day: day, index: 42, bandRaw: 1, ringFeatureCount: 4,
                               coverageFraction: 0.9, contributionsJSON: "{\"hrv\":-0.3}",
                               absentJSON: "{}", computedAt: at(1))))

        XCTAssertFalse(try store.insertRiskDayIfAbsent(
            StoredHeadacheRisk(day: day, index: 99, bandRaw: 2, ringFeatureCount: 6,
                               coverageFraction: 1, contributionsJSON: "{\"hrv\":-9}",
                               absentJSON: "{}", computedAt: at(9))),
            "a day already scored must not be scored again")

        // The re-stage / alert annotations run over the same row.
        try store.markRiskRestaged(day: day, sleepUpdatedAt: at(10))
        try store.markRiskAlerted(day: day)

        let rows = try store.riskDays(from: at(-24), to: at(24))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].index, 42, accuracy: 0.0001, "the frozen score must be untouched")
        XCTAssertEqual(rows[0].bandRaw, 1)
        XCTAssertEqual(rows[0].ringFeatureCount, 4)
        XCTAssertEqual(rows[0].contributionsJSON, "{\"hrv\":-0.3}")
        XCTAssertTrue(rows[0].sleepRestaged, "a re-staged night is EXCLUDED from evaluation, not rescored")
        XCTAssertEqual(rows[0].sleepUpdatedAt, at(10))
        XCTAssertTrue(rows[0].alerted)
    }

    // MARK: Wipe backup (#40 RollupBackup)

    /// The headache log is USER-ENTERED and is not re-syncable from the ring, nor readable back out
    /// of Apple Health once the app's own samples are gone — exactly like the period log, which is
    /// already carried across the last-resort store wipe. Round-trip it through the real
    /// export → JSON → restore path, provenance and Health watermark included, so a restored entry
    /// is not re-written to Health (which would duplicate it) and an imported one is still excluded.
    ///
    /// `exportBeforeWipe` also writes `rollup-backup.json` into the test host's Application Support
    /// as a side effect; `restore` removes it again on success. Nothing reads that file back.
    func testRollupBackupRoundTripsHeadacheRows() throws {
        let url = uniqueTempStoreURL()
        defer { removeStore(at: url) }

        do {
            let seeded = try OpenCircuitApp.makeContainerOrThrow(storeURL: url)
            let store = LocalStore(seeded.mainContext)
            try store.saveHeadacheEntry(onset: at(0), end: at(2), severityRaw: 4,
                                        symptoms: ["nausea"], customSymptoms: ["jaw ache"],
                                        factors: ["poor sleep"], notes: "woke up with it")
            try store.recordHeadacheEntryHK(onset: at(0), hkSampleUUIDs: ["hk-1"], finalized: true)
            try store.saveHeadacheEntry(onset: at(30), end: at(31), severityRaw: 2, symptoms: [],
                                        source: .healthImport, importedHKUUID: "hk-imported")
        }   // release the container before re-opening the same file, as a real wipe would

        let exported = try XCTUnwrap(
            RollupBackup.exportBeforeWipe(config: ModelConfiguration(url: url)),
            "the pre-wipe backup must be able to read the headache log")
        let decoded = try JSONDecoder().decode(RollupBackup.self,
                                               from: JSONEncoder().encode(exported))

        let fresh = try makeContainer()
        decoded.restore(into: fresh)
        let restored = LocalStore(ModelContext(fresh))

        let rows = try restored.allHeadacheEntries()
        XCTAssertEqual(rows.count, 2, "user-entered labels must survive the wipe")
        let logged = try XCTUnwrap(rows.first { $0.onset == at(0) })
        XCTAssertEqual(logged.end, at(2))
        XCTAssertEqual(logged.severityRaw, 4)
        XCTAssertEqual(logged.symptoms, ["nausea"])
        XCTAssertEqual(logged.customSymptoms, ["jaw ache"])
        XCTAssertEqual(logged.factors, ["poor sleep"])
        XCTAssertEqual(logged.notes, "woke up with it")
        XCTAssertTrue(logged.healthWritten)
        XCTAssertEqual(logged.hkSampleUUIDs, ["hk-1"],
                       "the Health samples must stay nameable after a restore")

        let imported = try XCTUnwrap(rows.first { $0.onset == at(30) })
        XCTAssertEqual(imported.source, .healthImport)
        XCTAssertEqual(imported.importedHKUUID, "hk-imported")
        XCTAssertTrue(try restored.pendingHeadacheEntries().isEmpty,
                      "a restored entry must not be re-written to Apple Health")
    }

    /// A backup written by a build that predates the headache log (build ≤ 33) must still decode:
    /// the wipe path is exactly where an upgrading user meets it, and a decode failure there loses
    /// the sleep/period/nap rollups the backup exists to carry.
    func testOlderRollupBackupWithoutHeadacheArraysStillDecodes() throws {
        // Hand-built older JSON. Dates use JSONEncoder's default `.deferredToDate` strategy
        // (seconds since the 2001 reference date), matching what an older build actually wrote.
        let legacy = """
        {"sleep":[{"night":806692800,"asleepMin":445,"deepMin":70,"lightMin":300,"remMin":75,\
        "awakeMin":35,"efficiency":0.92,"inBedStart":806689200,"inBedEnd":806718000,\
        "updatedAt":806721600}],\
        "daily":[{"day":806688000,"steps":5477,"updatedAt":806721600,"healthWrittenSteps":5000}],\
        "periods":[],"naps":[]}
        """
        let decoded = try JSONDecoder().decode(RollupBackup.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.sleep.count, 1)
        XCTAssertEqual(decoded.sleep.first?.asleepMin, 445)
        XCTAssertEqual(decoded.daily.first?.steps, 5477)

        let fresh = try makeContainer()
        decoded.restore(into: fresh)
        let ctx = ModelContext(fresh)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StoredSleepSummary>()).first?.asleepMin, 445)
        XCTAssertTrue(try LocalStore(ctx).allHeadacheEntries().isEmpty,
                      "an absent array restores as NO rows — never a fabricated one")
    }

    // MARK: Schema migration

    /// Adding the two headache models bumps the schema, and a schema the `MigrationPlan` can't
    /// handle traps at `ModelContainer` init on launch — the black screen (#40) whose recovery path
    /// WIPES the un-resyncable local history. This opens a store stamped at the shipped V3 version
    /// through the REAL `MigrationPlan` (via `makeContainerOrThrow`, the same builder the app and
    /// the BGTask handler use) and checks every pre-existing row survives.
    ///
    /// Caveat, stated rather than hidden: the V3 store is written with TODAY's `@Model` class
    /// definitions stamped at `SchemaV3.versionIdentifier`, because the historical column shapes
    /// don't exist in the test target. So this pins the plan/stage wiring and the additive
    /// migration; it does not reproduce a store written by the shipped build-33 binary. An
    /// on-device upgrade over an existing install is still the acceptance test.
    func testV3StoreOpensUnderV4Lightweight() throws {
        let url = uniqueTempStoreURL()
        defer { removeStore(at: url) }

        do {
            let v3 = Schema(versionedSchema: OpenCircuitApp.SchemaV3.self)
            let container = try ModelContainer(
                for: v3, configurations: ModelConfiguration(schema: v3, url: url))
            let ctx = container.mainContext
            ctx.insert(StoredSleepSummary(night: at(0), asleepMin: 445, deepMin: 70, lightMin: 300,
                                          remMin: 75, awakeMin: 35, efficiency: 0.92,
                                          inBedStart: at(-1), inBedEnd: at(7), updatedAt: at(8)))
            ctx.insert(StoredPeriodEntry(start: at(-48), end: at(-24), flowLevelRaw: 2,
                                         symptoms: ["cramping"], notes: "day one",
                                         healthWritten: true, hkSampleUUIDs: ["hk-flow"],
                                         updatedAt: at(-20)))
            ctx.insert(StoredNap(start: at(30), end: at(31), asleepMin: 45, isLongNap: false,
                                 healthWritten: true, updatedAt: at(31)))
            ctx.insert(StoredDaily(day: at(-24), steps: 5477, updatedAt: at(-1)))
            ctx.insert(StoredStepSample(start: at(-3), end: at(-2), delta: 412, healthWritten: true))
            try ctx.save()
        }   // release before re-opening, as a relaunch onto the new build would

        let migrated = try OpenCircuitApp.makeContainerOrThrow(storeURL: url)
        let ctx = ModelContext(migrated)

        let night = try XCTUnwrap(try ctx.fetch(FetchDescriptor<StoredSleepSummary>()).first)
        XCTAssertEqual(night.asleepMin, 445)
        XCTAssertEqual(night.inBedStart, at(-1))
        XCTAssertEqual(night.efficiency, 0.92, accuracy: 0.0001)
        let period = try XCTUnwrap(try ctx.fetch(FetchDescriptor<StoredPeriodEntry>()).first)
        XCTAssertEqual(period.symptoms, ["cramping"])
        XCTAssertEqual(period.hkSampleUUIDs, ["hk-flow"],
                       "a period's Health samples must stay deletable across the migration")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StoredNap>()).first?.asleepMin, 45)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StoredDaily>()).first?.steps, 5477)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StoredStepSample>()).first?.delta, 412)

        // The new tables must be part of the migrated store, and writable. Checked by entity name
        // first: fetching a model the container's schema doesn't know traps rather than throwing.
        let entities = Set(migrated.schema.entities.map(\.name))
        guard entities.contains("StoredHeadacheEntry"), entities.contains("StoredHeadacheRisk") else {
            return XCTFail("the migrated store is missing the headache models — the schema version "
                           + "and MigrationPlan stage must both be added, or an upgrading install "
                           + "traps at launch: \(entities.sorted())")
        }
        let store = LocalStore(ctx)
        try store.saveHeadacheEntry(onset: at(2), end: at(3), severityRaw: 3, symptoms: [])
        XCTAssertEqual(try store.allHeadacheEntries().count, 1)
    }

    /// Companion to the round-trip above, which on its own can't prove the plan was WIRED: SwiftData
    /// performs an implicit lightweight migration for a purely additive change even with no stage
    /// declared, so an open that succeeds doesn't distinguish the two. Pin the structure directly —
    /// a schema added to `schemas` without its stage is drift that only bites on the first
    /// non-additive change, long after anyone remembers this one.
    func testMigrationPlanDeclaresAStageForEveryVersion() throws {
        let schemas = OpenCircuitApp.MigrationPlan.schemas
        XCTAssertEqual(OpenCircuitApp.MigrationPlan.stages.count, schemas.count - 1,
                       "every consecutive pair of schema versions needs a migration stage")

        let newest = try XCTUnwrap(schemas.last)
        let models = Set(newest.models.map { String(describing: $0) })
        XCTAssertTrue(models.contains("StoredHeadacheEntry"), "newest schema models: \(models.sorted())")
        XCTAssertTrue(models.contains("StoredHeadacheRisk"))
        XCTAssertGreaterThan(newest.versionIdentifier, OpenCircuitApp.SchemaV3.versionIdentifier,
                             "a new model set must bump the version or no store ever migrates onto it")
    }
}
