import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// The stored per-night hypnogram (`StoredSleepSummary.hypnogramData`).
//
// The invariant these tests exist to pin: a night's SEGMENTS and its stage MINUTES must always come
// from the same capture. The minutes are a rollup that cannot be un-summed, so a stale timeline sitting
// next to fresh totals is a contradiction no consumer (card, export, Health mirror) could detect. The
// column is therefore written only inside the branch that writes the minutes, and inherits that
// branch's merge protection (`SleepSummaryMerge`) and manual-edit guard for free.
@MainActor
final class SleepHypnogramStoreTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func at(_ hours: Double) -> Date { ref.addingTimeInterval(hours * 3600) }
    private var night: Date { ref }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    // MARK: Fixtures — each is a self-consistent night: the minutes are DERIVED from the segments.

    /// 8 h in bed, 7 h asleep.
    private var fullNight: [SleepSegment] {[
        .init(start: at(0), end: at(8), stage: .inBed),
        .init(start: at(0), end: at(0.5), stage: .awake),
        .init(start: at(0.5), end: at(3), stage: .asleepCore),
        .init(start: at(3), end: at(4.5), stage: .asleepDeep),
        .init(start: at(4.5), end: at(6), stage: .asleepREM),
        .init(start: at(6), end: at(7.5), stage: .asleepCore),
        .init(start: at(7.5), end: at(8), stage: .awake),
    ]}

    /// A later 2 h fragment — the ring hands a night off in slices, so this arrives AFTER `fullNight`.
    private var shortSlice: [SleepSegment] {[
        .init(start: at(5), end: at(7), stage: .inBed),
        .init(start: at(5), end: at(7), stage: .asleepCore),
    ]}

    /// 9 h in bed, 8 h asleep — a genuinely fuller capture that SHOULD supersede `fullNight`.
    private var fullerNight: [SleepSegment] {[
        .init(start: at(-0.5), end: at(8.5), stage: .inBed),
        .init(start: at(-0.5), end: at(0), stage: .awake),
        .init(start: at(0), end: at(4), stage: .asleepCore),
        .init(start: at(4), end: at(6), stage: .asleepDeep),
        .init(start: at(6), end: at(8), stage: .asleepREM),
        .init(start: at(8), end: at(8.5), stage: .awake),
    ]}

    /// Persist `segments` exactly as `RingSession.persistSleepAndSteps` does: the summary, the window,
    /// and the hypnogram all derived from the same segment array and written in one call.
    private func save(_ segments: [SleepSegment], to store: LocalStore) throws {
        let start = try XCTUnwrap(segments.map(\.start).min())
        let end = try XCTUnwrap(segments.map(\.end).max())
        let window = SleepStaging.sleepWindow(segments)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        try store.saveSleepSummary(SleepStaging.summary(segments), night: night,
                                   inBedStart: start, inBedEnd: end,
                                   sleepOnset: window?.onset ?? .distantPast,
                                   sleepWake: window?.wake ?? .distantPast,
                                   extras: extras)
    }

    /// The core invariant: re-rolling the STORED segments must reproduce the STORED minutes exactly.
    private func assertTimelineAgreesWithMinutes(_ store: LocalStore,
                                                 _ message: String,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) throws {
        let row = try XCTUnwrap(store.sleepSummary(night: night), file: file, line: line)
        let stored = store.hypnogram(night: night)
        XCTAssertFalse(stored.isEmpty, message, file: file, line: line)
        let m = SleepStaging.summary(stored).minutes
        XCTAssertEqual(m.asleep, row.asleepMin, message, file: file, line: line)
        XCTAssertEqual(m.deep, row.deepMin, message, file: file, line: line)
        XCTAssertEqual(m.light, row.lightMin, message, file: file, line: line)
        XCTAssertEqual(m.rem, row.remMin, message, file: file, line: line)
        XCTAssertEqual(m.awake, row.awakeMin, message, file: file, line: line)
    }

    // MARK: Round-trip

    func testSavedNightRoundTripsItsHypnogram() throws {
        let store = try makeStore()
        try save(fullNight, to: store)
        XCTAssertEqual(store.hypnogram(night: night), fullNight)
        try assertTimelineAgreesWithMinutes(store, "a freshly saved night")
    }

    /// A save that supplies NO segments stores "not recorded" and the rest of the row stays usable.
    ///
    /// Named for what it actually covers. It used to be called `…ReadsBackEmpty` with the message
    /// "the migration default must read back as 'not recorded'", which it cannot check: this store
    /// is `isStoredInMemoryOnly`, freshly built from the CURRENT schema, so no migration runs. The
    /// migration default is covered for real — against a store written with build 34's pinned V4
    /// shape and opened through the app's own `MigrationPlan` — by
    /// `SchemaMigrationTests.testTheMigratedRowCanCarryAHypnogram`.
    func testNightSavedWithNoSegmentsStoresNotRecordedAndKeepsTheRestOfTheRow() throws {
        let store = try makeStore()
        try store.saveSleepSummary(SleepStaging.summary(fullNight), night: night,
                                   inBedStart: at(0), inBedEnd: at(8))
        XCTAssertEqual(store.hypnogram(night: night), [])
        XCTAssertGreaterThan(try XCTUnwrap(store.sleepSummary(night: night)).asleepMin, 0,
                             "the rest of the row must still be readable")
    }

    func testHypnogramOfUnknownNightIsEmpty() throws {
        let store = try makeStore()
        XCTAssertEqual(store.hypnogram(night: night), [])
    }

    func testUnreadableBlobReadsBackEmptyRatherThanFailingTheNight() throws {
        let store = try makeStore()
        try save(fullNight, to: store)
        let row = try XCTUnwrap(store.sleepSummary(night: night))
        row.hypnogramData = Data("not json".utf8)   // whatever a future format change could leave behind
        XCTAssertEqual(store.hypnogram(night: night), [])
        XCTAssertEqual(row.asleepMin, 420, "the rest of the night must still be intact")
    }

    // MARK: Merge protection (a shorter slice can never shrink a fuller stored night)

    func testShorterLaterSliceDoesNotReplaceAFullerNightsHypnogram() throws {
        let store = try makeStore()
        try save(fullNight, to: store)
        try save(shortSlice, to: store)

        XCTAssertEqual(store.hypnogram(night: night), fullNight,
                       "merge protection must keep the fuller night's timeline, not the 2 h fragment")
        try assertTimelineAgreesWithMinutes(store, "after a rejected shorter slice")
    }

    func testGenuinelyFullerCaptureReplacesBothTimelineAndMinutesTogether() throws {
        let store = try makeStore()
        try save(fullNight, to: store)
        try save(fullerNight, to: store)

        XCTAssertEqual(store.hypnogram(night: night), fullerNight)
        try assertTimelineAgreesWithMinutes(store, "after a fuller capture superseded the stored night")
    }

    /// The whole point of writing the column in the minutes' own branch: no ordering of accepted and
    /// rejected saves can leave a row whose timeline and totals came from different captures.
    func testTimelineAndMinutesCannotDivergeAcrossSaveMergeSave() throws {
        let store = try makeStore()
        try save(fullNight, to: store)
        try assertTimelineAgreesWithMinutes(store, "after the first capture")
        try save(shortSlice, to: store)          // rejected by merge protection
        try assertTimelineAgreesWithMinutes(store, "after a rejected fragment")
        try save(fullerNight, to: store)         // accepted
        try assertTimelineAgreesWithMinutes(store, "after an accepted fuller capture")
        try save(shortSlice, to: store)          // rejected again
        try assertTimelineAgreesWithMinutes(store, "after a second rejected fragment")
        XCTAssertEqual(store.hypnogram(night: night), fullerNight)
    }

    // MARK: Manual edit (#176) — authoritative over any later re-sync

    func testManualEditStoresTheEditedTimelineAndSurvivesAResync() throws {
        let store = try makeStore()
        try save(fullNight, to: store)

        let times = SleepEdit.Times(inBedStart: at(-1), sleepOnset: at(-0.5), sleepWake: at(8))
        let edited = SleepEdit.recompute(baseSegments: fullNight, times: times)
        XCTAssertFalse(edited.isEmpty)
        XCTAssertTrue(try store.applySleepEdit(night: night, times: times,
                                               summary: SleepStaging.summary(edited),
                                               hypnogram: edited))
        XCTAssertEqual(store.hypnogram(night: night), edited)
        try assertTimelineAgreesWithMinutes(store, "the edited night")

        // A later re-sync draining a FULLER capture must still not touch an edited night — proving the
        // guard is `isManuallyEdited`, not merely merge protection.
        try save(fullerNight, to: store)
        XCTAssertEqual(store.hypnogram(night: night), edited,
                       "a re-sync must not overwrite a manually edited night's timeline")
        try assertTimelineAgreesWithMinutes(store, "the edited night after a re-sync")
    }

    // MARK: An OMITTED hypnogram argument must never erase a stored one
    //
    // `applySleepEdit`'s `hypnogram` parameter is defaulted, and it used to default to `[]` and be
    // written UNCONDITIONALLY. Any caller that simply left it off therefore DESTROYED the night's
    // segment timeline — silently, and unrecoverably once the ~30 h epoch archive rolls over, with
    // the export then reporting the night as "not recorded" when it was recorded. The production
    // caller passes the recomputed segments, so nothing was broken today; the defect was that the
    // next call site was one omitted argument away from data loss.

    func testAnEditWithNoHypnogramArgumentLeavesTheStoredTimelineIntact() throws {
        let store = try makeStore()
        try save(fullNight, to: store)

        // A real edit (not the unchanged-times early return, which never reaches the write).
        let times = SleepEdit.Times(inBedStart: at(-1), sleepOnset: at(-0.5), sleepWake: at(8))
        let edited = SleepEdit.recompute(baseSegments: fullNight, times: times)
        XCTAssertFalse(edited.isEmpty)
        XCTAssertTrue(try store.applySleepEdit(night: night, times: times,
                                               summary: SleepStaging.summary(edited)))

        let row = try XCTUnwrap(store.sleepSummary(night: night))
        XCTAssertTrue(row.isManuallyEdited, "the edit really was applied — not an early return")
        XCTAssertEqual(store.hypnogram(night: night), fullNight,
                       "an omitted timeline must leave the recorded one alone, never wipe it")
    }

    /// …and a caller that genuinely means "clear it" still can, by saying so.
    func testAnEditThatExplicitlyPassesAnEmptyHypnogramStillClearsIt() throws {
        let store = try makeStore()
        try save(fullNight, to: store)

        let times = SleepEdit.Times(inBedStart: at(-1), sleepOnset: at(-0.5), sleepWake: at(8))
        XCTAssertTrue(try store.applySleepEdit(
            night: night, times: times,
            summary: SleepStaging.summary(SleepEdit.recompute(baseSegments: fullNight, times: times)),
            hypnogram: []))
        XCTAssertEqual(store.hypnogram(night: night), [],
                       "an EXPLICIT [] is a stated intent and must still clear the column")
    }

    /// The compatibility overload routes through the same guard, so it cannot be the back door.
    func testTheTwoEdgeOverloadWithNoHypnogramArgumentAlsoLeavesTheTimelineIntact() throws {
        let store = try makeStore()
        try save(fullNight, to: store)

        let window = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(8))
        let times = SleepEdit.Times(inBedStart: at(-1), sleepOnset: at(-0.5), sleepWake: at(8))
        let edited = SleepEdit.recompute(baseSegments: fullNight, times: times)
        XCTAssertTrue(try store.applySleepEdit(night: night, editedWindow: window,
                                               summary: SleepStaging.summary(edited),
                                               sleepOnset: at(-0.5), sleepWake: at(8)))
        XCTAssertEqual(store.hypnogram(night: night), fullNight)
    }

    func testUnchangedEditIsANoOpAndLeavesTheRecordedTimelineIntact() throws {
        let store = try makeStore()
        try save(fullNight, to: store)
        let row = try XCTUnwrap(store.sleepSummary(night: night))
        // Submitting the recorded times unchanged must not manufacture an edit — and must not clear
        // the recorded timeline on its way through.
        let unchanged = SleepEdit.Times(inBedStart: row.sleepEditCurrentInBedStart,
                                        sleepOnset: row.sleepEditCurrentOnset,
                                        sleepWake: row.sleepEditCurrentWake)
        XCTAssertTrue(try store.applySleepEdit(night: night, times: unchanged,
                                               summary: row.asSummary))
        XCTAssertFalse(row.isManuallyEdited)
        XCTAssertEqual(store.hypnogram(night: night), fullNight)
    }
}
