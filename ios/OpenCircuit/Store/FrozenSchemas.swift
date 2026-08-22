import Foundation
import SwiftData

/// FROZEN MODEL SNAPSHOTS — the entity shapes that are ON REAL PHONES.
///
/// # Why this file exists
///
/// SwiftData identifies an on-disk store by a checksum over the SHAPES in each `VersionedSchema`.
/// A historical version that lists a LIVE `@Model` type therefore does not describe a fixed shape:
/// it describes whatever that type happens to look like today. Add one column to the live type and
/// every historical version that points at it silently changes checksum, the store on the phone
/// matches nothing in the plan, `ModelContainer` throws
/// `NSCocoaErrorDomain 134504 "Cannot use staged migration with an unknown model version"`, and
/// `OpenCircuitApp.makeContainer` routes that to `wipeAndRecoverForeground` — which deletes every
/// raw `StoredSample` / `StoredCursor` / `StoredStepSample` / `StoredDaytimeTemp` row the ring can
/// never re-supply.
///
/// 🟢 That is not a theory. It has happened twice:
///   * **build 34 → the `hypnogramData` change** — `SchemaV4` pointed at the live summary.
///   * **THE BUILD-44 WIPE (2026-08-16)** — the four `widenedRecorded*` columns landed on the live
///     summary while `SchemaV5` still pointed at it. Every raw history row on every upgrading phone
///     was deleted, the maintainer's own Trends history among them. Build 44 was expired the same
///     day; build 45 was the hotfix.
///
/// Both times the fix was local (pin the ONE entity that changed) and both times the NEXT column on
/// a DIFFERENT entity re-opened the hole — most recently `StoredNap`, "the entity nobody was
/// watching", which SchemaV7 widens by three columns while V1…V5 still pointed at the live type.
/// This file closes the class of defect instead: **no `VersionedSchema` older than the current one
/// may name a live type.** `ShippedStoreMigrationTests.testNoHistoricalSchemaVersionNamesALiveType`
/// fails if one ever does again.
///
/// # What these shapes are, and how they were established
///
/// MEASURED from the shipped git tags, not recalled: `desktop`-side scan over every `v1.0-b*` tag
/// comparing each `@Model`'s stored properties.
///
///   | entity | shipped shape history |
///   |---|---|
///   | `StoredSample`, `StoredCursor`, `StoredDaily`, `StoredPeriodEntry` | unchanged b1 → b45 |
///   | `StoredStepSample`, `StoredDaytimeTemp` | first shipped b18 (together), unchanged b18 → b45 |
///   | `StoredHeadacheEntry`, `StoredHeadacheRisk` | first shipped b34, unchanged b34 → b45 |
///   | `StoredNap` | 6 props b1–b21; **11 props b22 → b45, unchanged**; SchemaV7 adds 3 |
///   | `StoredSleepSummary` | 19 props b1–b12 · 21 b13–b20 · 26 b21 · **29 b22–b37 (V4, and V3)** · **30 b38–b43 (V5)** · **34 b45 (V6)** · 40 on V7 |
///
/// The ENTITY COUNT is itself part of the shape: 6 entities b1–b17, 8 b18–b33, 10 b34–b45. That is
/// why `SchemaV3` (8 entities, 29-prop summary, 11-prop nap) describes builds 22–33 exactly and
/// **is reachable** — see the correction above `OpenCircuitApp.SchemaV1`, and do not restate the
/// retired claim that V1/V2/V3 are all inert.
///
/// (One boundary in this table was re-measured and corrected: the summary's 19→21 step is at b13
/// — `sleepOnset` + `sleepWake` — not b17. It moves nothing, since those are six-entity builds no
/// version describes, but the table is the audit record, so it says what the tags say.)
///
/// Note `hypnogramData` first shipped in **b38**. `SchemaV5`'s note used to say build 35; that was
/// wrong and has been corrected in place — the column is absent at the b35, b36 and b37 tags.
///
/// # Rules
///
/// 1. Nothing reads or writes through these types. They exist ONLY to give a version its checksum.
/// 2. Keep them byte-for-byte. The class name IS the CoreData entity name; any divergence in a
///    property's name, type or optionality re-breaks store identification for the builds that
///    version covers.
/// 3. **Never add a column here.** A new column belongs on the live type in `LocalStore.swift`
///    PLUS a brand-new `SchemaVn` that lists the live types, PLUS a new frozen snapshot of the
///    previous shape if a later version will change it again.
enum FrozenModels {

    // MARK: Entities that never changed shape after they first shipped (spans in the table above)

    /// `StoredSample` as shipped b34 → b45. The un-resyncable raw epoch rows — the table the wipe
    /// path destroys, and the reason all of this matters.
    @Model final class StoredSample {
        var kindRaw: String
        var start: Date
        var end: Date
        var value: Double
        var rawValue: Double?
        var isDelta: Bool = false
        var dailyTotal: Double?
        init(kindRaw: String = "", start: Date = .distantPast, end: Date = .distantPast,
             value: Double = 0, rawValue: Double? = nil, isDelta: Bool = false,
             dailyTotal: Double? = nil) {
            self.kindRaw = kindRaw
            self.start = start
            self.end = end
            self.value = value
            self.rawValue = rawValue
            self.isDelta = isDelta
            self.dailyTotal = dailyTotal
        }
    }

    /// `StoredCursor` as shipped b34 → b45.
    @Model final class StoredCursor {
        @Attribute(.unique) var kindRaw: String
        var last: Date
        init(kindRaw: String = "", last: Date = .distantPast) {
            self.kindRaw = kindRaw
            self.last = last
        }
    }

    /// `StoredDaily` as shipped b34 → b45.
    @Model final class StoredDaily {
        @Attribute(.unique) var day: Date = Date.distantPast
        var steps: Int = 0
        var updatedAt: Date = Date.distantPast
        var healthWrittenSteps: Int = 0
        init() {}
    }

    /// `StoredStepSample` as shipped b34 → b45.
    @Model final class StoredStepSample {
        var start: Date = Date.distantPast
        var end: Date = Date.distantPast
        var delta: Int = 0
        var healthWritten: Bool = false
        init() {}
    }

    /// `StoredDaytimeTemp` as shipped b34 → b45.
    @Model final class StoredDaytimeTemp {
        var time: Date = Date.distantPast
        var celsius: Double = 0
        init() {}
    }

    /// `StoredPeriodEntry` as shipped b34 → b45. User-ENTERED and not re-derivable from anything.
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

    /// `StoredHeadacheEntry` as shipped b34 → b45. The default for `sourceRaw` is spelled as the
    /// literal `"user"` rather than `HeadacheSource.user.rawValue` deliberately: a frozen shape must
    /// not move if a live enum is ever renamed. (Measured equal today — `case user`.)
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

    /// `StoredHeadacheRisk` as shipped b34 → b45 (including `nightKey`, which was added while V4
    /// was still unreleased — verified present at the `v1.0-b34` tag).
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

    // MARK: The entity nobody was watching

    /// `StoredNap` EXACTLY as shipped from build 22 through build 45 — WITHOUT SchemaV7's
    /// `recordedNapSegmentsData` / `healthWrittenStart` / `healthWrittenEnd`.
    ///
    /// ⚠️ THIS IS THE M1 DEFECT'S FIX. Until this snapshot existed, V1…V5 listed the LIVE
    /// `StoredNap`, so widening it in SchemaV7 changed the checksum of every one of those versions
    /// and a store written by builds 34–43 could no longer be identified. Reproduced before it was
    /// fixed: `ShippedStoreMigrationTests` writes a genuine build-43 store and the real
    /// `MigrationPlan` fails to open it with 134504.
    ///
    /// V6 keeps its own nested copy of this shape rather than referring here, because V6 is the
    /// shape on almost every live phone and its listing is deliberately left untouched.
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
