import CoreLocation
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// The strap's workout (#227): the recorder against a fake live-HR source, a fake Health writer and
// an in-memory journal, plus the HelioSession half against the simulated strap. Every key, reading
// and time is synthetic.

private let t0 = Date(timeIntervalSince1970: 1_789_862_400 + 10 * 3600)   // 2026-09-20T10:00:00Z
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// MARK: - Fakes

@MainActor
private final class FakeHRSource: StrapWorkoutHeartRateSource {
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
    private(set) var orphanStops = 0
    /// The persisted flag the recorder sets (`StrapWorkoutOrphanStop`), as `HelioSession` reads it.
    var owedStop: StrapWorkoutOrphanStop?

    init(timeline: SyncDeviceID = .timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-A")) {
        self.timeline = timeline
    }

    func startWorkoutHeartRate() { starts += 1 }
    func stopWorkoutHeartRate() { stops += 1 }
    func sendOwedOrphanStop() {
        guard let owedStop, owedStop.owed else { return }
        orphanStops += 1
        owedStop.owed = false
    }
    func syncHistory(manual: Bool) { syncRequests += 1 }

    /// The strap sends one reading.
    func send(_ bpm: Int, at date: Date) { heartRateObserver?(bpm, date) }
}

@MainActor
private final class FakeHealthWriter: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    var accept = true
    /// Runs inside the save, where the real `HKWorkoutBuilder` round trip takes its seconds.
    var duringSave: (@MainActor () async -> Void)?
    func save(_ write: StrapWorkoutWrite) async -> Bool {
        writes.append(write)
        await duringSave?()
        return accept
    }
}

@MainActor
private final class MemoryJournal: StrapWorkoutJournalStoring {
    var journal: StrapWorkoutJournal?
    var samples: [HRSample] = []
    var landing: [StrapWorkoutLandingBatch] = []
    func loadJournal() -> StrapWorkoutJournal? { journal }
    func saveJournal(_ journal: StrapWorkoutJournal) { self.journal = journal }
    func appendSamples(_ samples: [HRSample]) { self.samples += samples }
    func loadSamples() -> [HRSample] { samples }
    var parked: [StrapWorkoutParked] = []
    func clearRunning() { journal = nil; samples = [] }
    func parkRunning() {
        if let journal { parked.append(StrapWorkoutParked(journal: journal, samples: samples)) }
        clearRunning()
    }
    func loadParked() -> [StrapWorkoutParked] { parked }
    func saveParked(_ parked: [StrapWorkoutParked]) { self.parked = parked }
    func loadLanding() -> [StrapWorkoutLandingBatch] { landing }
    func saveLanding(_ batches: [StrapWorkoutLandingBatch]) { landing = batches }
}

@MainActor
private final class FakeLocation: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    private(set) var started: [Bool] = []
    private(set) var pausedCalls: [Bool] = []
    private(set) var stopped = 0
    func start(route: Bool) { started.append(route); gpsActive = true }
    func setPaused(_ paused: Bool) { pausedCalls.append(paused) }
    func stop() { stopped += 1; gpsActive = false }
}

@MainActor
private final class FakeHRStore: StrapWorkoutHRStore {
    private(set) var inserted: [HRSample] = []
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws { inserted += samples }
}

@MainActor
private final class FakeVO2: StrapVO2MaxProviding {
    var age: Int? = 40
    var resting: Double? = 60
    var status: VO2MaxHealthWriter.Status = .saved
    private(set) var saves: [(estimate: VO2MaxEstimate.Estimate, end: Date, timeline: SyncDeviceID)] = []
    func userSetAge() -> Int? { age }
    func restingHR(workoutStart: Date, workoutEnd: Date) -> Double? { resting }
    func save(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date,
              timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status {
        saves.append((estimate, workoutEnd, timeline))
        return status
    }
}

// MARK: - Recorder tests

@MainActor
final class StrapWorkoutRecorderTests: XCTestCase {
    private var now = t0
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male)   // max HR 180
    /// The owed-stop flag in a defaults suite of this test's own.
    private let orphanStop = StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!)

    private func makeSource(_ timeline: SyncDeviceID? = nil) -> FakeHRSource {
        let source = timeline.map { FakeHRSource(timeline: $0) } ?? FakeHRSource()
        source.owedStop = orphanStop
        return source
    }

    private struct Rig {
        let recorder: StrapWorkoutRecorder
        let health: FakeHealthWriter
        let journal: MemoryJournal
        let location: FakeLocation
        let store: FakeHRStore
    }

    /// Deleted workouts (#293), in a defaults suite of this test's own.
    private let tombstones = WorkoutTombstones(UserDefaults(suiteName: "strap-workout-tombstones-\(UUID().uuidString)")!)

    private func makeRig(source: @escaping @MainActor () -> (any StrapWorkoutHeartRateSource)?,
                         journal: MemoryJournal? = nil, store: FakeHRStore? = nil,
                         vo2: FakeVO2? = nil) -> Rig {
        let journal = journal ?? MemoryJournal()
        let store = store ?? FakeHRStore()
        let health = FakeHealthWriter()
        let location = FakeLocation()
        let profile = self.profile
        let recorder = StrapWorkoutRecorder(source: source, health: health, journal: journal, hrStore: { store },
                                            location: location, liveActivity: nil, profile: { profile },
                                            indoorKeepAlive: { false }, orphanStop: orphanStop, vo2: vo2,
                                            tombstones: tombstones,
                                            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        return Rig(recorder: recorder, health: health, journal: journal, location: location, store: store)
    }

    /// One reading a second from `from` (exclusive) through `to` (inclusive), ticking the recorder
    /// each second as production does.
    private func stream(_ rig: Rig, _ source: FakeHRSource?, from: TimeInterval, to: TimeInterval, bpm: Int) async {
        var s = from + 1
        while s <= to {
            now = at(s)
            source?.send(bpm, at: now)
            await rig.recorder.tick(now: now)
            s += 1
        }
    }

    // MARK: start → pause → resume → end

    func testStartPauseResumeEndWritesOneWorkoutWithTheActiveDurationAndZones() async throws {
        let source = makeSource()
        let rig = makeRig(source: { source })
        rig.recorder.selectedSport = .runningIndoor
        XCTAssertTrue(rig.recorder.canStart(source))
        rig.recorder.start()
        XCTAssertTrue(rig.recorder.isRecording)
        XCTAssertEqual(source.starts, 1, "the workout's stream starts with the workout")
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink, "history syncs wait while it runs")
        XCTAssertEqual(rig.location.started, [], "indoor without the keep-alive opt-in: no location session")

        await stream(rig, source, from: 0, to: 300, bpm: 152)            // 84 % of 180: anaerobic
        rig.recorder.pause()
        XCTAssertTrue(rig.recorder.isPaused)
        await stream(rig, source, from: 300, to: 420, bpm: 100)          // shown, never recorded
        XCTAssertEqual(rig.recorder.currentHR, 100, "the live number keeps showing while paused")
        XCTAssertEqual(rig.recorder.activeSeconds, 300, "the clock stands still while paused")
        rig.recorder.resume()
        await stream(rig, source, from: 420, to: 600, bpm: 152)
        XCTAssertEqual(rig.recorder.activeSeconds, 480)
        XCTAssertEqual(rig.location.pausedCalls, [true, false])

        await rig.recorder.end()

        XCTAssertEqual(rig.health.writes.count, 1, "exactly one HKWorkout write")
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.summary.activeSeconds, 480)
        XCTAssertEqual(write.summary.pauses, [DateInterval(start: at(300), end: at(420))], "Health gets the pause")
        XCTAssertEqual(write.samples.count, 480, "the 120 readings during the pause are not the workout's")
        XCTAssertEqual(write.summary.summary.hrSampleCount, 480)
        XCTAssertEqual(write.summary.summary.avgHR, 152)
        XCTAssertEqual(write.summary.summary.zoneBreakdown.anaerobicSeconds, 480, accuracy: 0.001)
        XCTAssertEqual(write.summary.summary.zoneBreakdown.totalZoneSeconds, 480, accuracy: 0.001)
        XCTAssertEqual(write.timeline, source.timeline, "attributed through the strap's own timeline")
        XCTAssertEqual(write.route.count, 0)
        guard case .finished(let summary, let saved) = rig.recorder.state else { return XCTFail("not finished") }
        XCTAssertTrue(saved)
        XCTAssertEqual(summary, write.summary)

        XCTAssertEqual(source.stops, 1, "End stops the workout's stream")
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink)
        XCTAssertEqual(source.syncRequests, 1, "the sync the workout held back runs at End")
        XCTAssertNil(rig.journal.journal, "nothing left to recover")
        XCTAssertEqual(rig.store.inserted.count, 480, "stored at End (no watermark moves; Health has them already)")
        XCTAssertEqual(rig.journal.landing, [], "nothing left queued")

        rig.recorder.reset()
        XCTAssertEqual(rig.recorder.state, .idle)
    }

    func testEndingWhilePausedEndsWhereItStoppedRunning() async throws {
        let source = makeSource()
        let rig = makeRig(source: { source })
        rig.recorder.selectedSport = .yoga
        rig.recorder.start()
        await stream(rig, source, from: 0, to: 200, bpm: 120)
        rig.recorder.pause()
        await stream(rig, source, from: 200, to: 260, bpm: 90)
        await rig.recorder.end()
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.summary.summary.endDate, at(200))
        XCTAssertEqual(write.summary.activeSeconds, 200)
        XCTAssertEqual(write.summary.pauses, [])
    }

    func testStartWaitsForTheStrapsSyncAndNeedsAStream() {
        let source = makeSource()
        let rig = makeRig(source: { source })
        source.syncing = true
        XCTAssertFalse(rig.recorder.canStart(source), "like the ring's Start, not while a sync holds the link")
        rig.recorder.start()
        XCTAssertEqual(rig.recorder.state, .idle)
        source.syncing = false
        source.canStreamHeartRate = false
        XCTAssertFalse(rig.recorder.canStart(source), "no key, no stream: no workout")
        XCTAssertFalse(rig.recorder.canStart(nil))
    }

    func testCancelWritesNothing() async {
        let source = makeSource()
        let rig = makeRig(source: { source })
        rig.recorder.start()
        await stream(rig, source, from: 0, to: 30, bpm: 120)
        rig.recorder.cancel()
        XCTAssertEqual(rig.health.writes.count, 0)
        XCTAssertEqual(rig.journal.landing, [])
        XCTAssertNil(rig.journal.journal)
        XCTAssertEqual(rig.recorder.state, .idle)
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink)
    }

    func testOutdoorStartsTheRouteAndTheRouteGoesToHealth() async throws {
        let source = makeSource()
        let rig = makeRig(source: { source })
        rig.recorder.selectedSport = .runningOutdoor
        rig.recorder.start()
        XCTAssertEqual(rig.location.started, [true])
        rig.location.route = [CLLocation(latitude: 1, longitude: 1), CLLocation(latitude: 1.001, longitude: 1)]
        rig.location.distanceMeters = 111
        await stream(rig, source, from: 0, to: 60, bpm: 140)
        await rig.recorder.end()
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.route.count, 2)
        XCTAssertTrue(write.summary.summary.hasRoute)
        XCTAssertEqual(write.summary.summary.distanceMeters, 111)
        XCTAssertEqual(rig.location.stopped, 1)
    }

    // MARK: VO₂ max estimate (#232 on the strap)

    /// A fix every 5 s from `t0` through `seconds`, heading north at `metersPerMinute`, no altitude.
    private func steadyRoute(seconds: TimeInterval, metersPerMinute: Double) -> [CLLocation] {
        let metersPerDegree = 111_195.0
        return stride(from: 0.0, through: seconds, by: 5).map { s in
            let north = metersPerMinute * s / 60
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1 + north / metersPerDegree, longitude: 1),
                              altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: at(s))
        }
    }

    /// Lets the estimate's Health write (a detached `Task`) run.
    private func settle(_ rig: Rig) async {
        for _ in 0 ..< 100 where rig.recorder.vo2MaxHealthStatus == nil { await Task.yield() }
    }

    func testASteadyOutdoorRunGetsAVO2MaxEstimateSavedUnderTheStrap() async throws {
        let source = makeSource()
        let vo2 = FakeVO2()
        let rig = makeRig(source: { source }, vo2: vo2)
        rig.recorder.selectedSport = .runningOutdoor
        rig.recorder.start()
        rig.location.route = steadyRoute(seconds: 900, metersPerMinute: 200)
        rig.location.distanceMeters = 3000
        await stream(rig, source, from: 0, to: 900, bpm: 150)
        await rig.recorder.end()
        await settle(rig)

        guard case .estimate(let e)? = rig.recorder.vo2MaxOutcome else {
            return XCTFail("expected an estimate, got \(String(describing: rig.recorder.vo2MaxOutcome))")
        }
        // ACSM: 0.2 × 200 + 3.5 = 43.5; Swain with rest 60, Tanaka max 180 at 40: 3.5 + 40 × 120 / 90 ≈ 56.8.
        XCTAssertEqual(e.vo2Max, 56.8, accuracy: 2.0)
        XCTAssertEqual(e.maxHRSource, .ageFormula)
        XCTAssertEqual(vo2.saves.count, 1, "one Health write")
        XCTAssertEqual(vo2.saves.first?.timeline, source.timeline, "attributed to the strap, not the ring")
        XCTAssertEqual(rig.recorder.vo2MaxHealthStatus, .saved)
        guard case .finished(let summary, _) = rig.recorder.state else { return XCTFail("not finished") }
        XCTAssertEqual(vo2.saves.first?.end, summary.summary.endDate)

        rig.recorder.reset()
        XCTAssertNil(rig.recorder.vo2MaxOutcome)
        XCTAssertNil(rig.recorder.vo2MaxHealthStatus)
    }

    func testRRIntervalsAreCountedFromWhenTheWorkoutAttached() async throws {
        let source = makeSource()
        source.rrIntervalsReceived = 7                                  // before the workout: not counted
        let rig = makeRig(source: { source })
        rig.recorder.selectedSport = .runningIndoor
        rig.recorder.start()
        source.rrIntervalsReceived += 2
        await stream(rig, source, from: 0, to: 1, bpm: 120)
        source.rrIntervalsReceived += 3
        await stream(rig, source, from: 1, to: 2, bpm: 120)
        XCTAssertEqual(rig.recorder.rrIntervalCount, 5)
        await rig.recorder.end()
        rig.recorder.reset()
        XCTAssertEqual(rig.recorder.rrIntervalCount, 0)
    }

    func testAnIndoorRunHasNoVO2MaxEstimate() async throws {
        let source = makeSource()
        let vo2 = FakeVO2()
        let rig = makeRig(source: { source }, vo2: vo2)
        rig.recorder.selectedSport = .runningIndoor
        rig.recorder.start()
        await stream(rig, source, from: 0, to: 900, bpm: 150)
        await rig.recorder.end()
        XCTAssertNil(rig.recorder.vo2MaxOutcome)
        XCTAssertTrue(vo2.saves.isEmpty)
    }

    func testTheTenMinuteRuleIsOnRunningTimeNotWallClock() async throws {
        let source = makeSource()
        let vo2 = FakeVO2()
        let rig = makeRig(source: { source }, vo2: vo2)
        rig.recorder.selectedSport = .runningOutdoor
        rig.recorder.start()
        rig.location.route = steadyRoute(seconds: 900, metersPerMinute: 200)
        await stream(rig, source, from: 0, to: 240, bpm: 150)
        rig.recorder.pause()
        await stream(rig, source, from: 240, to: 660, bpm: 100)          // 7 min paused
        rig.recorder.resume()
        await stream(rig, source, from: 660, to: 900, bpm: 150)          // 8 min running in all
        await rig.recorder.end()
        XCTAssertEqual(rig.recorder.vo2MaxOutcome, .skipped(.tooShort))
        XCTAssertTrue(vo2.saves.isEmpty)
    }

    func testNoAgeSaysSoAndWritesNothing() async throws {
        let source = makeSource()
        let vo2 = FakeVO2()
        vo2.age = nil
        let rig = makeRig(source: { source }, vo2: vo2)
        rig.recorder.selectedSport = .runningOutdoor
        rig.recorder.start()
        rig.location.route = steadyRoute(seconds: 900, metersPerMinute: 200)
        await stream(rig, source, from: 0, to: 900, bpm: 150)
        await rig.recorder.end()
        XCTAssertEqual(rig.recorder.vo2MaxOutcome, .skipped(.noAge))
        XCTAssertTrue(vo2.saves.isEmpty)
    }

    func testAWorkoutHealthRejectedNeverWritesItsEstimate() async throws {
        let source = makeSource()
        let vo2 = FakeVO2()
        let rig = makeRig(source: { source }, vo2: vo2)
        rig.health.accept = false
        rig.recorder.selectedSport = .runningOutdoor
        rig.recorder.start()
        rig.location.route = steadyRoute(seconds: 900, metersPerMinute: 200)
        await stream(rig, source, from: 0, to: 900, bpm: 150)
        await rig.recorder.end()
        guard case .estimate? = rig.recorder.vo2MaxOutcome else { return XCTFail("still shown on the summary") }
        XCTAssertEqual(rig.recorder.vo2MaxHealthStatus, .failed)
        XCTAssertTrue(vo2.saves.isEmpty)
    }

    // MARK: The app is killed

    func testAWorkoutInterruptedByAKillIsOfferedBackAndClosesAtItsLastReading() async throws {
        let journal = MemoryJournal()
        let source = makeSource()
        do {
            let first = makeRig(source: { source }, journal: journal)
            first.recorder.selectedSport = .runningIndoor
            first.recorder.start()
            await stream(first, source, from: 0, to: 905, bpm: 140)
            // Readings are journaled every tick; the heartbeat last re-stamped at 900 s. Then the
            // process dies: nothing else runs.
            XCTAssertEqual(journal.journal?.lastAliveAt, at(900))
            XCTAssertEqual(journal.samples.count, 905)
        }
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "a dead process holds nothing")

        now = at(4000)   // relaunch, an hour later
        let second = makeRig(source: { source }, journal: journal)
        second.recorder.resolveOrphan()
        let recovered = try XCTUnwrap(second.recorder.recoverable)
        XCTAssertEqual(recovered.end, at(905), "its last journaled reading, never stretched to now")
        XCTAssertEqual(recovered.activeSeconds, 905)
        XCTAssertEqual(recovered.samples.count, 905)

        let saved = await second.recorder.saveRecovered()
        XCTAssertTrue(saved)
        XCTAssertEqual(second.health.writes.count, 1)
        let write = try XCTUnwrap(second.health.writes.first)
        XCTAssertEqual(write.summary.activeSeconds, 905)
        XCTAssertEqual(write.samples.count, 905)
        XCTAssertEqual(write.summary.summary.zoneBreakdown.totalZoneSeconds, 905, accuracy: 0.001)
        XCTAssertNil(journal.journal, "a second launch can't offer (and write) it twice")
        XCTAssertEqual(source.orphanStops, 1, "the strap is ready at the launch: the owed 04 00 goes out at once")
        XCTAssertFalse(orphanStop.owed)
        XCTAssertEqual(second.store.inserted.count, 905, "its readings are stored too")
        XCTAssertNil(second.recorder.recoverable)

        let third = makeRig(source: { source }, journal: journal)
        third.recorder.resolveOrphan()
        XCTAssertNil(third.recorder.recoverable)
    }

    /// #293: an interrupted workout over a stretch the user deleted from the history is dropped, never
    /// offered back (the running journal and a parked one alike).
    func testAnInterruptedWorkoutOverADeletedWorkoutIsNotOfferedBack() async throws {
        let journal = MemoryJournal()
        let source = makeSource()
        do {
            let first = makeRig(source: { source }, journal: journal)
            first.recorder.start()
            await stream(first, source, from: 0, to: 120, bpm: 140)
        }
        now = at(4000)
        let probe = makeRig(source: { source }, journal: journal)
        probe.recorder.resolveOrphan()
        let offered = try XCTUnwrap(probe.recorder.recoverable, "offered before the delete")
        probe.recorder.postponeRecovered()
        let interrupted = try XCTUnwrap(journal.journal)

        tombstones.record(start: offered.ledger.start, end: offered.end)
        let relaunch = makeRig(source: { source }, journal: journal)
        relaunch.recorder.resolveOrphan()
        XCTAssertNil(relaunch.recorder.recoverable)
        XCTAssertNil(journal.journal, "the running journal is dropped")
        XCTAssertEqual(relaunch.health.writes.count, 0)

        // The same, parked aside by a later workout's start.
        journal.parked = [StrapWorkoutParked(journal: interrupted, samples: offered.samples)]
        let again = makeRig(source: { source }, journal: journal)
        again.recorder.resolveOrphan()
        XCTAssertNil(again.recorder.recoverable)
        XCTAssertTrue(journal.parked.isEmpty, "a parked one is dropped too")
    }

    func testDiscardAndNotNow() async throws {
        let journal = MemoryJournal()
        let source = makeSource()
        do {
            let first = makeRig(source: { source }, journal: journal)
            first.recorder.start()
            await stream(first, source, from: 0, to: 20, bpm: 140)
        }
        let second = makeRig(source: { source }, journal: journal)
        second.recorder.resolveOrphan()
        XCTAssertNotNil(second.recorder.recoverable)
        second.recorder.postponeRecovered()
        XCTAssertNotNil(journal.journal, "Not now: asked again next launch")
        second.recorder.resolveOrphan()
        second.recorder.discardRecovered()
        XCTAssertNil(journal.journal)
        XCTAssertEqual(source.orphanStops, 2, "each look at the journal owes one stop; the ready strap gets each at once")
        XCTAssertFalse(orphanStop.owed)
        XCTAssertEqual(second.health.writes.count, 0)
    }

    /// Review-238 SF2: Save, Discard, Not now and a refused journal all leave the stop owed when no
    /// strap is connected at the launch (the session sends it at its own `ready`; see the session test).
    func testTheOrphanStopStaysOwedWhenNoStrapIsConnected() async throws {
        let journal = MemoryJournal()
        let source = makeSource()
        do {
            let first = makeRig(source: { source }, journal: journal)
            first.recorder.start()
            await stream(first, source, from: 0, to: 20, bpm: 140)
        }
        now = at(3600)
        let launch = makeRig(source: { nil }, journal: journal)
        launch.recorder.resolveOrphan()
        XCTAssertTrue(orphanStop.owed)
        launch.recorder.postponeRecovered()
        XCTAssertTrue(orphanStop.owed, "Not now")
        orphanStop.owed = false
        launch.recorder.resolveOrphan()
        _ = await launch.recorder.saveRecovered()
        XCTAssertTrue(orphanStop.owed, "Save")
        XCTAssertEqual(source.orphanStops, 0, "nothing reached a strap that isn't connected")

        // A journal with no observed span is refused (dropped silently): its stream is still owed a stop.
        orphanStop.owed = false
        journal.journal = StrapWorkoutJournal(sport: .yoga, ledger: WorkoutActivityLedger(start: at(4000)),
                                              lastAliveAt: at(4000), timelineRaw: source.timeline.rawValue)
        launch.recorder.resolveOrphan()
        XCTAssertNil(launch.recorder.recoverable)
        XCTAssertNil(journal.journal)
        XCTAssertTrue(orphanStop.owed, "a refused journal")
    }

    /// Review-238 N1 (its probe, ported): "Not now" promises the next launch asks again. A new workout
    /// started in between sets the interrupted one aside instead of deleting it.
    func testNotNowThenANewWorkoutKeepsTheInterruptedOne() async throws {
        let journal = MemoryJournal()
        let source = makeSource()
        do {
            let dead = makeRig(source: { source }, journal: journal)
            dead.recorder.selectedSport = .runningIndoor
            dead.recorder.start()
            await stream(dead, source, from: 0, to: 30, bpm: 140)
        }
        now = at(3600)
        let next = makeRig(source: { source }, journal: journal)
        next.recorder.resolveOrphan()
        XCTAssertNotNil(next.recorder.recoverable)
        next.recorder.postponeRecovered()                     // "Not now"
        next.recorder.start()                                  // a new workout, the same launch
        await stream(next, source, from: 3600, to: 3620, bpm: 120)
        await next.recorder.end()
        XCTAssertEqual(next.health.writes.count, 1)

        let relaunch = makeRig(source: { source }, journal: journal)
        relaunch.recorder.resolveOrphan()
        let recovered = try XCTUnwrap(relaunch.recorder.recoverable, "the postponed interrupted workout is still there")
        XCTAssertEqual(recovered.end, at(30))
        XCTAssertEqual(recovered.samples.count, 30)
        _ = await relaunch.recorder.saveRecovered()
        XCTAssertEqual(relaunch.health.writes.count, 1)
        XCTAssertEqual(journal.parked, [], "saved once, then gone")
        let after = makeRig(source: { source }, journal: journal)
        after.recorder.resolveOrphan()
        XCTAssertNil(after.recorder.recoverable)
    }

    // MARK: The link drops mid-workout

    func testALinkDropKeepsTheWorkoutRunningMarksTheGapAndAdoptsTheReconnectedStrap() async throws {
        let first = makeSource()
        var current: FakeHRSource? = first
        let rig = makeRig(source: { current })
        rig.recorder.selectedSport = .runningIndoor
        rig.recorder.start()
        await stream(rig, first, from: 0, to: 200, bpm: 152)

        // The link drops: HelioConnection drops the session and keeps a standing connect.
        first.isLinkConnected = false
        current = nil
        await stream(rig, nil, from: 200, to: 260, bpm: 0)
        XCTAssertTrue(rig.recorder.isRecording, "the workout keeps running")
        XCTAssertTrue(rig.recorder.linkDown)
        XCTAssertEqual(rig.recorder.activeSeconds, 260)

        // It reconnects: a new session, set up but not yet ready, then ready.
        let second = makeSource()
        second.ready = false
        current = second
        await stream(rig, nil, from: 260, to: 300, bpm: 0)
        XCTAssertEqual(second.starts, 0, "not before the new session is ready")
        second.ready = true
        now = at(301)
        await rig.recorder.tick(now: now)
        XCTAssertEqual(second.starts, 1, "the reconnected strap's stream is started again")
        XCTAssertFalse(rig.recorder.linkDown)
        first.send(99, at: at(301))   // the old session is detached: ignored
        await stream(rig, second, from: 301, to: 600, bpm: 152)

        await rig.recorder.end()
        XCTAssertEqual(rig.health.writes.count, 1)
        let write = try XCTUnwrap(rig.health.writes.first)
        XCTAssertEqual(write.summary.activeSeconds, 600, "a gap is not a pause")
        XCTAssertEqual(write.summary.gaps, [DateInterval(start: at(201), end: at(301))], "the gap is marked")
        XCTAssertEqual(write.samples.count, 200 + 299)
        XCTAssertFalse(write.samples.contains { $0.bpm == 99 })
        // 199 one-second holds + the last pre-drop reading held to the 30 s cap; 299 after.
        XCTAssertEqual(write.summary.summary.zoneBreakdown.anaerobicSeconds, 199 + 30 + 299, accuracy: 0.001,
                       "the gap is never filled in")
        XCTAssertEqual(second.stops, 1)
        XCTAssertEqual(first.stops, 0, "the dead session isn't written to")
    }
}

// MARK: - HelioSession: the workout's stream

private let keyHex = "00112233445566778899aabbccddeeff"

@MainActor
private final class WorkoutStrapTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])
    var maxWriteLength = 244
    private(set) var writes: [ZeppWrite] = []
    private(set) var notifyChanges: [(ZeppCharacteristic, Bool)] = []
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }
    func write(_ write: ZeppWrite) {
        writes.append(write)
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) {
        notifyChanges.append((characteristic, enabled))
        inbox.append((characteristic, nil, enabled))
    }
    func read(_ characteristic: ZeppCharacteristic) {
        switch characteristic {
        case .hardwareRevision: inbox.append((characteristic, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((characteristic, [64], false))
        default: break
        }
    }
    func drain() {
        var guardCount = 0
        while !inbox.isEmpty, guardCount < 100_000 {
            guardCount += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes { session?.received(characteristic, bytes) }
            else { session?.notificationStateChanged(characteristic, enabled: enabled, failed: false) }
        }
    }

    /// Plaintext single-chunk commands the phone sent to the heart-rate endpoint (`0x001D`).
    var heartRateCommands: [[UInt8]] {
        writes.filter { $0.characteristic == .chunkedWrite }.compactMap { w in
            let b = w.bytes
            guard b.count > 11, b[0] == 0x03, b[1] & 0x01 != 0, b[1] & 0x08 == 0,
                  UInt16(b[9]) | (UInt16(b[10]) << 8) == ZeppEndpoint.heartRate else { return nil }
            return Array(b[11...])
        }
    }
}

@MainActor
private final class WorkoutKeys: HelioKeyStoring {
    var isRejected = false
    func load() -> ZeppAuthKey? { HelioKeyText.parse(keyHex) }
    func save(pasted text: String) throws -> Bool { true }
    func forget() {}
    func markRejected() { isRejected = true }
}

@MainActor
final class StrapWorkoutSessionTests: XCTestCase {
    private var clock = t0
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeSink() throws -> HelioStoreSink {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return HelioStoreSink(store: LocalStore(container.mainContext))
    }

    private func freshOrphanStop() -> StrapWorkoutOrphanStop {
        StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!)
    }

    private func connect(sink: HelioStoreSink? = nil, orphanStop: StrapWorkoutOrphanStop? = nil,
                         workoutHolds: @escaping @MainActor () -> Bool = { false }) -> (HelioSession, WorkoutStrapTransport) {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0),
                           (0x0043, 0), (0x0047, 0), (0x004B, 0), (0x0082, 0)]
        // Made-up versions (§5.3), so setup doesn't wait out the device-info step.
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        let transport = WorkoutStrapTransport(device: device)
        let keys = WorkoutKeys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000A2",
                                   key: keys.load(), keyStore: keys, sink: sink, findState: HelioFindState(),
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: false,
                                   workoutHoldsLink: workoutHolds)
        transport.session = session
        session.orphanStop = orphanStop ?? freshOrphanStop()
        session.start()
        transport.drain()
        return (session, transport)
    }

    func testTheWorkoutStreamRunsPastTheMeasureBudgetAndThroughBackgrounding() {
        let (session, transport) = connect()
        XCTAssertTrue(session.ready)
        XCTAssertTrue(session.canStreamHeartRate)
        var readings: [Int] = []
        session.heartRateObserver = { bpm, _ in readings.append(bpm) }
        session.startWorkoutHeartRate()
        XCTAssertEqual(session.liveHeartRateOwner, .workout)
        XCTAssertEqual(transport.heartRateCommands, [ZeppHeartRateControl.start])
        let live = StrapLiveHeartRate(session: session)
        XCTAssertFalse(live.measuring, "a workout's stream is not a Measure")
        XCTAssertTrue(live.disabled, "Measure can't take the stream from a workout")
        live.toggle()
        XCTAssertTrue(session.liveHeartRateRunning)

        // Ten minutes, a reading and a tick every second: well past the Measure's 90 s.
        for s in 1...600 {
            clock = at(TimeInterval(s))
            session.received(.heartRateMeasurement, [0x00, 130])
            session.tick(now: clock)
        }
        XCTAssertTrue(session.liveHeartRateRunning, "no time limit (SPEC-GAP: §7.1 sets none)")
        XCTAssertEqual(readings.count, 600)
        XCTAssertEqual(transport.heartRateCommands.filter { $0 == ZeppHeartRateControl.keepRunning }.count, 600,
                       "04 02 every second")
        session.appDidEnterBackground()
        XCTAssertTrue(session.liveHeartRateRunning, "backgrounding stops a Measure, not a workout")

        session.stopWorkoutHeartRate()
        XCTAssertFalse(session.liveHeartRateRunning)
        XCTAssertEqual(transport.heartRateCommands.last, ZeppHeartRateControl.stop)
    }

    /// §18.1 route 1, §18.8: `04 01` (after enabling 0x2A37), `04 02` each second, `04 00` and unsubscribe
    /// at the end, and NOTHING on the workout endpoint `0x0019` (no start/end, never phone GPS, §18.5).
    func testRouteOneNeverTouchesTheWorkoutEndpoint() {
        let (session, transport) = connect()
        session.startWorkoutHeartRate()
        XCTAssertEqual(transport.notifyChanges.last.map { [$0.0 == .heartRateMeasurement, $0.1] }, [true, true])
        for s in 1...5 {
            clock = at(TimeInterval(s))
            session.received(.heartRateMeasurement, [0x00, 0x8f])
            session.tick(now: clock)
        }
        session.stopWorkoutHeartRate()
        XCTAssertEqual(transport.heartRateCommands,
                       [ZeppHeartRateControl.start] + Array(repeating: ZeppHeartRateControl.keepRunning, count: 5)
                       + [ZeppHeartRateControl.stop])
        XCTAssertEqual(transport.notifyChanges.last.map { [$0.0 == .heartRateMeasurement, $0.1] }, [true, false])
        XCTAssertFalse(transport.device.receivedEndpoints.contains(0x0019), "route 1 sends nothing on 0x0019")
    }

    /// Review-238 SF2: the strap isn't connected when the person answers the interrupted-workout offer.
    /// It connects later: exactly one `04 00`, at its first authenticated ready, and none after.
    func testTheOwedStopIsSentOnceAtTheStrapsNextReady() async throws {
        let owed = freshOrphanStop()
        let journal = MemoryJournal()
        let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-O")
        journal.journal = StrapWorkoutJournal(sport: .runningIndoor, ledger: WorkoutActivityLedger(start: at(0)),
                                              lastAliveAt: at(600), timelineRaw: timeline.rawValue)
        journal.samples = (1...600).map { HRSample(bpm: 140, start: at(Double($0) - 1), end: at(Double($0))) }
        let recorder = StrapWorkoutRecorder(source: { nil }, health: FakeHealthWriter(), journal: journal,
                                            hrStore: { FakeHRStore() }, location: FakeLocation(), liveActivity: nil,
                                            profile: { UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male) },
                                            indoorKeepAlive: { false }, orphanStop: owed,
                                            clock: { at(4000) }, autoTick: false, managesIdleTimer: false)
        recorder.resolveOrphan()
        let saved = await recorder.saveRecovered()
        XCTAssertTrue(saved)
        XCTAssertTrue(owed.owed, "no strap at the tap: still owed")

        let (session, transport) = connect(orphanStop: owed)
        XCTAssertTrue(session.ready)
        XCTAssertEqual(transport.heartRateCommands, [ZeppHeartRateControl.stop], "exactly one 04 00, at ready")
        XCTAssertFalse(owed.owed)
        let (_, later) = connect(orphanStop: owed)
        XCTAssertEqual(later.heartRateCommands, [], "and never again")
    }

    func testAnOwedStopIsOnlyClearedWhenThisConnectionStreamsItself() {
        let owed = freshOrphanStop()
        let (session, transport) = connect(orphanStop: owed)
        session.startLiveHeartRate(duration: StrapLiveHeartRate.duration)
        owed.owed = true
        session.sendOwedOrphanStop()
        XCTAssertTrue(session.liveHeartRateRunning, "a Measure running on this connection is left alone")
        XCTAssertEqual(transport.heartRateCommands, [ZeppHeartRateControl.start])
        XCTAssertFalse(owed.owed)
    }

    func testAStalledWorkoutStreamIsStartedAgain() {
        let (session, transport) = connect()
        session.startWorkoutHeartRate()
        clock = at(1)
        session.received(.heartRateMeasurement, [0x00, 120])
        for s in 2...25 {
            clock = at(TimeInterval(s))
            session.tick(now: clock)
        }
        // Silent from 1 s: restarted at 11 s and again at 21 s, never more often than every 10 s.
        XCTAssertEqual(transport.heartRateCommands.filter { $0 == ZeppHeartRateControl.start }.count, 3)
    }

    func testAMeasureIsTakenOverByAWorkoutWithoutARestart() {
        let (session, transport) = connect()
        session.startLiveHeartRate(duration: StrapLiveHeartRate.duration)
        session.startWorkoutHeartRate()
        XCTAssertEqual(session.liveHeartRateOwner, .workout)
        XCTAssertEqual(transport.heartRateCommands.filter { $0 == ZeppHeartRateControl.start }.count, 1)
        clock = at(StrapLiveHeartRate.duration + 5)
        session.received(.heartRateMeasurement, [0x00, 120])
        session.tick(now: clock)
        XCTAssertTrue(session.liveHeartRateRunning, "the Measure's 90 s no longer applies")
    }

    func testSyncsWaitWhileAWorkoutHoldsTheLink() throws {
        var holds = true
        let (session, transport) = connect(sink: try makeSink(), workoutHolds: { holds })
        session.syncHistory(manual: true)
        XCTAssertFalse(session.syncing)
        XCTAssertEqual(session.syncStatus, "Syncs after the workout ends")
        XCTAssertFalse(transport.notifyChanges.contains { $0.0 == .activityControl })
        holds = false
        session.syncHistory(manual: false)
        XCTAssertTrue(session.syncing, "and runs once it ends")
    }
}

// MARK: - LocalStore: workout readings never move the strap's watermarks

@MainActor
final class StrapWorkoutStoreTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-B")

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
        StrapWorkoutHealthExclusions().clear(device: timeline)
    }

    override func tearDown() {
        StrapWorkoutHealthExclusions().clear(device: timeline)
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

    /// A 2-minute workout's readings, +1 … +120 s, each over the second before it.
    private var readings: [HRSample] { (1...120).map { HRSample(bpm: 150, start: at(Double($0) - 1), end: at(Double($0))) } }

    func testWorkoutReadingsLandWithoutMovingEitherWatermarkAndOnlyOnce() throws {
        let store = try makeStore()
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        try store.insertWorkoutHeartRate(readings, timeline: timeline)   // a retried landing
        let rows = try store.context.fetch(FetchDescriptor<StoredSample>())
        XCTAssertEqual(rows.count, 120, "no duplicates")
        XCTAssertTrue(rows.allSatisfy { $0.deviceID == timeline.rawValue && $0.kindRaw == MetricKind.heartRate.rawValue })
        XCTAssertNil(try store.loadCursor(device: timeline).last(.heartRate), "the ingest watermark is untouched")

        // The strap's own history from BEFORE the workout still goes in afterwards.
        let earlier = [QuantitySample(kind: .heartRate, start: at(-3600), value: 70)]
        XCTAssertEqual(try store.ingest(earlier, device: timeline).count, 1)
    }

    /// Review-238 SF1 (its probe, ported): the strap's history rows at +0 and +60 were synced and flushed,
    /// then the workout's readings are stored. None of them is offered to Health again.
    func testLandedWorkoutReadingsAreNotOfferedToHealthAgain() throws {
        let store = try makeStore()
        _ = try store.ingest([QuantitySample(kind: .heartRate, start: at(0), value: 150),
                              QuantitySample(kind: .heartRate, start: at(60), value: 152)], device: timeline)
        let firstFlush = try store.pendingHealthSamples(device: timeline, kinds: [.heartRate])
        XCTAssertEqual(firstFlush.count, 2)
        try store.markHealthWritten(firstFlush, device: timeline)
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        XCTAssertEqual(try store.pendingHealthSamples(device: timeline, kinds: [.heartRate]).count, 0)
    }

    /// Review-238 SF1's second probe, ported: the strap never synced again after the workout (the person
    /// went back to the ring); its next flush, whenever it comes, offers none of the readings.
    func testReadingsStoredBeforeTheStrapEverFlushedAreNotOffered() throws {
        let store = try makeStore()
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        XCTAssertEqual(try store.pendingHealthSamples(device: timeline, kinds: [.heartRate]).count, 0)
    }

    /// Why the Health watermark is not jumped (decision 39, the #241 shape): strap rows from before the
    /// workout that a skipped flush left pending are still offered after the readings are stored.
    func testPendingStrapRowsFromBeforeTheWorkoutAreStillOffered() throws {
        let store = try makeStore()
        let before = (1...10).map { QuantitySample(kind: .heartRate, start: at(Double(-60 * $0)), value: 70) }
        _ = try store.ingest(before, device: timeline)   // synced; its flush was skipped (busy, or Health off)
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        let pending = try store.pendingHealthSamples(device: timeline, kinds: [.heartRate])
        XCTAssertEqual(pending.count, 10, "none lost")
        XCTAssertTrue(pending.allSatisfy { $0.start < at(0) })
    }

    /// The strap's own all-day rows inside the workout (instants) still reach Health; only a reading the
    /// workout stored is left out.
    func testTheStrapsOwnRowsInsideTheWorkoutAreStillOffered() throws {
        let store = try makeStore()
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        // The history sync after End brings the strap's per-minute rows for the same two minutes.
        _ = try store.ingest([QuantitySample(kind: .heartRate, start: at(30), value: 149),
                              QuantitySample(kind: .heartRate, start: at(90), value: 151)], device: timeline)
        let pending = try store.pendingHealthSamples(device: timeline, kinds: [.heartRate])
        XCTAssertEqual(pending.map(\.start), [at(30), at(90)])
        XCTAssertTrue(pending.allSatisfy { $0.end == $0.start })
    }

    func testASpanIsDroppedOnceTheHealthWatermarkPassesIt() throws {
        let store = try makeStore()
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        XCTAssertEqual(StrapWorkoutHealthExclusions().intervals(device: timeline), [DateInterval(start: at(0), end: at(120))])
        let later = [QuantitySample(kind: .heartRate, start: at(600), value: 80)]
        _ = try store.ingest(later, device: timeline)
        let pending = try store.pendingHealthSamples(device: timeline, kinds: [.heartRate])
        XCTAssertEqual(pending, later)
        try store.markHealthWritten(pending, device: timeline)
        _ = try store.pendingHealthSamples(device: timeline, kinds: [.heartRate])
        XCTAssertEqual(StrapWorkoutHealthExclusions().intervals(device: timeline), [], "nothing inside it can be pending")
    }

    /// Review-238b N-1: a retired timeline is never flushed again, so its spans could never be pruned.
    /// Forgetting the strap, and a new identity replacing it, drop them.
    func testRetiringATimelineDropsItsSpans() throws {
        let store = try makeStore()
        try store.insertWorkoutHeartRate(readings, timeline: timeline)
        let other = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-C")
        StrapWorkoutHealthExclusions().add(DateInterval(start: at(0), end: at(120)), device: other)
        defer { StrapWorkoutHealthExclusions().clear(device: other) }

        StrapWorkoutHealthExclusions.retire(timeline: timeline)
        XCTAssertEqual(StrapWorkoutHealthExclusions().intervals(device: timeline), [])
        XCTAssertEqual(StrapWorkoutHealthExclusions().intervals(device: other).count, 1, "only the retired one")
        // The rows themselves stay, as every other forget leaves them; they are simply offered again,
        // which is right: this timeline will never be flushed, and a re-added strap gets a new one.
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<StoredSample>()).count, 120)
    }

    /// Spans are keyed per timeline, so a strap workout can never withhold one of the ring's rows.
    ///
    /// This used to assert the stronger "the exclusion never applies to the ring's timeline", which
    /// #241 / decision 46 deliberately ended: the ring's workout now lands the same way the strap's
    /// does, so it gets spans of its own. What that does to the ring's flush is
    /// `RingWorkoutHeartRateTests`; what must not change is this — the strap's spans stay the
    /// strap's.
    func testAStrapsSpansNeverTouchTheRingsPendingSamples() throws {
        let store = try makeStore()
        StrapWorkoutHealthExclusions().add(DateInterval(start: at(0), end: at(120)), device: timeline)
        ownership.install(DeviceOwnershipLog())   // a ring-only install
        let ring = (1...5).map { QuantitySample(kind: .heartRate, start: at(Double($0 * 10)), end: at(Double($0 * 10 + 2)), value: 90) }
        _ = try store.ingest(ring, device: .ringConn)
        XCTAssertEqual(try store.pendingHealthSamples(device: .ringConn, kinds: [.heartRate]), ring,
                       "a span recorded for the strap's timeline is not read for the ring's")
    }
}

// MARK: - #225 merged: background runs, wakes and expiry leave a workout's link alone (review-238 B1)

/// `HelioBackgroundLink` that counts what a run does to the link.
@MainActor
private final class CountingLink: HelioBackgroundLink {
    var session: HelioSession?
    var endedBusy = false
    var strapTimeline: SyncDeviceID? = .timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-H")
    var activeBackgroundRuns = 0
    var backgroundRunAdoptsNewSessions = false
    var pendingNightsFinalization: Date?
    var activeRun: HelioActiveRun?
    var handOver: HelioHandOver?
    private(set) var connects = 0
    private(set) var disconnects = 0
    private(set) var rearms = 0
    var onConnect: (() -> Void)?
    func connectForBackground() -> Bool { connects += 1; onConnect?(); return true }
    func disconnectForBackground(cancelNow: Bool) {
        disconnects += 1
        session?.linkLost()
        session = nil
    }
    func rearmAfterTeardown() { rearms += 1 }
    func noteBackgroundRunStarted(at date: Date) {}
}

@MainActor
final class StrapWorkoutBackgroundTests: XCTestCase {
    private var clock = t0
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private var recorders: [StrapWorkoutRecorder] = []
    /// Sessions hold their transport weakly: kept here for the test's length.
    private var transports: [WorkoutStrapTransport] = []

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        for recorder in recorders { recorder.cancel() }
        recorders.removeAll()
        transports.removeAll()
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func connect(sink: HelioStoreSink? = nil,
                         workoutHolds: @escaping @MainActor () -> Bool = { false }) -> (HelioSession, WorkoutStrapTransport) {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0),
                           (0x0043, 0), (0x0047, 0), (0x004B, 0), (0x0082, 0)]
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        let transport = WorkoutStrapTransport(device: device)
        let keys = WorkoutKeys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000A3",
                                   key: keys.load(), keyStore: keys, sink: sink, findState: HelioFindState(),
                                   clock: { [unowned self] in self.clock }, autoTick: false, autoSyncOnConnect: false,
                                   workoutHoldsLink: workoutHolds)
        transport.session = session
        session.orphanStop = StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!)
        session.start()
        transport.drain()
        transports.append(transport)
        return (session, transport)
    }

    private func makeSink() throws -> HelioStoreSink {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return HelioStoreSink(store: LocalStore(container.mainContext))
    }

    /// A recorder that has started a workout on whatever `source` returns.
    private func startWorkout(on source: @escaping @MainActor () -> (any StrapWorkoutHeartRateSource)?) -> StrapWorkoutRecorder {
        let recorder = StrapWorkoutRecorder(
            source: source, health: FakeHealthWriter(), journal: MemoryJournal(), hrStore: { FakeHRStore() },
            location: FakeLocation(), liveActivity: nil,
            profile: { UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male) }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!),
            clock: { [unowned self] in self.clock }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = .runningIndoor
        recorder.start()
        recorders.append(recorder)
        return recorder
    }

    private func service(_ link: CountingLink, pause: @escaping @MainActor () async -> Void = {}) -> HelioBackgroundSyncService {
        HelioBackgroundSyncService(link: link, keyStore: WorkoutKeys(), observability: ObservabilityStore(),
                                   flush: { _, _, _, _ in nil }, now: { [unowned self] in self.clock },
                                   pause: pause, grace: {}, appIsActive: { false })
    }

    func testABackgroundRunDuringAWorkoutTouchesNothing() async {
        let link = CountingLink()
        let (session, transport) = connect(workoutHolds: { StrapWorkoutRecorder.holdsStrapLink })
        link.session = session
        let recorder = startWorkout(on: { link.session })
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink)
        XCTAssertEqual(session.liveHeartRateOwner, .workout)
        let commandsBefore = transport.heartRateCommands.count

        let run = await service(link).run(kind: .appRefresh, timeout: 30, wake: .healthDelivery)
        XCTAssertEqual(run.ending, .workoutHoldsStrap)
        XCTAssertEqual(link.disconnects, 0, "no disconnectForBackground")
        XCTAssertEqual(link.rearms, 0, "no teardown re-arm")
        XCTAssertEqual(link.connects, 0)
        XCTAssertFalse(session.syncing, "no sync on the workout's link")
        XCTAssertTrue(session.isLinkConnected)
        XCTAssertTrue(session.liveHeartRateRunning, "the stream keeps going")
        XCTAssertEqual(transport.heartRateCommands.count, commandsBefore, "not even a 04 00")
        XCTAssertTrue(run.breadcrumb(kind: .appRefresh).contains("ending=workoutHoldsStrap"), "the breadcrumb names the hold")
        XCTAssertTrue(run.detail.contains("a strap workout holds the strap"))
        XCTAssertTrue(run.success, "busy recording, not a failure")
        XCTAssertTrue(recorder.isRecording)
    }

    /// A run already waiting for its session when the workout takes the strap ends at its next turn,
    /// before an expiry or a sync is considered, and without a teardown.
    func testARunInFlightEndsWithoutATeardownWhenAWorkoutTakesTheStrap() async {
        let link = CountingLink()
        var recorder: StrapWorkoutRecorder?
        let run = await service(link, pause: { [unowned self] in
            if recorder == nil {
                let (session, _) = self.connect(workoutHolds: { StrapWorkoutRecorder.holdsStrapLink })
                link.session = session
                recorder = self.startWorkout(on: { link.session })
            }
        }).run(kind: .processing, timeout: 60, wake: .processing)
        XCTAssertEqual(run.ending, .workoutHoldsStrap)
        XCTAssertEqual(link.disconnects, 0)
        XCTAssertEqual(link.rearms, 0)
        XCTAssertEqual(link.session?.liveHeartRateRunning, true)
        XCTAssertEqual(link.session?.backgroundRunOwnsSyncs, false, "handed back to its own hooks")
    }

    func testAnExpiryDuringAWorkoutLeavesTheLinkAlone() {
        let link = CountingLink()
        let (session, _) = connect(workoutHolds: { StrapWorkoutRecorder.holdsStrapLink })
        link.session = session
        _ = startWorkout(on: { link.session })
        link.tearDownForExpiry()
        XCTAssertEqual(link.disconnects, 0)
        XCTAssertEqual(link.rearms, 0)
        XCTAssertTrue(session.liveHeartRateRunning)
        XCTAssertTrue(session.isLinkConnected)
    }

    func testEveryWakeSkipsDuringAWorkout() {
        let sources: [HelioWake] = [.reconnect, .restoration, .idleTraffic, .strapEvent, .healthDelivery]
        for wake in sources {
            for appIsActive in [false, true] {
                XCTAssertEqual(HelioWakePolicy.action(for: wake, strapChosen: true, appIsActive: appIsActive, runActive: false,
                                                      lastCompletedSync: nil, lastBackgroundRunStart: nil, now: clock,
                                                      workoutHoldsStrap: true),
                               .skip(HelioWakePolicy.workoutHoldsStrapReason), "\(wake) app active \(appIsActive)")
            }
        }
        // Without a workout the same wakes still catch up (nothing else changed).
        XCTAssertEqual(HelioWakePolicy.action(for: .healthDelivery, strapChosen: true, appIsActive: false, runActive: false,
                                              lastCompletedSync: nil, lastBackgroundRunStart: nil, now: clock), .catchUp)
        // The stream's own traffic on the held link is never evaluated as a wake.
        var gate = HelioIdleTrafficGate()
        XCTAssertFalse(gate.shouldCheck(now: clock, appIsActive: false, syncing: false, runActive: false, workoutHoldsStrap: true))
        XCTAssertTrue(gate.shouldCheck(now: clock, appIsActive: false, syncing: false, runActive: false))
    }

    func testTheCoordinatorRunsNoCatchUpDuringAWorkout() {
        var runs = 0
        var notes: [String] = []
        let coordinator = HelioWakeCoordinator(.init(
            strapChosen: { true }, appIsActive: { false }, runActive: { false },
            state: HelioWakeState(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!),
            now: { [unowned self] in self.clock }, syncInForeground: { runs += 1 },
            beginAssertion: { _ in 1 }, endAssertion: { _ in }, run: { _ in runs += 1; return nil },
            expire: { runs += 1 }, afterRun: { _ in }, note: { _, text in notes.append(text) },
            workoutHoldsStrap: { true }))
        var done = 0
        for wake in [HelioWake.reconnect, .restoration, .idleTraffic, .strapEvent, .healthDelivery] {
            coordinator.wake(wake) { done += 1 }
        }
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(done, 5, "every completion handler is still called")
        XCTAssertEqual(notes.count, 5)
        XCTAssertTrue(notes.allSatisfy { $0.contains(HelioWakePolicy.workoutHoldsStrapReason) })
    }

    /// #225's app-open sync (review-225e SF-1): nothing while a workout holds the link, and it doesn't
    /// count as an attempt.
    func testTheAppOpenSyncWaitsForTheWorkoutAndIsNotCounted() {
        var gate = HelioActivationSync()
        XCTAssertFalse(gate.shouldSync(phase: .ready, syncing: false, finding: false, liveHeartRate: false,
                                       lastCompletedSync: nil, now: clock, workoutHoldsStrap: true))
        XCTAssertNil(gate.lastStarted)
        XCTAssertTrue(gate.shouldSync(phase: .ready, syncing: false, finding: false, liveHeartRate: false,
                                      lastCompletedSync: nil, now: clock))
    }

    /// The sync the workout held back runs once, at End (the T6 re-arm), on the merged code.
    func testAfterEndOneSyncRuns() async throws {
        let (session, transport) = connect(sink: try makeSink(), workoutHolds: { StrapWorkoutRecorder.holdsStrapLink })
        let recorder = startWorkout(on: { session })
        session.syncHistory(manual: false)            // a wake, an app open, a pull-to-refresh: deferred
        session.syncHistory(manual: true)
        XCTAssertFalse(session.syncing)
        XCTAssertFalse(transport.notifyChanges.contains { $0.0 == .activityControl && $0.1 })
        clock = clock.addingTimeInterval(60)
        await recorder.end()
        XCTAssertTrue(session.syncing, "the held-back sync starts at End")
        XCTAssertEqual(transport.notifyChanges.filter { $0.0 == .activityControl && $0.1 }.count, 1, "exactly one")
    }

    /// Review-238 S1: Bluetooth turned off mid-workout. `HelioConnection` gets only `.poweredOff` (no
    /// `didDisconnectPeripheral`): the link counts as lost (the keep-alive stops, the workout opens a
    /// gap), a reconnect waits for power-on, and the reconnected strap is adopted.
    func testBluetoothOffMidWorkoutOpensAGapAndTheReconnectIsAdopted() async {
        let connection = HelioConnection(keyStore: WorkoutKeys())
        let (session, _) = connect(workoutHolds: { StrapWorkoutRecorder.holdsStrapLink })
        connection.installSessionForTesting(session)
        let recorder = startWorkout(on: { connection.session })
        for s in 1...30 {
            clock = t0.addingTimeInterval(Double(s))
            session.received(.heartRateMeasurement, [0x00, 140])
            await recorder.tick(now: clock)
        }
        connection.centralStateChanged(.poweredOff)
        XCTAssertNil(connection.session)
        XCTAssertFalse(session.isLinkConnected)
        XCTAssertFalse(session.liveHeartRateRunning, "the keep-alive stopped")
        XCTAssertTrue(connection.reconnectArmedForPowerOn, "power-on reconnects the known strap")
        clock = t0.addingTimeInterval(31)
        await recorder.tick(now: clock)
        XCTAssertTrue(recorder.linkDown, "the gap is open")
        XCTAssertTrue(recorder.isRecording)

        let (back, _) = connect(workoutHolds: { StrapWorkoutRecorder.holdsStrapLink })
        connection.installSessionForTesting(back)   // what power-on's reconnect builds
        clock = t0.addingTimeInterval(90)
        await recorder.tick(now: clock)
        XCTAssertFalse(recorder.linkDown, "the gap is closed")
        XCTAssertEqual(back.liveHeartRateOwner, .workout, "the stream restarted on the reconnected strap")
        XCTAssertEqual(recorder.ledger?.gaps, [DateInterval(start: t0.addingTimeInterval(31), end: t0.addingTimeInterval(90))])
    }
}

// MARK: - Review-238b SF-1: the hold lasts until the workout is written

@MainActor
final class StrapWorkoutEndWindowTests: XCTestCase {
    private var now = t0
    private var containers: [ModelContainer] = []
    private var transports: [WorkoutStrapTransport] = []
    private var recorders: [StrapWorkoutRecorder] = []
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        for recorder in recorders where recorder.isRecording { recorder.cancel() }
        recorders.removeAll()
        transports.removeAll()
        containers.removeAll()
        ownership.restore()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "no test may leave the strap held")
        super.tearDown()
    }

    private func makeSink() throws -> HelioStoreSink {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return HelioStoreSink(store: LocalStore(container.mainContext))
    }

    private func connect(sink: HelioStoreSink? = nil) -> (HelioSession, WorkoutStrapTransport) {
        let device = FakeZeppDevice(authKey: ZeppHex.bytes(keyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                    random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
        device.services = [(0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0),
                           (0x0043, 0), (0x0047, 0), (0x004B, 0), (0x0082, 0)]
        device.deviceInfoReply = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0] + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]
        let transport = WorkoutStrapTransport(device: device)
        let keys = WorkoutKeys()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000A4",
                                   key: keys.load(), keyStore: keys, sink: sink, findState: HelioFindState(),
                                   clock: { [unowned self] in self.now }, autoTick: false, autoSyncOnConnect: false,
                                   workoutHoldsLink: { StrapWorkoutRecorder.holdsStrapLink })
        transport.session = session
        session.orphanStop = StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!)
        session.start()
        transport.drain()
        transports.append(transport)
        return (session, transport)
    }

    private func makeRecorder(source: @escaping @MainActor () -> (any StrapWorkoutHeartRateSource)?,
                              health: FakeHealthWriter) -> StrapWorkoutRecorder {
        let recorder = StrapWorkoutRecorder(
            source: source, health: health, journal: MemoryJournal(), hrStore: { FakeHRStore() },
            location: FakeLocation(), liveActivity: nil,
            profile: { UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male) }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!),
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = .runningIndoor
        recorders.append(recorder)
        return recorder
    }

    /// Review-238b SF-1, its probe in our own words. Writing the `HKWorkout` is a whole
    /// `HKWorkoutBuilder` round trip; a background run that starts inside it must still be held off,
    /// or it tears the link down before `end()` can run the sync the workout held back.
    /// Fails on 1078b6e: there the hold was already released when `.finishing` began.
    func testTheHoldLastsThroughTheHealthWrite() async throws {
        let link = CountingLink()
        let (session, _) = connect(sink: try makeSink())
        link.session = session
        let health = FakeHealthWriter()
        let recorder = makeRecorder(source: { link.session }, health: health)
        recorder.start()
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink)

        let service = HelioBackgroundSyncService(
            link: link, keyStore: WorkoutKeys(), observability: ObservabilityStore(),
            flush: { _, _, _, _ in nil }, now: { [unowned self] in self.now },
            pause: {}, grace: {}, appIsActive: { false })
        var heldDuringSave = false
        var endingDuringSave: HelioBackgroundRun.Ending?
        health.duringSave = {
            heldDuringSave = StrapWorkoutRecorder.holdsStrapLink
            endingDuringSave = await service.run(kind: .appRefresh, timeout: 2, wake: .healthDelivery).ending
        }

        now = at(120)
        await recorder.end()

        XCTAssertTrue(heldDuringSave, "the strap is still held while the HKWorkout is written")
        XCTAssertEqual(endingDuringSave, .workoutHoldsStrap, "a run started inside the save window is held off")
        XCTAssertEqual(link.disconnects, 0, "the link the workout is using is never torn down")
        XCTAssertEqual(link.rearms, 0)
        XCTAssertNotNil(link.session)
        XCTAssertTrue(session.syncing, "and the sync the workout held back runs once, after End")
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "released once End returns")
    }

    /// Every terminal path releases the hold: nothing may block the wakes and background syncs for good.
    func testEveryTerminalPathReleasesTheHold() async throws {
        // End, with Apple Health refusing the workout.
        let health = FakeHealthWriter()
        health.accept = false
        let source = FakeHRSource()
        let ended = makeRecorder(source: { source }, health: health)
        ended.start()
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink)
        now = at(60)
        await ended.end()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "End, Health refusing")
        guard case .finished(_, let saved) = ended.state else { return XCTFail("not finished") }
        XCTAssertFalse(saved)

        // End, with the strap gone (the `source()` the sync needs is nil).
        var live: FakeHRSource? = FakeHRSource()
        let vanished = makeRecorder(source: { live }, health: FakeHealthWriter())
        vanished.start()
        live = nil
        now = at(120)
        await vanished.end()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "End with no strap")

        // Cancel (the Discard path).
        let cancelled = makeRecorder(source: { source }, health: FakeHealthWriter())
        cancelled.start()
        XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink)
        cancelled.cancel()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "cancel")

        // A kill: the process goes with the hold, which is in memory only.
        do {
            let killed = makeRecorder(source: { source }, health: FakeHealthWriter())
            killed.start()
            XCTAssertTrue(StrapWorkoutRecorder.holdsStrapLink)
            recorders.removeAll { $0 === killed }
        }
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "a dead process holds nothing")

        // The recovery paths never take the hold in the first place.
        let journal = MemoryJournal()
        journal.journal = StrapWorkoutJournal(sport: .yoga, ledger: WorkoutActivityLedger(start: at(0)),
                                              lastAliveAt: at(300), timelineRaw: source.timeline.rawValue)
        journal.samples = (1...300).map { HRSample(bpm: 120, start: at(Double($0) - 1), end: at(Double($0))) }
        let recovery = StrapWorkoutRecorder(
            source: { source }, health: FakeHealthWriter(), journal: journal, hrStore: { FakeHRStore() },
            location: FakeLocation(), liveActivity: nil,
            profile: { UserProfile(age: 40, weightKg: 70, heightCm: 175, sex: .male) }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(UserDefaults(suiteName: "strap-workout-tests-\(UUID().uuidString)")!),
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorders.append(recovery)
        now = at(4000)
        recovery.resolveOrphan()
        XCTAssertNotNil(recovery.recoverable)
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "offering an interrupted workout")
        _ = await recovery.saveRecovered()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "saving it")
    }
}
