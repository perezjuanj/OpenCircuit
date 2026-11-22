import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Each night's Sleep Score factors are saved by the writer that writes the score, and the Sleep card
// shows them only while that score is still the row's. Every value here is synthetic; the side store
// lives in a scratch folder per test, never the app's own file.

@MainActor
final class SleepScoreFactorStoreTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)
    private var containers: [ModelContainer] = []
    private var folder: URL!
    private var savedShared: SleepScoreFactorStore!
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepScoreFactorStoreTests-\(UUID().uuidString)", isDirectory: true)
        savedShared = SleepScoreFactorStore.shared
        SleepScoreFactorStore.shared = SleepScoreFactorStore(folder: folder)
    }

    override func tearDown() {
        SleepScoreFactorStore.shared = savedShared
        try? FileManager.default.removeItem(at: folder)
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private var store: SleepScoreFactorStore { SleepScoreFactorStore.shared }

    private func at(_ hours: Double) -> Date { ref.addingTimeInterval(hours * 3600) }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    /// In bed 0 h → 8 h: 30 min awake, then core / deep / REM.
    private func segments() -> [SleepSegment] {
        [
            SleepSegment(start: at(0), end: at(8), stage: .inBed),
            SleepSegment(start: at(0), end: at(0.5), stage: .awake),
            SleepSegment(start: at(0.5), end: at(3), stage: .asleepCore),
            SleepSegment(start: at(3), end: at(4.5), stage: .asleepDeep),
            SleepSegment(start: at(4.5), end: at(6), stage: .asleepREM),
            SleepSegment(start: at(6), end: at(8), stage: .asleepCore),
        ]
    }

    /// The composite input the ring writer (`RingSession.computeSleepExtras`) builds.
    private func ringInput(hr: Double, off: Double?) -> SleepScore.CompositeInput {
        let s = SleepStaging.summary(segments())
        return .init(totalAsleep: s.totalAsleep, timeAwake: s.awake, efficiency: s.efficiency,
                     deep: s.deep, light: s.light, rem: s.rem, restingHR: hr, tempOffsetC: off)
    }

    /// Save a night the way the ring writer does: score and factors from ONE `scored` call, through
    /// `saveSleepSummary`'s `extras`.
    @discardableResult
    private func saveRingNight(_ local: LocalStore, hr: Double = 55, off: Double? = 0.2,
                               factors: Bool = true) throws -> SleepScoreFactors {
        let scored = SleepScoreFactors.scored(ringInput(hr: hr, off: off), producer: .ring)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments()
        extras.sleepScore = scored.score
        if factors { extras.scoreFactors = scored }
        try local.saveSleepSummary(SleepStaging.summary(segments()), night: at(0),
                                   inBedStart: at(0), inBedEnd: at(8),
                                   sleepOnset: at(0.5), sleepWake: at(8), extras: extras)
        return scored
    }

    private func row(_ local: LocalStore) throws -> StoredSleepSummary {
        try XCTUnwrap(local.sleepSummary(night: at(0)))
    }

    /// The factors `SleepScore.composite` gives for the same input, in the entry's key form.
    private func compositeFactors(_ input: SleepScore.CompositeInput) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: SleepScore.composite(input).factors.map { ($0.key.rawValue, $0.value) })
    }

    // MARK: Ring writer (`RingSession.computeSleepExtras` → `saveSleepSummary`)

    func testTheRingWriterSavesAnEntryWhoseScoreIsTheRowsAndWhoseFactorsAreTheComposites() throws {
        let local = try makeStore()
        try saveRingNight(local)
        let row = try row(local)
        let entry = try XCTUnwrap(store.entry(night: row.night), "the ring writer must save the factors")
        XCTAssertEqual(entry.score, row.sleepScore)
        XCTAssertEqual(entry.producer, .ring)
        XCTAssertEqual(entry.factors, compositeFactors(ringInput(hr: 55, off: 0.2)))
        let breakdown = try XCTUnwrap(row.scoreBreakdown)
        XCTAssertEqual(breakdown.score, row.sleepScore)
        XCTAssertEqual(breakdown.rows.count, 6, "HR and temperature were part of this score")
    }

    func testAReSyncOverwritesTheEntry() throws {
        let local = try makeStore()
        try saveRingNight(local, hr: 55)
        let second = try saveRingNight(local, hr: 70, off: nil)
        let row = try row(local)
        XCTAssertEqual(row.sleepScore, second.score)
        XCTAssertEqual(store.entry(night: row.night), second)
        XCTAssertEqual(row.scoreBreakdown?.rows.count, 5, "the re-sync had no temperature factor")
    }

    func testAScoreWrittenWithoutFactorsClearsTheEntry() throws {
        let local = try makeStore()
        try saveRingNight(local, hr: 55)
        try saveRingNight(local, hr: 70, factors: false)
        let row = try row(local)
        XCTAssertNil(store.entry(night: row.night))
        XCTAssertNil(row.scoreBreakdown)
    }

    // MARK: The display rule

    /// A writer that changed the score without saving factors must not leave the old factors on show.
    func testARowWhoseScoreChangedWithoutASavedEntryShowsNoBreakdown() throws {
        let local = try makeStore()
        try saveRingNight(local)
        let row = try row(local)
        XCTAssertNotNil(row.scoreBreakdown)
        row.sleepScore += 1
        XCTAssertNotNil(store.entry(night: row.night), "the stale entry is still there")
        XCTAssertNil(row.scoreBreakdown, "but it no longer matches the badge")
    }

    func testANightScoredBeforeFactorsWereSavedShowsNoBreakdown() throws {
        let local = try makeStore()
        try saveRingNight(local, factors: false)
        XCTAssertNil(try row(local).scoreBreakdown)
    }

    // MARK: Edit writer (`applySleepEdit`)

    func testAnEditOverwritesTheEntryWithTheEditedFourFactorScore() throws {
        let local = try makeStore()
        try saveRingNight(local)
        let edited = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(8))
        let editedSegments = SleepEdit.recompute(baseSegments: segments(), window: edited)
        let summary = SleepStaging.summary(editedSegments)
        XCTAssertTrue(try local.applySleepEdit(night: at(0), editedWindow: edited, summary: summary,
                                               sleepOnset: at(0.5), sleepWake: at(8),
                                               hypnogram: editedSegments))
        let row = try row(local)
        XCTAssertTrue(row.isManuallyEdited)
        let entry = try XCTUnwrap(store.entry(night: row.night))
        XCTAssertEqual(entry.score, row.sleepScore)
        XCTAssertEqual(entry.producer, .edited)
        XCTAssertEqual(entry.factors, compositeFactors(.init(
            totalAsleep: summary.totalAsleep, timeAwake: summary.awake, efficiency: summary.efficiency,
            deep: summary.deep, light: summary.light, rem: summary.rem)))
        XCTAssertEqual(row.scoreBreakdown?.rows.count, 4, "an edit has no HR or temperature factor")
    }

    // MARK: Heal writer (`healWithheldSleepScores`)

    func testTheHealPassOverwritesTheEntryWithTheHealedScore() throws {
        let local = try makeStore()
        try saveRingNight(local)
        let row = try row(local)
        // A build-47/48 scar: an edited night whose score was zeroed. A stale entry from before is
        // still filed under its key.
        row.isManuallyEdited = true
        row.sleepScore = 0
        row.sleepBasis = SleepBasis.measuredOnly.rawValue
        try containers.last!.mainContext.save()
        XCTAssertEqual(store.entry(night: row.night)?.producer, .ring)

        XCTAssertEqual(try local.healWithheldSleepScores(), [row.night])
        let healed = try XCTUnwrap(SleepScoreHeal.healedFactors(hypnogram: segments()))
        XCTAssertEqual(row.sleepScore, healed.score)
        XCTAssertEqual(store.entry(night: row.night), healed)
        XCTAssertEqual(row.scoreBreakdown?.score, row.sleepScore)
    }

    // MARK: Strap writers (`applyHelioNightScores`, `scoreUnscoredHelioNights`)

    private var strap: SyncDeviceID {
        SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-000000000378")
    }

    /// A strap night yesterday, 23:00 → 07:00, with no `.inBed` segment (the strap's record has none).
    private func strapWindow() -> DateInterval {
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        return DateInterval(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(7 * 3600))
    }

    private func strapSegments(_ w: DateInterval) -> [SleepSegment] {
        func f(_ x: Double) -> Date { w.start.addingTimeInterval(w.duration * x) }
        return [
            SleepSegment(start: w.start, end: f(0.35), stage: .asleepCore),
            SleepSegment(start: f(0.35), end: f(0.5), stage: .asleepDeep),
            SleepSegment(start: f(0.5), end: f(0.55), stage: .awake),
            SleepSegment(start: f(0.55), end: f(0.75), stage: .asleepREM),
            SleepSegment(start: f(0.75), end: w.end, stage: .asleepCore),
        ]
    }

    private func strapHR(_ w: DateInterval) -> [QuantitySample] {
        stride(from: w.start.timeIntervalSince1970, to: w.end.timeIntervalSince1970, by: 300).map {
            QuantitySample(kind: .heartRate, start: Date(timeIntervalSince1970: $0), value: 56)
        }
    }

    private func assertStrapEntry(_ local: LocalStore, _ w: DateInterval,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(try local.sleepSummaryOverlapping(start: w.start, end: w.end), file: file, line: line)
        XCTAssertGreaterThan(row.sleepScore, 0, file: file, line: line)
        let entry = try XCTUnwrap(store.entry(night: row.night), "the strap writer must save the factors",
                                  file: file, line: line)
        XCTAssertEqual(entry.score, row.sleepScore, file: file, line: line)
        XCTAssertEqual(entry.producer, .strap, file: file, line: line)
        XCTAssertEqual(entry.inputs.restingHR, 56, "the strap's own heart rate", file: file, line: line)
        XCTAssertEqual(entry.factors, compositeFactors(entry.inputs.compositeInput), file: file, line: line)
        XCTAssertEqual(row.scoreBreakdown?.score, row.sleepScore, file: file, line: line)
    }

    func testTheStrapSavePathSavesTheEntry() throws {
        ownership.install(.strapOwnsAllTime)
        let local = try makeStore()
        let w = strapWindow()
        _ = try local.ingest(strapHR(w), device: strap)
        let night = HelioSleepSelection.Night(segments: strapSegments(w), window: w, strapScore: 77,
                                              recordedTimeZone: TimeZone(identifier: "UTC"))
        XCTAssertEqual(try local.saveHelioNight(night, device: strap), .inserted)
        try assertStrapEntry(local, w)
    }

    func testTheStrapRepairPassSavesTheEntry() throws {
        ownership.install(.strapOwnsAllTime)
        let local = try makeStore()
        let w = strapWindow()
        _ = try local.ingest(strapHR(w), device: strap)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = strapSegments(w)
        try local.saveSleepSummary(SleepStaging.summary(extras.hypnogram),
                                   night: SleepNightKey.night(inBedStart: w.start, inBedEnd: w.end),
                                   inBedStart: w.start, inBedEnd: w.end, extras: extras, device: strap)
        XCTAssertFalse(try local.scoreUnscoredHelioNights().isEmpty)
        try assertStrapEntry(local, w)
    }

    // MARK: The side store itself

    func testItPersistsAcrossInstances() throws {
        let entry = SleepScoreFactors.scored(ringInput(hr: 55, off: nil), producer: .ring)
        store.set(entry, night: at(0))
        XCTAssertEqual(SleepScoreFactorStore(folder: folder).entry(night: at(0)), entry)
    }

    func testItIsBounded() {
        let small = SleepScoreFactorStore(folder: folder.appendingPathComponent("small"), capacity: 3)
        let entry = SleepScoreFactors.scored(ringInput(hr: 55, off: nil), producer: .ring)
        for day in 0..<5 { small.set(entry, night: at(Double(day) * 24)) }
        XCTAssertEqual(small.count, 3)
        XCTAssertNil(small.entry(night: at(0)), "the oldest nights go first")
        XCTAssertNil(small.entry(night: at(24)))
        XCTAssertNotNil(small.entry(night: at(96)))
        XCTAssertEqual(SleepScoreFactorStore(folder: folder.appendingPathComponent("small"), capacity: 3).count, 3,
                       "the bound is on disk too")
    }

    func testAReKeyMovesTheEntryWithTheRow() {
        let entry = SleepScoreFactors.scored(ringInput(hr: 55, off: nil), producer: .ring)
        store.set(entry, night: at(0))
        store.rename(from: at(0), to: at(24))
        XCTAssertNil(store.entry(night: at(0)))
        XCTAssertEqual(store.entry(night: at(24)), entry)
    }

    /// The store wipe (`wipeAndRecoverForeground`) clears every saved entry: the rows it described
    /// are gone, and the rollup restore brings back scores without factors.
    func testTheHistoryResetClearsTheSideStore() throws {
        store.set(SleepScoreFactors.scored(ringInput(hr: 55, off: nil), producer: .ring), night: at(0))
        XCTAssertEqual(store.count, 1)

        let defaults = UserDefaults.standard
        let priorFlag = defaults.object(forKey: HistoryResetNotice.flagKey)
        let priorDate = defaults.object(forKey: HistoryResetNotice.dateKey)
        defer {
            defaults.set(priorFlag, forKey: HistoryResetNotice.flagKey)
            defaults.set(priorDate, forKey: HistoryResetNotice.dateKey)
        }
        let storeURL = folder.appendingPathComponent("wipe/default.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = try OpenCircuitApp.makeContainerOrThrow(storeURL: storeURL).schema
        let fresh = OpenCircuitApp.wipeAndRecoverForeground(
            schema: schema, config: ModelConfiguration(schema: schema, url: storeURL))
        containers.append(fresh)

        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(SleepScoreFactorStore(folder: folder).count, 0, "and the file is gone")
    }
}
