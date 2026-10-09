import XCTest
@testable import OpenCircuitKit

/// The #281 motion gate on elevated-HR energy and minutes (`ExerciseMinutes.motionCorroborationEnabled`).
///
/// Every time, reading and step count here is synthetic and rounded. The "master" literals were
/// measured on 63e2796 (before the gate existed) with these exact fixtures. Pinning them with the
/// gate OFF proves the switch restores today's numbers to the last digit, not just "about the same".
/// Since decision 67 every Keytel price is net of resting energy, so each pinned literal is the 63e2796
/// value minus (elevated minutes × 1623.75 / 1440), this profile's resting kcal per minute.
final class MotionCorroborationGateTests: XCTestCase {

    private let profile = UserProfile(age: 35, weightKg: 70, heightCm: 175, sex: .male)  // maxHR 185, bar 92
    private let day = Date(timeIntervalSince1970: 1_767_225_600)

    private func at(_ hour: Double, _ minute: Double = 0) -> Date {
        day.addingTimeInterval(hour * 3600 + minute * 60)
    }

    /// Back-to-back 150 s history epochs (instants), the way the ring delivers all-day HR.
    private func bout(_ hour: Double, _ minute: Double, minutes: Int, bpm: Int) -> [HRSample] {
        (0 ..< minutes * 60 / 150).map {
            HRSample(bpm: bpm, start: at(hour, minute).addingTimeInterval(Double($0) * 150))
        }
    }

    // MARK: Fixtures

    /// The caffeine / stress shape: an hour at 104 bpm, seated, not one step.
    private var caffeine: [HRSample] { bout(14, 0, minutes: 60, bpm: 104) }

    /// The real-walk shape: 30 min at 110 bpm. HR lags the first steps by a couple of minutes.
    private var walk: [HRSample] { bout(10, 0, minutes: 30, bpm: 110) }
    /// The walk's steps as the strap stores them: one window per minute, 09:58–10:30, 100 spm.
    private var walkStrapSteps: [StepWindow] {
        (0 ..< 32).map { StepWindow(start: at(9, 58 + Double($0)), end: at(9, 59 + Double($0)), delta: 100) }
    }
    /// The same 3200 steps as the ring stores them: quarter-hour buckets (PROTOCOL.md §5.4).
    private var walkRingSteps: [StepWindow] {
        [StepWindow(start: at(9, 58), end: at(10, 0), delta: 200),
         StepWindow(start: at(10, 0), end: at(10, 15), delta: 1500),
         StepWindow(start: at(10, 15), end: at(10, 30), delta: 1500)]
    }

    private func attributed(_ hr: [HRSample], steps: Int, windows: [StepWindow],
                            activity: [DateInterval] = [], credited: [DateInterval] = [],
                            gate: Bool) -> Calories.DailyEstimate {
        Calories.dailyEstimate(hrSamples: hr, steps: steps, profile: profile,
                               stepWindows: windows, dayStart: day,
                               activityIntervals: activity, creditedWorkoutIntervals: credited,
                               corroborateMotion: gate)
    }

    private func legacy(_ hr: [HRSample], steps: Int, windows: [StepWindow] = [],
                        activity: [DateInterval] = [], credited: [DateInterval] = [],
                        gate: Bool) -> Calories.DailyEstimate {
        Calories.legacyDailyEstimate(hrSamples: hr, steps: steps, profile: profile,
                                     motion: .init(stepWindows: windows, activityIntervals: activity,
                                                   creditedWorkoutIntervals: credited),
                                     corroborateMotion: gate)
    }

    // MARK: The switch

    func testTheGateShipsOn() {
        XCTAssertTrue(ExerciseMinutes.motionCorroborationEnabled,
                      "ON since decision 67: validated on real days, see the switch's doc comment")
        XCTAssertNotNil(ExerciseMinutes.effectiveMotionEvidence(.init()))
        XCTAssertNil(ExerciseMinutes.effectiveMotionEvidence(.init(), corroborate: false),
                     "off is still reachable for side-by-side pricing")
        XCTAssertNotNil(ExerciseMinutes.effectiveMotionEvidence(.init(), corroborate: true),
                        "on with empty evidence is NOT 'no gate': nothing corroborates")
    }

    func testTheDefaultIsTheOnPath() {
        // Every production call site relies on the default. It must be the on path exactly: a seated
        // caffeine hour prices nothing, and a walk keeps all of it.
        let e = Calories.dailyEstimate(hrSamples: caffeine, steps: 0, profile: profile,
                                       stepWindows: [], dayStart: day)
        XCTAssertEqual(e, attributed(caffeine, steps: 0, windows: [], gate: true))
        XCTAssertEqual(e.activeKcal, 0)
        XCTAssertEqual(ExerciseMinutes.estimate(hrSamples: caffeine, maxHR: 185), 0)
        let w = Calories.dailyEstimate(hrSamples: walk, steps: 3200, profile: profile,
                                       stepWindows: walkStrapSteps, dayStart: day)
        XCTAssertEqual(w, attributed(walk, steps: 3200, windows: walkStrapSteps, gate: false))
    }

    // MARK: Fixture 1 — elevated HR, zero motion (caffeine / stress)

    func testCaffeineShapeGateOffPricesExactlyAsBeforeTheGate() {
        let a = attributed(caffeine, steps: 0, windows: [], gate: false)
        XCTAssertEqual(a.activeKcal, 383.9527366156789)
        XCTAssertEqual(a.elevatedMinutes, 60.0)
        XCTAssertEqual(a.buckets.count, 4)
        let l = legacy(caffeine, steps: 0, gate: false)
        XCTAssertEqual(l.activeKcal, 383.9527366156788)
        XCTAssertEqual(l.elevatedMinutes, 60.0)
        XCTAssertEqual(ExerciseMinutes.estimate(hrSamples: caffeine, maxHR: 185, corroborateMotion: false), 60.0)
    }

    func testCaffeineShapeGateOnPricesNothing() {
        let a = attributed(caffeine, steps: 0, windows: [], gate: true)
        XCTAssertEqual(a.activeKcal, 0)
        XCTAssertEqual(a.elevatedMinutes, 0)
        let l = legacy(caffeine, steps: 0, gate: true)
        XCTAssertEqual(l.activeKcal, 0, "the legacy degrade path must not be the one that still prices it")
        XCTAssertEqual(l.elevatedMinutes, 0)
        XCTAssertEqual(ExerciseMinutes.estimate(hrSamples: caffeine, maxHR: 185, corroborateMotion: true), 0)
        XCTAssertEqual(ExerciseMinutes.elevatedPieces(hrSamples: caffeine, maxHR: 185, corroborateMotion: true), [])
    }

    func testIncidentalStepsDoNotUnlockACaffeineHour() {
        // A trip to the kettle: 30 steps in the 14:15 quarter, 2 spm.
        let kettle = [StepWindow(start: at(14, 15), end: at(14, 30), delta: 30)]
        let off = attributed(caffeine, steps: 30, windows: kettle, gate: false)
        XCTAssertEqual(off.activeKcal, 383.9527366156789, "63e2796 value net of resting")
        XCTAssertEqual(off.elevatedMinutes, 60.0)
        let on = attributed(caffeine, steps: 30, windows: kettle, gate: true)
        XCTAssertEqual(on.elevatedMinutes, 0)
        XCTAssertEqual(on.activeKcal, Calories.activeKcalFromSteps(steps: 30, profile: profile), accuracy: 1e-12,
                       "the kettle trip keeps its walking energy; only the Keytel channel is gated")
    }

    func testTheDayWideStepFallbackCorroboratesNothing() {
        // `[startOfDay, sampleDate]` on a fresh baseline: thousands of steps placed nowhere in time.
        let fallback = [StepWindow(start: day, end: at(15, 0), delta: 6000)]
        XCTAssertEqual(attributed(caffeine, steps: 6000, windows: fallback, gate: true).elevatedMinutes, 0)
    }

    func testStepsAfterTheBoutDoNotExplainIt() {
        // HR is explained by motion BEFORE it. A walk that starts once the hour is over doesn't count.
        let after = (0 ..< 20).map {
            StepWindow(start: at(15, 1 + Double($0)), end: at(15, 2 + Double($0)), delta: 100)
        }
        XCTAssertEqual(attributed(caffeine, steps: 2000, windows: after, gate: true).elevatedMinutes, 0)
    }

    // MARK: Fixture 2 — elevated HR with corroborating steps (real walk)

    func testWalkShapeIsUnchangedByTheGateOnTheStrapsMinuteSteps() {
        let off = attributed(walk, steps: 3200, windows: walkStrapSteps, gate: false)
        let on = attributed(walk, steps: 3200, windows: walkStrapSteps, gate: true)
        XCTAssertEqual(off.activeKcal, 220.8543377151052, "63e2796 value net of resting")
        XCTAssertEqual(off.elevatedMinutes, 30.0)
        XCTAssertEqual(on, off, "same kcal, same minutes, same buckets")
    }

    func testWalkShapeIsUnchangedByTheGateOnTheRingsQuarterBuckets() {
        let off = attributed(walk, steps: 3200, windows: walkRingSteps, gate: false)
        let on = attributed(walk, steps: 3200, windows: walkRingSteps, gate: true)
        XCTAssertEqual(off.activeKcal, 220.8543377151052, "63e2796 value net of resting")
        XCTAssertEqual(off.elevatedMinutes, 30.0)
        XCTAssertEqual(on, off)
    }

    func testWalkShapeIsUnchangedByTheGateOnTheLegacyPath() {
        let off = legacy(walk, steps: 3200, windows: walkStrapSteps, gate: false)
        let on = legacy(walk, steps: 3200, windows: walkStrapSteps, gate: true)
        XCTAssertEqual(off.activeKcal, 219.11833771510518, "63e2796 value net of resting")
        XCTAssertEqual(off.elevatedMinutes, 30.0)
        XCTAssertEqual(on, off)
    }

    func testAWalkTheSuspendedAppSawNoStepsForIsCorroboratedByTheRingsSession() {
        // 2026-09-27 shape: no steps reached the app, but the ring logged its own activity session
        // (stamped 12 min late, as recognised), widened by `ringActivityLead`.
        let session = HealthAlertEvaluator.ringActivityIntervals([(at(10, 12), at(10, 31))])
            .map { DateInterval(start: $0.0, end: $0.1) }
        let off = attributed(walk, steps: 0, windows: [], gate: false)
        let on = attributed(walk, steps: 0, windows: [], activity: session, gate: true)
        XCTAssertEqual(on, off)
        XCTAssertEqual(on.elevatedMinutes, 30.0)
    }

    // MARK: Both on one day — the legacy path must not mix qualifying sets

    func testMixedDayLegacyPricesOnlyTheWalkAtTheWalksOwnBpm() {
        // If the gate filtered the minutes but not the qualifying bpm (or the other way round),
        // the walk's 30 min would be priced at the 104/110 blend. That is the hybrid
        // `effectiveRestingBaseline`'s comment measured at +40 %.
        let l = legacy(walk + caffeine, steps: 3200, windows: walkStrapSteps, gate: true)
        XCTAssertEqual(l.elevatedMinutes, 30.0)
        XCTAssertEqual(l.activeKcal, Calories.workoutActiveKcal(avgHR: 110, durationSeconds: 1800, profile: profile))
        let a = attributed(walk + caffeine, steps: 3200, windows: walkStrapSteps, gate: true)
        XCTAssertEqual(a, attributed(walk, steps: 3200, windows: walkStrapSteps, gate: true),
                       "the seated hour adds nothing; the walk is priced as on its own")
    }

    // MARK: Recorded workouts are never gated

    /// A ring workout as `WorkoutSessionManager` stores it: a ~2 s span before each lock, ~10 s apart.
    private func ringWorkoutReadings(_ hour: Double, _ minute: Double, minutes: Int, bpm: Int) -> [HRSample] {
        (0 ..< minutes * 6).map { i -> HRSample in
            let lock = at(hour, minute).addingTimeInterval(Double(i) * 10 + 2)
            return HRSample(bpm: bpm, start: lock.addingTimeInterval(-2), end: lock)
        }
    }

    /// A strap workout as `StrapWorkoutSampleLine` stores it: one reading a second, each over the
    /// second before it.
    private func strapWorkoutReadings(_ hour: Double, _ minute: Double, minutes: Int, bpm: Int) -> [HRSample] {
        (1 ... minutes * 60).map { s -> HRSample in
            let end = at(hour, minute).addingTimeInterval(Double(s))
            return HRSample(bpm: bpm, start: end.addingTimeInterval(-1), end: end)
        }
    }

    func testRecordedWorkoutPricingIsTheKeytelPathOnTheRingAndTheStrap() {
        // The recorded-workout calorie paths call `workoutActiveKcal` on the session's own HR, with
        // no `elevatedPieces` and no step input anywhere in them. A stationary session (no steps,
        // no distance) is the case a motion gate would hit if it ever reached these paths.
        let keytel = Calories.workoutActiveKcal(avgHR: 130, durationSeconds: 1800, profile: profile)

        let ring = WorkoutSessionAggregator(startDate: at(17, 0), userAge: profile.age)
        ringWorkoutReadings(17, 0, minutes: 30, bpm: 130).forEach { ring.add(sample: $0) }
        let ringSummary = ring.finalize(sport: .cyclingIndoor, endDate: at(17, 30),
                                        distanceMeters: nil, hasRoute: false, profile: profile, steps: 0)
        XCTAssertEqual(ringSummary.estimatedActiveKcal, keytel)

        let strap = StrapWorkoutSummaryBuilder.summarize(
            sport: .cyclingIndoor, ledger: WorkoutActivityLedger(start: at(17, 0)),
            samples: strapWorkoutReadings(17, 0, minutes: 30, bpm: 130), end: at(17, 30),
            distanceMeters: nil, hasRoute: false, profile: profile)
        XCTAssertEqual(strap.summary.estimatedActiveKcal, keytel)
    }

    func testARecordedRingWorkoutInTheDailyEstimateIsNotGated() {
        // The workout's readings land in the day's HR series beside the ring's own history, and the
        // Health flush nets the workout's committed kcal back out. Gating them would subtract a
        // stationary session's energy from the rest of the day. Includes a 15 min lock dropout,
        // during which only the ring's history instants cover the workout.
        let readings = ringWorkoutReadings(17, 0, minutes: 10, bpm: 130)
            + ringWorkoutReadings(17, 25, minutes: 5, bpm: 130)
        let hr = readings + bout(17, 0, minutes: 30, bpm: 128)
        let off = attributed(hr, steps: 0, windows: [], gate: false)
        XCTAssertGreaterThan(off.elevatedMinutes, 29)
        XCTAssertEqual(attributed(hr, steps: 0, windows: [], gate: true), off)
        XCTAssertEqual(legacy(hr, steps: 0, gate: true), legacy(hr, steps: 0, gate: false))
    }

    func testARecordedStrapWorkoutInTheDailyEstimateIsNotGated() {
        // The strap's per-minute history instants sit alongside the workout's per-second readings.
        let history = (0 ..< 30).map { HRSample(bpm: 128, start: at(17, Double($0))) }
        let hr = strapWorkoutReadings(17, 0, minutes: 30, bpm: 130) + history
        let off = attributed(hr, steps: 0, windows: [], gate: false)
        XCTAssertGreaterThan(off.elevatedMinutes, 29)
        XCTAssertEqual(attributed(hr, steps: 0, windows: [], gate: true), off)
        XCTAssertEqual(legacy(hr, steps: 0, gate: true), legacy(hr, steps: 0, gate: false))
    }

    /// review-281 F1: a workout whose kcal is credited (`HealthKitWriter.recordWorkoutActiveKcal`)
    /// but whose readings never form LocalStore span rows — a confirmed ring-detected import, a
    /// crash-recovered orphan, or a live ring session whose HR never locked. All three leave only
    /// history INSTANTS (`end == start`) behind, so `recordedWorkoutIntervals` alone can't find them
    /// and the gate would double-subtract their energy. `creditedWorkoutIntervals` is the
    /// independent, LocalStore-row-free exemption that closes this: the workout's own window is
    /// passed straight from the kcal-credit call site.
    func testAWorkoutCreditedWithoutSpanRowsIsExemptThroughCreditedWorkoutIntervals() {
        // 45 min of stationary history instants at 132 bpm, no steps, no span rows at all —
        // simulates importDetectedWorkout/saveRecoveredWorkout/a never-locked live ring session.
        let hr = bout(16, 0, minutes: 45, bpm: 132)
        let creditedSpan = DateInterval(start: at(16, 0), end: at(16, 45))
        let off = attributed(hr, steps: 0, windows: [], gate: false)
        XCTAssertGreaterThan(off.elevatedMinutes, 44, "sanity: the bout is elevated with the gate off")

        // Without the fix: no steps and no span rows, so the gate zeroes it — the exact
        // double-subtraction F1 describes (the walk's kcal eaten to 0.0 in the reviewer's repro).
        let goneWithoutCredit = attributed(hr, steps: 0, windows: [], gate: true)
        XCTAssertEqual(goneWithoutCredit.activeKcal, 0,
                       "sanity: without creditedWorkoutIntervals the stationary bout IS gated to zero")

        let withCredit = attributed(hr, steps: 0, windows: [], credited: [creditedSpan], gate: true)
        XCTAssertEqual(withCredit, off,
                       "creditedWorkoutIntervals must restore gate-OFF output for the credited span")

        // Legacy path: same property.
        XCTAssertEqual(legacy(hr, steps: 0, gate: true).activeKcal, 0)
        XCTAssertEqual(legacy(hr, steps: 0, credited: [creditedSpan], gate: true),
                       legacy(hr, steps: 0, gate: false))
    }

    func testRecordedWorkoutIntervalsGroupSpanReadingsAndIgnoreHistoryInstants() {
        let hr = ringWorkoutReadings(9, 0, minutes: 5, bpm: 120)          // 09:00–09:05
            + ringWorkoutReadings(9, 30, minutes: 5, bpm: 120)            // 25 min later: same workout
            + ringWorkoutReadings(11, 0, minutes: 5, bpm: 120)            // 1 h 25 min later: a new one
            + bout(12, 0, minutes: 30, bpm: 120)                          // instants: never a workout
        let spans = ExerciseMinutes.recordedWorkoutIntervals(hr)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.first?.start, at(9, 0))
        XCTAssertEqual(spans.first?.end, at(9, 35).addingTimeInterval(-8))
        XCTAssertEqual(spans.last?.start, at(11, 0))
    }

    // MARK: The cadence bar itself

    func testTheBarIsTwentyStepsAMinuteOverTheWindow() {
        // One 150 s interval at 12:00 → window [11:50, 12:02:30] = 12.5 min → 250 steps needed.
        let start = at(12, 0), end = at(12, 2.5)
        func gate(_ delta: Int) -> ExerciseMinutes.MotionGate {
            .init(evidence: .init(stepWindows: [StepWindow(start: at(11, 50), end: end, delta: delta)]),
                  hrSamples: [])
        }
        XCTAssertTrue(gate(250).corroborates(start: start, end: end))
        XCTAssertFalse(gate(249).corroborates(start: start, end: end))
    }

    func testAQuarterBucketIsProratedNotCountedWhole() {
        // 600 steps in the 11:40–11:55 quarter (40 spm across it). For an interval at 12:02:30 the
        // window is [11:52:30, 12:05]: only 2.5 of the bucket's 15 minutes fall inside, so 100
        // steps over 12.5 min = 8 spm, below the bar.
        let g = ExerciseMinutes.MotionGate(
            evidence: .init(stepWindows: [StepWindow(start: at(11, 40), end: at(11, 55), delta: 600)]),
            hrSamples: [])
        XCTAssertFalse(g.corroborates(start: at(12, 2.5), end: at(12, 5)))
        XCTAssertTrue(g.corroborates(start: at(11, 55), end: at(11, 57.5)),
                      "window [11:45, 11:57:30] holds 10 of its 15 minutes: 400 / 12.5 = 32 spm")
    }
}
