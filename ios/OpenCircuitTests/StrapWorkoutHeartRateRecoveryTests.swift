import CoreLocation
import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Heart rate recovery after a strap workout (#337, decision 82): the recorder's recovery window
// against a fake strap, fake Health writers, an in-memory journal and a fake clock, plus the window's
// readings in a real in-memory `LocalStore`. Every reading and time is synthetic and rounded.

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// MARK: - Fakes

@MainActor
private final class RecoverySource: StrapWorkoutHeartRateSource {
    let timeline: SyncDeviceID
    var isLinkConnected = true
    var ready = true
    var syncing = false
    var canStreamHeartRate = true
    var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    var rrIntervalsReceived = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var syncRequests = 0
    var log: EventLog?

    init(timeline: SyncDeviceID) { self.timeline = timeline }

    func startWorkoutHeartRate() { starts += 1 }
    func stopWorkoutHeartRate() { stops += 1; log?.add("stream stopped") }
    func sendOwedOrphanStop() {}
    func syncHistory(manual: Bool) { syncRequests += 1; log?.add("sync") }

    func send(_ bpm: Int, at date: Date) { heartRateObserver?(bpm, date) }
}

/// The order things happened in, across the fakes.
@MainActor
private final class EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

@MainActor
private final class WorkoutHealth: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    var accept = true
    var log: EventLog?
    func save(_ write: StrapWorkoutWrite) async -> Bool {
        writes.append(write)
        log?.add("workout saved")
        return accept
    }
}

@MainActor
private final class RecoveryHealth: HeartRateRecoveryHealthWriting {
    private(set) var readingWrites: [[HRSample]] = []
    private(set) var cardioWrites: [(bpm: Int, at: Date, timeline: SyncDeviceID)] = []
    var readingsStatus: HeartRateRecoveryHealthStatus = .saved
    var cardioStatus: HeartRateRecoveryHealthStatus = .saved
    var log: EventLog?
    func saveRecoveryHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus {
        readingWrites.append(samples)
        log?.add("recovery readings saved")
        return readingsStatus
    }
    func saveCardioRecovery(_ bpm: Int, at date: Date, timeline: SyncDeviceID) async -> HeartRateRecoveryHealthStatus {
        cardioWrites.append((bpm, date, timeline))
        log?.add("cardio recovery saved")
        return cardioStatus
    }
}

@MainActor
private final class RecoveryJournal: StrapWorkoutJournalStoring {
    var journal: StrapWorkoutJournal?
    var samples: [HRSample] = []
    var landing: [StrapWorkoutLandingBatch] = []
    var parked: [StrapWorkoutParked] = []
    func loadJournal() -> StrapWorkoutJournal? { journal }
    func saveJournal(_ journal: StrapWorkoutJournal) { self.journal = journal }
    func appendSamples(_ samples: [HRSample]) { self.samples += samples }
    func loadSamples() -> [HRSample] { samples }
    func clearRunning() { journal = nil; samples = [] }
    func parkRunning() { clearRunning() }
    func loadParked() -> [StrapWorkoutParked] { parked }
    func saveParked(_ parked: [StrapWorkoutParked]) { self.parked = parked }
    func loadLanding() -> [StrapWorkoutLandingBatch] { landing }
    func saveLanding(_ batches: [StrapWorkoutLandingBatch]) { landing = batches }
}

@MainActor
private final class StillLocation: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    func start(route: Bool) { gpsActive = true }
    func setPaused(_ paused: Bool) {}
    func stop() { gpsActive = false }
}

@MainActor
private final class RecordingHRStore: StrapWorkoutHRStore {
    private(set) var batches: [[HRSample]] = []
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws { batches.append(samples) }
}

// MARK: - Recorder

@MainActor
final class StrapWorkoutHeartRateRecoveryTests: XCTestCase {
    private var now = t0
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-HRR")
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)
    private var windowsSuite = "strap-hrr-windows-\(UUID().uuidString)"
    private var recorders: [StrapWorkoutRecorder] = []

    override func tearDown() {
        for recorder in recorders {
            if recorder.isRecording { recorder.cancel() }
            recorder.skipRecovery()
        }
        recorders.removeAll()
        UserDefaults().removePersistentDomain(forName: windowsSuite)
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "no test may leave the strap held")
        super.tearDown()
    }

    private struct Rig {
        let recorder: StrapWorkoutRecorder
        let source: RecoverySource
        let health: WorkoutHealth
        let recovery: RecoveryHealth?
        let journal: RecoveryJournal
        let store: RecordingHRStore
        let windows: WorkoutRecoveryWindows
        let log: EventLog
    }

    /// `window: false` builds the recorder as master did: no recovery writer, so no window.
    private func makeRig(window: Bool = true, hrStore: (any StrapWorkoutHRStore)? = nil) -> Rig {
        let log = EventLog()
        let source = RecoverySource(timeline: timeline)
        source.log = log
        let health = WorkoutHealth()
        health.log = log
        let recovery = window ? RecoveryHealth() : nil
        recovery?.log = log
        let journal = RecoveryJournal()
        let store = RecordingHRStore()
        let windows = WorkoutRecoveryWindows(UserDefaults(suiteName: windowsSuite)!)
        let profile = self.profile
        let storeToUse: any StrapWorkoutHRStore = hrStore ?? store
        let recorder = StrapWorkoutRecorder(
            source: { source }, health: health, journal: journal, hrStore: { storeToUse },
            location: StillLocation(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-hrr-orphan-\(UUID().uuidString)")!),
            tombstones: WorkoutTombstones(UserDefaults(suiteName: "strap-hrr-tomb-\(UUID().uuidString)")!),
            recoveryHealth: recovery, recoveryWindows: windows,
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = .runningIndoor
        recorders.append(recorder)
        return Rig(recorder: recorder, source: source, health: health, recovery: recovery, journal: journal,
                   store: store, windows: windows, log: log)
    }

    /// One reading a second over `(from, to]`, ticking the recorder each second as production does.
    private func stream(_ rig: Rig, from: TimeInterval, to: TimeInterval, bpm: (TimeInterval) -> Int) async {
        var s = from + 1
        while s <= to {
            now = at(s)
            rig.source.send(bpm(s), at: now)
            await rig.recorder.tick(now: now)
            s += 1
        }
    }

    /// A 10-minute run peaking at 170 bpm (zone 5 for a 40-year-old, under any bound source), ended at +600.
    private func runAndEnd(_ rig: Rig) async {
        rig.recorder.start()
        await stream(rig, from: 0, to: 600) { $0 > 540 ? 170 : 150 }
        await rig.recorder.end()
    }

    /// Recovery readings falling 1 bpm every 2 s from 160, for `(from, to]` seconds after an end at +600.
    private func recover(_ rig: Rig, from: TimeInterval = 0, to: TimeInterval) async {
        await stream(rig, from: 600 + from, to: 600 + to) { 160 - Int(($0 - 600) / 2) }
    }

    private func finishedSummary(_ recorder: StrapWorkoutRecorder) -> (StrapWorkoutSummary, Bool)? {
        if case .finished(let summary, let saved) = recorder.state { return (summary, saved) }
        return nil
    }

    // MARK: 82a — End is unchanged

    func testEndSavesAtOnceTheSameWorkoutMasterWouldHave() async {
        let master = makeRig(window: false)
        await runAndEnd(master)
        let rig = makeRig()
        now = t0
        await runAndEnd(rig)

        XCTAssertEqual(rig.health.writes.count, 1, "saved at End, not after the window")
        XCTAssertTrue(rig.recorder.isMeasuringRecovery, "the window is still open")
        let a = master.health.writes[0], b = rig.health.writes[0]
        XCTAssertEqual(b.summary, a.summary)
        XCTAssertEqual(b.samples, a.samples)
        XCTAssertEqual(b.timeline, a.timeline)
        XCTAssertEqual(b.route.count, a.route.count)
        XCTAssertEqual(b.summary.summary.endDate, at(600), "today's end time: the End tap")
        XCTAssertEqual(master.journal.landing, rig.journal.landing, "the workout's readings queued the same way")
    }

    // MARK: 82b — the window

    func testTheStreamKeepsRunningThroughTheWindowAndTheHoldLasts() async {
        let rig = makeRig()
        await runAndEnd(rig)
        XCTAssertEqual(rig.source.stops, 0, "the stream is not stopped at End")
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink)
        await recover(rig, to: 119)
        XCTAssertTrue(rig.recorder.isMeasuringRecovery)
        XCTAssertEqual(rig.recorder.currentHR, 160 - 59, "the live reading is shown in the window")
        XCTAssertEqual(rig.recorder.recoveryMarkAt, at(720))
        XCTAssertEqual(rig.source.stops, 0)

        await recover(rig, from: 119, to: 120)   // the +120 s reading
        XCTAssertNotNil(finishedSummary(rig.recorder))
        XCTAssertEqual(rig.recorder.recoveryClosedBy, .complete)
        XCTAssertEqual(rig.source.stops, 1, "stopped once, when the window closed")
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink)
        XCTAssertNil(rig.recorder.recoveryMarkAt)
    }

    func testWithoutTheTwoMinuteReadingTheWindowClosesTenSecondsLater() async {
        let rig = makeRig()
        await runAndEnd(rig)
        await recover(rig, to: 100)
        for s in stride(from: 701.0, through: 729, by: 1) {   // no readings: the strap went quiet
            now = at(s)
            await rig.recorder.tick(now: now)
        }
        XCTAssertTrue(rig.recorder.isMeasuringRecovery, "up to 10 s to catch the +120 s reading")
        now = at(730)
        await rig.recorder.tick(now: now)
        XCTAssertNotNil(finishedSummary(rig.recorder))
        XCTAssertEqual(rig.recorder.recoveryClosedBy, .complete)
        XCTAssertEqual(rig.recorder.heartRateRecovery?.twoMinutes, .notMeasured(.noReadingNearMark))
    }

    func testSkipEndsTheWindowWithTheReadingsSoFar() async throws {
        let rig = makeRig()
        await runAndEnd(rig)
        await recover(rig, to: 90)
        rig.recorder.skipRecovery()
        XCTAssertNotNil(finishedSummary(rig.recorder))
        XCTAssertEqual(rig.recorder.recoveryClosedBy, .skipped)
        XCTAssertEqual(rig.source.stops, 1)
        XCTAssertEqual(rig.recorder.heartRateRecovery?.oneMinute.drop, 170 - (160 - 30))
        XCTAssertEqual(rig.recorder.heartRateRecovery?.twoMinutes, .notMeasured(.noReadingNearMark))
        // A reading that arrives after the window closed is not kept.
        rig.source.send(100, at: at(700))
        await rig.recorder.recoveryWriteTask?.value
        XCTAssertEqual(try XCTUnwrap(rig.recovery?.readingWrites.first).count, 90)
    }

    func testANewWorkoutEndsTheWindowAndTakesTheHeldBackSync() async {
        let rig = makeRig()
        await runAndEnd(rig)
        await recover(rig, to: 30)
        rig.recorder.endRecoveryForNewWorkout()
        XCTAssertEqual(rig.recorder.recoveryClosedBy, .newWorkout)
        XCTAssertEqual(rig.source.syncRequests, 0, "the new workout holds the strap; its End runs the sync")
        rig.recorder.reset()
        XCTAssertEqual(rig.recorder.state, .idle)
        rig.recorder.start()
        XCTAssertTrue(rig.recorder.isRecording)
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink)
        XCTAssertNil(rig.recorder.heartRateRecovery, "the new workout starts clean")
        rig.recorder.cancel()
        XCTAssertEqual(rig.source.syncRequests, 1, "and the sync runs once that one ends")
    }

    func testANewWorkoutCannotEndTheWindowWhileTheWorkoutIsStillBeingSaved() async {
        let rig = makeRig()
        rig.recorder.start()
        await stream(rig, from: 0, to: 60) { _ in 150 }
        // Not reachable from the UI (`.finishing` isn't startable); the call must be a no-op anyway.
        rig.recorder.endRecoveryForNewWorkout()
        XCTAssertTrue(rig.recorder.isRecording)
        rig.recorder.cancel()
    }

    func testALinkDropEndsTheWindow() async {
        let rig = makeRig()
        await runAndEnd(rig)
        await recover(rig, to: 70)
        rig.source.isLinkConnected = false
        now = at(671)
        await rig.recorder.tick(now: now)
        XCTAssertNotNil(finishedSummary(rig.recorder))
        XCTAssertEqual(rig.recorder.recoveryClosedBy, .linkLost)
        XCTAssertEqual(rig.recorder.heartRateRecovery?.oneMinute.drop, 170 - (160 - 30))
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink)
    }

    func testEndedWithTheLinkDownHasNoWindowAndSyncsAtOnce() async {
        let rig = makeRig()
        rig.recorder.start()
        await stream(rig, from: 0, to: 300) { _ in 170 }
        rig.source.isLinkConnected = false
        now = at(301)
        await rig.recorder.tick(now: now)
        XCTAssertTrue(rig.recorder.linkDown)
        rig.source.isLinkConnected = true
        rig.source.ready = true
        await rig.recorder.end()
        XCTAssertNotNil(finishedSummary(rig.recorder), "straight to the result")
        XCTAssertEqual(rig.recorder.recoveryClosedBy, .linkLost)
        XCTAssertEqual(rig.source.syncRequests, 1)
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink)
    }

    func testAWorkoutEndedWhilePausedMeasuresFromWhereItStoppedRunning() async {
        let rig = makeRig()
        rig.recorder.start()
        await stream(rig, from: 0, to: 600) { _ in 170 }
        rig.recorder.pause()
        // The strap keeps streaming through the pause; End comes 90 s later.
        await stream(rig, from: 600, to: 690) { 160 - Int(($0 - 600) / 2) }
        await rig.recorder.end()
        XCTAssertEqual(rig.health.writes.first?.summary.summary.endDate, at(600))
        XCTAssertTrue(rig.recorder.isMeasuringRecovery, "30 s of the window are still to come")
        await stream(rig, from: 690, to: 720) { 160 - Int(($0 - 600) / 2) }
        XCTAssertEqual(rig.recorder.heartRateRecovery?.oneMinute.drop, 170 - (160 - 30), "the pause's reading at +60 s")
        XCTAssertEqual(rig.recorder.heartRateRecovery?.twoMinutes.drop, 170 - (160 - 60))
    }

    // MARK: 82g — the held-back sync

    func testTheHeldBackSyncRunsOnceAfterTheWindowNotAtEnd() async {
        let rig = makeRig()
        await runAndEnd(rig)
        XCTAssertEqual(rig.source.syncRequests, 0, "not at End")
        await recover(rig, to: 120)
        XCTAssertEqual(rig.source.syncRequests, 1, "once the window closed")
        await rig.recorder.recoveryWriteTask?.value
        XCTAssertEqual(rig.source.syncRequests, 1)
        XCTAssertEqual(rig.log.events.filter { $0 == "sync" }.count, 1)
        XCTAssertLessThan(rig.log.events.firstIndex(of: "stream stopped")!, rig.log.events.firstIndex(of: "sync")!)
    }

    func testWithoutARecoveryWriterEndIsMastersEndExactly() async {
        let rig = makeRig(window: false)
        await runAndEnd(rig)
        XCTAssertNotNil(finishedSummary(rig.recorder))
        XCTAssertEqual(rig.source.stops, 1)
        XCTAssertEqual(rig.source.syncRequests, 1)
        XCTAssertNil(rig.recorder.heartRateRecovery)
        XCTAssertNil(rig.recorder.recoveryMarkAt)
    }

    // MARK: 82c — the readings

    func testRecoveryReadingsAreWrittenAfterTheWorkoutAndNeverInsideIt() async throws {
        let rig = makeRig()
        await runAndEnd(rig)
        rig.source.send(150, at: at(600.5))   // spans 599.5 … 600.5: partly inside the workout
        await recover(rig, to: 120)
        await rig.recorder.recoveryWriteTask?.value
        let readings = try XCTUnwrap(rig.recovery?.readingWrites.first)
        XCTAssertEqual(rig.recovery?.readingWrites.count, 1)
        XCTAssertEqual(readings.count, 120, "+1 … +120, each over the second before it: the first starts at the end")
        XCTAssertTrue(readings.allSatisfy { $0.start >= at(600) && $0.end <= at(730) })
        XCTAssertTrue(rig.health.writes[0].samples.allSatisfy { $0.end <= at(600) }, "none in the HKWorkout")
        let saved = rig.log.events.firstIndex(of: "workout saved")!
        let recovered = rig.log.events.firstIndex(of: "recovery readings saved")!
        XCTAssertLessThan(saved, recovered)
        // Stored through the landing queue (no watermark moves, `insertWorkoutHeartRate`), on their own.
        XCTAssertEqual(rig.store.batches.last, readings)
        XCTAssertTrue(rig.journal.landing.isEmpty, "nothing left queued")
        XCTAssertEqual(rig.windows.window(endingWorkoutAt: at(600)), DateInterval(start: at(600), end: at(720)))
    }

    // MARK: 82e — Cardio Recovery

    func testCardioRecoveryIsWrittenOnceWithHRR1AtOneMinuteAfterTheEnd() async throws {
        let rig = makeRig()
        await runAndEnd(rig)
        await recover(rig, to: 120)
        await rig.recorder.recoveryWriteTask?.value
        let cardio = try XCTUnwrap(rig.recovery?.cardioWrites)
        XCTAssertEqual(cardio.count, 1)
        XCTAssertEqual(cardio.first?.bpm, 170 - 130)
        XCTAssertEqual(cardio.first?.at, at(660))
        XCTAssertEqual(cardio.first?.timeline, timeline)
        XCTAssertEqual(rig.recorder.heartRateRecovery?.twoMinutes.drop, 170 - 100)
        XCTAssertEqual(rig.recorder.recoveryHealthStatus?.cardioRecovery, .saved)
    }

    func testAFailedCardioRecoveryWriteLeavesTheWorkoutSaved() async throws {
        let rig = makeRig()
        rig.recovery?.cardioStatus = .failed
        rig.recovery?.readingsStatus = .failed
        await runAndEnd(rig)
        await recover(rig, to: 120)
        await rig.recorder.recoveryWriteTask?.value
        let (_, saved) = try XCTUnwrap(finishedSummary(rig.recorder))
        XCTAssertTrue(saved, "the workout is in Health")
        XCTAssertEqual(rig.health.writes.count, 1, "and was never written again")
        XCTAssertEqual(rig.recorder.recoveryHealthStatus?.cardioRecovery, .failed)
        XCTAssertEqual(rig.recorder.recoveryHealthStatus?.readings, .failed)
        XCTAssertEqual(rig.store.batches.last?.count, 120, "the readings are still stored")
        XCTAssertEqual(rig.source.syncRequests, 1, "and the held-back sync still runs")
    }

    func testNoCardioRecoveryBelowZoneFour() async {
        let rig = makeRig()
        rig.recorder.start()
        await stream(rig, from: 0, to: 600) { _ in 110 }
        await rig.recorder.end()
        await recover(rig, to: 120)
        await rig.recorder.recoveryWriteTask?.value
        guard case .notMeasured(.peakBelowZoneFour(let peak, _))? = rig.recorder.heartRateRecovery?.oneMinute else {
            return XCTFail("measured below zone 4")
        }
        XCTAssertEqual(peak, 110)
        XCTAssertEqual(rig.recovery?.cardioWrites.count, 0)
        XCTAssertEqual(rig.recovery?.readingWrites.count, 1, "the readings themselves still go to Health")
    }

    func testNoCardioRecoveryForAWorkoutHealthRefused() async {
        let rig = makeRig()
        rig.health.accept = false
        await runAndEnd(rig)
        await recover(rig, to: 120)
        await rig.recorder.recoveryWriteTask?.value
        XCTAssertEqual(rig.recorder.heartRateRecovery?.oneMinute.drop, 40, "still shown")
        XCTAssertEqual(rig.recovery?.cardioWrites.count, 0)
    }
}

// MARK: - The window's readings in LocalStore

@MainActor
final class StrapWorkoutRecoveryStoreTests: XCTestCase {
    private var now = t0
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-HRR-STORE")
    private var windowsSuite = "strap-hrr-store-windows-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
        StrapWorkoutHealthExclusions().clear(device: timeline)
    }

    override func tearDown() {
        StrapWorkoutHealthExclusions().clear(device: timeline)
        UserDefaults().removePersistentDomain(forName: windowsSuite)
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

    /// The strap synced an hour of history before the workout and its Health flush hasn't run (the
    /// undrained backlog). After a workout and its recovery window, neither watermark moved: the backlog
    /// is still offered to Health, the workout's and the window's readings are not, and the strap's own
    /// history for the same minutes still goes in.
    func testNoWatermarkMovesAheadOfAnUndrainedBacklog() async throws {
        let store = try makeStore()
        let backlog = (1...60).map { QuantitySample(kind: .heartRate, start: at(Double(-60 * $0)), value: 70) }
        _ = try store.ingest(backlog, device: timeline)
        let ingestMark = try store.loadCursor(device: timeline).last(.heartRate)

        let source = RecoverySource(timeline: timeline)
        let recovery = RecoveryHealth()
        let recorder = StrapWorkoutRecorder(
            source: { source }, health: WorkoutHealth(), journal: RecoveryJournal(), hrStore: { store },
            location: StillLocation(), liveActivity: nil,
            profile: { UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male) }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-hrr-orphan-\(UUID().uuidString)")!),
            recoveryHealth: recovery, recoveryWindows: WorkoutRecoveryWindows(UserDefaults(suiteName: windowsSuite)!),
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = .runningIndoor
        recorder.start()
        for s in stride(from: 1.0, through: 720, by: 1) {
            now = at(s)
            source.send(s <= 600 ? 170 : 140, at: now)
            await recorder.tick(now: now)
            if s == 600 { await recorder.end() }
        }
        await recorder.recoveryWriteTask?.value
        XCTAssertFalse(recorder.isMeasuringRecovery)

        XCTAssertEqual(try store.loadCursor(device: timeline).last(.heartRate), ingestMark, "the ingest watermark is untouched")
        let rows = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertEqual(rows.filter { $0.start >= at(600) }.count, 120, "the recovery readings are stored")
        let pending = try store.pendingHealthSamples(device: timeline, kinds: [.heartRate])
        XCTAssertEqual(pending.count, 60, "the whole backlog is still offered, and nothing of the workout or window")
        XCTAssertTrue(pending.allSatisfy { $0.start < at(0) })

        // The history sync after the window brings the strap's own instants for those minutes.
        _ = try store.ingest([QuantitySample(kind: .heartRate, start: at(630), value: 141)], device: timeline)
        XCTAssertEqual(try store.pendingHealthSamples(device: timeline, kinds: [.heartRate]).map(\.start).last, at(630))
    }
}

// MARK: - The workout detail and the words

@MainActor
final class HeartRateRecoveryPresentationTests: XCTestCase {
    private func reading(_ bpm: Int, _ s: TimeInterval) -> HRSample { HRSample(bpm: bpm, start: at(s - 1), end: at(s)) }

    func testTheDetailUsesOnlyStoredReadingsInsideTheWorkoutsWindow() throws {
        let workout = (1...600).map { reading($0 > 540 ? 170 : 150, Double($0)) }
        let window = DateInterval(start: at(600), end: at(690))   // skipped at +90 s
        let rows = [reading(130, 661),
                    HRSample(bpm: 90, start: at(660)),             // an all-day history instant, right on the mark
                    reading(150, 720)]                             // the next workout's first reading
        let outcome = try XCTUnwrap(WorkoutDetailContent.recovery(workoutHR: workout, storedRows: rows,
                                                                  window: window, age: 40))
        XCTAssertEqual(outcome.oneMinute.drop, 40)
        XCTAssertEqual(outcome.twoMinutes, .notMeasured(.noReadingNearMark), "the next workout's reading is not recovery")
    }

    func testNoWindowNoRow() {
        XCTAssertNil(WorkoutDetailContent.recovery(workoutHR: [reading(170, 10)], storedRows: [reading(130, 70)],
                                                   window: nil, age: 40))
    }

    func testTheRowSitsBeforeTheDevice() {
        let outcome = HeartRateRecovery.Outcome(peak: 170, oneMinute: .measured(drop: 22, reading: 148, at: at(60)),
                                                twoMinutes: .measured(drop: 41, reading: 129, at: at(120)))
        let item = WorkoutHistoryReader.Item(id: UUID(), activityType: .running, start: at(-600), end: at(0),
                                             activeKcal: nil, distanceMeters: nil, avgHR: nil)
        let rows = WorkoutDetailContent.rows(item, hr: [], age: 40, unit: .metric, recordedWith: "Helio Strap",
                                             recovery: outcome)
        XCTAssertEqual(rows.suffix(2).map(\.title), ["Heart rate recovery", "Recorded with"])
        XCTAssertEqual(rows.first { $0.title == "Heart rate recovery" }?.value, "1 min -22 bpm, 2 min -41 bpm")
        let without = WorkoutDetailContent.rows(item, hr: [], age: 40, unit: .metric, recordedWith: "Helio Strap")
        XCTAssertFalse(without.contains { $0.title == "Heart rate recovery" })
    }

    func testTheWords() {
        let both = HeartRateRecovery.Outcome(peak: 170, oneMinute: .measured(drop: 22, reading: 148, at: at(60)),
                                             twoMinutes: .measured(drop: 41, reading: 129, at: at(120)))
        XCTAssertEqual(HeartRateRecoveryText.headline(both), "Heart rate recovery: 1 min -22 bpm, 2 min -41 bpm")
        XCTAssertEqual(HeartRateRecoveryText.reasons(both), [])

        let skipped = HeartRateRecovery.Outcome(peak: 170, oneMinute: .measured(drop: 22, reading: 148, at: at(60)),
                                                twoMinutes: .notMeasured(.noReadingNearMark))
        XCTAssertEqual(HeartRateRecoveryText.headline(skipped), "Heart rate recovery: 1 min -22 bpm, 2 min not measured")
        XCTAssertEqual(HeartRateRecoveryText.reasons(skipped, closedBy: .skipped),
                       ["2 min not measured: no heart-rate reading within 10 seconds of 2 minutes after End (recording was skipped)."])

        let easy = HeartRateRecovery.Outcome(peak: 120, oneMinute: .notMeasured(.peakBelowZoneFour(peak: 120, zoneFourLowerBound: 146)),
                                             twoMinutes: .notMeasured(.peakBelowZoneFour(peak: 120, zoneFourLowerBound: 146)))
        XCTAssertEqual(HeartRateRecoveryText.headline(easy), "Heart rate recovery: not measured")
        XCTAssertEqual(HeartRateRecoveryText.reasons(easy).count, 1)
        XCTAssertTrue(HeartRateRecoveryText.reasons(easy)[0].contains("peaked at 120 bpm, below zone 4 (from 146 bpm)"))

        let rose = HeartRateRecovery.Outcome(peak: 150, oneMinute: .measured(drop: -4, reading: 154, at: at(60)),
                                             twoMinutes: .measured(drop: 10, reading: 140, at: at(120)))
        XCTAssertEqual(HeartRateRecoveryText.values(rose), "1 min heart rate rose, 2 min -10 bpm")
    }

    func testCardioRecoveryIsInTheOneShareSetAndNamed() {
        let type = HKQuantityType(.heartRateRecoveryOneMinute)
        XCTAssertTrue(HealthKitWriter().allTypes.contains(type))
        XCTAssertTrue(HeartRateRecoveryHealthWriter.cardioRecoveryType.isEqual(type))
        XCTAssertEqual(HealthKitWriter.friendlyName(for: type), "Cardio Recovery")
    }
}
