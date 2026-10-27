import Foundation
import Observation
import OpenCircuitKit

// Indoor runs and walks (#339, decision 84): steps → cadence and a step-based distance, then at End the
// summary's "Treadmill distance?" / "Incline %" prompt, the Apple Health writes and the indoor VO₂ max.
// Shared by both devices: the strap's recorder (`StrapWorkoutRecorder`, realtime steps on `0x0016`) and
// the ring's (`WorkoutSessionManager`, its `0x4e` sport steps). Each recorder counts the steps
// (`IndoorStepTracker`) and, at End, hands one `IndoorRunFinish` to the summary.
//
// When the workout is saved (decision 84j, which replaces 84e's "at End" for this one case): an indoor run
// or walk WITH STEPS saves its `HKWorkout` when the person answers or skips the distance prompt, dismisses
// the summary, or 10 minutes after End, whichever comes first, so the workout's own total distance is the
// typed one when given (else the step estimate, `OpenCircuitEstimated = true`). Every other workout, and
// an indoor one without steps, saves at End as before (82a). A distance typed after an estimate save
// replaces the estimate's samples (`IndoorRunHealthWriter.replaceEstimate`).

/// Our metadata key on every sample computed from a step estimate (decision 84f).
enum IndoorRunMetadata {
    static let estimatedKey = "OpenCircuitEstimated"
}

/// The workout's distance from steps, handed to the workout's own Health write (`StrapWorkoutWrite`,
/// `WorkoutSessionManager.writeWorkout`).
struct IndoorDistanceWrite: Equatable {
    let meters: Double
    /// The person typed it from the treadmill (decision 84j); false for the step estimate.
    var typed = false
}

/// The stride a typed distance calibrated, per device and sport (decision 84e): the next indoor run of
/// that sport on that device starts from it. UserDefaults, not SwiftData.
struct IndoorStrideCalibrations {
    nonisolated static let key = "workout.indoorStride.v1"
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func slot(_ timeline: SyncDeviceID, _ sport: WorkoutSportType) -> String {
        "\(timeline.rawValue)|\(sport.rawValue)"
    }

    func stride(timeline: SyncDeviceID, sport: WorkoutSportType) -> Double? {
        (defaults.dictionary(forKey: Self.key) as? [String: Double])?[Self.slot(timeline, sport)]
    }

    func store(_ meters: Double, timeline: SyncDeviceID, sport: WorkoutSportType) {
        var all = (defaults.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
        all[Self.slot(timeline, sport)] = meters
        defaults.set(all, forKey: Self.key)
    }
}

/// The height the person set in Profile; nil while they never set one (the 170 cm placeholder is not
/// a height, the way the 35 placeholder is not an age).
enum IndoorRunProfile {
    static func userSetHeightCm(_ defaults: UserDefaults = .standard) -> Double? {
        guard let cm = defaults.object(forKey: "userProfile.heightCm") as? Double, cm > 0 else { return nil }
        return cm
    }
}

/// Counts one workout's steps from a running counter (decision 84c, 84d). The recorders feed it every
/// counter reading with whether the workout is running at that instant; it never decides that itself.
struct IndoorStepTracker {
    let sport: WorkoutSportType
    /// The stride at the start: a stored calibration, else the person's height × the sport's factor.
    let stride: IndoorStride?
    private(set) var counter = StepCounterDeltas()
    private(set) var log = WorkoutStepLog()
    /// Since when steps have counted without a break (start, resume, reconnect), for the live cadence.
    private(set) var countingSince: Date?

    init(sport: WorkoutSportType, stride: IndoorStride?) {
        self.sport = sport
        self.stride = stride
    }

    /// One counter reading. `running`: the workout is running (not paused, the link up).
    mutating func observe(_ reading: Int, at date: Date, running: Bool) {
        let steps = counter.observe(reading, counting: running)
        log.add(steps, at: date)
        if running, countingSince == nil { countingSince = date }
        if !running { countingSince = nil }
    }

    /// The next reading is a base (the stream was turned on again, the link came back, a pause began).
    mutating func rebase() {
        counter.rebase()
        countingSince = nil
    }

    func liveCadence(now: Date) -> Double? {
        guard let countingSince else { return nil }
        return log.liveCadence(now: now, countingSince: countingSince)
    }

    /// Active steps × stride (decision 84d), nil without steps or a stride.
    var estimatedMeters: Double? {
        guard let stride, log.total > 0 else { return nil }
        return stride.distance(steps: log.total)
    }
}

/// What a finished indoor workout needs after End: its steps, its active time, the estimate, and what
/// the VO₂ max estimate needs besides a typed distance.
struct IndoorRunInputs: Equatable {
    let sport: WorkoutSportType
    let timeline: SyncDeviceID
    let start: Date
    let end: Date
    let activeSeconds: TimeInterval
    /// The running stretches (pauses and link gaps left out), for the per-minute samples.
    let activeSegments: [DateInterval]
    let steps: WorkoutStepLog
    let stride: IndoorStride?
    /// The step stream stopped before End and didn't come back (the strap's link dropped: no `05 01`
    /// after a reconnect, decision 84b). The steps cover only part of the run.
    let stepsInterrupted: Bool
    let heartRate: [HRSample]
    let age: Int?
    let restingHR: Double?

    var activeSteps: Int { steps.total }
    var estimatedMeters: Double? {
        guard let stride, activeSteps > 0 else { return nil }
        return stride.distance(steps: activeSteps)
    }
}

/// One minute's running speed and stride length for Apple Health (decision 84f).
struct IndoorRunMinuteSample: Equatable {
    let start: Date
    let end: Date
    /// Metres per second.
    let speed: Double
    /// Metres.
    let strideLength: Double
}

enum IndoorRunHealthStatus: Equatable {
    case saved
    /// Apple Health isn't connected (the main grant is missing): nothing was asked or written.
    case notConnected
    /// The person declined or turned off this type for OpenCircuit.
    case sharingOff
    case failed
    /// The typed distance is saved, but the estimate could not be removed: Health holds both
    /// (review-indoor-run SF2a; the estimate is deleted only AFTER the typed save succeeded).
    case savedEstimateKept
}

/// The Apple Health half of an indoor run beyond the workout's own write (decision 84f, 84g).
@MainActor
protocol IndoorRunHealthWriting: AnyObject {
    /// Per-minute running speed and stride length, each type asked lazily in its own one-type request.
    func saveRunningMetrics(_ minutes: [IndoorRunMinuteSample], estimated: Bool,
                            timeline: SyncDeviceID) async -> IndoorRunHealthStatus
    /// The typed distance replaces the step estimate: this app's estimated distance, speed and stride
    /// samples inside `workout` are deleted, and the typed distance is saved for the workout.
    func replaceEstimate(workout: DateInterval, typedMeters: Double, timeline: SyncDeviceID) async -> IndoorRunHealthStatus
    func saveVO2Max(_ estimate: VO2MaxEstimate.Estimate, workoutEnd: Date, timeline: SyncDeviceID) async -> VO2MaxHealthWriter.Status
}

/// The summary's indoor-run state and its actions, `submit` and `skip` (decision 84e–84g, 84j). One per
/// finished indoor workout, owned by the recorder that ended it.
@Observable
@MainActor
final class IndoorRunFinish {
    /// What ended the wait for the workout's save (decision 84j).
    enum SaveTrigger: Equatable {
        case answered, skipped, dismissed, timedOut
    }

    /// How long after End a waiting workout saves on its own (decision 84j).
    static let saveDeadline: TimeInterval = 10 * 60

    let inputs: IndoorRunInputs
    /// The typed distance, once submitted (metres).
    private(set) var typedMeters: Double?
    private(set) var inclinePercent: Double?
    /// The stride the summary's numbers use now: the typed calibration once submitted.
    private(set) var stride: IndoorStride?
    /// The typed distance's stride was stored for the next indoor run of this sport on this device
    /// (false when it was refused: an implausible ratio, or a step stream cut short).
    private(set) var calibrationStored = false
    /// The workout's own Health write: nil while it waits for the prompt (84j), then whether it committed.
    private(set) var workoutSaved: Bool?
    private(set) var saveTrigger: SaveTrigger?
    /// Per-minute speed and stride to Health: nil while in flight or not attempted.
    private(set) var runningMetricsStatus: IndoorRunHealthStatus?
    /// The typed distance's Health write: nil while in flight or before a submit.
    private(set) var distanceStatus: IndoorRunHealthStatus?
    /// The indoor VO₂ max (indoor runs only): `.skipped(.noTypedDistance)` until a distance is typed.
    private(set) var vo2MaxOutcome: VO2MaxEstimate.Outcome?
    private(set) var vo2MaxHealthStatus: VO2MaxHealthWriter.Status?
    /// The Health writes, for tests to await.
    @ObservationIgnored private(set) var writeTask: Task<Void, Never>?
    /// The recorder's deferred workout save (84j): the typed distance in metres, or nil for the estimate.
    /// It reports back through `workoutSaveFinished(saved:)`.
    @ObservationIgnored var saveWorkout: (@MainActor (Double?) -> Void)?

    @ObservationIgnored private let health: (any IndoorRunHealthWriting)?
    @ObservationIgnored private let calibrations: IndoorStrideCalibrations
    /// The stride the typed distance gave, when it may be used for the per-minute samples.
    @ObservationIgnored private var typedStride: IndoorStride?

    /// `workoutSaved`: the result of a save made at End, or nil when the save waits for the prompt.
    init(inputs: IndoorRunInputs, workoutSaved: Bool?, health: (any IndoorRunHealthWriting)?,
         calibrations: IndoorStrideCalibrations) {
        self.inputs = inputs
        self.workoutSaved = workoutSaved
        self.health = health
        self.calibrations = calibrations
        stride = inputs.stride
        if inputs.sport == .runningIndoor { vo2MaxOutcome = Self.vo2(inputs, typed: nil, incline: nil) }
    }

    /// The distance on the summary: typed, else the step estimate (labelled "est.").
    var distanceMeters: Double? { typedMeters ?? inputs.estimatedMeters }
    var distanceIsEstimate: Bool { typedMeters == nil }
    var submitted: Bool { typedMeters != nil }
    /// The workout waits for the prompt before it is saved (84j).
    var savePending: Bool { workoutSaved == nil }
    /// The prompt is offered until a distance is typed or the person skipped it.
    var promptOpen: Bool { !submitted && saveTrigger != .skipped }

    var averageCadence: Double? { inputs.steps.averageCadence(activeSeconds: inputs.activeSeconds) }

    /// Whole running minutes and their cadence (steps per minute).
    var minuteCadence: [WorkoutStepLog.Minute] {
        inputs.steps.minutes(start: inputs.start, end: inputs.end, active: inputs.activeSegments)
            .filter(\.wholeInActiveTime)
    }

    /// After a save made at End: the per-minute speed and stride for an indoor RUN from the estimated
    /// stride, marked estimated. Never before the workout is saved, never for a walk.
    func writeEstimateMetrics() {
        guard workoutSaved == true, IndoorStepWorkout.writesRunningMetrics(inputs.sport),
              let stride = inputs.stride, let health else { return }
        let minutes = Self.minuteSamples(inputs, stride: stride.meters)
        guard !minutes.isEmpty else { return }
        let timeline = inputs.timeline
        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            let status = await health.saveRunningMetrics(minutes, estimated: true, timeline: timeline)
            // A submit that already replaced them owns the status now.
            guard let self, !self.submitted else { return }
            self.runningMetricsStatus = status
        }
    }

    /// The prompt's answer (decision 84e). A typed distance replaces the estimate: the summary, the stride
    /// stored for the next indoor run of this sport on this device, the per-minute samples, (indoor run)
    /// the VO₂ max, and the workout's distance in Health: saved WITH the workout when it is still waiting
    /// (84j), else replacing the estimate's samples. Once per workout.
    func submit(typedMeters: Double, inclinePercent: Double?) {
        guard !submitted, typedMeters > 0 else { return }
        let incline = inclinePercent.flatMap { IndoorRunEntry.inclineRange.contains($0) ? $0 : nil }
        self.typedMeters = typedMeters
        self.inclinePercent = incline
        let calibrated = IndoorStride.calibrate(typedMeters: typedMeters, activeSteps: inputs.activeSteps)
        // A run whose step stream was cut short has too few steps for the typed distance: its ratio is
        // not a stride, so it is never stored, and the minutes keep the estimated stride.
        typedStride = inputs.stepsInterrupted ? nil : calibrated
        if let typedStride {
            stride = typedStride
            calibrations.store(typedStride.meters, timeline: inputs.timeline, sport: inputs.sport)
            calibrationStored = true
        }
        if inputs.sport == .runningIndoor {
            vo2MaxOutcome = inputs.stepsInterrupted
                ? .skipped(.noStepData)
                : Self.vo2(inputs, typed: typedMeters, incline: incline)
        }
        if savePending {
            requestSave(.answered)
            return
        }
        // The workout isn't in Health, so nothing describing it is written (the VO₂ max rule).
        if workoutSaved == false, case .estimate? = vo2MaxOutcome { vo2MaxHealthStatus = .failed }
        guard workoutSaved == true, let health else { return }
        let inputs = inputs
        let vo2 = vo2MaxOutcome
        let typedStride = typedStride
        let strideForMinutes = typedStride ?? inputs.stride
        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            let workout = DateInterval(start: inputs.start, end: max(inputs.end, inputs.start))
            let distance = await health.replaceEstimate(workout: workout, typedMeters: typedMeters, timeline: inputs.timeline)
            var metrics: IndoorRunHealthStatus?
            // Review-indoor-run SF2b: only once the estimate is gone. A replace that failed (or left the
            // estimate in place) keeps the estimated speed/stride, so a second set is never added.
            if distance == .saved, IndoorStepWorkout.writesRunningMetrics(inputs.sport), let strideForMinutes {
                let minutes = Self.minuteSamples(inputs, stride: strideForMinutes.meters)
                if !minutes.isEmpty {
                    metrics = await health.saveRunningMetrics(minutes, estimated: typedStride == nil, timeline: inputs.timeline)
                }
            }
            var vo2Status: VO2MaxHealthWriter.Status?
            if case .estimate(let estimate)? = vo2 {
                vo2Status = await health.saveVO2Max(estimate, workoutEnd: inputs.end, timeline: inputs.timeline)
            }
            guard let self else { return }
            self.distanceStatus = distance
            self.runningMetricsStatus = metrics
            self.vo2MaxHealthStatus = vo2Status
        }
    }

    /// "Skip" on the prompt (84j): the waiting workout is saved now, with the step estimate.
    func skip() {
        guard savePending, !submitted else { return }
        requestSave(.skipped)
    }

    /// The summary was dismissed, or 10 minutes passed since End (84j): a waiting workout is saved now
    /// with the step estimate. A no-op once it is saved.
    func endWait(_ trigger: SaveTrigger) {
        guard savePending else { return }
        requestSave(trigger)
    }

    private func requestSave(_ trigger: SaveTrigger) {
        guard savePending, saveTrigger == nil else { return }
        saveTrigger = trigger
        saveWorkout?(trigger == .answered ? typedMeters : nil)
    }

    /// The recorder's deferred save committed (or not). Then, and only then, what describes the workout
    /// goes to Health: the per-minute speed and stride (indoor run) and the VO₂ max.
    func workoutSaveFinished(saved: Bool) {
        guard savePending else { return }
        workoutSaved = saved
        guard saved else {
            if case .estimate? = vo2MaxOutcome { vo2MaxHealthStatus = .failed }
            return
        }
        if submitted { distanceStatus = .saved }
        guard let health else { return }
        let inputs = inputs
        let vo2 = vo2MaxOutcome
        let typedStride = submitted ? self.typedStride : nil
        let strideForMinutes = typedStride ?? inputs.stride
        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            var metrics: IndoorRunHealthStatus?
            if IndoorStepWorkout.writesRunningMetrics(inputs.sport), let strideForMinutes {
                let minutes = Self.minuteSamples(inputs, stride: strideForMinutes.meters)
                if !minutes.isEmpty {
                    metrics = await health.saveRunningMetrics(minutes, estimated: typedStride == nil, timeline: inputs.timeline)
                }
            }
            var vo2Status: VO2MaxHealthWriter.Status?
            if case .estimate(let estimate)? = vo2 {
                vo2Status = await health.saveVO2Max(estimate, workoutEnd: inputs.end, timeline: inputs.timeline)
            }
            guard let self else { return }
            if metrics != nil { self.runningMetricsStatus = metrics }
            if vo2Status != nil { self.vo2MaxHealthStatus = vo2Status }
        }
    }

    /// Per-minute speed and stride (decision 84f): only whole minutes inside the running time, and only
    /// minutes with steps. Speed = that minute's steps × stride ÷ 60 s.
    static func minuteSamples(_ inputs: IndoorRunInputs, stride: Double) -> [IndoorRunMinuteSample] {
        inputs.steps.minutes(start: inputs.start, end: inputs.end, active: inputs.activeSegments)
            .filter { $0.wholeInActiveTime && $0.steps > 0 }
            .map { IndoorRunMinuteSample(start: $0.start, end: $0.end, speed: Double($0.steps) * stride / 60,
                                         strideLength: stride) }
    }

    static func vo2(_ inputs: IndoorRunInputs, typed: Double?, incline: Double?) -> VO2MaxEstimate.Outcome {
        VO2MaxEstimate.estimateIndoor(VO2MaxEstimate.IndoorInput(
            sport: inputs.sport, start: inputs.start, end: inputs.end, activeSeconds: inputs.activeSeconds,
            heartRate: inputs.heartRate, steps: inputs.steps.deltas, typedDistance: typed,
            inclinePercent: incline, age: inputs.age, restingHR: inputs.restingHR))
    }
}
