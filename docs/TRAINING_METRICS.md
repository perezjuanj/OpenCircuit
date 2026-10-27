# Training metrics: training load and a VO₂ max estimate (#232)

Status: shipped on the phone for workouts the app records, ring and Helio Strap alike (every input
below is device-agnostic). Until 2026-10-03 the strap's recorder (#227) computed neither metric: its
summary had no TRAINING section and no VO₂ max ever reached Apple Health from a strap run. It now runs
the same `VO2MaxEstimate` over the strap's 1 Hz heart rate (readings inside the running stretches
only) and the phone's route, applies the 10-minute rule to RUNNING time (pauses left out), and writes
the estimate attributed to the strap rather than the ring (`VO2MaxHealthWriter.save(_:workoutEnd:timeline:)`).
The strap's own VO₂ max (Zepp's) is still never read (decision 34).

Scope (decision 34): the strap's own workout values are out of scope (#226 is closed). Everything
here is computed on the phone from the workout the app recorded:

- the workout's heart-rate series (and its 5-zone breakdown, #75);
- for outdoor runs, the phone's GPS route (distance, time and, when reliable, altitude);
- the user's profile (age) and the app's daily resting heart rate.

Every number is labelled an estimate. When an input is missing the app says what is missing instead
of filling it in.

| Metric | Shipped | Where | Apple Health |
|---|---|---|---|
| Training load per workout | yes | workout summary | no type exists; app only |
| Weekly load trend | yes | one line under Recent Workouts | app only |
| VO₂ max estimate | yes, outdoor runs ≥ 10 min with GPS | workout summary | `vo2Max`, submaximal prediction |
| Recovery time | **no** (§3) | — | — |
| Training effect | **no** (§3) | — | — |

Code: `OpenCircuitKit/Analytics/TrainingLoad.swift`, `OpenCircuitKit/Analytics/VO2MaxEstimate.swift`
(pure, tested in `TrainingMetricsTests.swift`), `OpenCircuit/TrainingMetricsViews.swift`,
`OpenCircuit/Health/VO2MaxHealthWriter.swift`, `OpenCircuit/Health/VO2MaxInputs.swift` (route, set
age and resting HR, shared by both recorders), the `vo2Max*` additions in
`WorkoutSessionManager.stop()` and in `StrapWorkoutRecorder.end()` (tested in
`StrapWorkoutRecorderTests`, "VO₂ max estimate").

---

## 1. Training load: Edwards' TRIMP

**Citation.** Edwards S. "High performance training and racing." In: Edwards S, ed. *The Heart Rate
Monitor Book*. Sacramento, CA: Feet Fleet Press; 1993:113–123.

**Method.** Minutes in each of five heart-rate zones, multiplied by the zone number, summed:

    TRIMP = 1 × min(50–60 % HRmax) + 2 × min(60–70 %) + 3 × min(70–80 %) + 4 × min(80–90 %) + 5 × min(90–100 %)

Worked example (in the tests): 10 / 15 / 20 / 8 / 2 minutes in zones 1–5
→ 10 + 30 + 60 + 32 + 10 = **142**.

**Inputs.** The workout's own zone breakdown, the same one the summary draws as zone bars, so the
load always agrees with what the user sees.

**Where it differs from Edwards, on purpose:**

- *Zone boundaries.* The app's zones (from RingConn's own zone screen, #75) start at 50/61/71/81/91 %
  of max instead of 50/60/70/80/90 %. A reading between 60 % and 61 % therefore counts as zone 1, not
  zone 2. Re-zoning would make the load disagree with the bars drawn right above it.
- *Max HR.* The zones use 220 − age, as the workout screen always has. Edwards uses the athlete's
  measured maximum.
- *Gaps.* Each reading is held until the next one, for at most 30 s (`timeInZonesHeld`). A dropout
  longer than that adds nothing, and nothing is interpolated (#45). Where the ring missed readings,
  the load is a lower bound.

**Why Edwards and not Banister.** Banister's TRIMP weights mean %HR-reserve with a sex-specific
exponential. It needs a resting HR for every workout and a mean HR that hides intervals. Edwards
needs only the zone time the app already has.

**When it is skipped.** If the workout recorded no heart rate at all (e.g. a crash-recovered
workout, which keeps only counts), the load shows `--` with "No heart rate was recorded". A workout
whose heart rate stayed under 50 % of max scores a real **0**, which is Edwards' answer, not a
missing value.

### 1.1 Weekly trend

- **This week** = the sum of the loads of workouts that ended in (now − 7 days, now].
- **4-week average** = the sum of the loads in (now − 35 days, now − 7 days], divided by 4.
- **Change** = this week ÷ average − 1, shown as a signed percentage, with an arrow:
  - up when the change is above +10 %;
  - down when it is below −10 %;
  - flat otherwise.
  The ±10 % band is a display choice, not physiology.
- **No earlier workouts:** if no scored workout ended in the previous 4 weeks, the line says "no
  earlier workouts to compare". The app can't tell four weeks of rest from four weeks before it was
  installed, so it shows no 0 average.
- **Nothing in the last 35 days:** the line is hidden, so it never reads "0" above a list of older
  workouts.
- **Workouts without heart rate** in the last 7 days are counted and named ("1 workout without heart
  rate not counted"), not scored as 0.
- **No injury-risk claim.** The line compares two numbers. It applies no acute:chronic thresholds
  and gives no advice.

**Source of history.** No local table and no SwiftData change. The line reads this app's own
workouts from the last 35 days back out of Apple Health. It re-scores each one from the heart-rate
samples saved with that workout (`HKQuery.predicateForObjects(from: workout)`), using the same held
zones and 220 − age as the summary, so the two agree (pinned by
`testLoadFromStoredHeartRateMatchesTheSummaryLoad`). The current age is used, so a birthday moves
older workouts' loads by one zone-boundary bpm at most. This needs no new authorization: workouts
come from our own source, and heart rate is already in the main request's read set.

---

## 2. VO₂ max estimate

### 2.1 Method and citations

1. **Oxygen cost of the run** at a steady speed. This uses the ACSM running equation (American
   College of Sports Medicine, *ACSM's Guidelines for Exercise Testing and Prescription*, chapter on
   metabolic calculations; the equation is unchanged across recent editions):

       VO₂ (mL·kg⁻¹·min⁻¹) = 0.2 × S + 0.9 × S × G + 3.5      S = speed (m/min), G = grade (fraction)

2. **Extrapolation to the maximum** through %HRR ≈ %VO₂R. Source: Swain DP, Leutholtz BC. "Heart rate
   reserve is equivalent to %VO₂ reserve, not to %VO₂max." *Med Sci Sports Exerc*.
   1997;29(3):410–414.

       (HR − HRrest) / (HRmax − HRrest) = (VO₂ − 3.5) / (VO₂max − 3.5)
       ⇒ VO₂max = 3.5 + (VO₂ − 3.5) × (HRmax − HRrest) / (HR − HRrest)

3. **Max HR.** The higher of:
   - Tanaka's age formula, 208 − 0.7 × age (Tanaka H, Monahan KD, Seals DR. "Age-predicted maximal
     heart rate revisited." *J Am Coll Cardiol*. 2001;37(1):153–156);
   - the highest 1-minute mean HR in this run.

**Worked example** (in the tests): 200 m/min (12 km/h) on the flat at 160 bpm, age 40, resting 60:

- ACSM cost: 0.2 × 200 + 3.5 = **43.5**
- Max HR: Tanaka 208 − 28 = 180 (the run's 160 is lower)
- VO₂max = 3.5 + 40 × 120 / 100 = **51.5 mL·kg⁻¹·min⁻¹**

The same run up a reliable 5 % grade costs 40 + 9 + 3.5 = 52.5, so VO₂max = 3.5 + 49 × 1.2 = **62.3**.

### 2.2 Inputs

| Input | Source | If missing |
|---|---|---|
| Sport | the workout's sport; only **Outdoor Running** | skipped: "only estimated for outdoor runs" |
| Duration | workout start → end | under 10 min: skipped |
| Speed | the phone's GPS fixes, as cumulative distance (the same running sum as the workout's distance: accuracy ≤ 50 m, no cached fixes) | no route: skipped |
| Grade | GPS altitude, only when reliable (§2.3) | assumed flat, and the UI says so |
| Heart rate | the workout's recorded readings (ring now, strap via #227) | too few: skipped |
| Age | Profile, only if the user set it. The app's placeholder 35 is never used here | skipped: "set your age in Profile" |
| Resting HR | median of the last 7 daily resting-HR values on or before the run day (`RestingHR.dailyValues`, the series the app already shows). The workout's own window is excluded | fewer than 3 days: skipped |

### 2.3 Rules and where each comes from

| Rule | Value | Origin |
|---|---|---|
| Qualifying run | Outdoor Running, ≥ 10 min, GPS route | #232 (Amazfit's own 10-minute outdoor-run rule) |
| Steady state | ACSM equations describe steady-state exercise | ACSM |
| Warm-up excluded | first 4 min | ours: HR needs a few minutes to reach steady state |
| Segment | 5 consecutive 1-minute bins | ours |
| Bin valid | ≥ 2 HR readings, and a GPS fix within 15 s of both minute edges (GPS gaps are never bridged) | ours |
| Steady pace | coefficient of variation of the 5 bin speeds ≤ 10 % | ours |
| Steady HR | the 5 bin means span ≤ 10 bpm | ours |
| Speed range | 80–400 m/min | ACSM: the running equation applies above 134 m/min, and down to 80 m/min when the person is truly jogging (the user chose "running"). The 400 m/min (24 km/h) ceiling is a GPS plausibility guard (ours) |
| Reliable elevation | ≥ 3 fixes in the segment, every one with 0 < vertical accuracy ≤ 10 m, covering ≥ 100 m | ours |
| Grade | least-squares slope of altitude against distance over the segment | ours |
| Grade range | −1 % … +15 %; −1 %…0 is read as level (altitude noise); steeper downhill is excluded | ours: the grade term models uphill work, so it is not used to credit downhill running |
| Segment choice | the qualifying segment with the lowest speed CV; ties go to the earliest | ours |
| Intensity | segment HR ≥ 50 % of HR reserve | ours: below that, the extrapolation multiplies GPS and HR error by more than 2× |
| Plausible result | 15–90 mL·kg⁻¹·min⁻¹ | ours: outside it the input is wrong, not the person |
| Observed max | highest 1-minute mean, not the highest single reading | ours: one optical spike must not raise max HR |

**Sensitivity, stated so nobody over-reads the number.** In the worked example, a max HR of 190
instead of 180 raises the estimate from 51.5 to 55.5. The age formula's spread across people is about
that size. A 5 % error in GPS speed moves it by about 5 % as well. The estimate is good for following
one person's trend on similar routes. It is not a lab value.

### 2.4 Skip reasons (exact UI copy, after "No VO₂ max estimate: ")

| Reason | Copy |
|---|---|
| not an outdoor run | "it is only estimated for outdoor runs." (shown only on Outdoor Running summaries, so in practice a detected or recovered run without GPS shows the no-GPS line) |
| too short | "the run was shorter than 10 minutes." |
| no GPS | "there was no GPS route for this run." |
| no heart rate | "too few heart-rate readings during the run." |
| no age | "set your age in Profile so a maximum heart rate can be estimated." |
| no resting HR | "there isn't enough heart-rate history yet for a resting heart rate (3 days needed)." |
| no steady segment | "the run had no steady 5-minute stretch (even pace, heart rate and GPS, level or uphill)." |
| too easy | "the steady stretch was too easy (under half your heart-rate reserve) to extrapolate from." |
| implausible | "the result fell outside a plausible range, so it was discarded." |

### 2.5 Apple Health

- **Type and unit.** `HKQuantityType(.vo2Max)` in mL/(kg·min), stamped at the workout's end time,
  attributed to the active wearable (`activeWearableDevice()`).
- **Metadata:**
  - `HKMetadataKeyVO2MaxTestType` = `HKVO2MaxTestType.predictionSubMaxExercise`. This is Apple's
    "predicted from submaximal exercise"; the SDK has no case named `.predictionSubMaximal`.
  - `HKMetadataKeyWasUserEntered` = false.
  - `OpenCircuitVO2MaxMethod` names the method.
- **When it is written.** Only when the workout itself was saved, and only once per run (from
  `stop()`).

**Authorization (#210, the build-50 permission loop).**

- *Lazy.* `vo2Max` is not in `HealthKitWriter.allTypes`, so nothing new is asked at launch or on
  upgrade.
- *First estimate.* The first time an estimate is about to be written, `VO2MaxHealthWriter` asks for
  `vo2Max` **share only**: `requestAuthorization(toShare: [vo2Max], read: [])`.
- *Why this can't recreate the loop.* The build-50 loop needed two requests that disagreed about one
  type. `vo2Max` is named by this request only, and the main request never names it. Two tests pin
  this:
  - `HealthKitAuthorizationSurfaceTests.testTheLazyVO2MaxRequestNamesOnlyVO2Max` (Kit source
    audit) allows that exact request and forbids the type anywhere else in the app;
  - `HealthKitShareTypesTests.testVO2MaxStaysOutOfTheMainRequest` (app).
- *No first prompt.* If Apple Health was never connected (heart-rate share is off), the app shows no
  prompt at all, because a VO₂-only sheet would be that user's first Health prompt. The summary says
  "Apple Health isn't connected".
- *Denied.* If VO₂ max sharing was denied, the app doesn't ask again. The summary says sharing is off.
- **Not yet observed on a device:** that this second, disjoint request leaves the existing Workouts,
  Workout Routes and Heart Rate grants intact. This is the PR's on-phone check.

---

## 2b. Heart rate recovery (#337, decision 82)

Heart rate recovery (HRR) is how far heart rate falls after a hard effort. The app measures it the way
the tester's app (Bevel) defines it, from readings only: nothing is interpolated or defaulted.

- **Peak** = the highest reading in the workout's active time (the running stretches; pauses hold none).
- **HRR1** = peak − the reading nearest end + 60 s; **HRR2** = peak − the reading nearest end + 120 s.
  A reading counts only within 10 s of its mark (inclusive; on a tie the earlier one).
- **Only after zone 4.** Computed only when the peak reached zone 4, the bound read through the zone
  classifier for the person (`HeartRateRecovery.zoneFourLowerBound`), whatever source of bounds is
  current. Otherwise "not measured", with the reason in words.
- **The window.** After End the strap's stream keeps running for 120 s, plus up to 10 s to catch the
  +120 s reading. The workout itself is saved at End exactly as before. Skip, a new workout, or the
  link dropping end the window early; a missing value then says why. A workout ended while paused
  ended where the pause began, so the readings the strap streamed during that pause count.
- **Where it shows.** The summary (a countdown with Skip, then "Heart rate recovery: 1 min -N bpm,
  2 min -M bpm"), and the workout detail, re-derived from the app's stored rows inside the window this
  app recorded for that workout (`WorkoutRecoveryWindows`), never from Health's readings.
- **Apple Health.** The readings as heart-rate samples after the workout; HRR1 as Cardio Recovery at
  end + 60 s (`docs/HEALTHKIT_MAPPING.md`).
- **The ring** has no recovery window yet: its workout ends with SportStop (`06 00 00`), and its live
  heart rate after that is a smoothed, converging average whose first value after a mode change is
  not yet measured on hardware (follow-up in #337's PR).

Code: `OpenCircuitKit/Analytics/HeartRateRecovery.swift` (pure, `HeartRateRecoveryTests`), the
recorder's window in `Helio/StrapWorkoutRecorder.swift`.

---

## 3. Recovery time and training effect: not shipped

The brief allows these only with a published, documented method, and we found none that can be
reproduced from heart rate (plus pace) without invented constants.

- **Training effect (aerobic and anaerobic)** and **recovery time** as shown by Zepp come from
  Firstbeat's models. Firstbeat has published white papers on the concepts: Training Effect is
  scaled from EPOC, the excess post-exercise oxygen consumption. The model that estimates EPOC from
  heart rate, and the mappings to a 0–5 effect or to hours, are proprietary. Re-deriving them would
  be inventing a formula and borrowing a brand's scale.
- **Banister's impulse-response (fitness–fatigue) model** is published (Banister et al., 1975). It
  needs per-person constants (gains k₁, k₂ and decay times τ₁, τ₂) fitted against performance tests
  the app doesn't have. Generic textbook constants would turn one of our guesses into a "recovery
  time".
- **Recovery time from HR alone** has no validated published formula we could find.

So both are left out. If a published, reproducible method turns up, it can be added behind the same
rules as §1–§2.

---

## 4. Two-week comparison against Zepp: the tolerance, fixed before shipping

The issue's exit criterion is that over two weeks of real workouts our values fall within a
tolerance, written down in advance, of Zepp's values for the same workouts. Here it is. Changing a
threshold after seeing the data invalidates the run.

**Setup.**

- For 14 consecutive days, record each workout in OpenCircuit and, at the same time, on the Helio
  Strap with the Zepp app.
- Note Zepp's values for each workout from the Zepp app by hand. #226 is closed, so there is no
  import.
- Pair workouts by start time (within 5 min).
- OpenCircuit records with whichever wearable it has (ring today, strap via #227). Zepp computes from
  the strap. So a disagreement can come from the input heart rate as much as from the method. Note
  which wearable OpenCircuit used for each workout.

**VO₂ max.**

- *Paired values:* for every run where both apps produced a value, our per-run estimate against the
  VO₂ max Zepp shows after that run.
- *Pass if all three hold:*
  - the median absolute difference is **≤ 3.5 mL·kg⁻¹·min⁻¹** (1 MET);
  - **≥ 80 %** of runs are within **±5 mL·kg⁻¹·min⁻¹**;
  - the median of our two-week estimates is within **±3.5** of Zepp's value on day 14.
- *Too few runs:* with fewer than 4 paired runs the result is **inconclusive**, not a pass.
- *Why 3.5:* each step of the method (ACSM cost, age-formula max, %HRR ≈ %VO₂R) carries an error of
  about one MET, and Zepp smooths across runs while we don't. A tighter band would test luck, not
  method.

**Training load.**

- Zepp's training load is EPOC-based and on its own scale, so absolute values can't be compared. The
  test is agreement in **ordering and trend**:
  - per workout: Spearman rank correlation **ρ ≥ 0.70** between our load and Zepp's per-workout
    load, over **≥ 8** paired workouts (fewer is inconclusive);
  - per day: Pearson **r ≥ 0.80** between our 7-day sum and Zepp's 7-day training load, evaluated
    once a day on each of the 14 days.

**Not compared:** recovery time and training effect (§3, not shipped).

**If it fails:**

- Don't tune constants until the numbers match Zepp. The §2.3 thresholds and the §1.1 band are the
  only knobs. Changing any of them means updating this document and the tests in the same commit,
  then running a new two-week comparison.
- Publish counts, the summary statistics and pass/fail, never individual health values. The repo is
  public.

### 4.1 Results

Not yet run.
