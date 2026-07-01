import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Regression coverage for the corrupted-timestamp cursor-poisoning bug: a sample whose decoded
/// date is implausible (e.g. a misaligned bulk-page parse landing decades in the future) must be
/// rejected BEFORE it can advance a kind's `SyncCursor` watermark — otherwise every later
/// legitimate sample of that kind is silently dropped forever, since a cursor only moves forward.
@MainActor
final class SyncCursorPlausibilityTests: XCTestCase {
    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return LocalStore(container.mainContext)
    }

    private func hr(_ value: Double, _ date: Date) -> QuantitySample {
        QuantitySample(kind: .heartRate, start: date, value: value)
    }

    /// A garbage-future-dated HR sample must not be stored, and — the actual bug — must not
    /// poison the `.heartRate` cursor so a later, legitimately-dated HR sample still ingests.
    func testFutureDatedSampleDoesNotPoisonCursor() throws {
        let store = try makeStore()
        let now = Date()
        let corrupted = hr(83, Date(timeIntervalSince1970: 3_155_760_000))   // ~2069

        _ = try store.ingest([corrupted])
        XCTAssertTrue(try store.samples(kind: .heartRate, from: .distantPast, to: .distantFuture).isEmpty)

        let legit = hr(72, now)
        let ingested = try store.ingest([legit])
        XCTAssertEqual(ingested.map(\.value), [72])
        XCTAssertEqual(try store.samples(kind: .heartRate, from: .distantPast, to: .distantFuture).map(\.value), [72])
    }

    /// Same poisoning risk via the OTHER plausibility gate (out-of-band HR value) sharing a
    /// timestamp far enough ahead to otherwise win the cursor race.
    func testOutOfBandHeartRateDoesNotPoisonCursor() throws {
        let store = try makeStore()
        let now = Date()
        let garbageValue = hr(0, now.addingTimeInterval(-60))   // earlier, but value=0 is implausible

        _ = try store.ingest([garbageValue])
        let legit = hr(72, now)
        let ingested = try store.ingest([legit])
        XCTAssertEqual(ingested.map(\.value), [72])
    }

    /// `repairFutureSyncCursors` undoes a cursor already stuck in the future (the lasting damage
    /// from before the ingest reordering existed), resetting it to the latest stored plausible
    /// sample of that kind so the backlog of newer real samples is no longer blocked.
    func testRepairResetsStuckCursorToLatestPlausibleSample() throws {
        let store = try makeStore()
        let now = Date()
        let validPast = now.addingTimeInterval(-3600)

        // Seed a StoredSample + a cursor manually poisoned into the future, simulating the
        // pre-fix state (a corrupted sample that slipped through before this ordering fix).
        _ = try store.ingest([hr(70, validPast)])
        let context = store.context
        let rows = try context.fetch(FetchDescriptor<StoredCursor>())
        XCTAssertEqual(rows.count, 1)
        rows[0].last = now.addingTimeInterval(10 * 365 * 24 * 3600)   // ~10 years in the future
        try context.save()

        let repaired = try store.repairFutureSyncCursors(now: now)
        XCTAssertEqual(repaired, 1)

        let after = try context.fetch(FetchDescriptor<StoredCursor>())
        XCTAssertEqual(after.first?.last, validPast)

        // The cursor no longer blocks a sample newer than the repaired watermark.
        let ingested = try store.ingest([hr(75, now)])
        XCTAssertEqual(ingested.map(\.value), [75])
    }

    /// When NO plausible sample of the poisoned kind exists locally (the actual `.heartRate`
    /// case — the only ones ever stored were the corrupted future-dated ones, since purged), the
    /// stuck cursor row is removed entirely rather than left dangling, so the next ingest treats
    /// that kind as never-synced and re-admits the full backlog.
    func testRepairRemovesCursorWithNoPlausibleSamples() throws {
        let store = try makeStore()
        let context = store.context
        let now = Date()
        context.insert(StoredCursor(kindRaw: "heartRate", last: now.addingTimeInterval(10 * 365 * 24 * 3600)))
        try context.save()

        let repaired = try store.repairFutureSyncCursors(now: now)
        XCTAssertEqual(repaired, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredCursor>()).isEmpty)

        let ingested = try store.ingest([hr(72, now)])
        XCTAssertEqual(ingested.map(\.value), [72])
    }

    /// The `hk:`-prefixed HealthKit-mirror cursor is repaired the same way as the plain ingest
    /// cursor — a poisoned mirror watermark would otherwise keep new, valid local samples from
    /// ever reaching Apple Health even after the ingest side is fixed.
    func testRepairCoversHealthKitMirrorCursor() throws {
        let store = try makeStore()
        let context = store.context
        let now = Date()
        context.insert(StoredCursor(kindRaw: "hk:heartRate", last: now.addingTimeInterval(10 * 365 * 24 * 3600)))
        try context.save()

        let repaired = try store.repairFutureSyncCursors(now: now)
        XCTAssertEqual(repaired, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredCursor>()).isEmpty)
    }

    /// A cursor within the plausible range is left untouched.
    func testRepairIsNoOpWhenNothingIsStuck() throws {
        let store = try makeStore()
        _ = try store.ingest([hr(70, Date())])
        XCTAssertEqual(try store.repairFutureSyncCursors(), 0)
    }
}
