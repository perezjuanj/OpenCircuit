import SwiftData
import XCTest
@testable import OpenCircuit

// SHIPPED-STORE MIGRATION — can the app still open the stores that are on real phones?
//
// WHY THIS SUITE EXISTS, AND WHY `SchemaMigrationTests` COULD NOT CATCH THIS.
//
// `SchemaMigrationTests.writeShippedV4Store()` builds its "build 34 store" from
// `Schema(OpenCircuitApp.SchemaV4.models)` — the CURRENT definition of V4. Every entity V4 does not
// pin therefore resolves to the LIVE type, so the "old" store it writes is whatever today's code
// says, and the open that follows compares that against the very same definition. It agrees with
// itself by construction. It passed green through the change that made a genuine build-43 store
// unopenable.
//
// This suite is structurally different: the shipped shapes are declared BELOW, in this file,
// transcribed from the `v1.0-b34` / `v1.0-b43` / `v1.0-b45` git tags, and nothing here reads the
// app's schema enums to decide what an old store looks like. The store is then opened through
// `OpenCircuitApp.makeContainerOrThrow(storeURL:)` — the actual production builder, with the actual
// `MigrationPlan` — not a hand-rolled plan.
//
// WHAT FAILURE MEANS. A throw out of `makeContainerOrThrow` is not a test detail. In production
// `makeContainer` catches exactly that throw and calls `wipeAndRecoverForeground`, which deletes
// every `StoredSample`, `StoredCursor`, `StoredStepSample` and `StoredDaytimeTemp` row on the
// device. That is the build-44 wipe (2026-08-16), and it reached real phones.
@MainActor
final class ShippedStoreMigrationTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-shipped-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        storeURL = nil
        try super.tearDownWithError()
    }

    private let night = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Writing a genuinely shipped store

    /// Write a store in one of the shapes that actually shipped, seeded with a row from each table
    /// the wipe path destroys plus the two rollups it keeps.
    private func writeShippedStore(_ models: [any PersistentModel.Type],
                                   summary: @escaping (ModelContext) -> Void) throws {
        let schema = Schema(models)
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let context = ModelContext(container)
        summary(context)

        context.insert(ShippedB45.StoredSample(kindRaw: "heartRate", start: night, end: night,
                                               value: 58))
        context.insert(ShippedB45.StoredCursor(kindRaw: "heartRate", last: night))

        let step = ShippedB45.StoredStepSample()
        step.start = night
        step.end = night.addingTimeInterval(900)
        step.delta = 137
        context.insert(step)

        let temp = ShippedB45.StoredDaytimeTemp()
        temp.time = night
        temp.celsius = 33.5
        context.insert(temp)

        // The entity nobody was watching — and a MANUALLY EDITED one, because that overlay is the
        // part of a nap the ring can never re-derive.
        let nap = ShippedB45.StoredNap()
        nap.start = night.addingTimeInterval(3_600)
        nap.end = night.addingTimeInterval(7_200)
        nap.asleepMin = 45
        nap.isManuallyEdited = true
        nap.editedStart = night.addingTimeInterval(3_900)
        context.insert(nap)

        try context.save()
    }

    /// Open it the way the app does at launch: `makeContainerOrThrow` is the real production
    /// builder — the same schema and the same `MigrationPlan` `App.init` uses.
    private func openExactlyAsTheAppDoes() throws -> ModelContainer {
        try OpenCircuitApp.makeContainerOrThrow(storeURL: storeURL)
    }

    private func assertRawHistorySurvived(_ container: ModelContainer,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredSample>()).count, 1,
                       "raw samples are un-resyncable; a failed open deletes them", file: file, line: line)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredCursor>()).count, 1,
                       "the sync cursor decides what the ring re-sends", file: file, line: line)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredStepSample>()).count, 1,
                       "steps have no ring-side backlog to heal them", file: file, line: line)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredDaytimeTemp>()).count, 1,
                       "skin temp is live-only; a missed window can never be back-filled",
                       file: file, line: line)
        let naps = try context.fetch(FetchDescriptor<StoredNap>())
        XCTAssertEqual(naps.count, 1, file: file, line: line)
        XCTAssertEqual(naps.first?.isManuallyEdited, true,
                       "the user's own nap edit must survive the migration", file: file, line: line)
    }

    // MARK: - The shapes that can be on a phone today

    /// Builds 22–33 — the EIGHT-entity era, before `StoredHeadacheEntry` / `StoredHeadacheRisk`
    /// arrived at b34. Same 29-column summary and 11-column nap as b34; the entity set is the
    /// difference.
    ///
    /// This is the arm that refutes the old "V1, V2 and V3 are inert, no store can match them"
    /// note. Re-measured across every `v1.0-b*` tag: the entity count goes 6 (b1–b17) → 8 (b18–b33)
    /// → 10 (b34–b45), `StoredNap` goes 6 → 11 props at b22, and `StoredSleepSummary` sits at 29
    /// props for b22–b37 — so `SchemaV3`, once pinned, describes b22–b33 EXACTLY. Those builds are
    /// weeks old, not archaeology. Opened here through the real plan, so the claim is enforced.
    func testABuild33StoreOpensAndKeepsEveryRow() throws {
        try writeShippedStore(ShippedModels.b33) { context in
            let row = ShippedB34.StoredSleepSummary()
            row.night = self.night
            row.asleepMin = 388
            context.insert(row)
        }
        let container = try openExactlyAsTheAppDoes()
        try assertRawHistorySurvived(container)
        let summaries = try ModelContext(container).fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(summaries.first?.asleepMin, 388)
    }

    /// Builds 34–37. `StoredSleepSummary` at 29 columns, `StoredNap` at 11.
    func testABuild34StoreOpensAndKeepsEveryRow() throws {
        try writeShippedStore(ShippedModels.b34) { context in
            let row = ShippedB34.StoredSleepSummary()
            row.night = self.night
            row.asleepMin = 431
            row.deepMin = 92
            context.insert(row)
        }
        let container = try openExactlyAsTheAppDoes()
        try assertRawHistorySurvived(container)
        let summaries = try ModelContext(container).fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(summaries.first?.asleepMin, 431)
    }

    /// Builds 38–43 — the newest pre-45 shape, and the one most likely to be sitting on a tester's
    /// phone. `hypnogramData` present, `widenedRecorded*` absent.
    func testABuild43StoreOpensAndKeepsEveryRow() throws {
        try writeShippedStore(ShippedModels.b43) { context in
            let row = ShippedB43.StoredSleepSummary()
            row.night = self.night
            row.asleepMin = 403
            row.hypnogramData = Data([0x5B, 0x5D])
            context.insert(row)
        }
        let container = try openExactlyAsTheAppDoes()
        try assertRawHistorySurvived(container)
        let summaries = try ModelContext(container).fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(summaries.first?.asleepMin, 403)
        XCTAssertEqual(summaries.first?.hypnogramData, Data([0x5B, 0x5D]))
    }

    /// Build 45 — the current shipped build. This one is expected to pass even BEFORE the nap pin,
    /// because SchemaV6 already snapshots both entities V7 widens. Keeping it is the control: if
    /// this ever goes red the fix has damaged the shape almost every live phone actually has.
    func testABuild45StoreOpensAndKeepsEveryRow() throws {
        try writeShippedStore(ShippedModels.b45) { context in
            let row = ShippedB45.StoredSleepSummary()
            row.night = self.night
            row.asleepMin = 246
            row.widenedRecordedOnset = self.night
            context.insert(row)
        }
        let container = try openExactlyAsTheAppDoes()
        try assertRawHistorySurvived(container)
        let summaries = try ModelContext(container).fetch(FetchDescriptor<StoredSleepSummary>())
        XCTAssertEqual(summaries.first?.asleepMin, 246)
    }

    // MARK: - Making the blindness impossible to repeat

    /// THE STRUCTURAL GUARD, as a function so the same rule can be aimed at a synthetic plan.
    ///
    /// "Live" is **DERIVED from the plan's own current (last) version**, never from a list of type
    /// names written out by hand. That distinction is the fix for a real hole: the hand-written
    /// version named the ten entities that existed the day it was written, so an ELEVENTH `@Model`
    /// added later would be absent from it and a historical version naming that eleventh type would
    /// pass the guard in silence — "the entity nobody was watching", one entity further along, which
    /// is exactly the failure mode this whole file exists to close.
    private static func historicalVersionsNamingLiveTypes(
        _ plan: [any VersionedSchema.Type]
    ) -> [(version: Schema.Version, names: [String])] {
        guard let current = plan.last else { return [] }
        let live = Set(current.models.map { ObjectIdentifier($0) })
        return plan.dropLast().compactMap { version in
            let names = version.models
                .filter { live.contains(ObjectIdentifier($0)) }
                .map { String(describing: $0) }
            return names.isEmpty ? nil : (version.versionIdentifier, names)
        }
    }

    /// A `VersionedSchema` older than the current one must not name a LIVE `@Model` type: a live
    /// type is not a shape, it is a moving target, and the next column added to it silently
    /// re-breaks every store the version was supposed to identify.
    func testNoHistoricalSchemaVersionNamesALiveType() {
        let all = OpenCircuitApp.MigrationPlan.schemas
        guard let current = all.last else { return XCTFail("empty migration plan") }
        XCTAssertEqual(current.versionIdentifier, OpenCircuitApp.SchemaV7.versionIdentifier,
                       "the CURRENT version is the only one allowed to name live types")
        for offender in Self.historicalVersionsNamingLiveTypes(all) {
            XCTFail("""
                Schema version \(offender.version) names the LIVE type(s) \
                \(offender.names.joined(separator: ", ")). A historical version must pin a FROZEN \
                snapshot (see FrozenModels) — otherwise the next column added to that live type \
                changes this version's checksum, the store on the phone matches nothing, and \
                makeContainer wipes every raw history row. That is the build-44 wipe.
                """)
        }
    }

    /// The derivation above is sound only if the container the app ACTUALLY builds lists exactly the
    /// current version's models — otherwise a new live type could be reachable at runtime while
    /// sitting outside the derived set. `makeSchemaAndConfig`'s own comment claimed this suite
    /// asserted it; until this test, nothing did.
    func testTheLiveContainerListsExactlyTheCurrentVersionsModels() throws {
        let container = try OpenCircuitApp.makeContainerOrThrow(storeURL: storeURL)
        XCTAssertEqual(container.schema, Schema(OpenCircuitApp.SchemaV7.models), """
            The container schema and the CURRENT VersionedSchema have drifted apart. Everything \
            above derives "which types are live" from SchemaV7.models; a type the app can reach \
            but SchemaV7 does not name would be invisible to that derivation.
            """)
    }

    /// PROOF THAT THE GUARD IS DERIVED, NOT HAND-MAINTAINED — the eleventh type.
    ///
    /// `EleventhTypePlan` is a two-version plan whose current version introduces a type that appears
    /// in no list anywhere in this file, and whose historical version names that same live type.
    /// A guard built from a hand-written roster of the ten known entities returns nothing here; the
    /// derived rule names it. This is the regression test for the roster, not for the app plan.
    func testTheGuardCatchesAnEleventhTypeNoHandWrittenListCouldKnow() {
        let offenders = Self.historicalVersionsNamingLiveTypes(
            [EleventhTypePlan.Historical.self, EleventhTypePlan.Current.self])
        XCTAssertEqual(offenders.map(\.names), [["StoredEleventhEntity"]], """
            The rule must flag a live type it was never told about by name. If this is empty the \
            guard has been re-narrowed to a fixed list of entities and stopped generalising.
            """)
    }

    /// Shape tripwire: each frozen version must still describe the shape that SHIPPED. Compared
    /// against this file's independently transcribed snapshots, so a typo in `FrozenModels` — or a
    /// column quietly appended to a frozen snapshot — is caught before it reaches a phone.
    func testEachFrozenVersionStillDescribesTheShippedShape() {
        XCTAssertEqual(Schema(OpenCircuitApp.SchemaV3.models), Schema(ShippedModels.b33), """
            SchemaV3 must describe the store builds 22–33 wrote. This one is NOT a formality: the \
            note above SchemaV1 used to call V1/V2/V3 inert, and for V3 that is false — pinning it \
            handed b22–b33 phones a version that matches, so they migrate instead of being wiped. \
            Anyone who "corrects" that note and re-points V3 at the live types trips this.
            """)
        XCTAssertEqual(Schema(OpenCircuitApp.SchemaV4.models), Schema(ShippedModels.b34),
                       "SchemaV4 must describe the store builds 34–37 wrote")
        XCTAssertEqual(Schema(OpenCircuitApp.SchemaV5.models), Schema(ShippedModels.b43),
                       "SchemaV5 must describe the store builds 38–43 wrote")
        XCTAssertEqual(Schema(OpenCircuitApp.SchemaV6.models), Schema(ShippedModels.b45),
                       "SchemaV6 must describe the store build 45 wrote")
    }

    /// Consecutive versions must stay distinguishable, or SwiftData rejects the whole plan with
    /// "duplicate version checksums" and every launch fails.
    func testEveryConsecutiveSchemaPairIsDistinct() {
        let schemas = OpenCircuitApp.MigrationPlan.schemas
        for (a, b) in zip(schemas, schemas.dropFirst()) {
            XCTAssertNotEqual(Schema(a.models), Schema(b.models),
                              "\(a.versionIdentifier) and \(b.versionIdentifier) describe the same shapes")
        }
    }

    // MARK: - What survives when the wipe DOES run

    /// The pins above are the first line; `RollupBackup` is the last one. It is what a user is left
    /// holding if a future schema change still gets this wrong, and it was carrying six of
    /// `StoredNap`'s fourteen columns and twenty-three of `StoredSleepSummary`'s forty — dropping
    /// exactly the parts nothing can regenerate: the score, the skin temperature, the per-stage
    /// heart rates, the movement bars, the OSA block, and the whole manual nap overlay including
    /// `isManuallyAdded`, which is what stops auto re-detection deleting a nap a person typed in.
    ///
    /// Round-tripped through the REAL export → JSON → restore path, not a hand-built struct.
    func testTheWipeBackupCarriesTheWholeRowNotJustTheMinutes() throws {
        let inBed = night.addingTimeInterval(-3_600)
        do {
            let seeded = try OpenCircuitApp.makeContainerOrThrow(storeURL: storeURL)
            let context = seeded.mainContext
            let row = StoredSleepSummary(night: night, asleepMin: 403, deepMin: 43, lightMin: 329,
                                         remMin: 31, awakeMin: 36, efficiency: 0.918,
                                         inBedStart: inBed, inBedEnd: night)
            row.skinTempC = 33.4
            row.sleepScore = 71
            row.stressScore = 42
            row.feelScore = 3
            row.hrDeep = 51
            row.hrLight = 55
            row.hrRem = 60
            row.hrAwake = 68
            row.movementLevels = [1, 4, 2, 9]
            row.osaMinSpO2 = 88
            row.osaODI = 4.2
            row.osaValidWindows = 17
            row.widenedRecordedOnset = inBed
            context.insert(row)

            let nap = StoredNap(start: night.addingTimeInterval(3_600),
                                end: night.addingTimeInterval(7_200), asleepMin: 45)
            nap.isManuallyAdded = true
            nap.isManuallyEdited = true
            nap.editedStart = night.addingTimeInterval(3_900)
            nap.editedEnd = night.addingTimeInterval(6_900)
            nap.napSegmentsData = Data([0x5B, 0x5D])
            nap.healthWrittenStart = night.addingTimeInterval(3_600)
            nap.healthWrittenEnd = night.addingTimeInterval(7_200)
            context.insert(nap)
            try context.save()
        }   // release the container before re-reading the file, as a real wipe would

        let exported = try XCTUnwrap(
            RollupBackup.exportBeforeWipe(config: ModelConfiguration(url: storeURL)))
        let decoded = try JSONDecoder().decode(RollupBackup.self,
                                               from: JSONEncoder().encode(exported))

        let schema = Schema(OpenCircuitApp.SchemaV7.models)
        let fresh = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema,
                                                            isStoredInMemoryOnly: true))
        decoded.restore(into: fresh)
        let restored = ModelContext(fresh)

        let sleep = try XCTUnwrap(try restored.fetch(FetchDescriptor<StoredSleepSummary>()).first)
        XCTAssertEqual(sleep.sleepScore, 71, "the score is computed from raw rows the wipe deletes")
        XCTAssertEqual(sleep.stressScore, 42)
        XCTAssertEqual(sleep.feelScore, 3)
        XCTAssertEqual(sleep.skinTempC, 33.4,
                       "skin temp is LIVE-only — the ring cannot re-send it, ever")
        XCTAssertEqual(sleep.hrDeep, 51)
        XCTAssertEqual(sleep.hrAwake, 68)
        XCTAssertEqual(sleep.movementLevels, [1, 4, 2, 9])
        XCTAssertEqual(sleep.osaMinSpO2, 88)
        XCTAssertEqual(sleep.osaODI, 4.2)
        XCTAssertEqual(sleep.osaValidWindows, 17)
        XCTAssertEqual(sleep.widenedRecordedOnset, inBed)

        let nap = try XCTUnwrap(try restored.fetch(FetchDescriptor<StoredNap>()).first)
        XCTAssertTrue(nap.isManuallyAdded,
                      "a nap the ring never detected is USER data; restoring it as auto-detected " +
                      "hands it to the next re-detection pass to delete")
        XCTAssertTrue(nap.isManuallyEdited)
        XCTAssertEqual(nap.editedStart, night.addingTimeInterval(3_900))
        XCTAssertEqual(nap.editedEnd, night.addingTimeInterval(6_900))
        XCTAssertEqual(nap.napSegmentsData, Data([0x5B, 0x5D]))
        XCTAssertEqual(nap.healthWrittenEnd, night.addingTimeInterval(7_200),
                       "without the written span, flushNaps cannot clean a shrunk nap out of Health")
    }

    // MARK: - The defect itself, kept as a permanent measurement

    /// `SchemaV5` as it stood before the fix: pinned summary, but the LIVE `StoredNap`.
    private enum V5PointingAtTheLiveNap: VersionedSchema {
        static var versionIdentifier = Schema.Version(5, 0, 0)
        static var models: [any PersistentModel.Type] {
            [StoredSample.self, StoredCursor.self,
             OpenCircuitApp.SchemaV5.StoredSleepSummary.self, StoredDaily.self,
             StoredNap.self, StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
             StoredHeadacheEntry.self, StoredHeadacheRisk.self]
        }
    }

    private enum PlanEndingAtTheLiveNapV5: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [OpenCircuitApp.SchemaV1.self, OpenCircuitApp.SchemaV2.self,
             OpenCircuitApp.SchemaV3.self, OpenCircuitApp.SchemaV4.self,
             V5PointingAtTheLiveNap.self]
        }
        static var stages: [MigrationStage] {
            [.lightweight(fromVersion: OpenCircuitApp.SchemaV1.self,
                          toVersion: OpenCircuitApp.SchemaV2.self),
             .lightweight(fromVersion: OpenCircuitApp.SchemaV2.self,
                          toVersion: OpenCircuitApp.SchemaV3.self),
             .lightweight(fromVersion: OpenCircuitApp.SchemaV3.self,
                          toVersion: OpenCircuitApp.SchemaV4.self),
             .lightweight(fromVersion: OpenCircuitApp.SchemaV4.self,
                          toVersion: V5PointingAtTheLiveNap.self)]
        }
    }

    /// Widening the live `StoredNap` while a historical version still names it makes a genuine
    /// build-43 store unidentifiable. Measured here rather than argued about, so nobody ever
    /// "simplifies" the nap pin away again.
    func testAVersionNamingTheLiveNapCannotIdentifyABuild43Store() throws {
        try writeShippedStore(ShippedModels.b43) { context in
            let row = ShippedB43.StoredSleepSummary()
            row.night = self.night
            context.insert(row)
        }
        let schema = Schema(V5PointingAtTheLiveNap.models)
        XCTAssertThrowsError(
            try ModelContainer(for: schema,
                               migrationPlan: PlanEndingAtTheLiveNapV5.self,
                               configurations: ModelConfiguration(schema: schema, url: storeURL)),
            """
            A version whose StoredNap no longer matches what build 43 wrote must FAIL to identify \
            the store (NSCocoaErrorDomain 134504). If this stops throwing, re-measure before \
            relaxing any pin.
            """)
    }
}

// MARK: - The shipped shapes, transcribed from the git tags
//
// Deliberately declared in the TEST target and NOT derived from `OpenCircuitApp`'s schema enums or
// from `FrozenModels`: if these were read from the code under test the comparison would be circular
// and would agree with itself, which is exactly how the previous suite went blind.
//
// Source of truth: `git show v1.0-b34:ios/OpenCircuit/Store/LocalStore.swift` (and the b43 / b45
// tags), plus `HeadacheStore.swift` and `CycleStore.swift` at the same tags. Verified by scanning
// EVERY `v1.0-b*` tag: the eight entities in `ShippedB45` below are byte-identical from b34 to b45;
// `StoredNap` is unchanged from b22 to b45; `StoredSleepSummary` changed at b38 and again at b45.

/// The eight entities that never changed across b34…b45, plus `StoredNap` (unchanged b22…b45) and
/// the build-45 `StoredSleepSummary`.
private enum ShippedB45 {
    // `kindRaw` / `start` / `end` / `value` carry NO Swift default in the shipped source; the
    // transcription keeps it that way rather than "tidying" defaults in, because a shape is only
    // frozen if it is frozen exactly.
    @Model final class StoredSample {
        var kindRaw: String
        var start: Date
        var end: Date
        var value: Double
        var rawValue: Double? = nil
        var isDelta: Bool = false
        var dailyTotal: Double? = nil
        init(kindRaw: String = "", start: Date = .distantPast, end: Date = .distantPast,
             value: Double = 0) {
            self.kindRaw = kindRaw
            self.start = start
            self.end = end
            self.value = value
        }
    }
    @Model final class StoredCursor {
        @Attribute(.unique) var kindRaw: String
        var last: Date
        init(kindRaw: String = "", last: Date = .distantPast) {
            self.kindRaw = kindRaw
            self.last = last
        }
    }
    @Model final class StoredDaily {
        @Attribute(.unique) var day: Date = Date.distantPast
        var steps: Int = 0
        var updatedAt: Date = Date.distantPast
        var healthWrittenSteps: Int = 0
        init() {}
    }
    @Model final class StoredStepSample {
        var start: Date = Date.distantPast
        var end: Date = Date.distantPast
        var delta: Int = 0
        var healthWritten: Bool = false
        init() {}
    }
    @Model final class StoredDaytimeTemp {
        var time: Date = Date.distantPast
        var celsius: Double = 0
        init() {}
    }
    @Model final class StoredPeriodEntry {
        @Attribute(.unique) var start: Date = Date.distantPast
        var end: Date? = nil
        var flowLevelRaw: Int = 2
        var symptoms: [String] = []
        var notes: String = ""
        var healthWritten: Bool = false
        var hkSampleUUIDs: [String] = []
        var updatedAt: Date = Date()
        init() {}
    }
    @Model final class StoredHeadacheEntry {
        @Attribute(.unique) var onset: Date = Date.distantPast
        var end: Date? = nil
        var severityRaw: Int = 0
        var symptoms: [String] = []
        var customSymptoms: [String] = []
        var factors: [String] = []
        var notes: String = ""
        var sourceRaw: String = "user"
        var importedHKUUID: String? = nil
        var healthWritten: Bool = false
        var hkSampleUUIDs: [String] = []
        var updatedAt: Date = Date()
        init() {}
    }
    @Model final class StoredHeadacheRisk {
        @Attribute(.unique) var day: Date = Date.distantPast
        var nightKey: Date = Date.distantPast
        var index: Double = 0
        var bandRaw: Int = 0
        var ringFeatureCount: Int = 0
        var coverageFraction: Double = 0
        var contributionsJSON: String = ""
        var absentJSON: String = ""
        var computedAt: Date = Date()
        var sleepUpdatedAt: Date? = nil
        var sleepRestaged: Bool = false
        var alerted: Bool = false
        var postUnlock: Bool = false
        var updatedAt: Date = Date()
        init() {}
    }
    /// Unchanged b22 → b45.
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
    /// Build 45: b43's shape + the four `widenedRecorded*` columns.
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
}

/// Builds 38–43: b34's summary + `hypnogramData`.
private enum ShippedB43 {
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

/// Builds 22–37 (V4's era): no `hypnogramData`.
private enum ShippedB34 {
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

private enum ShippedModels {
    /// The seven non-summary entities present from b18 (when `StoredDaytimeTemp` and
    /// `StoredStepSample` arrived together) through b45. `StoredNap` is the b22–b45 shape.
    private static var commonB18: [any PersistentModel.Type] {
        [ShippedB45.StoredSample.self, ShippedB45.StoredCursor.self, ShippedB45.StoredDaily.self,
         ShippedB45.StoredNap.self, ShippedB45.StoredPeriodEntry.self,
         ShippedB45.StoredDaytimeTemp.self, ShippedB45.StoredStepSample.self]
    }
    /// b34 added the two headache entities.
    private static var common: [any PersistentModel.Type] {
        commonB18 + [ShippedB45.StoredHeadacheEntry.self, ShippedB45.StoredHeadacheRisk.self]
    }
    static var b33: [any PersistentModel.Type] { commonB18 + [ShippedB34.StoredSleepSummary.self] }
    static var b34: [any PersistentModel.Type] { common + [ShippedB34.StoredSleepSummary.self] }
    static var b43: [any PersistentModel.Type] { common + [ShippedB43.StoredSleepSummary.self] }
    static var b45: [any PersistentModel.Type] { common + [ShippedB45.StoredSleepSummary.self] }
}

// MARK: - The eleventh type
//
// A `@Model` that is deliberately NOT one of the app's ten entities, and a two-version plan that
// misuses it exactly the way a future maintainer would: the current version introduces it, and the
// historical version — which pins its other entity properly — still names the live one. It stands
// for the entity that gets added AFTER a guard is written, which no roster of today's entities can
// contain.
private enum EleventhTypePlan {
    @Model final class StoredEleventhEntity {
        var day: Date = Date.distantPast
        var value: Double = 0
        init() {}
    }
    /// Its summary is pinned to a frozen snapshot (the correct discipline); the eleventh entity is
    /// left naming the live type (the mistake under test), so it is the ONLY offender expected.
    enum Historical: VersionedSchema {
        static var versionIdentifier = Schema.Version(1, 0, 0)
        static var models: [any PersistentModel.Type] {
            [ShippedB34.StoredSleepSummary.self, StoredEleventhEntity.self]
        }
    }
    enum Current: VersionedSchema {
        static var versionIdentifier = Schema.Version(2, 0, 0)
        static var models: [any PersistentModel.Type] {
            [ShippedB43.StoredSleepSummary.self, StoredEleventhEntity.self]
        }
    }
}
