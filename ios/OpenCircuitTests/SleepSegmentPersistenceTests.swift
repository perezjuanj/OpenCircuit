import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Simulation of the stranded-sleep bug-and-fix path, using no real hardware:
//
//  Bug: [SleepSegment] arrays lived only in-memory on RingSession. When the session
//       was torn down (BG expiry, kill, relaunch), segments were lost. flushHealth()
//       saw session==nil → segments=[] → pendingHealthSleep([]) returned [] → HealthKit
//       was never updated even though StoredSleepSummary showed data in the app UI.
//
//  Fix: commitDrainedRecords() now persists segments to EpochArchiveStore (UserDefaults).
//       flushHealth() falls back to the archive when session segments are empty, then
//       calls clearPendingSleepSegments() after a confirmed HealthKit write.
//       The .sleep cursor in LocalStore is the idempotency guard (prevents re-writes).
@MainActor
final class SleepSegmentPersistenceTests: XCTestCase {

    // Isolated UserDefaults suite per test run — never touches real app state.
    private let suiteName = "test.SleepSegmentPersistenceTests"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: Fixtures

    // 2026-06-28 22:00 UTC → 2026-06-29 06:30 UTC (realistic overnight window)
    private let nightStart = Date(timeIntervalSince1970: 1_751_148_000)
    private let nightEnd   = Date(timeIntervalSince1970: 1_751_178_600)

    /// Coarse two-segment summary the ring always emits.
    private var coarseSegments: [SleepSegment] {[
        SleepSegment(start: nightStart, end: nightEnd, stage: .inBed),
        SleepSegment(start: nightStart, end: nightEnd, stage: .asleepCore),
    ]}

    /// Staged four-segment hypnogram produced by the sleep-staging model.
    private var stagedSegments: [SleepSegment] {
        let midNight = nightStart.addingTimeInterval(14400)   // 02:00 UTC
        let lateNight = midNight.addingTimeInterval(7200)     // 04:00 UTC
        return [
            SleepSegment(start: nightStart, end: midNight,  stage: .asleepDeep),
            SleepSegment(start: midNight,   end: lateNight, stage: .asleepREM),
            SleepSegment(start: lateNight,  end: nightEnd,  stage: .awake),
        ]
    }

    private func makeArchive(namespace: String = "ring-A") -> EpochArchiveStore {
        EpochArchiveStore(namespace: namespace, testDefaults)
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return LocalStore(container.mainContext)
    }

    // MARK: EpochArchiveStore round-trip

    func testRoundTrip_coarseAndStagedSurviveReinstantiation() {
        let archive = makeArchive()
        archive.savePendingSleepSegments(coarse: coarseSegments, staged: stagedSegments)

        // Fresh instance with same namespace + defaults simulates app relaunch.
        let reloaded = makeArchive()
        let (coarse, staged) = reloaded.loadPendingSleepSegments()

        XCTAssertEqual(coarse.count, coarseSegments.count)
        XCTAssertEqual(staged.count, stagedSegments.count)
        XCTAssertEqual(coarse.map(\.stage), coarseSegments.map(\.stage))
        XCTAssertEqual(staged.map(\.stage), stagedSegments.map(\.stage))
        // Timestamps must survive JSON encode/decode (rounded to second).
        XCTAssertEqual(staged.map { $0.end.timeIntervalSince1970.rounded() },
                       stagedSegments.map { $0.end.timeIntervalSince1970.rounded() })
    }

    func testRoundTrip_emptyLoadBeforeAnySave() {
        let (coarse, staged) = makeArchive().loadPendingSleepSegments()
        XCTAssertTrue(coarse.isEmpty)
        XCTAssertTrue(staged.isEmpty)
    }

    func testRoundTrip_saveOverwritesPreviousNight() {
        let archive = makeArchive()
        archive.savePendingSleepSegments(coarse: coarseSegments, staged: stagedSegments)

        // Save a single-segment replacement (simulates a re-sync of a different night).
        let replacement = [SleepSegment(start: nightEnd, end: nightEnd.addingTimeInterval(28800), stage: .inBed)]
        archive.savePendingSleepSegments(coarse: replacement, staged: [])

        let (coarse, staged) = makeArchive().loadPendingSleepSegments()
        XCTAssertEqual(coarse.count, 1)
        XCTAssertTrue(staged.isEmpty)
    }

    func testClear_removesPersistedSegments() {
        let archive = makeArchive()
        archive.savePendingSleepSegments(coarse: coarseSegments, staged: stagedSegments)
        archive.clearPendingSleepSegments()

        let (coarse, staged) = makeArchive().loadPendingSleepSegments()
        XCTAssertTrue(coarse.isEmpty)
        XCTAssertTrue(staged.isEmpty)
    }

    func testNamespace_twoRingsAreIsolated() {
        let archiveA = EpochArchiveStore(namespace: "ring-A", testDefaults)
        let archiveB = EpochArchiveStore(namespace: "ring-B", testDefaults)

        archiveA.savePendingSleepSegments(coarse: coarseSegments, staged: [])

        let (coarseA, _) = archiveA.loadPendingSleepSegments()
        let (coarseB, _) = archiveB.loadPendingSleepSegments()
        XCTAssertEqual(coarseA.count, coarseSegments.count)
        XCTAssertTrue(coarseB.isEmpty, "ring-B must not inherit ring-A's data")
    }

    // MARK: LocalStore cursor gate (standalone)

    func testCursorGate_newNightOffersAllSegments() throws {
        let store = try makeStore()
        let pending = try store.pendingHealthSleep(stagedSegments)
        // Cursor starts at distantPast — every segment is new.
        XCTAssertEqual(pending.count, stagedSegments.count)
    }

    func testCursorGate_alreadyWrittenNightIsSkipped() throws {
        let store = try makeStore()
        try store.markSleepWritten(stagedSegments)
        XCTAssertTrue(try store.pendingHealthSleep(stagedSegments).isEmpty,
                      "cursor past the night's max-end — nothing should be re-offered")
    }

    func testCursorGate_emptySegmentsReturnEmpty() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.pendingHealthSleep([]).isEmpty)
    }

    func testCursorGate_partialNightFiltersByEnd() throws {
        // Cursor sits halfway through the night — only segments ending AFTER the watermark surface.
        let store = try makeStore()
        let midNight = nightStart.addingTimeInterval(14400)
        let firstHalf  = SleepSegment(start: nightStart, end: midNight,  stage: .asleepDeep)
        let secondHalf = SleepSegment(start: midNight,   end: nightEnd,  stage: .asleepREM)
        try store.markSleepWritten([firstHalf])   // advance cursor to midNight

        let pending = try store.pendingHealthSleep([firstHalf, secondHalf])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.stage, .asleepREM)
    }

    // MARK: Full stranded-sleep simulation

    /// Simulates the complete bug-then-fix path:
    ///   Phase 1 — Morning sync commits records → segments saved to EpochArchiveStore.
    ///   Phase 2 — App killed / BG task expired → session torn down (new archive instance).
    ///   Phase 3 — App re-opens: flushHealth loads archive, pendingHealthSleep returns segments,
    ///              markSleepWritten advances cursor, archive cleared.
    ///   Phase 4 — Second flushHealth: cursor blocks re-write; archive already empty.
    func testFullStrandedSleep_segmentsSurviveSessionTeardownAndWriteExactlyOnce() throws {
        let store = try makeStore()

        // Phase 1: drain committed → segments persisted (mirrors commitDrainedRecords fix).
        let archive = makeArchive()
        archive.savePendingSleepSegments(coarse: coarseSegments, staged: stagedSegments)

        // Phase 2: session torn down — simulated by dropping the archive reference.
        // A fresh instance loaded with the same namespace/defaults represents the next launch.
        let freshArchive = makeArchive()
        let (_, persisted) = freshArchive.loadPendingSleepSegments()
        XCTAssertFalse(persisted.isEmpty, "staged segments must survive a simulated relaunch")
        XCTAssertEqual(persisted.count, stagedSegments.count)

        // Phase 3a: flushHealth fallback — segments offered to HealthKit.
        let pending = try store.pendingHealthSleep(persisted)
        XCTAssertFalse(pending.isEmpty, "persisted segments must pass the cursor gate")

        // Phase 3b: confirmed HealthKit write → advance cursor + clear archive.
        try store.markSleepWritten(pending)
        freshArchive.clearPendingSleepSegments()

        // Phase 4: second flush — cursor blocks re-write; archive is already empty.
        let (_, afterClear) = makeArchive().loadPendingSleepSegments()
        XCTAssertTrue(afterClear.isEmpty, "archive must be empty after the successful write")
        XCTAssertTrue(try store.pendingHealthSleep(persisted).isEmpty,
                      "cursor must block a second write of the same night")
    }

    /// Verifies that a failed HealthKit save (markSleepWritten never called) does NOT
    /// lose the night: segments are re-offered on the next flushHealth call.
    func testStrandedSleep_failedHealthKitWriteBackfillsOnRetry() throws {
        let store = try makeStore()
        let archive = makeArchive()
        archive.savePendingSleepSegments(coarse: coarseSegments, staged: stagedSegments)

        let (_, persisted) = makeArchive().loadPendingSleepSegments()

        // First flush attempt: read pending but do NOT mark written (simulates failed HK save).
        let firstAttempt = try store.pendingHealthSleep(persisted)
        XCTAssertFalse(firstAttempt.isEmpty)

        // Second flush: same segments must still be offered — cursor was never advanced.
        let secondAttempt = try store.pendingHealthSleep(persisted)
        XCTAssertEqual(secondAttempt.count, firstAttempt.count,
                       "backfill must re-offer the same night after a failed write")
    }

    /// When both coarse and staged segments are non-empty, flushHealth prefers staged
    /// (finer hypnogram) — matches the selection logic added to ContentView.flushHealth().
    func testStagedPreferredOverCoarseWhenBothNonEmpty() {
        let archive = makeArchive()
        archive.savePendingSleepSegments(coarse: coarseSegments, staged: stagedSegments)

        let (coarse, staged) = makeArchive().loadPendingSleepSegments()
        // Mirror the flushHealth selection: use staged if both non-empty.
        let selected = !staged.isEmpty && !coarse.isEmpty ? staged : coarse
        XCTAssertEqual(selected.map(\.stage), stagedSegments.map(\.stage),
                       "staged segments must be selected when both arrays are non-empty")
    }

    /// When staged is empty (sleep-staging model produced no output), coarse is the fallback.
    func testCoarseFallbackWhenStagedEmpty() {
        let archive = makeArchive()
        archive.savePendingSleepSegments(coarse: coarseSegments, staged: [])

        let (coarse, staged) = makeArchive().loadPendingSleepSegments()
        let selected = !staged.isEmpty && !coarse.isEmpty ? staged : coarse
        XCTAssertEqual(selected.map(\.stage), coarseSegments.map(\.stage),
                       "coarse must be the fallback when staged is empty")
    }
}
