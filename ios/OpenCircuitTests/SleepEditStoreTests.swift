import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

@MainActor
final class SleepEditStoreTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func at(_ hours: Double) -> Date {
        ref.addingTimeInterval(hours * 3600)
    }

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

    private func seed(_ store: LocalStore) throws {
        let summary = SleepStaging.Summary(inBed: 8 * 3600, awake: 30 * 60,
                                           light: 5 * 3600, deep: 90 * 60, rem: 60 * 60)
        try store.saveSleepSummary(summary, night: at(0), inBedStart: at(0), inBedEnd: at(8),
                                   sleepOnset: at(0.5), sleepWake: at(7.75))
    }

    func testFirstEditPersistsFlagOverlayAndImmutableRecordedAnchors() throws {
        let store = try makeStore()
        try seed(store)
        let edited = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let segments = SleepEdit.recompute(
            baseSegments: [
                .init(start: at(0), end: at(8), stage: .inBed),
                .init(start: at(0), end: at(8), stage: .asleepCore),
            ], window: edited)
        let summary = SleepStaging.summary(segments)

        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: edited,
                                                summary: summary,
                                                sleepOnset: at(-1), sleepWake: at(9)))
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        XCTAssertTrue(row.isManuallyEdited)
        XCTAssertEqual(row.editedInBedStart, at(-1))
        XCTAssertEqual(row.editedInBedEnd, at(9))
        XCTAssertEqual(row.inBedStart, at(0), "recorded anchors remain immutable")
        XCTAssertEqual(row.inBedEnd, at(8))
        XCTAssertEqual(row.sleepOnset, at(0.5))
        XCTAssertEqual(row.sleepWake, at(7.75))
        XCTAssertEqual(row.asleepMin, 10 * 60)
        XCTAssertEqual(row.efficiency, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(row.sleepScore, 0)
    }

    func testResyncCannotOverwriteManualEditAndReeditKeepsOriginalBounds() throws {
        let store = try makeStore()
        try seed(store)
        let first = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let firstSummary = SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                                light: 10 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: first,
                                                summary: firstSummary,
                                                sleepOnset: at(-1), sleepWake: at(9)))

        // A later sync is ignored once the explicit persisted flag is set.
        let replacement = SleepStaging.Summary(inBed: 2 * 3600, awake: 0,
                                                light: 2 * 3600, deep: 0, rem: 0)
        try store.saveSleepSummary(replacement, night: at(0), inBedStart: at(3), inBedEnd: at(5))
        XCTAssertEqual(try store.sleepSummary(night: at(0))?.editedInBedStart, at(-1))

        let second = SleepEdit.Window(inBedStart: at(-2), inBedEnd: at(10))
        let secondSummary = SleepStaging.Summary(inBed: 12 * 3600, awake: 0,
                                                 light: 12 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: second,
                                                summary: secondSummary,
                                                sleepOnset: at(-2), sleepWake: at(10)))
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        XCTAssertEqual(row.sleepOnset, at(0.5))
        XCTAssertEqual(row.sleepWake, at(7.75))
        XCTAssertEqual(row.inBedStart, at(0))
        XCTAssertEqual(row.inBedEnd, at(8))
        XCTAssertEqual(row.editedInBedStart, at(-2))
        XCTAssertEqual(row.editedInBedEnd, at(10))
    }

    func testManualFlagIsNotInferredFromUncommittedOverlayDates() throws {
        let store = try makeStore()
        try seed(store)
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        row.editedInBedStart = at(-1)
        row.editedInBedEnd = at(9)
        XCTAssertFalse(row.isManuallyEdited)
    }

    func testVisuallyUnchangedRecordedWindowDoesNotBecomeManualEdit() throws {
        let store = try makeStore()
        try seed(store)
        let row = try XCTUnwrap(store.sleepSummary(night: at(0)))
        // The picker displays minute precision. Hidden seconds may change after interacting with it,
        // but returning to the same displayed minutes is still an unchanged edit.
        let unchanged = SleepEdit.Window(inBedStart: row.inBedStart.addingTimeInterval(10),
                                         inBedEnd: row.inBedEnd.addingTimeInterval(10))
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: unchanged,
                                                summary: row.asSummary,
                                                sleepOnset: row.sleepOnset,
                                                sleepWake: row.sleepWake))
        XCTAssertFalse(row.isManuallyEdited)
        XCTAssertEqual(row.editedInBedStart, .distantPast)
        XCTAssertEqual(row.editedInBedEnd, .distantPast)
    }

    func testLeadingHealthExtensionIsPendingRetryableAndIncrementalAcrossReedit() throws {
        let store = try makeStore()
        try seed(store)
        try store.markSleepWritten([
            .init(start: at(0), end: at(8), stage: .asleepCore)
        ])

        let first = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let firstSummary = SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                                light: 10 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: first,
                                                summary: firstSummary,
                                                sleepOnset: at(-1), sleepWake: at(9)))

        let pending = try store.pendingSleepEditHealthWrites()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].segments.map(\.stage), [.inBed, .asleepCore, .inBed, .asleepCore])
        XCTAssertEqual(pending[0].segments.first?.start, at(-1))
        XCTAssertEqual(pending[0].segments.first?.end, at(0))
        XCTAssertEqual(pending[0].segments[2].start, at(8))
        XCTAssertEqual(pending[0].segments[2].end, at(9))
        // Merely reading pending work does not mark it; a failed/denied write retries identically.
        XCTAssertEqual(try store.pendingSleepEditHealthWrites().first?.segments, pending[0].segments)

        try store.markSleepEditHealthWritten(night: pending[0].night, segments: pending[0].segments)
        XCTAssertTrue(try store.pendingSleepEditHealthWrites().isEmpty)
        XCTAssertTrue(try store.pendingHealthSleep([
            .init(start: at(8), end: at(9), stage: .asleepCore),
        ]).isEmpty, "successful manual-tail retry must advance the shared sleep cursor")

        let second = SleepEdit.Window(inBedStart: at(-2), inBedEnd: at(10))
        let secondSummary = SleepStaging.Summary(inBed: 12 * 3600, awake: 0,
                                                 light: 12 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: second,
                                                summary: secondSummary,
                                                sleepOnset: at(-2), sleepWake: at(10)))
        let incremental = try XCTUnwrap(store.pendingSleepEditHealthWrites().first)
        XCTAssertEqual(incremental.segments.first?.start, at(-2))
        XCTAssertEqual(incremental.segments.first?.end, at(-1),
                       "re-edit must append only the newly exposed bedtime slice")
    }

    func testNormalFullNightWriteCoversLeadingEditWithoutSecondAppend() throws {
        let store = try makeStore()
        try seed(store)
        let edited = SleepEdit.Window(inBedStart: at(-1), inBedEnd: at(9))
        let summary = SleepStaging.Summary(inBed: 10 * 3600, awake: 0,
                                           light: 10 * 3600, deep: 0, rem: 0)
        XCTAssertTrue(try store.applySleepEdit(night: at(0), editedWindow: edited,
                                                summary: summary,
                                                sleepOnset: at(-1), sleepWake: at(9)))

        let full = [SleepSegment(start: at(-1), end: at(9), stage: .asleepCore)]
        try store.markSleepWritten(full)
        try store.markSleepEditHealthCovered(by: full)
        XCTAssertTrue(try store.pendingSleepEditHealthWrites().isEmpty)
        XCTAssertTrue(try store.pendingSleepEditHealthWrites().isEmpty)
    }
}
