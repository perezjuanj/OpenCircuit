import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The Health mirror resolves a night by IN-BED OVERLAP against the stored summary rather than
/// `startOfDay(firstSegmentStart)`, so a bedtime that straddles midnight (or a lead-in trim that moves
/// the earliest start across it) can't key the mirror to a different calendar day than the card — which
/// would else miss a manually-edited row (invariant 5) or under-scope the delete cleanup.
@MainActor
final class SleepMirrorOverlapTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() { containers.removeAll(); super.tearDown() }

    private func at(_ hours: Double) -> Date { ref.addingTimeInterval(hours * 3600) }

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

    private func seedNight(_ store: LocalStore, night: Date, inBedStart: Date, inBedEnd: Date) throws {
        let summary = SleepStaging.Summary(inBed: inBedEnd.timeIntervalSince(inBedStart),
                                           awake: 30 * 60, light: 5 * 3600, deep: 90 * 60, rem: 60 * 60)
        try store.saveSleepSummary(summary, night: night, inBedStart: inBedStart, inBedEnd: inBedEnd,
                                   sleepOnset: inBedStart, sleepWake: inBedEnd)
    }

    func testOverlappingSpanResolvesTheRow() throws {
        let store = try makeStore()
        try seedNight(store, night: at(0), inBedStart: at(0), inBedEnd: at(8))
        // A re-drain whose span is shifted but still overlaps the stored in-bed window.
        let row = try store.sleepSummaryOverlapping(start: at(1), end: at(9))
        XCTAssertEqual(row?.inBedStart, at(0), "an overlapping span must resolve the stored night")
    }

    func testNonOverlappingSpanReturnsNil() throws {
        let store = try makeStore()
        try seedNight(store, night: at(0), inBedStart: at(0), inBedEnd: at(8))
        XCTAssertNil(try store.sleepSummaryOverlapping(start: at(10), end: at(12)),
                     "a span that doesn't touch the in-bed window must not resolve it")
    }

    func testPicksLargestOverlapAmongNights() throws {
        let store = try makeStore()
        try seedNight(store, night: at(-24), inBedStart: at(-25), inBedEnd: at(-17)) // prior night
        try seedNight(store, night: at(0), inBedStart: at(0), inBedEnd: at(8))        // last night
        // Span overlaps last night by ~7h and the prior night not at all.
        let row = try store.sleepSummaryOverlapping(start: at(1), end: at(9))
        XCTAssertEqual(row?.inBedStart, at(0))
    }

    func testResolvesEvenWhenSpanStartDayDiffersFromNightKey() throws {
        // The core #4/#1 case: the stored row's `night` (start-of-day) and the query span's own
        // start-of-day fall on DIFFERENT calendar days, yet overlap resolution still finds the row —
        // where the old `sleepSummary(night: startOfDay(start))` lookup would have returned nil.
        let store = try makeStore()
        // Anchor to a real local midnight so the day boundary is deterministic across time zones:
        // the night starts just AFTER midnight (keyed to day D), the re-drain span starts just BEFORE
        // it (day D-1) — exactly the bedtime-straddles-midnight scenario.
        let midnight = Calendar.current.startOfDay(for: ref)
        let inBedStart = midnight.addingTimeInterval(15 * 60)     // 00:15, day D
        let inBedEnd = inBedStart.addingTimeInterval(8 * 3600)
        try seedNight(store, night: inBedStart, inBedStart: inBedStart, inBedEnd: inBedEnd)
        let rowDay = Calendar.current.startOfDay(for: inBedStart)   // day D
        let queryStart = midnight.addingTimeInterval(-30 * 60)      // 23:30, day D-1
        XCTAssertNotEqual(Calendar.current.startOfDay(for: queryStart), rowDay,
                          "precondition: query start is on an earlier calendar day than the row key")
        let resolved = try store.sleepSummaryOverlapping(start: queryStart, end: inBedEnd)
        XCTAssertEqual(resolved?.night, rowDay,
                       "overlap resolution must find the row regardless of the day-key mismatch")
    }
}
