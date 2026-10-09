// Estimate Apple Exercise Time (elevated-HR minutes) from stored HR samples (#82).
//
// SCOPE — BASIC ESTIMATE ONLY.
// A basic threshold model: minutes where HR ≥ 50% of max HR (equivalent to brisk
// walking, Apple's own exercise definition). This estimate uses ONLY the decoded
// HR samples we have — sleep-window bulk epochs (0x4c[4], 🟢) and live monitoring
// readings — and EXCLUDES the overnight sleep window to avoid counting sleeping
// elevated HR as voluntary exercise.
//
// ⚠️ The FULL 4-level intensity mapping (Vigorous/Moderate/Low/Inactive minutes) is
// GATED on the *separate, still-uncaptured* 历史活动响应 activity record (#93,
// PROTOCOL.md §5.3.1) — NOT on 0x4c[15:22], which is just the tail of the
// already-decoded `acti_counts` intensity blob on the MEASUREMENT record we already
// have (a same-record "is it moving" signal, not 4 calibrated bands). Do not invent
// 4 intensity buckets from the basic HR threshold alone. This file is the
// basic-threshold placeholder until that capture (sync-open `byte[6]=0x02`, see
// `RingSession.probeActivityChannels`) lands and the bands can be calibrated against
// the app's own per-day readout.
//
// HealthKit target: `.appleExerciseTime` (written by HealthKitWriter as a delta,
// not stored as a ring sample in LocalStore).

import Foundation

public enum ExerciseMinutes {

    /// ══ THE PERSONALISED THRESHOLD IS OFF. READ THIS BEFORE TURNING IT BACK ON. ══
    ///
    /// `false` ⇒ the %-of-max model, byte-identical to what shipped through build 41. This is the
    /// ONE switch: `elevatedPieces`, `estimate` and `Calories` all resolve their baseline through
    /// `effectiveRestingBaseline`, so nothing can be left half-converted.
    ///
    /// It is off because the personalised model as tuned here is WRONG IN THE OTHER DIRECTION, and
    /// that was measured, not guessed. Release review built this Kit and ran realistic days at the
    /// ring's 150 s epoch cadence: a 35-year-old walker with a 66.5 bpm resting pulse, walking at
    /// 96–99 bpm, went from **95 elevated minutes to 0**, active calories 406 → 72, and an Activity
    /// Score of 100 to 50 — on a completely unchanged day. The tester whose report motivated the
    /// change went from 200 minutes to 0. And it is provably one-directional: `new < old` requires
    /// `rhr < maxHR/6 ≈ 31 bpm`, which the 35 bpm plausibility floor excludes, so NO user anywhere
    /// gains a single minute or calorie.
    ///
    /// The error was mine and it is worth naming precisely, because the arithmetic below is fine.
    /// 0.40 HRR is the textbook ACSM floor for MODERATE INTENSITY — but this file estimates Apple
    /// EXERCISE TIME, whose definition is "brisk walk or above", and a brisk walk does not reach
    /// 40 % HRR. Equating the two is a taxonomy conflation; it made us stricter than the metric we
    /// are approximating. I measured the fix on a high-resting-pulse day, saw 280 min → 12.5, and
    /// read the collapse as success without asking whether 12.5 was the right answer for a day that
    /// contained a real walk. It was not.
    ///
    /// The reported defect is still real — an absolute %-of-max bar over-credits a fast resting
    /// pulse — and heart-rate reserve is still the right shape for the fix. What it needs before it
    /// ships: a fraction re-fitted against days with KNOWN activity (review's sweep put the cliff
    /// between 0.25 and 0.30 HRR — 0.25 → 60 min, 0.30 → 2 min, so ~0.25 is the candidate), a
    /// resting baseline that outlives the day so the ring cannot run backwards mid-morning, and a
    /// re-baselined `GoalDefaults.defaultActivityMinutes` (still 30, set against the old bar).
    public static let personalisedThresholdEnabled = false

    /// Fraction of HEART-RATE RESERVE at which a reading counts as elevated. Dormant while
    /// `personalisedThresholdEnabled` is false. ⚠️ 0.40 is the ACSM MODERATE floor, which is NOT the
    /// same band as Apple's "brisk walk or above" — see above. Re-fit before enabling.
    public static let hrReserveFraction = 0.40

    /// The baseline every consumer must resolve through, so the kill-switch cannot be honoured in
    /// one place and ignored in another.
    ///
    /// This exists because the first version of the switch DIDN'T work: `Calories.legacyDailyEstimate`
    /// re-derived the baseline directly, so flipping `deriveRestingHR` produced a hybrid — old-model
    /// minutes divided into new-model qualifying samples. Release review measured the wreckage
    /// (40 min priced at 0.00 kcal where 161.66 was correct; 70 min at 574.69 where 410.09 was
    /// correct, +40 %) and noted `swift test` could not see it, because both models are individually
    /// self-consistent. A kill-switch that corrupts the thing it is meant to restore is worse than
    /// no kill-switch.
    public static func effectiveRestingBaseline(
        _ hrSamples: [HRSample],
        derive: Bool = personalisedThresholdEnabled
    ) -> Double? {
        derive ? restingBaseline(hrSamples) : nil
    }

    // MARK: Motion corroboration (#281)

    /// ══ THE MOTION GATE IS OFF. READ THIS BEFORE TURNING IT ON. ══
    ///
    /// `false` ⇒ every reading at or above `threshold` is elevated, exactly as through build 73. This
    /// is the ONE switch: `elevatedPieces`, `estimate`, `Calories.attributedDailyEstimate` and
    /// `Calories.legacyDailyEstimate` all resolve it through `effectiveMotionEvidence`, so nothing can
    /// be left half-gated. A half-gated day is worse than either model: the minutes ring and the
    /// calorie number would stop sharing a qualifying set (see `effectiveRestingBaseline` for what
    /// that cost the last time).
    ///
    /// WHAT IT FIXES. Nothing in this file has ever asked whether the wearer was MOVING. A seated hour
    /// at 104 bpm (coffee, stress, a fever, a hot room) crosses the same bar as a brisk walk and is
    /// priced by the same Keytel regression: for a synthetic 35-year-old 70 kg man that hour is
    /// 451.61 kcal and 60 elevated minutes, more than a 30-minute walk at 110 bpm (254.68 kcal). A
    /// tester reported ~4000 active kcal on a day with no workout (#281). With the gate on, an elevated
    /// reading prices only where `corroborates` finds motion around it; the same seated hour reads
    /// 0 kcal and 0 minutes, and the walk is unchanged to the last digit. The pinned fixtures are in
    /// `MotionCorroborationGateTests`.
    ///
    /// It is a GATE, not a repricing. A gated reading is still a real heart rate. It keeps its sample
    /// and its HR chart, and its steps (if any) still earn walking energy in `Calories`. Only the
    /// Keytel channel and the exercise minutes leave it out.
    ///
    /// WHY IT IS ON (#281, decision 67). It shipped off until checked against real days. Three
    /// days from the owner's own ring were priced side by side. Ungated, two ordinary full days with
    /// ~5,300 steps and no workout read ~2,200-2,330 active kcal from 325-342 "elevated" minutes,
    /// mostly seated stretches just over the half-of-max-HR bar. Gated, they read ~330-410 kcal from 40-53
    /// minutes, and each morning walk kept its energy. That matches how motion-aware wearables
    /// (Apple Watch, Garmin, Fitbit) count active energy. Known costs, each of which is a real day
    /// getting LESS than it did with the gate off:
    ///   • Unrecorded exercise that is not walking (cycling, rowing, weights, swimming) produces few
    ///     or no steps. It keeps its HR energy only if the ring flagged it as an activity session or
    ///     the wearer recorded it as a workout.
    ///   • The ring keeps no step backlog: a quarter-hour nobody was connected for has no steps at all
    ///     (PROTOCOL.md §5.4, #192), while its HR arrives later as history. A walk in such a gap is
    ///     corroborated only by the ring's own activity session, which needs ≥ 10 min of continuous
    ///     activity before the ring recognises one (`AutomaticWorkoutDetector.minimumDuration`).
    ///   • The ring's activity sessions are kept for 48 h (`RingActivityEventLedger.retention`), so
    ///     Trends' re-pricing of older days loses that evidence.
    ///   • A day whose step rows predate per-snapshot step history has no step windows. With the gate
    ///     on, its HR channel reads 0 and the day falls back to step energy only.
    ///
    /// Recording non-walking exercise as a workout keeps all of it (recorded workouts are always
    /// corroborated). `corroborateMotion:` still lets a day be priced both ways side by side.
    public static let motionCorroborationEnabled = true

    /// Minimum step cadence, in steps per minute AVERAGED over a reading's corroboration window,
    /// that counts as motion.
    ///
    /// Tudor-Locke's free-living cadence bands (Tudor-Locke & Rowe, Sports Med 2012;42(5):381–398)
    /// split stepping into 0 (no movement), 1–19 (incidental: a step to the printer, shifting at a
    /// desk), 20–39 (sporadic), 40–59 (purposeful), 60–79 / 80–99 / 100–119 (slow, medium, brisk
    /// walking) and 120+. A cadence of ≥ 100 is the moderate-intensity (≈ 3 MET) heuristic
    /// (Tudor-Locke et al., BJSM 2018;52(12):776–788).
    ///
    /// 20 is the lowest band edge above incidental movement, and it is deliberately not 100.
    /// Grading intensity is the job of `threshold`, not of this gate. The gate only rejects elevated
    /// heart rate with no walking behind it, and a seated caffeine or stress bout is incidental
    /// movement by definition. The cadence is also an average, not a per-minute reading: the ring
    /// only ever reports a quarter-hour bucket (PROTOCOL.md §5.4), so a 5-minute brisk walk inside an
    /// otherwise seated quarter reads 500 / 15 ≈ 33 spm. A bar of 100 would refuse most real ring
    /// walks. A bar of 20 still needs ≥ 250 steps in the 12.5-minute window around one 150 s epoch.
    /// The incidental band can't produce that, and any real walk does.
    public static let minCorroboratingCadence: Double = 20

    /// How far BEFORE an elevated reading its corroborating motion may lie.
    ///
    /// Heart rate lags movement both ways: it rises within a minute or two of setting off, and it
    /// stays raised for minutes after stopping. So a reading is explained by motion in the minutes
    /// before it, never after. The window is `[start − lookback, end]`. 10 min is the recovery tail
    /// `HealthAlertEvaluator.nonExercising` already pads for the same physiology (#144). The two
    /// gates therefore agree on what "just exercised" means: a reading this gate credits as exercise
    /// is one that alert gate would treat as exercising.
    public static let corroborationLookback: TimeInterval = 10 * 60

    /// Largest gap between two recorded-workout readings that still belongs to the same workout (see
    /// `recordedWorkoutIntervals`). The ring records a workout reading only on a fresh HR lock, and
    /// the lock can drop out for minutes in motion (#45). Erring wide costs at most crediting the
    /// stretch between two recorded workouts. Erring narrow puts part of a recorded workout through
    /// the gate, and the Health flush still nets the workout's whole committed kcal out of the day
    /// (`HealthKitWriter.netDailyActiveKcalEstimate`). That would eat energy earned elsewhere.
    public static let recordedWorkoutMaxGap: TimeInterval = 30 * 60

    /// Everything the gate may treat as motion, as stored. A pure value so the gate stays testable
    /// off the app's SwiftData models.
    public struct MotionEvidence: Equatable, Sendable {
        /// Step snapshots (`StoredStepSample`): ring quarter-hour buckets, strap minutes. Windows
        /// wider than `HealthAlertEvaluator.maxActivityWindow` are ignored. That width is only ever
        /// the day-wide `[startOfDay, sampleDate]` fallback, which places none of its steps in time.
        public let stepWindows: [StepWindow]
        /// Spans a device itself judged the wearer active: the ring's `0x50` activity sessions,
        /// already widened by `HealthAlertEvaluator.ringActivityIntervals`
        /// (`RingActivityEventLedger.corroboratingIntervals`). A piece overlapping one, or its
        /// `corroborationLookback` tail, is corroborated outright. This is the evidence for a walk the
        /// suspended app recorded no steps for (2026-09-27).
        public let activityIntervals: [DateInterval]
        /// Spans a workout's committed active energy was credited for via
        /// `HealthKitWriter.recordWorkoutActiveKcal`, recorded independently of any LocalStore HR
        /// rows (review-281 F1). Some recorded-workout paths bank that credit without ever landing
        /// span rows — a confirmed ring-detected import (`importDetectedWorkout`), a crash-recovered
        /// orphan (`saveRecoveredWorkout`), and a live ring session whose HR never locked — so
        /// `recordedWorkoutIntervals(_:)` alone (which reads only LocalStore rows) misses them, and
        /// the gate would double-subtract their energy. Today-scoped, same as the kcal credit it
        /// travels beside.
        public let creditedWorkoutIntervals: [DateInterval]

        public init(stepWindows: [StepWindow] = [], activityIntervals: [DateInterval] = [],
                    creditedWorkoutIntervals: [DateInterval] = []) {
            self.stepWindows = stepWindows
            self.activityIntervals = activityIntervals
            self.creditedWorkoutIntervals = creditedWorkoutIntervals
        }
    }

    /// The evidence every consumer must resolve the gate through, so the kill-switch can't be honoured
    /// in one place and ignored in another (the `effectiveRestingBaseline` lesson). nil = no gate:
    /// every elevated reading counts, byte-identical to before #281.
    ///
    /// With the gate on, EMPTY evidence is not "no gate". It means nothing corroborates, so only
    /// recorded-workout readings count. A caller that forgets to pass its evidence therefore
    /// under-credits, which is the direction Health can still recover from on a later day. It never
    /// silently restores the over-credit this gate exists to stop.
    public static func effectiveMotionEvidence(
        _ evidence: MotionEvidence,
        corroborate: Bool = motionCorroborationEnabled
    ) -> MotionEvidence? {
        corroborate ? evidence : nil
    }

    /// The recorded workouts in an HR series, recovered from the readings themselves.
    ///
    /// A recorded workout is explicit intent and is NEVER gated (#281). It needs no extra plumbing to
    /// find, because of an invariant both stores keep (`WorkoutHealthExclusions`): every history row
    /// either device stores is an INSTANT (`end == start`), and only a recorded workout's readings
    /// last a moment. The ring stores the ~2 s before each lock (`WorkoutSessionManager`) and the
    /// strap the second before each reading (`StrapWorkoutSampleLine`). Runs of those readings, split
    /// at gaps wider than `maxGap`, are the workouts.
    ///
    /// This matters for more than intent. The workout's HR lands in the same series this estimate
    /// prices, and the Health flush nets the workout's committed kcal back out
    /// (`HealthKitWriter.netDailyActiveKcalEstimate`). Gating a recorded cycling session (few steps)
    /// would subtract its kcal from energy earned at other times of the day.
    static func recordedWorkoutIntervals(_ hrSamples: [HRSample],
                                         maxGap: TimeInterval = recordedWorkoutMaxGap) -> [DateInterval] {
        let readings = hrSamples.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        var open: (start: Date, end: Date)?
        for r in readings {
            if let o = open, r.start.timeIntervalSince(o.end) <= maxGap {
                open = (o.start, Swift.max(o.end, r.end))
            } else {
                if let o = open { out.append(DateInterval(start: o.start, end: o.end)) }
                open = (r.start, r.end)
            }
        }
        if let o = open { out.append(DateInterval(start: o.start, end: o.end)) }
        return out
    }

    /// The gate itself, built once per estimate. Internal so the tests can probe single windows.
    struct MotionGate {
        /// Usable step windows (moved, and narrow enough to place their steps), sorted by start.
        private let steps: [StepWindow]
        /// Activity sessions and recorded workouts: corroborate anything they or their tail overlap.
        private let spans: [DateInterval]

        init(evidence: MotionEvidence, hrSamples: [HRSample]) {
            steps = evidence.stepWindows
                .filter { $0.delta > 0
                    && $0.end >= $0.start
                    && $0.end.timeIntervalSince($0.start) <= HealthAlertEvaluator.maxActivityWindow }
                .sorted { $0.start < $1.start }
            spans = evidence.activityIntervals + evidence.creditedWorkoutIntervals
                + ExerciseMinutes.recordedWorkoutIntervals(hrSamples)
        }

        /// Whether motion explains elevated heart rate over `[start, end]`.
        func corroborates(start: Date, end: Date) -> Bool {
            let lookback = ExerciseMinutes.corroborationLookback
            if spans.contains(where: { start <= $0.end.addingTimeInterval(lookback) && end >= $0.start }) {
                return true
            }
            let lo = start.addingTimeInterval(-lookback)
            let hi = Swift.max(end, start)
            // A usable window is at most `maxActivityWindow` wide, so none starting earlier than
            // this can reach `lo`. Binary-search past them instead of scanning the whole day.
            let earliest = lo.addingTimeInterval(-HealthAlertEvaluator.maxActivityWindow)
            var a = 0, b = steps.count
            while a < b {
                let m = (a + b) / 2
                if steps[m].start < earliest { a = m + 1 } else { b = m }
            }
            // Prorate each window's steps on its overlap, as `Calories` does on metres: a quarter
            // bucket earned its steps across the whole quarter, not in the minute we look at.
            var counted = 0.0
            var i = a
            while i < steps.count, steps[i].start <= hi {
                let w = steps[i]
                let span = w.end.timeIntervalSince(w.start)
                if span > 0 {
                    let overlap = Swift.min(w.end, hi).timeIntervalSince(Swift.max(w.start, lo))
                    if overlap > 0 { counted += Double(w.delta) * overlap / span }
                } else if w.start >= lo {
                    counted += Double(w.delta)  // a point snapshot inside the window counts whole
                }
                i += 1
            }
            let minutes = hi.timeIntervalSince(lo) / 60
            return counted >= ExerciseMinutes.minCorroboratingCadence * minutes
        }
    }

    /// Plausibility band for a derived resting HR. Outside it we do not trust the value and fall
    /// back to the %-of-max model rather than compute a threshold off a bad baseline.
    ///
    /// The 90 ceiling is deliberately below the physiological maximum for a resting pulse: a
    /// derived value that high is far more likely to mean "this sample set never contained rest"
    /// than "this person rests at 95". Falling back there errs toward the LOWER threshold, i.e.
    /// toward crediting the user, which is the safe direction for a goal ring.
    static let plausibleRestingHR: ClosedRange<Double> = 35 ... 90

    /// Minimum readings before a derived resting baseline is trusted.
    static let minRestingBaselineSamples = 12
    /// Minimum span the readings must cover before a derived resting baseline is trusted.
    ///
    /// These guards exist because `lowestSustained` answers "what is the quietest stretch IN THIS
    /// ARRAY", which is only a resting HR if the array actually contains a quiet stretch. Three
    /// readings taken during a workout produce a "resting HR" of 100 and a threshold of 134 — the
    /// exact failure a unit fixture hit when this landed.
    ///
    /// ⚠️ 2 h, NOT the 4 h this first shipped with, and the reason is a real UX defect adversarial
    /// review measured (2026-08-12). The derived threshold is always ≥ the %-of-max one for any
    /// realistic age (new < old ⟺ rhr < maxHR/6, impossible with rhr floored at 35), so the moment
    /// this guard flips the threshold JUMPS UP and the day's elevated minutes JUMP DOWN. Measured at
    /// maxHR 185: a ring put on at 07:00, 1 h at 62 bpm then a 40-min walk at 95 bpm read 40 elevated
    /// minutes (baseline nil, threshold 92) and then **0** once the span passed the guard (baseline
    /// 62, threshold 111) — the goal ring visibly running backwards mid-morning.
    ///
    /// Halving the span halves that exposure without weakening the "did this array contain rest"
    /// test, because that test is really carried by `plausibleRestingHR` and by the
    /// sustained-window requirement below, not by elapsed time. On any ring worn overnight the
    /// guard is satisfied long before waking and the day is unaffected either way.
    ///
    /// 🔴 KNOWN RESIDUAL, not fixed here: the jump still exists inside the first 2 h after a ring is
    /// put on (charge-day mornings, day 1 of pairing). Eliminating it needs a baseline that outlives
    /// the day — yesterday's stored resting HR carried in as a fallback — which is real plumbing
    /// through every `Calories.dailyEstimate` call site and is the named follow-up.
    /// `testEstimateIsNonMonotonicAcrossTheBaselineBoundary` pins the current behaviour so the
    /// boundary is visible rather than surprising.
    static let minRestingBaselineSpan: TimeInterval = 2 * 3600

    /// HR threshold for exercise, in bpm.
    ///
    /// ══ WHY THIS IS RELATIVE TO RESTING HR ══
    ///
    /// With `restingHR` nil this is the ORIGINAL model — 50 % of max HR — kept byte-identical as
    /// the degrade path and the kill-switch.
    ///
    /// That model is wrong in a specific, reported way: it ignores where the person STARTS. A
    /// tester wrote "Elevated HR… seems to fill up too easily… it was nearly complete right after I
    /// woke up. I generally have a fast heart rate" (2026-08-12). She is describing the defect
    /// exactly. At age 35 the old threshold is 92 bpm for everyone; for someone resting at 78 that
    /// is 14 bpm above rest — reached by standing up and making coffee — while for someone resting
    /// at 45 the same 92 bpm is real exertion. One absolute number cannot mean the same thing to
    /// both, so the ring filled from ordinary morning ambulation for her and would under-credit an
    /// endurance athlete on the same day.
    ///
    /// Heart-rate reserve is the standard fix and the one the exercise-physiology literature
    /// defines intensity in: `threshold = RHR + fraction · (maxHR − RHR)` (Karvonen). At 40 % HRR
    /// the same two people get 120 bpm and 101 bpm — each 40 % of the way up their OWN range.
    /// (78 + 0.4·107 = 120.8 → 120 after truncation; 45 + 0.4·140 = 101.)
    ///
    /// Note this generally RAISES the threshold versus 50 % maxHR (ACSM puts 40–59 % HRR at
    /// 64–76 % maxHR, so the old constant sat below even the LIGHT band). Elevated-HR minutes and
    /// the active-calorie estimate that prices the same qualifying periods therefore both come
    /// down. That is the intended direction: the old number over-credited.
    ///
    /// The `max(…, 60)` absolute floor is retained from the original model unchanged — no adult's
    /// exercise threshold should land below 60 bpm regardless of what the inputs say.
    ///
    /// NOTE: Full 4-level intensity (Vigorous/Moderate/Low/Inactive) follows the #93
    /// activity-record capture (PROTOCOL.md §5.3.1), not the current measurement record.
    public static func threshold(maxHR: Int, restingHR: Double? = nil) -> Int {
        let mx = Double(max(maxHR, 1))
        guard let rhr = restingHR, plausibleRestingHR.contains(rhr), rhr < mx else {
            return max(Int(mx * 0.5), 60)
        }
        return max(Int(rhr + hrReserveFraction * (mx - rhr)), 60)
    }

    /// The resting-HR baseline to price a day's elevated time against, derived from the SAME HR
    /// samples the estimate is computed over.
    ///
    /// Deriving it here rather than threading a parameter through every call site is deliberate and
    /// load-bearing: `ExerciseMinutes.elevatedPieces` is the single owner of "which periods count",
    /// and `Calories` prices exactly those periods. A caller that forgot to pass the baseline would
    /// silently produce a different qualifying set for calories than for the minutes ring — the one
    /// invariant `GoalsCardView`'s footnote promises the user ("Active calories and elevated-HR
    /// minutes now use the same qualifying heart-rate periods"). Same input samples ⇒ same
    /// baseline ⇒ same periods, with no call site able to get it wrong.
    ///
    /// `RestingHR.lowestSustained` is the lowest rolling 5-min mean — Apple Health's own resting-HR
    /// convention. nil — too few samples, too short a span, no genuinely sustained window, or a
    /// value outside `plausibleRestingHR` — degrades to the %-of-max model.
    ///
    /// ⚠️ THE SUSTAINED-WINDOW CHECK IS NOT REDUNDANT. `lowestSustained` falls back to the single
    /// lowest reading whenever NO 5-min window held two readings, and the production auto-measure
    /// cadence is 600 s — longer than that window. So on a day whose HR is spot reads only (before
    /// the morning bulk sync, or a night that never synced) every window holds one reading and the
    /// "resting HR" becomes the day's single lowest read: one poor-contact 40 bpm sample would set
    /// the bar for the whole day. Adversarial review reproduced it — 30 reads at 10-min spacing, all
    /// 68 bpm except one 44, gave a baseline of 44.0 (2026-08-12). An earlier version of this comment
    /// claimed `lowestSustained`'s ≥2-reading rule prevented exactly that; it does not, because of
    /// the fallback. Asking for the guarantee explicitly is what makes the claim true.
    public static func restingBaseline(_ hrSamples: [HRSample]) -> Double? {
        let valid = hrSamples.filter { LiveHR.validBPM.contains($0.bpm) }
        guard valid.count >= minRestingBaselineSamples,
              let first = valid.map(\.start).min(), let last = valid.map(\.start).max(),
              last.timeIntervalSince(first) >= minRestingBaselineSpan,
              let derived = RestingHR.lowestSustainedDetailed(hr: valid,
                                                              window: RestingHR.sustainedWindow),
              derived.wasSustained
        else { return nil }
        return plausibleRestingHR.contains(derived.value) ? derived.value : nil
    }

    /// Estimate exercise minutes as the total merged duration of elevated-HR intervals,
    /// excluding samples that fall inside a sleep window.
    ///
    /// Algorithm:
    /// 1. Filter to samples with HR ≥ threshold and outside the sleep window.
    /// 2. Map each sample to an interval. Samples with a real span (end > start) use it
    ///    directly. POINT samples (start == end) are ambiguous on the wire: a 0x4c bulk
    ///    sleep-vitals epoch genuinely spans `epochSeconds`, but a live-HR spot read
    ///    (RingSession persists these as point samples too) represents only an instant.
    ///    To keep the bulk-epoch behavior without letting one isolated non-exercise spot
    ///    read inflate the Apple Exercise ring by a full 2.5 min, a point sample gets the
    ///    full `epochSeconds` width ONLY when it is part of a run of ≥2 consecutive
    ///    elevated readings spaced within one epoch (back-to-back bulk epochs / sustained
    ///    elevated HR). An ISOLATED elevated point read gets only `pointSampleWidth`
    ///    (default 0 — a single spot read is not evidence of voluntary exercise).
    /// 3. Merge overlapping intervals so consecutive elevated epochs are counted once.
    /// 4. Return the sum of merged interval durations in minutes.
    ///
    /// ESTIMATE — based on available HR samples only. Accuracy improves after #93 decode.
    ///
    /// Defined as the total duration of `elevatedPieces` so the scalar the Apple Exercise ring
    /// writes and the per-piece slices the energy estimate prices can never drift apart. See
    /// `elevatedPieces` for the algorithm; this contract is unchanged.
    public static func estimate(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval? = nil,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
        pointSampleWidth: TimeInterval = 0,
        restingHR: Double? = nil,
        deriveRestingHR: Bool = personalisedThresholdEnabled,
        motion: MotionEvidence = MotionEvidence(),
        corroborateMotion: Bool = motionCorroborationEnabled
    ) -> Double {
        let seconds = elevatedPieces(hrSamples: hrSamples,
                                     maxHR: maxHR,
                                     sleepWindow: sleepWindow,
                                     epochSeconds: epochSeconds,
                                     pointSampleWidth: pointSampleWidth,
                                     restingHR: restingHR,
                                     deriveRestingHR: deriveRestingHR,
                                     motion: motion,
                                     corroborateMotion: corroborateMotion)
            .reduce(0.0) { $0 + $1.seconds }
        return seconds / 60.0
    }

    /// One disjoint slice of elevated-HR time, carrying the bpm that priced it.
    ///
    /// `estimate` collapses the day to a single duration, which forces any energy model built on
    /// it to price the whole day at ONE average HR. That average is what froze active energy for
    /// the rest of the day once the last bout ended, and what let an isolated spot read dilute a
    /// morning workout's price (tester, 2026-07-28). Pieces keep the time structure so each slice
    /// can be priced — and placed — on its own.
    public struct ElevatedPiece: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let bpm: Int

        public init(start: Date, end: Date, bpm: Int) {
            self.start = start
            self.end = end
            self.bpm = bpm
        }

        public var seconds: TimeInterval { Swift.max(0, end.timeIntervalSince(start)) }
    }

    /// The same elevated intervals `estimate` sums, emitted as NON-OVERLAPPING, chronologically
    /// ordered slices that each carry their own bpm. Filtering, point-sample widening and overlap
    /// collapse are identical to `estimate` — which is now defined in terms of this — so the two
    /// can never disagree about how much elevated time a day contains.
    ///
    /// Overlap rule: where two elevated samples cover the same instant, the EARLIER one keeps it
    /// (the later slice starts where the earlier ends). Total duration is therefore exactly the
    /// merged-union duration, and a live spot read landing inside a bulk epoch cannot add time.
    ///
    /// `restingHR` personalises the threshold (see `threshold(maxHR:restingHR:)`). Left nil — every
    /// production call site — it is DERIVED from `hrSamples` via `restingBaseline`, so callers
    /// cannot accidentally price calories against a different qualifying set than the minutes ring
    /// uses. Pass a value explicitly only to override that derivation.
    ///
    /// `deriveRestingHR: false` is THE KILL-SWITCH: it restores the pre-HRR %-of-max model exactly,
    /// everywhere at once. It exists as a parameter rather than a mutable global so it stays
    /// Sendable and so the tests can pin both models side by side; flipping this default to `false`
    /// is the one-line revert. Note nil-`restingHR` alone does NOT mean "old model" here — nil means
    /// "derive it", which is why this flag is separate.
    ///
    /// `motion` + `corroborateMotion` are the #281 gate, resolved through `effectiveMotionEvidence`
    /// (see `motionCorroborationEnabled`). Gate on: a reading's interval counts only if
    /// `MotionGate.corroborates` it. The decision is made per reading BEFORE the overlap collapse, so
    /// time a gated reading would have claimed goes to a corroborated reading that overlaps it.
    public static func elevatedPieces(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval? = nil,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
        pointSampleWidth: TimeInterval = 0,
        restingHR: Double? = nil,
        deriveRestingHR: Bool = personalisedThresholdEnabled,
        motion: MotionEvidence = MotionEvidence(),
        corroborateMotion: Bool = motionCorroborationEnabled
    ) -> [ElevatedPiece] {
        let intervals = elevatedIntervals(
            hrSamples: hrSamples,
            maxHR: maxHR,
            sleepWindow: sleepWindow,
            epochSeconds: epochSeconds,
            pointSampleWidth: pointSampleWidth,
            restingHR: restingHR,
            deriveRestingHR: deriveRestingHR,
            motion: effectiveMotionEvidence(motion, corroborate: corroborateMotion))
        return pieces(sweeping: intervals.filter(\.corroborated))
    }

    /// One elevated reading's interval, before overlap collapse, with the gate's verdict on it.
    struct ElevatedInterval {
        let start: Date
        let end: Date
        let bpm: Int
        /// Always true with the gate off (`motion == nil`).
        let corroborated: Bool
    }

    /// One interval per elevated reading (at/above threshold, outside the sleep window), in start
    /// order. `Calories.legacyDailyEstimate` builds its qualifying bpm from the SAME list, so its
    /// average and its minutes can't come from two different qualifying sets (the hybrid
    /// `effectiveRestingBaseline`'s comment measures). `motion` is the RESOLVED evidence: pass it
    /// through `effectiveMotionEvidence`, never raw.
    static func elevatedIntervals(
        hrSamples: [HRSample],
        maxHR: Int,
        sleepWindow: DateInterval?,
        epochSeconds: TimeInterval = TimeInterval(BulkRecord.epochSeconds),
        pointSampleWidth: TimeInterval = 0,
        restingHR: Double? = nil,
        deriveRestingHR: Bool = personalisedThresholdEnabled,
        motion: MotionEvidence?
    ) -> [ElevatedInterval] {
        let effectiveRHR = restingHR ?? effectiveRestingBaseline(hrSamples, derive: deriveRestingHR)
        let thresh = threshold(maxHR: maxHR, restingHR: effectiveRHR)
        let elevated = hrSamples
            .filter { s in
                s.bpm >= thresh
                    && (sleepWindow.map { !$0.contains(s.start) } ?? true)
            }
            .sorted { $0.start < $1.start }

        guard !elevated.isEmpty else { return [] }

        // Build intervals. Real-span samples use their own duration. A point sample gets a
        // full epoch only when it neighbours another elevated reading within one epoch
        // (a sustained run); an isolated point read gets only `pointSampleWidth`.
        let intervals: [(start: Date, end: Date, bpm: Int)] = elevated.enumerated().map { idx, s in
            let dur = s.end.timeIntervalSince(s.start)
            if dur > 0 { return (s.start, s.end, s.bpm) }
            let prevClose = idx > 0
                && s.start.timeIntervalSince(elevated[idx - 1].start) <= epochSeconds
            let nextClose = idx < elevated.count - 1
                && elevated[idx + 1].start.timeIntervalSince(s.start) <= epochSeconds
            let width = (prevClose || nextClose) ? epochSeconds : pointSampleWidth
            return (s.start, s.start.addingTimeInterval(width), s.bpm)
        }

        let gate = motion.map { MotionGate(evidence: $0, hrSamples: hrSamples) }
        return intervals.map { iv in
            ElevatedInterval(start: iv.start, end: iv.end, bpm: iv.bpm,
                             corroborated: gate?.corroborates(start: iv.start, end: iv.end) ?? true)
        }
    }

    /// The overlap collapse `elevatedPieces` has always done, over intervals already in start order.
    static func pieces(sweeping intervals: [ElevatedInterval]) -> [ElevatedPiece] {
        // Collapse overlaps by sweeping a cursor instead of merging into maximal runs: each
        // interval contributes only the part not already covered. The emitted slices therefore
        // tile exactly the same union the old merge produced (same total duration), but keep the
        // per-slice bpm the merge threw away.
        var pieces: [ElevatedPiece] = []
        var cursor: Date?
        for interval in intervals {
            let start = cursor.map { Swift.max(interval.start, $0) } ?? interval.start
            guard interval.end > start else { continue }  // fully covered, or zero-width
            pieces.append(ElevatedPiece(start: start, end: interval.end, bpm: interval.bpm))
            cursor = interval.end
        }
        return pieces
    }
}
