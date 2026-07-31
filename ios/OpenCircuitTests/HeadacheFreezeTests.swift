import SwiftData
import XCTest
@testable import OpenCircuit

/// Regression locks for THE freeze: a day's overnight-signals score is written exactly once and is
/// never recomputed. Every later precision/AUC claim about this detector rests on scores that could
/// not have seen the label, so a second write for the same night doesn't just corrupt a number — it
/// retroactively turns the whole self-evaluation into a retro-fit.
///
/// Two ways to break it were found by review and fixed; both are INVISIBLE at runtime (no crash, no
/// error, just a second row), which is exactly why they need tests:
///
/// 1. TIMEZONE RE-KEY. `StoredHeadacheRisk.day` is a LOCAL start-of-day, recomputed on every pass,
///    so a device timezone change re-keys it: the exact-equality existence check matches nothing and
///    the SAME NIGHT is frozen a second time under a second key — two rows, two indices, one night.
///    The fix is `nightKey`, the PERSISTED `StoredSleepSummary.night` of the night scored, which does
///    not move with the calendar, plus a second existence check on it in `insertRiskDayIfAbsent`.
/// 2. BACKUP ROUND-TRIP. Frozen rows cannot be regenerated, so they ride the last-resort store wipe
///    (#40) in `RollupBackup`. `RiskDay.nightKey` is `Date?` there so a backup written by a build
///    that predates the key still decodes — a decode failure at that point loses the rows entirely.
///
/// The assertions deliberately check the SURVIVING VALUE, not just the row count: a "fix" that
/// avoids the duplicate row by overwriting the frozen score would be worse than the bug it replaces.
///
/// All fixtures are synthetic (fixed reference date, made-up JSON payloads) — no real health data.
@MainActor
final class HeadacheFreezeTests: XCTestCase {
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
            .appendingPathComponent("headache-freeze-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        let base = url.deletingPathExtension()
        for u in [url, base.appendingPathExtension("store-shm"), base.appendingPathExtension("store-wal")] {
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// Every frozen row, unfiltered. Deliberately NOT `riskDays(from:to:)`: that filters on `day`,
    /// the very key these tests accuse of moving, so a second row parked outside the window would
    /// read as "exactly one row".
    private func allRiskRows(_ store: LocalStore) throws -> [StoredHeadacheRisk] {
        try store.context.fetch(FetchDescriptor<StoredHeadacheRisk>(
            sortBy: [SortDescriptor(\.day, order: .forward)]))
    }

    private func riskRow(day: Date, nightKey: Date, index: Double,
                         bandRaw: Int = 1, computedAt: Date) -> StoredHeadacheRisk {
        StoredHeadacheRisk(day: day, nightKey: nightKey, index: index, bandRaw: bandRaw,
                           ringFeatureCount: 4, coverageFraction: 0.9,
                           contributionsJSON: "{\"hrv\":-0.3}", absentJSON: "{}",
                           computedAt: computedAt)
    }

    // MARK: The timezone re-key

    /// The dangerous case. The user scores a night, then flies west; `day` is recomputed from the
    /// new calendar and lands on a DIFFERENT local start-of-day, so the pre-existing `day` check
    /// matches nothing. Only the persisted `nightKey` can still recognise the night.
    ///
    /// The surviving row must carry the ORIGINAL score: rejecting the duplicate row while letting
    /// the later pass overwrite `index` would keep the table tidy and still destroy the freeze.
    func testSecondFreezeOfTheSameNightUnderANewDayKeyIsRejected() throws {
        let store = try makeStore()
        let night = at(-6)   // the persisted StoredSleepSummary.night for last night

        XCTAssertTrue(try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: night, index: 42, computedAt: at(1))))

        // Same night, re-keyed onto another local day by the timezone move.
        XCTAssertFalse(try store.insertRiskDayIfAbsent(
            riskRow(day: at(4), nightKey: night, index: 99, bandRaw: 2, computedAt: at(9))),
            "a night already frozen must not be frozen again under a re-keyed day")

        let rows = try allRiskRows(store)
        XCTAssertEqual(rows.count, 1, "one night is one frozen row, whatever the device calendar says")
        XCTAssertEqual(rows[0].day, at(0), "the original row must be the one that survived")
        XCTAssertEqual(rows[0].nightKey, night)
        XCTAssertEqual(rows[0].index, 42, accuracy: 0.0001,
                       "the frozen score must be the FIRST one — an overwrite is worse than a dup row")
        XCTAssertEqual(rows[0].bandRaw, 1)
        XCTAssertEqual(rows[0].computedAt, at(1), "a re-scoring pass must leave no trace at all")
    }

    /// The `day` guard predates `nightKey` and must still stand on its own — the second row here
    /// carries a DIFFERENT `nightKey`, so only the original check can reject it.
    ///
    /// This also pins the one case where the two keys disagree: crossing the date line westward
    /// repeats a local day, so two consecutive nights can both end on it and the second is dropped
    /// rather than scored. That is the deliberate ordering — the freeze outranks coverage, and a
    /// missing day is recoverable evidence while a double-scored one is not.
    func testSameDayIsRejectedEvenWhenTheNightKeyDiffers() throws {
        let store = try makeStore()

        XCTAssertTrue(try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: at(-6), index: 42, computedAt: at(1))))
        XCTAssertFalse(try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: at(-30), index: 99, bandRaw: 2, computedAt: at(9))),
            "a day already scored must not be scored again")

        let rows = try allRiskRows(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].index, 42, accuracy: 0.0001, "the frozen score must be untouched")
        XCTAssertEqual(rows[0].nightKey, at(-6), "the surviving row keeps its own night, not the new one")
    }

    /// `.distantPast` is the "frozen without a sleep summary" SENTINEL, not a night. If it were
    /// treated as a real key, the first unkeyed row would match every later unkeyed row and block
    /// every subsequent day from ever being scored — the detector would go permanently silent on a
    /// user whose first scored night had no summary.
    func testUnkeyedRowsDoNotBlockEachOther() throws {
        let store = try makeStore()

        XCTAssertTrue(try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: .distantPast, index: 10, computedAt: at(1))))
        XCTAssertTrue(try store.insertRiskDayIfAbsent(
            riskRow(day: at(24), nightKey: .distantPast, index: 20, computedAt: at(25))),
            "the no-summary sentinel is not a night — it must never match another day's sentinel")
        XCTAssertTrue(try store.insertRiskDayIfAbsent(
            riskRow(day: at(48), nightKey: at(42), index: 30, computedAt: at(49))))

        let rows = try allRiskRows(store)
        XCTAssertEqual(rows.map(\.index), [10, 20, 30])

        // The `day` guard still applies to unkeyed rows — they are not a bypass.
        XCTAssertFalse(try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: .distantPast, index: 99, computedAt: at(50))))
        XCTAssertEqual(try allRiskRows(store).count, 3)
    }

    /// The lookup side of the same key. `riskRow(nightKey:)` is what lets a moved device still find
    /// the row it already wrote (to flag a re-stage, say) — and it must refuse the sentinel, or an
    /// unkeyed row would be handed back as if it were the night being asked about.
    func testRiskRowLookupByNightKey() throws {
        let store = try makeStore()
        try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: at(-6), index: 42, computedAt: at(1)))
        try store.insertRiskDayIfAbsent(
            riskRow(day: at(24), nightKey: .distantPast, index: 10, computedAt: at(25)))

        let found = try XCTUnwrap(try store.riskRow(nightKey: at(-6)))
        XCTAssertEqual(found.day, at(0))
        XCTAssertEqual(found.index, 42, accuracy: 0.0001)

        XCTAssertNil(try store.riskRow(nightKey: at(-30)), "an unscored night has no row")
        XCTAssertNil(try store.riskRow(nightKey: .distantPast),
                     "the no-summary sentinel must never resolve to a row, unkeyed rows or not")
    }

    /// The freeze restated at the store level: whatever key path the second call arrives by, one
    /// night ends up as one row holding the FIRST call's score and the FIRST call's timestamp.
    func testFreezeIsIdempotentAcrossEveryKeyPath() throws {
        let store = try makeStore()
        let night = at(-6)
        try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: night, index: 42, computedAt: at(1)))

        // Same day + same night (the ordinary repeat pass), then the re-keyed variant.
        XCTAssertFalse(try store.insertRiskDayIfAbsent(
            riskRow(day: at(0), nightKey: night, index: 77, bandRaw: 2, computedAt: at(5))))
        XCTAssertFalse(try store.insertRiskDayIfAbsent(
            riskRow(day: at(-20), nightKey: night, index: 88, bandRaw: 2, computedAt: at(6))),
            "an eastward move re-keys `day` backwards — still the same night")

        // Annotations are the only permitted writes, and they must not disturb the score.
        try store.markRiskRestaged(day: at(0), sleepUpdatedAt: at(10))
        try store.markRiskAlerted(day: at(0))

        let rows = try allRiskRows(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].index, 42, accuracy: 0.0001)
        XCTAssertEqual(rows[0].bandRaw, 1)
        XCTAssertEqual(rows[0].computedAt, at(1))
        XCTAssertTrue(rows[0].sleepRestaged, "a re-staged night is EXCLUDED from evaluation, not rescored")
        XCTAssertTrue(rows[0].alerted)
    }

    // MARK: Wipe backup (#40 RollupBackup)

    /// A frozen row is the one thing in the store that CANNOT be regenerated — that is the whole
    /// point of freezing it — so losing it to a wipe doesn't reset a number, it silently deletes a
    /// day from every later statistic. `nightKey` has to survive the round trip too: a row restored
    /// without it is a row the duplicate check can no longer recognise after a timezone change.
    ///
    /// Run through the REAL export → JSON → decode → restore path, not a hand-rolled copy.
    func testRollupBackupRoundTripsRiskDaysWithNightKey() throws {
        let url = uniqueTempStoreURL()
        defer { removeStore(at: url) }

        do {
            let seeded = try OpenCircuitApp.makeContainerOrThrow(storeURL: url)
            let store = LocalStore(seeded.mainContext)
            try store.insertRiskDayIfAbsent(StoredHeadacheRisk(
                day: at(0), nightKey: at(-6), index: 61.5, bandRaw: 2, ringFeatureCount: 5,
                coverageFraction: 0.82, contributionsJSON: "{\"hrv\":-0.4,\"rhr\":0.2}",
                absentJSON: "{\"spo2\":\"noDataThisDay\"}", computedAt: at(1),
                sleepUpdatedAt: at(2), sleepRestaged: true, alerted: true, postUnlock: true))
            // A second, unkeyed row: the sentinel must round-trip as itself, not as a real night.
            try store.insertRiskDayIfAbsent(
                riskRow(day: at(24), nightKey: .distantPast, index: 12, bandRaw: 0, computedAt: at(25)))
        }   // release the container before re-opening the same file, as a real wipe would

        let exported = try XCTUnwrap(
            RollupBackup.exportBeforeWipe(config: ModelConfiguration(url: url)),
            "the pre-wipe backup must be able to read the frozen rows")
        let decoded = try JSONDecoder().decode(RollupBackup.self,
                                               from: JSONEncoder().encode(exported))

        let fresh = try makeContainer()
        decoded.restore(into: fresh)
        let restored = LocalStore(ModelContext(fresh))

        let rows = try allRiskRows(restored)
        XCTAssertEqual(rows.count, 2, "frozen rows cannot be regenerated — they must survive the wipe")

        let scored = try XCTUnwrap(rows.first { $0.day == at(0) })
        XCTAssertEqual(scored.nightKey, at(-6),
                       "without the night key a restored row is invisible to the duplicate check")
        XCTAssertEqual(scored.index, 61.5, accuracy: 0.0001)
        XCTAssertEqual(scored.bandRaw, 2)
        XCTAssertEqual(scored.ringFeatureCount, 5)
        XCTAssertEqual(scored.coverageFraction, 0.82, accuracy: 0.0001)
        XCTAssertEqual(scored.contributionsJSON, "{\"hrv\":-0.4,\"rhr\":0.2}")
        XCTAssertEqual(scored.absentJSON, "{\"spo2\":\"noDataThisDay\"}")
        XCTAssertEqual(scored.computedAt, at(1))
        XCTAssertEqual(scored.sleepUpdatedAt, at(2))
        XCTAssertTrue(scored.sleepRestaged)
        XCTAssertTrue(scored.alerted)
        XCTAssertTrue(scored.postUnlock)

        let unkeyed = try XCTUnwrap(rows.first { $0.day == at(24) })
        XCTAssertEqual(unkeyed.nightKey, .distantPast,
                       "the no-summary sentinel must not come back as a real night")

        // And the restored rows still hold the line against a re-freeze.
        XCTAssertFalse(try restored.insertRiskDayIfAbsent(
            riskRow(day: at(4), nightKey: at(-6), index: 99, computedAt: at(30))),
            "a restored row must still block a re-keyed second freeze of its night")
        XCTAssertEqual(try allRiskRows(restored).count, 2)
    }

    /// A backup written before `nightKey` existed (any build up to the one that added it) must still
    /// decode. The wipe path is precisely where an upgrading user meets this file, and a decode
    /// failure there doesn't lose one field — `JSONDecoder` fails the WHOLE `RollupBackup`, taking
    /// the sleep/period/headache rollups with it. The missing key must land as the `.distantPast`
    /// sentinel: an absent night is absent, never a fabricated one.
    func testOlderBackupWithoutNightKeyStillDecodes() throws {
        // Hand-built older JSON. Dates use JSONEncoder's default `.deferredToDate` strategy (seconds
        // since the 2001 reference date), matching what an older build actually wrote: 806692800 is
        // `at(0)`, 806696400 `at(1)`, 806779200 `at(24)`.
        let legacy = """
        {"sleep":[],"daily":[],"periods":[],"naps":[],\
        "riskDays":[{"day":806692800,"index":61.5,"bandRaw":2,"ringFeatureCount":5,\
        "coverageFraction":0.82,"contributionsJSON":"{}","absentJSON":"{}",\
        "computedAt":806696400,"sleepRestaged":false,"alerted":false,"postUnlock":false,\
        "updatedAt":806696400}]}
        """
        let decoded = try JSONDecoder().decode(RollupBackup.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.riskDays?.count, 1)
        XCTAssertNil(decoded.riskDays?.first?.nightKey,
                     "an absent key decodes as nil — nothing is invented at the decode layer either")

        let fresh = try makeContainer()
        decoded.restore(into: fresh)
        let restored = LocalStore(ModelContext(fresh))

        let rows = try allRiskRows(restored)
        XCTAssertEqual(rows.count, 1, "an older backup must still restore its frozen rows")
        XCTAssertEqual(rows[0].day, at(0))
        XCTAssertEqual(rows[0].index, 61.5, accuracy: 0.0001)
        XCTAssertEqual(rows[0].computedAt, at(1))
        XCTAssertEqual(rows[0].nightKey, .distantPast,
                       "a pre-key row has no night — it must restore as the sentinel, not as `day`")

        // The sentinel it restored as must behave like one: it can't block a later real night.
        XCTAssertTrue(try restored.insertRiskDayIfAbsent(
            riskRow(day: at(24), nightKey: at(18), index: 30, computedAt: at(25))))
        XCTAssertEqual(try allRiskRows(restored).count, 2)
    }
}
