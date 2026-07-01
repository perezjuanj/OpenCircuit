import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// End-to-end "capture -> store" coverage (A4 of the test-coverage gap): exercises the real
// sequencing risk flagged in the deep assessment — cursor advancing only after a durable
// store commit, and the sleep-summary merge picking the fuller side — using the SAME real
// 0x4c fixture bytes BulkSleepTests already has. Does NOT touch CoreBluetooth or HealthKit
// (see the BLE-mock and HealthKit-mirror gaps, tracked separately); this is the cheap,
// zero-mocking two-thirds of the full BLE->store->HealthKit pipeline.
@MainActor
final class CaptureToStoreEndToEndTests: XCTestCase {

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return LocalStore(container.mainContext)
    }

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Real, XOR-valid 0x4c page (same fixture as BulkSleepTests.realPage): header 4c 00 26,
    // 6 x 23-byte records, then XOR. Two of the six are sleep-vitals epochs with valid HR.
    private let realPage = "4c00260c22a16b55210a7d120a010101010100000402400400000c22a20155000300"
        + "120a010101010100003c00000d01200c22a297540001005f0a010101010100001101b00f"
        + "00440c22a32d6027077b120a010101010100402501c02235a00c22a3c351260577120b01"
        + "0101010108a01000000401300c22a459502d0378120a01010101010160200000040ff0cc"

    // MARK: Cursor dedup across a re-sync (PROTOCOL.md §3: consecutive syncs re-deliver overlap)

    func testFirstIngestPersistsNewSamples() throws {
        let store = try makeStore()
        let records = BulkSleep.records(fromPage: hex(realPage))
        XCTAssertFalse(records.isEmpty, "fixture must decode")
        let samples = BulkSleep.samples(from: records)

        let ingested = try store.ingest(samples)

        XCTAssertEqual(ingested.count, samples.count)
        XCTAssertFalse(ingested.isEmpty)
    }

    func testReSyncOfSamePageDoesNotDuplicate() throws {
        let store = try makeStore()
        let records = BulkSleep.records(fromPage: hex(realPage))
        let samples = BulkSleep.samples(from: records)

        let firstIngest = try store.ingest(samples)
        XCTAssertFalse(firstIngest.isEmpty)

        // Same page redelivered (the documented small re-sync overlap) -> the cursor already
        // advanced past every one of these timestamps, so nothing new should land.
        let secondIngest = try store.ingest(samples)
        XCTAssertTrue(secondIngest.isEmpty,
                      "re-syncing the same page must not duplicate already-ingested samples")

        // The store itself only holds the first ingest's rows, not double the count.
        let stored = try store.samples(kind: .heartRate,
                                       from: .distantPast, to: .distantFuture)
        let firstHRCount = firstIngest.filter { $0.kind == .heartRate }.count
        XCTAssertEqual(stored.count, firstHRCount)
    }

    func testCursorAdvancesOnlyPastIngestedSamples() throws {
        let store = try makeStore()
        let records = BulkSleep.records(fromPage: hex(realPage))
        let samples = BulkSleep.samples(from: records)
        _ = try store.ingest(samples)

        let cursor = try store.loadCursor()
        let latestHR = samples.filter { $0.kind == .heartRate }.map(\.start).max()
        XCTAssertNotNil(latestHR)
        XCTAssertEqual(cursor.last(.heartRate), latestHR)
    }

    // MARK: Sleep-summary merge (fuller night must survive a thinner re-stage)

    private func summary(inBedMin: Int, asleepMin: Int) -> SleepStaging.Summary {
        // Split the asleep minutes entirely into "light" for simplicity; only totals matter
        // to SleepSummaryMerge.shouldReplace (driven by `summary.minutes.asleep`).
        SleepStaging.Summary(inBed: TimeInterval(inBedMin * 60), awake: TimeInterval((inBedMin - asleepMin) * 60),
                             light: TimeInterval(asleepMin * 60), deep: 0, rem: 0)
    }

    func testFullerNightReplacesThinnerStoredNight() throws {
        let store = try makeStore()
        let night = Date(timeIntervalSince1970: 1_750_000_000)   // arbitrary fixed night
        let inBedStart = night
        let thinEnd = night.addingTimeInterval(2 * 3600)     // 2h fragment
        let fullEnd = night.addingTimeInterval(8 * 3600)     // 8h full night

        // A thin fragment lands first (e.g. a background drain mid-night)...
        try store.saveSleepSummary(summary(inBedMin: 120, asleepMin: 100),
                                   night: night, inBedStart: inBedStart, inBedEnd: thinEnd)
        // ...then the fuller morning sync arrives and should REPLACE it.
        try store.saveSleepSummary(summary(inBedMin: 480, asleepMin: 420),
                                   night: night, inBedStart: inBedStart, inBedEnd: fullEnd)

        let stored = try store.latestSleepSummary()
        XCTAssertEqual(stored?.asleepMin, 420, "the fuller night must win")
    }

    func testThinnerReStageDoesNotClobberFullerStoredNight() throws {
        let store = try makeStore()
        let night = Date(timeIntervalSince1970: 1_750_000_000)
        let inBedStart = night
        let fullEnd = night.addingTimeInterval(8 * 3600)
        let thinEnd = night.addingTimeInterval(2 * 3600)

        // The full night is already stored (e.g. the morning sync)...
        try store.saveSleepSummary(summary(inBedMin: 480, asleepMin: 420),
                                   night: night, inBedStart: inBedStart, inBedEnd: fullEnd)
        // ...then a later, SHORTER re-stage (e.g. a stray periodic drain) must NOT shrink it.
        try store.saveSleepSummary(summary(inBedMin: 120, asleepMin: 100),
                                   night: night, inBedStart: inBedStart, inBedEnd: thinEnd)

        let stored = try store.latestSleepSummary()
        XCTAssertEqual(stored?.asleepMin, 420, "a thinner re-stage must not clobber the fuller night")
    }
}
