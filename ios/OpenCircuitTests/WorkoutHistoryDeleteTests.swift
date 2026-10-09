import HealthKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Workout history, detail and delete (#293): undoing a deleted workout's credits, the tombstone on
// every path that offers a past workout back, the deletion's order and partial failures, and the
// detail screen's pure selection/formatting. Every value is synthetic.

private let cal = Calendar.current
/// Noon local, so "today" never straddles midnight in any time zone the suite runs in.
private let noon = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12))!
private func at(_ minutes: Double, from base: Date = noon) -> Date { base.addingTimeInterval(minutes * 60) }
private let yesterdayNoon = cal.date(byAdding: .day, value: -1, to: noon)!

private func suite() -> UserDefaults {
    UserDefaults(suiteName: "workout-history-tests-\(UUID().uuidString)")!
}

// MARK: - Credit undo (HealthKitWriter)

@MainActor
final class WorkoutCreditUndoTests: XCTestCase {
    private var defaults: UserDefaults!
    override func setUp() async throws { defaults = suite() }

    private var kcalCredit: Double { defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey) }
    private var kcalConsumed: Double { defaults.double(forKey: HealthKitWriter.activeWorkoutCreditedKey) }

    /// The active-energy flush has netted `kcal` of today's credit (what `flushAttributedActiveCalories`
    /// persists after a write).
    private func markConsumed(_ kcal: Double, now: Date = noon) {
        defaults.set(cal.startOfDay(for: now).timeIntervalSince1970, forKey: HealthKitWriter.activeWorkoutCreditedDayKey)
        defaults.set(kcal, forKey: HealthKitWriter.activeWorkoutCreditedKey)
    }

    func testUndoingAWorkoutsKcalLeavesTheOtherWorkoutsCredit() {
        HealthKitWriter.recordWorkoutActiveKcal(120, day: at(-60), defaults)
        HealthKitWriter.recordWorkoutActiveKcal(80, day: at(-10), defaults)
        XCTAssertTrue(HealthKitWriter.undoWorkoutActiveKcal(120, day: at(-60), now: noon, defaults))
        XCTAssertEqual(kcalCredit, 80, accuracy: 1e-9)
    }

    func testUndoingKcalLowersTheConsumedMarkSoWhatIsStillOwedIsUnchanged() {
        HealthKitWriter.recordWorkoutActiveKcal(120, day: at(-60), defaults)
        HealthKitWriter.recordWorkoutActiveKcal(80, day: at(-10), defaults)
        markConsumed(150)
        let owedBefore = kcalCredit - kcalConsumed
        HealthKitWriter.undoWorkoutActiveKcal(120, day: at(-60), now: noon, defaults)
        XCTAssertEqual(kcalConsumed, 30, accuracy: 1e-9)
        XCTAssertEqual(kcalCredit - kcalConsumed, owedBefore, accuracy: 1e-9,
                       "the other workout's unnetted part is still netted on the next flush")
    }

    func testTheConsumedMarkNeverExceedsTheCreditAfterAnUndo() {
        HealthKitWriter.recordWorkoutActiveKcal(120, day: at(-60), defaults)
        markConsumed(120)
        HealthKitWriter.undoWorkoutActiveKcal(120, day: at(-60), now: noon, defaults)
        XCTAssertEqual(kcalCredit, 0, accuracy: 1e-9)
        XCTAssertEqual(kcalConsumed, 0, accuracy: 1e-9,
                       "a later workout today must be netted, not hidden behind a stale consumed mark")
    }

    func testUndoingMoreThanWasCreditedStopsAtZero() {
        HealthKitWriter.recordWorkoutActiveKcal(50, day: at(-10), defaults)
        HealthKitWriter.undoWorkoutActiveKcal(80, day: at(-10), now: noon, defaults)
        XCTAssertEqual(kcalCredit, 0, accuracy: 1e-9)
    }

    func testAWorkoutFromAnotherDayUndoesNothing() {
        HealthKitWriter.recordWorkoutActiveKcal(120, day: at(-10), defaults)
        XCTAssertFalse(HealthKitWriter.undoWorkoutActiveKcal(120, day: yesterdayNoon, now: noon, defaults))
        XCTAssertEqual(kcalCredit, 120, accuracy: 1e-9)
    }

    func testYesterdaysCreditSlotIsNotTouchedToday() {
        HealthKitWriter.recordWorkoutActiveKcal(120, day: yesterdayNoon, defaults)
        XCTAssertFalse(HealthKitWriter.undoWorkoutActiveKcal(120, day: noon, now: noon, defaults))
        XCTAssertEqual(kcalCredit, 120, accuracy: 1e-9)
    }

    func testRemovingACreditedSpanDropsOnlyThatSpan() {
        HealthKitWriter.recordWorkoutCreditedSpan(start: at(-90), end: at(-60), now: noon, defaults)
        HealthKitWriter.recordWorkoutCreditedSpan(start: at(-40), end: at(-10), now: noon, defaults)
        // Health hands dates back through its own storage: a sub-second difference is the same span.
        XCTAssertTrue(HealthKitWriter.removeWorkoutCreditedSpan(start: at(-90).addingTimeInterval(0.3),
                                                                end: at(-60).addingTimeInterval(-0.3),
                                                                now: noon, defaults))
        XCTAssertEqual(HealthKitWriter.workoutCreditedSpans(day: noon, defaults),
                       [DateInterval(start: at(-40), end: at(-10))])
    }

    func testRemovingASpanThatWasNeverCreditedChangesNothing() {
        HealthKitWriter.recordWorkoutCreditedSpan(start: at(-40), end: at(-10), now: noon, defaults)
        XCTAssertFalse(HealthKitWriter.removeWorkoutCreditedSpan(start: at(-90), end: at(-60), now: noon, defaults))
        XCTAssertEqual(HealthKitWriter.workoutCreditedSpans(day: noon, defaults).count, 1)
    }

    func testUndoingWalkRunDistanceLowersTheTotalAndTheNettedMark() {
        HealthKitWriter.recordWorkoutWalkRunDistance(5_000, now: noon, defaults)
        HealthKitWriter.recordWorkoutWalkRunDistance(2_000, now: noon, defaults)
        defaults.set(cal.startOfDay(for: noon).timeIntervalSince1970, forKey: HealthKitWriter.estimateGPSCreditedDayKey)
        defaults.set(6_000.0, forKey: HealthKitWriter.estimateGPSCreditedMetersKey)
        XCTAssertTrue(HealthKitWriter.undoWorkoutWalkRunDistance(5_000, now: noon, defaults))
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutWalkRunDistanceMetersKey), 2_000, accuracy: 1e-9)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.estimateGPSCreditedMetersKey), 1_000, accuracy: 1e-9)
    }

    func testYesterdaysDistanceSlotIsNotTouchedToday() {
        HealthKitWriter.recordWorkoutWalkRunDistance(5_000, now: yesterdayNoon, defaults)
        XCTAssertFalse(HealthKitWriter.undoWorkoutWalkRunDistance(5_000, now: noon, defaults))
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutWalkRunDistanceMetersKey), 5_000, accuracy: 1e-9)
    }
}

// MARK: - Deletion

@MainActor
private final class FakeWorkoutHealth: WorkoutHealthDeleting {
    var failSamples = false
    var failWorkout = false
    /// Kept readings HealthKit "removed" with the workout and that could not be saved back.
    var lostReadings = 0
    private(set) var calls: [String] = []
    func deleteOwnedSamples(ofWorkout id: UUID) async throws {
        calls.append("samples")
        if failSamples { throw CocoaError(.featureUnsupported) }
    }
    func deleteWorkout(_ id: UUID) async throws -> Int {
        calls.append("workout")
        if failWorkout { throw CocoaError(.featureUnsupported) }
        return lostReadings
    }
}

@MainActor
final class WorkoutDeleterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var tombstones: WorkoutTombstones!
    private var health: FakeWorkoutHealth!
    override func setUp() async throws {
        defaults = suite()
        tombstones = WorkoutTombstones(suite())
        health = FakeWorkoutHealth()
    }

    private var deleter: WorkoutDeleter {
        WorkoutDeleter(health: health, tombstones: tombstones, defaults: defaults, now: { noon })
    }

    /// A walk that ended 10 minutes ago and was credited the way `writeWorkout` credits it.
    private let walk = WorkoutDeleter.Target(id: UUID(), start: at(-40), end: at(-10),
                                             activeKcal: 150, walkRunMeters: 3_000)

    private func creditAsTheWritePathDoes(_ t: WorkoutDeleter.Target) {
        HealthKitWriter.recordWorkoutWalkRunDistance(t.walkRunMeters ?? 0, now: noon, defaults)
        HealthKitWriter.recordWorkoutActiveKcal(t.activeKcal ?? 0, day: t.end, defaults)
        HealthKitWriter.recordWorkoutCreditedSpan(start: t.start, end: t.end, now: noon, defaults)
    }

    func testADeleteRemovesTheSamplesBeforeTheWorkoutThenRecordsItAndUndoesTodaysCredits() async {
        creditAsTheWritePathDoes(walk)
        let outcome = await deleter.delete(walk)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(health.calls, ["samples", "workout"])
        XCTAssertTrue(tombstones.suppresses(start: walk.start, end: walk.end))
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 0, accuracy: 1e-9)
        XCTAssertTrue(HealthKitWriter.workoutCreditedSpans(day: noon, defaults).isEmpty)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutWalkRunDistanceMetersKey), 0, accuracy: 1e-9)
        XCTAssertEqual(defaults.integer(forKey: HealthKitWriter.workoutCreditsRevisionKey), 1,
                       "the dashboard's cached estimates are told to recompute")
    }

    func testWhenHealthKeepsTheSamplesNothingLocalChanges() async {
        creditAsTheWritePathDoes(walk)
        health.failSamples = true
        let outcome = await deleter.delete(walk)
        XCTAssertEqual(outcome, .samplesNotDeleted)
        XCTAssertNotNil(outcome.failureMessage)
        XCTAssertEqual(health.calls, ["samples"], "the workout is never deleted without its samples")
        XCTAssertTrue(tombstones.entries.isEmpty)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 150, accuracy: 1e-9)
        XCTAssertEqual(HealthKitWriter.workoutCreditedSpans(day: noon, defaults).count, 1)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutWalkRunDistanceMetersKey), 3_000, accuracy: 1e-9)
    }

    func testWhenHealthKeepsTheWorkoutNothingLocalChanges() async {
        creditAsTheWritePathDoes(walk)
        health.failWorkout = true
        let outcome = await deleter.delete(walk)
        XCTAssertEqual(outcome, .workoutNotDeleted)
        XCTAssertNotNil(outcome.failureMessage)
        XCTAssertTrue(tombstones.entries.isEmpty)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 150, accuracy: 1e-9)
        XCTAssertEqual(HealthKitWriter.workoutCreditedSpans(day: noon, defaults).count, 1)
        XCTAssertEqual(defaults.integer(forKey: HealthKitWriter.workoutCreditsRevisionKey), 0)
    }

    func testARetryAfterAPartialFailureUndoesTheCreditExactlyOnce() async {
        let run = WorkoutDeleter.Target(id: UUID(), start: at(-120), end: at(-90), activeKcal: 200, walkRunMeters: nil)
        creditAsTheWritePathDoes(walk)
        creditAsTheWritePathDoes(run)
        health.failWorkout = true
        _ = await deleter.delete(run)
        health.failWorkout = false
        let outcome = await deleter.delete(run)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 150, accuracy: 1e-9,
                       "only the run's 200 comes off; the walk's 150 is still netted")
        XCTAssertEqual(HealthKitWriter.workoutCreditedSpans(day: noon, defaults),
                       [DateInterval(start: walk.start, end: walk.end)])
    }

    func testDeletingAnOlderWorkoutRecordsItButLeavesTodaysCreditsAlone() async {
        creditAsTheWritePathDoes(walk)
        let old = WorkoutDeleter.Target(id: UUID(), start: at(-40, from: yesterdayNoon), end: at(-10, from: yesterdayNoon),
                                        activeKcal: 150, walkRunMeters: 3_000)
        let outcome = await deleter.delete(old)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertTrue(tombstones.suppresses(start: old.start, end: old.end))
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 150, accuracy: 1e-9)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutWalkRunDistanceMetersKey), 3_000, accuracy: 1e-9)
        XCTAssertEqual(HealthKitWriter.workoutCreditedSpans(day: noon, defaults).count, 1)
    }

    func testAWorkoutThatWasNeverCreditedChangesNoCredit() async {
        // Today's credit belongs to the walk; this workout's energy never landed (no credit banked).
        creditAsTheWritePathDoes(walk)
        let uncredited = WorkoutDeleter.Target(id: UUID(), start: at(-200), end: at(-170), activeKcal: nil, walkRunMeters: nil)
        _ = await deleter.delete(uncredited)
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 150, accuracy: 1e-9)
        XCTAssertEqual(HealthKitWriter.workoutCreditedSpans(day: noon, defaults).count, 1)
    }

    func testTheConfirmationNamesWhatGoesAndSaysHeartRateIsKept() {
        let message = WorkoutDeleter.confirmationMessage
        for removed in ["workout", "calorie estimate", "distance", "route", "Apple Health"] {
            XCTAssertTrue(message.contains(removed), "names \(removed)")
        }
        XCTAssertTrue(message.contains("Heart-rate readings and steps are kept"))
    }

    func testReadingsThatCouldNotBePutBackStillCountAsADeleteButAreReported() async {
        creditAsTheWritePathDoes(walk)
        health.lostReadings = 3
        let outcome = await deleter.delete(walk)
        XCTAssertEqual(outcome, .deletedLosingReadings(3))
        XCTAssertTrue(outcome.removedWorkout, "the workout is gone, so the row goes")
        XCTAssertEqual(outcome.failureTitle, "Workout deleted")
        XCTAssertTrue(outcome.failureMessage?.contains("3 heart-rate or step readings") ?? false)
        XCTAssertTrue(tombstones.suppresses(start: walk.start, end: walk.end))
        XCTAssertEqual(defaults.double(forKey: HealthKitWriter.workoutActiveKcalKey), 0, accuracy: 1e-9)
    }

    func testFailedDeletesKeepTheRowAndSaySo() {
        for outcome in [WorkoutDeleter.Outcome.samplesNotDeleted, .workoutNotDeleted] {
            XCTAssertFalse(outcome.removedWorkout)
            XCTAssertEqual(outcome.failureTitle, "Workout not fully deleted")
        }
        XCTAssertTrue(WorkoutDeleter.Outcome.samplesNotDeleted.failureMessage?.contains("did not remove") ?? false)
        XCTAssertTrue(WorkoutDeleter.Outcome.deleted.removedWorkout)
        XCTAssertNil(WorkoutDeleter.Outcome.deleted.failureMessage)
    }
}

// MARK: - What the HealthKit layer deletes (review-293 SF2)

@MainActor
final class WorkoutHealthDeleteScopeTests: XCTestCase {
    func testTheWorkoutsOwnSamplesIncludeTheRouteAndNeverAMeasurement() {
        let owned = HealthKitWorkoutStore.ownedSampleTypes
        XCTAssertTrue(owned.contains(HKSeriesType.workoutRoute()), "the route goes with the workout")
        XCTAssertTrue(owned.contains(HKQuantityType(.activeEnergyBurned)))
        XCTAssertTrue(owned.contains(HKQuantityType(.distanceWalkingRunning)))
        XCTAssertTrue(owned.contains(HKQuantityType(.distanceCycling)))
        XCTAssertEqual(owned.count, 4)
        for kept in HealthKitWorkoutStore.keptSampleTypes {
            XCTAssertFalse(owned.contains(kept), "\(kept) is a measurement and is never deleted")
        }
        XCTAssertEqual(Set(HealthKitWorkoutStore.keptSampleTypes),
                       [HKQuantityType(.heartRate), HKQuantityType(.stepCount)])
    }

    func testSamplesAreMatchedByWorkoutAndSourceNeverByTime() {
        let start = Date(timeIntervalSince1970: 1_758_369_600)
        let workout = HKWorkout(activityType: .walking, start: start, end: start.addingTimeInterval(1_800))
        // Stand-in for the source predicate: `HKSource.default()` can't be built in an unsigned test host.
        let ourSource = NSPredicate(format: "sourceStandIn == 1")
        let predicate = HealthKitWorkoutStore.savedWith(workout, ourSource: ourSource)
        guard let compound = predicate as? NSCompoundPredicate else { return XCTFail("compound expected") }
        XCTAssertEqual(compound.compoundPredicateType, .and)
        let expected = [HKQuery.predicateForObjects(from: workout), ourSource]
        XCTAssertEqual(compound.subpredicates.count, 2)
        for (got, want) in zip(compound.subpredicates.compactMap { $0 as? NSPredicate }, expected) {
            XCTAssertEqual(got.predicateFormat, want.predicateFormat)
        }
        XCTAssertFalse(predicate.predicateFormat.contains(HKPredicateKeyPathStartDate),
                       "a time window would also catch the daily energy flush and other workouts")
        XCTAssertFalse(predicate.predicateFormat.contains(HKPredicateKeyPathEndDate))
    }

    func testOnlyReadingsNotFoundAgainAreSavedBack() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(HealthKitWorkoutStore.removedWithWorkout(kept: [a, b, c], stillPresent: [a, b, c]), [],
                       "HealthKit kept them: nothing is written twice")
        XCTAssertEqual(HealthKitWorkoutStore.removedWithWorkout(kept: [a, b, c], stillPresent: []), [a, b, c])
        XCTAssertEqual(HealthKitWorkoutStore.removedWithWorkout(kept: [a, b, c], stillPresent: [b]), [a, c])
    }
}

// MARK: - Tombstones on every offer path

@MainActor
final class WorkoutTombstoneTests: XCTestCase {
    private var tombstones: WorkoutTombstones!
    override func setUp() async throws { tombstones = WorkoutTombstones(suite()) }

    func testOverlapIsSuppressedAndADisjointWindowIsNot() {
        tombstones.record(start: at(-40), end: at(-10))
        XCTAssertTrue(tombstones.suppresses(start: at(-45), end: at(-30)))
        XCTAssertTrue(tombstones.suppresses(start: at(-20), end: at(5)))
        XCTAssertFalse(tombstones.suppresses(start: at(-90), end: at(-50)))
        XCTAssertFalse(tombstones.suppresses(start: at(0), end: at(30)))
    }

    func testRecordingTheSameWorkoutTwiceKeepsOneEntryAndTheListIsBounded() {
        tombstones.record(start: at(-40), end: at(-10))
        tombstones.record(start: at(-40), end: at(-10))
        XCTAssertEqual(tombstones.entries.count, 1)
        for i in 0..<(WorkoutTombstones.capacity + 5) {
            tombstones.record(start: at(Double(-10_000 + i * 60)), end: at(Double(-10_000 + i * 60 + 30)))
        }
        XCTAssertEqual(tombstones.entries.count, WorkoutTombstones.capacity)
        XCTAssertTrue(tombstones.suppresses(start: at(-40), end: at(-10)), "the newest are the ones kept")
    }

    // Ring: the detected-workout inbox.

    /// 70 ring sport records, one per 10 s, ending at `end`: a 700 s bout the detector reports.
    private func bout(endingAt end: Date) -> [HistoricalSportFrame.Sample] {
        let last = UInt32(end.timeIntervalSince1970 - TimeInterval(Command.syncEpoch))
        return (0..<70).map { i in
            HistoricalSportFrame.Sample(cursor: last - UInt32((69 - i) * 10), heartRate: 120, steps: 18)
        }
    }

    func testARingBoutOverADeletedWorkoutIsNotOfferedAgain() throws {
        let samples = bout(endingAt: at(-10))
        let offered = AutomaticWorkoutInbox.rebuild(
            existing: [], incoming: samples,
            resolvedSpans: RingSession.suppressedAutomaticWorkoutSpans(resolved: [], manual: [], tombstones: tombstones),
            now: noon)
        let candidate = try XCTUnwrap(offered.candidates.first, "offered before the delete")

        tombstones.record(start: candidate.start, end: candidate.end)
        let after = AutomaticWorkoutInbox.rebuild(
            existing: [], incoming: samples,
            resolvedSpans: RingSession.suppressedAutomaticWorkoutSpans(resolved: [], manual: [], tombstones: tombstones),
            now: noon)
        XCTAssertTrue(after.candidates.isEmpty)
    }

    // Ring: crash recovery.

    func testARingRecoveryOverADeletedWorkoutIsDiscarded() {
        let snapshot = WorkoutSessionSnapshot(sport: .walkingOutdoor, startDate: at(-40), lastAliveAt: at(-10),
                                              hrSampleCount: 0)
        guard case .offer = WorkoutSessionManager.recoveryDecision(snapshot: snapshot, tombstones: tombstones, now: noon) else {
            return XCTFail("offered before the delete")
        }
        tombstones.record(start: at(-41), end: at(-12))
        XCTAssertEqual(WorkoutSessionManager.recoveryDecision(snapshot: snapshot, tombstones: tombstones, now: noon),
                       .discard(.deletedByUser))
    }

    func testARingRecoveryNextToADeletedWorkoutIsStillOffered() {
        tombstones.record(start: at(-120), end: at(-90))
        let snapshot = WorkoutSessionSnapshot(sport: .walkingOutdoor, startDate: at(-40), lastAliveAt: at(-10),
                                              hrSampleCount: 0)
        guard case .offer = WorkoutSessionManager.recoveryDecision(snapshot: snapshot, tombstones: tombstones, now: noon) else {
            return XCTFail("a different workout is not suppressed")
        }
    }
}

// MARK: - Detail screen content

@MainActor
final class WorkoutDetailContentTests: XCTestCase {
    private func item(activity: HKWorkoutActivityType = .running, minutes: Double = 30,
                      kcal: Double? = nil, distance: Double? = nil, avgHR: Int? = nil, maxHR: Int? = nil,
                      pauses: [DateInterval] = [], start: Date = at(-60)) -> WorkoutHistoryReader.Item {
        WorkoutHistoryReader.Item(id: UUID(), activityType: activity, start: start,
                                  end: start.addingTimeInterval(minutes * 60), activeKcal: kcal,
                                  distanceMeters: distance, avgHR: avgHR,
                                  walkRunMeters: activity == .cycling ? nil : distance, maxHR: maxHR,
                                  pauses: pauses)
    }

    private func hr(_ bpms: [Int], from start: Date, every seconds: TimeInterval = 60) -> [HRSample] {
        bpms.enumerated().map { i, bpm in
            let s = start.addingTimeInterval(Double(i) * seconds)
            return HRSample(bpm: bpm, start: s, end: s.addingTimeInterval(1))
        }
    }

    func testPausesPairEachPauseWithTheNextResumeAndCloseAnOpenOneAtTheEnd() {
        let end = at(60)
        let pauses = WorkoutDetailContent.pauses(
            [.resume(at(1)), .pause(at(10)), .resume(at(15)), .pause(at(50))], end: end)
        XCTAssertEqual(pauses, [DateInterval(start: at(10), end: at(15)), DateInterval(start: at(50), end: end)])
    }

    func testAWorkoutWithNothingButItsTimeShowsOnlyDurationAndDevice() {
        let rows = WorkoutDetailContent.rows(item(), hr: [], age: 40, unit: .metric, recordedWith: "RingConn ring")
        XCTAssertEqual(rows.map(\.title), ["Duration", "Recorded with"])
        XCTAssertFalse(rows.contains { $0.value.hasPrefix("0 ") }, "nothing absent is shown as zero")
    }

    func testEveryFieldTheWorkoutHasIsShownInOrder() {
        let w = item(minutes: 30, kcal: 300, distance: 5_000, avgHR: 150, maxHR: 172,
                     pauses: [DateInterval(start: at(-50), duration: 300)])
        let samples = hr(Array(repeating: 150, count: 25), from: w.start)
        let rows = WorkoutDetailContent.rows(w, hr: samples, age: 40, unit: .metric, recordedWith: "Helio Strap")
        XCTAssertEqual(rows.map(\.title), ["Duration", "Paused", "Active energy", "Average heart rate",
                                           "Maximum heart rate", "Distance", "Average pace", "Training load",
                                           "Recorded with"])
        XCTAssertEqual(rows.first { $0.title == "Duration" }?.value, "25m 00s", "moving time, pauses taken out")
        XCTAssertEqual(rows.first { $0.title == "Paused" }?.value, "5m 00s")
        XCTAssertNotNil(rows.first { $0.title == "Active energy" }?.caption, "labelled as an estimate")
        XCTAssertEqual(rows.first { $0.title == "Average pace" }?.value, "5:00 /km", "5 km in 25 moving minutes")
        let load = TrainingLoad.workoutLoad(hrSamples: samples, age: 40, sessionEnd: w.end)
        XCTAssertEqual(rows.first { $0.title == "Training load" }?.value, load.map { "\(Int($0.rounded()))" })
    }

    func testCyclingShowsSpeedNotPace() {
        let ride = item(activity: .cycling, minutes: 60, distance: 20_000)
        let rows = WorkoutDetailContent.rows(ride, hr: [], age: 40, unit: .metric, recordedWith: "RingConn ring")
        XCTAssertEqual(rows.first { $0.title == "Average speed" }?.value, "20.0 km/h")
        XCTAssertNil(rows.first { $0.title == "Average pace" })
    }

    func testHeartRateFromHealthWinsAndTheAppHistoryIsNotRead() {
        let window = DateInterval(start: at(-60), end: at(-30))
        var askedApp = false
        let chosen = WorkoutDetailContent.heartRate(health: hr([120, 130], from: at(-50)), window: window,
                                                    appHistory: { askedApp = true; return [] })
        XCTAssertEqual(chosen.source, .health)
        XCTAssertEqual(chosen.samples.map(\.bpm), [120, 130])
        XCTAssertFalse(askedApp)
    }

    func testWithoutHealthHeartRateTheAppsReadingsInsideTheWindowAreUsed() {
        let window = DateInterval(start: at(-60), end: at(-30))
        let app = hr([90], from: at(-90)) + hr([125, 135], from: at(-45)) + hr([95], from: at(-20))
        let chosen = WorkoutDetailContent.heartRate(health: [], window: window, appHistory: { app })
        XCTAssertEqual(chosen.source, .appHistory)
        XCTAssertEqual(chosen.samples.map(\.bpm), [125, 135])
    }

    func testNoHeartRateAnywhereMeansNoZonesAndNoLoad() {
        let chosen = WorkoutDetailContent.heartRate(health: [], window: DateInterval(start: at(-60), end: at(-30)),
                                                    appHistory: { [] })
        XCTAssertEqual(chosen.source, .none)
        XCTAssertNil(WorkoutDetailContent.zones([], age: 40, end: at(-30)))
    }

    func testZonesAreTheHeldClassifierWithTheWorkoutsMaxHR() {
        let samples = hr(Array(repeating: 150, count: 10), from: at(-60))
        let zones = WorkoutDetailContent.zones(samples, age: 40, end: at(-50))
        XCTAssertEqual(zones, HRZoneClassifier.timeInZonesHeld(hrSamples: samples, maxHR: TrainingLoad.zoneMaxHR(age: 40),
                                                               sessionEnd: at(-50)))
        XCTAssertNil(WorkoutDetailContent.zones(hr([60, 62], from: at(-60)), age: 40, end: at(-58)),
                     "readings below every zone draw nothing")
    }

    func testTheStrapIsNamedAndThePhoneAttributedWorkoutFollowsTheOwner() {
        XCTAssertEqual(WorkoutDetailContent.recordedWith(deviceName: "Helio Strap", deviceManufacturer: "Amazfit",
                                                         owner: .ringConn), "Helio Strap")
        XCTAssertEqual(WorkoutDetailContent.recordedWith(deviceName: "iPhone", deviceManufacturer: "Apple Inc.",
                                                         owner: .ringConn), "RingConn ring")
        XCTAssertEqual(WorkoutDetailContent.recordedWith(deviceName: "iPhone", deviceManufacturer: "Apple Inc.",
                                                         owner: .zeppOS), "Helio Strap")
        XCTAssertEqual(WorkoutDetailContent.recordedWith(deviceName: nil, deviceManufacturer: nil, owner: .ringConn),
                       "RingConn ring")
    }

    func testTheListIsSectionedByMonthNewestFirst() {
        let sept1 = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 8))!
        let sept15 = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 8))!
        let aug30 = cal.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 8))!
        let items = [item(start: sept1), item(start: aug30), item(start: sept15)]
        let sections = WorkoutDetailContent.monthSections(items)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].items.map(\.start), [sept15, sept1])
        XCTAssertEqual(sections[1].items.map(\.start), [aug30])
    }

    func testPagingAppendsOlderWorkoutsOnceAndStopsOnAShortPage() {
        let first = (0..<3).map { item(start: at(Double(-60 * $0))) }
        var result = WorkoutDetailContent.appendPage(first, to: [], pageSize: 3)
        XCTAssertFalse(result.reachedEnd)
        let older = [item(start: at(-500))]
        result = WorkoutDetailContent.appendPage(older + [first[2]], to: result.items, pageSize: 3)
        XCTAssertEqual(result.items.count, 4, "a repeat of a held workout is not added twice")
        XCTAssertTrue(result.reachedEnd)
        XCTAssertEqual(result.items.map(\.start), result.items.map(\.start).sorted(by: >))
    }

    /// Two workouts sharing the page boundary's start instant: the next page (queried at-or-before
    /// the cursor) repeats the held one and brings the other, which must not be skipped.
    func testAWorkoutSharingTheBoundaryStartIsNotSkipped() {
        let boundary = at(-120)
        let first = [item(start: at(0)), item(start: at(-60)), item(start: boundary)]
        var result = WorkoutDetailContent.appendPage(first, to: [], pageSize: 3)
        let twin = item(start: boundary)
        result = WorkoutDetailContent.appendPage([first[2], twin, item(start: at(-500))], to: result.items, pageSize: 3)
        XCTAssertTrue(result.items.contains { $0.id == twin.id })
        XCTAssertEqual(result.items.count, 5)
        XCTAssertFalse(result.reachedEnd, "a full page that brought something new is not the end")
    }
}
