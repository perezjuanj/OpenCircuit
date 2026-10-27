import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// A ring indoor run that ended and waits for its distance prompt (#339, decision 84j) keeps its
// heart-rate readings and pauses on disk next to its snapshot (84l, review-indoor-run-b B1). Killed in
// that wait, the next launch's recovered save writes them with the workout and lands them in LocalStore
// once; a normal save clears them. `WorkoutSessionManager` with an in-memory pending store and its
// deferred-write seam, and a real in-memory `LocalStore`. Every reading and time is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_789_862_400 + 9 * 3600)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

@MainActor
private final class MemoryPending: RingPendingWorkoutStoring {
    var stored: RingPendingWorkout?
    func save(_ pending: RingPendingWorkout) { stored = pending }
    func load() -> RingPendingWorkout? { stored }
    func clear() { stored = nil }
}

@MainActor
private final class DeferredWrites {
    private(set) var writes: [(summary: WorkoutSummary, hr: [HRSample], pauses: [DateInterval], distance: Double?, typed: Bool)] = []
    func record(_ summary: WorkoutSummary, _ hr: [HRSample], _ pauses: [DateInterval], _ distance: Double?, _ typed: Bool) -> Bool {
        writes.append((summary, hr, pauses, distance, typed))
        return true
    }
}

@MainActor
final class RingIndoorRunRecoveryTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(DeviceOwnershipLog())   // a ring-only install: the ring owns all time
        WorkoutHealthExclusions().clear(device: .ringConn)
        WorkoutSessionManager.clearSessionSnapshot()
    }

    override func tearDown() {
        WorkoutSessionManager.clearSessionSnapshot()
        WorkoutHealthExclusions().clear(device: .ringConn)
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private func heartRateRows(_ store: LocalStore) throws -> Int {
        let kindRaw = MetricKind.heartRate.rawValue
        return try store.context.fetchCount(FetchDescriptor<StoredSample>(predicate: #Predicate { $0.kindRaw == kindRaw }))
    }

    /// A 20-minute indoor run with a 2-minute pause: one reading per 10 s outside the pause.
    private let readings: [HRSample] = stride(from: 10.0, through: 1_200, by: 10)
        .filter { !(600 ... 720).contains($0) }
        .map { HRSample(bpm: 150, start: at($0 - 2), end: at($0)) }
    private let pauses = [DateInterval(start: at(600), end: at(720))]

    private var summary: WorkoutSummary {
        WorkoutSummary(sport: .runningIndoor, startDate: t0, endDate: at(1_200), avgHR: 150, maxHR: 150,
                       estimatedActiveKcal: 180, zoneBreakdown: WorkoutZoneBreakdown(), distanceMeters: nil,
                       hasRoute: false, hrSampleCount: readings.count)
    }

    private func manager(_ pending: MemoryPending, _ writes: DeferredWrites) -> WorkoutSessionManager {
        let manager = WorkoutSessionManager()
        manager.pendingReadings = pending
        manager.deferredWriteOverride = { summary, hr, pauses, distance, typed in
            writes.record(summary, hr, pauses, distance, typed)
        }
        return manager
    }

    func testAKillWhileWaitingIsRecoveredWithItsReadingsAndPausesAndLandsThemOnce() async throws {
        let pending = MemoryPending()
        let ended = manager(pending, DeferredWrites())
        ended.beginWaitingSave(summary: summary, end: at(1_200), hrSamples: readings, pauses: pauses,
                               estimate: 3_500, unresolve: {})
        XCTAssertEqual(pending.stored?.hrSamples.count, readings.count, "on disk next to the snapshot")
        // The process dies here. The next launch, as ContentView runs it: the offer, then Save.
        let decision = WorkoutSessionManager.recoveryDecision(snapshot: WorkoutSessionManager.persistedSessionSnapshot,
                                                              now: at(4_000))
        guard case .offer(let recovered) = decision else { return XCTFail("expected an offer, got \(decision)") }
        XCTAssertEqual(recovered.end, at(1_200), "closed at End")
        WorkoutSessionManager.clearSessionSnapshot()
        let writes = DeferredWrites()
        let relaunched = manager(pending, writes)
        let store = try makeStore()
        let saved = await relaunched.saveRecoveredWorkout(recovered, store: store)
        XCTAssertTrue(saved)
        XCTAssertEqual(writes.writes.count, 1)
        XCTAssertEqual(writes.writes.first?.hr, readings, "the workout keeps its heart rate")
        XCTAssertEqual(writes.writes.first?.pauses, pauses)
        XCTAssertEqual(writes.writes.first?.distance, 3_500)
        XCTAssertEqual(writes.writes.first?.typed, false, "the step estimate")
        XCTAssertEqual(try heartRateRows(store), readings.count, "landed in LocalStore")
        XCTAssertNil(pending.stored, "taken: written and landed once")
    }

    func testANormalSaveClearsThePersistedReadingsAndLandsThemOnce() async throws {
        let pending = MemoryPending()
        let writes = DeferredWrites()
        let ring = manager(pending, writes)
        let store = try makeStore()
        ring.store = store
        ring.beginWaitingSave(summary: summary, end: at(1_200), hrSamples: readings, pauses: pauses,
                              estimate: 3_500, unresolve: {})
        ring.saveWaitingWorkout(typedMeters: 3_900)
        XCTAssertNil(pending.stored, "cleared before the write")
        XCTAssertNil(WorkoutSessionManager.persistedSessionSnapshot, "and the snapshot with it")
        await ring.deferredSaveTask?.value
        XCTAssertEqual(writes.writes.count, 1)
        XCTAssertEqual(writes.writes.first?.hr, readings)
        XCTAssertEqual(writes.writes.first?.distance, 3_900)
        XCTAssertEqual(writes.writes.first?.typed, true)
        XCTAssertEqual(try heartRateRows(store), readings.count)
        // A later relaunch finds nothing to offer, and nothing to take.
        XCTAssertEqual(WorkoutSessionManager.recoveryDecision(snapshot: WorkoutSessionManager.persistedSessionSnapshot),
                       .nothingToRecover)
        XCTAssertNil(pending.take(start: t0))
    }

    func testReadingsLeftByAnotherWorkoutAreNeverWrittenWithThisOne() async throws {
        let pending = MemoryPending()
        pending.save(RingPendingWorkout(start: at(-86_400), hrSamples: readings, pauses: []))
        XCTAssertNil(pending.take(start: t0))
        XCTAssertNil(pending.stored, "and the stray file is removed")
    }

    func testTheFileStoreRoundTripsAndClears() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ring-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = RingPendingWorkoutFile(folder: folder)
        XCTAssertNil(file.load())
        let value = RingPendingWorkout(start: t0, hrSamples: readings, pauses: pauses)
        file.save(value)
        XCTAssertEqual(file.load(), value)
        file.clear()
        XCTAssertNil(file.load())
    }
}
