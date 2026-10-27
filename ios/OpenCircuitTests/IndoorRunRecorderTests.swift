import CoreLocation
import HealthKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Indoor runs and walks (#339, decision 84c–84g): the strap recorder's step bookkeeping against a fake
// step source, the summary's typed distance (`IndoorRunFinish`) against a fake Health writer, the
// calibrated stride per device and sport, the per-minute speed and stride, the indoor VO₂ max, and the
// ring's `sportSteps` reading. Every counter, reading and time is synthetic and rounded.

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// MARK: - Fakes

@MainActor
private final class StepSource: StrapWorkoutHeartRateSource, StrapWorkoutStepSource {
    let timeline: SyncDeviceID
    var isLinkConnected = true
    var ready = true
    var syncing = false
    var canStreamHeartRate = true
    var heartRateObserver: (@MainActor (Int, Date) -> Void)?
    var rrIntervalsReceived = 0
    var stepCounterObserver: (@MainActor (Int, Date) -> Void)?
    /// What the source was asked, in order: "on", "off", "owed-off".
    private(set) var commands: [String] = []
    var hasSteps = true
    /// The stream is on, as the session's: frames reach the observer only then (unless forced).
    private(set) var on = false

    init(timeline: SyncDeviceID) { self.timeline = timeline }

    func startWorkoutHeartRate() {}
    func stopWorkoutHeartRate() {}
    func sendOwedOrphanStop() {}
    func syncHistory(manual: Bool) {}
    func startWorkoutSteps() -> Bool {
        guard hasSteps else { return false }
        commands.append("on")
        on = true
        return true
    }
    func stopWorkoutSteps() { commands.append("off"); on = false }
    func sendOwedStepsOff() { commands.append("owed-off") }

    /// One frame. `force`: delivered even with the stream off (a frame already in flight at a pause).
    func counter(_ value: Int, at date: Date, force: Bool = false) {
        guard on || force else { return }
        stepCounterObserver?(value, date)
    }
    func heartRate(_ bpm: Int, at date: Date) { heartRateObserver?(bpm, date) }
}

@MainActor
private final class WorkoutHealth: StrapWorkoutHealthWriting {
    private(set) var writes: [StrapWorkoutWrite] = []
    var accept = true
    func save(_ write: StrapWorkoutWrite) async -> Bool {
        writes.append(write)
        return accept
    }
}

@MainActor
private final class IndoorHealth: IndoorRunHealthWriting {
    private(set) var metrics: [(minutes: [IndoorRunMinuteSample], estimated: Bool)] = []
    private(set) var replacements: [(workout: DateInterval, meters: Double)] = []
    private(set) var vo2: [(estimate: VO2MaxEstimate.Estimate, end: Date)] = []
    var replaceStatus: IndoorRunHealthStatus = .saved
    func saveRunningMetrics(_ minutes: [IndoorRunMinuteSample], estimated: Bool, timeline: SyncDeviceID) async -> IndoorRunHealthStatus {
        metrics.append((minutes, estimated))
        return .saved
    }
    func replaceEstimate(workout: DateInterval, typedMeters: Double, timeline: SyncDeviceID) async -> IndoorRunHealthStatus {
        replacements.append((workout, typedMeters))
        return replaceStatus
    }
    func saveVO2Max(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date, timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status {
        vo2.append((estimate, workoutEnd))
        return .saved
    }
}

@MainActor
private final class Journal: StrapWorkoutJournalStoring {
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
private final class Treadmill: WorkoutLocationTracking {
    var gpsActive = false
    var distanceMeters: Double?
    var route: [CLLocation] = []
    var keepAliveUnavailable = false
    func start(route: Bool) {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
}

@MainActor
private final class HRStore: StrapWorkoutHRStore {
    func insertWorkoutHeartRate(_ samples: [HRSample], timeline: SyncDeviceID) throws {}
}

@MainActor
private final class VO2Inputs: StrapVO2MaxProviding {
    func userSetAge() -> Int? { 40 }
    func restingHR(workoutStart: Date, workoutEnd: Date) -> Double? { 60 }
    func save(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date, timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status { .saved }
}

// MARK: - Tests

@MainActor
final class IndoorRunRecorderTests: XCTestCase {
    private var now = t0
    private let timeline = SyncDeviceID.timeline(for: .zeppOS(model: "Helio Strap"), identityID: "STRAP-INDOOR")
    private let profile = UserProfile(age: 40, weightKg: 70, heightCm: 180, sex: .male)
    private var suites: [String] = []
    private var recorders: [StrapWorkoutRecorder] = []

    override func tearDown() {
        for recorder in recorders where recorder.isRecording { recorder.cancel() }
        recorders.removeAll()
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites.removeAll()
        XCTAssertFalse(StrapWorkoutRecorder.holdsStrapLink, "no test may leave the strap held")
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "indoor-run-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private struct Rig {
        let recorder: StrapWorkoutRecorder
        let source: StepSource
        let health: WorkoutHealth
        let indoor: IndoorHealth
        let journal: Journal
        let flag: StrapStepStreamFlag
        let calibrations: IndoorStrideCalibrations
    }

    private func makeRig(sport: WorkoutSportType = .runningIndoor, height: Double? = 180,
                         calibrations: IndoorStrideCalibrations? = nil,
                         source: StepSource? = nil) -> Rig {
        let source = source ?? StepSource(timeline: timeline)
        let current = Box(source)
        let health = WorkoutHealth()
        let indoor = IndoorHealth()
        let journal = Journal()
        let flag = StrapStepStreamFlag(defaults())
        let calibrations = calibrations ?? IndoorStrideCalibrations(defaults())
        let profile = self.profile
        let recorder = StrapWorkoutRecorder(
            source: { current.value }, health: health, journal: journal, hrStore: { HRStore() },
            location: Treadmill(), liveActivity: nil, profile: { profile }, indoorKeepAlive: { false },
            orphanStop: StrapWorkoutOrphanStop(defaults()), vo2: VO2Inputs(),
            tombstones: WorkoutTombstones(defaults()), recoveryHealth: nil,
            recoveryWindows: WorkoutRecoveryWindows(defaults()), indoorHealth: indoor, stepStreamFlag: flag,
            strideCalibrations: calibrations, userHeightCm: { height },
            clock: { [unowned self] in self.now }, autoTick: false, managesIdleTimer: false)
        recorder.selectedSport = sport
        recorders.append(recorder)
        boxes[ObjectIdentifier(recorder)] = current
        return Rig(recorder: recorder, source: source, health: health, indoor: indoor, journal: journal,
                   flag: flag, calibrations: calibrations)
    }

    /// The source a recorder sees; tests swap it to model a reconnect's new session.
    private final class Box {
        var value: StepSource
        init(_ value: StepSource) { self.value = value }
    }
    private var boxes: [ObjectIdentifier: Box] = [:]

    /// A counter reading every 10 s over `(from, to]`, `perTen` steps apart, plus a heart-rate reading
    /// at each, ticking the recorder as production does.
    private func run(_ rig: Rig, from: TimeInterval, to: TimeInterval, counter start: Int, perTen: Int = 20,
                     bpm: Int = 160, source: StepSource? = nil) async -> Int {
        var counter = start
        var s = from + 10
        while s <= to {
            now = at(s)
            counter += perTen
            (source ?? rig.source).counter(counter, at: now)
            (source ?? rig.source).heartRate(bpm, at: now)
            await rig.recorder.tick(now: now)
            s += 10
        }
        return counter
    }

    // MARK: Step bookkeeping (84b, 84c)

    func testPauseExcludesStepsAndEachRunningStretchStartsFromANewBase() async {
        let rig = makeRig()
        rig.recorder.start()
        XCTAssertEqual(rig.source.commands, ["on"])
        rig.source.counter(1_000, at: at(5))                       // the base
        var c = await run(rig, from: 5, to: 65, counter: 1_000)    // 6 × 20 = 120
        now = at(70)
        rig.recorder.pause()
        XCTAssertEqual(rig.source.commands, ["on", "off"], "`05 00` at pause")
        c += 300
        rig.source.counter(c, at: at(80), force: true)             // a frame in flight while paused
        now = at(130)
        rig.recorder.resume()
        XCTAssertEqual(rig.source.commands, ["on", "off", "on"], "`05 01` at resume")
        c += 400
        rig.source.counter(c, at: at(135))                         // the new base after resume
        _ = await run(rig, from: 135, to: 195, counter: c)         // 6 × 20 = 120
        now = at(200)
        await rig.recorder.end()
        XCTAssertEqual(rig.source.commands.last, "off", "`05 00` at End")
        XCTAssertEqual(rig.recorder.indoorRun?.inputs.activeSteps, 240,
                       "the pause's 300 and the 400 before the post-resume base are never counted")
    }

    func testANewTreadmillRunUsesAStrideFromHeightAndTheWorkoutGetsTheEstimateAsItsDistance() async throws {
        let rig = makeRig()
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        _ = await run(rig, from: 0, to: 600, counter: 0, perTen: 25)   // 60 × 25 = 1 500 steps
        XCTAssertEqual(rig.recorder.liveCadence ?? 0, 150, accuracy: 0.001, "steps/min over the last 60 s")
        XCTAssertEqual(rig.recorder.liveEstimatedMeters ?? 0, 1_500 * 1.17, accuracy: 0.001)
        now = at(600)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        XCTAssertEqual(finish.inputs.stride?.source, .height)
        XCTAssertEqual(finish.inputs.stride?.meters ?? 0, 1.17, accuracy: 1e-9)
        XCTAssertEqual(rig.health.writes.last?.indoorDistance?.meters ?? 0, 1_755, accuracy: 0.001)
        XCTAssertEqual(finish.distanceMeters ?? 0, 1_755, accuracy: 0.001)
        XCTAssertTrue(finish.distanceIsEstimate)
        XCTAssertEqual(finish.averageCadence ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(finish.minuteCadence.count, 10)
        XCTAssertEqual(finish.vo2MaxOutcome, .skipped(.noTypedDistance), "the indoor VO₂ max waits for the prompt")
    }

    func testATypedDistanceReplacesTheEstimateAndCalibratesThisDeviceAndSportOnly() async throws {
        let calibrations = IndoorStrideCalibrations(defaults())
        let rig = makeRig(calibrations: calibrations)
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        _ = await run(rig, from: 0, to: 600, counter: 0, perTen: 25)
        now = at(600)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        await finish.writeTask?.value
        finish.submit(typedMeters: 1_875, inclinePercent: 2)
        await finish.writeTask?.value

        XCTAssertFalse(finish.distanceIsEstimate)
        XCTAssertEqual(finish.distanceMeters, 1_875)
        XCTAssertEqual(rig.indoor.replacements.map(\.meters), [1_875])
        XCTAssertEqual(rig.indoor.replacements.first?.workout, DateInterval(start: t0, end: at(600)))
        XCTAssertEqual(calibrations.stride(timeline: timeline, sport: .runningIndoor) ?? 0, 1.25, accuracy: 1e-9)
        XCTAssertNil(calibrations.stride(timeline: timeline, sport: .walkingIndoor), "per sport")
        XCTAssertNil(calibrations.stride(timeline: .ringConn, sport: .runningIndoor), "per device")
        // The per-minute samples are rewritten with the typed stride, no longer marked estimated.
        XCTAssertEqual(rig.indoor.metrics.map(\.estimated), [true, false])
        XCTAssertEqual(rig.indoor.metrics.last?.minutes.first?.strideLength ?? 0, 1.25, accuracy: 1e-9)
        finish.submit(typedMeters: 2_000, inclinePercent: nil)
        await finish.writeTask?.value
        XCTAssertEqual(rig.indoor.replacements.count, 1, "once per workout")

        // The next indoor run of this sport on this device starts from the calibration.
        rig.recorder.reset()
        now = at(1_000)
        rig.recorder.start()
        now = at(1_700)
        rig.source.counter(5, at: now)
        rig.source.counter(905, at: at(1_700))
        await rig.recorder.end()
        XCTAssertEqual(rig.recorder.indoorRun?.inputs.stride?.source, .calibrated)
        XCTAssertEqual(rig.recorder.indoorRun?.inputs.stride?.meters ?? 0, 1.25, accuracy: 1e-9)
    }

    func testNoAnswerKeepsTheEstimateMarkedEstimated() async throws {
        let rig = makeRig()
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        _ = await run(rig, from: 0, to: 300, counter: 0)
        now = at(300)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        await finish.writeTask?.value
        XCTAssertNotNil(rig.health.writes.last?.indoorDistance, "the workout carries the estimate")
        XCTAssertEqual(rig.indoor.metrics.map(\.estimated), [true])
        XCTAssertEqual(rig.indoor.replacements.count, 0)
        XCTAssertTrue(finish.distanceIsEstimate)
        rig.recorder.reset()
        XCTAssertEqual(rig.indoor.replacements.count, 0, "leaving the summary changes nothing in Health")
    }

    func testSpeedAndStrideAreWrittenForRunsOnlyAndOnlyForWholeRunningMinutes() async throws {
        let rig = makeRig()
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        var c = await run(rig, from: 0, to: 180, counter: 0)
        now = at(185)
        rig.recorder.pause()
        now = at(240)
        rig.recorder.resume()
        c += 50
        rig.source.counter(c, at: at(240))
        _ = await run(rig, from: 240, to: 420, counter: c)
        now = at(420)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        await finish.writeTask?.value
        let minutes = try XCTUnwrap(rig.indoor.metrics.first?.minutes)
        XCTAssertEqual(minutes.map(\.start), [at(0), at(60), at(120), at(240), at(300), at(360)],
                       "never the minute the pause touched")
        for minute in minutes { XCTAssertEqual(minute.end.timeIntervalSince(minute.start), 60) }
        XCTAssertEqual(minutes[1].speed, 120 * 1.17 / 60, accuracy: 1e-9, "6 × 20 steps × stride ÷ 60 s")

        let walk = makeRig(sport: .walkingIndoor)
        now = t0
        walk.recorder.start()
        walk.source.counter(0, at: at(0))
        _ = await run(walk, from: 0, to: 300, counter: 0)
        now = at(300)
        await walk.recorder.end()
        let walkFinish = try XCTUnwrap(walk.recorder.indoorRun)
        await walkFinish.writeTask?.value
        walkFinish.submit(typedMeters: 300, inclinePercent: nil)
        await walkFinish.writeTask?.value
        XCTAssertEqual(walk.indoor.metrics.count, 0, "a walk writes no running speed or stride")
        XCTAssertEqual(walk.indoor.replacements.count, 1, "its distance is still corrected")
        XCTAssertEqual(walkFinish.inputs.stride?.meters ?? 0, 1.8 * 0.415, accuracy: 1e-9)
        XCTAssertNil(walkFinish.vo2MaxOutcome)
    }

    func testAStrapWithoutTheStepStreamGivesNoDistanceAndTheVO2MaxSaysWhy() async throws {
        let source = StepSource(timeline: timeline)
        source.hasSteps = false
        let rig = makeRig(source: source)
        rig.recorder.start()
        _ = await run(rig, from: 0, to: 900, counter: 0)   // the stream never turned on: no frame arrives
        now = at(900)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        XCTAssertNil(rig.health.writes.last?.indoorDistance, "no steps: no distance, as today")
        XCTAssertNil(finish.distanceMeters)
        XCTAssertEqual(finish.vo2MaxOutcome, .skipped(.noStepData))
    }

    func testAnOutdoorRunNeverTouchesTheStepStream() async {
        let rig = makeRig(sport: .runningOutdoor)
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        _ = await run(rig, from: 0, to: 120, counter: 0)
        now = at(120)
        await rig.recorder.end()
        XCTAssertEqual(rig.source.commands, [])
        XCTAssertNil(rig.recorder.indoorRun)
        XCTAssertNil(rig.health.writes.last?.indoorDistance)
        XCTAssertNil(rig.recorder.liveCadence)
    }

    func testCancelTurnsTheStreamOff() {
        let rig = makeRig()
        rig.recorder.start()
        rig.recorder.cancel()
        XCTAssertEqual(rig.source.commands, ["on", "off"])
    }

    // MARK: The owed off (84b)

    func testAJournalKilledWithTheStreamOnOwesTheStrapAnOff() {
        let rig = makeRig()
        rig.journal.journal = StrapWorkoutJournal(sport: .runningIndoor, ledger: WorkoutActivityLedger(start: t0),
                                                  lastAliveAt: at(60), timelineRaw: timeline.rawValue,
                                                  stepStreamOn: true)
        now = at(3_600)
        rig.recorder.resolveOrphan()
        XCTAssertTrue(rig.flag.offOwed)
        XCTAssertEqual(rig.source.commands, ["owed-off"], "sent at once to a ready strap")
        rig.recorder.postponeRecovered()
    }

    func testALinkDropStopsTheStepsAndTheReconnectNeverTurnsThemBackOn() async throws {
        let rig = makeRig()
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        _ = await run(rig, from: 0, to: 120, counter: 0)
        rig.source.isLinkConnected = false
        now = at(121)
        await rig.recorder.tick(now: now)
        XCTAssertTrue(rig.recorder.linkDown)
        let reconnected = StepSource(timeline: timeline)
        boxes[ObjectIdentifier(rig.recorder)]?.value = reconnected
        now = at(130)
        await rig.recorder.tick(now: now)
        XCTAssertFalse(rig.recorder.linkDown, "the workout adopted the new session")
        XCTAssertEqual(reconnected.commands, [], "no `05 01` after a reconnect (decision 84b)")
        reconnected.counter(5_000, at: at(140))
        now = at(700)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        XCTAssertTrue(finish.inputs.stepsInterrupted)
        XCTAssertEqual(finish.inputs.activeSteps, 240)
        finish.submit(typedMeters: 250, inclinePercent: nil)   // 1.04 m a step: a plausible ratio, still not a stride
        await finish.writeTask?.value
        XCTAssertNil(rig.calibrations.stride(timeline: timeline, sport: .runningIndoor),
                     "too few steps for the typed distance: not a stride, not stored")
        XCTAssertEqual(finish.vo2MaxOutcome, .skipped(.noStepData))
        XCTAssertEqual(rig.indoor.replacements.map(\.meters), [250], "the typed distance still replaces the estimate")
    }

    // MARK: Indoor VO₂ max (84g)

    private func steadyInputs(sport: WorkoutSportType = .runningIndoor, saved: Bool = true) -> IndoorRunInputs {
        var log = WorkoutStepLog()
        for s in stride(from: 10, through: 1_200, by: 10) { log.add(26, at: at(Double(s) - 0.5)) }   // 156 spm
        let hr = stride(from: 0, to: 1_200, by: 10).map { HRSample(bpm: 160, start: at(Double($0))) }
        return IndoorRunInputs(sport: sport, timeline: timeline, start: t0, end: at(1_200), activeSeconds: 1_200,
                               activeSegments: [DateInterval(start: t0, end: at(1_200))], steps: log,
                               stride: IndoorStride(meters: 1.17, source: .height), stepsInterrupted: false,
                               savedToHealth: saved, heartRate: hr, age: 40, restingHR: 60)
    }

    func testTheIndoorVO2MaxIsComputedFromTheTypedDistanceAndInclineAndWrittenWithTheTreadmillMethod() async throws {
        let health = IndoorHealth()
        let finish = IndoorRunFinish(inputs: steadyInputs(), health: health, calibrations: IndoorStrideCalibrations(defaults()))
        XCTAssertEqual(finish.vo2MaxOutcome, .skipped(.noTypedDistance))
        // 3 120 steps; typed 3 900 m → stride 1.25 → 195 m/min; incline 5 %.
        finish.submit(typedMeters: 3_900, inclinePercent: 5)
        await finish.writeTask?.value
        guard case .estimate(let e)? = finish.vo2MaxOutcome else { return XCTFail("expected an estimate") }
        XCTAssertEqual(e.speed, 195, accuracy: 0.001)
        XCTAssertEqual(e.grade, 0.05, accuracy: 1e-12)
        XCTAssertEqual(e.speedSource, .treadmillSteps)
        XCTAssertEqual(health.vo2.count, 1)
        XCTAssertEqual(health.vo2.first?.end, at(1_200))
        XCTAssertEqual(finish.vo2MaxHealthStatus, .saved)
        XCTAssertEqual(IndoorRunHealthWriter.indoorVO2MaxMethod,
                       "ACSM running equation + Swain %HRR (estimate), treadmill distance + steps")
    }

    func testAWorkoutHealthRefusedGetsNoIndoorWritesAtAll() async {
        let health = IndoorHealth()
        let finish = IndoorRunFinish(inputs: steadyInputs(saved: false), health: health,
                                     calibrations: IndoorStrideCalibrations(defaults()))
        finish.writeEstimateMetrics()
        finish.submit(typedMeters: 3_900, inclinePercent: nil)
        await finish.writeTask?.value
        XCTAssertEqual(health.metrics.count + health.replacements.count + health.vo2.count, 0)
        XCTAssertEqual(finish.vo2MaxHealthStatus, .failed)
    }

    // MARK: Review fixes (84i)

    func testAReplaceThatDidNotRemoveTheEstimateNeverAddsASecondSetOfSpeedAndStride() async throws {
        for status in [IndoorRunHealthStatus.failed, .savedEstimateKept, .notConnected] {
            let rig = makeRig()
            rig.indoor.replaceStatus = status
            now = t0
            rig.recorder.start()
            rig.source.counter(0, at: at(0))
            _ = await run(rig, from: 0, to: 300, counter: 0)
            now = at(300)
            await rig.recorder.end()
            let finish = try XCTUnwrap(rig.recorder.indoorRun)
            await finish.writeTask?.value
            finish.submit(typedMeters: 380, inclinePercent: nil)
            await finish.writeTask?.value
            XCTAssertEqual(rig.indoor.metrics.map(\.estimated), [true], "\(status): the estimated set only")
            XCTAssertEqual(finish.distanceStatus, status)
        }
    }

    func testAResumeThatTurnsStepsBackOnAfterALinkDropCountsTheRunAsWholeAgain() async throws {
        let rig = makeRig()
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        _ = await run(rig, from: 0, to: 120, counter: 0)
        rig.source.isLinkConnected = false
        now = at(121)
        await rig.recorder.tick(now: now)
        let reconnected = StepSource(timeline: timeline)
        boxes[ObjectIdentifier(rig.recorder)]?.value = reconnected
        now = at(130)
        await rig.recorder.tick(now: now)
        rig.recorder.pause()
        now = at(140)
        rig.recorder.resume()
        XCTAssertEqual(reconnected.commands, ["on"], "`05 01` again only at the resume")
        reconnected.counter(7_000, at: at(150))
        _ = await run(rig, from: 150, to: 300, counter: 7_000, source: reconnected)
        now = at(300)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        XCTAssertFalse(finish.inputs.stepsInterrupted)
        XCTAssertEqual(finish.inputs.activeSteps, 240 + 15 * 20)
    }

    func testTheSummaryClaimsACalibrationOnlyWhenOneWasStored() async throws {
        let rig = makeRig()
        rig.recorder.start()
        rig.source.counter(0, at: at(0))
        _ = await run(rig, from: 0, to: 300, counter: 0)   // 600 steps
        now = at(300)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        finish.submit(typedMeters: 6_000, inclinePercent: nil)   // 10 m a step: refused
        await finish.writeTask?.value
        XCTAssertFalse(finish.calibrationStored)
        let notes = IndoorRunSummarySection.notes(finish)
        XCTAssertFalse(notes.contains { $0.contains("calibrated from it") })
        XCTAssertTrue(notes.contains { $0.contains("your stride wasn't changed") })

        let calibrated = makeRig()
        calibrated.recorder.start()
        calibrated.source.counter(0, at: at(300))
        _ = await run(calibrated, from: 300, to: 600, counter: 0)
        now = at(600)
        await calibrated.recorder.end()
        let ok = try XCTUnwrap(calibrated.recorder.indoorRun)
        ok.submit(typedMeters: 720, inclinePercent: nil)
        await ok.writeTask?.value
        XCTAssertTrue(ok.calibrationStored)
        XCTAssertTrue(IndoorRunSummarySection.notes(ok).contains { $0.contains("calibrated from it") })
    }

    func testATypedDistanceWithNoStepsNeverSaysThereIsNoDistance() async throws {
        let source = StepSource(timeline: timeline)
        source.hasSteps = false
        let rig = makeRig(source: source)
        rig.recorder.start()
        now = at(300)
        await rig.recorder.end()
        let finish = try XCTUnwrap(rig.recorder.indoorRun)
        XCTAssertTrue(IndoorRunSummarySection.notes(finish).contains { $0.contains("no distance estimate") })
        finish.submit(typedMeters: 900, inclinePercent: nil)
        await finish.writeTask?.value
        let notes = IndoorRunSummarySection.notes(finish)
        XCTAssertFalse(notes.contains { $0.contains("no distance") })
        XCTAssertTrue(notes.contains { $0.hasPrefix("Distance as you typed it") })
    }

    // MARK: The ring (84a)

    func testTheRingsIndoorStepsAreDeltasOfItsRunningSportTotalAcrossAReconnectAndAPause() {
        var tracker = IndoorStepTracker(sport: .runningIndoor, stride: IndoorStride(meters: 1, source: .height))
        // (carried from sessions left behind, the current session's live `0x4e` sum, running)
        let readings: [(Int, Int, Bool)] = [
            (0, 0, true),       // SportStart: the base
            (0, 120, true),     // +120
            (120, 0, true),     // a reconnect's new session counts from 0; the total stays 120
            (120, 50, true),    // +50
            (120, 80, false),   // paused: the base moves, nothing counts
            (120, 90, true),    // +10 after the resume
        ]
        for (i, reading) in readings.enumerated() {
            tracker.observe(WorkoutSessionManager.indoorStepReading(carried: reading.0, sessionSteps: reading.1),
                            at: at(Double(i * 10)), running: reading.2)
        }
        XCTAssertEqual(tracker.log.total, 180)
        XCTAssertEqual(tracker.estimatedMeters, 180)
        XCTAssertEqual(tracker.counter.resets, 0, "a reconnect is not a reset")
    }

    // MARK: Apple Health types (84f)

    func testRunningSpeedAndStrideStayOutOfTheMainRequest() {
        let writer = HealthKitWriter()
        for type in [HKQuantityType(.runningSpeed), HKQuantityType(.runningStrideLength)] {
            XCTAssertFalse(writer.allTypes.contains(type), "\(type) is asked lazily, never at launch")
            XCTAssertFalse(writer.authorizationReadTypes.contains(type))
        }
        XCTAssertEqual(IndoorRunHealthWriter.runningSpeedType, HKQuantityType(.runningSpeed))
        XCTAssertEqual(IndoorRunHealthWriter.runningStrideLengthType, HKQuantityType(.runningStrideLength))
    }
}
