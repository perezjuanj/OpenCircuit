import SwiftData
import XCTest
@testable import OpenCircuit

// The SwiftData migration path for the `StoredSleepSummary.hypnogramData` column.
//
// WHY THIS SUITE EXISTS. `SchemaV4` shipped in build 34 (`v1.0-b34`) and every build since, so its
// model shapes are the shapes sitting on real phones. Adding the column to the LIVE model while
// `SchemaV4` still pointed at that live type changed V4's checksum, and SwiftData identifies a store
// by exactly that checksum — a store written by build 34 then matched no known version and the open
// failed with `NSCocoaErrorDomain 134504 "Cannot use staged migration with an unknown model
// version."` (measured). `makeContainer` routes that to `wipeAndRecoverForeground`, which keeps the
// rollups and deletes every raw `StoredSample` / `StoredCursor` / `StoredStepSample` /
// `StoredDaytimeTemp` row — the history the ring cannot re-supply. On EVERY existing install, on the
// first foreground launch.
//
// The fix is `SchemaV4` pinning a snapshot of the pre-change shape plus a real `SchemaV5`. This test
// writes a store with that pinned shape — i.e. the bytes build 34 wrote — and then opens it the way
// the app does, so the failure mode above cannot come back silently.
//
// ⚠️ KNOWN LIMIT OF THIS SUITE, AND WHY `ShippedStoreMigrationTests` EXISTS. Everything below builds
// its "old" store from `OpenCircuitApp.SchemaV4.models` — the CURRENT definition of V4 — so it
// compares the code under test against itself. While V4 still named live types for the entities it
// did not pin, "the shape build 34 wrote" here meant "whatever those types look like today", and
// this suite stayed green straight through the change that made a genuine build-43 store
// unopenable. It is kept because the V4↔V5 assertions are still worth having; the non-circular
// coverage — shipped shapes transcribed from the git tags, opened through
// `makeContainerOrThrow` — lives in `ShippedStoreMigrationTests`.
@MainActor
final class SchemaMigrationTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-migration-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        storeURL = nil
        try super.tearDownWithError()
    }

    private let night = Date(timeIntervalSince1970: 1_750_000_000)

    /// Write a store whose `StoredSleepSummary` has exactly build 34's shape, plus one raw sample —
    /// the row class the wipe path destroys and the ring cannot re-send.
    private func writeShippedV4Store() throws {
        let schema = Schema(OpenCircuitApp.SchemaV4.models)
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let context = ModelContext(container)
        let summary = OpenCircuitApp.SchemaV4.StoredSleepSummary()
        summary.night = night
        summary.asleepMin = 431
        summary.deepMin = 92
        context.insert(summary)
        // The FROZEN sample type: V4's model list names snapshots now, and inserting the live class
        // into a schema that does not contain it is a runtime trap, not a compile error.
        context.insert(FrozenModels.StoredSample(kindRaw: "heartRate", start: night, end: night,
                                                 value: 58))
        try context.save()
    }

    /// Open it exactly as the app does — by calling the production builder itself, rather than
    /// re-deriving "the current schema". It used to hand-build `Schema(SchemaV5.models)`, which
    /// stopped being the current version at V6 and again at V7: the test was opening with a schema
    /// no shipped build uses, so it could neither confirm nor deny what a real launch does.
    private func openAsTheAppDoes() throws -> ModelContainer {
        try OpenCircuitApp.makeContainerOrThrow(storeURL: storeURL)
    }

    func testAStoreWrittenByTheShippedV4OpensAndKeepsEveryRow() throws {
        try writeShippedV4Store()

        let container = try openAsTheAppDoes()
        let context = ModelContext(container)

        let summaries = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(summaries.count, 1, "the night must survive the migration, not be wiped")
        XCTAssertEqual(summaries.first?.asleepMin, 431)
        XCTAssertEqual(summaries.first?.deepMin, 92)

        let samples = try context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertEqual(samples.count, 1,
                       "raw samples are un-resyncable — a failed open would have deleted them")
        XCTAssertEqual(samples.first?.value, 58)
    }

    /// The new column has to be usable on a MIGRATED row, not only on a freshly inserted one — the
    /// lightweight stage must actually add it rather than the open merely succeeding.
    func testTheMigratedRowCanCarryAHypnogram() throws {
        try writeShippedV4Store()

        let container = try openAsTheAppDoes()
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredSleepSummary>()).first)
        XCTAssertEqual(row.hypnogramData, Data(),
                       "a pre-existing night reads back as 'not recorded', per the column default")

        row.hypnogramData = Data([0x5B, 0x5D])   // "[]"
        try context.save()
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<StoredSleepSummary>()).first?.hypnogramData,
            Data([0x5B, 0x5D]))
    }

    // MARK: - Why the pinned snapshot has to exist
    //
    // Reconstructed locally rather than argued about: a V4 that points at the LIVE (changed) model
    // is exactly what this branch shipped before the fix, and it cannot open build 34's store at
    // all. Measured here so the necessity of the snapshot never has to be taken on trust — delete
    // the snapshot and `testAStoreWrittenByTheShippedV4OpensAndKeepsEveryRow` starts failing this
    // same way.

    /// `SchemaV4` as it was written BEFORE the fix: the same 4.0.0 identifier over the live models.
    private enum V4PointingAtTheLiveModels: VersionedSchema {
        static var versionIdentifier = Schema.Version(4, 0, 0)
        static var models: [any PersistentModel.Type] {
            [StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self,
             StoredNap.self, StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
             StoredHeadacheEntry.self, StoredHeadacheRisk.self]
        }
    }

    /// The real `MigrationPlan` as it stood before the fix: the shipped V1→V3 chain plus the
    /// edited-in-place V4. The STAGED chain matters — a single-version plan with no stages falls
    /// back to plain inference and opens the store happily, so a shorter reconstruction would have
    /// "disproved" a defect that is entirely real (measured while writing this test).
    private enum PlanEndingAtTheEditedV4: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [OpenCircuitApp.SchemaV1.self, OpenCircuitApp.SchemaV2.self,
             OpenCircuitApp.SchemaV3.self, V4PointingAtTheLiveModels.self]
        }
        static var stages: [MigrationStage] {
            [.lightweight(fromVersion: OpenCircuitApp.SchemaV1.self,
                          toVersion: OpenCircuitApp.SchemaV2.self),
             .lightweight(fromVersion: OpenCircuitApp.SchemaV2.self,
                          toVersion: OpenCircuitApp.SchemaV3.self),
             .lightweight(fromVersion: OpenCircuitApp.SchemaV3.self,
                          toVersion: V4PointingAtTheLiveModels.self)]
        }
    }

    func testEditingV4InPlaceWouldMakeTheShippedStoreUnopenable() throws {
        try writeShippedV4Store()
        let schema = Schema(V4PointingAtTheLiveModels.models)
        XCTAssertThrowsError(
            try ModelContainer(for: schema,
                               migrationPlan: PlanEndingAtTheEditedV4.self,
                               configurations: ModelConfiguration(schema: schema, url: storeURL)),
            """
            A V4 whose shapes no longer match what build 34 wrote must FAIL to identify the store. \
            If this ever stops throwing, re-measure before relaxing the snapshot — this throw is \
            the whole reason SchemaV4 pins its own StoredSleepSummary.
            """)
    }

    /// V4's pinned snapshot exists to differ from the live type by exactly `hypnogramData`. If it
    /// were edited to match, the two versions would describe the SAME shapes and SwiftData rejects
    /// the plan outright with "duplicate version checksums" — the trap the old in-place edit was
    /// chosen to avoid. Building both schemas is what proves they are still distinguishable.
    func testV4AndV5AreDistinctSchemaVersions() throws {
        XCTAssertNotEqual(OpenCircuitApp.SchemaV4.versionIdentifier,
                          OpenCircuitApp.SchemaV5.versionIdentifier)
        let v4 = Schema(OpenCircuitApp.SchemaV4.models)
        let v5 = Schema(OpenCircuitApp.SchemaV5.models)
        XCTAssertNotEqual(v4, v5,
                          "SchemaV4 must stay pinned to the pre-hypnogramData shape build 34 wrote")
    }
}
